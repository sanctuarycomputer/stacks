require "test_helper"

class CommissionTest < ActiveSupport::TestCase
  test "validates type presence" do
    c = Commission.new(rate: 0.1)
    assert_not c.valid?
    assert_includes c.errors[:type], "can't be blank"
  end

  test "validates rate presence" do
    c = PercentageCommission.new
    assert_not c.valid?
    assert_includes c.errors[:rate], "can't be blank"
  end

  test "validates rate is non-negative" do
    c = PercentageCommission.new(rate: -0.1)
    assert_not c.valid?
    assert_includes c.errors[:rate], "must be greater than or equal to 0"
  end

  test "is acts_as_paranoid (soft-delete via deleted_at)" do
    assert Commission.respond_to?(:with_deleted)
  end
end
