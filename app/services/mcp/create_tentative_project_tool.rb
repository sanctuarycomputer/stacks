module Mcp
  class CreateTentativeProjectTool < MCP::Tool
    tool_name 'create_tentative_project'
    description 'WRITE: create a TENTATIVE (unconfirmed) project shell for pipeline work. Name should ' \
                'carry the lead marker, e.g. "Globex Redesign [lead:<notion-page-id>]", so the sweep ' \
                'can match shells to leads. Tentative-only by design: is_confirmed is not accepted here.'
    input_schema(
      properties: {
        name: { type: 'string' },
        client_id: { type: 'integer' },
        pricing_model: { type: 'string', description: '"tm" (default), "fp", or "nb"' },
      },
      required: %w[name client_id]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: false)

    PRICING_MODELS = %w[tm fp nb].freeze

    def self.call(name:, client_id:, pricing_model: 'tm', server_context:)
      raise ArgumentError, 'name must be non-empty' if name.to_s.strip.empty?
      name = WriteValidation.short_string!("name", name.to_s.strip, 255)
      raise ArgumentError, "pricing_model must be one of #{PRICING_MODELS.join(', ')}" unless PRICING_MODELS.include?(pricing_model)
      cid = WriteValidation.integer!("client_id", client_id)
      WriteGuard.check!

      project = Stacks::Runn.new(max_retries: 0).create_project(name, cid, pricing_model: pricing_model, is_confirmed: false)
      Responses.ok({ before: nil, after: project })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::CreateTentativeProjectTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("create_tentative_project failed; the error was logged")
    end
  end
end
