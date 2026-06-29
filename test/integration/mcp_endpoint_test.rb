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
    assert_equal %w[get_document list_documents list_sources search], tool_names.sort,
      "Expected all four tools registered, got: #{tool_names.inspect}"
  end
end
