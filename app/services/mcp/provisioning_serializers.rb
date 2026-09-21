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
        monthly_budget_low_end: tracker.monthly_budget_low_end&.to_f,
        monthly_budget_high_end: tracker.monthly_budget_high_end&.to_f,
        considered_ongoing: tracker.considered_ongoing?,
        work_completed_at: tracker.work_completed_at,
        completed: tracker.work_completed_at.present?,
        msa_url: link_url(tracker, :msa),
        sow_url: link_url(tracker, :sow),
        # Every link, not just MSA/SOW: twist_channel and notion_homepage are
        # how Stacksbot finds a project's conversation without name-matching.
        links: tracker.project_tracker_links.map { |l| { name: l.name, url: public_url(l.url), link_type: l.link_type } },
        account_lead: lead_json(tracker.account_lead_periods),
        project_lead: lead_json(tracker.project_lead_periods),
        workstreams: tracker.project_tracker_forecast_projects.map { |ws| workstream_json(ws) },
      }
    end

    def link_url(tracker, type)
      public_url(tracker.project_tracker_links.find { |l| l.link_type == type.to_s }&.url)
    end

    # Links are validated credential-free on write now; legacy rows are
    # stripped defensively so a basic-auth staging URL never reaches a reader.
    def public_url(url)
      return nil if url.nil?
      parsed = URI.parse(url)
      return url if parsed.userinfo.blank?
      # `userinfo = nil` is a no-op in Ruby's URI; clearing the parts works.
      parsed.user = nil
      parsed.password = nil
      parsed.to_s
    rescue URI::InvalidURIError
      url
    end

    # One weekly ship row, shared by list_weekly_ships and get_project_burnup.
    # Callers must scope through WeeklyShip.corpus_eligible first.
    def weekly_ship_json(ship)
      return nil if ship.nil?
      doc = ship.document
      {
        id: ship.id,
        document_id: doc&.id,
        subject: doc&.title,
        sent_at: ship.sent_at,
        sent_by: ship.sent_by_name.presence || ship.sent_by_email,
        url: doc&.google_groups_permalink,
        matched_by: ship.matched_by,
        confidence: ship.confidence,
      }
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
