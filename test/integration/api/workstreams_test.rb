require "test_helper"

class Api::WorkstreamsTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  def tracker
    ProjectTracker.provision!(name: "Q", msa_url: "https://e.com/m", sow_url: "https://e.com/s").first
  end

  test "403 without key" do
    post "/api/project_trackers/1/workstreams", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "create delegates to add_workstream! and returns a generic workstream" do
    t = tracker
    ws = t.project_tracker_forecast_projects.build # placeholder to stand in for return
    ForecastClient.new(forecast_id: 42, name: "Q").save!(validate: false)
    ForecastProject.new(forecast_id: 5001, client_id: 42, name: "Design", code: "Q-1", tags: ["450p/h"]).save!(validate: false)
    real_ws = t.project_tracker_forecast_projects.create!(forecast_project_id: 5001)
    ProjectTracker.any_instance.expects(:add_workstream!).returns(real_ws)

    post "/api/project_trackers/#{t.id}/workstreams", headers: auth,
      params: { name: "Design", code: "Q-1", rate: 450, client: "Q" }.to_json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal real_ws.id, body["id"]
    assert_equal [450.0], body["rates"]
    refute body.to_s.include?("forecast")
  end

  test "add_rate delegates to Stacks::Forecast#add_project_rate!" do
    t = tracker
    ForecastProject.new(forecast_id: 5002, client_id: 42, name: "P", code: "Q-2", tags: ["300p/h"]).save!(validate: false)
    ws = t.project_tracker_forecast_projects.create!(forecast_project_id: 5002)
    fake = mock("fc"); fake.expects(:add_project_rate!).with(5002, 450).returns(true)
    Stacks::Forecast.stubs(:new).returns(fake)

    post "/api/project_trackers/#{t.id}/workstreams/#{ws.id}/rates", params: { rate: 450 }.to_json, headers: auth
    assert_response :success
  end

  test "remove_rate handles decimals" do
    t = tracker
    ForecastProject.new(forecast_id: 5003, client_id: 42, name: "P", code: "Q-3", tags: ["99.75p/h"]).save!(validate: false)
    ws = t.project_tracker_forecast_projects.create!(forecast_project_id: 5003)
    fake = mock("fc"); fake.expects(:remove_project_rate!).with(5003, "99.75").returns(true)
    Stacks::Forecast.stubs(:new).returns(fake)

    delete "/api/project_trackers/#{t.id}/workstreams/#{ws.id}/rates", params: { rate: "99.75" }.to_json, headers: auth
    assert_response :success
  end
end
