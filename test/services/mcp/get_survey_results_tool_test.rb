require "test_helper"

class McpGetSurveyResultsToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include SurveyFixtures

  setup { travel_to Time.zone.parse(SurveyFixtures::FROZEN_NOW) }
  teardown { travel_back }

  test "returns anonymous aggregate results with free text for a closed survey" do
    survey = build_project_survey!(answers: [
      { sentiment: :agree, context: "budget was tight", free_text: "more discovery" },
      { sentiment: :neutral, context: "ok", free_text: "less scope creep" },
      { sentiment: :agree, context: nil, free_text: "keep the rituals" },
    ])
    payload = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "project", id: survey.id, server_context: {}))

    assert_equal "closed", payload["status"]
    assert_equal 3, payload["response_count"]
    assert_equal ["budget was tight", "ok"], payload["questions"].first["contexts"]
    assert_equal ["keep the rituals", "less scope creep", "more discovery"], payload["free_text_questions"].first["responses"]
    assert_equal true, payload["small_sample"]
  end

  test "withholds results for an open survey" do
    survey = build_studio_survey!(closed: false, answers: [{ sentiment: :agree, free_text: "hidden" }])
    payload = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "studio", id: survey.id, server_context: {}))
    assert_equal "survey is open", payload["results_withheld"]
    refute_includes payload.to_json, "hidden"
  end

  test "errors for unknown kind, missing id, and an id of the other kind" do
    project = build_project_survey!
    err = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "client", id: project.id, server_context: {}))
    assert_equal "Unknown kind 'client'. Valid kinds: studio, project", err["error"]
    err = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "project", id: 999_999, server_context: {}))
    assert_equal "Survey not found", err["error"]
    err = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "studio", id: project.id, server_context: {}))
    assert_equal "Survey not found", err["error"]
  end
end
