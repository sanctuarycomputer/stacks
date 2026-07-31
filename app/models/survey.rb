class Survey < ApplicationRecord
  OTHER_RESPONDENTS = Struct.new(:name).new("Other respondents").freeze

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

  def reference_date
    # Anchor for "as of" membership + the elevated-service window. Use the survey's
    # open date so a closed/past survey reflects the cohort that was actually surveyed,
    # but never the future: a draft opening later (e.g. a freshly duplicated survey,
    # whose opens_at is set weeks out) must still evaluate against the trailing
    # completed months from today, not a shifted/incomplete future window.
    [opens_at&.to_date || Date.today, Date.today].min
  end

  def elevated_service_periods
    ref = reference_date.beginning_of_month
    # The trailing 6 completed months before reference_date. A contributor counts as
    # "elevated" if they met the threshold in at least
    # Contributor::ELEVATED_SERVICE_MIN_QUALIFYING_MONTHS (1) of these.
    # NOTE: Stacks::Period.for_gradation excludes the month CONTAINING `through`
    # (it stops at through.last_month.end_of_month), so passing `ref` (first of the
    # current month) yields exactly the 6 completed months before it.
    Stacks::Period.for_gradation(:month, ref - 6.months, ref)
  end

  def expected_responders
    expected_responder_status.values.flat_map(&:keys).uniq
  end

  # Cheap membership test for ONE user — avoids computing the whole expected set
  # (which runs the elevated-service bulk). Equivalent to
  # expected_responders.include?(admin_user).
  def expected_responder?(admin_user)
    return false if admin_user.nil?
    ref = reference_date
    # Core members (full-time) of any of the survey's studios — cheap existence checks.
    return true if studios.any? { |s| s.core_members_active_on(ref).exists?(id: admin_user.id) }
    # Elevated service: only if the user is a member of one of the survey's studios,
    # and only checks THIS user's contributor (bulk call with a single candidate).
    return false unless studios.any? { |s| s.members_active_on(ref).exists?(id: admin_user.id) }
    fp_id = admin_user.forecast_person&.forecast_id
    return false if fp_id.nil?
    Contributor.elevated_service_admin_user_ids(elevated_service_periods, [fp_id]).include?(admin_user.id)
  end

  # Memoized: called repeatedly per survey (index rows call expected_responders twice),
  # and the elevated-service bulk is the expensive part.
  def expected_responder_status
    @expected_responder_status ||= begin
      ref = reference_date
      # One bulk elevated-service computation for the whole survey.
      candidate_fp_ids = studios.flat_map { |s|
        s.members_active_on(ref).joins(:forecast_person).pluck("forecast_people.forecast_id")
      }.uniq
      elevated_ids = Contributor.elevated_service_admin_user_ids(elevated_service_periods, candidate_fp_ids)

      studios.each_with_object({}) do |studio, acc|
        core = studio.core_members_active_on(ref).to_a
        elevated = studio.members_active_on(ref).where(id: elevated_ids.to_a).to_a
        members = (core + elevated).uniq
        acc[studio] = members.each_with_object({}) do |admin_user, h|
          h[admin_user] = SurveyResponder.find_by(survey: self, admin_user: admin_user)
        end
      end
    end
  end

  def responder_status
    status = expected_responder_status
    already = status.values.flat_map(&:keys).to_set

    others = SurveyResponder.where(survey: self).includes(:admin_user).each_with_object({}) do |responder, h|
      au = responder.admin_user
      next if au.nil? || already.include?(au)
      h[au] = responder
    end

    others.empty? ? status : status.merge(OTHER_RESPONDENTS => others)
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
        new_survey.survey_free_text_questions << n
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