require 'test_helper'

class Api::ProfitSharePassesControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get "/api/profit_share_passes"
    assert_response :success
    assert_equal({data: 'Hello World!'}.to_json, @response.body)
  end
end
