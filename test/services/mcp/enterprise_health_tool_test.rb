require 'test_helper'

class Mcp::EnterpriseHealthToolTest < ActiveSupport::TestCase
  def month_entry(label, starts_at, ends_at, revenue:, cogs:, expenses:, growth: nil)
    {
      'label' => label,
      'period_starts_at' => starts_at,
      'period_ends_at' => ends_at,
      'verticals' => {
        'All' => {
          'cash' => {
            'datapoints' => {
              'revenue' => { 'value' => revenue, 'unit' => 'usd', 'growth' => growth },
              'cogs' => { 'value' => cogs, 'unit' => 'usd' },
              'expenses' => { 'value' => expenses, 'unit' => 'usd' },
              # The persisted margin is 0 until the nightly regenerate picks up
              # the D1 fix — the tool must compute margin itself, never trust this.
              'profit_margin' => { 'value' => 0, 'unit' => 'percentage' },
            },
          },
        },
      },
    }
  end

  def enterprise!(name: 'Index Space, LLC')
    Enterprise.create!(
      name: name,
      snapshot: {
        'generated_at' => '2026-07-01T00:00:00+00:00',
        'month' => [
          month_entry('May, 2026', '05/01/2026', '05/31/2026', revenue: 0, cogs: 50.0, expenses: 25.0),
          month_entry('June, 2026', '06/01/2026', '06/30/2026', revenue: 1000.0, cogs: 200.0, expenses: 100.0, growth: 10.0),
        ],
      }
    )
  end

  test 'echoes the entity and computes profit_margin in-tool (never the snapshot 0)' do
    enterprise!
    payload = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'Index Space, LLC', server_context: {}))
    assert_equal 'Index Space, LLC', payload['entity']
    assert_equal 'month', payload['gradation']
    assert_equal 'All', payload['vertical']
    assert_equal 'cash', payload['accounting_method']
    assert_equal 'operating', payload['margin_basis'],
      'All-vertical net/margin are operating figures (rev - cogs - exp), not QBO Net Income'
    assert_includes payload['available_verticals'], 'All'

    june = payload['periods'].last
    assert_equal 'June, 2026', june['label']
    assert_equal '06/01/2026', june['period_starts_at']
    assert_equal '06/30/2026', june['period_ends_at']
    assert_equal 1000.0, june['revenue']
    assert_equal 10.0, june['revenue_growth']
    assert_equal 200.0, june['cogs']
    assert_equal 100.0, june['expenses']
    assert_equal 700.0, june['net_revenue']
    assert_equal 70.0, june['profit_margin'], 'margin must be computed from the datapoints, not read as the snapshot 0'
  end

  test 'zero-revenue period returns nil profit_margin, not a division blowup' do
    enterprise!
    payload = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'Index Space, LLC', server_context: {}))
    may = payload['periods'].first
    assert_equal 0.0, may['revenue']
    assert_equal(-75.0, may['net_revenue'])
    assert_nil may['profit_margin']
    assert_nil may['revenue_growth']
  end

  test 'unknown entity errors listing the valid enterprise names' do
    enterprise!
    err = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'Nope Inc', server_context: {}))
    assert_includes err['error'], "Unknown entity 'Nope Inc'"
    assert_includes err['error'], 'Index Space, LLC'
    assert_includes err['error'], 'Sanctuary Computer Inc'
  end

  test 'unknown vertical errors listing available_verticals' do
    enterprise!
    err = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'Index Space, LLC', vertical: 'ZZ', server_context: {}))
    assert_includes err['error'], "Unknown vertical 'ZZ'"
    assert_includes err['error'], 'All'
  end

  test 'vertical validation reads the snapshot only — never the live discover_verticals P&L union' do
    ent = enterprise!
    QboAccount.create!(enterprise: ent, client_id: 'c', client_secret: 's', realm_id: "r#{SecureRandom.hex(3)}")
    Enterprise.any_instance.expects(:discover_verticals).never

    payload = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'Index Space, LLC', server_context: {}))
    assert_equal ['All'], payload['available_verticals'],
      'available_verticals come from the snapshot entries themselves'
  end

  test 'invalid gradation and accounting_method error listing valid values' do
    enterprise!
    err = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'Index Space, LLC', gradation: 'weekly', server_context: {}))
    assert_includes err['error'], "Invalid gradation 'weekly'"
    assert_includes err['error'], 'month'
    err = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'Index Space, LLC', accounting_method: 'both', server_context: {}))
    assert_includes err['error'], "Invalid accounting_method 'both'"
  end

  test 'an enterprise with no snapshot for the gradation errors instead of returning empty success' do
    Enterprise.create!(name: 'USB Club, LLC') # no snapshot
    err = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'USB Club, LLC', server_context: {}))
    assert_includes err['error'], 'no generated snapshot'
  end

  test 'raw_rows: true attaches the most recent cached P&L rows for the entity' do
    ent = enterprise!
    qa = QboAccount.create!(enterprise: ent, client_id: 'c', client_secret: 's', realm_id: "r#{SecureRandom.hex(3)}")
    QboProfitAndLossReport.create!(
      qbo_account: qa,
      starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31),
      data: { cash: { rows: [['Total Income', '500.0']] }, accrual: { rows: [] } },
    )
    QboProfitAndLossReport.create!(
      qbo_account: qa,
      starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
      data: { cash: { rows: [['Total Income', '1000.0'], ['Net Income', '700.0']] }, accrual: { rows: [] } },
    )

    payload = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'Index Space, LLC', raw_rows: true, server_context: {}))
    raw = payload['raw_rows']
    assert_equal '2026-06-30', raw['ends_at']
    assert_equal [['Total Income', '1000.0'], ['Net Income', '700.0']], raw['rows']

    without = mcp_payload(Mcp::GetEnterpriseHealthTool.call(entity: 'Index Space, LLC', server_context: {}))
    refute without.key?('raw_rows'), 'raw_rows must be opt-in'
  end
end
