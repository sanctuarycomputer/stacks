require "test_helper"

class Api::ForecastProjectsTest < ActionDispatch::IntegrationTest
  def key; Stacks::Utils.config[:stacks][:private_api_key]; end
  def auth; { "X-Api-Key" => key, "Content-Type" => "application/json" }; end

  test "403 without a valid key" do
    post "/api/forecast_projects", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "create delegates to Stacks::Forecast#create_project and returns the project" do
    fake = mock("forecast")
    fake.expects(:create_project).with(client_id: 42, name: "Q", code: "QUAL-1", tags: ["450p/h"], notes: "").returns({ "id" => 777, "tags" => ["450p/h"] })
    Stacks::Forecast.stubs(:new).returns(fake)

    post "/api/forecast_projects",
      params: { client_id: 42, name: "Q", code: "QUAL-1", rates: [450] }.to_json, headers: auth
    assert_response :success
    assert_equal 777, JSON.parse(response.body)["forecast_id"]
  end

  test "add_rate delegates to add_project_rate!" do
    fake = mock("forecast"); fake.expects(:add_project_rate!).with(777, 450).returns({ "id" => 777, "tags" => ["450p/h"] })
    Stacks::Forecast.stubs(:new).returns(fake)
    post "/api/forecast_projects/777/rates", params: { rate: 450 }.to_json, headers: auth
    assert_response :success
  end

  test "remove_rate delegates to remove_project_rate!" do
    fake = mock("forecast"); fake.expects(:remove_project_rate!).with(777, "450").returns({ "id" => 777, "tags" => [] })
    Stacks::Forecast.stubs(:new).returns(fake)
    delete "/api/forecast_projects/777/rates", params: { rate: "450" }.to_json, headers: auth
    assert_response :success
  end

  test "remove_rate handles decimal rates (no format truncation)" do
    fake = mock("forecast"); fake.expects(:remove_project_rate!).with(777, "99.75").returns({ "id" => 777, "tags" => [] })
    Stacks::Forecast.stubs(:new).returns(fake)
    delete "/api/forecast_projects/777/rates", params: { rate: "99.75" }.to_json, headers: auth
    assert_response :success
  end
end
