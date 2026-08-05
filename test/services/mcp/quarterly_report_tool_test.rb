require 'test_helper'

class Mcp::QuarterlyReportToolTest < ActiveSupport::TestCase
  def g3d_with_quarter!(label = 'Q2, 2026')
    _tb, g3d = make_studio!
    g3d.update!(snapshot: {
      'quarter' => [
        {
          'label' => label,
          'cash' => {
            'okrs' => {
              'Profit Margin' => { 'value' => 12.5, 'unit' => 'percentage', 'target' => 15.0, 'health' => 'at_risk', 'surplus' => -2.5, 'hint' => '12.5%' },
              'Successful Projects' => { 'value' => 80.0, 'unit' => 'percentage', 'health' => 'healthy' },
            },
          },
          'accrual' => { 'okrs' => {} },
        },
      ],
    })
    g3d
  end

  def report!(label: 'Q2, 2026', starts_at: Date.new(2026, 4, 1), blueprint: nil)
    r = PeriodicReport.create!(period_gradation: :quarter, period_starts_at: starts_at, period_label: label)
    r.update!(blueprint: blueprint) if blueprint
    r
  end

  def generated_blueprint
    {
      'generated_at' => '2026-07-05T00:00:00+00:00',
      'successful_projects' => 80.0,
      'gross_surplus' => 100_000.0,
      'net_profit_share_pool' => 24_000.0,
      'total_shares' => 400.0,
    }
  end

  def profit_share!(report, email:, shares:, amount:, accepted: false)
    enterprise = Enterprise.find_by(name: 'Test Ent') || Enterprise.create!(name: 'Test Ent')
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    ledger = Ledger.find_or_create_for(enterprise: enterprise, contributor: fp.contributor)
    ProfitShare.create!(
      periodic_report: report,
      ledger: ledger,
      amount: amount,
      accepted_at: accepted ? DateTime.now : nil,
      blueprint: {
        'email' => email,
        'tenure_multiplier' => 1.25,
        'effective_cost_of_living_index' => 56.3,
        'elevated_service_months' => 3,
        'shares' => shares,
      }
    )
  end

  test 'returns the collective OKR chips, blueprint, and per-contributor profit shares' do
    g3d_with_quarter!
    report = report!(blueprint: generated_blueprint)
    profit_share!(report, email: 'zoe@sanctuary.computer', shares: 250.0, amount: 15_000.0, accepted: true)
    profit_share!(report, email: 'ada@sanctuary.computer', shares: 150.0, amount: 9_000.0)

    payload = mcp_payload(Mcp::GetQuarterlyReportTool.call(server_context: {}))

    assert_equal 'Q2, 2026', payload['period_label']
    assert_equal '2026-04-01', payload['period_starts_at']
    assert_equal '2026-06-30', payload['period_ends_at']
    assert_equal 'g3d', payload['studio_tab']
    assert_equal 'garden3d', payload['studio']
    assert_equal 'cash', payload['accounting_method']

    assert_equal %w[profit_margin income_growth successful_projects successful_proposals lead_growth project_satisfaction],
      payload['okrs'].map { |r| r['datapoint'] }
    pm = payload['okrs'].find { |r| r['datapoint'] == 'profit_margin' }
    assert_equal 12.5, pm.dig('okr', 'value')
    assert_equal 15.0, pm.dig('okr', 'target')
    assert_nil payload['okrs'].find { |r| r['datapoint'] == 'lead_growth' }['okr'], 'missing OKRs stay nil rows'

    assert_equal true, payload['generated']
    bp = payload['blueprint']
    assert_equal 100_000.0, bp['gross_surplus']
    assert_equal 24_000.0, bp['net_profit_share_pool']
    assert_equal 400.0, bp['total_shares']
    assert_equal 80.0, bp['successful_projects']
    assert_equal '2026-07-05T00:00:00+00:00', bp['generated_at']

    # Person-level exposure is deliberate (transparency policy, spec section 7.1).
    assert_equal %w[ada@sanctuary.computer zoe@sanctuary.computer], payload['profit_shares'].map { |p| p['name'] }
    zoe = payload['profit_shares'].last
    assert_equal 1.25, zoe['tenure_multiplier']
    assert_equal 56.3, zoe['effective_cost_of_living_index']
    assert_equal 3, zoe['elevated_service_months']
    assert_equal 250.0, zoe['shares']
    assert_equal 15_000.0, zoe['amount']
    assert_equal true, zoe['accepted']
    assert_equal false, payload['profit_shares'].first['accepted']
  end

  test 'defaults to the latest GENERATED report, skipping newer not-yet-generated quarters' do
    g3d_with_quarter!
    report!(label: 'Q2, 2026', starts_at: Date.new(2026, 4, 1), blueprint: generated_blueprint)
    report!(label: 'Q3, 2026', starts_at: Date.new(2026, 7, 1)) # blueprint never generated

    payload = mcp_payload(Mcp::GetQuarterlyReportTool.call(server_context: {}))
    assert_equal 'Q2, 2026', payload['period_label']
  end

  test 'an explicitly requested not-generated report is graceful: generated false, nil blueprint' do
    g3d_with_quarter!('Q3, 2026')
    report!(label: 'Q3, 2026', starts_at: Date.new(2026, 7, 1))

    payload = mcp_payload(Mcp::GetQuarterlyReportTool.call(period_label: 'Q3, 2026', server_context: {}))
    assert_equal 'Q3, 2026', payload['period_label']
    assert_equal false, payload['generated']
    assert_nil payload['blueprint']
    assert_equal [], payload['profit_shares']
  end

  test 'unknown period_label errors listing the available labels' do
    g3d_with_quarter!
    report!(label: 'Q2, 2026')
    err = mcp_payload(Mcp::GetQuarterlyReportTool.call(period_label: 'Q9, 1999', server_context: {}))
    assert_includes err['error'], "Unknown period_label 'Q9, 1999'"
    assert_includes err['error'], 'Q2, 2026'
  end

  test 'invalid studio tab and accounting_method error listing valid values' do
    g3d_with_quarter!
    report!
    err = mcp_payload(Mcp::GetQuarterlyReportTool.call(studio: 'nope', server_context: {}))
    assert_includes err['error'], "Invalid studio 'nope'"
    assert_includes err['error'], 'g3d'
    err = mcp_payload(Mcp::GetQuarterlyReportTool.call(accounting_method: 'both', server_context: {}))
    assert_includes err['error'], "Invalid accounting_method 'both'"
  end

  test 'no reports at all errors instead of returning empty success' do
    err = mcp_payload(Mcp::GetQuarterlyReportTool.call(server_context: {}))
    assert_includes err['error'], 'No quarterly reports'
  end
end
