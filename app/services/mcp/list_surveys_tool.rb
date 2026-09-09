module Mcp
  class ListSurveysTool < MCP::Tool
    tool_name 'list_surveys'
    description 'READ: list studio-wide and project satisfaction surveys, newest first (closed ' \
                'surveys by closed_at, open ones by opened_at). Filter by kind (studio|project), ' \
                'status (open|closed), and a closed_at range. Survey responses are ANONYMOUS by ' \
                'design: this tool exposes counts only, never responders. Each row carries ' \
                'overall_score (0-5, closed surveys only) so trends across surveys of the same ' \
                'scope can be read without extra calls. Use get_survey_results for per-question ' \
                'scores and free text.'

    MIN_LIMIT = 1
    MAX_LIMIT = 200
    DEFAULT_LIMIT = 50

    input_schema(
      properties: {
        kind: { type: 'string', description: "Optional: #{SurveyPresenter::KINDS.join(' | ')}. Default both." },
        status: { type: 'string', description: "Optional: #{SurveyPresenter::STATUSES.join(' | ')}. Default both (drafts are never listed)." },
        closed_after: { type: 'string', description: 'ISO8601 lower bound on closed_at (inclusive; a date-only value means the start of that day). Implies status closed.' },
        closed_before: { type: 'string', description: 'ISO8601 upper bound on closed_at (inclusive of the exact instant; a date-only value means the START of that day, so pass a full timestamp or the next day to include a whole day). Implies status closed.' },
        limit: { type: 'integer', description: "Rows per page (default #{DEFAULT_LIMIT}, clamped #{MIN_LIMIT}..#{MAX_LIMIT})." },
        offset: { type: 'integer', description: 'Rows to skip after sorting, for pagination (default 0).' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(kind: nil, status: nil, closed_after: nil, closed_before: nil,
                  limit: DEFAULT_LIMIT, offset: 0, server_context:)
      kind = kind.presence
      status = status.presence
      if kind && !SurveyPresenter::KINDS.include?(kind)
        return Responses.error("Unknown kind '#{kind}'. Valid kinds: #{SurveyPresenter::KINDS.join(', ')}")
      end
      if status && !SurveyPresenter::STATUSES.include?(status)
        return Responses.error("Unknown status '#{status}'. Valid statuses: #{SurveyPresenter::STATUSES.join(', ')}")
      end

      range = Mcp::DateRange.parse(closed_after, closed_before)
      if range && status == 'open'
        return Responses.error("closed_after/closed_before cannot be combined with status 'open'")
      end

      limit = limit.to_i.clamp(MIN_LIMIT, MAX_LIMIT)
      offset = [offset.to_i, 0].max

      rows = SurveyPresenter.list(kind: kind, status: status, closed_range: range, limit: limit, offset: offset)
      Responses.ok(rows.map(&:summary))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ListSurveysTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('list_surveys failed; the error was logged')
    end
  end
end
