require 'test_helper'

# Scoped tokens on the MCP and API surfaces (roadmap Phase 7). The read MCP needs mcp:read; the write MCP shows
# and runs only the tools a token's scopes allow; the legacy shared key keeps read, and keeps write only while
# STACKS_LEGACY_KEY_WRITE is not "off".
class ApiTokenAuthTest < ActionDispatch::IntegrationTest
  HEADERS = { "Content-Type" => "application/json", "Accept" => "application/json" }.freeze
  LIST = { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json

  def with_key(key)
    HEADERS.merge("X-Api-Key" => key)
  end

  def tool_names(path, key)
    post path, headers: with_key(key), params: LIST
    assert_response :success
    JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
  end

  def legacy_key
    Stacks::Utils.config[:stacks][:private_api_key]
  end

  setup do
    Rails.cache.delete("mcp_write_count:#{Time.zone.today.iso8601}")
  end

  test "a read token reads, and cannot reach the write surface at all" do
    _, raw = ApiToken.mint!(name: "reader", scopes: ["mcp:read"])
    assert tool_names("/api/mcp", raw).any?
    post "/api/mcp/write", headers: with_key(raw), params: LIST
    assert_response :forbidden
  end

  test "a write token for trackers sees and can call only tracker tools" do
    _, raw = ApiToken.mint!(name: "trackers", scopes: ["mcp:write:trackers"])
    names = tool_names("/api/mcp/write", raw)
    assert_equal Mcp::WriteServer::TOOL_SCOPES.select { |_, s| s == "mcp:write:trackers" }.keys.sort, names.sort
    refute_includes names, "create_assignment"
    post "/api/mcp/write", headers: with_key(raw),
      params: { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "create_assignment", arguments: {} } }.to_json
    body = JSON.parse(response.body)
    assert body["error"] || body.dig("result", "isError"), "calling a tool outside the token's scopes must fail: #{body}"
    # A write-only token has no read access.
    post "/api/mcp", headers: with_key(raw), params: LIST
    assert_response :forbidden
  end

  test "every write tool maps to exactly one known scope" do
    assert_equal Mcp::WriteServer::TOOLS.map(&:name_value).sort, Mcp::WriteServer::TOOL_SCOPES.keys.sort
    assert (Mcp::WriteServer::TOOL_SCOPES.values - ApiToken::SCOPES.keys).empty?
  end

  test "a revoked token stops working on the very next request" do
    record, raw = ApiToken.mint!(name: "w", scopes: ["mcp:write:resourcing"])
    post "/api/mcp/write", headers: with_key(raw), params: LIST
    assert_response :success
    record.revoke!
    post "/api/mcp/write", headers: with_key(raw), params: LIST
    assert_response :forbidden
  end

  test "legacy key: read always; write only until the deprecation switch is off" do
    assert tool_names("/api/mcp", legacy_key).any?
    assert_equal Mcp::WriteServer::TOOLS.size, tool_names("/api/mcp/write", legacy_key).size
    ENV["STACKS_LEGACY_KEY_WRITE"] = "off"
    begin
      assert tool_names("/api/mcp", legacy_key).any?
      post "/api/mcp/write", headers: with_key(legacy_key), params: LIST
      assert_response :forbidden
    ensure
      ENV.delete("STACKS_LEGACY_KEY_WRITE")
    end
  end

  test "the REST write endpoints follow the same scopes and the same deprecation switch" do
    writes = [["/api/project_trackers", "mcp:write:trackers"], ["/api/project_trackers/1/workstreams", "mcp:write:trackers"],
              ["/api/recurring_assignments", "mcp:write:resourcing"]]
    _, reader = ApiToken.mint!(name: "reader", scopes: ["mcp:read"])
    writes.each do |path, scope|
      post path, headers: with_key(reader), params: {}.to_json
      assert_response :forbidden, "#{path} with a read token"
      _, writer = ApiToken.mint!(name: scope, scopes: [scope])
      post path, headers: with_key(writer), params: {}.to_json
      refute_equal 403, response.status, "#{path} with #{scope}"
    end
    ENV["STACKS_LEGACY_KEY_WRITE"] = "off"
    begin
      writes.each do |path, _|
        post path, headers: with_key(legacy_key), params: {}.to_json
        assert_response :forbidden, "#{path} with the legacy key after the switch"
      end
      get "/api/project_trackers", headers: with_key(legacy_key)
      assert_response :success
    ensure
      ENV.delete("STACKS_LEGACY_KEY_WRITE")
    end
  end

  test "projected assignments API needs api:write:projections" do
    _, reader = ApiToken.mint!(name: "reader", scopes: ["mcp:read"])
    post "/api/v1/projected_assignments/batch", headers: with_key(reader), params: { assignments: [] }.to_json
    assert_response :forbidden
    _, writer = ApiToken.mint!(name: "proj", scopes: ["api:write:projections"])
    post "/api/v1/projected_assignments/batch", headers: with_key(writer), params: { assignments: [] }.to_json
    refute_equal 403, response.status
  end

  test "with the table missing (before the migration) the legacy key still works and tokens are refused" do
    ApiToken.stub(:available?, false) do
      assert tool_names("/api/mcp", legacy_key).any?
      post "/api/mcp", headers: with_key("stk_anything"), params: LIST
      assert_response :forbidden
    end
  end

  test "the key never reaches Sentry: the headers it would report don't carry it" do
    _, raw = ApiToken.mint!(name: "reader", scopes: ["mcp:read"])
    post "/api/mcp", headers: with_key(raw), params: LIST
    assert_response :success
    env = request.env
    refute env.key?("HTTP_X_API_KEY")
    reported = Sentry::RequestInterface.build(env: env).headers
    refute reported.values.any? { |v| v.include?(raw) }, "Sentry would report the token"
    refute reported.key?("X-Api-Key")
  end
end
