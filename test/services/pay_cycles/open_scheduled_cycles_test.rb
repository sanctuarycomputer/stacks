require "test_helper"

class PayCycles::OpenScheduledCyclesTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "OSC-#{SecureRandom.hex(2)}")
  end

  test "skips enterprises with no cadence set" do
    assert_nil PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
    assert_equal 0, @enterprise.pay_cycles.count
  end

  test "monthly: opens the previous month's cycle on the first of the new month" do
    @enterprise.update!(pay_cycle_cadence: "monthly")
    travel_to Date.new(2026, 6, 1) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2026, 5, 1), cycle.starts_at
      assert_equal Date.new(2026, 5, 31), cycle.ends_at
    end
  end

  test "monthly: does NOT open the current month's cycle mid-month" do
    @enterprise.update!(pay_cycle_cadence: "monthly")
    travel_to Date.new(2026, 5, 15) do
      # April ended Apr 30, so the bootstrap cycle would be April 1-30 (already ended).
      # But this test exercises the case where today is mid-May — the May cycle
      # (May 1-31) shouldn't open yet because today < May 31.
      # If April 1-30 hasn't been opened, the cron opens it; we want to confirm
      # the next-cycle logic (after April) doesn't auto-open May yet.
      first_cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_equal Date.new(2026, 4, 1), first_cycle.starts_at
      assert_equal Date.new(2026, 4, 30), first_cycle.ends_at

      second_attempt = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_nil second_attempt, "should NOT open May cycle on May 15 since it hasn't ended"
      assert_equal 1, @enterprise.pay_cycles.count
    end
  end

  test "monthly: opens the next cycle the day after the latest one ends" do
    @enterprise.update!(pay_cycle_cadence: "monthly")
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 4, 1), ends_at: Date.new(2026, 4, 30))

    travel_to Date.new(2026, 5, 31) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2026, 5, 1), cycle.starts_at
      assert_equal Date.new(2026, 5, 31), cycle.ends_at
    end
  end

  test "twice_monthly: opens the first-half cycle on the 16th" do
    @enterprise.update!(pay_cycle_cadence: "twice_monthly")
    travel_to Date.new(2026, 5, 16) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2026, 5, 1), cycle.starts_at
      assert_equal Date.new(2026, 5, 15), cycle.ends_at
    end
  end

  test "twice_monthly: opens the second-half cycle on the first of the next month" do
    @enterprise.update!(pay_cycle_cadence: "twice_monthly")
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))

    travel_to Date.new(2026, 6, 1) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2026, 5, 16), cycle.starts_at
      assert_equal Date.new(2026, 5, 31), cycle.ends_at
    end
  end

  test "cadence change mid-stream: twice_monthly cycle then monthly fills the second half" do
    @enterprise.update!(pay_cycle_cadence: "twice_monthly")
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))

    # Admin switches to monthly between cycles
    @enterprise.update!(pay_cycle_cadence: "monthly")
    travel_to Date.new(2026, 6, 1) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      # Starts the day after the last twice_monthly cycle ended (May 16)
      assert_equal Date.new(2026, 5, 16), cycle.starts_at
      # Monthly ends_at uses end_of_month
      assert_equal Date.new(2026, 5, 31), cycle.ends_at
    end
  end

  test "is idempotent on the same day (won't double-open)" do
    @enterprise.update!(pay_cycle_cadence: "monthly")
    travel_to Date.new(2026, 6, 1) do
      first = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil first
      # Same day, same call → no new cycle (next would be June 1-30, hasn't ended yet)
      second = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_nil second
      assert_equal 1, @enterprise.pay_cycles.count
    end
  end

  test ".call iterates all enterprises with cadence set" do
    @enterprise.update!(pay_cycle_cadence: "monthly")
    other = Enterprise.find_or_create_by!(name: "OSC-Other-#{SecureRandom.hex(2)}")
    other.update!(pay_cycle_cadence: "monthly")
    no_cadence = Enterprise.find_or_create_by!(name: "OSC-Nada-#{SecureRandom.hex(2)}")
    # no_cadence has no pay_cycle_cadence — should be skipped

    travel_to Date.new(2026, 6, 1) do
      opened = PayCycles::OpenScheduledCycles.call
      assert_includes opened.map(&:enterprise_id), @enterprise.id
      assert_includes opened.map(&:enterprise_id), other.id
      refute_includes opened.map(&:enterprise_id), no_cadence.id
    end
  end
end
