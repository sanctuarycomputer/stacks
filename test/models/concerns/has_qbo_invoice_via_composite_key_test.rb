require "test_helper"

class HasQboInvoiceViaCompositeKeyTest < ActiveSupport::TestCase
  def setup
    # Sanctuary has two qbo_account fixtures; pin the one has_one picks.
    @sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    @other_qa = QboAccount.create!(enterprise: enterprises(:garden3d), realm_id: "g-#{SecureRandom.hex(4)}",
                                   client_id: "x", client_secret: "y")
    pass = InvoicePass.create!(start_of_month: Date.new(2089, 1, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 930_101, name: "Composite Key Co")
    @tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                      qbo_account: @sanctuary_qa)
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  def invoice!(qbo_account, qbo_id, total)
    QboInvoice.create!(qbo_account: qbo_account, qbo_id: qbo_id,
                       data: { "total" => total, "balance" => "0.0", "email_status" => "EmailSent",
                               "due_date" => "2999-01-01" })
  end

  test "a preloaded invoice from another QuickBooks account is not this tracker's invoice" do
    # Only the OTHER account holds invoice 1001, so a preload by qbo_id alone
    # can find nothing else. update_columns: the model's own validation would
    # (rightly) refuse this pair.
    invoice!(@other_qa, "1001", "170000.0")
    @tracker.update_columns(qbo_invoice_id: "1001")

    preloaded = InvoiceTracker.includes(:qbo_invoice).find(@tracker.id)

    assert_nil preloaded.qbo_invoice
    assert_equal :not_made, preloaded.status
  end

  test "with the same id in two accounts, the tracker reads its own account's invoice" do
    mine = invoice!(@sanctuary_qa, "1002", "500.0")
    theirs = invoice!(@other_qa, "1002", "170000.0")
    @tracker.update!(qbo_invoice_id: "1002")
    tracker = InvoiceTracker.find(@tracker.id)
    # Exactly what a preload by qbo_id alone can leave behind.
    tracker.association(:qbo_invoice).target = theirs

    assert_equal mine, tracker.qbo_invoice
    assert_equal 500.0, tracker.value
    assert_equal mine, tracker.qbo_invoice, "and the corrected row is what stays in memory"
  end

  test "an in-memory invoice from the tracker's own account is still used without a query" do
    mine = invoice!(@sanctuary_qa, "1003", "500.0")
    @tracker.update!(qbo_invoice_id: "1003")
    tracker = InvoiceTracker.includes(:qbo_invoice).find(@tracker.id)

    queries = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*| queries += 1 }
    assert_equal mine, tracker.qbo_invoice
    assert_equal 0, queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
