module Mcp
  # READ: ONE "Weekly Ship Gmail Autoformatter" block for an engagement, summed
  # across its trackers. A client email carries one numbers block even when the
  # work is split across a Design tracker and a Development tracker, so the
  # summing has to happen here, exactly, rather than in the agent's head.
  class GetWeeklyShipBlockTool < MCP::Tool
    extend TrackerResolution

    tool_name 'get_weekly_ship_block'
    description 'READ: the "Weekly Ship Gmail Autoformatter" block for an engagement as ONE ' \
                'block: pass trackers (ids or exact names) or a client (every open tracker ' \
                'for that client). Hours and money are summed across the trackers; a budget ' \
                'band or monthly budget prints only when every tracker carries it. Returns the ' \
                'block text to print verbatim, the summed numbers, weeks_left at the trailing ' \
                '7-day pace, considered_ongoing (any tracker), and the newest linked weekly ' \
                'ship. Use this for the "How we\'re tracking" section of a weekly ship.'
    input_schema(
      properties: {
        trackers: { type: 'array', items: { type: 'string' }, description: 'ProjectTracker ids or exact names (case-insensitive).' },
        client: { type: 'string', description: 'Client name (exact, case-insensitive); uses every open tracker for that client. Ignored when trackers is given.' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(trackers: nil, client: nil, server_context:)
      list = resolve(trackers, client)
      return list if list.is_a?(MCP::Tool::Response)

      numbers = ProjectTracker.weekly_ship_summary(list)
      last_ship = WeeklyShip.corpus_eligible
                            .where(project_tracker_id: list.map(&:id))
                            .includes(:document).order(sent_at: :desc).first
      Responses.ok({
        trackers: list.map { |t| { id: t.id, name: t.name, url: t.external_link, considered_ongoing: t.considered_ongoing? } },
        combined: {
          hours_7d: numbers[:hours_7d].round(2),
          spend_7d: numbers[:spend_7d].round(2),
          invoiced: numbers[:invoiced].round(2),
          running_spend: numbers[:running_spend].round(2),
          total_spend: numbers[:total_spend].round(2),
          budget: { low: numbers[:budget_low_end], high: numbers[:budget_high_end] },
          monthly_budget: { low: numbers[:monthly_budget_low_end], high: numbers[:monthly_budget_high_end] },
        },
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
      open = ProjectTracker.where(work_completed_at: nil).to_a.select { |t| t.derived_client&.name&.casecmp?(name) }
      return Responses.error("No open tracker for client '#{client}'. Use list_project_trackers to find one.") if open.empty?
      open
    end
  end
end
