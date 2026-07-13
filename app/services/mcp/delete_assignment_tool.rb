module Mcp
  class DeleteAssignmentTool < MCP::Tool
    tool_name 'delete_assignment'
    description 'WRITE: delete a planned (projection) assignment by id. The provider has no ' \
                'single-assignment read, so keep your own copy of the record as revert material ' \
                'BEFORE deleting (the sweep world / finding payload carries it).'
    input_schema(
      properties: { assignment_id: { type: 'integer' } },
      required: %w[assignment_id]
    )
    annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true)

    def self.call(assignment_id:, server_context:)
      id = WriteValidation.integer!("assignment_id", assignment_id)
      WriteGuard.check!

      Stacks::Runn.new(max_retries: 0).delete_assignment(id)
      Responses.ok({ deleted_assignment_id: id, after: nil })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::DeleteAssignmentTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("delete_assignment failed; the error was logged")
    end
  end
end
