require "test_helper"

class Api::ProjectTrackersTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  test "403 without key" do
    post "/api/project_trackers", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "create makes a bare tracker with placeholder links + warnings, no forecast leakage" do
    post "/api/project_trackers", headers: auth, params: { name: "Qualitate" }.to_json
    assert_response :success
    body = JSON.parse(response.body)
    assert ProjectTracker.find(body["id"]).persisted?
    assert body["warnings"].any?
    refute body.to_s.include?("forecast")
  end

  test "index by client lists trackers with nested workstreams + rates" do
    ForecastClient.new(forecast_id: 42, name: "Qualitate").save!(validate: false)
    ForecastProject.new(forecast_id: 5001, client_id: 42, name: "P", code: "Q-1", tags: ["450p/h"]).save!(validate: false)
    t = ProjectTracker.provision!(name: "Qualitate", msa_url: "https://e.com/m", sow_url: "https://e.com/s").first
    t.project_tracker_forecast_projects.create!(forecast_project_id: 5001)
    get "/api/project_trackers", params: { client: "Qualitate" }, headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }
    assert_response :success
    row = JSON.parse(response.body).find { |r| r["id"] == t.id }
    assert_equal "Qualitate", row["client"]
    assert_equal [450.0], row["workstreams"].first["rates"]
  end
end
