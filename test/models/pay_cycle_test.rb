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
end
