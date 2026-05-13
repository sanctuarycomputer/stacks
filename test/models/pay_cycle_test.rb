require "test_helper"

class PayCycleTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "G3D Test #{SecureRandom.hex(2)}")
    @starts = Date.new(2026, 5, 1)
    @ends = Date.new(2026, 5, 31)
  end

  test "valid with enterprise, starts_at, ends_at" do
    pc = PayCycle.new(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    assert pc.valid?, pc.errors.full_messages.inspect
  end

  test "requires starts_at <= ends_at" do
    pc = PayCycle.new(enterprise: @enterprise, starts_at: @ends, ends_at: @starts)
    refute pc.valid?
    assert_includes pc.errors[:ends_at], "must be on or after starts_at"
  end

  test "uniqueness on (enterprise_id, starts_at, ends_at)" do
    PayCycle.create!(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    dup = PayCycle.new(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    refute dup.valid?
  end

  test "stubs_status returns :no_stubs when there are no pay_stubs" do
    pc = PayCycle.create!(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    assert_equal :no_stubs, pc.stubs_status
  end

  test "acts_as_paranoid soft-deletes" do
    pc = PayCycle.create!(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    pc.destroy
    assert pc.deleted_at.present?
    assert_equal 0, PayCycle.where(id: pc.id).count
    assert_equal 1, PayCycle.with_deleted.where(id: pc.id).count
  end

  test "rejects a cycle that overlaps an existing sibling" do
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))
    overlap = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 5, 10), ends_at: Date.new(2026, 5, 20))
    refute overlap.valid?
    assert_includes overlap.errors[:base], "overlaps another pay cycle for this enterprise"
  end

  test "rejects a cycle that doesn't start the day after the latest sibling's ends_at" do
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))
    # Should start May 16. May 17 leaves a gap; rejected.
    gap = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 5, 17), ends_at: Date.new(2026, 5, 31))
    refute gap.valid?
    assert(gap.errors[:starts_at].any? { |e| e.include?("contiguous") })
  end

  test "accepts a contiguous cycle starting the day after the latest sibling" do
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))
    next_one = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 5, 16), ends_at: Date.new(2026, 5, 31))
    assert next_one.valid?, next_one.errors.full_messages.inspect
  end

  test "first cycle for an enterprise has no timeline constraint" do
    # No prior cycles → any (starts_at, ends_at) is acceptable.
    first = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2027, 3, 7), ends_at: Date.new(2027, 3, 22))
    assert first.valid?, first.errors.full_messages.inspect
  end

  test "switching cadence mid-stream is allowed (twice_monthly → monthly picks up where prior cycle left off)" do
    # Twice-monthly first half
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))
    # Now switch to monthly — the next cycle continues from May 16 through end of month
    transition = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 5, 16), ends_at: Date.new(2026, 5, 31))
    assert transition.valid?
    transition.save!
    # Next monthly cycle runs Jun 1..30
    next_monthly = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30))
    assert next_monthly.valid?
  end
end
