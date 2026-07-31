require "test_helper"

class Api::ResolversTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }; end

  test "forecast_clients index matches by name case-insensitively" do
    ForecastClient.new(forecast_id: 42, name: "Qualitate").save!(validate: false)
    get "/api/forecast_clients", params: { name: "qualitate" }, headers: auth
    assert_response :success
    assert_equal 42, JSON.parse(response.body).first["forecast_id"]
  end

  test "client projects lists rates parsed from tags" do
    ForecastClient.new(forecast_id: 43, name: "Acme").save!(validate: false)
    ForecastProject.new(forecast_id: 5001, client_id: 43, name: "P", code: "A-1", tags: ["450p/h","300p/h"]).save!(validate: false)
    get "/api/forecast_clients/43/forecast_projects", headers: auth
    assert_response :success
    row = JSON.parse(response.body).first
    assert_equal [450.0, 300.0], row["rates"]
  end

  test "forecast_people index matches by email" do
    # insert! (not save!) — ForecastPerson#after_create builds a Contributor + ledgers cascade.
    ForecastPerson.insert!({ forecast_id: 324711, email: "hugh@sanctuary.computer" })
    get "/api/forecast_people", params: { email: "hugh@sanctuary.computer" }, headers: auth
    assert_response :success
    assert_equal 324711, JSON.parse(response.body).first["forecast_id"]
  end
end
