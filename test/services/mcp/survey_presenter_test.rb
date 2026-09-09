require "test_helper"

class McpSurveyPresenterTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include SurveyFixtures

  setup { travel_to Time.zone.parse(SurveyFixtures::FROZEN_NOW) }
  teardown { travel_back }

  # ----- find + summary -----

  test "find returns a studio presenter with a closed summary" do
    survey = build_studio_survey!(answers: [{ sentiment: :agree }, { sentiment: :strongly_agree }])
    p = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id)

    s = p.summary
    assert_equal "studio", s[:kind]
    assert_equal survey.id, s[:id]
    assert_equal "Alpha Pulse", s[:title]
    assert_equal "closed", s[:status]
    assert_equal "2026-06-01", s[:opened_at]
    assert_equal Time.zone.parse(SurveyFixtures::CLOSED_AT).iso8601, s[:closed_at]
    assert_equal({ studios: [{ name: "Alpha", mini_name: "alpha" }] }, s[:scope])
    assert_equal 2, s[:response_count]
    assert_in_delta 4.38, s[:overall_score], 0.01 # mean of (3.75, 5) for the single question
    assert_equal "https://stacks.garden3d.net/admin/surveys/#{survey.id}", s[:url]
  end

  test "find returns a project presenter with tracker scope and persisted score" do
    survey = build_project_survey!(answers: [{ sentiment: :neutral }])
    p = Mcp::SurveyPresenter.find(kind: "project", id: survey.id)

    s = p.summary
    assert_equal "project", s[:kind]
    assert_equal "closed", s[:status]
    assert_equal survey.created_at.to_date.iso8601, s[:opened_at]
    tracker = survey.project_capsule.project_tracker
    assert_equal({ project_tracker_id: tracker.id, project: tracker.name }, s[:scope])
    assert_equal 1, s[:response_count]
    assert_in_delta 2.5, s[:overall_score], 0.01
    assert_equal "https://stacks.garden3d.net/admin/project_satisfaction_surveys/#{survey.id}", s[:url]
  end

  test "open surveys summarize with status open and nil overall_score" do
    survey = build_studio_survey!(closed: false, answers: [{ sentiment: :agree }])
    s = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).summary
    assert_equal "open", s[:status]
    assert_nil s[:closed_at]
    assert_nil s[:overall_score]
  end

  test "find returns nil for a draft studio survey, an unknown id, or the wrong kind" do
    draft = Survey.create!(title: "Draft", description: "d", opens_at: Date.new(2026, 9, 1))
    project = build_project_survey!
    assert_nil Mcp::SurveyPresenter.find(kind: "studio", id: draft.id)
    assert_nil Mcp::SurveyPresenter.find(kind: "studio", id: 999_999)
    assert_nil Mcp::SurveyPresenter.find(kind: "studio", id: project.id)
    assert_nil Mcp::SurveyPresenter.find(kind: "bogus", id: project.id)
  end
end
