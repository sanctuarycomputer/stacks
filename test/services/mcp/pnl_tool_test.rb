require 'test_helper'

class Mcp::PnlToolTest < ActiveSupport::TestCase
  def qbo_account_for(enterprise)
    enterprise.qbo_account ||
      QboAccount.create!(enterprise: enterprise, client_id: 'x', client_secret: 'x',
                         realm_id: "realm-#{SecureRandom.hex(3)}")
  end

  # A persisted P&L report with the QBO row shape data_for_enterprise reads.
  def pnl_report!(enterprise:, starts_at:, ends_at:, income:, cogs:, expenses:)
    rows = [
      ['Total Income', income],
      ['Total Cost of Goods Sold', cogs],
      ['Total Expenses', expenses],
      ['Net Income', income - cogs - expenses],
    ]
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account_for(enterprise),
      starts_at: starts_at, ends_at: ends_at,
      data: { 'cash' => { 'rows' => rows }, 'accrual' => { 'rows' => rows } }
    )
  end

  setup { @sanctuary = enterprises(:sanctuary) }

  test 'returns bucketed P&L with a tool-computed margin (not the model bug 0)' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 100_000.0, cogs: 40_000.0, expenses: 20_000.0)
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_equal 'Sanctuary Computer Inc', payload['enterprise']
    assert_equal 'cash', payload['accounting_method']
    assert_equal 100_000.0, payload['revenue']
    assert_equal 40_000.0, payload['cogs']
    assert_equal 20_000.0, payload['expenses']
    assert_equal 40_000.0, payload['net_revenue']
    assert_equal 40.0, payload['profit_margin'] # 40k/100k*100 — NOT the model's 0
  end

  test 'never triggers a live fetch' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 10.0, cogs: 1.0, expenses: 1.0)
    QboProfitAndLossReport.expects(:find_or_fetch_for_range).never
    Mcp::GetPnlTool.call(server_context: {})
  end

  test 'defaults to the most recent persisted report' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31),
                income: 1.0, cogs: 0.0, expenses: 0.0)
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 2.0, cogs: 0.0, expenses: 0.0)
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_equal '2026-06-30', payload['period']['ends_at']
    assert_equal 2.0, payload['revenue']
  end

  test 'accrual accounting_method is selectable' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 5.0, cogs: 0.0, expenses: 0.0)
    payload = mcp_payload(Mcp::GetPnlTool.call(accounting_method: 'accrual', server_context: {}))
    assert_equal 'accrual', payload['accounting_method']
    assert_equal 5.0, payload['revenue']
  end

  test 'an explicit range with no persisted report errors listing available ranges' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 1.0, cogs: 0.0, expenses: 0.0)
    payload = mcp_payload(Mcp::GetPnlTool.call(start_date: '2026-01-01', end_date: '2026-01-31', server_context: {}))
    assert_includes payload['error'], 'No P&L report'
    assert_includes payload['error'], '2026-06-01 to 2026-06-30'
  end

  test 'unknown enterprise errors listing qbo-account enterprises' do
    qbo_account_for(@sanctuary)
    # A second qbo_account on the same enterprise — the schema has no unique
    # index, so the enterprise must still be listed once (join must .distinct).
    QboAccount.create!(enterprise: @sanctuary, client_id: 'x', client_secret: 'x',
                       realm_id: "realm-#{SecureRandom.hex(3)}")
    payload = mcp_payload(Mcp::GetPnlTool.call(enterprise: 'Nope Inc', server_context: {}))
    assert_includes payload['error'], "Unknown enterprise 'Nope Inc'"
    assert_includes payload['error'], 'Sanctuary Computer Inc'
    assert_equal 1, payload['error'].scan('Sanctuary Computer Inc').length, 'enterprise listed once, not duplicated'
  end

  test 'invalid accounting_method errors' do
    payload = mcp_payload(Mcp::GetPnlTool.call(accounting_method: 'both', server_context: {}))
    assert_includes payload['error'], "Invalid accounting_method 'both'"
  end

  test 'no synced reports at all is a clear error, not a fetch' do
    qbo_account_for(@sanctuary)
    QboProfitAndLossReport.expects(:find_or_fetch_for_range).never
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_includes payload['error'], 'no synced P&L reports'
  end

  test 'a report missing the requested accounting method errors instead of raising' do
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account_for(@sanctuary),
      starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
      data: { 'cash' => { 'rows' => [['Total Income', 1.0]] } }
    )
    payload = mcp_payload(Mcp::GetPnlTool.call(accounting_method: 'accrual', server_context: {}))
    assert_includes payload['error'], 'no accrual data'
  end

  test 'a report with entirely empty data errors instead of raising' do
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account_for(@sanctuary),
      starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
      data: {}
    )
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_includes payload['error'], 'no cash data'
  end

  test 'an unknown vertical errors listing the verticals actually present in the report' do
    rows = [
      ['[SC] Total Income', 10.0], ['Total Income', 10.0],
      ['[SC] Total Cost of Goods Sold', 1.0], ['Total Cost of Goods Sold', 1.0],
      ['[SC] Total Expenses', 2.0], ['Total Expenses', 2.0],
      ['Net Income', 7.0],
    ]
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account_for(@sanctuary),
      starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
      data: { 'cash' => { 'rows' => rows }, 'accrual' => { 'rows' => rows } }
    )
    payload = mcp_payload(Mcp::GetPnlTool.call(vertical: 'nope', server_context: {}))
    assert_includes payload['error'], "Vertical 'nope' not found"
    assert_includes payload['error'], 'SC'

    ok_payload = mcp_payload(Mcp::GetPnlTool.call(vertical: 'SC', server_context: {}))
    assert_equal 10.0, ok_payload['revenue']
  end

  test 'an enterprise with no qbo account errors cleanly instead of raising' do
    # The default path resolves Enterprise.sanctuary WITHOUT the
    # joins(:qbo_account) filter the named path uses, so an account-less
    # default must guard rather than NoMethodError on ent.qbo_account.id.
    no_qbo = Enterprise.create!(name: "No QBO Ent #{SecureRandom.hex(2)}")
    Enterprise.stubs(:sanctuary).returns(no_qbo)
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_includes payload['error'], 'has no QBO account'
  end
end
