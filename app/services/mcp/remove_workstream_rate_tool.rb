module Mcp
  class RemoveWorkstreamRateTool < MCP::Tool
    tool_name 'remove_workstream_rate'
    description 'WRITE: remove a p/h rate from a workstream (idempotent — removing an absent ' \
                'rate is a no-op). rate is a string like "450p/h". Returns {before, after, removed}.'
    input_schema(
      properties: {
        workstream_id: { type: 'integer' },
        rate: { type: 'string', description: 'rate as a string, e.g. "450p/h"' },
      },
      required: %w[workstream_id rate]
    )
    annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true)

    def self.call(workstream_id:, rate:, server_context:)
      wid = WriteValidation.integer!("workstream_id", workstream_id)
      ws = ProjectTrackerForecastProject.find(wid)
      tag = Stacks::Forecast.rate_tag(rate)
      present = Array(ws.forecast_project&.tags).include?(tag)
      unless present
        json = ProvisioningSerializers.workstream_json(ws)
        return Responses.ok({ before: json, after: json, removed: false })
      end
      before = ProvisioningSerializers.workstream_json(ws)
      WriteGuard.check!
      Stacks::Forecast.new.remove_project_rate!(ws.forecast_project_id, rate)
      Responses.ok({ before: before, after: ProvisioningSerializers.workstream_json(ws.reload), removed: true })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("workstream #{workstream_id} not found")
    rescue StandardError => e
      Rails.logger.warn("[Mcp::RemoveWorkstreamRateTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("remove_workstream_rate failed; the error was logged")
    end
  end
end
