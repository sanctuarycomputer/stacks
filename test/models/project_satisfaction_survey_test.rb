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

  test "destroy removes closed survey, dependents, and clears capsule survey status" do
    forecast_project = make_forecast_project![0]
    tracker = make_project_tracker!([forecast_project])
    capsule = ProjectCapsule.create!(
      project_tracker: tracker,
      project_satisfaction_survey_status: :internal_project_team_satisfaction_survey_created
    )
    survey = ProjectSatisfactionSurvey.create!(
      project_capsule: capsule,
      title: "S",
      description: "D"
    )
    question = survey.project_satisfaction_survey_questions.create!(prompt: "Q1")
    ft_question = survey.project_satisfaction_survey_free_text_questions.create!(prompt: "FT1")
    survey_response = survey.project_satisfaction_survey_responses.create!
    survey_response.project_satisfaction_survey_question_responses.create!(
      project_satisfaction_survey_question: question,
      sentiment: :strongly_agree
    )
    survey_response.project_satisfaction_survey_free_text_question_responses.create!(
      project_satisfaction_survey_free_text_question: ft_question,
      response: "notes"
    )
    admin = AdminUser.create!(
      email: "pss-destroy-test-#{SecureRandom.hex(6)}@example.com",
      password: "password"
    )
    survey.project_satisfaction_survey_responders.create!(admin_user: admin)

    survey.update!(closed_at: Time.current)
    survey.reload
    survey_id = survey.id
    response_id = survey_response.id

    survey.destroy!

    assert_nil ProjectSatisfactionSurvey.find_by(id: survey_id)
    assert_nil ProjectSatisfactionSurveyResponse.find_by(id: response_id)
    assert_equal 0, ProjectSatisfactionSurveyQuestion.where(project_satisfaction_survey_id: survey_id).count
    assert_equal 0, ProjectSatisfactionSurveyFreeTextQuestion.where(project_satisfaction_survey_id: survey_id).count
    assert_equal 0, ProjectSatisfactionSurveyResponder.where(project_satisfaction_survey_id: survey_id).count
    assert_nil capsule.reload.project_satisfaction_survey_status
  end
end
