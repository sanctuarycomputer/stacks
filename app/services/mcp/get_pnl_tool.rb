module Mcp
  class GetPnlTool < MCP::Tool
    tool_name 'get_pnl'
    description 'Profit & Loss (revenue, COGS, expenses, net revenue, profit margin) for an ' \
                'enterprise (whole entity) from the nightly-synced QBO P&L reports. Reads ' \
                'persisted reports only — never calls QBO live. Defaults to the most recent ' \
                'synced period.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Enterprise name (default: Sanctuary Computer Inc)' },
        accounting_method: { type: 'string', description: 'cash (default) or accrual' },
        start_date: { type: 'string', description: 'ISO period start; with end_date, selects an exact synced report' },
        end_date: { type: 'string', description: 'ISO period end' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    ACCOUNTING_METHODS = %w[cash accrual].freeze

    def self.call(enterprise: nil, accounting_method: 'cash', start_date: nil, end_date: nil, server_context:)
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end

      # Resolve enterprise (must have a qbo_account — P&L is per QBO realm).
      ent =
        if enterprise.present?
          matches, err = QboReceivables.resolve_enterprises(enterprise)
          return Responses.error(err) if err
          matches.first
        else
          Enterprise.sanctuary
        end

      # The default (Sanctuary) resolves without the joins(:qbo_account) filter
      # the named path uses, so guard against a missing account rather than
      # NoMethodError on ent.qbo_account.id.
      if ent.qbo_account.nil?
        return Responses.error("Enterprise '#{ent.name}' has no QBO account, so no P&L is available.")
      end

      reports = QboProfitAndLossReport.where(qbo_account_id: ent.qbo_account.id)
      if reports.none?
        return Responses.error("Enterprise '#{ent.name}' has no synced P&L reports yet.")
      end

      if start_date.present? ^ end_date.present?
        return Responses.error('Provide both start_date and end_date to select a specific period, or neither for the most recent.')
      end

      # Select the persisted report — explicit range (exact match, never fetch)
      # or the most recent. NEVER find_or_fetch_for_range (it fires live QBO).
      report =
        if start_date.present? || end_date.present?
          begin
            reports.find_by(starts_at: Date.parse(start_date.to_s), ends_at: Date.parse(end_date.to_s))
          rescue Date::Error, ArgumentError => e
            return Responses.error("Invalid date: #{e.message}. Use ISO format, e.g. 2026-06-01.")
          end
        else
          reports.order(:ends_at).last
        end

      if report.nil?
        available = reports.order(:ends_at).map { |r| "#{r.starts_at} to #{r.ends_at}" }.join(', ')
        return Responses.error("No P&L report synced for that range. Available: #{available}")
      end

      # A persisted report can have a NULL `data` column (jsonb, nullable), an
      # empty `data` (the schema default), or only one accounting method's key
      # populated (e.g. a legacy row synced before both methods were
      # captured). data_for_enterprise indexes data[method]["rows"]
      # unconditionally, so guard here — otherwise a NoMethodError on nil
      # escapes as an opaque 500 instead of a tool error.
      if report.data.blank? || report.data[method].blank? || report.data[method]['rows'].blank?
        return Responses.error("The synced P&L report for '#{ent.name}' (#{report.starts_at} to #{report.ends_at}) has no #{method} data.")
      end

      d = report.data_for_enterprise(ent, method, "", :All)
      revenue = d[:revenue].to_f
      # data_for_enterprise discards its own margin computation (returns 0) —
      # compute it here from the (sound) bucketed net_revenue/revenue.
      margin = revenue.positive? ? (d[:net_revenue].to_f / revenue * 100).round(1) : 0.0

      Responses.ok(
        enterprise: ent.name,
        accounting_method: method,
        period: { starts_at: report.starts_at.iso8601, ends_at: report.ends_at.iso8601 },
        revenue: revenue.round(2),
        cogs: d[:cogs].to_f.round(2),
        expenses: d[:expenses].to_f.round(2),
        net_revenue: d[:net_revenue].to_f.round(2),
        profit_margin: margin
      )
    end
  end
end
