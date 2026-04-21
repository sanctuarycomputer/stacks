require "test_helper"

class ProjectSatisfactionSurveyTest < ActiveSupport::TestCase
  test "score is set when survey is closed and cleared when reopened" do
    forecast_project = make_forecast_project![0]
    tracker = make_project_tracker!([forecast_project])
    capsule = ProjectCapsule.create!(project_tracker: tracker)
    survey = ProjectSatisfactionSurvey.create!(
      project_capsule: capsule,
      title: "S",
      description: "D"
    )
    question = survey.project_satisfaction_survey_questions.create!(prompt: "Q1")
    survey_response = survey.project_satisfaction_survey_responses.create!
    survey_response.project_satisfaction_survey_question_responses.create!(
      project_satisfaction_survey_question: question,
      sentiment: :strongly_agree
    )

    survey.update!(closed_at: Time.current)
    survey.reload
    assert_in_delta 5.0, survey.score.to_f, 0.01

    survey.update!(closed_at: nil)
    survey.reload
    assert_nil survey.score
  end
end
