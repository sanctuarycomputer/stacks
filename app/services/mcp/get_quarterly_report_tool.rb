module Mcp
  class GetQuarterlyReportTool < MCP::Tool
    tool_name 'get_quarterly_report'
    description 'One quarterly PeriodicReport as the admin page shows it: the six collective ' \
                'OKR chips for a studio tab, the profit-share blueprint (gross surplus, pool, ' \
                'total shares), and the per-contributor share breakdown (tenure multiplier, ' \
                'cost-of-living index, shares, amount, acceptance). Person-level figures are ' \
                'deliberate (transparency policy). Defaults to the latest generated report.'
    STUDIO_TABS = PeriodicReport::STUDIO_TAB_KEYS
    ACCOUNTING_METHODS = %w[cash accrual].freeze

    input_schema(
      properties: {
        period_label: { type: 'string', description: "A report's period label, e.g. 'Q2, 2026'. Default: the latest generated report." },
        studio: { type: 'string', description: "Studio tab: #{PeriodicReport::STUDIO_TAB_KEYS.join(' | ')} (default g3d)" },
        accounting_method: { type: 'string', description: 'cash (default) | accrual' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(period_label: nil, studio: 'g3d', accounting_method: 'cash', server_context:)
      tab = studio.to_s.downcase.strip
      unless STUDIO_TABS.include?(tab)
        return Responses.error("Invalid studio '#{studio}'. Valid studio tabs: #{STUDIO_TABS.join(', ')}")
      end
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end

      reports = PeriodicReport.order(period_starts_at: :desc).to_a
      return Responses.error('No quarterly reports exist yet.') if reports.empty?

      report =
        if period_label.present?
          reports.find { |r| r.period_label == period_label } ||
            (return Responses.error("Unknown period_label '#{period_label}'. Available: #{reports.map(&:period_label).join(', ')}"))
        else
          # Latest GENERATED report (a freshly-minted quarter has no blueprint
          # yet); fall back to the latest report if none are generated.
          reports.find { |r| generated?(r) } || reports.first
        end

      scope_studio = PeriodicReport.scope_studio_from_param(tab)
      okrs = report.collective_okrs_for_studio_tab(method, tab, scope_studio)

      bp = report.blueprint.presence || {}
      shares = report.profit_shares_for_studio(scope_studio).filter_map do |ps|
        row_for(ps)
      end.sort_by { |row| row[:name].to_s }

      Responses.ok({
        period_label: report.period_label,
        period_starts_at: report.period.starts_at.iso8601,
        period_ends_at: report.period.ends_at.iso8601,
        studio_tab: tab,
        studio: scope_studio&.name || tab,
        accounting_method: method,
        okrs: okrs,
        generated: generated?(report),
        blueprint: generated?(report) ? {
          generated_at: bp['generated_at'],
          successful_projects: bp['successful_projects']&.to_f,
          gross_surplus: bp['gross_surplus']&.to_f,
          net_profit_share_pool: bp['net_profit_share_pool']&.to_f,
          total_shares: bp['total_shares']&.to_f,
        } : nil,
        profit_shares: shares,
        total_shares_for_studio: shares.sum { |row| row[:shares].to_f }.round(2),
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetQuarterlyReportTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_quarterly_report failed; the error was logged')
    end

    # "Generated" means the sync wrote real pool numbers — the failure path
    # writes only generated_at, and a fresh report has an empty blueprint.
    def self.generated?(report)
      report.blueprint.present? && !report.blueprint['gross_surplus'].nil?
    end

    def self.row_for(ps)
      bp = ps.blueprint.presence || {}
      {
        name: bp['email'].presence || ps.contributor&.forecast_person&.email,
        tenure_multiplier: bp['tenure_multiplier']&.to_f,
        effective_cost_of_living_index: bp['effective_cost_of_living_index']&.to_f,
        elevated_service_months: bp['elevated_service_months'],
        shares: bp['shares']&.to_f,
        amount: ps.amount.to_f.round(2),
        accepted: ps.accepted?,
      }
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetQuarterlyReportTool] skipping profit share ##{ps.id}: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      nil
    end
  end
end
