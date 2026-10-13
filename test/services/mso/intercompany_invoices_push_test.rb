require "test_helper"

class Mso::IntercompanyInvoicesPushTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2095, 9, 1))
    @payer = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [960_001])
    @tracker = fee_tracker(@pass, @payer)
    @customers = [qbo_customer("2", "Sanctuary Computer Inc"), qbo_customer("55", "Someone Else")]
    stub_garden3d_qbo(customers: @customers)
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    clear_enterprise_memos
  end

  # Expects exactly one invoice write and returns what was sent.
  def expect_one_draft(qbo_id = "9001")
    sent = []
    Quickbooks::Service::Invoice.any_instance.expects(:create).once
      .with { |invoice| sent << invoice }
      .returns(qbo_created_invoice(qbo_id))
    sent
  end

  def forbid_writes
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    Quickbooks::Service::Customer.any_instance.expects(:create).never
  end

  def push
    Mso::IntercompanyInvoices.push_invoice!(invoice_tracker: @tracker)
  end

  def unattached?
    InvoiceTracker.find(@tracker.id).qbo_invoice_id.nil?
  end

  # --- the draft -------------------------------------------------------------

  test "the draft is one $0.00 Management fee line on Managerial Services, Net 15, dated month end" do
    sent = expect_one_draft

    push

    invoice = sent.first
    assert_equal "2", invoice.customer_ref.value
    assert_equal Date.new(2095, 9, 30), invoice.txn_date
    assert_equal "2", invoice.sales_term_ref.value
    assert_equal "September 2095", invoice.private_note
    assert_nil invoice.customer_memo

    assert_equal 1, invoice.line_items.size
    line = invoice.line_items.first
    assert_equal "Management fee", line.description
    assert_equal BigDecimal("0"), line.amount
    assert line.sales_item?
    assert_equal "2", line.sales_line_item_detail.item_ref.value, "Managerial Services, not the default Services item"
    assert_equal BigDecimal("0"), line.sales_line_item_detail.unit_price
    assert_equal 1, line.sales_line_item_detail.quantity
  end

  test "it records the invoice with its data and attaches it to the tracker" do
    expect_one_draft("9001")

    mirror = push

    assert_kind_of QboInvoice, mirror
    assert_equal "9001", mirror.qbo_id
    assert_equal @qbo_account.id, mirror.qbo_account_id
    assert_equal "NotSet", mirror.read_attribute(:data)["email_status"]

    tracker = InvoiceTracker.find(@tracker.id)
    assert_equal "9001", tracker.qbo_invoice_id
    assert_nil tracker.blueprint
    assert_equal :not_sent, tracker.status
  end

  # --- the customer ----------------------------------------------------------

  test "a stored customer id means no customer is ever created" do
    expect_one_draft
    Quickbooks::Service::Customer.any_instance.expects(:create).never

    push
  end

  test "a stored customer id that is not an active customer raises and pushes nothing" do
    @payer.update_columns(g3d_qbo_customer_id: "404")
    forbid_writes

    error = assert_raises(Mso::IntercompanyInvoices::Misconfigured) { push }

    assert_match(/404/, error.message)
    assert unattached?
  end

  # --- configuration ---------------------------------------------------------

  test "a missing Managerial Services item raises and never falls back to Services" do
    stub_garden3d_qbo(items: [qbo_item("1", "Services")], customers: @customers)
    forbid_writes

    error = assert_raises(Mso::IntercompanyInvoices::Misconfigured) { push }

    assert_match(/Managerial Services/, error.message)
  end

  test "a missing 15-day payment term raises" do
    stub_garden3d_qbo(terms: [qbo_term("1", "Net 30", 30)], customers: @customers)
    forbid_writes

    error = assert_raises(Mso::IntercompanyInvoices::Misconfigured) { push }

    assert_match(/15 days/, error.message)
  end

  test "a tracker that already has an invoice raises instead of doing nothing" do
    @tracker = attach_invoice(@tracker, qbo_id: "8000", total: "0.0", balance: "0.0", sent: false)
    forbid_writes

    error = assert_raises(Mso::IntercompanyInvoices::PushFailed) { push }

    assert_match(/already has QuickBooks invoice 8000/, error.message)
  end

  test "a tracker that gains an invoice while this push is still preparing is refused under the lock" do
    # The double click: both requests pass the first check. This one is still
    # reading QuickBooks when the other attaches its draft.
    account = @tracker.qbo_account
    tracker_id = @tracker.id
    customers = @customers
    account.define_singleton_method(:fetch_all_customers) do
      QboInvoice.create!(qbo_account_id: id, qbo_id: "7777", data: { "id" => "7777", "total" => "0.0" })
      InvoiceTracker.where(id: tracker_id).update_all(qbo_invoice_id: "7777")
      customers
    end
    Quickbooks::Service::Invoice.any_instance.expects(:query).never
    forbid_writes

    error = assert_raises(Mso::IntercompanyInvoices::PushFailed) { push }

    assert_match(/already has QuickBooks invoice 7777/, error.message)
    assert_equal "7777", InvoiceTracker.find(@tracker.id).qbo_invoice_id
  end

  test "a blank invoice id is no invoice: the push goes ahead" do
    # "" is what a cleared form field leaves behind, and QboInvoice#sync!
    # treats a mirror with that id as junk. It must not block a draft forever.
    QboInvoice.create!(qbo_account: @qbo_account, qbo_id: "", data: { "total" => "0.0" })
    @tracker.update_columns(qbo_invoice_id: "")
    expect_one_draft("9002")

    push

    assert_equal "9002", InvoiceTracker.find(@tracker.id).qbo_invoice_id
  end

  test "a tracker bound to another company's QuickBooks account is refused before any QuickBooks call" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    @tracker.update_columns(qbo_account_id: sanctuary_qa.id)
    @tracker = InvoiceTracker.find(@tracker.id)
    QboAccount.any_instance.expects(:fetch_all_items).never
    QboAccount.any_instance.expects(:fetch_all_terms).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    Quickbooks::Service::Invoice.any_instance.expects(:query).never
    forbid_writes

    error = assert_raises(Mso::IntercompanyInvoices::Misconfigured) { push }

    assert_match(/InvoiceTracker #{@tracker.id} is bound to a QuickBooks account that is not garden3d, LLC's/,
                 error.message)
    assert unattached?
  end

  test "a tracker on Sanctuary's pass is refused" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 9, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 960_002, name: "External Co")
    @tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                      qbo_account: sanctuary_qa)
    forbid_writes

    assert_raises(Mso::IntercompanyInvoices::Misconfigured) { push }
  end

  test "an enterprise with no stored customer id is not billed: Stacks never creates a customer" do
    @payer.update_columns(g3d_qbo_customer_id: nil)
    forbid_writes

    error = assert_raises(Mso::IntercompanyInvoices::Misconfigured) { push }

    assert_match(/not on the internal Forecast client of an enterprise garden3d, LLC bills/, error.message)
    assert unattached?
  end

  test "QuickBooks answering without an invoice is a failure, not a success" do
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(nil)

    assert_raises(Mso::IntercompanyInvoices::PushFailed) { push }

    assert unattached?
    assert_equal 0, QboInvoice.where(qbo_account_id: @qbo_account.id).count
  end

  # --- refusing to double-invoice -------------------------------------------

  test "it refuses when QuickBooks already holds an invoice for that customer in the month, naming it" do
    stub_garden3d_qbo(customers: @customers,
                      invoices_in_month: [qbo_created_invoice("4411", total: "135000"), qbo_created_invoice("4412")])
    forbid_writes

    error = assert_raises(Mso::IntercompanyInvoices::AlreadyInvoiced) { push }

    assert_match(/4411/, error.message)
    assert_match(/4412/, error.message)
    assert unattached?
  end

  test "a refused push leaves the invoices it found attachable from the tracker's edit page" do
    # garden3d has no invoice mirror of its own, and Refresh only re-reads
    # attached invoices: without these rows the dropdown could never offer them.
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    stub_garden3d_qbo(customers: @customers,
                      invoices_in_month: [qbo_created_invoice("4411", total: "135000", balance: "135000"),
                                          qbo_created_invoice("4412")])
    forbid_writes

    error = assert_raises(Mso::IntercompanyInvoices::AlreadyInvoiced) { push }

    mirrors = QboInvoice.where(qbo_id: %w[4411 4412]).order(:qbo_id).to_a
    assert_equal %w[4411 4412], mirrors.map(&:qbo_id)
    assert_equal [@qbo_account.id], mirrors.map(&:qbo_account_id).uniq
    assert_equal BigDecimal("135000"), BigDecimal(mirrors.first.read_attribute(:data)["total"])
    assert_equal "NotSet", mirrors.last.read_attribute(:data)["email_status"]
    assert_equal %w[4411 4412], QboInvoice.orphans.where(qbo_account_id: @qbo_account.id).pluck(:qbo_id).sort
    assert_equal 0, QboInvoice.where(qbo_account_id: sanctuary_qa.id, qbo_id: %w[4411 4412]).count
    assert_match(/listed on the tracker's edit page/, error.message)
    assert_no_match(/Refresh/, error.message)
    assert unattached?
  end

  test "a second refused push does not duplicate the mirrored invoices, and stores what QuickBooks says now" do
    stub_garden3d_qbo(customers: @customers, invoices_in_month: [qbo_created_invoice("4411", total: "135000")])
    assert_raises(Mso::IntercompanyInvoices::AlreadyInvoiced) { push }

    stub_garden3d_qbo(customers: @customers,
                      invoices_in_month: [qbo_created_invoice("4411", total: "140000", email_status: "EmailSent")])
    forbid_writes

    assert_no_difference -> { QboInvoice.count } do
      assert_raises(Mso::IntercompanyInvoices::AlreadyInvoiced) { push }
    end

    stored = QboInvoice.find_by!(qbo_account_id: @qbo_account.id, qbo_id: "4411").read_attribute(:data)
    assert_equal BigDecimal("140000"), BigDecimal(stored["total"])
    assert_equal "EmailSent", stored["email_status"]
  end

  test "an invoice found by the pre-flight that is already attached elsewhere stays attached" do
    other = make_payer("Other Payer #{SecureRandom.hex(3)}")
    elsewhere = attach_invoice(fee_tracker(@pass, other), qbo_id: "4411", total: "0.0", balance: "0.0", sent: false)
    stub_garden3d_qbo(customers: @customers, invoices_in_month: [qbo_created_invoice("4411", total: "135000")])
    forbid_writes

    assert_raises(Mso::IntercompanyInvoices::AlreadyInvoiced) { push }

    assert_equal "4411", InvoiceTracker.find(elsewhere.id).qbo_invoice_id
    assert_equal 1, QboInvoice.where(qbo_account_id: @qbo_account.id, qbo_id: "4411").count
  end

  test "the pre-flight asks QuickBooks about this customer and this month only" do
    queries = []
    Quickbooks::Service::Invoice.any_instance.stubs(:query)
      .with { |query, _options| queries << query }
      .returns(qbo_collection([]))
    expect_one_draft

    push

    assert_equal 1, queries.size
    assert_match(/FROM Invoice/i, queries.first)
    assert_match(/CustomerRef = '2'/, queries.first)
    assert_match(/TxnDate >= '2095-09-01'/, queries.first)
    assert_match(/TxnDate <= '2095-09-30'/, queries.first)
  end

  test "a pass before the start month is refused without asking QuickBooks anything" do
    pass = garden3d_pass(InvoicePass::INTERCOMPANY_START - 1.month)
    @tracker = fee_tracker(pass, @payer)
    QboAccount.any_instance.expects(:fetch_all_items).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    Quickbooks::Service::Invoice.any_instance.expects(:query).never
    forbid_writes

    assert_raises(Mso::IntercompanyInvoices::Misconfigured) { push }
    assert_equal Date.new(2026, 8, 1), InvoicePass::INTERCOMPANY_START
  end

end
