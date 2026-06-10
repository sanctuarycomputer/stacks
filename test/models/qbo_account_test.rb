require "test_helper"

class QboAccountTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    # Reuse the fixture QboAccount (:one) to avoid INSERT-level deadlocks that
    # occur when creating rows concurrently with the fixture-loading transaction.
    # The fixture already has a qbo_tokens(:one) row associated with it.
    @qa = qbo_accounts(:one)
    @enterprise = @qa.enterprise
  end

  # ---------------------------------------------------------------------------
  # sync_all_vendors!
  # ---------------------------------------------------------------------------

  test "sync_all_vendors! writes qbo_account_id to each upserted row" do
    fake_vendor = OpenStruct.new(id: "V-#{SecureRandom.hex(4)}", as_json: { "display_name" => "Acme" })
    @qa.stubs(:fetch_all_vendors).returns([fake_vendor])

    @qa.sync_all_vendors!

    row = QboVendor.find_by(qbo_id: fake_vendor.id)
    assert_not_nil row, "expected a QboVendor row to be created"
    assert_equal @qa.id, row.qbo_account_id
    assert_equal fake_vendor.as_json, row.data
  end

  test "sync_all_vendors! is idempotent — second call does not duplicate rows" do
    fake_vendor = OpenStruct.new(id: "V-#{SecureRandom.hex(4)}", as_json: { "display_name" => "Acme" })
    @qa.stubs(:fetch_all_vendors).returns([fake_vendor])

    @qa.sync_all_vendors!
    @qa.sync_all_vendors!

    assert_equal 1, QboVendor.where(qbo_id: fake_vendor.id, qbo_account_id: @qa.id).count
  end

  # ---------------------------------------------------------------------------
  # sync_all_invoices!
  # ---------------------------------------------------------------------------

  test "sync_all_invoices! writes qbo_account_id" do
    # sync_all_invoices! uses i["id"] (hash bracket access) and i.as_json
    fake_invoice = OpenStruct.new(as_json: { "id" => "INV-#{SecureRandom.hex(4)}", "doc_number" => "1001" })
    fake_invoice.define_singleton_method(:[]) { |k| as_json[k] }
    @qa.stubs(:fetch_all_invoices).returns([fake_invoice])

    @qa.sync_all_invoices!

    qbo_id = fake_invoice["id"]
    row = QboInvoice.find_by(qbo_id: qbo_id, qbo_account_id: @qa.id)
    assert_not_nil row, "expected a QboInvoice row to be created"
    assert_equal @qa.id, row.qbo_account_id
  end

  # ---------------------------------------------------------------------------
  # sync_all_bills!
  # ---------------------------------------------------------------------------

  test "sync_all_bills! writes qbo_account_id" do
    bill = OpenStruct.new(
      "id" => "B-#{SecureRandom.hex(4)}",
      :id => "B-#{SecureRandom.hex(4)}",
      :as_json => { "id" => "JSON-ID" },
      :vendor_ref => OpenStruct.new(value: "VENDOR-#{SecureRandom.hex(2)}"),
    )
    @qa.stubs(:fetch_all_bills).returns([bill])
    @qa.sync_all_bills!
    row = QboBill.find_by(qbo_account_id: @qa.id, qbo_id: bill["id"])
    assert_not_nil row
  end

  test "sync_all_bills! detaches qbo_bill_id from host rows when bill no longer exists in QBO" do
    # Pre-seed a QboBill + PayStub that references it. QboBill.belongs_to
    # :qbo_vendor (primary_key: qbo_id) requires a matching QboVendor row.
    vendor_qbo_id = "VEN-#{SecureRandom.hex(4)}"
    QboVendor.create!(qbo_id: vendor_qbo_id, qbo_account: @qa, data: {})
    qbo_id = "GONE-#{SecureRandom.hex(4)}"
    QboBill.create!(qbo_id: qbo_id, qbo_account: @qa, qbo_vendor_id: vendor_qbo_id, data: {})

    # PayStub is the simplest LedgerItem to construct — no invoice_tracker FK
    # required like ContributorPayout has.
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "syncbill#{SecureRandom.hex(2)}@x.com", data: {})
    c = Contributor.create!(forecast_person: fp)
    ledger = Ledger.find_or_create_for(enterprise: Enterprise.sanctuary, contributor: c)
    cycle = PayCycle.create!(enterprise: Enterprise.sanctuary, starts_at: Date.new(2030, 1, 1), ends_at: Date.new(2030, 1, 31))
    stub = PayStub.create!(
      pay_cycle: cycle,
      ledger: ledger,
      amount: 100,
      blueprint: { "lines" => [{ "amount" => 100, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] },
    )
    stub.update_columns(qbo_bill_id: qbo_id)
    assert_equal qbo_id, stub.reload.qbo_bill_id

    # fetch_all_bills returns NOTHING — the bill is gone in QBO.
    @qa.stubs(:fetch_all_bills).returns([])
    @qa.sync_all_bills!

    # Host's qbo_bill_id should be nulled
    assert_nil stub.reload.qbo_bill_id
    # QboBill row removed
    assert_nil QboBill.find_by(qbo_id: qbo_id, qbo_account_id: @qa.id)
  end

  # ---------------------------------------------------------------------------
  # cleanup_orphaned_qbo_objects! scopes to self.id
  # ---------------------------------------------------------------------------

  test "cleanup_orphaned_qbo_objects! only touches bills belonging to self" do
    # Use the second fixture QboAccount to avoid creating new rows that can
    # deadlock alongside the fixture-loading transaction.
    other_qa = qbo_accounts(:two)

    # Seed a QboBill row for the other account so we can assert it survives.
    other_bill_id = "OTHER-#{SecureRandom.hex(4)}"
    QboBill.upsert(
      { qbo_id: other_bill_id, qbo_account_id: other_qa.id, qbo_vendor_id: "V-#{SecureRandom.hex(4)}", data: {} },
      unique_by: :index_qbo_bills_on_qbo_account_and_qbo_id
    )

    # @qa sees ONE bill with a Stacks doc_number pointing to a non-existent host.
    # cleanup falls through to the else branch and would call delete_bill.
    my_bill_obj = OpenStruct.new(
      id: "MY-#{SecureRandom.hex(4)}",
      doc_number: "Stacks_999999999_CP",  # CP ID 999999999 won't exist in test DB
    )
    @qa.stubs(:fetch_all_bills).returns([my_bill_obj])
    # Stub delete_bill so we don't attempt a real QBO API call.
    @qa.stubs(:delete_bill)

    @qa.cleanup_orphaned_qbo_objects!

    # The other account's QboBill must remain untouched.
    assert_not_nil QboBill.find_by(qbo_id: other_bill_id, qbo_account_id: other_qa.id),
      "cleanup_orphaned_qbo_objects! on @qa must not destroy bills belonging to other_qa"
  end

  # ---------------------------------------------------------------------------
  # fetch_bill_by_id — verifies make_and_refresh_qbo_access_token is called on self
  # ---------------------------------------------------------------------------

  test "fetch_bill_by_id calls make_and_refresh_qbo_access_token on self" do
    # Assert that the token helper is invoked on the correct QboAccount instance.
    # We rescue any error from the real Quickbooks service call (nil token, no network).
    @qa.expects(:make_and_refresh_qbo_access_token).at_least_once.returns(nil)
    begin
      @qa.fetch_bill_by_id("fake-id")
    rescue
      # Service will raise without a real access token / network — that is expected.
    end
  end

  # ---------------------------------------------------------------------------
  # make_and_refresh_qbo_access_token
  # ---------------------------------------------------------------------------

  test "make_and_refresh_qbo_access_token returns nil when no qbo_token exists" do
    # Stub the association to return nil so we don't need to create a second
    # QboAccount row (which can cause deadlocks alongside fixture loading).
    @qa.stubs(:qbo_token).returns(nil)

    result = @qa.make_and_refresh_qbo_access_token
    assert_nil result, "expected nil when qbo_token is absent"
  end

  test "make_and_refresh_qbo_access_token returns an OAuth2::AccessToken when token is fresh" do
    # Token fixture was created recently (updated_at < 10 minutes ago) so the
    # method should NOT attempt a refresh roundtrip.
    # We can't import OAuth2::AccessToken directly but we can assert the return
    # value is non-nil and responds to #token.
    @qa.qbo_token.update!(updated_at: Time.now)

    result = @qa.make_and_refresh_qbo_access_token
    assert_not_nil result
    assert_respond_to result, :token
  end

  test "make_and_refresh_qbo_access_token refreshes when stale (>10 min)" do
    skip "OAuth refresh hits real Intuit; integration-test only"
  end

  # ---------------------------------------------------------------------------
  # ping
  # ---------------------------------------------------------------------------

  test "ping returns nil when no qbo_token exists" do
    @qa.stubs(:qbo_token).returns(nil)
    assert_nil @qa.ping
  end

  test "ping fetches CompanyInfo by realm_id when token is present" do
    fake_access_token = Object.new
    @qa.stubs(:make_and_refresh_qbo_access_token).returns(fake_access_token)

    service = mock("CompanyInfoService")
    service.expects(:company_id=).with(@qa.realm_id)
    service.expects(:access_token=).with(fake_access_token)
    fake_company_info = OpenStruct.new(company_name: "Acme Co")
    service.expects(:fetch_by_id).with(@qa.realm_id).returns(fake_company_info)
    Quickbooks::Service::CompanyInfo.stubs(:new).returns(service)

    assert_equal fake_company_info, @qa.ping
  end

  # ---------------------------------------------------------------------------
  # sync_all_chart_accounts!
  # ---------------------------------------------------------------------------

  test "sync_all_chart_accounts! upserts mirror rows with metadata columns" do
    fake = OpenStruct.new(
      id: 99, name: "Bonuses", acct_num: "5710",
      classification: "Expense", account_type: "Expense",
      as_json: { "name" => "Bonuses", "current_balance" => 0 },
    )
    @qa.stubs(:fetch_all_accounts).returns([fake])

    @qa.sync_all_chart_accounts!

    row = QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "99")
    assert_not_nil row
    assert_equal "Bonuses", row.name
    assert_equal "5710", row.acct_num
    assert_equal "Expense", row.account_type
    assert row.active?
    assert_equal fake.as_json, row.data
  end

  test "sync_all_chart_accounts! is idempotent and updates changed names in place" do
    fake = OpenStruct.new(id: 99, name: "Bonuses", acct_num: "5710", classification: "Expense", account_type: "Expense", as_json: {})
    @qa.stubs(:fetch_all_accounts).returns([fake])
    @qa.sync_all_chart_accounts!

    renamed = OpenStruct.new(id: 99, name: "Bonuses & Awards", acct_num: "5710", classification: "Expense", account_type: "Expense", as_json: {})
    @qa.stubs(:fetch_all_accounts).returns([renamed])
    @qa.sync_all_chart_accounts!

    rows = QboChartAccount.where(qbo_account_id: @qa.id, qbo_id: "99")
    assert_equal 1, rows.count
    assert_equal "Bonuses & Awards", rows.first.name
  end

  test "sync_all_chart_accounts! deactivates rows that disappear from QBO and reactivates returning ones" do
    a = OpenStruct.new(id: "1", name: "Keep", acct_num: nil, classification: "Expense", account_type: "Expense", as_json: {})
    b = OpenStruct.new(id: "2", name: "Gone", acct_num: nil, classification: "Expense", account_type: "Expense", as_json: {})
    @qa.stubs(:fetch_all_accounts).returns([a, b])
    @qa.sync_all_chart_accounts!

    @qa.stubs(:fetch_all_accounts).returns([a])
    @qa.sync_all_chart_accounts!

    assert QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "1").active?
    refute QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "2").active?

    @qa.stubs(:fetch_all_accounts).returns([a, b])
    @qa.sync_all_chart_accounts!
    assert QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "2").active?, "returning account should reactivate"
  end

  test "sync_all_chart_accounts! is a no-op when QBO returns no accounts" do
    a = OpenStruct.new(id: "1", name: "Keep", acct_num: nil, classification: "Expense", account_type: "Expense", as_json: {})
    @qa.stubs(:fetch_all_accounts).returns([a])
    @qa.sync_all_chart_accounts!

    @qa.stubs(:fetch_all_accounts).returns([])
    @qa.sync_all_chart_accounts!

    assert QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "1").active?,
      "an empty fetch (likely an API hiccup) must not deactivate the whole mirror"
  end
end
