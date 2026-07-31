module Mcp
  class FindContributorTool < MCP::Tool
    tool_name 'find_contributor'
    description 'READ: find contributors by email (exact, case-insensitive). Returns ' \
                '[{id, name, email}]. Use the returned id as contributor_id for ' \
                'create_recurring_assignment.'
    input_schema(
      properties: { email: { type: 'string' } },
      required: %w[email]
    )
    annotations(read_only_hint: true)

    def self.call(email:, server_context:)
      fp_ids = ForecastPerson.where("lower(email) = ?", email.to_s.strip.downcase).select(:forecast_id)
      rows = Contributor.where(forecast_person_id: fp_ids).map do |c|
        { id: c.id, name: c.display_name, email: c.forecast_person&.email }
      end
      Responses.ok(rows)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::FindContributorTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("find_contributor failed; the error was logged")
    end
  end
end
