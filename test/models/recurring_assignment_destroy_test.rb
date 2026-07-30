require "test_helper"

class RecurringAssignmentDestroyTest < ActiveSupport::TestCase
  test "destroying a rule deletes future materialized occurrences from Forecast, not past ones" do
    ra = RecurringAssignment.create!(
      forecast_person_id: 1, forecast_project_id: 2, allocation: 900,
      weekdays: [1], starts_on: Date.today - 30,
    )
    past   = ra.recurring_assignment_occurrences.create!(occurs_on: Date.today - 7, status: "materialized", forecast_assignment_id: 100)
    future = ra.recurring_assignment_occurrences.create!(occurs_on: Date.today + 7, status: "materialized", forecast_assignment_id: 200)
    tomb   = ra.recurring_assignment_occurrences.create!(occurs_on: Date.today + 8, status: "deleted",      forecast_assignment_id: 300)

    client = Stacks::Forecast.allocate.tap { |c| c.instance_variable_set(:@headers, {}) }
    Stacks::Forecast.stubs(:new).returns(client)
    client.expects(:delete_assignment).with(200).once.returns(true)
    # past (100) and tombstoned (300) must NOT be deleted
    client.expects(:delete_assignment).with(100).never
    client.expects(:delete_assignment).with(300).never

    ra.destroy!
    assert_equal 0, RecurringAssignmentOccurrence.where(recurring_assignment_id: ra.id).count
  end
end
