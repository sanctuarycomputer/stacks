module Mcp
  class SurveyPresenter
    # ProjectSatisfactionSurvey side of the presenter's adapter interface. Aggregate-only:
    # never loads responder rows or AdminUser identities.
    class ProjectAdapter
      attr_reader :record

      def initialize(record)
        @record = record
      end

      def self.visible_scope(status)
        case status
        when 'open' then ProjectSatisfactionSurvey.open
        when 'closed' then ProjectSatisfactionSurvey.closed
        else ProjectSatisfactionSurvey.all
        end
      end

      def self.find(id)
        ProjectSatisfactionSurvey.find_by(id: id)
      end

      def self.preload(scope)
        scope.includes(project_capsule: :project_tracker)
      end

      def self.response_counts(ids)
        ProjectSatisfactionSurveyResponse.where(project_satisfaction_survey_id: ids)
                                         .group(:project_satisfaction_survey_id).count
      end

      # The persisted `score` column (synced on close) is the number the admin page shows.
      def self.overall_scores(ids)
        ProjectSatisfactionSurvey.where(id: ids).pluck(:id, :score)
                                 .to_h { |id, score| [id, score&.to_f&.round(2)] }
      end

      def opened_at
        record.created_at.to_date
      end

      def scope
        tracker = record.project_capsule&.project_tracker
        { project_tracker_id: tracker&.id, project: tracker&.name }
      end

      def url
        "#{ADMIN_HOST}/admin/project_satisfaction_surveys/#{record.id}"
      end

      def response_count
        record.project_satisfaction_survey_responses.count
      end

      def overall_score
        record.score&.to_f&.round(2)
      end

      # all_contributors_with_roles filtered to AdminUser.active — no responder rows involved.
      def expected_response_count
        record.expected_responders.size
      end

      def questions
        record.project_satisfaction_survey_questions.order(:id).to_a
      end

      def free_text_questions
        record.project_satisfaction_survey_free_text_questions.order(:id).to_a
      end

      def rating_answers
        ProjectSatisfactionSurveyQuestionResponse
          .joins(:project_satisfaction_survey_response)
          .where(project_satisfaction_survey_responses: { project_satisfaction_survey_id: record.id })
          .order(:id)
          .pluck(:project_satisfaction_survey_question_id, :sentiment, :context)
          .map { |(qid, s, c)| [qid, SurveyPresenter.sentiment_name(s), c] }
      end

      def free_text_answers
        ProjectSatisfactionSurveyFreeTextQuestionResponse
          .joins(:project_satisfaction_survey_response)
          .where(project_satisfaction_survey_responses: { project_satisfaction_survey_id: record.id })
          .order(:id)
          .pluck(:project_satisfaction_survey_free_text_question_id, :response)
      end
    end
  end
end
