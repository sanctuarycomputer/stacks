module Mcp
  # READ: ONE "Weekly Ship Gmail Autoformatter" block for an engagement, summed
  # across its trackers. A client email carries one numbers block even when the
  # work is split across a Design tracker and a Development tracker, so the
  # summing has to happen here, exactly, rather than in the agent's head.
  class GetWeeklyShipBlockTool < MCP::Tool
    extend TrackerResolution

    tool_name 'get_weekly_ship_block'
    description 'READ: the "Weekly Ship Gmail Autoformatter" block for an engagement as ONE ' \
                'block. Prefer trackers (ids or exact names: the engagement you mean); client ' \
                'is a fallback that takes every open tracker for that client, which can mix ' \
                'unrelated engagements. Hours and money are summed; a budget band or monthly ' \
                'budget prints only when EVERY tracker carries it, and each tracker entry ' \
                'says whether it has one so a dropped band is visible. Returns the block text ' \
                'to print verbatim, the summed numbers, weeks_left at the trailing 7-day pace, ' \
                'considered_ongoing (any tracker), and the newest linked weekly ship. Errors ' \
                'if any tracker has no nightly snapshot yet (its money would read as $0).'
    input_schema(
      properties: {
        trackers: { type: 'array', items: { type: 'string' }, description: 'ProjectTracker ids or exact names (case-insensitive). Preferred.' },
        client: { type: 'string', description: 'Client name (exact, case-insensitive); every open tracker for that client. Ignored when trackers is given.' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(trackers: nil, client: nil, server_context:)
      list = resolve(trackers, client)
      return list if list.is_a?(MCP::Tool::Response)

      unsnapshotted = list.find { |t| t.snapshot.blank? }
      if unsnapshotted
        return Responses.error("Tracker '#{unsnapshotted.name}' has no generated snapshot yet; its invoiced and " \
                               'spend figures would read as $0. Wait for the nightly sync or leave it out of trackers.')
      end

      numbers = ProjectTracker.weekly_ship_summary(list)
      last_ship = WeeklyShip.corpus_eligible
                            .where(project_tracker_id: list.map(&:id))
                            .includes(:document).order(sent_at: :desc).first
      Responses.ok({
        trackers: list.map do |t|
          {
            id: t.id, name: t.name, url: t.external_link,
            considered_ongoing: t.considered_ongoing?,
            has_budget: t.overall_budget?,
            has_monthly_budget: t.monthly_budget?,
          }
        end,
        combined: {
          hours_7d: numbers[:hours_7d].round(2),
          spend_7d: numbers[:spend_7d].round(2),
          invoiced: numbers[:invoiced].round(2),
          running_spend: numbers[:running_spend].round(2),
          total_spend: numbers[:total_spend].round(2),
          budget: { low: numbers[:budget_low_end], high: numbers[:budget_high_end] },
          monthly_budget: { low: numbers[:monthly_budget_low_end], high: numbers[:monthly_budget_high_end] },
        },
        # True when the band or monthly budget was dropped because only SOME
        # trackers carry it; the agent should narrow `trackers` or say so.
        budget_dropped: list.any?(&:overall_budget?) && !list.all?(&:overall_budget?),
        monthly_budget_dropped: list.any?(&:monthly_budget?) && !list.all?(&:monthly_budget?),
        weekly_ship_block: ProjectTracker.render_weekly_ship_block(numbers),
        weeks_left: ProjectTracker.weekly_ship_weeks_left(numbers),
        considered_ongoing: list.any?(&:considered_ongoing?),
        last_weekly_ship: ProvisioningSerializers.weekly_ship_json(last_ship),
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetWeeklyShipBlockTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_weekly_ship_block failed; the error was logged')
    end

    def self.resolve(trackers, client)
      refs = Array(trackers).map { |r| r.to_s.strip }.reject(&:empty?)
      if refs.any?
        found = refs.map { |ref| [ref, resolve_tracker(ref)] }
        missing = found.select { |_, t| t.nil? }.map(&:first)
        return unknown_tracker_error(missing.first) if missing.any?
        return found.map(&:last).uniq
      end
      name = client.to_s.strip
      return Responses.error('Pass trackers (ids or names) or a client name.') if name.empty?
      # Same membership rule as list_project_trackers: a tracker belongs to the
      # client when ANY of its Forecast projects does (derived_client would use
      # only the first one and disagree with the list tool).
      client_ids = ForecastClient.where('lower(name) = ?', name.downcase).select(:forecast_id)
      fp_ids = ForecastProject.where(client_id: client_ids).select(:forecast_id)
      open = ProjectTracker.where(work_completed_at: nil)
                           .where(id: ProjectTrackerForecastProject.where(forecast_project_id: fp_ids).select(:project_tracker_id))
                           .order(:id).to_a
      return Responses.error("No open tracker for client '#{client}'. Use list_project_trackers to find one.") if open.empty?
      open
    end
  end
end
