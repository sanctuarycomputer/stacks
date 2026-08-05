module Mcp
  class GetExecutiveDashboardTool < MCP::Tool
    tool_name 'get_executive_dashboard'
    description 'The collective /admin/dashboard as data: the 8 YTD OKR tiles (accrual, from the ' \
                'nightly Studio snapshots — g3d profit margin/growth/satisfaction, per-studio ' \
                'successful projects & proposals) plus, only when include_money is true, the ' \
                'Money at a Glance block (net cash from live QBO account balances, 3-month ' \
                'average burn from the cached P&L, runway months). Money is 24h-cached and ' \
                'degrades to zeros with degraded: true when QBO is unreachable.'

    # The 8 tiles exactly as app/admin/dashboard.rb:12-63 builds them: which
    # studio's YTD accrual snapshot each reads, which OKR row, and (for the two
    # growth tiles) which datapoint feeds Okr.make_annual_growth_progress_data.
    TILES = [
      { name: 'profit_margin', studio: 'g3d', okr: 'Profit Margin' },
      { name: 'income_growth', studio: 'g3d', okr: 'Income Growth', growth: { datapoint: 'income', unit: :usd } },
      { name: 'successful_design_projects', studio: 'xxix', okr: 'Successful Projects' },
      { name: 'successful_development_projects', studio: 'sanctu', okr: 'Successful Projects' },
      { name: 'successful_design_proposals', studio: 'xxix', okr: 'Successful Proposals' },
      { name: 'successful_development_proposals', studio: 'sanctu', okr: 'Successful Proposals' },
      { name: 'lead_growth', studio: 'g3d', okr: 'Lead Growth', growth: { datapoint: 'lead_count', unit: :count } },
      { name: 'project_satisfaction', studio: 'g3d', okr: 'Project Satisfaction' },
    ].freeze

    # The admin dashboard's money block keys its cache on the session
    # accounting method; the tool has no session, so it pins the default.
    MONEY_ACCOUNTING_METHOD = 'cash'.freeze

    input_schema(
      properties: {
        include_money: { type: 'boolean', description: 'Include the Money at a Glance block (net cash, burn, runway, account balances). Makes a live QBO call (24h-cached). Default false.' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(include_money: false, server_context:)
      studios_by_mini = Studio.where(mini_name: %w[g3d xxix sanctu]).index_by(&:mini_name)

      tiles = TILES.filter_map do |tile|
        studio = studios_by_mini[tile[:studio]]
        next nil unless studio
        okr = studio.ytd_snapshot.dig('accrual', 'okrs', tile[:okr])
        next nil unless okr
        row = {
          name: tile[:name],
          studio: tile[:studio],
          value: okr['value'],
          target: okr['target'],
          tolerance: okr['tolerance'],
          health: okr['health'],
          unit: okr['unit'],
          surplus: okr['surplus'],
          hint: okr['hint'],
        }
        if tile[:growth]
          gp = growth_progress_for(studio, okr, tile[:growth])
          row[:growth_progress] = gp if gp
        end
        row
      rescue StandardError => e
        Rails.logger.warn("[Mcp::GetExecutiveDashboardTool] skipping tile '#{tile[:name]}': #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end

      payload = {
        as_of: studios_by_mini['g3d']&.snapshot&.dig('finished_at') || Date.today.iso8601,
        okr_tiles: tiles,
      }
      payload[:money] = money_block if include_money
      Responses.ok(payload)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetExecutiveDashboardTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_executive_dashboard failed; the error was logged')
    end

    # Mirrors app/admin/dashboard.rb:17-34 for the two annual-growth tiles.
    # Computed defensively: a snapshot missing the datapoint would nil-crash
    # inside make_annual_growth_progress_data, which must cost only the
    # growth_progress key, never the tile.
    def self.growth_progress_for(studio, okr, growth)
      Okr.make_annual_growth_progress_data(
        okr['target'].to_f.round(2),
        okr['tolerance'].to_f.round(2),
        studio.last_year_snapshot.dig('accrual', 'datapoints', growth[:datapoint], 'value'),
        studio.ytd_snapshot.dig('accrual', 'datapoints', growth[:datapoint], 'value'),
        growth[:unit]
      ).deep_stringify_keys
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetExecutiveDashboardTool] growth_progress for '#{growth[:datapoint]}' failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      nil
    end

    # Mirrors app/admin/dashboard.rb:66-152 under the tool's OWN cache key —
    # the tool computes a different burn than the admin page (cache-only vs
    # fetch-on-miss), so sharing the admin's key would poison whichever
    # surface reads second. Deliberate divergence (hazard H1): burn comes
    # from the persisted P&L cache via find_by — never find_or_fetch_for_range
    # (live QBO + delete_all on force). A month with no cached report is
    # skipped from the average; months_used makes such degraded averages
    # visible. On any QBO failure: zeros + degraded: true (the admin page's
    # own precedent), so the tiles still render.
    def self.money_block
      cached = Rails.cache.fetch(['mcp/dashboard/money', MONEY_ACCOUNTING_METHOD, Date.current], expires_in: 24.hours) do
        qbo_account = Enterprise.sanctuary.qbo_account
        raise 'Sanctuary enterprise has no qbo_account' unless qbo_account

        cc_or_bank_accounts = qbo_account.fetch_all_accounts.select do |a|
          ['Bank', 'Credit Card'].include?(a.account_type)
        end
        net_cash = cc_or_bank_accounts.map do |a|
          a.classification == 'Liability' ? -1 * a.current_balance.abs : a.current_balance
        end.reduce(0, :+)

        burn_rates = [1, 2, 3].filter_map do |month|
          report = QboProfitAndLossReport.find_by(
            qbo_account: qbo_account,
            starts_at: (Date.today - month.months).beginning_of_month,
            ends_at: (Date.today - month.months).end_of_month
          )
          next nil unless report
          report.find_row(MONEY_ACCOUNTING_METHOD, 'Total Cost of Goods Sold') +
            report.find_row(MONEY_ACCOUNTING_METHOD, 'Total Expenses')
        end
        average_burn_rate = burn_rates.empty? ? 0.0 : burn_rates.sum(0.0) / burn_rates.length

        ledger = Contributor.aggregated_new_deal_balance

        {
          account_rows: cc_or_bank_accounts.map do |a|
            { 'name' => a.name, 'classification' => a.classification, 'current_balance' => a.current_balance.to_f }
          end,
          net_cash: net_cash.to_f,
          average_burn_rate: average_burn_rate.to_f,
          months_used: burn_rates.length,
          aggregated_new_deal_balance: { balance: ledger[:balance].to_f, unsettled: ledger[:unsettled].to_f },
        }
      end

      burn = cached[:average_burn_rate].to_f
      net_cash = cached[:net_cash].to_f
      {
        net_cash: net_cash,
        avg_burn_3mo: burn,
        months_used: cached[:months_used].to_i,
        runway_months: burn.positive? ? (net_cash / burn).round(2) : nil,
        accounts: cached[:account_rows].map do |row|
          { name: row['name'], classification: row['classification'], balance: row['current_balance'] }
        end,
        new_deal: {
          balance: cached[:aggregated_new_deal_balance][:balance],
          unsettled: cached[:aggregated_new_deal_balance][:unsettled],
        },
        degraded: false,
      }
    rescue StandardError => e
      Rails.logger.error("[Mcp::GetExecutiveDashboardTool] QBO money block failed — returning zeros: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      {
        net_cash: 0.0,
        avg_burn_3mo: 0.0,
        months_used: 0,
        runway_months: nil,
        accounts: [],
        new_deal: { balance: 0.0, unsettled: 0.0 },
        degraded: true,
      }
    end
  end
end
