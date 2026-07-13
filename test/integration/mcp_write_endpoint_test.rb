require 'test_helper'

class McpWriteEndpointTest < ActionDispatch::IntegrationTest
  WRITE_TOOLS = %w[archive_project create_assignment create_placeholder create_tentative_project delete_assignment].freeze

  MCP_HEADERS = {
    "Content-Type" => "application/json",
    "Accept" => "application/json"
  }.freeze

  def api_key_headers
    MCP_HEADERS.merge("X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key])
  end

  def tools_list(path)
    post path, headers: api_key_headers,
      params: { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json
    assert_response :success
    JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
  end

  def call_tool(name, arguments = {})
    post "/api/mcp/write", headers: api_key_headers,
      params: { jsonrpc: "2.0", id: 99, method: "tools/call",
                params: { name: name, arguments: arguments } }.to_json
    assert_response :success
    JSON.parse(JSON.parse(response.body).dig("result", "content", 0, "text"))
  end

  setup do
    Rails.cache.delete("mcp_write_count:#{Date.today.iso8601}")
  end

  # ----- auth -----

  test "POST /api/mcp/write without X-Api-Key returns 403" do
    post "/api/mcp/write", headers: MCP_HEADERS,
      params: { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json
    assert_response :forbidden
  end

  test "POST /api/mcp/write with wrong key returns 403" do
    post "/api/mcp/write", headers: MCP_HEADERS.merge("X-Api-Key" => "nope"),
      params: { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json
    assert_response :forbidden
  end

  # ----- surface isolation (the read-only invariant, pinned) -----

  test "write surface exposes exactly the five write tools" do
    assert_equal WRITE_TOOLS, tools_list("/api/mcp/write").sort
  end

  test "read surface exposes NONE of the write tools" do
    read_tools = tools_list("/api/mcp")
    assert_empty read_tools & WRITE_TOOLS,
      "read-only /api/mcp must never expose write tools; found: #{read_tools & WRITE_TOOLS}"
  end

  # ----- tool behavior -----

  test "create_assignment validates, applies, and returns segments" do
    segments = [{ "id" => 5001, "personId" => 10, "startDate" => "2026-07-14", "endDate" => "2026-09-30" }]
    Stacks::Runn.any_instance.expects(:create_assignment).once.returns(segments)

    payload = call_tool("create_assignment", { person_id: 10, project_id: 100, role_id: 7,
      start_date: "2026-07-14", end_date: "2026-09-30", minutes_per_day: 480 })

    assert_equal segments, payload["after"]
    assert_nil payload["before"]
  end

  test "create_assignment rejects out-of-range minutes without calling the provider" do
    Stacks::Runn.any_instance.expects(:create_assignment).never
    payload = call_tool("create_assignment", { person_id: 10, project_id: 100, role_id: 7,
      start_date: "2026-07-14", end_date: "2026-09-30", minutes_per_day: 2000 })
    assert_match(/minutes_per_day/, payload["error"])
  end

  test "create_assignment rejects inverted date ranges" do
    Stacks::Runn.any_instance.expects(:create_assignment).never
    payload = call_tool("create_assignment", { person_id: 10, project_id: 100, role_id: 7,
      start_date: "2026-09-30", end_date: "2026-07-14", minutes_per_day: 480 })
    assert_match(/start_date must be on or before end_date/, payload["error"])
  end

  test "delete_assignment deletes by id and echoes it" do
    Stacks::Runn.any_instance.expects(:delete_assignment).once.with(5001).returns({})
    payload = call_tool("delete_assignment", { assignment_id: 5001 })
    assert_equal 5001, payload["deleted_assignment_id"]
  end

  test "archive_project refuses a confirmed project without allow_confirmed" do
    RunnProject.create!(runn_id: 88_200, name: "Real Engagement", is_confirmed: true, data: {})
    Stacks::Runn.any_instance.expects(:update_project).never

    payload = call_tool("archive_project", { project_id: 88_200, is_archived: true })
    assert_match(/confirmed/, payload["error"])
  end

  test "archive_project archives a tentative shell and returns before/after" do
    RunnProject.create!(runn_id: 88_300, name: "Dead Deal [lead:abc]", is_confirmed: false, data: {})
    Stacks::Runn.any_instance.expects(:update_project).once.with(88_300, is_archived: true)
      .returns({ "id" => 88_300, "isArchived" => true })

    payload = call_tool("archive_project", { project_id: 88_300, is_archived: true })
    assert_equal false, payload.dig("before", "is_confirmed")
    assert_equal true, payload.dig("after", "isArchived")
  end

  test "create_tentative_project always creates unconfirmed" do
    Stacks::Runn.any_instance.expects(:create_project).once
      .with("Globex Redesign [lead:abc123]", 5, pricing_model: "tm", is_confirmed: false)
      .returns({ "id" => 99_100, "isConfirmed" => false })

    payload = call_tool("create_tentative_project", { name: "Globex Redesign [lead:abc123]", client_id: 5 })
    assert_equal false, payload.dig("after", "isConfirmed")
  end

  test "create_placeholder passes the role through" do
    Stacks::Runn.any_instance.expects(:create_placeholder).once.with(role_id: 7).returns({ "id" => 999_001 })
    payload = call_tool("create_placeholder", { role_id: 7 })
    assert_equal 999_001, payload.dig("after", "id")
  end

  # ----- circuit breaker -----

  test "daily cap refuses further mutations" do
    # the test env cache is a :null_store — use a real store so the counter counts
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    store.write("mcp_write_count:#{Date.today.iso8601}", Mcp::WriteGuard::DAILY_CAP)
    Stacks::Runn.any_instance.expects(:delete_assignment).never

    payload = call_tool("delete_assignment", { assignment_id: 1 })
    assert_match(/daily write cap/, payload["error"])
  end

  test "writes below the cap increment the counter" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    Stacks::Runn.any_instance.expects(:delete_assignment).once.returns({})

    call_tool("delete_assignment", { assignment_id: 1 })
    assert_equal 1, store.read("mcp_write_count:#{Date.today.iso8601}").to_i
  end
end
