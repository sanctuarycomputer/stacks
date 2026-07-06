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
    assert_equal 'month', payload['period_type']
  end

  test 'default (month) ignores a later future-dated yearly report; period_type selects granularity' do
    # QBO syncs monthly + quarterly + yearly into one table; the current year's
    # yearly report is future-dated (Dec 31), giving it the max ends_at. The
    # default must return the latest MONTH, not that year-spanning report.
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 2.0, cogs: 0.0, expenses: 0.0) # monthly (29d)
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 4, 1), ends_at: Date.new(2026, 6, 30),
                income: 6.0, cogs: 0.0, expenses: 0.0) # quarterly (90d)
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 1, 1), ends_at: Date.new(2026, 12, 31),
                income: 99.0, cogs: 0.0, expenses: 0.0) # yearly (364d), max ends_at

    default_payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_equal 'month', default_payload['period_type']
    assert_equal 2.0, default_payload['revenue'], 'default returns the latest month, not the year'

    quarter_payload = mcp_payload(Mcp::GetPnlTool.call(period_type: 'quarter', server_context: {}))
    assert_equal 'quarter', quarter_payload['period_type']
    assert_equal 6.0, quarter_payload['revenue']

    year_payload = mcp_payload(Mcp::GetPnlTool.call(period_type: 'year', server_context: {}))
    assert_equal 'year', year_payload['period_type']
    assert_equal 99.0, year_payload['revenue']
  end

  test 'invalid period_type errors listing valid values' do
    payload = mcp_payload(Mcp::GetPnlTool.call(period_type: 'weekly', server_context: {}))
    assert_includes payload['error'], "Invalid period_type 'weekly'"
  end

  test 'a period_type with no synced report of that granularity errors clearly' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 2.0, cogs: 0.0, expenses: 0.0) # only a month exists
    payload = mcp_payload(Mcp::GetPnlTool.call(period_type: 'year', server_context: {}))
    assert_includes payload['error'], 'no synced year P&L reports yet'
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

  test 'a report whose data or method value is a non-Hash errors in the guard, not a 500' do
    # sync drift: data is a JSON array; data[method] String-indexing would
    # TypeError in the guard itself if it were not type-checked.
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account_for(@sanctuary),
      starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
      data: ['not', 'a', 'hash']
    )
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_includes payload['error'], 'no cash data'

    # data[method] itself a non-Hash (number)
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account_for(@sanctuary),
      starts_at: Date.new(2026, 7, 1), ends_at: Date.new(2026, 7, 31),
      data: { 'cash' => 5 }
    )
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_includes payload['error'], 'no cash data'
  end

  test 'an ambiguous enterprise name (two enterprises share it) errors instead of picking one' do
    dupe = Enterprise.create!(name: @sanctuary.name) # same name, distinct row
    QboAccount.create!(enterprise: dupe, client_id: 'x', client_secret: 'x',
                       realm_id: "realm-#{SecureRandom.hex(3)}")
    qbo_account_for(@sanctuary)
    payload = mcp_payload(Mcp::GetPnlTool.call(enterprise: @sanctuary.name, server_context: {}))
    assert_includes payload['error'], 'matches 2 enterprises'
  end

  test 'a report with a NULL data column errors instead of raising' do
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account_for(@sanctuary),
      starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
      data: nil
    )
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_includes payload['error'], 'no cash data'
  end

  test 'only one of start_date/end_date errors asking for both' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 1.0, cogs: 0.0, expenses: 0.0)
    payload = mcp_payload(Mcp::GetPnlTool.call(start_date: '2026-06-01', server_context: {}))
    assert_includes payload['error'], 'both start_date and end_date'
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

  test 'a missing default enterprise (Sanctuary not seeded) errors cleanly instead of raising' do
    Enterprise.stubs(:sanctuary).raises(ActiveRecord::RecordNotFound)
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_includes payload['error'], 'not configured'
  end

  test 'scopes P&L reports across all of the enterprise qbo_accounts, not just qbo_account.first' do
    first_account = qbo_account_for(@sanctuary)
    second_account = QboAccount.create!(enterprise: @sanctuary, client_id: 'x', client_secret: 'x',
                                        realm_id: "realm-#{SecureRandom.hex(3)}")
    # Report synced under whichever account isn't `ent.qbo_account`'s
    # (has_one, so arbitrary LIMIT 1) — the tool must still find it.
    other_account = @sanctuary.qbo_account == first_account ? second_account : first_account
    rows = [
      ['Total Income', 9.0], ['Total Cost of Goods Sold', 0.0],
      ['Total Expenses', 0.0], ['Net Income', 9.0],
    ]
    QboProfitAndLossReport.create!(
      qbo_account: other_account,
      starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
      data: { 'cash' => { 'rows' => rows }, 'accrual' => { 'rows' => rows } }
    )
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_equal 9.0, payload['revenue']
  end

  test 'a malformed report row errors cleanly instead of raising' do
    # A bare `nil` entry in a rows array makes find_rows's String#include?
    # check raise TypeError (no implicit conversion of nil into String) —
    # simulating sync drift/corruption rather than a hand-crafted fixture bug.
    rows = [
      ['Total Income', 100.0],
      [nil, 5.0],
      ['Total Cost of Goods Sold', 10.0],
      ['Total Expenses', 5.0],
      ['Net Income', 85.0],
    ]
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account_for(@sanctuary),
      starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
      data: { 'cash' => { 'rows' => rows }, 'accrual' => { 'rows' => rows } }
    )
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_includes payload['error'], 'malformed'
    refute payload.key?('revenue')
  end
end
