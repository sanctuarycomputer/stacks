require "test_helper"

class AdminManagementFeeInvoicesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ManagementFeeFixtures

  setup do
    @admin = AdminUser.create!(email: "fee-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "fee-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2094, 7, 1))
    @payer = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [980_001])
    stub_garden3d_qbo(customers: [qbo_customer("2", "Sanctuary Computer Inc")])
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  teardown do
    clear_enterprise_memos
  end

  def tracker_path(tracker)
    admin_invoice_pass_invoice_tracker_path(tracker.invoice_pass, tracker)
  end

  def attempt_generate_path(tracker)
    attempt_generate_admin_invoice_pass_invoice_tracker_path(tracker.invoice_pass, tracker)
  end

  def orphan_invoice!(qbo_account, doc_number)
    QboInvoice.create!(qbo_account: qbo_account, qbo_id: "orphan-#{doc_number}", data: {
      "doc_number" => doc_number, "total" => "10.0", "balance" => "10.0", "email_status" => "NotSet",
      "customer_ref" => { "name" => "Some Customer", "value" => "9" },
    })
  end

  # --- Regenerate on one tracker --------------------------------------------

  test "an admin's Regenerate creates the management fee draft" do
    tracker = fee_tracker(@pass, @payer)
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(qbo_created_invoice("9100"))
    sign_in @admin

    post attempt_generate_path(tracker)

    assert_redirected_to tracker_path(tracker)
    assert_match(/Draft created in garden3d's QuickBooks/, flash[:notice])
    assert_equal "9100", tracker.reload.qbo_invoice_id
  end

  test "a failed Regenerate says why" do
    tracker = fee_tracker(@pass, @payer)
    @payer.update_columns(g3d_qbo_customer_id: "404")
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    sign_in @admin

    post attempt_generate_path(tracker)

    assert_redirected_to tracker_path(tracker)
    assert_match(/404/, flash[:alert])
    assert_nil tracker.reload.qbo_invoice_id
  end

  test "QuickBooks failing mid-Regenerate tells the admin to look before retrying" do
    tracker = fee_tracker(@pass, @payer)
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.raises(Timeout::Error, "execution expired")
    sign_in @admin

    post attempt_generate_path(tracker)

    assert_redirected_to tracker_path(tracker)
    assert_match(/check garden3d's QuickBooks/i, flash[:alert])
    assert_match(/execution expired/, flash[:alert])
    assert_nil tracker.reload.qbo_invoice_id
  end

  test "a Regenerate refused because QuickBooks already has the invoice offers it on the Edit page" do
    tracker = fee_tracker(@pass, @payer)
    stub_garden3d_qbo(customers: [qbo_customer("2", "Sanctuary Computer Inc")],
                      invoices_in_month: [qbo_created_invoice("4500", total: "135000", balance: "135000")])
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    sign_in @admin

    post attempt_generate_path(tracker)

    assert_redirected_to tracker_path(tracker)
    assert_match(/4500/, flash[:alert])
    assert_nil tracker.reload.qbo_invoice_id

    get edit_admin_invoice_pass_invoice_tracker_path(@pass, tracker)

    assert_response :success
    assert_select "select#invoice_tracker_qbo_invoice_id option[value=?]", "#{@qbo_account.id}:4500", count: 1
  end

  test "a lead cannot Regenerate a management fee invoice tracker by posting directly" do
    tracker = fee_tracker(@pass, @payer)
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    sign_in @lead

    post attempt_generate_path(tracker)

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
    assert_nil tracker.reload.qbo_invoice_id
  end

  # --- the invoice dropdown on the edit page --------------------------------

  test "an admin editing a tracker is offered only its own QuickBooks account's invoices" do
    tracker = fee_tracker(@pass, @payer)
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    orphan_invoice!(@qbo_account, "G-ORPHAN-1")
    orphan_invoice!(sanctuary_qa, "S-ORPHAN-1")
    sign_in @admin

    get edit_admin_invoice_pass_invoice_tracker_path(@pass, tracker)

    assert_response :success
    assert_match(/G-ORPHAN-1/, response.body)
    assert_no_match(/S-ORPHAN-1/, response.body)
  end

  # Was "a lead editing a legacy garden3d tracker is shown no invoices at
  # all", with a 200. garden3d's passes are now admin-only, the legacy ones
  # included, so the lead does not reach the page.
  test "a lead cannot open a legacy garden3d tracker's edit page, and is shown no invoices" do
    other = make_payer("Legacy Edit #{SecureRandom.hex(3)}")
    legacy = fee_tracker(@pass, other)
    legacy.update!(blueprint: { "lines" => {} })
    orphan_invoice!(@qbo_account, "G-ORPHAN-2")
    sign_in @lead

    get edit_admin_invoice_pass_invoice_tracker_path(@pass, legacy)

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
    assert_no_match(/G-ORPHAN-2/, response.body)
  end

  # --- payouts ----------------------------------------------------------------

  test "Calculate Default Payouts on a management fee invoice is refused politely" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8200", total: "130000.0", balance: "0.0", sent: true)
    sign_in @admin

    post make_payouts_admin_invoice_tracker_contributor_payouts_path(tracker)

    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(tracker)
    assert_match(/no contributor payouts/, flash[:alert])
    assert_equal 0, ContributorPayout.where(invoice_tracker_id: tracker.id).count
  end

  test "a management fee tracker's page offers no way into its payouts" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8201", total: "130000.0", balance: "0.0", sent: true)
    assert @pass.allows_payment_splits?, "sanity: the link is shown on passes in the payment-splits era"
    QboInvoice.any_instance.stubs(:sync!).returns(true) # the page's own re-sync
    sign_in @admin

    get tracker_path(tracker)

    assert_response :success
    assert_match(/Payouts/, response.body, "sanity: the page rendered its payouts section")
    assert_select "a[href=?]", admin_invoice_tracker_contributor_payouts_path(tracker), count: 0
    assert_no_match(/All Payouts/, response.body)
  end

  test "a legacy garden3d tracker's page still links to its payouts" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8202", total: "1000.0", balance: "1000.0", sent: true)
    tracker.update!(blueprint: { "lines" => {} })
    QboInvoice.any_instance.stubs(:sync!).returns(true)
    sign_in @admin

    get tracker_path(tracker)

    assert_response :success
    assert_select "a[href=?]", admin_invoice_tracker_contributor_payouts_path(tracker), text: /All Payouts/, count: 1
  end

  # --- The pass page ---------------------------------------------------------

  # "Generate Invoices": the same button every pass has. On garden3d's pass it
  # makes the trackers and a $0.00 draft for each.
  def generate_path(pass)
    rerun_invoice_pass_without_reminders_admin_invoice_pass_path(pass)
  end

  def refresh_path(pass)
    refresh_intercompany_invoices_admin_invoice_pass_path(pass)
  end

  test "garden3d's pass page offers Generate Invoices and Refresh, and lists who is billed" do
    attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8100", total: "130000.0", balance: "130000.0", sent: true)
    # The Forecast missing-hours report means nothing on this pass.
    Stacks::Automator.expects(:discover_people_missing_hours_for_month).never
    sign_in @admin

    get admin_invoice_pass_path(@pass)

    assert_response :success
    assert_select "a[href=?]", generate_path(@pass), text: "Generate Invoices", count: 1
    assert_select "a[href=?][data-confirm]", generate_path(@pass), count: 1
    assert_select "a[href=?]", refresh_path(@pass), count: 1
    assert_select "a[href=?]", rerun_invoice_pass_admin_invoice_pass_path(@pass), count: 0
    assert_match(/Sanctuary Computer Inc/, response.body)
    assert_match(/\$130,000\.00/, response.body)
  end

  test "a Sanctuary pass page offers Generate Invoices as it always has, with no confirm, and no Refresh" do
    Stacks::Automator.stubs(:discover_people_missing_hours_for_month).returns([])
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 7, 1), enterprise: enterprises(:sanctuary), data: {})
    sign_in @admin

    get admin_invoice_pass_path(pass)

    assert_response :success
    assert_select "a[href=?]", generate_path(pass), text: "Generate Invoices", count: 1
    assert_select "a[href=?][data-confirm]", generate_path(pass), count: 0
    assert_select "a[href=?]", refresh_path(pass), count: 0
  end

  test "a garden3d pass from before the first month renders like any other garden3d pass" do
    pass = garden3d_pass(InvoicePass::INTERCOMPANY_START - 1.month)
    fee_tracker(pass, @payer).update!(blueprint: { "lines" => {} })
    Stacks::Automator.expects(:discover_people_missing_hours_for_month).never
    sign_in @admin

    get admin_invoice_pass_path(pass)

    assert_response :success
    assert_select "a[href=?]", generate_path(pass), count: 1
    assert_match(/Invoices to paying companies/, response.body)
  end

  test "Generate Invoices posted to a garden3d pass from before the first month makes nothing" do
    pass = garden3d_pass(InvoicePass::INTERCOMPANY_START - 1.month)
    Stacks::Automator.expects(:attempt_invoicing_for_invoice_pass).never
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    sign_in @admin

    post generate_path(pass)

    assert_redirected_to admin_invoice_pass_path(pass)
    assert_match(/were made by hand/, flash[:alert])
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  # August, September and October 2026 were invoiced by hand before Stacks
  # drafted anything: the click must find each existing invoice, create
  # nothing, and offer it for attaching.
  test "Generate Invoices on a first-month pass that was invoiced by hand refuses and lists the invoice to attach" do
    pass = garden3d_pass(InvoicePass::INTERCOMPANY_START)
    assert_equal "August 2026", pass.invoice_month
    stub_garden3d_qbo(customers: [qbo_customer("2", "Sanctuary Computer Inc")],
                      invoices_in_month: [qbo_created_invoice("4700", total: "140000", balance: "0")])
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    Quickbooks::Service::Customer.any_instance.expects(:create).never
    sign_in @admin

    get admin_invoice_pass_path(pass)

    assert_response :success
    assert_select "a[href=?]", generate_path(pass), count: 1

    post generate_path(pass)

    assert_redirected_to admin_invoice_pass_path(pass)
    assert_nil flash[:notice]
    assert_match(/Created 0 draft/, flash[:alert])
    assert_match(/already holds 1 invoice\(s\).*August 2026: 4700 \(total 140000\.0\)/, flash[:alert])
    assert_match(/attach the right one/, flash[:alert])
    tracker = InvoiceTracker.find_by!(invoice_pass_id: pass.id)
    assert_nil tracker.qbo_invoice_id

    get edit_admin_invoice_pass_invoice_tracker_path(pass, tracker)

    assert_response :success
    assert_select "select#invoice_tracker_qbo_invoice_id option[value=?]", "#{@qbo_account.id}:4700", count: 1

    patch tracker_path(tracker), params: { invoice_tracker: { qbo_invoice_id: "#{@qbo_account.id}:4700" } }

    assert_equal "4700", tracker.reload.qbo_invoice_id
  end

  test "an admin's Generate Invoices makes the trackers and their drafts with one click" do
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(qbo_created_invoice("9300"))
    sign_in @admin

    post generate_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/Created 1 draft/, flash[:notice])
    assert_equal ["9300"], InvoiceTracker.where(invoice_pass_id: @pass.id).pluck(:qbo_invoice_id)
  end

  test "Generate Invoices skips a company that already has an invoice, and one failing does not stop the next" do
    attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8110", total: "130000.0", balance: "0.0", sent: true)
    broken = make_payer("Broken #{SecureRandom.hex(3)}", customer_id: "404", forecast_ids: [980_010])
    working = make_payer("Working #{SecureRandom.hex(3)}", customer_id: "77", forecast_ids: [980_011])
    stub_garden3d_qbo(customers: [qbo_customer("2", "Sanctuary Computer Inc"), qbo_customer("77", "Working Co")])
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(qbo_created_invoice("9301"))
    sign_in @admin

    post generate_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/Created 1 draft/, flash[:alert])
    assert_match(/404/, flash[:alert])
    invoice_ids = lambda do |payer|
      InvoiceTracker.where(invoice_pass_id: @pass.id, forecast_client_id: payer.internal_forecast_client_ids)
                    .pluck(:qbo_invoice_id)
    end
    assert_equal ["8110"], invoice_ids.call(@payer), "the invoice already attached is left alone"
    assert_equal [nil], invoice_ids.call(broken)
    assert_equal ["9301"], invoice_ids.call(working)
  end

  test "a lead cannot create drafts by posting directly" do
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    sign_in @lead

    post generate_path(@pass)

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: @pass.id).count
  end

  test "a lead cannot refresh by posting directly, and QuickBooks is never read" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8103", total: "0.0", balance: "0.0", sent: false)
    Mso::IntercompanyInvoices.expects(:refresh!).never
    QboInvoice.any_instance.expects(:sync!).never
    QboAccount.any_instance.expects(:fetch_invoice_by_id).never
    sign_in @lead

    post refresh_path(@pass)

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
    assert_equal "8103", tracker.reload.qbo_invoice_id
  end

  test "a lead posting create-drafts never reaches QuickBooks at all" do
    InvoicePass.any_instance.expects(:make_trackers!).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    Quickbooks::Service::Invoice.any_instance.expects(:query).never
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    Quickbooks::Service::Customer.any_instance.expects(:create).never
    sign_in @lead

    post generate_path(@pass)

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: @pass.id).count
  end

  test "a lead cannot update a management fee invoice tracker by PATCH or PUT, not even its notes" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8104", total: "130000.0", balance: "0.0", sent: true)
    sign_in @lead

    patch tracker_path(tracker), params: { invoice_tracker: { notes: "From a lead", qbo_invoice_id: "" } }

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])

    put tracker_path(tracker), params: { invoice_tracker: { notes: "From a lead", qbo_invoice_id: "" } }

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
    tracker.reload
    assert_nil tracker.notes
    assert_equal "8104", tracker.qbo_invoice_id
    assert_equal @qbo_account.id, tracker.qbo_account_id
  end

  test "a lead cannot open a management fee invoice tracker's edit page" do
    tracker = fee_tracker(@pass, @payer)
    orphan_invoice!(@qbo_account, "G-ORPHAN-3")
    sign_in @lead

    get edit_admin_invoice_pass_invoice_tracker_path(@pass, tracker)

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
  end

  test "an admin refreshes the attached invoices from QuickBooks" do
    attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8101", total: "0.0", balance: "0.0", sent: false)
    QboInvoice.any_instance.stubs(:sync!).returns(true)
    sign_in @admin

    post refresh_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/Refreshed 1 of 1 invoice/, flash[:notice])
    assert_nil flash[:alert]
  end

  test "a refresh that could not read an invoice says so in an alert, not a green notice" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8102", total: "0.0", balance: "0.0", sent: false)
    QboInvoice.any_instance.stubs(:sync!).returns(false)
    sign_in @admin

    post refresh_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_nil flash[:notice]
    assert_match(/Refreshed 0 of 1 invoice/, flash[:alert])
    assert_match(/#{tracker.id}/, flash[:alert])
  end
end
