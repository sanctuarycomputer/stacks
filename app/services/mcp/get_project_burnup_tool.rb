module Mcp
  class GetProjectBurnupTool < MCP::Tool
    extend TrackerResolution

    tool_name 'get_project_burnup'
    description 'Budget burn-up for a project tracker, as the admin tracker page shows it: ' \
                'cumulative income/spend/cost/hours series against the budget band, money ' \
                'totals (invoiced, running spend, estimated cost, profit, margin, commissions), ' \
                'overage vs each budget end, and the estimated weeks/months of budget left at ' \
                'the trailing 7/30-day spend rate. Series come from the nightly tracker snapshot.'
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
      if t.snapshot.blank?
        return Responses.error("Tracker '#{t.name}' has no generated snapshot yet; burn-up data is unavailable.")
      end

      spend = t.spend
      budget_low = t.budget_low_end&.to_f
      budget_high = t.budget_high_end&.to_f
      at_budget_overage = budget_low ? [spend - budget_low, 0].max : 0
      over_budget_overage = budget_high ? [spend - budget_high, 0].max : 0
      invoiced = t.income
      income_series = ProjectTrackers::IncomeSeries.call(t)

      Responses.ok({
        tracker: t.name,
        id: t.id,
        url: t.external_link,
        budget: { low: budget_low, high: budget_high },
        series: {
          income: income_series[:income],
          spend: Array(t.snapshot['spend']),
          cost: Array(t.snapshot['cost']),
          hours: Array(t.snapshot['hours']),
        },
        totals: {
          invoiced: invoiced,
          running_spend: (spend - invoiced).round(2),
          total_spend: spend,
          estimated_cost: t.estimated_cost,
          profit: t.profit.to_f.round(2),
          profit_margin: t.profit_margin.to_f.round(2),
          commissions: t.lifetime_commissions_paid.to_f.round(2),
        },
        overage: {
          at_budget: at_budget_overage.to_f.round(2),
          over_budget: over_budget_overage.to_f.round(2),
        },
        completion: completion_block(t, spend, budget_low, budget_high, at_budget_overage, over_budget_overage),
        # Invoice mirrors whose stored QBO data is blank are excluded from the
        # income series (never lazily synced) — this counts them.
        skipped_invoices: income_series[:skipped_invoices],
        # Legacy rows may carry exactly one budget end (they predate the
        # both-or-neither validation); ProjectTracker#status nil-compares on
        # them, so emit 'partial_budget' defensively without calling it.
        status: (budget_low.nil? ^ budget_high.nil?) ? 'partial_budget' : t.status,
        work_status: t.work_status,
        considered_successful: t.considered_successful?,
        generated_at: t.snapshot['generated_at'],
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetProjectBurnupTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_project_burnup failed; the error was logged')
    end

    # Mirrors _show.html.erb:343-386: no estimate unless there was spend in
    # the trailing 30 days and a budget exists; within budget-low the low end
    # is the reference, between low and high the high end is, and overbudget
    # projects get an overage (in the payload above) instead of a time
    # estimate. Divisions are guarded (nil, not Infinity — JSON can't carry
    # the admin page's float Infinity).
    def self.completion_block(t, spend, budget_low, budget_high, at_budget_overage, over_budget_overage)
      trailing_7d = t.trailing_7_days_value.to_f
      trailing_30d = t.trailing_30_days_value.to_f
      block = {
        trailing_7d_spend: trailing_7d.round(2),
        trailing_30d_spend: trailing_30d.round(2),
        weeks_left: nil,
        months_left: nil,
        budget_reference: nil,
      }
      return block unless trailing_30d.positive? && budget_low.present?

      remaining, reference =
        if at_budget_overage.zero?
          # A single-point budget (low == high) is labeled by its high end,
          # as the admin page does.
          [budget_low - spend, budget_low == budget_high ? 'budget_high_end' : 'budget_low_end']
        elsif over_budget_overage.positive? || budget_high.nil?
          # Overbudget — or a legacy one-sided budget with no high end to
          # reference — gets an overage (in the payload above), no estimate.
          [nil, nil]
        else
          [budget_high - spend, 'budget_high_end']
        end
      return block if remaining.nil?

      block[:weeks_left] = trailing_7d.positive? ? (remaining / trailing_7d).round(1) : nil
      block[:months_left] = (remaining / trailing_30d).round(1)
      block[:budget_reference] = reference
      block
    end
  end
end
