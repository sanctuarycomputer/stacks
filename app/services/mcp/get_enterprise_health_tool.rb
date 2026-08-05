module Mcp
  class GetEnterpriseHealthTool < MCP::Tool
    tool_name 'get_enterprise_health'
    description 'Per-legal-entity financial health from the nightly Enterprise snapshot ' \
                '(QBO P&L cache): revenue/cogs/expenses/net revenue/margin per period, ' \
                'per business vertical. Figures are as of the nightly sync.'
    GRADATIONS = Studio::SNAPSHOT_GRADATIONS.map(&:to_s).freeze
    ACCOUNTING_METHODS = %w[cash accrual].freeze

    input_schema(
      properties: {
        entity: { type: 'string', description: 'One of the four Enterprise names. Required.' },
        gradation: { type: 'string', description: "#{GRADATIONS.join(', ')} (default month)" },
        vertical: { type: 'string', description: 'A vertical tag (see available_verticals in output); default All' },
        accounting_method: { type: 'string', description: 'cash (default) | accrual' },
        periods: { type: 'integer', description: 'How many trailing periods, default 6, max 24' },
        raw_rows: { type: 'boolean', description: 'Include the raw cached P&L rows for the most recent period (label/value pairs). Default false.' },
      },
      required: ['entity']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(entity:, gradation: 'month', vertical: 'All', accounting_method: 'cash', periods: 6, raw_rows: false, server_context:)
      ent = Enterprise.find_by(name: entity)
      unless ent
        return Responses.error("Unknown entity '#{entity}'. Valid entities: #{Enterprise.order(:name).pluck(:name).join(', ')}")
      end
      gradation = gradation.to_s
      unless GRADATIONS.include?(gradation)
        return Responses.error("Invalid gradation '#{gradation}'. Valid gradations: #{GRADATIONS.join(', ')}")
      end
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end

      entries = Array(ent.snapshot.presence && ent.snapshot[gradation])
      if entries.empty?
        return Responses.error("Enterprise '#{ent.name}' has no generated snapshot for gradation '#{gradation}' yet.")
      end

      # Verticals present anywhere in this gradation's snapshot, plus any
      # discoverable from the cached P&L rows (an enterprise without a
      # qbo_account simply has none beyond All).
      available_verticals = (
        ['All'] +
        entries.flat_map { |e| e.is_a?(Hash) && e['verticals'].is_a?(Hash) ? e['verticals'].keys : [] } +
        (ent.qbo_account ? ent.discover_verticals : [])
      ).uniq
      unless available_verticals.include?(vertical)
        return Responses.error("Unknown vertical '#{vertical}'. Valid verticals: #{available_verticals.join(', ')}")
      end

      rows = entries.last(periods.to_i.clamp(1, 24)).filter_map do |e|
        dp = e.dig('verticals', vertical, method, 'datapoints')
        next nil unless dp
        revenue = dp.dig('revenue', 'value').to_f
        cogs = dp.dig('cogs', 'value').to_f
        expenses = dp.dig('expenses', 'value').to_f
        net = revenue - cogs - expenses
        {
          label: e['label'],
          period_starts_at: e['period_starts_at'],
          period_ends_at: e['period_ends_at'],
          revenue: revenue,
          revenue_growth: dp.dig('revenue', 'growth')&.to_f,
          cogs: cogs,
          expenses: expenses,
          net_revenue: net,
          # Computed here, never read from the snapshot: persisted margins are
          # 0 for any snapshot generated before the D1 fix regenerates them.
          profit_margin: revenue.positive? ? ((net / revenue) * 100).round(2) : nil,
        }
      rescue StandardError => e2
        Rails.logger.warn("[Mcp::GetEnterpriseHealthTool] skipping period: #{e2.class}: #{e2.message}")
        Sentry.capture_exception(e2) if defined?(Sentry)
        nil
      end

      payload = {
        entity: ent.name,
        gradation: gradation,
        vertical: vertical,
        accounting_method: method,
        available_verticals: available_verticals,
        periods: rows,
      }
      payload[:raw_rows] = latest_raw_rows(ent, method) if raw_rows
      Responses.ok(payload)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetEnterpriseHealthTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_enterprise_health failed; the error was logged')
    end

    # Cache-only read (hazard H1): find the most recent persisted P&L report —
    # never find_or_fetch_for_range, which calls live QBO and deletes rows.
    def self.latest_raw_rows(ent, accounting_method)
      return nil unless ent.qbo_account
      report = QboProfitAndLossReport.where(qbo_account: ent.qbo_account).order(ends_at: :desc).first
      return nil unless report
      {
        starts_at: report.starts_at,
        ends_at: report.ends_at,
        rows: Array(report.data.dig(accounting_method, 'rows')),
      }
    end
  end
end
