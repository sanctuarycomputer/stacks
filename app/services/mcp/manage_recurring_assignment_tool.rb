module Mcp
  class ManageRecurringAssignmentTool < MCP::Tool
    tool_name 'manage_recurring_assignment'
    description 'WRITE: change a recurring assignment\'s lifecycle. action = "pause" (stop ' \
                'materializing), "resume", or "destroy" (delete the rule; already-materialized ' \
                'Forecast assignments are LEFT INTACT). Returns {before, after, action}.'
    input_schema(
      properties: {
        recurring_assignment_id: { type: 'integer' },
        action: { type: 'string', description: '"pause" | "resume" | "destroy"' },
      },
      required: %w[recurring_assignment_id action]
    )
    annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true)

    ACTIONS = %w[pause resume destroy].freeze

    def self.call(recurring_assignment_id:, action:, server_context:)
      rid = WriteValidation.integer!("recurring_assignment_id", recurring_assignment_id)
      raise ArgumentError, "action must be one of #{ACTIONS.join(', ')}" unless ACTIONS.include?(action.to_s)
      ra = RecurringAssignment.find(rid)
      before = { paused_at: ra.paused_at, exists: true }
      WriteGuard.check!
      case action.to_s
      when "pause"   then ra.update!(paused_at: Time.current)
      when "resume"  then ra.update!(paused_at: nil)
      when "destroy" then ra.destroy!
      end
      after = ra.destroyed? ? { paused_at: nil, exists: false } : { paused_at: ra.paused_at, exists: true }
      Responses.ok({ before: before, after: after, action: action.to_s })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("recurring_assignment #{recurring_assignment_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ManageRecurringAssignmentTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("manage_recurring_assignment failed; the error was logged")
    end
  end
end
