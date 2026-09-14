module Mcp
  class CreatePlaceholderTool < MCP::Tool
    tool_name 'create_placeholder'
    description 'WRITE: create a placeholder "person" for an unfilled role on a shell/project. ' \
                'IMPORTANT: the provider garbage-collects placeholders with no assignment within ' \
                '~24h — call create_assignment for it immediately. Returns the placeholder person ' \
                'id to assign.'
    input_schema(
      properties: { role_id: { type: 'integer' } },
      required: %w[role_id]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: false)

    def self.call(role_id:, server_context:)
      rid = WriteValidation.integer!("role_id", role_id)
      WriteGuard.check!

      placeholder = Stacks::Runn.new(max_retries: 0).create_placeholder(role_id: rid)
      Responses.ok({ before: nil, after: placeholder })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::CreatePlaceholderTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("create_placeholder failed; the error was logged")
    end
  end
end
