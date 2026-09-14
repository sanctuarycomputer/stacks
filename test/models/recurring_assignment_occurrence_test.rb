require "test_helper"

class RecurringAssignmentOccurrenceTest < ActiveSupport::TestCase
  setup do
    @ra = RecurringAssignment.create!(
      forecast_person_id: 1, forecast_project_id: 2, allocation: 900,
      weekdays: [1], starts_on: Date.new(2026, 8, 3),
    )
  end

  test "status must be a known value" do
    occ = @ra.recurring_assignment_occurrences.new(occurs_on: Date.new(2026, 8, 3), status: "bogus")
    assert_not occ.valid?
  end

  test "materialized/deleted scopes" do
    m = @ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 3), status: "materialized")
    d = @ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 10), status: "deleted")
    assert_includes RecurringAssignmentOccurrence.materialized, m
    assert_includes RecurringAssignmentOccurrence.deleted, d
  end

  test "occurs_on is unique per rule" do
    @ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 3))
    dup = @ra.recurring_assignment_occurrences.new(occurs_on: Date.new(2026, 8, 3))
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end
end
