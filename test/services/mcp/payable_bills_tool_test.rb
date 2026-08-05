require 'test_helper'

class Mcp::PayableBillsToolTest < ActiveSupport::TestCase
  setup do
    @today = Date.today
    Date.stubs(:today).returns(@today)
    @sanctuary = enterprises(:sanctuary)
    # Fixtures attach TWO qbo_accounts to sanctuary; pin the one has_one picks.
    @account = Enterprise.find(@sanctuary.id).qbo_account
    @other_account = (@sanctuary.reload && QboAccount.where(enterprise: @sanctuary).where.not(id: @account.id).first)

    # Bills must NEVER be destroyed from a read tool: QboBill#destroy deletes
    # the REMOTE bill in QBO (before_destroy :delete_qbo_bill!).
    QboBill.any_instance.expects(:destroy).never
    QboBill.any_instance.expects(:delete_qbo_bill!).never
  end

  def vendor!(qbo_id:, name:, account: @account)
    QboVendor.create!(qbo_account: account, qbo_id: qbo_id, data: { 'display_name' => name })
  end

  def bill!(qbo_id:, vendor_qbo_id:, data:, account: @account)
    QboBill.create!(qbo_account: account, qbo_id: qbo_id, qbo_vendor_id: vendor_qbo_id, data: data)
  end

  test 'lists bills per entity with vendor, totals, paid state and outstanding sum' do
    vendor!(qbo_id: 'v-1', name: 'Acme Hosting')
    # Same vendor qbo_id in ANOTHER realm with a different name — the
    # realm-scoped #vendor helper must not leak it across accounts.
    vendor!(qbo_id: 'v-1', name: 'Wrong Realm Vendor', account: @other_account)

    bill!(qbo_id: 'b-1', vendor_qbo_id: 'v-1', data: {
      'doc_number' => 'B-1', 'total_amt' => 1000.0, 'balance' => 500.0, 'due_date' => '2026-08-20',
    })
    bill!(qbo_id: 'b-2', vendor_qbo_id: 'v-1', data: {
      'doc_number' => 'B-2', 'total' => 100.0, 'balance' => 100.0,
    })
    bill!(qbo_id: 'b-3', vendor_qbo_id: 'v-1', data: {
      'doc_number' => 'B-3', 'total_amt' => 250.0, 'balance' => 0.0, 'due_date' => '2026-07-01',
    })
    # Unsynced mirror row (empty data jsonb): skipped, counted, NOT read live.
    bill!(qbo_id: 'b-4', vendor_qbo_id: 'v-1', data: {})

    payload = mcp_payload(Mcp::ListPayableBillsTool.call(entity: @sanctuary.name, server_context: {}))

    assert_equal @today.iso8601, payload['as_of']
    assert_equal 1, payload['entities'].length
    ent = payload['entities'].first
    assert_equal 'Sanctuary Computer Inc', ent['entity']
    assert_equal 1, ent['skipped_count']
    assert_equal %w[B-3 B-1 B-2], ent['bills'].map { |b| b['doc_number'] },
      'sorted by due date, bills without a due date last'

    b1 = ent['bills'].find { |b| b['doc_number'] == 'B-1' }
    assert_equal 'Acme Hosting', b1['vendor']
    assert_equal 1000.0, b1['total']
    assert_equal 500.0, b1['remaining_balance'], 'partial payments reflected'
    assert_equal false, b1['paid']
    assert_equal '2026-08-20', b1['due_date']
    assert_equal 'https://qbo.intuit.com/app/bill?&txnId=b-1', b1['url']

    b2 = ent['bills'].find { |b| b['doc_number'] == 'B-2' }
    assert_equal 100.0, b2['total'], "falls back to the 'total' key"
    refute b2.key?('due_date'), 'due_date only appears when the synced data has one'

    b3 = ent['bills'].find { |b| b['doc_number'] == 'B-3' }
    assert_equal true, b3['paid']

    assert_equal 600.0, ent['total_outstanding'], 'unpaid remaining balances only (500 + 100)'
  end

  test 'defaults to every enterprise, each labeled, including ones with no bills' do
    other = enterprises(:one)
    other_qa = QboAccount.create!(enterprise: other, client_id: 'c', client_secret: 's', realm_id: "r-#{SecureRandom.hex(4)}")
    vendor!(qbo_id: 'v-9', name: 'One Vendor', account: other_qa)
    bill!(qbo_id: 'b-9', vendor_qbo_id: 'v-9', account: other_qa, data: {
      'doc_number' => 'ONE-1', 'total_amt' => 75.0, 'balance' => 75.0, 'due_date' => '2026-09-01',
    })

    payload = mcp_payload(Mcp::ListPayableBillsTool.call(server_context: {}))

    assert_equal Enterprise.order(:name).pluck(:name), payload['entities'].map { |e| e['entity'] }
    one = payload['entities'].find { |e| e['entity'] == 'One LLC' }
    assert_equal ['ONE-1'], one['bills'].map { |b| b['doc_number'] }
    assert_equal 75.0, one['total_outstanding']
    two = payload['entities'].find { |e| e['entity'] == 'Two LLC' }
    assert_equal [], two['bills'], 'an enterprise with no QBO account still appears, empty'
    assert_equal 0.0, two['total_outstanding']
  end

  test 'a bill whose vendor exists only in another realm lists with a nil vendor' do
    # The unscoped belongs_to would resolve this cross-realm vendor; the
    # realm-scoped #vendor helper must return nil instead of leaking it.
    vendor!(qbo_id: 'v-none', name: 'Cross Realm Only', account: @other_account)
    bill!(qbo_id: 'b-5', vendor_qbo_id: 'v-none', data: {
      'doc_number' => 'B-5', 'total_amt' => 10.0, 'balance' => 10.0,
    })

    payload = mcp_payload(Mcp::ListPayableBillsTool.call(entity: @sanctuary.name, server_context: {}))
    row = payload['entities'].first['bills'].find { |b| b['doc_number'] == 'B-5' }
    assert_nil row['vendor']
  end

  test 'unknown entity errors listing the valid enterprise names' do
    err = mcp_payload(Mcp::ListPayableBillsTool.call(entity: 'Globex', server_context: {}))
    assert_includes err['error'], "Unknown entity 'Globex'"
    assert_includes err['error'], 'Sanctuary Computer Inc'
    assert_includes err['error'], 'One LLC'
  end
end
