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
    assert_equal %w[get_ar_aging get_document list_documents list_overdue_invoices list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
  end

  test "POST tools/call for get_ar_aging returns a parseable report" do
    post "/api/mcp",
      headers: api_key_headers,
      params: {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "get_ar_aging", arguments: {} }
      }.to_json

    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("result"), "Expected JSON-RPC result key, got: #{body.inspect}"
    text = body["result"]["content"][0]["text"]
    payload = JSON.parse(text)
    assert payload.key?("as_of"), "Expected 'as_of' key in payload, got: #{payload.inspect}"
    assert_equal 0, payload["total_ar"]
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
