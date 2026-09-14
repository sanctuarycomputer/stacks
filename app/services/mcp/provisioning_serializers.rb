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
        # budget_low_end/budget_high_end are decimal columns; BigDecimal#as_json serializes
        # to a STRING (e.g. "1000.0"), same pitfall noted in InvoiceTracker's ic_share
        # comment — coerce to Float so these come back as JSON numbers.
        budget_low_end: tracker.budget_low_end&.to_f,
        budget_high_end: tracker.budget_high_end&.to_f,
        work_completed_at: tracker.work_completed_at,
        completed: tracker.work_completed_at.present?,
        msa_url: link_url(tracker, :msa),
        sow_url: link_url(tracker, :sow),
        account_lead: lead_json(tracker.account_lead_periods),
        project_lead: lead_json(tracker.project_lead_periods),
        workstreams: tracker.project_tracker_forecast_projects.map { |ws| workstream_json(ws) },
      }
    end

    def link_url(tracker, type)
      tracker.project_tracker_links.find { |l| l.link_type == type.to_s }&.url
    end

    # Current lead = the open period (ended_at nil); if several, the latest-started.
    def lead_json(periods)
      period = periods.select { |p| p.ended_at.nil? }.max_by { |p| p.started_at || Date.new(0) }
      return nil if period.nil?
      au = period.admin_user
      { name: au&.display_name, email: au&.email }
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
