class Survey < ApplicationRecord
  scope :draft, -> {
    where(closed_at: nil).where("opens_at IS NULL OR opens_at > ?", Date.today)

  }
  scope :open, -> {
    where(closed_at: nil).where("opens_at <= ?", Date.today)
  }
  scope :closed, -> {
    where.not(closed_at: nil)
  }

  has_many :survey_questions
  accepts_nested_attributes_for :survey_questions, allow_destroy: true

  has_many :survey_free_text_questions
  accepts_nested_attributes_for :survey_free_text_questions, allow_destroy: true

  has_many :survey_studios
  accepts_nested_attributes_for :survey_studios, allow_destroy: true

  has_many :survey_responses

  has_many :studios, through: :survey_studios

  def status
    return :closed if closed_at.present?

    if opens_at.nil? || opens_at > Date.today
      :draft
    else
      :open
    end
  end

  def expected_responders
    studios.reduce([]) do |acc, studio|
      [*acc, *studio.core_members_active_on(Date.today)]
    end
  end

  def expected_responder_status
    studios.reduce({}) do |acc, studio|
      acc[studio] = studio.core_members_active_on(Date.today).reduce({}) do |acc, admin_user|
        acc[admin_user] = SurveyResponder.find_by(survey: self, admin_user: admin_user)
        acc
      end
      acc
    end
  end

  def results
    survey_responses.reduce({ by_q: {}, by_free_text_q: {} }) do |acc, sr|
      sr.survey_question_responses.each do |sqr|
        acc[:by_q][sqr.survey_question] =
          acc[:by_q][sqr.survey_question] || { sentiments: [], contexts: [], prompt: sqr.survey_question.prompt }
        if SurveyQuestionResponse.sentiments[sqr.sentiment]
          acc[:by_q][sqr.survey_question][:sentiments] << SurveyQuestionResponse.sentiment_to_score(sqr.sentiment)
        end
        if sqr.context.present?
          acc[:by_q][sqr.survey_question][:contexts] << sqr.context
        end
      end

      sr.survey_free_text_question_responses.each do |sftqr|
        acc[:by_free_text_q][sftqr.survey_free_text_question] =
          acc[:by_free_text_q][sftqr.survey_free_text_question] || { responses: [], prompt: sftqr.survey_free_text_question.prompt }
        if sftqr.response.present?
          acc[:by_free_text_q][sftqr.survey_free_text_question][:responses] << sftqr.response
        end
      end

      acc[:by_q].each do |question, data|
        data[:average] = data[:sentiments].instance_eval { reduce(:+) / size.to_f }
      end
      acc[:overall] = acc[:by_q].values.map{|v| v[:average]}.instance_eval { reduce(:+) / size.to_f }
      acc
    end
  end

  def self.clone_from(prev_survey)
    ActiveRecord::Base.transaction do
      new_survey = prev_survey.dup
      new_survey.title = "Cloned from: #{prev_survey.title}"
      new_survey.opens_at = (Date.today + 4.weeks) if new_survey.opens_at.present?
      new_survey.closed_at = nil

      prev_survey.survey_questions.each do |sq|
        n = sq.dup
        n.survey = new_survey
        new_survey.survey_questions << n
      end

      prev_survey.survey_free_text_questions.each do |sq|
        n = sq.dup
        n.survey = new_survey
        new_survey.survey_questions << n
      end

      prev_survey.survey_studios.each do |ss|
        n = ss.dup
        n.survey = new_survey
        new_survey.survey_studios << n
      end

      new_survey.save!
      new_survey
    end
  end
end