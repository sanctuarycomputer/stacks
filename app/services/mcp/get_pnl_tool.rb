module Mcp
  class GetPnlTool < MCP::Tool
    tool_name 'get_pnl'
    description 'Profit & Loss (revenue, COGS, expenses, net revenue, profit margin) for an ' \
                'enterprise (whole entity) from the nightly-synced QBO P&L reports. Reads ' \
                'persisted reports only — never calls QBO live. Defaults to the most recent ' \
                'synced MONTHLY period; pass period_type for quarter/year, or an explicit ' \
                'start_date+end_date for a specific report.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Enterprise name (default: Sanctuary Computer Inc)' },
        accounting_method: { type: 'string', description: 'cash (default) or accrual' },
        period_type: { type: 'string', description: 'month (default), quarter, or year — which granularity of the most-recent synced report to return (ignored when start_date/end_date are given)' },
        start_date: { type: 'string', description: 'ISO period start; with end_date, selects an exact synced report' },
        end_date: { type: 'string', description: 'ISO period end' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    ACCOUNTING_METHODS = %w[cash accrual].freeze
    # QBO reports are synced monthly + quarterly + yearly into ONE table with
    # no period-type column, so "most recent" must be scoped by the report's
    # span in days (the only discriminator). Ranges are well-separated:
    # month ≈ 27-30d, quarter ≈ 89-91d, year = 364d.
    PERIOD_SPAN_DAYS = { 'month' => (20..45), 'quarter' => (80..135), 'year' => (300..400) }.freeze

    def self.call(enterprise: nil, accounting_method: 'cash', period_type: 'month', start_date: nil, end_date: nil, server_context:)
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end
      ptype = period_type.to_s
      unless PERIOD_SPAN_DAYS.key?(ptype)
        return Responses.error("Invalid period_type '#{ptype}'. Valid: #{PERIOD_SPAN_DAYS.keys.join(', ')}")
      end

      # Resolve enterprise (must have a qbo_account — P&L is per QBO realm).
      ent =
        if enterprise.present?
          matches, err = QboReceivables.resolve_enterprises(enterprise)
          return Responses.error(err) if err
          if matches.size > 1
            return Responses.error("'#{enterprise}' matches #{matches.size} enterprises (#{matches.map(&:name).join(', ')}). This is ambiguous — the names collide; resolve the duplicate before querying P&L.")
          end
          matches.first
        else
          begin
            Enterprise.sanctuary
          rescue ActiveRecord::RecordNotFound
            return Responses.error('Default enterprise (Sanctuary Computer Inc) is not configured; pass an explicit enterprise.')
          end
        end

      # An enterprise can have more than one qbo_account (ent.qbo_account is a
      # has_one — arbitrary LIMIT 1 — so scoping by it alone can silently miss
      # reports synced under a second account). Scope by every qbo_account_id
      # belonging to this enterprise instead, matching how QboReceivables scopes.
      account_ids = QboAccount.where(enterprise_id: ent.id).ids
      if account_ids.empty?
        return Responses.error("Enterprise '#{ent.name}' has no QBO account, so no P&L is available.")
      end

      # v1 limitation: Enterprise has_one :qbo_account (one QBO realm is the
      # domain intent). Scoping across account_ids ensures we FIND the report
      # even if it's under a non-primary account, but if an enterprise genuinely
      # spans two realms with same-period reports, the single-report selection
      # below reports one realm — cross-realm P&L aggregation is out of scope
      # for v1 (would need summing two data blobs; deferred).
      reports = QboProfitAndLossReport.where(qbo_account_id: account_ids)

      if start_date.present? ^ end_date.present?
        return Responses.error('Provide both start_date and end_date to select a specific period, or neither for the most recent.')
      end

      explicit_range = start_date.present? || end_date.present?

      # Select the persisted report — explicit range (exact match, never fetch)
      # or the most recent of the requested period_type. The default path MUST
      # scope by span: the table mixes monthly/quarterly/yearly rows, and the
      # current year's report is future-dated (Dec 31), so an unscoped
      # order(:ends_at).last would return a whole-year P&L, not the latest month.
      # NEVER find_or_fetch_for_range (it fires live QBO).
      report =
        if explicit_range
          begin
            reports.find_by(starts_at: Date.parse(start_date.to_s), ends_at: Date.parse(end_date.to_s))
          rescue Date::Error, ArgumentError => e
            return Responses.error("Invalid date: #{e.message}. Use ISO format, e.g. 2026-06-01.")
          end
        else
          span = PERIOD_SPAN_DAYS[ptype]
          # Completed periods only: the sync also persists the CURRENT in-progress
          # period (e.g. a July report labeled ends_at Jul 31 that holds only a few
          # days of data), which would otherwise win order(:ends_at).last and report
          # a partial month's distorted revenue/margin. ends_at <= today keeps the
          # default to the most recent FULLY-ELAPSED period. (Use an explicit
          # start_date/end_date for the current period-to-date.)
          reports
            .where('(qbo_profit_and_loss_reports.ends_at - qbo_profit_and_loss_reports.starts_at) BETWEEN ? AND ?', span.min, span.max)
            .where('qbo_profit_and_loss_reports.ends_at <= ?', Date.today)
            .order(:ends_at)
            .last
        end

      if report.nil?
        if reports.none?
          return Responses.error("Enterprise '#{ent.name}' has no synced P&L reports yet.")
        elsif explicit_range
          available = reports.order(:ends_at).pluck(:starts_at, :ends_at).map { |s, e| "#{s} to #{e}" }.join(', ')
          return Responses.error("No P&L report synced for that range. Available: #{available}")
        else
          span = PERIOD_SPAN_DAYS[ptype]
          only_in_progress = reports
            .where('(qbo_profit_and_loss_reports.ends_at - qbo_profit_and_loss_reports.starts_at) BETWEEN ? AND ?', span.min, span.max)
            .where('qbo_profit_and_loss_reports.ends_at > ?', Date.today)
            .exists?
          if only_in_progress
            return Responses.error("Enterprise '#{ent.name}' has only an in-progress #{ptype} period synced (not yet complete). Pass explicit start_date + end_date for the current period-to-date.")
          end
          return Responses.error("Enterprise '#{ent.name}' has no synced #{ptype} P&L reports yet. Try period_type: #{(PERIOD_SPAN_DAYS.keys - [ptype]).join(' or ')}.")
        end
      end

      # A persisted report can have a NULL `data` column (jsonb, nullable), an
      # empty `data` (the schema default), only one accounting method's key
      # populated (legacy row), OR a non-Hash jsonb value (array/number from
      # sync drift). Type-check every level with is_a?(Hash) so the GUARD
      # itself can't raise on malformed data — data_for_enterprise indexes
      # data[method]["rows"] unconditionally, and the guard's own string
      # indexing would TypeError on a non-Hash, escaping as an opaque 500.
      method_data = report.data.is_a?(Hash) ? report.data[method] : nil
      unless method_data.is_a?(Hash) && method_data['rows'].present?
        return Responses.error("The synced P&L report for '#{ent.name}' (#{report.starts_at} to #{report.ends_at}) has no #{method} data.")
      end

      begin
        d = report.data_for_enterprise(ent, method, "", :All)
      rescue StandardError => e
        Rails.logger.warn("[Mcp::GetPnlTool] malformed P&L data for '#{ent.name}' (#{report.starts_at}..#{report.ends_at}): #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        return Responses.error("The synced P&L report for '#{ent.name}' (#{report.starts_at} to #{report.ends_at}) could not be read — its data appears malformed. The failure was logged.")
      end
      revenue = d[:revenue].to_f
      # data_for_enterprise discards its own margin computation (returns 0) —
      # compute it here from the (sound) bucketed net_revenue/revenue.
      margin = revenue.positive? ? (d[:net_revenue].to_f / revenue * 100).round(1) : 0.0

      Responses.ok(
        enterprise: ent.name,
        accounting_method: method,
        # The report's classified span — echoes the requested period_type on the
        # default path, and tells an explicit-range caller which granularity
        # they actually hit.
        period_type: PERIOD_SPAN_DAYS.find { |_t, span| span.cover?((report.ends_at - report.starts_at).to_i) }&.first || 'custom',
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
