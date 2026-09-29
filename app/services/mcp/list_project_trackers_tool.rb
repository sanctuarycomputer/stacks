module Mcp
  class ListProjectTrackersTool < MCP::Tool
    tool_name 'list_project_trackers'
    description 'READ: list project trackers, optionally filtered by name or client ' \
                '(both exact, case-insensitive), or to the Active tab with in_progress: true ' \
                '(not complete, not dormant). Each tracker includes its nested ' \
                'workstreams (id, name, code, rates), its last weekly ship (sent_at, sent_by, ' \
                'subject, url, grade; subject/url/grade are null when that email is walled from ' \
                'the corpus; grade is null until the nightly grader has scored it: stars 1-5, ' \
                'summary, suggestions for the sender), ' \
                'and ship_status: fresh (last ship within 10 days of the last recorded hour), ' \
                'stale (over 10), overdue (over 30), never, or internal (our own companies, ' \
                'which do not send client ships). Use to find a tracker id, to inspect existing ' \
                'workstreams/rates before ensuring one, or to see which projects owe a ship. ' \
                'With include_hours_by_studio: true, each tracker also carries hours_by_studio_90d ' \
                '({ studio name => scheduled hours over the last 90 days }), computed in one query.'
    input_schema(
      properties: {
        name: { type: 'string' },
        client: { type: 'string' },
        in_progress: { type: 'boolean', description: 'true: only trackers on the Active tab (not complete, not dormant)' },
        include_hours_by_studio: { type: 'boolean', description: 'true: add hours_by_studio_90d to each tracker (scheduled Forecast hours per studio, last 90 days)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(name: nil, client: nil, in_progress: nil, include_hours_by_studio: nil, server_context:)
      # Preload what tracker_json, internal_client? and the lead columns read, so an unfiltered
      # call (the checklist workflows list every tracker) stays a handful of queries.
      trackers = ProjectTracker.includes(
        :project_tracker_links,
        { forecast_projects: :forecast_client },
        { project_tracker_forecast_projects: { forecast_project: :forecast_client } },
        { account_lead_periods: :admin_user },
        { project_lead_periods: :admin_user },
      )
      trackers = trackers.where(id: ProjectTracker.in_progress.select(:id)) if in_progress == true
      if client.present?
        client_ids = ForecastClient.where("lower(name) = ?", client.strip.downcase).select(:forecast_id)
        fp_ids = ForecastProject.where(client_id: client_ids).select(:forecast_id)
        trackers = trackers.where(id: ProjectTrackerForecastProject.where(forecast_project_id: fp_ids).select(:project_tracker_id))
      end
      trackers = trackers.where("lower(name) = ?", name.strip.downcase) if name.present?
      trackers = trackers.to_a

      ships = WeeklyShip.includes(:document).latest_by_tracker(trackers.map(&:id))
      eligible_doc_ids = Document.corpus_eligible.where(id: ships.values.map(&:document_id)).pluck(:id).to_set
      studio_hours = include_hours_by_studio == true ? hours_by_studio(trackers) : nil

      Responses.ok(trackers.map do |t|
        ship = ships[t.id]
        internal = t.internal_client?
        ProvisioningSerializers.tracker_json(t).merge(
          internal: internal,
          last_weekly_ship: last_ship_json(ship, eligible_doc_ids),
          ship_status: internal ? :internal : ProjectTracker.ship_staleness(ship, anchor: t.last_recorded_forecast_date),
        ).merge(studio_hours ? { hours_by_studio_90d: studio_hours[t.id] || {} } : {})
      end)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ListProjectTrackersTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("list_project_trackers failed; the error was logged")
    end

    # Scheduled Forecast hours per studio over the last 90 days, for every tracker at once: ONE assignments query
    # (a person's studio comes from their roles against Studio.all, loaded once), so a caller listing every live
    # tracker (the daily entity-registry build) pays one query, not one per tracker. Same arithmetic as
    # ProjectTracker#total_hours_during_range_by_studio.
    def self.hours_by_studio(trackers, since: 90.days.ago.to_date, till: Date.today)
      studios = Studio.all.to_a
      fp_by_tracker = trackers.to_h { |t| [t.id, t.forecast_projects.map(&:forecast_id)] }
      assignments = ForecastAssignment.includes(:forecast_person)
        .where(project_id: fp_by_tracker.values.flatten.uniq)
        .where('end_date >= ? AND start_date <= ?', since, till)
        .group_by(&:project_id)
      fp_by_tracker.transform_values do |fp_ids|
        fp_ids.flat_map { |id| assignments[id] || [] }.each_with_object(Hash.new(0)) do |a, acc|
          studio = a.forecast_person&.studio(studios)
          next unless studio
          acc[studio.name] += a.allocation_during_range_in_hours(since, till)
        end.transform_values { |h| h.round(1) }
      end
    end

    # The newest linked ship, walled or not: its date is what says whether the
    # project shipped. A walled email keeps its subject and permalink hidden,
    # matching what get_document refuses to return.
    def self.last_ship_json(ship, eligible_doc_ids)
      return nil if ship.nil?
      visible = eligible_doc_ids.include?(ship.document_id)
      {
        sent_at: ship.sent_at,
        sent_by: ship.sent_by_name.presence || ship.sent_by_email,
        subject: visible ? ship.document&.title : nil,
        url: visible ? ship.document&.google_groups_permalink : nil,
        # The grade is read from the email's text, so it is walled with it.
        grade: visible ? ship.grade_json : nil,
      }
    end
  end
end
