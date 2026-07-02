require 'test_helper'

class Mcp::FinanceToolsTest < ActiveSupport::TestCase
  setup do
    @sanctuary = enterprises(:sanctuary)
    @account = qbo_accounts(:one)
    @today = Date.today
    Date.stubs(:today).returns(@today)
  end

  # Minimal synced-invoice factory mirroring the jsonb shape QboInvoice
  # accessors read (see app/models/qbo_invoice.rb).
  def invoice!(doc:, due:, balance:, total: nil, customer: 'Acme Co', customer_id: nil,
               email_status: 'EmailSent', account: @account, omit_customer_ref: false)
    data = {
      'doc_number' => doc,
      'email_status' => email_status,
      'due_date' => due.iso8601,
      'balance' => balance,
      'total' => total || balance,
    }
    unless omit_customer_ref
      customer_ref = { 'name' => customer }
      customer_ref['value'] = customer_id if customer_id
      data['customer_ref'] = customer_ref
    end
    QboInvoice.create!(qbo_account: account, qbo_id: "inv-#{doc}", data: data)
  end

  def payload_for(resp)
    JSON.parse(resp.content.first[:text])
  end

  # --- get_ar_aging ---

  test 'get_ar_aging buckets balances by days overdue with correct boundaries' do
    invoice!(doc: 'a', due: @today, balance: 10.0)           # 0 days  -> current
    invoice!(doc: 'b', due: @today - 30, balance: 20.0)      # 30 days -> days_1_30
    invoice!(doc: 'c', due: @today - 31, balance: 40.0)      # 31 days -> days_31_60
    invoice!(doc: 'd', due: @today - 90, balance: 80.0)      # 90 days -> days_61_90
    invoice!(doc: 'e', due: @today - 91, balance: 160.0)     # 91 days -> days_over_90

    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    ent = payload['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    acme = ent['customers'].find { |c| c['customer'] == 'Acme Co' }

    assert_equal 10.0, acme['current']
    assert_equal 20.0, acme['days_1_30']
    assert_equal 40.0, acme['days_31_60']
    assert_equal 80.0, acme['days_61_90']
    assert_equal 160.0, acme['days_over_90']
    assert_equal 310.0, acme['total']
    assert_equal 310.0, ent['total_ar']
    assert_equal 310.0, payload['total_ar']
    assert_equal @today.iso8601, payload['as_of']
  end

  test 'get_ar_aging cross-foots exactly across buckets despite fractional-cent balances' do
    invoice!(doc: 'cf1', due: @today, balance: 10.01, customer: 'Cent Co', customer_id: 'cc')
    invoice!(doc: 'cf2', due: @today - 30, balance: 20.02, customer: 'Cent Co', customer_id: 'cc')
    invoice!(doc: 'cf3', due: @today - 31, balance: 0.99, customer: 'Cent Co', customer_id: 'cc')

    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    ent = payload['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    row = ent['customers'].find { |c| c['customer'] == 'Cent Co' }

    bucket_sum = Mcp::QboReceivables::BUCKETS.sum { |b| row[b] }
    assert_equal row['total'], bucket_sum
    assert_in_delta 31.02, row['total'], 0.0001
    assert_equal row['total'], ent['total_ar']
  end

  test 'get_ar_aging sums outstanding balance, not invoice total' do
    invoice!(doc: 'p', due: @today - 10, balance: 500.0, total: 1000.0)
    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    acme = payload['enterprises'].first['customers'].first
    assert_equal 500.0, acme['days_1_30']
    assert_equal 500.0, acme['total']
  end

  test 'get_ar_aging excludes paid, unsent, and unsynced invoices — and never syncs' do
    invoice!(doc: 'live', due: @today - 5, balance: 100.0)
    invoice!(doc: 'paid', due: @today - 5, balance: 0.0, total: 300.0)
    invoice!(doc: 'draft', due: @today - 5, balance: 50.0, email_status: 'NotSet')
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-unsynced', data: nil)

    QboInvoice.any_instance.expects(:sync!).never
    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 100.0, payload['total_ar']
  end

  test 'get_ar_aging groups by enterprise and scopes by the enterprise param' do
    other = QboAccount.create!(enterprise: enterprises(:one), client_id: 'x',
                               client_secret: 'x', realm_id: 'realm-other')
    invoice!(doc: 's1', due: @today - 5, balance: 100.0)
    invoice!(doc: 'o1', due: @today - 5, balance: 999.0, account: other,
             customer: 'Other Client')

    all = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 1099.0, all['total_ar']
    assert_equal 2, all['enterprises'].length

    scoped = payload_for(Mcp::GetArAgingTool.call(
      enterprise: 'sanctuary computer inc', server_context: {}))
    assert_equal 100.0, scoped['total_ar']
    assert_equal [@sanctuary.name], scoped['enterprises'].map { |e| e['enterprise'] }
  end

  test 'get_ar_aging resolves an enterprise name padded with whitespace' do
    invoice!(doc: 's2', due: @today - 5, balance: 100.0)

    scoped = payload_for(Mcp::GetArAgingTool.call(
      enterprise: '  sanctuary computer inc  ', server_context: {}))
    assert_equal 100.0, scoped['total_ar']
    assert_equal [@sanctuary.name], scoped['enterprises'].map { |e| e['enterprise'] }
  end

  test 'get_ar_aging keeps same-named customers with different customer_id as distinct rows' do
    invoice!(doc: 'dup1', due: @today - 5, balance: 100.0, customer: 'Studio LLC', customer_id: 'c1')
    invoice!(doc: 'dup2', due: @today - 10, balance: 200.0, customer: 'Studio LLC', customer_id: 'c2')

    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    ent = payload['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    studios = ent['customers'].select { |c| c['customer'] == 'Studio LLC' }

    assert_equal 2, studios.length
    assert_equal %w[c1 c2].sort, studios.map { |c| c['customer_id'] }.sort
    totals = studios.map { |c| c['total'] }.sort
    assert_equal [100.0, 200.0], totals
  end

  test 'get_ar_aging groups same customer_id into one row even if the display name drifted between syncs' do
    invoice!(doc: 'rn1', due: @today - 20, balance: 100.0, customer: 'Acme', customer_id: 'c1')
    invoice!(doc: 'rn2', due: @today - 5, balance: 200.0, customer: 'Acme Co', customer_id: 'c1')

    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    ent = payload['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    rows = ent['customers'].select { |c| c['customer_id'] == 'c1' }

    assert_equal 1, rows.length
    assert_equal 'Acme Co', rows.first['customer']
    assert_equal 300.0, rows.first['total']
  end

  test 'get_ar_aging returns an error payload for an unknown enterprise' do
    payload = payload_for(Mcp::GetArAgingTool.call(enterprise: 'Nope Inc', server_context: {}))
    assert_includes payload['error'], "Unknown enterprise 'Nope Inc'"
    assert_includes payload['error'], @sanctuary.name
  end

  test 'get_ar_aging skips malformed synced rows instead of raising' do
    invoice!(doc: 'good', due: @today - 5, balance: 100.0)
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-malformed', data: {
      'due_date' => (@today - 5).iso8601,
      'balance' => { 'weird' => 'shape' },
      'email_status' => 'EmailSent',
      'customer_ref' => { 'name' => 'Broken' },
      'doc_number' => 'bad1',
    })

    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 100.0, payload['total_ar']
    ent = payload['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    assert_equal ['Acme Co'], ent['customers'].map { |c| c['customer'] }
  end

  test 'both tools keep a row with a missing or unparseable total, emitting total: nil' do
    invoice!(doc: 'good', due: @today - 5, balance: 100.0)
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-no-total', data: {
      'doc_number' => 'no-total',
      'email_status' => 'EmailSent',
      'due_date' => (@today - 5).iso8601,
      'balance' => 50.0,
      'customer_ref' => { 'name' => 'Missing Total Inc' },
    })
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-comma-total', data: {
      'doc_number' => 'comma-total',
      'email_status' => 'EmailSent',
      'due_date' => (@today - 5).iso8601,
      'balance' => 50.0,
      'total' => '1,200.00',
      'customer_ref' => { 'name' => 'Comma Total Inc' },
    })

    # A missing/unparseable total is display-only — the row still owes its
    # balance, so it must not be dropped from AR: both the missing-total and
    # comma-total balances still show up in the aging buckets/total.
    aging = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 200.0, aging['total_ar']
    ent = aging['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    assert_equal ['Acme Co', 'Comma Total Inc', 'Missing Total Inc'].sort,
                 ent['customers'].map { |c| c['customer'] }.sort

    overdue = payload_for(Mcp::ListOverdueInvoicesTool.call(server_context: {}))
    assert_equal %w[comma-total good no-total].sort, overdue['invoices'].map { |i| i['doc_number'] }.sort
    no_total_row = overdue['invoices'].find { |i| i['doc_number'] == 'no-total' }
    comma_total_row = overdue['invoices'].find { |i| i['doc_number'] == 'comma-total' }
    assert_nil no_total_row['total']
    assert_nil comma_total_row['total']
    assert_equal 50.0, no_total_row['balance']
    assert_equal 50.0, comma_total_row['balance']
  end

  test 'get_ar_aging excludes and warns about a sent invoice with no balance key at all' do
    invoice!(doc: 'good', due: @today - 5, balance: 100.0)
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-no-balance', data: {
      'doc_number' => 'no-balance',
      'email_status' => 'EmailSent',
      'due_date' => (@today - 5).iso8601,
      'total' => 50.0,
      'customer_ref' => { 'name' => 'No Balance Inc' },
    })

    Rails.logger.expects(:warn).with { |msg| msg.include?('excluded as malformed') }

    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 100.0, payload['total_ar']
    ent = payload['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    assert_equal ['Acme Co'], ent['customers'].map { |c| c['customer'] }
  end

  test 'get_ar_aging keeps identity-less debtors (no customer_id, no customer name) as separate rows' do
    invoice!(doc: 'anon1', due: @today - 5, balance: 100.0, omit_customer_ref: true)
    invoice!(doc: 'anon2', due: @today - 10, balance: 200.0, omit_customer_ref: true)

    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    ent = payload['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    unknown_rows = ent['customers'].select { |c| c['customer'] == 'Unknown' }

    assert_equal 2, unknown_rows.length
    assert unknown_rows.all? { |r| r['customer_id'].nil? }
    assert_equal [100.0, 200.0], unknown_rows.map { |r| r['total'] }.sort
  end

  test 'get_ar_aging returns an empty report when there are no receivables' do
    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 0, payload['total_ar']
  end

  test 'an empty-string customer name falls back to Unknown in both tools' do
    invoice!(doc: 'nc1', due: @today - 5, balance: 100.0, customer: '')

    aging = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    ent = aging['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    unknown = ent['customers'].find { |c| c['customer'] == 'Unknown' }
    assert unknown, "Expected an 'Unknown' customer row, got: #{ent['customers'].inspect}"
    assert_equal 100.0, unknown['total']

    overdue = payload_for(Mcp::ListOverdueInvoicesTool.call(server_context: {}))
    assert_equal ['Unknown'], overdue['invoices'].map { |i| i['customer'] }
  end

  test 'a String customer_ref falls back to Unknown in both tools instead of substring-matching name' do
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-string-ref', data: {
      'doc_number' => 'str-ref',
      'email_status' => 'EmailSent',
      'due_date' => (@today - 5).iso8601,
      'balance' => 100.0,
      'total' => 100.0,
      'customer_ref' => 'Acme (trade name)',
    })

    aging = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    ent = aging['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    assert_equal ['Unknown'], ent['customers'].map { |c| c['customer'] }

    overdue = payload_for(Mcp::ListOverdueInvoicesTool.call(server_context: {}))
    assert_equal ['Unknown'], overdue['invoices'].map { |i| i['customer'] }
  end

  test 'both tools drop a row whose due_date passes the SQL filter but fails to parse' do
    invoice!(doc: 'ok', due: @today - 5, balance: 100.0)
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-bad-date', data: {
      'doc_number' => 'bad-date',
      'email_status' => 'EmailSent',
      'due_date' => 'not-a-date',
      'balance' => 50.0,
      'total' => 50.0,
      'customer_ref' => { 'name' => 'Broken Dates Inc' },
    })

    aging = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 100.0, aging['total_ar']
    ent = aging['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    assert_equal ['Acme Co'], ent['customers'].map { |c| c['customer'] }

    overdue = payload_for(Mcp::ListOverdueInvoicesTool.call(server_context: {}))
    assert_equal %w[ok], overdue['invoices'].map { |i| i['doc_number'] }
  end

  # --- list_overdue_invoices ---

  test 'list_overdue_invoices returns overdue rows sorted most-overdue first' do
    invoice!(doc: '10', due: @today - 5, balance: 100.0)
    invoice!(doc: '11', due: @today - 45, balance: 200.0, customer: 'Beta LLC')
    invoice!(doc: '12', due: @today + 5, balance: 300.0)   # not overdue
    invoice!(doc: '13', due: @today - 20, balance: 150.0, total: 400.0) # partially paid overdue

    payload = payload_for(Mcp::ListOverdueInvoicesTool.call(server_context: {}))
    assert_equal 3, payload['count']
    assert_equal %w[11 13 10], payload['invoices'].map { |i| i['doc_number'] }

    top = payload['invoices'].first
    assert_equal 'Beta LLC', top['customer']
    assert_equal @sanctuary.name, top['enterprise']
    assert_equal 45, top['days_overdue']
    assert_equal 'unpaid_overdue', top['status']
    assert_equal (@today - 45).iso8601, top['due_date']
    assert_match %r{https://app\.qbo\.intuit\.com/app/invoice\?txnId=}, top['qbo_invoice_link']
    assert top['display_name'].present?

    partial = payload['invoices'].find { |i| i['doc_number'] == '13' }
    assert_equal 'partially_paid_overdue', partial['status']
    assert_equal 150.0, partial['balance']
    assert_equal 400.0, partial['total']
  end

  test 'list_overdue_invoices honors min_days_overdue' do
    invoice!(doc: '20', due: @today - 5, balance: 100.0)
    invoice!(doc: '21', due: @today - 40, balance: 200.0)

    payload = payload_for(Mcp::ListOverdueInvoicesTool.call(min_days_overdue: 30, server_context: {}))
    assert_equal %w[21], payload['invoices'].map { |i| i['doc_number'] }
  end

  test 'list_overdue_invoices clamps min_days_overdue below 1 to 1' do
    invoice!(doc: '25', due: @today, balance: 100.0)      # due today, 0 days overdue
    invoice!(doc: '26', due: @today - 3, balance: 200.0)  # 3 days overdue

    payload = payload_for(Mcp::ListOverdueInvoicesTool.call(min_days_overdue: 0, server_context: {}))
    assert_equal %w[26], payload['invoices'].map { |i| i['doc_number'] }
  end

  test 'list_overdue_invoices scopes by enterprise and rejects unknown names' do
    other = QboAccount.create!(enterprise: enterprises(:one), client_id: 'x',
                               client_secret: 'x', realm_id: 'realm-other2')
    invoice!(doc: '30', due: @today - 5, balance: 100.0)
    invoice!(doc: '31', due: @today - 5, balance: 200.0, account: other)

    scoped = payload_for(Mcp::ListOverdueInvoicesTool.call(
      enterprise: @sanctuary.name, server_context: {}))
    assert_equal %w[30], scoped['invoices'].map { |i| i['doc_number'] }

    err = payload_for(Mcp::ListOverdueInvoicesTool.call(enterprise: 'Nope Inc', server_context: {}))
    assert_includes err['error'], "Unknown enterprise 'Nope Inc'"
  end

  test 'list_overdue_invoices skips unsynced rows without syncing' do
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-unsynced-2', data: nil)
    QboInvoice.any_instance.expects(:sync!).never
    payload = payload_for(Mcp::ListOverdueInvoicesTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['invoices']
  end
end
