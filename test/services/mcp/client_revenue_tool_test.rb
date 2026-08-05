require 'test_helper'

class Mcp::ClientRevenueToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Time.zone.parse('2026-08-04 12:00:00')
    @tb, @g3d = make_studio!
    @qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account

    @reactor = ForecastClient.create!(forecast_id: 9201, name: 'Reactor')
    @replit = ForecastClient.create!(forecast_id: 9202, name: 'Replit')

    @may = InvoicePass.create!(start_of_month: Date.new(2026, 5, 1))
    @june = InvoicePass.create!(start_of_month: Date.new(2026, 6, 1))
    @july = InvoicePass.create!(start_of_month: Date.new(2026, 7, 1))

    # ClientRevenue's own guard skips blank-data mirrors; nothing here may
    # ever fire QboInvoice's lazy live sync.
    QboInvoice.any_instance.expects(:sync!).never
  end

  def invoiced_tracker!(pass, client, qbo_id, total, blueprint: { 'lines' => {} }, data_extra: {})
    QboInvoice.create!(qbo_account: @qa, qbo_id: qbo_id,
                       data: { 'total' => total, 'email_status' => 'EmailSent', 'balance' => 0.0, 'due_date' => '2026-08-15' }.merge(data_extra))
    InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                           qbo_account: @qa, qbo_invoice_id: qbo_id, blueprint: blueprint)
  end

  def seed!
    invoiced_tracker!(@may, @reactor, 'cr-1', 1000.0)
    invoiced_tracker!(@june, @reactor, 'cr-2', 2000.0)
    invoiced_tracker!(@july, @reactor, 'cr-3', 3000.0)
    invoiced_tracker!(@june, @replit, 'cr-4', 1000.0)

    # Voided invoice: not countable revenue.
    invoiced_tracker!(@july, @replit, 'cr-void', 9999.0,
                      data_extra: { 'email_status' => 'NotSet', 'private_note' => 'Voided by accountant' })

    # Internal client (mapped to an enterprise): never countable.
    internal = ForecastClient.create!(forecast_id: 9203, name: 'Internal Corp')
    EnterpriseForecastClient.create!(enterprise: enterprises(:sanctuary), forecast_client: internal)
    invoiced_tracker!(@july, internal, 'cr-int', 5000.0)

    # Blank stored data: skipped + counted by ClientRevenue's guard. Its own
    # client — trackers are unique per (forecast_client, invoice_pass).
    blanky = ForecastClient.create!(forecast_id: 9204, name: 'Blanky')
    QboInvoice.create!(qbo_account: @qa, qbo_id: 'cr-blank', data: {})
    InvoiceTracker.create!(invoice_pass: @july, forecast_client_id: blanky.forecast_id,
                           qbo_account: @qa, qbo_invoice_id: 'cr-blank', blueprint: { 'lines' => {} })

    # Outside every window this test uses.
    old = InvoicePass.create!(start_of_month: Date.new(2024, 1, 1))
    invoiced_tracker!(old, @reactor, 'cr-old', 77_777.0)
  end

  test 'client-by-month revenue rows for garden3d: full totals, external clients, top-N by total' do
    seed!

    payload = mcp_payload(Mcp::GetClientRevenueTool.call(server_context: {}))

    assert_equal '2026-08-04', payload['as_of']
    assert_equal 'garden3d', payload['studio']
    assert_equal 6, payload['months_back']
    assert_includes payload['scope'], 'External clients'

    assert_equal %w[Reactor Replit], payload['clients'].map { |c| c['client'] },
      'sorted by window total desc; voided + internal + out-of-window rows never appear'

    reactor = payload['clients'].first
    assert_equal 6000.0, reactor['total']
    assert_equal 85.7, reactor['share_of_total_pct']
    assert_equal(
      [{ 'month' => '2026-03-01', 'amount' => 0.0 },
       { 'month' => '2026-04-01', 'amount' => 0.0 },
       { 'month' => '2026-05-01', 'amount' => 1000.0 },
       { 'month' => '2026-06-01', 'amount' => 2000.0 },
       { 'month' => '2026-07-01', 'amount' => 3000.0 },
       { 'month' => '2026-08-01', 'amount' => 0.0 }],
      reactor['monthly'], 'zero-filled across the whole window, oldest first'
    )

    replit = payload['clients'].last
    assert_equal 1000.0, replit['total']
    assert_equal 14.3, replit['share_of_total_pct']

    assert_equal 7000.0, payload['total_revenue']
    assert_equal 2, payload['client_count']
    assert_equal 1, payload['skipped_tracker_count'], 'the blank-data mirror is skipped and counted'
    assert_equal(
      [{ 'month' => '2026-03-01', 'total' => 0.0 },
       { 'month' => '2026-04-01', 'total' => 0.0 },
       { 'month' => '2026-05-01', 'total' => 1000.0 },
       { 'month' => '2026-06-01', 'total' => 3000.0 },
       { 'month' => '2026-07-01', 'total' => 3000.0 },
       { 'month' => '2026-08-01', 'total' => 0.0 }],
      payload['mom_totals']
    )
  end

  test 'cross-account qbo_id collisions resolve each tracker to its own account invoice' do
    # qbo_id is only composite-unique with qbo_account_id. A qbo_id-only
    # preload in Stacks::ClientRevenue.all_trackers would hand one account's
    # invoice to BOTH trackers (this also protects the nightly snapshot).
    one_qa = QboAccount.create!(enterprise: enterprises(:one), client_id: 'c',
                                client_secret: 's', realm_id: "r-#{SecureRandom.hex(4)}")
    QboInvoice.create!(qbo_account: @qa, qbo_id: 'cr-dup',
                       data: { 'total' => 999.0, 'email_status' => 'EmailSent', 'balance' => 0.0, 'due_date' => '2026-08-15' })
    QboInvoice.create!(qbo_account: one_qa, qbo_id: 'cr-dup',
                       data: { 'total' => 100.0, 'email_status' => 'EmailSent', 'balance' => 0.0, 'due_date' => '2026-08-15' })
    InvoiceTracker.create!(invoice_pass: @july, forecast_client_id: @reactor.forecast_id,
                           qbo_account: @qa, qbo_invoice_id: 'cr-dup', blueprint: { 'lines' => {} })
    InvoiceTracker.create!(invoice_pass: @july, forecast_client_id: @replit.forecast_id,
                           qbo_account: one_qa, qbo_invoice_id: 'cr-dup', blueprint: { 'lines' => {} })

    payload = mcp_payload(Mcp::GetClientRevenueTool.call(server_context: {}))

    reactor = payload['clients'].find { |c| c['client'] == 'Reactor' }
    replit = payload['clients'].find { |c| c['client'] == 'Replit' }
    assert_equal 999.0, reactor['total']
    assert_equal 100.0, replit['total'], "Replit must report its own account's invoice total"
    assert_equal 1099.0, payload['total_revenue']
  end

  test 'top clamps 1..50 and trims the client list without changing the window totals' do
    seed!

    payload = mcp_payload(Mcp::GetClientRevenueTool.call(top: 1, server_context: {}))
    assert_equal ['Reactor'], payload['clients'].map { |c| c['client'] }
    assert_equal 7000.0, payload['total_revenue'], 'window totals cover clients beyond the top-N cut'
    assert_equal 2, payload['client_count']

    payload = mcp_payload(Mcp::GetClientRevenueTool.call(top: 0, server_context: {}))
    assert_equal 1, payload['clients'].length, 'top clamps up to 1'
  end

  test 'months_back clamps 1..24 and windows the rows' do
    seed!

    payload = mcp_payload(Mcp::GetClientRevenueTool.call(months_back: 100, server_context: {}))
    assert_equal 24, payload['months_back']
    assert_equal 24, payload['mom_totals'].length
    assert_equal 7000.0, payload['total_revenue'], 'even the widest window excludes the 2024 rows'

    payload = mcp_payload(Mcp::GetClientRevenueTool.call(months_back: 2, server_context: {}))
    assert_equal %w[2026-07-01 2026-08-01], payload['mom_totals'].map { |m| m['month'] }
    assert_equal 3000.0, payload['total_revenue']
  end

  test 'a sub-studio takes its pro-rata blueprint share instead of full invoice totals' do
    ForecastPerson.create!(forecast_id: 9301, first_name: 'Tee', last_name: 'Bee', roles: ['Thoughtbot'])
    ForecastPerson.create!(forecast_id: 9302, first_name: 'Gee', last_name: 'Dee', roles: ['garden3d'])

    invoiced_tracker!(@july, @reactor, 'cr-split', 2000.0, blueprint: {
      'lines' => {
        'Tee Bee work' => { 'id' => '1', 'quantity' => 10, 'unit_price' => 100.0, 'forecast_person' => 9301 },
        'Gee Dee work' => { 'id' => '2', 'quantity' => 10, 'unit_price' => 100.0, 'forecast_person' => 9302 },
      },
    })
    # A tracker with no usable blueprint lines is omitted from sub-studio
    # numbers (it still counts for garden3d).
    invoiced_tracker!(@june, @replit, 'cr-nolines', 1000.0)

    payload = mcp_payload(Mcp::GetClientRevenueTool.call(studio: 'tb', server_context: {}))

    assert_equal 'Thoughtbot', payload['studio']
    assert_equal ['Reactor'], payload['clients'].map { |c| c['client'] }
    assert_equal 1000.0, payload['clients'].first['total'], 'half the blueprint value → half the invoice total'
    assert_equal 1000.0, payload['total_revenue']
  end

  test 'a sent invoice with malformed stored data is skipped and counted, dropping its revenue' do
    # EmailSent with no due_date: QboInvoice#status raises inside
    # ClientRevenue's voided check, so the tracker is skipped + counted.
    # DIVERGES from get_invoice_passes, which buckets the same row as status
    # `unknown` and still counts its total.
    weird = ForecastClient.create!(forecast_id: 9205, name: 'Weird Data Client')
    QboInvoice.create!(qbo_account: @qa, qbo_id: 'cr-weird',
                       data: { 'total' => 100.0, 'balance' => 100.0, 'email_status' => 'EmailSent' })
    InvoiceTracker.create!(invoice_pass: @july, forecast_client_id: weird.forecast_id,
                           qbo_account: @qa, qbo_invoice_id: 'cr-weird', blueprint: { 'lines' => {} })

    payload = mcp_payload(Mcp::GetClientRevenueTool.call(server_context: {}))

    refute payload['clients'].any? { |c| c['client'] == 'Weird Data Client' },
      'the malformed tracker contributes no revenue row'
    assert_equal 0.0, payload['total_revenue']
    assert_equal 1, payload['skipped_tracker_count']
  end

  test 'unknown studio errors listing the valid studios' do
    err = mcp_payload(Mcp::GetClientRevenueTool.call(studio: 'nope', server_context: {}))
    assert_includes err['error'], "Unknown studio 'nope'"
    assert_includes err['error'], 'garden3d'
    assert_includes err['error'], 'Thoughtbot'
  end
end
