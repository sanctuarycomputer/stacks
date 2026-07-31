module Mcp
  class ListProjectTrackersTool < MCP::Tool
    tool_name 'list_project_trackers'
    description 'READ: list project trackers, optionally filtered by name or client ' \
                '(both exact, case-insensitive). Each tracker includes its nested ' \
                'workstreams (id, name, code, rates). Use to find a tracker id or to ' \
                'inspect existing workstreams/rates before ensuring one.'
    input_schema(
      properties: {
        name: { type: 'string' },
        client: { type: 'string' },
      },
      required: []
    )
    annotations(read_only_hint: true)

    def self.call(name: nil, client: nil, server_context:)
      trackers = ProjectTracker.all
      if client.present?
        client_ids = ForecastClient.where("lower(name) = ?", client.strip.downcase).select(:forecast_id)
        fp_ids = ForecastProject.where(client_id: client_ids).select(:forecast_id)
        trackers = trackers.where(id: ProjectTrackerForecastProject.where(forecast_project_id: fp_ids).select(:project_tracker_id))
      end
      trackers = trackers.where("lower(name) = ?", name.strip.downcase) if name.present?
      Responses.ok(trackers.map { |t| ProvisioningSerializers.tracker_json(t) })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ListProjectTrackersTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("list_project_trackers failed; the error was logged")
    end
  end
end
