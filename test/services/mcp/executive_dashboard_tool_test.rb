require 'test_helper'

class Mcp::ExecutiveDashboardToolTest < ActiveSupport::TestCase
  def okr(value:, target: 30, tolerance: 5, health: 'healthy', unit: 'percentage', surplus: 1.5, hint: 'a hint')
    { 'value' => value, 'target' => target, 'tolerance' => tolerance,
      'health' => health, 'unit' => unit, 'surplus' => surplus, 'hint' => hint }
  end

  def studio!(name:, mini_name:, okrs:, ytd_datapoints: {}, last_year_datapoints: {})
    Studio.create!(
      name: name, mini_name: mini_name,
      snapshot: {
        'finished_at' => '2026-08-01T05:00:00+00:00',
        'year' => [
          { 'label' => (Date.today.year - 1).to_s,
            'accrual' => { 'datapoints' => last_year_datapoints, 'okrs' => {} } },
          { 'label' => 'YTD',
            'accrual' => { 'datapoints' => ytd_datapoints, 'okrs' => okrs } },
        ],
      }
    )
  end

  def seed_dashboard_studios!
    studio!(
      name: 'garden3d', mini_name: 'g3d',
      okrs: {
        'Profit Margin' => okr(value: 22.0),
        'Income Growth' => okr(value: 12.0, target: 20, tolerance: 5),
        'Lead Growth' => okr(value: 8.0, target: 10, tolerance: 4),
        'Project Satisfaction' => okr(value: 4.6, unit: 'count'),
      },
      ytd_datapoints: {
        'income' => { 'value' => 600_000.0, 'unit' => 'usd' },
        'lead_count' => { 'value' => 40, 'unit' => 'count' },
      },
      last_year_datapoints: {
        'income' => { 'value' => 1_000_000.0, 'unit' => 'usd' },
        'lead_count' => { 'value' => 60, 'unit' => 'count' },
      }
    )
    studio!(name: 'XXIX', mini_name: 'xxix', okrs: {
      'Successful Projects' => okr(value: 80.0),
      'Successful Proposals' => okr(value: 50.0),
    })
    studio!(name: 'Sanctuary Computer', mini_name: 'sanctu', okrs: {
      'Successful Projects' => okr(value: 70.0),
      'Successful Proposals' => okr(value: 40.0),
    })
  end

  test 'returns the eight dashboard tiles from the YTD accrual snapshots; money is off by default' do
    seed_dashboard_studios!
    payload = mcp_payload(Mcp::GetExecutiveDashboardTool.call(server_context: {}))

    assert_equal %w[
      profit_margin income_growth successful_design_projects successful_development_projects
      successful_design_proposals successful_development_proposals lead_growth project_satisfaction
    ], payload['okr_tiles'].map { |t| t['name'] }, 'tile order must mirror app/admin/dashboard.rb'

    pm = payload['okr_tiles'].find { |t| t['name'] == 'profit_margin' }
    assert_equal 'g3d', pm['studio']
    assert_equal 22.0, pm['value']
    assert_equal 30, pm['target']
    assert_equal 5, pm['tolerance']
    assert_equal 'healthy', pm['health']
    assert_equal 'percentage', pm['unit']
    assert_equal 1.5, pm['surplus']
    assert_equal 'a hint', pm['hint']

    assert_equal 'xxix', payload['okr_tiles'].find { |t| t['name'] == 'successful_design_projects' }['studio']
    assert_equal 70.0, payload['okr_tiles'].find { |t| t['name'] == 'successful_development_projects' }['value']
    assert_equal 'sanctu', payload['okr_tiles'].find { |t| t['name'] == 'successful_development_proposals' }['studio']

    assert_equal '2026-08-01T05:00:00+00:00', payload['as_of']
    refute payload.key?('money'), 'money must be opt-in (include_money default false)'
  end

  test 'the two growth tiles carry growth_progress computed from last-year datapoints' do
    seed_dashboard_studios!
    payload = mcp_payload(Mcp::GetExecutiveDashboardTool.call(server_context: {}))

    income = payload['okr_tiles'].find { |t| t['name'] == 'income_growth' }
    gp = income['growth_progress']
    assert gp.present?, 'income_growth tile must carry growth_progress'
    assert_equal 1_200_000.0, gp.dig('eoy', 'mid'), 'eoy mid = last year income * (1 + target/100)'
    assert_equal 1_150_000.0, gp.dig('eoy', 'low')
    assert_equal 1_250_000.0, gp.dig('eoy', 'high')
    assert_equal 600_000.0, gp.dig('today', 'actual')
    assert gp.key?('health')
    assert_equal 'usd', gp['unit']

    lead = payload['okr_tiles'].find { |t| t['name'] == 'lead_growth' }
    assert lead['growth_progress'].present?
    assert_equal 40, lead['growth_progress'].dig('today', 'actual')

    refute payload['okr_tiles'].find { |t| t['name'] == 'profit_margin' }.key?('growth_progress'),
      'growth_progress belongs only to the two growth tiles'
  end

  test 'a missing OKR row or an entirely missing/empty studio snapshot skips those tiles without crashing' do
    seed_dashboard_studios!
    xxix = Studio.find_by(mini_name: 'xxix')
    snap = xxix.snapshot
    snap['year'].last['accrual']['okrs'].delete('Successful Proposals')
    xxix.update!(snapshot: snap)
    # sanctu with an empty snapshot: ytd_snapshot raises (snapshot['year'] is nil)
    Studio.find_by(mini_name: 'sanctu').update!(snapshot: {})

    payload = mcp_payload(Mcp::GetExecutiveDashboardTool.call(server_context: {}))
    names = payload['okr_tiles'].map { |t| t['name'] }
    refute_includes names, 'successful_design_proposals'
    refute_includes names, 'successful_development_projects'
    refute_includes names, 'successful_development_proposals'
    assert_includes names, 'profit_margin'
    assert_includes names, 'successful_design_projects'
  end

  test 'include_money: true returns the money block from cached P&L + stubbed QBO accounts (no live P&L fetch)' do
    seed_dashboard_studios!
    QboProfitAndLossReport.expects(:find_or_fetch_for_range).never

    fake = ->(name, type, classification, balance) {
      OpenStruct.new(name: name, account_type: type, classification: classification, current_balance: balance)
    }
    QboAccount.any_instance.stubs(:fetch_all_accounts).returns([
      fake.call('Chase Checking', 'Bank', 'Asset', BigDecimal('100000')),
      fake.call('Amex', 'Credit Card', 'Liability', BigDecimal('-5000')),
      fake.call('Sales', 'Income', 'Revenue', BigDecimal('999')),
    ])

    qbo_account = Enterprise.sanctuary.reload.qbo_account
    [1, 2, 3].each do |month|
      QboProfitAndLossReport.create!(
        qbo_account: qbo_account,
        starts_at: (Date.today - month.months).beginning_of_month,
        ends_at: (Date.today - month.months).end_of_month,
        data: { 'cash' => { 'rows' => [['Total Cost of Goods Sold', '100.0'], ['Total Expenses', '50.0']] },
                'accrual' => { 'rows' => [] } }
      )
    end

    payload = mcp_payload(Mcp::GetExecutiveDashboardTool.call(include_money: true, server_context: {}))
    money = payload['money']
    assert_equal 95_000.0, money['net_cash'], 'Bank + CC with Liabilities negated'
    assert_equal 150.0, money['avg_burn_3mo']
    assert_equal (95_000.0 / 150.0).round(2), money['runway_months']
    assert_equal false, money['degraded']
    assert_equal [
      { 'name' => 'Chase Checking', 'classification' => 'Asset', 'balance' => 100_000.0 },
      { 'name' => 'Amex', 'classification' => 'Liability', 'balance' => -5_000.0 },
    ], money['accounts'], 'only Bank/Credit Card accounts appear'
    assert_equal({ 'balance' => 0.0, 'unsettled' => 0.0 }, money['new_deal'])
  end

  test 'months with no cached P&L are skipped from the burn average; none cached means zero burn, nil runway' do
    seed_dashboard_studios!
    QboAccount.any_instance.stubs(:fetch_all_accounts).returns([
      OpenStruct.new(name: 'Chase', account_type: 'Bank', classification: 'Asset', current_balance: BigDecimal('1000')),
    ])
    qbo_account = Enterprise.sanctuary.reload.qbo_account
    [1, 3].each_with_index do |month, i|
      QboProfitAndLossReport.create!(
        qbo_account: qbo_account,
        starts_at: (Date.today - month.months).beginning_of_month,
        ends_at: (Date.today - month.months).end_of_month,
        data: { 'cash' => { 'rows' => [['Total Cost of Goods Sold', (i.zero? ? '300.0' : '100.0')], ['Total Expenses', '0.0']] },
                'accrual' => { 'rows' => [] } }
      )
    end

    money = mcp_payload(Mcp::GetExecutiveDashboardTool.call(include_money: true, server_context: {}))['money']
    assert_equal 200.0, money['avg_burn_3mo'], 'average over the cached months only (H1: never live-fetch missing ones)'
    assert_equal false, money['degraded']

    QboProfitAndLossReport.delete_all
    money = mcp_payload(Mcp::GetExecutiveDashboardTool.call(include_money: true, server_context: {}))['money']
    assert_equal 0.0, money['avg_burn_3mo']
    assert_nil money['runway_months']
    assert_equal false, money['degraded']
  end

  test 'a QBO failure degrades the money block to zeros with degraded: true, leaving tiles intact' do
    seed_dashboard_studios!
    QboAccount.any_instance.stubs(:fetch_all_accounts).raises(RuntimeError, 'qbo token expired')

    payload = mcp_payload(Mcp::GetExecutiveDashboardTool.call(include_money: true, server_context: {}))
    money = payload['money']
    assert_equal true, money['degraded']
    assert_equal 0.0, money['net_cash']
    assert_equal 0.0, money['avg_burn_3mo']
    assert_nil money['runway_months']
    assert_equal [], money['accounts']
    assert_equal({ 'balance' => 0.0, 'unsettled' => 0.0 }, money['new_deal'])
    assert_equal 8, payload['okr_tiles'].length, 'tiles must render even when QBO is down'
  end
end
