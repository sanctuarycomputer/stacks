require "test_helper"

class Mso::ManagementFeeInvoicesCollectedTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2091, 7, 1))
    @payer = make_payer(Enterprise::SANCTUARY_NAME, forecast_ids: [992_101])
    # Exactly what push_invoice! leaves behind: an unsent $0.00 snapshot.
    @tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "k-1", total: "0.0", balance: "0.0", sent: false)
  end

  def teardown
    clear_enterprise_memos
  end

  test "it reads QuickBooks first, so a stale draft snapshot cannot hide a paid invoice" do
    refute InvoicePass.find(@pass.id).management_fee_collected?, "sanity: the stored snapshot says nobody was charged"
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.with("k-1")
      .returns(qbo_created_invoice("k-1", total: "130000", balance: "0", email_status: "EmailSent",
                                          txn_date: Date.new(2091, 7, 31)))

    assert Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "it reads QuickBooks first, so a stale paid snapshot cannot hide an unpaid invoice" do
    mirror = QboInvoice.find_by!(qbo_account_id: @qbo_account.id, qbo_id: "k-1")
    mirror.update!(data: mirror.read_attribute(:data).merge("email_status" => "EmailSent", "total" => "130000.0"))
    assert InvoicePass.find(@pass.id).management_fee_collected?, "sanity: the stored snapshot says paid"
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once
      .returns(qbo_created_invoice("k-1", total: "130000", balance: "130000", email_status: "EmailSent",
                                          txn_date: Date.new(2091, 7, 31)))

    refute Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  # --- the refreshed answer is the pure rule's, fail-closed parts included ----

  def paid_in(txn_date)
    qbo_created_invoice("k-1", total: "130000", balance: "0", email_status: "EmailSent", txn_date: txn_date)
  end

  test "a refreshed invoice that turns out to be dated another month is not collected" do
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.returns(paid_in(Date.new(2091, 8, 1)))

    refute Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "a refreshed invoice with no date is not collected" do
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.returns(paid_in(nil))

    refute Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "a payer with no tracker on the pass is not collected, however the refresh goes" do
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.returns(paid_in(Date.new(2091, 7, 31)))
    make_payer(Enterprise::INDEX_SPACE_NAME, forecast_ids: [992_103])

    refute Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "an unattached invoice to a payer in the pass month is not collected, and is not read" do
    @payer.update_columns(g3d_qbo_customer_id: "2")
    # Only the attached invoice is refreshed.
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.with("k-1").returns(paid_in(Date.new(2091, 7, 31)))
    mirror_invoice(@qbo_account, qbo_id: "k-9", total: "5000.0", balance: "0.0", sent: true,
                                 txn_date: Date.new(2091, 7, 20), customer_id: "2")

    refute Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "an unattached invoice to a non-payer, or in another month, does not stop a collected answer" do
    @payer.update_columns(g3d_qbo_customer_id: "2")
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.with("k-1").returns(paid_in(Date.new(2091, 7, 31)))
    mirror_invoice(@qbo_account, qbo_id: "k-10", total: "5000.0", balance: "5000.0", sent: true,
                                 txn_date: Date.new(2091, 7, 20), customer_id: "9")
    mirror_invoice(@qbo_account, qbo_id: "k-11", total: "5000.0", balance: "5000.0", sent: true,
                                 txn_date: Date.new(2091, 8, 1), customer_id: "2")

    assert Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "it raises when an invoice cannot be read, rather than answer from a stale copy" do
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.raises(RuntimeError, "QuickBooks is down")

    error = assert_raises(Mso::ManagementFeeInvoices::RefreshFailed) do
      Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
    end

    assert_match(/InvoiceTracker #{@tracker.id}/, error.message)
  end

  test "an invoice deleted in QuickBooks leaves its tracker with nothing attached: not collected" do
    other = make_payer(Enterprise::INDEX_SPACE_NAME, forecast_ids: [992_102])
    attach_invoice(fee_tracker(@pass, other), qbo_id: "k-2", total: "40000.0", balance: "0.0", sent: true)
    QboAccount.any_instance.stubs(:fetch_invoice_by_id).with("k-2")
      .returns(qbo_created_invoice("k-2", total: "40000", balance: "0", email_status: "EmailSent",
                                          txn_date: Date.new(2091, 7, 31)))
    QboAccount.any_instance.stubs(:fetch_invoice_by_id).with("k-1")
      .raises(RuntimeError, "Object Not Found: Something you're trying to use has been made inactive.")

    refute Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
    assert_nil InvoiceTracker.find(@tracker.id).qbo_invoice_id
  end

  test "it refuses a pass that is not garden3d's" do
    pass = InvoicePass.create!(start_of_month: Date.new(2091, 7, 1), enterprise: enterprises(:sanctuary), data: {})
    QboAccount.any_instance.expects(:fetch_invoice_by_id).never

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.collected?(invoice_pass: pass)
    end
  end
end
