module Mcp
  class GetSurveyResultsTool < MCP::Tool
    tool_name 'get_survey_results'
    description 'READ: one survey with ANONYMOUS aggregate results. For a CLOSED survey: ' \
                'per-question averages (0-5), Likert distributions, the optional free-text ' \
                'context behind each score, and free-text answers (text arrays are sorted, and ' \
                'withheld entirely under 3 responses — see free_text_withheld). For an OPEN ' \
                'survey: metadata and response rate only (results_withheld). Responses cannot ' \
                'be tied to a person and must never be attributed, guessed at, or quoted ' \
                'verbatim into team-visible stores; small_sample flags surveys with fewer than ' \
                '5 responses. Never combine with contributor-listing tools for the same project ' \
                'or studio.'

    input_schema(
      properties: {
        kind: { type: 'string', description: SurveyPresenter::KINDS.join(' | ') },
        id: { type: 'integer', description: 'Survey id from list_surveys (ids are per kind).' },
      },
      required: %w[kind id]
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(kind:, id:, server_context:)
      kind = kind.to_s
      unless SurveyPresenter::KINDS.include?(kind)
        return Responses.error("Unknown kind '#{kind}'. Valid kinds: #{SurveyPresenter::KINDS.join(', ')}")
      end

      presenter = SurveyPresenter.find(kind: kind, id: id.to_i)
      return Responses.error('Survey not found') unless presenter

      Responses.ok(presenter.results)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetSurveyResultsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_survey_results failed; the error was logged')
    end
  end
end
