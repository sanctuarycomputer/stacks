require 'test_helper'

class McpEndpointTest < ActionDispatch::IntegrationTest
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
    assert_equal %w[get_ar_aging get_document get_pnl get_studio_health list_documents list_open_admin_tasks list_overdue_invoices list_projects_at_risk list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
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

  test "tools/call round-trip for get_pnl returns a payload or a clear error" do
    payload = call_tool("get_pnl")
    # Empty test DB may have no synced reports — either a P&L payload or the
    # descriptive no-reports error is valid; both prove dispatch + envelope.
    assert(payload.key?("revenue") || payload.key?("error"))
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
