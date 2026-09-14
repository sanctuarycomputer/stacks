# Builders for the two survey families, used by the MCP survey presenter/tool tests.
# Every builder is deterministic under travel_to; callers freeze time first.
module SurveyFixtures
  FROZEN_NOW = "2026-08-01 12:00:00".freeze
  CLOSED_AT = "2026-07-01 12:00:00".freeze

  # answers: array of hashes, one per response:
  #   { sentiment: :agree, context: "…", free_text: "…" }
  # Returns the Survey. One rating question + one free-text question.
  def build_studio_survey!(closed: true, answers: [], title: "Alpha Pulse", studio_name: "Alpha",
                           opens_at: Date.new(2026, 6, 1))
    studio = Studio.find_by(name: studio_name) ||
             Studio.create!(name: studio_name, mini_name: studio_name.downcase, snapshot: {})
    survey = Survey.create!(title: title, description: "How is it going?", opens_at: opens_at,
                            closed_at: closed ? Time.zone.parse(CLOSED_AT) : nil)
    survey.survey_studios.create!(studio: studio)
    question = survey.survey_questions.create!(prompt: "I feel supported")
    free_text = survey.survey_free_text_questions.create!(prompt: "What should we stop doing?")
    answers.each do |a|
      response = survey.survey_responses.create!
      SurveyQuestionResponse.create!(survey_response: response, survey_question: question,
                                     sentiment: a.fetch(:sentiment, :agree), context: a[:context])
      SurveyFreeTextQuestionResponse.create!(survey_response: response,
                                             survey_free_text_question: free_text,
                                             response: a[:free_text])
    end
    survey
  end

  # Same answer shape. Returns the ProjectSatisfactionSurvey. The tracker is named
  # "Healthcare.gov Project Tracker" by make_project_tracker!.
  def build_project_survey!(closed: true, answers: [], title: "Healthcare Retro")
    forecast_project = make_forecast_project![0]
    tracker = make_project_tracker!([forecast_project])
    capsule = ProjectCapsule.create!(project_tracker: tracker)
    survey = ProjectSatisfactionSurvey.create!(project_capsule: capsule, title: title,
                                               description: "Retro")
    question = survey.project_satisfaction_survey_questions.create!(prompt: "The budget was realistic")
    free_text = survey.project_satisfaction_survey_free_text_questions.create!(prompt: "What should we start doing?")
    answers.each do |a|
      response = survey.project_satisfaction_survey_responses.create!
      ProjectSatisfactionSurveyQuestionResponse.create!(
        project_satisfaction_survey_response: response,
        project_satisfaction_survey_question: question,
        sentiment: a.fetch(:sentiment, :agree), context: a[:context]
      )
      ProjectSatisfactionSurveyFreeTextQuestionResponse.create!(
        project_satisfaction_survey_response: response,
        project_satisfaction_survey_free_text_question: free_text,
        response: a[:free_text]
      )
    end
    # Close AFTER answers exist so the before_save sync persists a real score.
    survey.update!(closed_at: Time.zone.parse(CLOSED_AT)) if closed
    survey
  end

  # Collects every SQL statement executed inside the block.
  def sql_statements
    statements = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end
end
