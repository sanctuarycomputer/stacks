class ProjectSatisfactionSurvey < ApplicationRecord
  scope :draft, -> {
    where(closed_at: nil).where("opens_at IS NULL OR opens_at > ?", Date.today)
  }
  scope :open, -> {
    where(closed_at: nil).where("opens_at <= ?", Date.today)
  }
  scope :closed, -> {
    where.not(closed_at: nil)
  }

  belongs_to :project_capsule

  has_many :project_satisfaction_survey_questions
  accepts_nested_attributes_for :project_satisfaction_survey_questions, allow_destroy: true

  has_many :project_satisfaction_survey_free_text_questions
  accepts_nested_attributes_for :project_satisfaction_survey_free_text_questions, allow_destroy: true

  has_many :project_satisfaction_survey_responses
  has_many :project_satisfaction_survey_responders

  def status
    return :closed if closed_at.present?

    if opens_at.nil? || opens_at > Date.today
      :draft
    else
      :open
    end
  end

  def expected_responders
    if project_capsule.project_tracker.present?
      project_tracker = project_capsule.project_tracker
      # Get all admin users who were assigned to this project
      project_members = []

      # Add project leads
      project_members += project_tracker.project_lead_periods.map(&:admin_user)

      # Add creative leads
      project_members += project_tracker.creative_lead_periods.map(&:admin_user)

      # Add technical leads
      project_members += project_tracker.technical_lead_periods.map(&:admin_user)

      # Return unique list of admin users
      project_members.uniq
    else
      []
    end
  end

  def expected_responder_status
    expected_responders.reduce({}) do |acc, admin_user|
      acc[admin_user] = ProjectSatisfactionSurveyResponder.find_by(
        project_satisfaction_survey: self,
        admin_user: admin_user
      )
      acc
    end
  end

  def self.clone_from(original_survey)
    new_survey = ProjectSatisfactionSurvey.create!({
      project_capsule: original_survey.project_capsule,
      title: "#{original_survey.title} (Copy)",
      description: original_survey.description,
    })

    original_survey.project_satisfaction_survey_questions.each do |question|
      new_survey.project_satisfaction_survey_questions << ProjectSatisfactionSurveyQuestion.create!({
        project_satisfaction_survey: new_survey,
        prompt: question.prompt
      })
    end

    original_survey.project_satisfaction_survey_free_text_questions.each do |question|
      new_survey.project_satisfaction_survey_free_text_questions << ProjectSatisfactionSurveyFreeTextQuestion.create!({
        project_satisfaction_survey: new_survey,
        prompt: question.prompt
      })
    end

    new_survey
  end

  def results
    return nil if project_satisfaction_survey_responses.empty?

    # Calculate average sentiment by question
    question_results = {}
    project_satisfaction_survey_questions.each do |q|
      responses = ProjectSatisfactionSurveyQuestionResponse.where(project_satisfaction_survey_question: q)

      if responses.any?
        question_results[q] = {
          average_sentiment: responses.reduce(0.0) do |sum, response|
            sum + ProjectSatisfactionSurveyQuestionResponse.sentiment_to_score(response.sentiment.to_s)
          end / responses.count,
          response_count: responses.count
        }
      end
    end

    # Collect free text responses
    free_text_results = {}
    project_satisfaction_survey_free_text_questions.each do |q|
      responses = ProjectSatisfactionSurveyFreeTextQuestionResponse.where(
        project_satisfaction_survey_free_text_question: q
      ).pluck(:response).reject(&:blank?)

      if responses.any?
        free_text_results[q] = responses
      end
    end

    {
      question_results: question_results,
      free_text_results: free_text_results,
      response_count: project_satisfaction_survey_responses.count,
      expected_response_count: expected_responders.count
    }
  end
end