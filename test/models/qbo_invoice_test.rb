require "test_helper"

class QboInvoiceTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary, client_id: "c", client_secret: "s", realm_id: "r#{SecureRandom.hex(3)}",
    )
    @other_ent = Enterprise.create!(name: "Other-#{SecureRandom.hex(2)}")
    @other_qa = QboAccount.create!(
      enterprise: @other_ent, client_id: "c", client_secret: "s", realm_id: "r#{SecureRandom.hex(3)}",
    )
  end

  # ---------------------------------------------------------------------------
  # Bug 1: primary_key dropped — destroy! must be scoped to a single row.
  # ---------------------------------------------------------------------------

  test "destroy! deletes only the row in this qbo_account, not same-qbo_id rows from other qa" do
    shared_qbo_id = "SHARED#{SecureRandom.hex(3)}"
    a = QboInvoice.create!(qbo_id: shared_qbo_id, qbo_account: @sanctuary_qa, data: { "x" => 1 })
    b = QboInvoice.create!(qbo_id: shared_qbo_id, qbo_account: @other_qa, data: { "x" => 2 })

    a.destroy!

    assert_nil QboInvoice.find_by(qbo_id: shared_qbo_id, qbo_account_id: @sanctuary_qa.id)
    assert_not_nil QboInvoice.find_by(qbo_id: shared_qbo_id, qbo_account_id: @other_qa.id),
      "destroying the Sanctuary-scoped row must NOT delete the same-qbo_id row in another qa"
  end

  # ---------------------------------------------------------------------------
  # Bug 3: sync!'s "Object Not Found" destroy path must scope tracker detachment
  # by qbo_account, not blanket-null every tracker with that qbo_invoice_id.
  # ---------------------------------------------------------------------------

  test "sync! Object Not Found path detaches only trackers whose effective qa matches" do
    shared_qbo_id = "SHARED#{SecureRandom.hex(3)}"

    # Two QboInvoice rows with the same qbo_id, one per qa.
    inv_sanctuary = QboInvoice.create!(qbo_id: shared_qbo_id, qbo_account: @sanctuary_qa, data: { "x" => 1 })
    inv_other = QboInvoice.create!(qbo_id: shared_qbo_id, qbo_account: @other_qa, data: { "x" => 2 })

    # Two trackers pointing at that qbo_id:
    #   - tracker_sanctuary's forecast_client routes to Sanctuary (external)
    #   - tracker_other's forecast_client routes to @other_ent (internal-mapped)
    fc_external = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Ext-#{SecureRandom.hex(2)}")
    fc_internal = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Int-#{SecureRandom.hex(2)}")
    EnterpriseForecastClient.create!(enterprise: @other_ent, forecast_client_id: fc_internal.forecast_id)

    ip = InvoicePass.find_or_create_by!(start_of_month: Date.new(2098, 1, 1))
    tracker_sanctuary = InvoiceTracker.create!(invoice_pass: ip, forecast_client: fc_external, qbo_invoice_id: shared_qbo_id)
    tracker_other = InvoiceTracker.create!(invoice_pass: ip, forecast_client: fc_internal, qbo_invoice_id: shared_qbo_id)

    # Force inv_sanctuary's sync! to hit the "Object Not Found" branch.
    inv_sanctuary.qbo_account.stubs(:fetch_invoice_by_id).raises(StandardError.new("Object Not Found: foo"))

    inv_sanctuary.sync!

    # Sanctuary-scoped invoice row is gone; other-qa row survives.
    assert_nil QboInvoice.find_by(qbo_id: shared_qbo_id, qbo_account_id: @sanctuary_qa.id)
    assert_not_nil QboInvoice.find_by(qbo_id: shared_qbo_id, qbo_account_id: @other_qa.id),
      "other-qa row with same qbo_id must survive the destroy"

    # Sanctuary-routed tracker detached; other-routed tracker survives intact.
    assert_nil tracker_sanctuary.reload.qbo_invoice_id,
      "tracker routed to Sanctuary should be detached when its invoice was destroyed"
    assert_equal shared_qbo_id, tracker_other.reload.qbo_invoice_id,
      "tracker routed to other-qa must NOT be detached by Sanctuary's destroy"
  end
end

class InvoiceTrackerQboInvoiceLookupTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary, client_id: "c", client_secret: "s", realm_id: "r#{SecureRandom.hex(3)}",
    )
  end

  # ---------------------------------------------------------------------------
  # Bug 2: InvoiceTracker#qbo_invoice must NOT create phantom rows. When no
  # matching QboInvoice exists for the tracker's current qa, return nil.
  # ---------------------------------------------------------------------------

  test "qbo_invoice returns nil when no matching row exists for this qa (no phantom row created)" do
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "FC-#{SecureRandom.hex(2)}")
    ip = InvoicePass.find_or_create_by!(start_of_month: Date.new(2097, 1, 1))
    tracker = InvoiceTracker.create!(invoice_pass: ip, forecast_client: fc, qbo_invoice_id: "GONE#{SecureRandom.hex(3)}")

    assert_no_difference -> { QboInvoice.where(qbo_id: tracker.qbo_invoice_id).count } do
      assert_nil tracker.qbo_invoice
    end
  end

  test "qbo_invoice returns the row when one exists in this qa" do
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "FC-#{SecureRandom.hex(2)}")
    ip = InvoicePass.find_or_create_by!(start_of_month: Date.new(2097, 2, 1))
    qbo_id = "INV#{SecureRandom.hex(3)}"
    inv = QboInvoice.create!(qbo_id: qbo_id, qbo_account: @sanctuary_qa, data: { "x" => 1 })
    tracker = InvoiceTracker.create!(invoice_pass: ip, forecast_client: fc, qbo_invoice_id: qbo_id)

    assert_equal inv, tracker.qbo_invoice
  end

  test "qbo_invoice returns nil when matching row exists but in a DIFFERENT qa" do
    other_ent = Enterprise.create!(name: "Other-#{SecureRandom.hex(2)}")
    other_qa = QboAccount.create!(
      enterprise: other_ent, client_id: "c", client_secret: "s", realm_id: "r#{SecureRandom.hex(3)}",
    )
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "FC-#{SecureRandom.hex(2)}")
    EnterpriseForecastClient.create!(enterprise: other_ent, forecast_client_id: fc.forecast_id)
    ip = InvoicePass.find_or_create_by!(start_of_month: Date.new(2097, 3, 1))

    # Existing QboInvoice is in Sanctuary, but tracker's forecast_client routes to other_ent.
    qbo_id = "INV#{SecureRandom.hex(3)}"
    QboInvoice.create!(qbo_id: qbo_id, qbo_account: @sanctuary_qa, data: { "x" => 1 })
    tracker = InvoiceTracker.create!(invoice_pass: ip, forecast_client: fc, qbo_invoice_id: qbo_id)

    # Tracker's qa is other_qa; no QboInvoice matches there.
    assert_equal other_qa, tracker.qbo_account
    assert_nil tracker.qbo_invoice
    # And critically: no phantom row was created in other_qa.
    assert_nil QboInvoice.find_by(qbo_id: qbo_id, qbo_account_id: other_qa.id)
  end
end
