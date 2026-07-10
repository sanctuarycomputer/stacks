require 'test_helper'

class McpEndpointTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  TOOLS_LIST_REQUEST = {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/list",
    params: {}
  }.freeze

  MCP_HEADERS = {
    "Content-Type" => "application/json",
    "Accept" => "application/json"
  }.freeze

  def api_key_headers
    MCP_HEADERS.merge("X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key])
  end

  # POSTs a JSON-RPC tools/call and returns the parsed tool payload.
  def call_tool(name, arguments = {})
    post "/api/mcp",
      headers: api_key_headers,
      params: { jsonrpc: "2.0", id: 99, method: "tools/call",
                params: { name: name, arguments: arguments } }.to_json
    assert_response :success
    JSON.parse(JSON.parse(response.body).dig("result", "content", 0, "text"))
  end

  # ----- auth -----

  test "POST without X-Api-Key returns 403 forbidden" do
    post "/api/mcp",
      headers: MCP_HEADERS,
      params: TOOLS_LIST_REQUEST.to_json
    assert_response :forbidden
  end

  test "POST with wrong X-Api-Key returns 403 forbidden" do
    post "/api/mcp",
      headers: MCP_HEADERS.merge("X-Api-Key" => "wrong-key"),
      params: TOOLS_LIST_REQUEST.to_json
    assert_response :forbidden
  end

  # ----- happy path -----

  test "POST tools/list with valid key returns search tool" do
    post "/api/mcp",
      headers: api_key_headers,
      params: TOOLS_LIST_REQUEST.to_json

    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("result"), "Expected JSON-RPC result key, got: #{body.inspect}"
    tool_names = body["result"]["tools"].map { |t| t["name"] }
    assert_includes tool_names, "search", "Expected 'search' tool in: #{tool_names.inspect}"
    assert_equal %w[get_ar_aging get_document get_runn_projections get_studio_health list_documents list_open_admin_tasks list_overdue_invoices list_projects_at_risk list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
  end

  test "tools/call round-trip for get_runn_projections window-filters and joins trackers" do
    travel_to Time.zone.parse("2026-07-15 12:00:00") # midnight-proof: tool + test must agree on "today"
    today = Time.zone.today
    Stacks::Runn.any_instance.stubs(:get_projects).returns([
      { "id" => 91_100, "name" => "Mapped Project", "isConfirmed" => true, "isArchived" => false, "isTemplate" => false, "clientId" => 5, "budget" => 100_000, "pricingModel" => "tm" },
      { "id" => 91_200, "name" => "Tentative Deal", "isConfirmed" => false, "isArchived" => false, "isTemplate" => false, "clientId" => 6, "budget" => nil, "pricingModel" => "tm" },
      { "id" => 91_300, "name" => "Old Archived", "isConfirmed" => true, "isArchived" => true, "isTemplate" => false, "clientId" => 7, "budget" => nil, "pricingModel" => "tm" },
    ])
    Stacks::Runn.any_instance.stubs(:get_people).returns([
      { "id" => 10, "firstName" => "Ada", "lastName" => "Lovelace", "email" => "ada@example.com", "isArchived" => false },
      { "id" => 11, "firstName" => "Old", "lastName" => "Timer", "email" => "old@example.com", "isArchived" => true },
    ])
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([
      { "id" => 1, "personId" => 10, "projectId" => 91_100, "roleId" => 7, "startDate" => (today - 5).iso8601, "endDate" => (today + 10).iso8601, "minutesPerDay" => 480, "isPlaceholder" => false, "isActive" => true, "isTemplate" => false, "note" => "" },
      { "id" => 2, "personId" => 10, "projectId" => 91_100, "roleId" => 7, "startDate" => (today - 90).iso8601, "endDate" => (today - 30).iso8601, "minutesPerDay" => 480, "isPlaceholder" => false, "isActive" => true, "isTemplate" => false, "note" => "" },
      { "id" => 3, "personId" => 10, "projectId" => 91_300, "roleId" => 7, "startDate" => today.iso8601, "endDate" => (today + 5).iso8601, "minutesPerDay" => 240, "isPlaceholder" => true, "isActive" => true, "isTemplate" => false, "note" => "" },
      # boundary pins: ends exactly today (in), starts exactly at the horizon (in), nil start (dropped)
      { "id" => 4, "personId" => 10, "projectId" => 91_100, "roleId" => 7, "startDate" => (today - 10).iso8601, "endDate" => today.iso8601, "minutesPerDay" => 240, "isPlaceholder" => false, "isActive" => true, "isTemplate" => false, "note" => "" },
      { "id" => 5, "personId" => 10, "projectId" => 91_100, "roleId" => 7, "startDate" => (today + 90).iso8601, "endDate" => (today + 120).iso8601, "minutesPerDay" => 240, "isPlaceholder" => false, "isActive" => true, "isTemplate" => false, "note" => "" },
      { "id" => 6, "personId" => 10, "projectId" => 91_100, "roleId" => 7, "startDate" => nil, "endDate" => (today + 10).iso8601, "minutesPerDay" => 240, "isPlaceholder" => false, "isActive" => true, "isTemplate" => false, "note" => "" },
    ])

    RunnProject.create!(runn_id: 91_100, name: "Mapped Project", data: {})
    tracker = ProjectTracker.new(
      name: "Mapped Tracker",
      runn_project_id: 91_100,
      snapshot: { "first_forecast_assignment_start_date" => (today - 30).iso8601,
                  "last_forecast_assignment_end_date" => (today + 20).iso8601,
                  "hours_total" => 400.0, "hours_free" => 12.5 }
    )
    assert tracker.save(validate: false), "test tracker should persist"

    payload = call_tool("get_runn_projections")

    assert_equal 2, payload["projects"].size, "archived project should be excluded by default"
    mapped = payload["projects"].find { |p| p["runn_id"] == 91_100 }
    tentative = payload["projects"].find { |p| p["runn_id"] == 91_200 }
    assert_equal true, mapped["is_confirmed"]
    assert_equal "Mapped Tracker", mapped.dig("project_tracker", "name")
    assert_equal (today + 20).iso8601, mapped.dig("project_tracker", "snapshot_end_date")
    assert_equal false, tentative["is_confirmed"]
    assert_nil tentative["project_tracker"]

    assert_equal [1, 4, 5], payload["assignments"].map { |a| a["id"] }.sort,
      "past (2), archived-project (3) and nil-date (6) drop; today-boundary (4) and horizon-boundary (5) stay"
    assert_equal 480, payload["assignments"].first["minutes_per_day"]
    assert_equal true, payload["assignments"].first.key?("is_placeholder")
    assert_equal ["Ada Lovelace"], payload["people"].map { |p| p["name"] },
      "archived people must be excluded by default"
    assert payload["people"].none? { |p| p.key?("email") }, "emails must not appear on this surface"
    assert_equal today.iso8601, payload["as_of"]
    assert_equal (today + 90).iso8601, payload.dig("window", "end")
  end

  test "get_runn_projections clamps a hostile window_days" do
    Stacks::Runn.any_instance.stubs(:get_projects).returns([])
    Stacks::Runn.any_instance.stubs(:get_people).returns([])
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([])

    payload = call_tool("get_runn_projections", { window_days: 100_000 })
    assert_equal (Time.zone.today + 365).iso8601, payload.dig("window", "end"), "window must clamp to 365 days"

    payload = call_tool("get_runn_projections", { window_days: -5 })
    assert_equal (Time.zone.today + 1).iso8601, payload.dig("window", "end"), "window must clamp up to 1 day"
  end

  test "POST tools/call for get_ar_aging returns a parseable report" do
    payload = call_tool("get_ar_aging")
    assert payload.key?("total_ar"), "Expected 'total_ar' key in payload, got: #{payload.inspect}"
    assert payload.key?("enterprises"), "Expected 'enterprises' key in payload, got: #{payload.inspect}"
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, payload["as_of"])
  end

  test "tools/call round-trip for list_open_admin_tasks returns a valid payload" do
    Stacks::TaskBuilder.any_instance.stubs(:tasks).returns([])
    payload = call_tool("list_open_admin_tasks")
    assert_equal 0, payload["count"]
    assert_equal [], payload["tasks"]
  end

  test "tools/call round-trip for list_projects_at_risk returns a valid payload" do
    payload = call_tool("list_projects_at_risk")
    assert payload.key?("count")
    assert payload.key?("projects")
  end

  test "tools/call round-trip for get_studio_health returns a valid payload" do
    payload = call_tool("get_studio_health", { gradation: "month" })
    assert payload.key?("studios")
  end

  test "POST returns 403 when MCP API key is not configured" do
    Stacks::Utils.stub(:config, { stacks: { private_api_key: '' } }) do
      post "/api/mcp",
        headers: MCP_HEADERS.merge("X-Api-Key" => "any-key"),
        params: TOOLS_LIST_REQUEST.to_json
      assert_response :forbidden
    end
  end
end
