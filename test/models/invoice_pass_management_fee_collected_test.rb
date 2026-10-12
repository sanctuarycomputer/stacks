require "test_helper"

class InvoicePassManagementFeeCollectedTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2091, 6, 1))
    @sanctuary = make_payer(Enterprise::SANCTUARY_NAME, forecast_ids: [992_001])
    @index = make_payer(Enterprise::INDEX_SPACE_NAME, forecast_ids: [992_002])
    # The pure rule must never read QuickBooks.
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    clear_enterprise_memos
  end

  def collected?
    InvoicePass.find(@pass.id).management_fee_collected?
  end

  def invoice_for(payer, qbo_id, total:, balance:, sent:, private_note: nil)
    tracker = attach_invoice(fee_tracker(@pass, payer), qbo_id: qbo_id, total: total, balance: balance, sent: sent)
    if private_note
      mirror = QboInvoice.find_by!(qbo_account_id: @qbo_account.id, qbo_id: qbo_id)
      mirror.update!(data: mirror.read_attribute(:data).merge("private_note" => private_note))
    end
    tracker
  end

  # --- nothing charged -------------------------------------------------------

  test "not collected when the pass has no trackers" do
    refute collected?
  end

  test "not collected when every invoice is an untouched draft" do
    invoice_for(@sanctuary, "c-1", total: "0.0", balance: "0.0", sent: false)
    invoice_for(@index, "c-2", total: "0.0", balance: "0.0", sent: false)

    refute collected?
  end

  # --- sent invoices ---------------------------------------------------------

  test "collected when the one sent invoice is paid in full" do
    invoice_for(@sanctuary, "c-3", total: "130000.0", balance: "0.0", sent: true)

    assert collected?
  end

  test "not collected while a sent invoice is unpaid" do
    invoice_for(@sanctuary, "c-4", total: "130000.0", balance: "130000.0", sent: true)

    refute collected?
  end

  test "not collected while a sent invoice is partly paid" do
    invoice_for(@sanctuary, "c-5", total: "130000.0", balance: "0.01", sent: true)

    refute collected?
  end

  test "a sent $0.00 invoice is not collected, though QuickBooks status calls it paid" do
    tracker = invoice_for(@sanctuary, "c-6", total: "0.0", balance: "0.0", sent: true)

    assert_equal :paid, tracker.qbo_invoice.status, "the trap this rule exists for"
    refute collected?
  end

  test "not collected when one of two sent invoices is unpaid" do
    invoice_for(@sanctuary, "c-10", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-11", total: "40000.0", balance: "40000.0", sent: true)

    refute collected?
  end

  # --- who is ignored --------------------------------------------------------

  test "an untouched draft is ignored when another payer's invoice is sent and paid" do
    invoice_for(@sanctuary, "c-7", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-8", total: "0.0", balance: "0.0", sent: false)

    assert collected?
  end

  # --- a tracker with nothing attached ---------------------------------------

  test "a payer's tracker with no invoice attached is unknown: not collected" do
    # Stacks cannot see whether this payer was charged. The pre-flight may
    # have refused to draft because Finance invoiced it by hand.
    invoice_for(@sanctuary, "c-9", total: "130000.0", balance: "0.0", sent: true)
    fee_tracker(@pass, @index)

    refute collected?
  end

  test "a blank invoice id is no invoice: not collected" do
    invoice_for(@sanctuary, "c-14", total: "130000.0", balance: "0.0", sent: true)
    QboInvoice.create!(qbo_account: @qbo_account, qbo_id: "", data: { "total" => "0.0" })
    fee_tracker(@pass, @index).update_columns(qbo_invoice_id: "")

    refute collected?
  end

  test "a legacy Forecast tracker with no invoice is not a fee tracker and does not block" do
    invoice_for(@sanctuary, "c-15", total: "130000.0", balance: "0.0", sent: true)
    fee_tracker(@pass, @index).update!(blueprint: { "lines" => {} })

    assert collected?
  end

  # --- an amount is a charge, emailed or not ---------------------------------

  test "an unsent invoice with an amount is a charge: unpaid, it blocks collection" do
    # Finance set the amount but never emailed it from QuickBooks. It still
    # posts to account 4100 and raises the cap, so it must be paid first.
    invoice_for(@sanctuary, "c-20", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-21", total: "40000.0", balance: "40000.0", sent: false)

    refute collected?
  end

  test "an unsent invoice with an amount, paid in full, is collected" do
    # An intercompany invoice recorded as paid without ever being emailed.
    invoice_for(@sanctuary, "c-22", total: "130000.0", balance: "0.0", sent: false)

    assert collected?
  end

  # --- voided ----------------------------------------------------------------

  test "a sent-then-voided invoice is not a charge and is ignored" do
    invoice_for(@sanctuary, "c-30", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-31", total: "0.0", balance: "0.0", sent: true, private_note: "Voided - sent in error")

    assert collected?
  end

  test "a pass whose only invoice was voided has collected nothing" do
    invoice_for(@sanctuary, "c-32", total: "0.0", balance: "0.0", sent: true, private_note: "Voided")

    refute collected?
  end

  test "a note that merely mentions a voided invoice does not hide an unpaid charge" do
    invoice_for(@sanctuary, "c-33", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-34", total: "40000.0", balance: "40000.0", sent: true, private_note: "replaces voided #12")

    refute collected?
  end

  test "a voided note on an invoice that still has an amount is not believed" do
    # QuickBooks zeroes a voided invoice. One that still carries a total was
    # not voided, whatever its note says.
    invoice_for(@sanctuary, "c-35", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-36", total: "40000.0", balance: "40000.0", sent: false, private_note: "Voided")

    refute collected?
  end

  # --- unknown, and misuse ---------------------------------------------------

  test "an invoice that was never synced is unknown: not collected, and not fetched" do
    invoice_for(@sanctuary, "c-12", total: "130000.0", balance: "0.0", sent: true)
    tracker = fee_tracker(@pass, @index)
    QboInvoice.create!(qbo_account: @qbo_account, qbo_id: "c-13", data: {})
    tracker.update!(qbo_invoice_id: "c-13")

    refute collected?
  end

  test "a tracker pointed at another company's QuickBooks account raises" do
    invoice_for(@sanctuary, "c-40", total: "130000.0", balance: "0.0", sent: true)
    tracker = fee_tracker(@pass, @index)
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    QboInvoice.create!(qbo_account: sanctuary_qa, qbo_id: "c-41",
                       data: { "total" => "40000.0", "balance" => "0.0", "email_status" => "EmailSent" })
    tracker.update!(qbo_account: sanctuary_qa, qbo_invoice_id: "c-41")

    error = assert_raises(RuntimeError) { collected? }

    assert_match(/InvoiceTracker #{tracker.id}/, error.message)
    assert_match(/not garden3d, LLC's/, error.message)
  end

  test "it refuses to answer for a pass that is not garden3d's" do
    pass = InvoicePass.create!(start_of_month: Date.new(2091, 6, 1), enterprise: enterprises(:sanctuary), data: {})

    error = assert_raises(RuntimeError) { pass.management_fee_collected? }

    assert_match(/only applies to garden3d, LLC's passes/, error.message)
  end
end
