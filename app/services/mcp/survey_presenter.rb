module Mcp
  # Adapts both survey families (Survey = studio-wide, ProjectSatisfactionSurvey = per
  # project) into one ANONYMOUS, aggregate-only shape for the MCP tools. Responses are
  # structurally anonymous in Stacks (no link from an answer to a person); this class keeps
  # it that way: it never loads responder rows, names, or emails — only counts, scores,
  # and (for closed surveys with enough responses) the free text itself.
  class SurveyPresenter
    KINDS = %w[studio project].freeze
    STATUSES = %w[open closed].freeze
    SMALL_SAMPLE_THRESHOLD = 5
    MIN_RESPONSES_FOR_TEXT = 3
    ADMIN_HOST = 'https://stacks.garden3d.net'.freeze
    SENTIMENT_ORDER = %w[strongly_disagree disagree neutral agree strongly_agree].freeze
    # Same 0–5 scale as SurveyQuestionResponse.sentiment_to_score / the admin pages.
    SENTIMENT_SCORES = {
      'strongly_disagree' => 0.0, 'disagree' => 1.25, 'neutral' => 2.5, 'agree' => 3.75, 'strongly_agree' => 5.0
    }.freeze

    attr_reader :kind, :adapter

    def self.adapter_class(kind)
      case kind
      when 'studio' then StudioAdapter
      when 'project' then ProjectAdapter
      else raise ArgumentError, "unknown survey kind #{kind.inspect}"
      end
    end

    def self.find(kind:, id:)
      return nil unless KINDS.include?(kind)

      record = adapter_class(kind).find(id)
      record && new(kind, record)
    end

    # Enum values arrive as names from pluck (Rails casts enum columns), but an unmapped
    # stored 0 comes back nil, and a raw integer is possible on older adapters — normalize
    # to the enum name or nil. Both families share the same mapping.
    def self.sentiment_name(value)
      value.is_a?(Integer) ? SurveyQuestionResponse.sentiments.key(value) : value
    end

    # pairs: [[question_id, sentiment_name_or_nil], ...] → mean of the per-question
    # averages over valid answers, or nil when no question has a valid answer.
    def self.mean_of_question_averages(pairs)
      averages = pairs.group_by(&:first).values.filter_map do |rows|
        scores = rows.filter_map { |(_, s)| SENTIMENT_SCORES[s] }
        scores.empty? ? nil : scores.sum / scores.size
      end
      averages.empty? ? nil : (averages.sum / averages.size).round(2)
    end

    def initialize(kind, record, response_count: nil, overall_score: nil, overall_score_known: false)
      @kind = kind
      @adapter = self.class.adapter_class(kind).new(record)
      @response_count = response_count
      @overall_score = overall_score
      @overall_score_known = overall_score_known
    end

    def id
      adapter.record.id
    end

    def closed?
      adapter.record.closed_at.present?
    end

    def status
      closed? ? 'closed' : 'open'
    end

    def response_count
      @response_count ||= adapter.response_count
    end

    def overall_score
      return nil unless closed?

      unless @overall_score_known
        @overall_score = adapter.overall_score
        @overall_score_known = true
      end
      @overall_score
    end

    def summary
      {
        kind: kind,
        id: id,
        title: adapter.record.title,
        status: status,
        opened_at: adapter.opened_at&.iso8601,
        closed_at: adapter.record.closed_at&.iso8601,
        scope: adapter.scope,
        response_count: response_count,
        overall_score: overall_score,
        url: adapter.url,
      }
    end

    def results
      expected = adapter.expected_response_count
      base = summary.merge(
        description: adapter.record.description,
        expected_response_count: expected,
        response_rate: expected.zero? ? nil : response_count.fdiv(expected).round(2),
      )
      return base.merge(results_withheld: 'survey is open') unless closed?

      text_allowed = response_count >= MIN_RESPONSES_FOR_TEXT
      payload = base.merge(
        small_sample: response_count < SMALL_SAMPLE_THRESHOLD,
        questions: question_results(text_allowed),
        free_text_questions: free_text_results(text_allowed),
      )
      payload[:free_text_withheld] = "fewer than #{MIN_RESPONSES_FOR_TEXT} responses" unless text_allowed
      payload
    end

    private

    # Text arrays are SORTED, never in insertion order: DB order would align index i of every
    # array to the same respondent, reconstructing one full questionnaire per index.
    def question_results(text_allowed)
      by_question = adapter.rating_answers.group_by(&:first)
      adapter.questions.map do |question|
        rows = by_question.fetch(question.id, [])
        valid = rows.map { |(_, sentiment, _)| sentiment }.select { |s| SENTIMENT_SCORES.key?(s) }
        {
          prompt: question.prompt,
          average: valid.empty? ? nil : (valid.sum { |s| SENTIMENT_SCORES[s] } / valid.size).round(2),
          response_count: valid.size,
          distribution: SENTIMENT_ORDER.each_with_object({}) { |s, h| h[s.to_sym] = valid.count(s) },
          contexts: text_allowed ? rows.map(&:last).select(&:present?).sort : [],
        }
      end
    end

    def free_text_results(text_allowed)
      by_question = adapter.free_text_answers.group_by(&:first)
      adapter.free_text_questions.map do |question|
        answers = by_question.fetch(question.id, []).map(&:last).select(&:present?)
        { prompt: question.prompt, responses: text_allowed ? answers.sort : [] }
      end
    end
  end
end
