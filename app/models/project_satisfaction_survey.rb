class ProjectSatisfactionSurvey < ApplicationRecord
  # Only two states are used: open and closed
  scope :open, -> {
    where(closed_at: nil)
  }
  scope :closed, -> {
    where.not(closed_at: nil)
  }
  scope :all, -> { unscope(:where) }

  belongs_to :project_capsule
  validates :project_capsule, presence: true
  validates :title, presence: true
  validates :description, presence: true

  has_many :project_satisfaction_survey_questions
  accepts_nested_attributes_for :project_satisfaction_survey_questions, allow_destroy: true

  has_many :project_satisfaction_survey_free_text_questions
  accepts_nested_attributes_for :project_satisfaction_survey_free_text_questions, allow_destroy: true

  has_many :project_satisfaction_survey_responses
  has_many :project_satisfaction_survey_responders

  def status
    return :closed if closed_at.present?
    :open
  end

  def closed?
    closed_at.present?
  end

  # Get all team members who are expected to respond to this survey
  def expected_responders
    return [] if project_capsule.project_tracker.blank?

    # Get all contributors with roles from the project tracker
    project_members = project_capsule.project_tracker.all_contributors_with_roles

    # Get the list of active admin users
    active_admin_users = AdminUser.active

    # Filter to include only active users
    project_members.select do |admin_user, _|
      active_admin_users.include?(admin_user)
    end
  end

  # Returns a hash of admin users and whether they've responded
  def expected_responder_status
    expected_responders.keys.reduce({}) do |acc, admin_user|
      acc[admin_user] = ProjectSatisfactionSurveyResponder.find_by(
        project_satisfaction_survey: self,
        admin_user: admin_user
      )
      acc
    end
  end

  # Calculate the survey results, including scores and free text responses
  def results
    return nil if project_satisfaction_survey_responses.empty?

    # Calculate average sentiment by question
    question_results = {}
    total_score_sum = 0.0
    total_responses = 0

    project_satisfaction_survey_questions.each do |q|
      responses = ProjectSatisfactionSurveyQuestionResponse.where(project_satisfaction_survey_question: q)

      if responses.any?
        # Get context responses for this question
        context_responses = responses.map(&:context).reject(&:blank?)

        question_score_sum = responses.reduce(0.0) do |sum, response|
          sum + ProjectSatisfactionSurveyQuestionResponse.sentiment_to_score(response.sentiment.to_s)
        end

        average_sentiment = question_score_sum / responses.count

        # Add to overall totals
        total_score_sum += question_score_sum
        total_responses += responses.count

        question_results[q] = {
          average_sentiment: average_sentiment,
          response_count: responses.count,
          contexts: context_responses
        }
      end
    end

    # Calculate overall average
    overall_score = total_responses > 0 ? (total_score_sum / total_responses) : 0

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
      overall: overall_score,
      question_results: question_results,
      free_text_results: free_text_results,
      response_count: project_satisfaction_survey_responses.count,
      expected_response_count: expected_responders.count
    }
  end
end