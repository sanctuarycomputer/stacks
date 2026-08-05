require 'test_helper'

class Mcp::InvoicePassesToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Time.zone.parse('2026-08-04 12:00:00')
    @sanctuary = enterprises(:sanctuary)
    # Fixtures attach TWO qbo_accounts to sanctuary; pin the one has_one picks.
    @sanct_qa = Enterprise.find(@sanctuary.id).qbo_account
    @one = enterprises(:one)
    @one_qa = QboAccount.create!(enterprise: @one, client_id: 'c', client_secret: 's', realm_id: "r-#{SecureRandom.hex(4)}")

    @client = ForecastClient.create!(forecast_id: 9101, name: 'Reactor')
    @client_b = ForecastClient.create!(forecast_id: 9102, name: 'Replit')
    @client_c = ForecastClient.create!(forecast_id: 9103, name: 'Curology')
    @client_d = ForecastClient.create!(forecast_id: 9104, name: 'Left Field')
    @client_e = ForecastClient.create!(forecast_id: 9105, name: 'Koto')

    @june = InvoicePass.create!(start_of_month: Date.new(2026, 6, 1), completed_at: Time.zone.parse('2026-07-03 10:00:00'))
    @july = InvoicePass.create!(start_of_month: Date.new(2026, 7, 1))
    @ancient = InvoicePass.create!(start_of_month: Date.new(2023, 1, 1))

    # QboInvoice#data lazily live-syncs (and can DESTROY the row) when the
    # stored jsonb is blank — the tool must only ever read stored attributes.
    QboInvoice.any_instance.expects(:sync!).never
  end

  def invoice!(qbo_id, data, account: @sanct_qa)
    QboInvoice.create!(qbo_account: account, qbo_id: qbo_id, data: data)
  end

  def tracker!(pass, client, qbo_invoice_id: nil, account: @sanct_qa, blueprint: nil)
    InvoiceTracker.create!(
      invoice_pass: pass,
      forecast_client_id: client.forecast_id,
      qbo_account: account,
      qbo_invoice_id: qbo_invoice_id,
      blueprint: blueprint,
    )
  end

  def seed_july!
    invoice!('inv-paid', { 'total' => 1000.0, 'balance' => 0.0, 'email_status' => 'EmailSent', 'due_date' => '2026-08-15' })
    tracker!(@july, @client, qbo_invoice_id: 'inv-paid', blueprint: { 'lines' => {} })

    invoice!('inv-overdue', { 'total' => 500.0, 'balance' => 500.0, 'email_status' => 'EmailSent', 'due_date' => '2026-07-20' })
    tracker!(@july, @client_b, qbo_invoice_id: 'inv-overdue', blueprint: { 'lines' => {} })

    invoice!('inv-one', { 'total' => 250.0, 'balance' => 250.0, 'email_status' => 'EmailSent', 'due_date' => '2026-09-01' }, account: @one_qa)
    tracker!(@july, @client_c, qbo_invoice_id: 'inv-one', account: @one_qa, blueprint: { 'lines' => {} })

    # Unsynced mirror (blank stored data): skipped + counted, NEVER synced live.
    invoice!('inv-blank', {})
    tracker!(@july, @client_d, qbo_invoice_id: 'inv-blank', blueprint: { 'lines' => {} })

    # No invoice yet, no blueprint: the tracker is not_made.
    tracker!(@july, @client_e)
  end

  test 'per-pass per-entity invoiced totals, status mix and MoM series from stored data only' do
    seed_july!
    invoice!('inv-june', { 'total' => 2000.0, 'balance' => 0.0, 'email_status' => 'EmailSent', 'due_date' => '2026-07-01' })
    tracker!(@june, @client, qbo_invoice_id: 'inv-june', blueprint: { 'lines' => {} })

    payload = mcp_payload(Mcp::GetInvoicePassesTool.call(server_context: {}))

    assert_equal '2026-08-04', payload['as_of']
    assert_equal 6, payload['months_back']
    assert_equal %w[2026-06-01 2026-07-01], payload['passes'].map { |p| p['month'] },
      'oldest first; the 2023 pass is outside the window'

    june = payload['passes'].first
    assert_equal 'June 2026', june['label']
    assert_equal @june.completed_at.iso8601, june['completed_at']
    assert_equal false, june['missing_hours']
    assert_equal 2000.0, june['total_invoiced']

    july = payload['passes'].last
    assert_nil july['completed_at']
    assert_equal 1750.0, july['total_invoiced']
    assert_equal ['One LLC', 'Sanctuary Computer Inc'], july['entities'].map { |e| e['entity'] },
      'entities sorted by name; only entities with trackers in the pass appear'

    sanct = july['entities'].find { |e| e['entity'] == 'Sanctuary Computer Inc' }
    assert_equal 1500.0, sanct['invoiced_total']
    assert_equal 2, sanct['invoice_count']
    assert_equal({ 'paid' => 1, 'unpaid_overdue' => 1, 'not_made' => 1 }, sanct['status_mix'])
    assert_equal 1, sanct['skipped_invoices'], 'the blank-data mirror is skipped and counted'

    one = july['entities'].find { |e| e['entity'] == 'One LLC' }
    assert_equal 250.0, one['invoiced_total']
    assert_equal 1, one['invoice_count']
    assert_equal({ 'unpaid' => 1 }, one['status_mix'])
    assert_equal 0, one['skipped_invoices']

    assert_equal(
      [{ 'month' => '2026-06-01', 'total_invoiced' => 2000.0 },
       { 'month' => '2026-07-01', 'total_invoiced' => 1750.0 }],
      payload['mom']
    )
  end

  test 'the same qbo_id in two qbo_accounts resolves each tracker to its own account invoice' do
    # qbo_id is only composite-unique with qbo_account_id (Deel-style ID
    # collision). A qbo_id-only preload would hand one account's invoice to
    # BOTH trackers; each entity must report its own account's total.
    invoice!('inv-dup', { 'total' => 999.0, 'balance' => 0.0, 'email_status' => 'EmailSent', 'due_date' => '2026-08-15' })
    invoice!('inv-dup', { 'total' => 100.0, 'balance' => 100.0, 'email_status' => 'EmailSent', 'due_date' => '2026-09-01' }, account: @one_qa)
    tracker!(@july, @client, qbo_invoice_id: 'inv-dup', blueprint: { 'lines' => {} })
    tracker!(@july, @client_b, qbo_invoice_id: 'inv-dup', account: @one_qa, blueprint: { 'lines' => {} })

    july = mcp_payload(Mcp::GetInvoicePassesTool.call(server_context: {}))['passes']
      .find { |p| p['month'] == '2026-07-01' }

    sanct = july['entities'].find { |e| e['entity'] == 'Sanctuary Computer Inc' }
    assert_equal 999.0, sanct['invoiced_total']
    assert_equal({ 'paid' => 1 }, sanct['status_mix'])

    one = july['entities'].find { |e| e['entity'] == 'One LLC' }
    assert_equal 100.0, one['invoiced_total'], "One LLC must report its own invoice, not sanctuary's"
    assert_equal({ 'unpaid' => 1 }, one['status_mix'])
  end

  test 'a tracker with an invoice but no blueprint reports status impossible, total still counted' do
    # Mirrors InvoiceTracker#status precedence: qbo_invoice present +
    # blueprint.nil? => :impossible, never the invoice's own status. The
    # total still counts (parity with InvoicePass#value, which sums every
    # linked invoice regardless of blueprint).
    invoice!('inv-impossible', { 'total' => 400.0, 'balance' => 0.0, 'email_status' => 'EmailSent', 'due_date' => '2026-08-15' })
    tracker!(@july, @client, qbo_invoice_id: 'inv-impossible', blueprint: nil)

    sanct = mcp_payload(Mcp::GetInvoicePassesTool.call(server_context: {}))['passes']
      .find { |p| p['month'] == '2026-07-01' }['entities']
      .find { |e| e['entity'] == 'Sanctuary Computer Inc' }

    assert_equal 400.0, sanct['invoiced_total']
    assert_equal 1, sanct['invoice_count']
    assert_equal({ 'impossible' => 1 }, sanct['status_mix'])
  end

  test 'a sent invoice with malformed stored data still counts its total, as status unknown' do
    # EmailSent with no due_date: QboInvoice#status raises on Date.parse.
    invoice!('inv-weird', { 'total' => 100.0, 'balance' => 100.0, 'email_status' => 'EmailSent' })
    tracker!(@july, @client, qbo_invoice_id: 'inv-weird', blueprint: { 'lines' => {} })

    sanct = mcp_payload(Mcp::GetInvoicePassesTool.call(server_context: {}))['passes']
      .find { |p| p['month'] == '2026-07-01' }['entities']
      .find { |e| e['entity'] == 'Sanctuary Computer Inc' }

    assert_equal 100.0, sanct['invoiced_total']
    assert_equal({ 'unknown' => 1 }, sanct['status_mix'])
  end

  test 'a pass stuck on missing hours is flagged' do
    # Keys must round-trip through DateTime#iso8601 (the model looks the
    # latest pass up by re-serializing the parsed key): +00:00, never Z.
    @july.update!(data: { 'reminder_passes' => { '2026-08-01T09:00:00+00:00' => ['Someone Behind'] } })

    july = mcp_payload(Mcp::GetInvoicePassesTool.call(server_context: {}))['passes']
      .find { |p| p['month'] == '2026-07-01' }
    assert_equal true, july['missing_hours']
  end

  test 'months_back clamps to 1..24 and windows the passes' do
    seed_july!

    payload = mcp_payload(Mcp::GetInvoicePassesTool.call(months_back: 100, server_context: {}))
    assert_equal 24, payload['months_back']
    assert_equal %w[2026-06-01 2026-07-01], payload['passes'].map { |p| p['month'] },
      'even the widest window excludes the 2023 pass'

    payload = mcp_payload(Mcp::GetInvoicePassesTool.call(months_back: 0, server_context: {}))
    assert_equal 1, payload['months_back']
    assert_equal [], payload['passes'], 'no pass exists for the current month'
  end
end
