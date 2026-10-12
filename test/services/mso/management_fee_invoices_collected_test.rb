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
      .returns(qbo_created_invoice("k-1", total: "130000", balance: "0", email_status: "EmailSent"))

    assert Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "it reads QuickBooks first, so a stale paid snapshot cannot hide an unpaid invoice" do
    mirror = QboInvoice.find_by!(qbo_account_id: @qbo_account.id, qbo_id: "k-1")
    mirror.update!(data: mirror.read_attribute(:data).merge("email_status" => "EmailSent", "total" => "130000.0"))
    assert InvoicePass.find(@pass.id).management_fee_collected?, "sanity: the stored snapshot says paid"
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once
      .returns(qbo_created_invoice("k-1", total: "130000", balance: "130000", email_status: "EmailSent"))

    refute Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "it raises when an invoice cannot be read, rather than answer from a stale copy" do
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.raises(RuntimeError, "QuickBooks is down")

    error = assert_raises(Mso::ManagementFeeInvoices::RefreshFailed) do
      Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
    end

    assert_match(/InvoiceTracker #{@tracker.id}/, error.message)
  end

  test "it refuses a pass that is not garden3d's" do
    pass = InvoicePass.create!(start_of_month: Date.new(2091, 7, 1), enterprise: enterprises(:sanctuary), data: {})
    QboAccount.any_instance.expects(:fetch_invoice_by_id).never

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.collected?(invoice_pass: pass)
    end
  end
end
