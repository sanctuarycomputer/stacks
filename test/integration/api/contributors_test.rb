require "test_helper"

class Api::ContributorsTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }; end

  test "403 without key" do
    get "/api/contributors", params: { email: "x@y.z" }
    assert_response :forbidden
  end

  test "resolves a contributor by email (native id, no forecast leakage)" do
    ForecastPerson.insert!({ forecast_id: 324711, email: "hugh@sanctuary.computer" })
    Contributor.insert!({ forecast_person_id: 324711, created_at: Time.current, updated_at: Time.current })
    get "/api/contributors", params: { email: "hugh@sanctuary.computer" }, headers: auth
    assert_response :success
    row = JSON.parse(response.body).first
    assert_equal Contributor.find_by(forecast_person_id: 324711).id, row["id"]
    assert_equal "hugh@sanctuary.computer", row["email"]
    refute row.key?("forecast_id")
    refute row.key?("forecast_person_id")
  end
end
