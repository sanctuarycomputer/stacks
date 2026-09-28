module Mcp
  class ListProjectTrackersTool < MCP::Tool
    tool_name 'list_project_trackers'
    description 'READ: list project trackers, optionally filtered by name or client ' \
                '(both exact, case-insensitive), or to the Active tab with in_progress: true ' \
                '(not complete, not dormant). Each tracker includes its nested ' \
                'workstreams (id, name, code, rates), its last weekly ship (sent_at, sent_by, ' \
                'subject, url; subject/url are null when that email is walled from the corpus), ' \
                'and ship_status: fresh (last ship within 10 days of the last recorded hour), ' \
                'stale (over 10), overdue (over 30), never, or internal (our own companies, ' \
                'which do not send client ships). Use to find a tracker id, to inspect existing ' \
                'workstreams/rates before ensuring one, or to see which projects owe a ship.'
    input_schema(
      properties: {
        name: { type: 'string' },
        client: { type: 'string' },
        in_progress: { type: 'boolean', description: 'true: only trackers on the Active tab (not complete, not dormant)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(name: nil, client: nil, in_progress: nil, server_context:)
      trackers = ProjectTracker.includes(:project_tracker_links)
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

      Responses.ok(trackers.map do |t|
        ship = ships[t.id]
        internal = t.internal_client?
        ProvisioningSerializers.tracker_json(t).merge(
          internal: internal,
          last_weekly_ship: last_ship_json(ship, eligible_doc_ids),
          ship_status: internal ? :internal : ProjectTracker.ship_staleness(ship, anchor: t.last_recorded_forecast_date),
        )
      end)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ListProjectTrackersTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("list_project_trackers failed; the error was logged")
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
      }
    end
  end
end
