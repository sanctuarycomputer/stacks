require "test_helper"

class McpListSurveysToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include SurveyFixtures

  setup { travel_to Time.zone.parse(SurveyFixtures::FROZEN_NOW) }
  teardown { travel_back }

  test "returns an array of survey summaries" do
    build_project_survey!(title: "P", answers: [{ sentiment: :agree }])
    payload = mcp_payload(Mcp::ListSurveysTool.call(server_context: {}))
    assert_kind_of Array, payload
    assert_equal "P", payload.first["title"]
    assert_equal "project", payload.first["kind"]
    assert_equal 1, payload.first["response_count"]
  end

  test "rejects unknown kind and status with the valid values" do
    err = mcp_payload(Mcp::ListSurveysTool.call(kind: "client", server_context: {}))
    assert_equal "Unknown kind 'client'. Valid kinds: studio, project", err["error"]
    err = mcp_payload(Mcp::ListSurveysTool.call(status: "draft", server_context: {}))
    assert_equal "Unknown status 'draft'. Valid statuses: open, closed", err["error"]
  end

  test "closed_after alone implies closed; combined with status open it errors" do
    build_studio_survey!(title: "Closed", answers: [])
    build_studio_survey!(title: "Open", closed: false, opens_at: Date.new(2026, 7, 15))

    payload = mcp_payload(Mcp::ListSurveysTool.call(closed_after: "2026-06-01", server_context: {}))
    assert_equal ["Closed"], payload.map { |r| r["title"] }

    err = mcp_payload(Mcp::ListSurveysTool.call(closed_after: "2026-06-01", status: "open", server_context: {}))
    assert_equal "closed_after/closed_before cannot be combined with status 'open'", err["error"]
  end

  test "clamps limit and offset" do
    3.times { |i| build_project_survey!(title: "P#{i}") }
    assert_equal 1, mcp_payload(Mcp::ListSurveysTool.call(limit: 0, server_context: {})).size
    assert_equal 3, mcp_payload(Mcp::ListSurveysTool.call(limit: 999, server_context: {})).size
    assert_equal 3, mcp_payload(Mcp::ListSurveysTool.call(offset: -5, server_context: {})).size
    assert_equal 200, Mcp::ListSurveysTool::MAX_LIMIT
    assert_equal 1, Mcp::ListSurveysTool::MIN_LIMIT
  end

  test "declares itself read-only" do
    assert_equal "list_surveys", Mcp::ListSurveysTool.tool_name
    assert Mcp::ListSurveysTool.annotations.read_only_hint
  end
end
