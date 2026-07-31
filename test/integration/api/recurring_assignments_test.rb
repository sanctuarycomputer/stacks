require "test_helper"

class Api::RecurringAssignmentsTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  def setup_contributor_and_workstream
    ForecastPerson.insert!({ forecast_id: 324711, email: "hugh@sanctuary.computer", updated_at: Time.current })
    Contributor.insert!({ forecast_person_id: 324711, created_at: Time.current, updated_at: Time.current })
    c = Contributor.find_by(forecast_person_id: 324711)
    ForecastProject.new(forecast_id: 5001, client_id: 42, name: "P", code: "Q-1").save!(validate: false)
    t = ProjectTracker.provision!(name: "Q", msa_url: "https://e.com/m", sow_url: "https://e.com/s").first
    ws = t.project_tracker_forecast_projects.create!(forecast_project_id: 5001)
    [c, ws]
  end

  test "403 without key" do
    post "/api/recurring_assignments", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "creates from contributor_id + workstream_id, translating to forecast ids, defaults applied" do
    c, ws = setup_contributor_and_workstream
    post "/api/recurring_assignments", headers: auth, params: { contributor_id: c.id, workstream_id: ws.id }.to_json
    assert_response :success
    body = JSON.parse(response.body)
    ra = RecurringAssignment.find(body["id"])
    assert_equal 324711, ra.forecast_person_id
    assert_equal 5001, ra.forecast_project_id
    assert_equal 28_800, ra.allocation
    assert_equal [1,2,3,4,5], ra.weekdays
    assert_equal Date.today, ra.starts_on
    # response is generic — no forecast ids
    assert_equal c.id, body["contributor_id"]
    assert_equal ws.id, body["workstream_id"]
    refute body.to_s.include?("forecast")
  end

  test "honors explicit hours/weekdays" do
    c, ws = setup_contributor_and_workstream
    post "/api/recurring_assignments", headers: auth,
      params: { contributor_id: c.id, workstream_id: ws.id, allocation_hours: 4, weekdays: [1] }.to_json
    ra = RecurringAssignment.find(JSON.parse(response.body)["id"])
    assert_equal 14_400, ra.allocation
    assert_equal [1], ra.weekdays
  end
end
