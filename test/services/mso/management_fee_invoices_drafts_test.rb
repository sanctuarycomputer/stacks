require "test_helper"

class Mso::ManagementFeeInvoicesDraftsTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2093, 9, 1))
    @sanctuary = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [990_001])
    @index = make_payer(Enterprise::INDEX_SPACE_NAME, customer_id: "5", forecast_ids: [990_002])
    stub_garden3d_qbo(customers: [qbo_customer("2", "Sanctuary Computer Inc"), qbo_customer("5", "Index Space LLC")])
  end

  def teardown
    clear_enterprise_memos
  end

  # --- create_drafts! --------------------------------------------------------

  test "it makes the trackers and pushes a draft for each payer" do
    Quickbooks::Service::Invoice.any_instance.expects(:create).twice
      .returns(qbo_created_invoice("9201")).then.returns(qbo_created_invoice("9202"))

    run = Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: @pass)

    assert_equal 2, run.created.size
    assert_equal [], run.already_drafted
    assert_equal [], run.failed
    assert_equal %w[9201 9202], InvoiceTracker.where(invoice_pass_id: @pass.id).order(:id).pluck(:qbo_invoice_id)
  end

  test "a tracker that already has an invoice is left alone" do
    existing = attach_invoice(fee_tracker(@pass, @sanctuary), qbo_id: "8000", total: "0.0", balance: "0.0", sent: false)
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(qbo_created_invoice("9203"))

    run = Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: @pass)

    assert_equal [existing.id], run.already_drafted.map(&:id)
    assert_equal 1, run.created.size
    assert_equal [], run.failed
    assert_equal "8000", existing.reload.qbo_invoice_id
  end

  test "one payer failing does not stop the others" do
    @sanctuary.update_columns(g3d_qbo_customer_id: "404")
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(qbo_created_invoice("9204"))

    run = Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: @pass)

    assert_equal 1, run.created.size
    assert_equal 1, run.failed.size
    failed_tracker, message = run.failed.first
    assert_equal 990_001, failed_tracker.forecast_client_id
    assert_match(/404/, message)
  end

  test "it refuses a pass that is not garden3d's" do
    pass = InvoicePass.create!(start_of_month: Date.new(2093, 9, 1), enterprise: enterprises(:sanctuary), data: {})
    Quickbooks::Service::Invoice.any_instance.expects(:create).never

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: pass)
    end
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  test "it refuses a month before drafting started, and makes no trackers" do
    pass = garden3d_pass(Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START - 1.month)
    Quickbooks::Service::Invoice.any_instance.expects(:create).never

    assert_raises(Mso::ManagementFeeInvoices::NotDraftable) do
      Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: pass)
    end
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  test "it refuses a pass that holds a legacy Forecast tracker" do
    fee_tracker(@pass, @sanctuary).update!(blueprint: { "lines" => {} })
    Quickbooks::Service::Invoice.any_instance.expects(:create).never

    assert_raises(Mso::ManagementFeeInvoices::NotDraftable) do
      Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: @pass)
    end
    assert_equal 1, InvoiceTracker.where(invoice_pass_id: @pass.id).count
  end

  # --- refresh! --------------------------------------------------------------
  # These run the real QboInvoice#sync!; only the QuickBooks fetch is stubbed.

  test "refresh stores what QuickBooks now says and counts it" do
    tracker = attach_invoice(fee_tracker(@pass, @sanctuary), qbo_id: "8001", total: "0.0", balance: "0.0", sent: false)
    fee_tracker(@pass, @index) # no invoice: not attempted
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.with("8001")
      .returns(qbo_created_invoice("8001", total: "130000", balance: "0", email_status: "EmailSent"))

    run = Mso::ManagementFeeInvoices.refresh!(invoice_pass: @pass)

    assert_equal [1, 1, 0, []], [run.attempted, run.succeeded, run.detached, run.failed]
    stored = QboInvoice.find_by(qbo_account_id: @qbo_account.id, qbo_id: "8001").read_attribute(:data)
    assert_equal "EmailSent", stored["email_status"]
    assert_equal BigDecimal("130000"), BigDecimal(stored["total"])
    assert_equal :paid, InvoiceTracker.find(tracker.id).status
  end

  test "a sync that fails is reported, not counted as refreshed" do
    tracker = attach_invoice(fee_tracker(@pass, @sanctuary), qbo_id: "8002", total: "0.0", balance: "0.0", sent: false)
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.raises(RuntimeError, "QuickBooks is down")

    run = Mso::ManagementFeeInvoices.refresh!(invoice_pass: @pass)

    assert_equal [1, 0, 0], [run.attempted, run.succeeded, run.detached]
    assert_equal [tracker.id], run.failed.map(&:id)
    assert_equal "8002", InvoiceTracker.find(tracker.id).qbo_invoice_id, "a failed read changes nothing"
  end

  test "an invoice deleted in QuickBooks is detached, and that is not a failure" do
    tracker = attach_invoice(fee_tracker(@pass, @sanctuary), qbo_id: "8003", total: "0.0", balance: "0.0", sent: false)
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once
      .raises(RuntimeError, "Object Not Found: Something you're trying to use has been made inactive.")

    run = Mso::ManagementFeeInvoices.refresh!(invoice_pass: @pass)

    assert_equal [1, 0, 1, []], [run.attempted, run.succeeded, run.detached, run.failed]
    assert_nil InvoiceTracker.find(tracker.id).qbo_invoice_id
    assert_equal :not_made, InvoiceTracker.find(tracker.id).status
  end

  test "refresh refuses a pass that is not garden3d's" do
    pass = InvoicePass.create!(start_of_month: Date.new(2093, 9, 1), enterprise: enterprises(:sanctuary), data: {})
    QboAccount.any_instance.expects(:fetch_invoice_by_id).never

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.refresh!(invoice_pass: pass)
    end
  end
end
