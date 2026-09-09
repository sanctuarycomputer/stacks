module Mcp
  class SurveyPresenter
    # Survey (studio-wide) side of the presenter's adapter interface. Every query here is
    # aggregate-only: it never loads SurveyResponder rows or any AdminUser.
    class StudioAdapter
      attr_reader :record

      def initialize(record)
        @record = record
      end

      # Draft surveys (not yet open) are invisible to the MCP.
      def self.visible_scope(status)
        case status
        when 'open' then Survey.open
        when 'closed' then Survey.closed
        else Survey.where('closed_at IS NOT NULL OR opens_at <= ?', Time.zone.today)
        end
      end

      def self.find(id)
        survey = Survey.find_by(id: id)
        survey if survey && survey.status != :draft
      end

      def self.preload(scope)
        scope.includes(:studios)
      end

      # { survey_id => response count }
      def self.response_counts(ids)
        SurveyResponse.where(survey_id: ids).group(:survey_id).count
      end

      # { survey_id => overall score } — mean of per-question averages, one query for all ids.
      def self.overall_scores(ids)
        rows = SurveyQuestionResponse.joins(:survey_response)
                                     .where(survey_responses: { survey_id: ids })
                                     .pluck('survey_responses.survey_id', :survey_question_id, :sentiment)
        rows.group_by(&:first).transform_values do |survey_rows|
          SurveyPresenter.mean_of_question_averages(
            survey_rows.map { |(_, qid, s)| [qid, SurveyPresenter.sentiment_name(s)] }
          )
        end
      end

      def opened_at
        record.opens_at
      end

      def scope
        { studios: record.studios.map { |s| { name: s.name, mini_name: s.mini_name } } }
      end

      def url
        "#{ADMIN_HOST}/admin/surveys/#{record.id}"
      end

      def response_count
        record.survey_responses.count
      end

      def overall_score
        self.class.overall_scores([record.id])[record.id]
      end

      def expected_response_count
        record.expected_responder_ids.size
      end

      def questions
        record.survey_questions.order(:id).to_a
      end

      def free_text_questions
        record.survey_free_text_questions.order(:id).to_a
      end

      # [[question_id, sentiment_name_or_nil, context], ...]
      def rating_answers
        SurveyQuestionResponse.joins(:survey_response)
                              .where(survey_responses: { survey_id: record.id })
                              .order(:id)
                              .pluck(:survey_question_id, :sentiment, :context)
                              .map { |(qid, s, c)| [qid, SurveyPresenter.sentiment_name(s), c] }
      end

      # [[free_text_question_id, response], ...]
      def free_text_answers
        SurveyFreeTextQuestionResponse.joins(:survey_response)
                                      .where(survey_responses: { survey_id: record.id })
                                      .order(:id)
                                      .pluck(:survey_free_text_question_id, :response)
      end
    end
  end
end
