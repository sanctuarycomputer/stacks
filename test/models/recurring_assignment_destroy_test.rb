require "test_helper"

class RecurringAssignmentDestroyTest < ActiveSupport::TestCase
  test "destroying a rule leaves its Forecast assignments intact (they are historical records)" do
    ra = RecurringAssignment.create!(
      forecast_person_id: 1, forecast_project_id: 2, allocation: 900,
      weekdays: [1], starts_on: Date.today - 30,
    )
    ra.recurring_assignment_occurrences.create!(occurs_on: Date.today - 7, status: "materialized", forecast_assignment_id: 100)
    ra.recurring_assignment_occurrences.create!(occurs_on: Date.today, status: "materialized", forecast_assignment_id: 200)

    # Destroy makes NO Forecast API calls — every materialized assignment is a record of
    # allocation that already happened, so it's left untouched; only tracking rows go.
    Stacks::Forecast.expects(:new).never
    Stacks::Forecast.expects(:delete).never

    ra.destroy!

    assert_equal 0, RecurringAssignmentOccurrence.where(recurring_assignment_id: ra.id).count,
      "occurrence tracking rows are removed, but the Forecast assignments remain"
  end
end
