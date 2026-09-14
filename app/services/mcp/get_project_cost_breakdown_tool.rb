module Mcp
  class GetProjectCostBreakdownTool < MCP::Tool
    extend TrackerResolution

    tool_name 'get_project_cost_breakdown'
    description 'Month-by-month estimated cost of servicing revenue for a project tracker, as ' \
                'the admin Project Cost Explorer shows it: per person per month — salary ' \
                'pro-rata for assigned full-timers, plus contributor payouts attributable to ' \
                'this tracker. Person-level amounts are deliberate (transparency policy). ' \
                'Computed live from assignments and payouts. EXPENSIVE (per-day queries ' \
                "over the tracker's whole assignment history): call sparingly, one tracker " \
                'at a time.'
    input_schema(
      properties: {
        tracker: { type: 'string', description: 'ProjectTracker id or exact name (case-insensitive). Required.' },
      },
      required: ['tracker']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(tracker:, server_context:)
      t = resolve_tracker(tracker)
      return unknown_tracker_error(tracker) unless t

      grand_total = 0.0
      # monthly_cosr returns { Date(end of month) => { ForecastPerson =>
      # { amount:, type: } } }, already sorted chronologically.
      months = t.monthly_cosr.map do |month, cosr|
        people = cosr.filter_map do |person, entry|
          {
            name: person.name,
            type: entry[:type],
            amount: entry[:amount].to_f.round(2),
          }
        rescue StandardError => e2
          Rails.logger.warn("[Mcp::GetProjectCostBreakdownTool] skipping person row: #{e2.class}: #{e2.message}")
          Sentry.capture_exception(e2) if defined?(Sentry)
          nil
        end.sort_by { |p| p[:name].to_s }
        total = people.sum { |p| p[:amount] }.round(2)
        grand_total += total
        { month: month.iso8601, people: people, total: total }
      end

      Responses.ok({
        tracker: t.name,
        id: t.id,
        url: t.external_link,
        months: months,
        total: grand_total.round(2),
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetProjectCostBreakdownTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_project_cost_breakdown failed; the error was logged')
    end
  end
end
