require "test_helper"

# Saving the tracker edit form must not change which QuickBooks invoice the
# tracker points at unless an admin asked for that.
class AdminInvoiceTrackerInvoiceAttachmentTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ManagementFeeFixtures

  setup do
    @admin = AdminUser.create!(email: "attach-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "attach-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2094, 8, 1))
    @payer = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [985_001])
    @tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8300", total: "130000.0", balance: "0.0", sent: true)

    # Nothing here may read or write QuickBooks.
    stub_garden3d_qbo
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  teardown do
    clear_enterprise_memos
  end

  def tracker_path(tracker)
    admin_invoice_pass_invoice_tracker_path(tracker.invoice_pass, tracker)
  end

  def mirror!(qbo_account, qbo_id)
    QboInvoice.create!(qbo_account: qbo_account, qbo_id: qbo_id, data: {
      "doc_number" => "DOC-#{qbo_id}", "total" => "10.0", "balance" => "10.0", "email_status" => "NotSet",
      "customer_ref" => { "name" => "Some Customer", "value" => "9" },
    })
  end

  # A tracker a lead may update: on Sanctuary's pass, with an invoice attached.
  def sanctuary_tracker_with_invoice
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 8, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 985_010, name: "External Co")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                     qbo_account: sanctuary_qa)
    attach_invoice(tracker, qbo_id: "7300", total: "500.0", balance: "500.0", sent: true)
  end

  # --- an admin ---------------------------------------------------------------

  test "an admin saving only notes keeps the attached invoice" do
    sign_in @admin

    patch tracker_path(@tracker), params: { invoice_tracker: { notes: "Checked with Finance" } }

    assert_redirected_to tracker_path(@tracker)
    @tracker.reload
    assert_equal "Checked with Finance", @tracker.notes
    assert_equal "8300", @tracker.qbo_invoice_id
    assert_equal @qbo_account.id, @tracker.qbo_account_id
  end

  test "the edit form offers the attached invoice, selected, so re-saving the form keeps it" do
    mirror!(@qbo_account, "8301")
    sign_in @admin

    get edit_admin_invoice_pass_invoice_tracker_path(@pass, @tracker)

    assert_response :success
    packed = "#{@qbo_account.id}:8300"
    assert_select "select#invoice_tracker_qbo_invoice_id option[selected][value=?]", packed
    values = css_select("select#invoice_tracker_qbo_invoice_id option").map { |option| option["value"] }
    assert_equal ["", packed, "#{@qbo_account.id}:8301"], values, "None, then the attached invoice, then the orphans"

    patch tracker_path(@tracker), params: { invoice_tracker: { notes: "Re-saved", qbo_invoice_id: packed } }

    @tracker.reload
    assert_equal "Re-saved", @tracker.notes
    assert_equal "8300", @tracker.qbo_invoice_id
    assert_equal @qbo_account.id, @tracker.qbo_account_id
  end

  test "an admin choosing None detaches the invoice" do
    sign_in @admin

    patch tracker_path(@tracker), params: { invoice_tracker: { notes: "Wrong invoice", qbo_invoice_id: "" } }

    assert_redirected_to tracker_path(@tracker)
    @tracker.reload
    assert_nil @tracker.qbo_invoice_id
    assert_equal @qbo_account.id, @tracker.qbo_account_id, "the tracker stays on its own QuickBooks account"
    assert_equal "Wrong invoice", @tracker.notes
  end

  test "an admin choosing another invoice re-points both columns" do
    other_qa = QboAccount.create!(enterprise: enterprises(:one), realm_id: "one-#{SecureRandom.hex(4)}",
                                  client_id: "x", client_secret: "y")
    mirror!(other_qa, "8400")
    sign_in @admin

    patch tracker_path(@tracker), params: { invoice_tracker: { qbo_invoice_id: "#{other_qa.id}:8400" } }

    assert_redirected_to tracker_path(@tracker)
    @tracker.reload
    assert_equal "8400", @tracker.qbo_invoice_id
    assert_equal other_qa.id, @tracker.qbo_account_id
  end

  # --- a lead -----------------------------------------------------------------

  test "a lead posting an invoice and account directly changes neither, but their notes still save" do
    tracker = sanctuary_tracker_with_invoice
    sanctuary_qa_id = tracker.qbo_account_id
    mirror!(@qbo_account, "8500")
    sign_in @lead

    patch tracker_path(tracker), params: { invoice_tracker: {
      notes: "From a lead", qbo_invoice_id: "#{@qbo_account.id}:8500", qbo_account_id: @qbo_account.id,
    } }

    assert_redirected_to tracker_path(tracker)
    tracker.reload
    assert_equal "From a lead", tracker.notes
    assert_equal "7300", tracker.qbo_invoice_id
    assert_equal sanctuary_qa_id, tracker.qbo_account_id
  end

  test "a lead cannot detach an invoice by posting a blank one" do
    tracker = sanctuary_tracker_with_invoice
    sign_in @lead

    patch tracker_path(tracker), params: { invoice_tracker: { notes: "Blank from a lead", qbo_invoice_id: "" } }

    tracker.reload
    assert_equal "Blank from a lead", tracker.notes
    assert_equal "7300", tracker.qbo_invoice_id
  end

  test "a lead's edit form shows the attached invoice and no other" do
    tracker = sanctuary_tracker_with_invoice
    mirror!(tracker.qbo_account, "7301")
    sign_in @lead

    get edit_admin_invoice_pass_invoice_tracker_path(tracker.invoice_pass, tracker)

    assert_response :success
    values = css_select("select#invoice_tracker_qbo_invoice_id option").map { |option| option["value"] }
    assert_equal ["", "#{tracker.qbo_account_id}:7300"], values
    assert_select "select#invoice_tracker_qbo_invoice_id[disabled]"
  end
end
