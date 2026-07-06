module Mcp
  class GetPnlTool < MCP::Tool
    tool_name 'get_pnl'
    description 'Profit & Loss (revenue, COGS, expenses, net revenue, profit margin) for an ' \
                'enterprise from the nightly-synced QBO P&L reports. Reads persisted reports ' \
                'only — never calls QBO live. Defaults to the most recent synced period.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Enterprise name (default: Sanctuary Computer Inc)' },
        accounting_method: { type: 'string', description: 'cash (default) or accrual' },
        start_date: { type: 'string', description: 'ISO period start; with end_date, selects an exact synced report' },
        end_date: { type: 'string', description: 'ISO period end' },
        vertical: { type: 'string', description: 'Vertical tag within a combined P&L (e.g. SC, XXIX); default All (whole entity)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    ACCOUNTING_METHODS = %w[cash accrual].freeze

    def self.call(enterprise: nil, accounting_method: 'cash', start_date: nil, end_date: nil, vertical: 'All', server_context:)
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end

      # Resolve enterprise (must have a qbo_account — P&L is per QBO realm).
      accounts_by_enterprise = Enterprise.joins(:qbo_account).distinct.to_a
      ent =
        if enterprise.present?
          match = accounts_by_enterprise.find { |e| e.name.to_s.casecmp?(enterprise.to_s.strip) }
          unless match
            valid = accounts_by_enterprise.map(&:name).sort.join(', ')
            return Responses.error("Unknown enterprise '#{enterprise}'. Valid enterprises: #{valid}")
          end
          match
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

      # Select the persisted report — explicit range (exact match, never fetch)
      # or the most recent. NEVER find_or_fetch_for_range (it fires live QBO).
      report =
        if start_date.present? || end_date.present?
          reports.find_by(starts_at: Date.parse(start_date.to_s), ends_at: Date.parse(end_date.to_s))
        else
          reports.order(:ends_at).last
        end

      if report.nil?
        available = reports.order(:ends_at).map { |r| "#{r.starts_at} to #{r.ends_at}" }.join(', ')
        return Responses.error("No P&L report synced for that range. Available: #{available}")
      end

      vertical_sym = vertical.to_s.presence&.to_sym || :All
      d = report.data_for_enterprise(ent, method, "", vertical_sym)
      revenue = d[:revenue].to_f
      # data_for_enterprise discards its own margin computation (returns 0) —
      # compute it here from the (sound) bucketed net_revenue/revenue.
      margin = revenue.positive? ? (d[:net_revenue].to_f / revenue * 100).round(1) : 0.0

      Responses.ok(
        enterprise: ent.name,
        accounting_method: method,
        vertical: vertical.to_s,
        period: { starts_at: report.starts_at.iso8601, ends_at: report.ends_at.iso8601 },
        revenue: revenue.round(2),
        cogs: d[:cogs].to_f.round(2),
        expenses: d[:expenses].to_f.round(2),
        net_revenue: d[:net_revenue].to_f.round(2),
        profit_margin: margin
      )
    rescue Date::Error, ArgumentError => e
      Responses.error("Invalid date: #{e.message}. Use ISO format, e.g. 2026-06-01.")
    end
  end
end
