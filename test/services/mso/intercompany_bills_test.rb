require "test_helper"
require "ostruct"

# A garden3d invoice, mirrored as a bill in the paying company's QuickBooks.
class Mso::IntercompanyBillsTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  MONTH = Date.new(2095, 9, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @payer = make_payer(Enterprise::INDEX_SPACE_NAME, forecast_ids: [rand(1_000_000..2_000_000_000)])
    @payer.update!(g3d_qbo_vendor_id: "32")
    @payer_qbo = QboAccount.create!(enterprise: @payer, realm_id: "idx-#{SecureRandom.hex(4)}", client_id: "x",
                                    client_secret: "y")
    @tracker = fee_tracker(@pass, @payer)
    attach_invoice(@tracker, qbo_id: "9001", total: "140000", balance: "0", sent: true)

    @invoice = invoice(lines: [["Managerial Services", "Management fee", "136000"], ["Loan Repayment", nil, "4000"],
                               ["Managerial Services", "nothing", "0"]])
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token).returns(:token)
    QboAccount.any_instance.stubs(:fetch_invoice_by_id).with("9001").returns(@invoice)
    QboAccount.any_instance.stubs(:fetch_all_accounts)
      .returns([account("9100", 91), account("9500", 95), account("8300", 83)])
    QboAccount.any_instance.stubs(:fetch_all_vendors)
      .returns([OpenStruct.new(id: "32", display_name: "garden3d, LLC", active?: true)])
    QboAccount.any_instance.stubs(:fetch_all_terms).returns([OpenStruct.new(id: "2", name: "Net 15", due_days: 15)])
    Quickbooks::Service::Bill.any_instance.stubs(:access_token=)
    Quickbooks::Service::Bill.any_instance.stubs(:query).returns(OpenStruct.new(entries: []))
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(RuntimeError, "unexpected bill create")
    Quickbooks::Service::Bill.any_instance.stubs(:update).raises(RuntimeError, "unexpected bill update")
    Quickbooks::Service::Invoice.any_instance.stubs(:create).raises(RuntimeError, "unexpected invoice write")
  end

  def teardown
    clear_enterprise_memos
  end

  def account(number, id)
    OpenStruct.new(acct_num: number, id: id)
  end

  # [[item name, description, amount], ...]
  def invoice(lines:, doc_number: "1052", txn_date: MONTH.end_of_month)
    inv = Quickbooks::Model::Invoice.new
    inv.id = "9001"
    inv.doc_number = doc_number
    inv.txn_date = txn_date
    inv.total = lines.sum { |_, _, amount| BigDecimal(amount) }
    lines.each do |item, description, amount|
      line = Quickbooks::Model::InvoiceLineItem.new
      line.description = description
      line.amount = BigDecimal(amount)
      line.sales_item! { |detail| detail.item_ref = Quickbooks::Model::BaseReference.new("1", name: item) }
      inv.line_items << line
    end
    inv
  end

  def saved_bill(id = "7001")
    bill = Quickbooks::Model::Bill.new
    bill.id = id
    bill.doc_number = "1052"
    bill
  end

  def remote_bill(id: "7001", total: "140000", balance: "140000")
    bill = Quickbooks::Model::Bill.new
    bill.id = id
    bill.doc_number = "1052"
    bill.total = BigDecimal(total)
    bill.balance = BigDecimal(balance)
    bill
  end

  def sync!
    Mso::IntercompanyBills.sync_bill!(invoice_tracker: InvoiceTracker.find(@tracker.id))
  end

  def bill_id
    InvoiceTracker.find(@tracker.id).payer_qbo_bill_id
  end

  test "the bill carries the invoice's number and date, Net 15, from garden3d's vendor, a line per invoice line" do
    sent = []
    Quickbooks::Service::Bill.any_instance.expects(:create).once.with { |bill| sent << bill }.returns(saved_bill)

    sync!

    bill = sent.first
    assert_equal "32", bill.vendor_ref.value
    assert_equal "1052", bill.doc_number
    assert_equal MONTH.end_of_month, bill.txn_date
    assert_equal MONTH.end_of_month + 15, bill.due_date
    assert_equal "2", bill.sales_term_ref.value
    assert_equal [[BigDecimal("136000"), "Management fee", 91], [BigDecimal("4000"), "Loan Repayment", 95]],
                 bill.line_items.map { |l| [l.amount, l.description, l.account_based_expense_line_detail.account_ref.value] }
    assert_equal "7001", bill_id
  end

  test "an invoice line whose item has no account in the payer's books refuses the whole bill" do
    # USB Club's loan item, on an invoice to Index Space: Index's books have no account for it.
    QboAccount.any_instance.stubs(:fetch_invoice_by_id)
      .returns(invoice(lines: [["Managerial Services", nil, "1000"], ["USB Loan Repayment", nil, "500"]]))
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    error = assert_raises(Mso::IntercompanyBills::Misconfigured) { sync! }

    assert_match(/"USB Loan Repayment" line/, error.message)
    assert_nil bill_id
  end

  test "an account missing from the payer's chart refuses the bill" do
    QboAccount.any_instance.stubs(:fetch_all_accounts).returns([account("9100", 91)])
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    error = assert_raises(Mso::IntercompanyBills::Misconfigured) { sync! }

    assert_match(/no account 9500/, error.message)
  end

  test "a $0.00 invoice, or a tracker with no invoice, is not ready" do
    QboAccount.any_instance.stubs(:fetch_invoice_by_id).returns(invoice(lines: [["Managerial Services", nil, "0"]]))
    assert_raises(Mso::IntercompanyBills::NotReady) { sync! }

    @tracker.update!(qbo_invoice_id: nil)
    assert_raises(Mso::IntercompanyBills::NotReady) { sync! }
  end

  test "without an active garden3d vendor in the payer's books nothing is written" do
    @payer.update!(g3d_qbo_vendor_id: nil)
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    error = assert_raises(Mso::IntercompanyBills::Misconfigured) { sync! }

    assert_match(/garden3d vendor/, error.message)
  end

  test "a bill already in the payer's QuickBooks with the invoice's number is attached, not duplicated" do
    Quickbooks::Service::Bill.any_instance.stubs(:query).returns(OpenStruct.new(entries: [remote_bill(id: "6500")]))
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    error = assert_raises(Mso::IntercompanyBills::NotReady) { sync! }

    assert_match(/attached it/, error.message)
    assert_equal "6500", bill_id, "the attach is kept, not rolled back with the refusal"
  end

  test "an attached, unpaid bill is rewritten to match the invoice" do
    @tracker.update!(payer_qbo_bill_id: "7001")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).with("7001").returns(remote_bill)
    sent = []
    Quickbooks::Service::Bill.any_instance.expects(:update).once.with { |bill| sent << bill }.returns(saved_bill)

    sync!

    assert_equal "7001", sent.first.id
    assert_equal BigDecimal("140000"), sent.first.line_items.sum(&:amount)
  end

  test "a bill with any payment is never changed" do
    @tracker.update!(payer_qbo_bill_id: "7001")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).returns(remote_bill(balance: "100000"))
    Quickbooks::Service::Bill.any_instance.expects(:update).never

    assert_raises(Mso::IntercompanyBills::PaidBill) { sync! }
    assert_equal "7001", bill_id
  end

  test "a bill deleted in QuickBooks is detached, and the detach is kept" do
    @tracker.update!(payer_qbo_bill_id: "7001")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "Object Not Found: bill 7001")
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    error = assert_raises(Mso::IntercompanyBills::NotReady) { sync! }

    assert_match(/7001 is no longer/, error.message)
    assert_nil bill_id
  end

  test "a tracker on a month before intercompany invoicing began is refused" do
    old_pass = garden3d_pass(Date.new(2025, 8, 1))
    @tracker.update_columns(invoice_pass_id: old_pass.id)
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    assert_raises(Mso::IntercompanyBills::Misconfigured) { sync! }
  end
end
