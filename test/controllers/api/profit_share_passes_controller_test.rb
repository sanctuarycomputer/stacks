require 'test_helper'

class Api::ProfitSharePassesControllerTest < ActionDispatch::IntegrationTest
  test "for each pass, appends total_psu_issued for that year to the response" do
    pass = ProfitSharePass.create!
    Studio.create!({
      name: "garden3d",
      mini_name: "g3d"
    })
    get "/api/profit_share_passes"

    assert_response :success
    expected = [{ id: pass.id, snapshot: pass.snapshot, total_psu_issued: pass.total_psu_issued.round }].to_json
    assert_equal(expected, @response.body)
  end

  test "returns empty list when no passes exist" do
    Studio.create!({
      name: "garden3d",
      mini_name: "g3d"
    })
    get "/api/profit_share_passes"

    assert_response :success
    assert_equal([].to_json, @response.body)
  end
end