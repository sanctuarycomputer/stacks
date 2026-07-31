require "test_helper"

class Api::RecurringAssignmentsTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  test "403 without key" do
    post "/api/recurring_assignments", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "creates a rule applying 8h/Mon-Fri/today defaults" do
    post "/api/recurring_assignments", headers: auth,
      params: { forecast_person_id: 324711, forecast_project_id: 3033811 }.to_json
    assert_response :success
    ra = RecurringAssignment.find(JSON.parse(response.body)["id"])
    assert_equal 28_800, ra.allocation
    assert_equal [1,2,3,4,5], ra.weekdays
    assert_equal Date.today, ra.starts_on
  end

  test "honors explicit hours/weekdays/dates" do
    post "/api/recurring_assignments", headers: auth, params: {
      forecast_person_id: 1, forecast_project_id: 2, allocation_hours: 4,
      weekdays: [1], starts_on: "2026-08-03", ends_on: "2026-08-31",
    }.to_json
    assert_response :success
    ra = RecurringAssignment.find(JSON.parse(response.body)["id"])
    assert_equal 14_400, ra.allocation
    assert_equal [1], ra.weekdays
  end
end
