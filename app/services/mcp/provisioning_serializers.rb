module Mcp
  # Shared JSON shapes for the provisioning tools. Forecast stays hidden:
  # ids are native (ProjectTracker#id, ProjectTrackerForecastProject#id).
  module ProvisioningSerializers
    module_function

    def tracker_json(tracker)
      {
        id: tracker.id,
        name: tracker.name,
        client: tracker.derived_client&.name,
        workstreams: tracker.project_tracker_forecast_projects.map { |ws| workstream_json(ws) },
      }
    end

    def workstream_json(ws)
      fp = ws.forecast_project
      {
        id: ws.id,
        project_tracker_id: ws.project_tracker_id,
        name: fp&.name,
        code: fp&.code,
        client: fp&.forecast_client&.name,
        rates: Array(fp&.tags).select { |t| t.to_s.end_with?("p/h") }.map(&:to_f),
      }
    end
  end
end
