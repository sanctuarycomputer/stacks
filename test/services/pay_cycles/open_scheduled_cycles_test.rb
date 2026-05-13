require "test_helper"

# Edge-case tests for PayCycles::OpenScheduledCycles — date math at
# year/leap boundaries, February truncation, and error-isolation semantics.
class PayCycles::OpenScheduledCyclesEdgeCasesTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "OSC-EC-#{SecureRandom.hex(2)}")
  end

  # ─── 1. Year-boundary monthly cadence ────────────────────────────────────────
  # Prior cycle: Dec 1-31 2026. Cron runs Feb 1 2027 (Jan's cycle ends Jan 31).
  # Next cycle should be Jan 1-31, correctly spanning the year boundary.
  test "monthly: year-boundary — opens Jan 2027 when prior cycle was Dec 2026" do
    @enterprise.update!(pay_cycle_cadence: "monthly")
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 12, 1), ends_at: Date.new(2026, 12, 31))

    travel_to Date.new(2027, 2, 1) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2027, 1, 1), cycle.starts_at
      assert_equal Date.new(2027, 1, 31), cycle.ends_at
    end
  end

  # ─── 2. Leap-year February (monthly cadence) ─────────────────────────────────
  # 2028 is a leap year — Feb has 29 days. Prior cycle: Jan 2028.
  # Cron runs Mar 1 2028 → should open Feb 1-29.
  test "monthly: leap-year Feb 2028 ends on the 29th" do
    @enterprise.update!(pay_cycle_cadence: "monthly")
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2028, 1, 1), ends_at: Date.new(2028, 1, 31))

    travel_to Date.new(2028, 3, 1) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2028, 2, 1), cycle.starts_at
      assert_equal Date.new(2028, 2, 29), cycle.ends_at
    end
  end

  # ─── 3. Twice-monthly Feb in a non-leap year (bootstrap) ─────────────────────
  # 2027 is not a leap year — Feb has 28 days.
  # travel_to Mar 1 2027, no prior cycle.
  # Bootstrap: today (Mar 1) falls in the Mar 1-15 range → previous range is
  # Feb 16-28. Cron opens Feb 16-28.
  test "twice_monthly: Feb second-half ends on the 28th in non-leap year" do
    @enterprise.update!(pay_cycle_cadence: "twice_monthly")

    travel_to Date.new(2027, 3, 1) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2027, 2, 16), cycle.starts_at
      assert_equal Date.new(2027, 2, 28), cycle.ends_at
    end
  end

  # ─── 4. Twice-monthly Feb in a leap year (bootstrap) ─────────────────────────
  # 2028 is a leap year — Feb has 29 days.
  # travel_to Mar 1 2028, no prior cycle.
  # Bootstrap → previous range is Feb 16-29.
  test "twice_monthly: Feb second-half ends on the 29th in leap year" do
    @enterprise.update!(pay_cycle_cadence: "twice_monthly")

    travel_to Date.new(2028, 3, 1) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2028, 2, 16), cycle.starts_at
      assert_equal Date.new(2028, 2, 29), cycle.ends_at
    end
  end

  # ─── 5. MissingRateError: cycle is persisted even when GenerateStubs raises ──
  # Setup: enterprise + internal client + assignment with NO rate tag.
  # open_cycle_for should create the cycle row AND then raise MissingRateError.
  test "open_cycle_for: cycle is persisted even when GenerateStubs raises MissingRateError" do
    @enterprise.update!(pay_cycle_cadence: "monthly")

    # Seed a prior cycle so next_starts_at is deterministic (Jun 1-30)
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))

    # Assignment overlaps the NEXT cycle (Jun 1-30) so GenerateStubs picks it up
    setup_missing_rate_assignment(@enterprise, Date.new(2026, 6, 1), Date.new(2026, 6, 30))

    travel_to Date.new(2026, 6, 30) do
      assert_raises(PayCycles::GenerateStubs::MissingRateError) do
        PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      end
      # The cycle row must have been committed BEFORE the raise
      assert_equal 2, @enterprise.pay_cycles.count,
        "cycle should be persisted even though GenerateStubs raised"
    end
  end

  # ─── 6. .call continues iteration when one enterprise fails ──────────────────
  # Two enterprises with monthly cadence. The second has a missing-rate assignment.
  # Expect: first enterprise's cycle is created; .call raises aggregate RuntimeError.
  test ".call continues past one enterprise's failure and raises aggregate at the end" do
    good_enterprise = Enterprise.find_or_create_by!(name: "OSC-Good-#{SecureRandom.hex(2)}")
    good_enterprise.update!(pay_cycle_cadence: "monthly")

    bad_enterprise = Enterprise.find_or_create_by!(name: "OSC-Bad-#{SecureRandom.hex(2)}")
    bad_enterprise.update!(pay_cycle_cadence: "monthly")
    # Seed a prior cycle so the next range (May) is deterministic
    PayCycle.create!(enterprise: bad_enterprise, starts_at: Date.new(2026, 4, 1), ends_at: Date.new(2026, 4, 30))
    setup_missing_rate_assignment(bad_enterprise, Date.new(2026, 5, 1), Date.new(2026, 5, 31))

    travel_to Date.new(2026, 6, 1) do
      err = assert_raises(RuntimeError) do
        PayCycles::OpenScheduledCycles.call
      end
      assert_match(/OpenScheduledCycles partial failure/, err.message)
      assert_match(/#{bad_enterprise.name}/, err.message)
      # Good enterprise must have had its cycle created despite the bad one failing
      assert_equal 1, good_enterprise.pay_cycles.count,
        "good enterprise should still have a cycle created"
    end
  end

  # ─── 7. .call does NOT raise when all enterprises succeed ────────────────────
  test ".call returns an array of cycles and does not raise when all succeed" do
    ent_a = Enterprise.find_or_create_by!(name: "OSC-A-#{SecureRandom.hex(2)}")
    ent_a.update!(pay_cycle_cadence: "monthly")
    ent_b = Enterprise.find_or_create_by!(name: "OSC-B-#{SecureRandom.hex(2)}")
    ent_b.update!(pay_cycle_cadence: "monthly")

    travel_to Date.new(2026, 6, 1) do
      cycles = nil
      assert_nothing_raised { cycles = PayCycles::OpenScheduledCycles.call }
      opened_enterprise_ids = cycles.map(&:enterprise_id)
      assert_includes opened_enterprise_ids, ent_a.id
      assert_includes opened_enterprise_ids, ent_b.id
    end
  end

  # ─── 8. Bootstrap when today is exactly the first of the month ───────────────
  # Monthly cadence, no prior cycle, today = Jun 1. The default range is Jun 1-30,
  # which covers today, so bootstrap falls back to the PREVIOUS month (May 1-31).
  # May 31 < Jun 1, so the cycle is opened.
  test "monthly: bootstrap on the 1st opens the previous month's cycle" do
    @enterprise.update!(pay_cycle_cadence: "monthly")

    travel_to Date.new(2026, 6, 1) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2026, 5, 1), cycle.starts_at
      assert_equal Date.new(2026, 5, 31), cycle.ends_at
    end
  end

  # ─── 9. Bootstrap on a cycle's own end date ──────────────────────────────────
  # Monthly cadence, no prior cycle, today = May 31.
  # The default range for May 31 is May 1-31, which covers today, so bootstrap
  # falls back to the PREVIOUS range: Apr 1-30 (ends Apr 30 < May 31). Opens Apr.
  test "monthly: bootstrap on May 31 opens the April cycle (not May)" do
    @enterprise.update!(pay_cycle_cadence: "monthly")

    travel_to Date.new(2026, 5, 31) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2026, 4, 1), cycle.starts_at
      assert_equal Date.new(2026, 4, 30), cycle.ends_at
    end
  end

  # ─── 10. Subsequent cycle on its own end date ─────────────────────────────────
  # Prior cycle: Apr 1-30. Today: May 31 (== ends_at of the next May cycle).
  # next_starts_at = May 1, next_ends_at = May 31. today >= May 31 → opens May.
  test "monthly: subsequent cycle opens on its own end date" do
    @enterprise.update!(pay_cycle_cadence: "monthly")
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 4, 1), ends_at: Date.new(2026, 4, 30))

    travel_to Date.new(2026, 5, 31) do
      cycle = PayCycles::OpenScheduledCycles.open_cycle_for(@enterprise)
      assert_not_nil cycle
      assert_equal Date.new(2026, 5, 1), cycle.starts_at
      assert_equal Date.new(2026, 5, 31), cycle.ends_at
    end
  end

  # ─── 11. .call is idempotent within a single day ─────────────────────────────
  # Two successive .call invocations on the same day must not double-open.
  test ".call called twice on the same day creates at most one cycle per enterprise" do
    @enterprise.update!(pay_cycle_cadence: "monthly")

    travel_to Date.new(2026, 6, 1) do
      PayCycles::OpenScheduledCycles.call
      PayCycles::OpenScheduledCycles.call
      # May 1-31 opened on first call; June cycle (Jun 1-30) not yet due.
      assert_equal 1, @enterprise.pay_cycles.count
    end
  end

  private

  def safe_random_id
    rand(1..2_000_000_000)
  end

  # Sets up a qualifying assignment whose ForecastProject has NO rate tag,
  # which causes PayCycles::GenerateStubs to raise MissingRateError.
  # The assignment spans `start_date..end_date` so it falls within the cycle.
  def setup_missing_rate_assignment(enterprise, start_date, end_date)
    internal_client = ForecastClient.create!(forecast_id: safe_random_id, name: "garden3d")
    EnterpriseForecastClient.find_or_create_by!(enterprise: enterprise, forecast_client_id: internal_client.forecast_id)
    no_rate_project = ForecastProject.create!(
      forecast_id: safe_random_id,
      client_id: internal_client.forecast_id,
      name: "NoRate #{SecureRandom.hex(2)}",
      tags: []  # no XXp/h tag → MissingRateError
    )
    fp = ForecastPerson.create!(forecast_id: safe_random_id, email: "nr#{SecureRandom.hex(3)}@example.com", data: {})
    AdminUser.create!(email: fp.email, password: "password123", password_confirmation: "password123")
    Contributor.find_or_create_by!(forecast_person: fp)
    ForecastAssignment.create!(
      forecast_id: safe_random_id,
      person_id: fp.forecast_id,
      project_id: no_rate_project.forecast_id,
      start_date: start_date,
      end_date: end_date,
      allocation: 8 * 60 * 60
    )
  end
end

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
