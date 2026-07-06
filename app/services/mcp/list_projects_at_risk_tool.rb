module Mcp
  class ListProjectsAtRiskTool < MCP::Tool
    tool_name 'list_projects_at_risk'
    description 'Projects at risk, judged against each ProjectTracker\'s own configured targets ' \
                '(margin below target, free hours above target, spend beyond budget). Reads the ' \
                'nightly tracker snapshots — never live data. Sorted most-at-risk first.'
    input_schema(
      properties: {
        only_at_risk: { type: 'boolean', description: 'Default true. When false, returns every project in scope with metrics + targets.' },
        include_complete: { type: 'boolean', description: 'Default false. Include completed / capsule-pending projects.' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    ACTIVE_STATUSES = %i[in_progress likely_complete].freeze

    def self.call(only_at_risk: true, include_complete: false, server_context:)
      trackers = ProjectTracker.all.to_a
      ProjectTracker.preload_for_render(trackers)

      rows = trackers.filter_map do |pt|
        if pt.snapshot.blank?
          Rails.logger.warn("[Mcp::ListProjectsAtRiskTool] skipping '#{pt.name}' (id=#{pt.id}): no snapshot")
          next nil
        end

        status = pt.work_status
        next nil unless include_complete || ACTIVE_STATUSES.include?(status)

        # Risk = the tracker's own targets, via the model's own predicates
        # (single source of truth with considered_successful?). Each axis is
        # guarded against its nullable input: a NULL target column (legacy rows
        # — set_targets backfills the 0.0 default, not nil) would raise inside
        # the model predicate, and the per-row rescue below would then drop the
        # whole tracker, hiding its OTHER at-risk axes. Guarding keeps one bad
        # metric from blinding the report to a genuinely at-risk project. A
        # missing target also means "no target set → don't judge this axis,"
        # matching the model's own `target <= 0 → satisfied` semantics.
        reasons = []
        if pt.target_profit_margin.present?
          reasons << 'margin_below_target' unless pt.target_profit_margin_satisfied?
        end
        if pt.target_free_hours_percent.present?
          reasons << 'free_hours_above_target' unless pt.target_free_hours_ratio_satisfied?
        end
        # #status raises on a half-configured budget (exactly one bound set).
        if pt.budget_low_end.present? && pt.budget_high_end.present?
          reasons << 'over_budget' if pt.status == :over_budget
        end

        # considered_successful? re-runs the same target predicates, so it
        # raises on the same NULL-target rows the reasons block guards above.
        # A tracker with an unset target genuinely can't be judged successful
        # or not — emit null rather than raising (which would drop the row).
        both_targets_set = pt.target_profit_margin.present? && pt.target_free_hours_percent.present?
        considered_successful = both_targets_set ? pt.considered_successful? : nil

        {
          name: pt.name,
          work_status: status,
          spend: pt.spend.round(2),
          budget_low_end: pt.budget_low_end&.to_f,
          budget_high_end: pt.budget_high_end&.to_f,
          profit_margin: pt.profit_margin.to_f.round(1),
          target_profit_margin: pt.target_profit_margin.to_f,
          free_hours_percent: (pt.free_hours_ratio * 100).round(1),
          target_free_hours_percent: pt.target_free_hours_percent.to_f,
          considered_successful: considered_successful,
          at_risk: reasons.any?,
          risk_reasons: reasons,
          url: pt.external_link,
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::ListProjectsAtRiskTool] skipping tracker id=#{pt.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end

      rows = rows.select { |r| r[:at_risk] } if only_at_risk
      rows = rows.sort_by { |r| [-r[:risk_reasons].length, r[:name].to_s] }

      Responses.ok({ count: rows.length, projects: rows })
    end
  end
end
