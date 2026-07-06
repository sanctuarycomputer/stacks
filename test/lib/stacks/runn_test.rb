require "test_helper"

class Stacks::RunnTest < ActiveSupport::TestCase
  setup do
    @runn = Stacks::Runn.new
  end

  test "create_or_update_actuals_bulk no-ops on empty input" do
    Stacks::Runn.expects(:post).never
    @runn.create_or_update_actuals_bulk([])
  end

  test "create_or_update_actuals_bulk sends one POST when count <= 100" do
    actuals = 50.times.map do |i|
      { "date" => "2026-01-01", "billableMinutes" => 60, "personId" => i, "projectId" => 1, "roleId" => 2 }
    end

    response = mock("response")
    response.stubs(:success?).returns(true)
    posted_body = nil
    Stacks::Runn.expects(:post).once.with do |path, opts|
      posted_body = opts[:body]
      path == "/actuals/bulk"
    end.returns(response)

    @runn.create_or_update_actuals_bulk(actuals)

    parsed = JSON.parse(posted_body)
    assert_equal 50, parsed["actuals"].size
    assert parsed["actuals"].all? { |a| a["nonbillableMinutes"] == 0 }, "every item should have nonbillableMinutes = 0"
    assert_equal actuals.first["personId"], parsed["actuals"].first["personId"]
  end

  test "create_or_update_actuals_bulk chunks into 100-item batches" do
    actuals = 250.times.map do |i|
      { "date" => "2026-01-01", "billableMinutes" => 60, "personId" => i, "projectId" => 1, "roleId" => 2 }
    end
    response = mock("response")
    response.stubs(:success?).returns(true)
    Stacks::Runn.expects(:post).times(3).returns(response, response, response)

    @runn.create_or_update_actuals_bulk(actuals)
  end

  test "create_or_update_actuals_bulk normalizes symbol/string keys and defaults nonbillableMinutes" do
    actuals = [
      { date: "2026-01-01", billableMinutes: 30, personId: 1, projectId: 1, roleId: 2 },           # symbol keys
      { "date" => "2026-01-02", "billableMinutes" => 45, "personId" => 1, "projectId" => 1, "roleId" => 2 },  # string keys
    ]

    response = mock("response")
    response.stubs(:success?).returns(true)
    posted_body = nil
    Stacks::Runn.expects(:post).once.with do |_path, opts|
      posted_body = opts[:body]
      true
    end.returns(response)

    @runn.create_or_update_actuals_bulk(actuals)

    parsed = JSON.parse(posted_body)["actuals"]
    assert_equal "2026-01-01", parsed[0]["date"]
    assert_equal 30, parsed[0]["billableMinutes"]
    assert_equal 0, parsed[0]["nonbillableMinutes"]
    assert_equal "2026-01-02", parsed[1]["date"]
    assert_equal 45, parsed[1]["billableMinutes"]
    assert_equal 0, parsed[1]["nonbillableMinutes"]
  end

  # --------------------------------------------------------------------------
  # create_project
  # --------------------------------------------------------------------------

  test "create_project POSTs the expected body and returns the parsed response" do
    parsed = { "id" => 9_999_001, "name" => "New Tracker", "clientId" => 12345 }
    response = mock("response")
    response.stubs(:success?).returns(true)
    response.stubs(:parsed_response).returns(parsed)

    posted_body = nil
    Stacks::Runn.expects(:post).once.with do |path, opts|
      posted_body = opts[:body]
      path == "/projects/"
    end.returns(response)

    result = @runn.create_project("New Tracker", 12345)

    body = JSON.parse(posted_body)
    assert_equal "New Tracker", body["name"]
    assert_equal 12345,         body["clientId"]
    assert_equal "tm",          body["pricingModel"], "default pricing_model should be 'tm'"
    assert_equal false,         body["isConfirmed"]
    assert_equal false,         body["isTemplate"]
    assert_equal parsed, result
  end

  test "create_project respects pricing_model and is_confirmed overrides" do
    response = mock("response")
    response.stubs(:success?).returns(true)
    response.stubs(:parsed_response).returns({})
    posted_body = nil
    Stacks::Runn.expects(:post).once.with do |_path, opts|
      posted_body = opts[:body]
      true
    end.returns(response)

    @runn.create_project("X", 1, pricing_model: "nb", is_confirmed: true)
    body = JSON.parse(posted_body)
    assert_equal "nb", body["pricingModel"]
    assert_equal true, body["isConfirmed"]
  end
end
