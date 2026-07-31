require "test_helper"

class Api::ProjectTrackersTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  test "403 without key" do
    post "/api/project_trackers", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "creates a tracker with links + attached projects" do
    ForecastProject.new(forecast_id: 2001, code: "QUAL-1", name: "P", client_id: 1).save!(validate: false)
    post "/api/project_trackers", headers: auth, params: {
      name: "Qualitate Retainer", forecast_project_ids: [2001],
      msa_url: "https://e.com/m", sow_url: "https://e.com/s",
    }.to_json
    assert_response :success
    body = JSON.parse(response.body)
    pt = ProjectTracker.find(body["id"])
    assert_equal [2001], pt.forecast_projects.map(&:forecast_id)
    assert_empty body["warnings"]
  end

  test "returns a warning when links are omitted" do
    ForecastProject.new(forecast_id: 2002, code: "QUAL-2", name: "P", client_id: 1).save!(validate: false)
    post "/api/project_trackers", headers: auth, params: { name: "T", forecast_project_ids: [2002] }.to_json
    assert_response :success
    assert JSON.parse(response.body)["warnings"].any?
  end
end
