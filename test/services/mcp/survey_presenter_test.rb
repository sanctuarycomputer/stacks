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

  # ----- results -----

  test "closed studio results carry averages, distributions, sorted contexts and free text" do
    survey = build_studio_survey!(answers: [
      { sentiment: :agree, context: "zebra context", free_text: "zebra answer" },
      { sentiment: :strongly_agree, context: "apple context", free_text: "apple answer" },
      { sentiment: :disagree, context: nil, free_text: "" },
    ])
    r = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results

    assert_equal "How is it going?", r[:description]
    assert_equal true, r[:small_sample] # 3 responses < 5
    assert_nil r[:free_text_withheld]
    q = r[:questions].first
    assert_equal "I feel supported", q[:prompt]
    assert_in_delta 3.33, q[:average], 0.01 # (3.75 + 5 + 1.25) / 3
    assert_equal 3, q[:response_count]
    assert_equal({ strongly_disagree: 0, disagree: 1, neutral: 0, agree: 1, strongly_agree: 1 }, q[:distribution])
    assert_equal ["apple context", "zebra context"], q[:contexts]
    ft = r[:free_text_questions].first
    assert_equal "What should we stop doing?", ft[:prompt]
    assert_equal ["apple answer", "zebra answer"], ft[:responses]
    assert_in_delta 3.33, r[:overall_score], 0.01
  end

  test "closed project results use the persisted score and report a float response rate" do
    survey = build_project_survey!(answers: [{ sentiment: :agree }, { sentiment: :agree }, { sentiment: :neutral }])
    lead = build_admin!(email_prefix: "lead")
    other = build_admin!(email_prefix: "other")
    tracker = survey.project_capsule.project_tracker
    AccountLeadPeriod.create!(project_tracker: tracker, admin_user: lead, started_at: Date.new(2026, 1, 1))
    ProjectLeadPeriod.create!(project_tracker: tracker, admin_user: other, started_at: Date.new(2026, 1, 1))
    ProjectLeadPeriod.create!(project_tracker: tracker, admin_user: build_admin!(email_prefix: "third"), started_at: Date.new(2026, 1, 1))
    ProjectLeadPeriod.create!(project_tracker: tracker, admin_user: build_admin!(email_prefix: "fourth"), started_at: Date.new(2026, 1, 1))

    r = nil
    statements = sql_statements { r = Mcp::SurveyPresenter.find(kind: "project", id: survey.id).results }
    assert_empty statements.grep(/survey_responders/), "responder tables must never be queried"

    assert_equal 4, r[:expected_response_count]
    assert_in_delta 0.75, r[:response_rate], 0.001
    assert_in_delta survey.reload.score.to_f, r[:overall_score], 0.01
    assert_equal true, r[:small_sample]
  end

  test "response_rate is nil when nobody is expected" do
    survey = build_project_survey!(answers: [{ sentiment: :agree }])
    r = Mcp::SurveyPresenter.find(kind: "project", id: survey.id).results
    assert_equal 0, r[:expected_response_count]
    assert_nil r[:response_rate]
  end

  test "studio expected_response_count counts core members and never queries responders" do
    survey = build_studio_survey!(answers: [{ sentiment: :agree }], studio_name: "Beta")
    studio = Studio.find_by!(name: "Beta")
    make_admin_user!(studio, Date.new(2026, 1, 1), nil, "core-beta@sanctuary.computer")

    statements = sql_statements do
      r = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results
      assert_equal 1, r[:expected_response_count]
    end
    offenders = statements.grep(/survey_responders/)
    assert_empty offenders, "responder tables must never be queried: #{offenders.inspect}"
  end

  test "free text is withheld under three responses but scores remain" do
    survey = build_studio_survey!(answers: [
      { sentiment: :agree, context: "c1", free_text: "f1" },
      { sentiment: :neutral, context: "c2", free_text: "f2" },
    ])
    r = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results

    assert_equal "fewer than 3 responses", r[:free_text_withheld]
    assert_equal [], r[:questions].first[:contexts]
    assert_equal [], r[:free_text_questions].first[:responses]
    assert_in_delta 3.13, r[:questions].first[:average], 0.01
    assert_equal 2, r[:questions].first[:response_count]
  end

  test "small_sample flips at five responses" do
    four = build_studio_survey!(title: "Four", answers: Array.new(4) { { sentiment: :agree } })
    five = build_studio_survey!(title: "Five", answers: Array.new(5) { { sentiment: :agree } })
    assert_equal true, Mcp::SurveyPresenter.find(kind: "studio", id: four.id).results[:small_sample]
    assert_equal false, Mcp::SurveyPresenter.find(kind: "studio", id: five.id).results[:small_sample]
  end

  test "a closed survey with no responses is safe" do
    survey = build_studio_survey!(answers: [])
    r = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results
    assert_nil r[:overall_score]
    assert_equal 1, r[:questions].size
    assert_nil r[:questions].first[:average]
    assert_equal 0, r[:questions].first[:response_count]
    assert_equal [], r[:free_text_questions].first[:responses]
  end

  test "an invalid stored sentiment of 0 is excluded from averages and distributions" do
    survey = build_studio_survey!(answers: [{ sentiment: :agree }, { sentiment: :agree }, { sentiment: :agree }])
    # update_column bypasses the enum cast (update_all(sentiment: 0) raises ArgumentError).
    survey.survey_responses.first.survey_question_responses.first.update_column(:sentiment, 0)

    q = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results[:questions].first
    assert_equal 2, q[:response_count]
    assert_in_delta 3.75, q[:average], 0.01
    assert_equal 2, q[:distribution][:agree]
  end

  test "open surveys withhold results entirely" do
    survey = build_project_survey!(closed: false, answers: [{ sentiment: :agree, context: "secret", free_text: "secret" }])
    r = Mcp::SurveyPresenter.find(kind: "project", id: survey.id).results

    assert_equal "survey is open", r[:results_withheld]
    assert_equal "Retro", r[:description]
    assert_equal 1, r[:response_count]
    refute r.key?(:questions)
    refute r.key?(:free_text_questions)
    refute r.key?(:small_sample)
    refute_includes r.to_json, "secret"
  end

  test "payloads never contain a responder's name or email" do
    survey = build_studio_survey!(answers: Array.new(3) { { sentiment: :agree, context: "fine", free_text: "fine" } })
    responder = AdminUser.create!(email: "very-distinctive-responder@sanctuary.computer",
                                  password: "password12345", password_confirmation: "password12345")
    SurveyResponder.create!(survey: survey, admin_user: responder)

    p = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id)
    json = [p.summary, p.results].to_json
    refute_includes json, "very-distinctive-responder"
    refute_includes json, "@sanctuary.computer"
  end
end
