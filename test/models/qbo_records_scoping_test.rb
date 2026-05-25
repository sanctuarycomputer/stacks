require "test_helper"

# Asserts that QBO records cannot be created without a qbo_account binding —
# both at the AR validation level (newly added) and at the DB level (NOT NULL
# from the ScopeQboRecordsByQboAccount migration).
class QboRecordsScopingTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @qa = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME).qbo_account ||
      QboAccount.create!(
        enterprise: Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME),
        client_id: "test_client",
        client_secret: "test_secret",
        realm_id: "test_realm_#{SecureRandom.hex(4)}",
      )
  end

  test "QboBill requires qbo_account" do
    b = QboBill.new(qbo_id: "X#{SecureRandom.hex(3)}", qbo_vendor_id: "VENDOR", data: {})
    refute b.valid?
    assert_includes b.errors[:qbo_account], "can't be blank"
  end

  test "QboVendor requires qbo_account" do
    v = QboVendor.new(qbo_id: "V#{SecureRandom.hex(3)}", data: {})
    refute v.valid?
    assert_includes v.errors[:qbo_account], "can't be blank"
  end

  test "QboInvoice requires qbo_account" do
    i = QboInvoice.new(qbo_id: "I#{SecureRandom.hex(3)}", data: {})
    refute i.valid?
    assert_includes i.errors[:qbo_account], "can't be blank"
  end

  test "QboBill composite (qbo_account_id, qbo_id) uniqueness allows same qbo_id across accounts" do
    other_ent = Enterprise.find_or_create_by!(name: "Other-#{SecureRandom.hex(2)}")
    other_qa = QboAccount.create!(enterprise: other_ent, client_id: "x", client_secret: "y", realm_id: SecureRandom.hex(8))
    shared = "SHARED#{SecureRandom.hex(3)}"
    vendor1 = QboVendor.create!(qbo_id: "V1-#{SecureRandom.hex(3)}", qbo_account: @qa, data: {})
    vendor2 = QboVendor.create!(qbo_id: "V2-#{SecureRandom.hex(3)}", qbo_account: other_qa, data: {})
    QboBill.create!(qbo_id: shared, qbo_account: @qa, qbo_vendor_id: vendor1.qbo_id, data: {})
    second = QboBill.new(qbo_id: shared, qbo_account: other_qa, qbo_vendor_id: vendor2.qbo_id, data: {})
    assert second.valid?, "same qbo_id should be allowed across different qbo_accounts"
    second.save!
    assert_equal 2, QboBill.where(qbo_id: shared).count
  end

  test "QboBill rejects duplicate qbo_id within the same qbo_account" do
    qbo_id = "DUP#{SecureRandom.hex(3)}"
    vendor = QboVendor.create!(qbo_id: "VDUP-#{SecureRandom.hex(3)}", qbo_account: @qa, data: {})
    QboBill.create!(qbo_id: qbo_id, qbo_account: @qa, qbo_vendor_id: vendor.qbo_id, data: {})
    dup = QboBill.new(qbo_id: qbo_id, qbo_account: @qa, qbo_vendor_id: vendor.qbo_id, data: {})
    # Wrap in a savepoint so the PG transaction is not left in an aborted state
    # after the expected RecordNotUnique error.
    ActiveRecord::Base.transaction(requires_new: true) do
      assert_raises(ActiveRecord::RecordNotUnique) do
        dup.save(validate: false)
      end
      raise ActiveRecord::Rollback
    end
  end

  test "QboVendor same composite scoping" do
    other_ent = Enterprise.find_or_create_by!(name: "OtherV-#{SecureRandom.hex(2)}")
    other_qa = QboAccount.create!(enterprise: other_ent, client_id: "x", client_secret: "y", realm_id: SecureRandom.hex(8))
    shared = "VSHARE#{SecureRandom.hex(3)}"
    QboVendor.create!(qbo_id: shared, qbo_account: @qa, data: {})
    QboVendor.create!(qbo_id: shared, qbo_account: other_qa, data: {})
    assert_equal 2, QboVendor.where(qbo_id: shared).count
  end

  test "QboInvoice same composite scoping (only when qbo_id is not nil — partial index)" do
    other_ent = Enterprise.find_or_create_by!(name: "OtherI-#{SecureRandom.hex(2)}")
    other_qa = QboAccount.create!(enterprise: other_ent, client_id: "x", client_secret: "y", realm_id: SecureRandom.hex(8))
    shared = "ISHARE#{SecureRandom.hex(3)}"
    QboInvoice.create!(qbo_id: shared, qbo_account: @qa, data: {})
    QboInvoice.create!(qbo_id: shared, qbo_account: other_qa, data: {})
    assert_equal 2, QboInvoice.where(qbo_id: shared).count
  end
end

# ---------------------------------------------------------------------------
# ContributorAdjustment — qbo_invoice scoping and payable? scoping
# ---------------------------------------------------------------------------

class ContributorAdjustmentQboInvoiceScopingTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil

    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary,
      client_id: "test_client",
      client_secret: "test_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )

    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ca#{SecureRandom.hex(2)}@x.com", data: {})
    contributor = Contributor.create!(forecast_person: fp)
    ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: contributor)

    # A positive adjustment so sync_qbo_bill! would not bail early.
    @adj = ContributorAdjustment.create!(ledger: ledger, amount: 50, effective_on: Date.new(2030, 7, 15), qbo_account: @sanctuary_qa)
  end

  # qbo_invoice lazy-create must include qbo_account
  test "qbo_invoice returns nil when qbo_invoice_id is blank" do
    assert_nil @adj.qbo_invoice_id
    assert_nil @adj.qbo_invoice
  end

  test "qbo_invoice returns the existing row when one exists in this enterprise's qa" do
    inv_id = "INV#{SecureRandom.hex(4)}"
    @adj.update_columns(qbo_invoice_id: inv_id)
    existing = QboInvoice.create!(qbo_id: inv_id, qbo_account: @sanctuary_qa, data: { "x" => 1 })

    inv = @adj.qbo_invoice
    assert_equal existing, inv
    assert_equal @sanctuary_qa, inv.qbo_account
  end

  test "qbo_invoice returns nil and creates NO phantom row when no matching row exists" do
    inv_id = "INV#{SecureRandom.hex(4)}"
    @adj.update_columns(qbo_invoice_id: inv_id)

    assert_no_difference -> { QboInvoice.count } do
      assert_nil @adj.qbo_invoice
    end
  end

  # payable? must scope the QboInvoice lookup by qbo_account
  test "payable? is true when qbo_invoice_id is blank" do
    assert @adj.payable?
  end

  test "payable? is false when qbo_invoice_id references a non-existent invoice" do
    # CA has a qbo_account but the referenced qbo_invoice_id does not exist
    # in that account — payable? must return false, not raise.
    @adj.update_columns(qbo_invoice_id: "GHOST#{SecureRandom.hex(3)}")

    assert_nothing_raised { refute @adj.payable? }
  end

  test "payable? scopes QboInvoice lookup to the enterprise's qbo_account" do
    other_ent = Enterprise.find_or_create_by!(name: "Other-#{SecureRandom.hex(2)}")
    other_qa = QboAccount.create!(enterprise: other_ent, client_id: "x", client_secret: "y", realm_id: SecureRandom.hex(8))

    inv_id = "PAYINV#{SecureRandom.hex(3)}"
    # Create the invoice ONLY under other_qa, NOT @sanctuary_qa.
    QboInvoice.create!(qbo_id: inv_id, qbo_account: other_qa, data: { "balance" => 0, "total" => 100 })

    @adj.update_columns(qbo_invoice_id: inv_id)
    # payable? must scope to @sanctuary_qa — the inv in other_qa must NOT be found.
    refute @adj.payable?, "payable? must not find a QboInvoice from a different qbo_account"
  end
end

# ---------------------------------------------------------------------------
# InvoiceTracker — qbo_invoice lazy-create and make_invoice! scoping
# ---------------------------------------------------------------------------

class InvoiceTrackerQboInvoiceScopingTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil

    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary,
      client_id: "test_client",
      client_secret: "test_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )
  end

  # Helper to build a minimal InvoiceTracker without hitting complex associations.
  # invoice_month is a computed method on InvoicePass (start_of_month.strftime), not a column.
  def build_tracker_with_invoice_id(inv_id)
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "TestClient-#{SecureRandom.hex(2)}")
    ip = InvoicePass.create!(start_of_month: Date.new(2030, 7, 1))
    tracker = InvoiceTracker.create!(forecast_client: fc, invoice_pass: ip, qbo_account: @sanctuary_qa)
    tracker.update_columns(qbo_invoice_id: inv_id)
    tracker
  end

  test "qbo_invoice returns nil when qbo_invoice_id is blank" do
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "TC-#{SecureRandom.hex(2)}")
    ip = InvoicePass.create!(start_of_month: Date.new(2030, 8, 1))
    tracker = InvoiceTracker.create!(forecast_client: fc, invoice_pass: ip, qbo_account: @sanctuary_qa)
    assert_nil tracker.qbo_invoice_id
    assert_nil tracker.qbo_invoice
  end

  test "qbo_invoice returns the existing row scoped to sanctuary's qbo_account" do
    inv_id = "ITINV#{SecureRandom.hex(4)}"
    tracker = build_tracker_with_invoice_id(inv_id)
    existing = QboInvoice.create!(qbo_id: inv_id, qbo_account: @sanctuary_qa, data: { "x" => 1 })

    inv = tracker.qbo_invoice
    assert_equal existing, inv
    assert_equal @sanctuary_qa, inv.qbo_account
  end

  test "qbo_invoice creates NO phantom row when no matching row exists" do
    inv_id = "ITINV2#{SecureRandom.hex(4)}"
    tracker = build_tracker_with_invoice_id(inv_id)

    assert_no_difference -> { QboInvoice.count } do
      assert_nil tracker.qbo_invoice
    end
  end

  test "qbo_invoice returns nil when a same-qbo_id row exists in a DIFFERENT qbo_account (no cross-qa pickup, no phantom create)" do
    other_ent = Enterprise.find_or_create_by!(name: "OtherIT-#{SecureRandom.hex(2)}")
    other_qa = QboAccount.create!(enterprise: other_ent, client_id: "x", client_secret: "y", realm_id: SecureRandom.hex(8))

    inv_id = "CROSS#{SecureRandom.hex(4)}"
    QboInvoice.create!(qbo_id: inv_id, qbo_account: other_qa, data: {})

    tracker = build_tracker_with_invoice_id(inv_id)

    # Tracker's qa is sanctuary_qa (external client default); only one QboInvoice
    # exists for inv_id and it's in other_qa. Resolver must return nil and NOT
    # create a phantom row in sanctuary_qa.
    assert_no_difference -> { QboInvoice.count } do
      assert_nil tracker.qbo_invoice
    end
    assert_equal 1, QboInvoice.where(qbo_id: inv_id).count,
      "only the original other-qa row should exist"
  end
end
