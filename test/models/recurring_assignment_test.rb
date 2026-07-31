require "test_helper"

class RecurringAssignmentTest < ActiveSupport::TestCase
  def valid_attrs(overrides = {})
    { forecast_person_id: 1, forecast_project_id: 2, allocation: 28_800,
      weekdays: [1, 2, 3, 4, 5], starts_on: Date.new(2026, 8, 3) }.merge(overrides)
  end

  test "valid with default attrs" do
    assert RecurringAssignment.new(valid_attrs).valid?
  end

  test "requires positive integer allocation" do
    assert_not RecurringAssignment.new(valid_attrs(allocation: 0)).valid?
    assert_not RecurringAssignment.new(valid_attrs(allocation: nil)).valid?
  end

  test "weekdays must be present and within 0..6" do
    assert_not RecurringAssignment.new(valid_attrs(weekdays: [])).valid?
    assert_not RecurringAssignment.new(valid_attrs(weekdays: [7])).valid?
    assert RecurringAssignment.new(valid_attrs(weekdays: [0, 6])).valid?
  end

  test "ends_on must not precede starts_on" do
    assert_not RecurringAssignment.new(valid_attrs(ends_on: Date.new(2026, 8, 2))).valid?
    assert RecurringAssignment.new(valid_attrs(ends_on: Date.new(2026, 8, 3))).valid?
  end

  test "active scope excludes paused rows" do
    a = RecurringAssignment.create!(valid_attrs)
    b = RecurringAssignment.create!(valid_attrs(paused_at: Time.current))
    assert_includes RecurringAssignment.active, a
    assert_not_includes RecurringAssignment.active, b
  end

  test "allocation_in_hours converts to/from seconds" do
    ra = RecurringAssignment.new(valid_attrs(allocation: 28_800))
    assert_equal 8.0, ra.allocation_in_hours
    ra.allocation_in_hours = 4
    assert_equal 14_400, ra.allocation
  end
end
