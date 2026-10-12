require "test_helper"

class Mso::ManagementFeeInvoicesPushTest < ActiveSupport::TestCase
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
    Mso::ManagementFeeInvoices.push_invoice!(invoice_tracker: @tracker)
  end

  def unattached?
    InvoiceTracker.find(@tracker.id).qbo_invoice_id.nil?
  end

  # No id stored, and no active customer carrying the payer's name.
  def blank_customer_id!(customers: [qbo_customer("55", "Someone Else")])
    @payer.update_columns(g3d_qbo_customer_id: nil)
    stub_garden3d_qbo(customers: customers)
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

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/404/, error.message)
    assert unattached?
  end

  test "a blank customer id creates the customer once, named after the enterprise, and stores its id" do
    blank_customer_id!
    created_customers = []
    Quickbooks::Service::Customer.any_instance.expects(:create).once
      .with { |customer| created_customers << customer }
      .returns(qbo_customer("77", Enterprise::SANCTUARY_NAME))
    sent = expect_one_draft

    push

    assert_equal Enterprise::SANCTUARY_NAME, created_customers.first.display_name
    assert_equal "77", @payer.reload.g3d_qbo_customer_id
    assert_equal "77", sent.first.customer_ref.value
  end

  test "a created customer's id survives the invoice push failing" do
    blank_customer_id!
    Quickbooks::Service::Customer.any_instance.expects(:create).once
      .returns(qbo_customer("77", Enterprise::SANCTUARY_NAME))
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.raises(RuntimeError, "QuickBooks is down")

    assert_raises(RuntimeError) { push }

    assert_equal "77", @payer.reload.g3d_qbo_customer_id, "or the next attempt creates a second customer"
    assert unattached?
  end

  test "a blank id with an active customer already carrying the payer's name raises; it neither creates nor adopts" do
    # What a lost response leaves behind: QuickBooks made the customer, Stacks
    # never learned its id.
    blank_customer_id!(customers: [qbo_customer("55", "Someone Else"),
                                    qbo_customer("77", Enterprise::SANCTUARY_NAME.upcase)])
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/\b77\b/, error.message)
    assert_nil @payer.reload.g3d_qbo_customer_id
    assert unattached?
  end

  test "QuickBooks refusing the name as a duplicate is the same configuration error" do
    # Names are unique across customers, vendors and employees, and across
    # inactive ones, none of which the active-customer check above can see.
    blank_customer_id!
    duplicate = Quickbooks::IntuitRequestException.new("Duplicate Name Exists Error:\n\tThe name supplied already exists.")
    duplicate.code = "6240"
    Quickbooks::Service::Customer.any_instance.expects(:create).once.raises(duplicate)
    Quickbooks::Service::Invoice.any_instance.expects(:create).never

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/already has that name/, error.message)
    assert_nil @payer.reload.g3d_qbo_customer_id
  end

  # --- configuration ---------------------------------------------------------

  test "a missing Managerial Services item raises and never falls back to Services" do
    stub_garden3d_qbo(items: [qbo_item("1", "Services")], customers: @customers)
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/Managerial Services/, error.message)
  end

  test "a missing 15-day payment term raises" do
    stub_garden3d_qbo(terms: [qbo_term("1", "Net 30", 30)], customers: @customers)
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/15 days/, error.message)
  end

  test "a tracker that already has an invoice raises instead of doing nothing" do
    @tracker = attach_invoice(@tracker, qbo_id: "8000", total: "0.0", balance: "0.0", sent: false)
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::PushFailed) { push }

    assert_match(/already has QuickBooks invoice 8000/, error.message)
  end

  test "a tracker on Sanctuary's pass is refused" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 9, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 960_002, name: "External Co")
    @tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                      qbo_account: sanctuary_qa)
    forbid_writes

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) { push }
  end

  test "a tracker whose client is not a flagged payer's is refused" do
    @payer.update_columns(management_fee_payer: false)
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/does not belong to a management fee payer/, error.message)
  end

  test "QuickBooks answering without an invoice is a failure, not a success" do
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(nil)

    assert_raises(Mso::ManagementFeeInvoices::PushFailed) { push }

    assert unattached?
    assert_equal 0, QboInvoice.where(qbo_account_id: @qbo_account.id).count
  end

  # --- refusing to double-invoice -------------------------------------------

  test "it refuses when QuickBooks already holds an invoice for that customer in the month, naming it" do
    stub_garden3d_qbo(customers: @customers,
                      invoices_in_month: [qbo_created_invoice("4411", total: "135000"), qbo_created_invoice("4412")])
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::AlreadyInvoiced) { push }

    assert_match(/4411/, error.message)
    assert_match(/4412/, error.message)
    assert unattached?
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
    pass = garden3d_pass(Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START - 1.month)
    @tracker = fee_tracker(pass, @payer)
    QboAccount.any_instance.expects(:fetch_all_items).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    Quickbooks::Service::Invoice.any_instance.expects(:query).never
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::NotDraftable) { push }

    assert_match(/October 2026/, error.message)
  end

  test "a pass holding a legacy Forecast tracker is refused" do
    other = make_payer("Legacy Neighbour #{SecureRandom.hex(3)}")
    fee_tracker(@pass, other).update!(blueprint: { "lines" => {} })
    forbid_writes

    assert_raises(Mso::ManagementFeeInvoices::NotDraftable) { push }
  end

  test "draftable? is garden3d's pass, from the start month, with no legacy tracker" do
    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START
    sanctuary_pass = InvoicePass.create!(start_of_month: start, enterprise: enterprises(:sanctuary), data: {})

    assert_equal Date.new(2026, 10, 1), start
    assert Mso::ManagementFeeInvoices.draftable?(garden3d_pass(start))
    refute Mso::ManagementFeeInvoices.draftable?(garden3d_pass(start - 1.month))
    refute Mso::ManagementFeeInvoices.draftable?(sanctuary_pass)

    assert Mso::ManagementFeeInvoices.draftable?(@pass)
    @tracker.update!(blueprint: { "lines" => {} })
    refute Mso::ManagementFeeInvoices.draftable?(@pass)
  end
end
