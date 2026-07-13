module Mcp
  class CreateAssignmentTool < MCP::Tool
    tool_name 'create_assignment'
    description 'WRITE: create a planned (projection) assignment — person, project, role, date range, ' \
                'minutes_per_day (480 = full day). The provider auto-splits around its own scheduled ' \
                'leave and returns each segment. There is no update: to change an assignment, create ' \
                'the replacement first, then delete_assignment the old one.'
    input_schema(
      properties: {
        person_id: { type: 'number' },
        project_id: { type: 'number' },
        role_id: { type: 'number' },
        start_date: { type: 'string', description: 'YYYY-MM-DD' },
        end_date: { type: 'string', description: 'YYYY-MM-DD' },
        minutes_per_day: { type: 'number', description: '0-1440; 480 = full day' },
        note: { type: 'string' },
      },
      required: %w[person_id project_id role_id start_date end_date minutes_per_day]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: false)

    def self.call(person_id:, project_id:, role_id:, start_date:, end_date:, minutes_per_day:, note: nil, server_context:)
      WriteValidation.date_range!(start_date, end_date)
      minutes = WriteValidation.minutes!(minutes_per_day)
      WriteGuard.check!

      segments = Stacks::Runn.new(max_retries: 0).create_assignment(
        person_id: WriteValidation.integer!("person_id", person_id),
        project_id: WriteValidation.integer!("project_id", project_id),
        role_id: WriteValidation.integer!("role_id", role_id),
        start_date: start_date,
        end_date: end_date,
        minutes_per_day: minutes,
        note: note,
      )
      Responses.ok({ before: nil, after: segments })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::CreateAssignmentTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("create_assignment failed; the error was logged")
    end
  end
end
