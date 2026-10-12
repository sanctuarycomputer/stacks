require "test_helper"

# garden3d's management fee invoices are intercompany. Once they are mirrored
# they must not show up as receivables in get_ar_aging / list_overdue_invoices.
class Mcp::ReceivablesManagementFeeTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  setup do
    @today = Date.today
    Date.stubs(:today).returns(@today)
    @qbo_account = garden3d_qbo_account
    @sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    @payer = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [994_001])
    # Neither tool may ever read QuickBooks.
    QboInvoice.any_instance.expects(:sync!).never
  end

  teardown do
    clear_enterprise_memos
  end

  # A sent, unpaid, overdue mirror row.
  def receivable!(account, doc, customer_id:, customer: "Customer #{customer_id}", balance: 100.0)
    QboInvoice.create!(qbo_account: account, qbo_id: "inv-#{doc}", data: {
      "doc_number" => doc,
      "email_status" => "EmailSent",
      "due_date" => (@today - 10).iso8601,
      "balance" => balance,
      "total" => balance,
      "customer_ref" => { "name" => customer, "value" => customer_id },
    })
  end

  def aging_customers
    payload = mcp_payload(Mcp::GetArAgingTool.call(server_context: {}))
    rows = payload["enterprises"].flat_map do |ent|
      ent["customers"].map { |customer| [ent["enterprise"], customer["customer_id"], customer["total"]] }
    end
    [rows, payload["total_ar"]]
  end

  def overdue_docs
    mcp_payload(Mcp::ListOverdueInvoicesTool.call(server_context: {}))["invoices"].map { |i| i["doc_number"] }.sort
  end

  test "a garden3d invoice billed to a payer's stored customer id is not a receivable, attached or not" do
    receivable!(@qbo_account, "FEE-1", customer_id: "2", balance: 135_000.0) # hand-made, attached to nothing
    receivable!(@sanctuary_qa, "SANC-1", customer_id: "2", balance: 500.0)   # same id value, Sanctuary's books
    receivable!(@qbo_account, "G3D-1", customer_id: "9", balance: 70.0)      # garden3d's, not a payer

    rows, total = aging_customers

    assert_equal [[Enterprise::SANCTUARY_NAME, "2", 500.0], [garden3d.name, "9", 70.0]], rows.sort
    assert_equal 570.0, total
    assert_equal %w[G3D-1 SANC-1], overdue_docs
  end

  test "an invoice attached to a management fee tracker is not a receivable, whatever its customer" do
    # No stored customer id to match on: the attachment alone marks it.
    @payer.update_columns(g3d_qbo_customer_id: nil)
    fee = receivable!(@qbo_account, "FEE-2", customer_id: "2", balance: 135_000.0)
    fee_tracker(garden3d_pass(Date.new(2092, 3, 1)), @payer).update!(qbo_invoice_id: fee.qbo_id)
    # The same QuickBooks id in Sanctuary's books is a different invoice.
    QboInvoice.create!(qbo_account: @sanctuary_qa, qbo_id: fee.qbo_id,
                       data: fee.read_attribute(:data).merge("doc_number" => "SANC-2", "balance" => 40.0))

    rows, total = aging_customers

    assert_equal [[Enterprise::SANCTUARY_NAME, "2", 40.0]], rows
    assert_equal 40.0, total
    assert_equal %w[SANC-2], overdue_docs
  end

  test "an invoice on a legacy Forecast tracker on garden3d's pass is still a receivable" do
    legacy = receivable!(@qbo_account, "LEGACY-1", customer_id: "9", balance: 70.0)
    fee_tracker(garden3d_pass(Date.new(2092, 4, 1)), @payer)
      .update!(qbo_invoice_id: legacy.qbo_id, blueprint: { "lines" => {} })

    rows, _total = aging_customers

    assert_equal [[garden3d.name, "9", 70.0]], rows
    assert_equal %w[LEGACY-1], overdue_docs
  end

  test "a fee invoice mirrored by a refused draft is not a receivable" do
    # End to end: the shape the pre-flight stores is the shape this reads.
    invoice = qbo_created_invoice("4600", total: "135000", balance: "135000", email_status: "EmailSent")
    invoice.customer_id = "2"
    invoice.due_date = @today - 10
    stub_garden3d_qbo(customers: [qbo_customer("2", "Sanctuary Computer Inc")], invoices_in_month: [invoice])
    pass = garden3d_pass(Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START)
    assert_raises(Mso::ManagementFeeInvoices::AlreadyInvoiced) do
      Mso::ManagementFeeInvoices.push_invoice!(invoice_tracker: fee_tracker(pass, @payer))
    end
    assert_equal 1, QboInvoice.open_receivables.where(qbo_account_id: @qbo_account.id, qbo_id: "4600").count,
                 "sanity: without the exclusion this row is a receivable"

    rows, total = aging_customers

    assert_equal [], rows
    assert_equal 0, total
    assert_equal [], overdue_docs
  end

  test "before the migration has run nothing is excluded, and the new columns are never read" do
    Mcp::QboReceivables.stubs(:management_fee_schema_ready?).returns(false)
    Enterprise.expects(:management_fee_payers).never
    receivable!(@qbo_account, "FEE-3", customer_id: "2", balance: 135_000.0)

    rows, _total = aging_customers

    assert_equal [[garden3d.name, "2", 135_000.0]], rows
    assert_equal %w[FEE-3], overdue_docs
  end
end
