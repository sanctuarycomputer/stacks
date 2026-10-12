require "test_helper"

# "Open garden3d month" on the invoice passes index: an admin gives a month
# its garden3d pass and trackers without the console. It is
# Mso::ManagementFeeInvoices.ensure_month!, so it touches the database only.
class AdminOpenManagementFeeMonthTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ManagementFeeFixtures

  setup do
    @admin = AdminUser.create!(email: "open-month-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "open-month-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    @qbo_account = garden3d_qbo_account
    make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [982_001])
    make_payer(Enterprise::INDEX_SPACE_NAME, customer_id: "5", forecast_ids: [982_002])

    @this_month = Date.today.beginning_of_month
    @last_month = @this_month.prev_month

    # Nothing set up before this: any QuickBooks call at all fails the test.
    QboAccount.any_instance.expects(:make_and_refresh_qbo_access_token).never
    QboAccount.any_instance.expects(:fetch_all_items).never
    QboAccount.any_instance.expects(:fetch_all_terms).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    QboAccount.any_instance.expects(:fetch_invoice_by_id).never
    QboAccount.any_instance.expects(:sync_all_invoices!).never
    QboInvoice.any_instance.expects(:sync!).never
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    Quickbooks::Service::Invoice.any_instance.expects(:query).never
    Quickbooks::Service::Customer.any_instance.expects(:create).never
    Mso::ManagementFeeInvoices.expects(:push_invoice!).never
    Mso::ManagementFeeInvoices.expects(:create_drafts!).never
    Mso::ManagementFeeInvoices.expects(:refresh!).never
  end

  teardown do
    clear_enterprise_memos
  end

  def open_month_path
    open_management_fee_month_admin_invoice_passes_path
  end

  def garden3d_passes
    InvoicePass.where(enterprise_id: garden3d.id)
  end

  def param(month)
    month.strftime("%Y-%m")
  end

  # --- the picker ---------------------------------------------------------------

  test "an admin is offered every month with no garden3d pass, and only those" do
    garden3d_pass(@last_month)
    # Sanctuary's pass for a month does not make it taken.
    InvoicePass.create!(start_of_month: @this_month, enterprise: enterprises(:sanctuary), data: {})
    sign_in @admin

    get admin_invoice_passes_path

    assert_response :success
    assert_select "form[action=?][method=post]", open_month_path, count: 1
    assert_select "form[action=?] select[name=month] option[value=?]", open_month_path, param(@this_month), count: 1
    assert_select "form[action=?] select[name=month] option[value=?]", open_month_path, param(@last_month), count: 0
    assert_select "form[action=?] select[name=month] option[value=?]", open_month_path, param(@this_month.next_month),
                  count: 0
    first = Mso::ManagementFeeInvoices::FIRST_FEE_MONTH
    assert_select "form[action=?] select[name=month] option[value=?]", open_month_path, param(first), count: 1
    assert_select "form[action=?] select[name=month] option[value=?]", open_month_path, param(first.prev_month), count: 0
  end

  test "a lead is not offered it" do
    sign_in @lead

    get admin_invoice_passes_path

    assert_response :success
    assert_select "form[action=?]", open_month_path, count: 0
  end

  # --- opening a month ------------------------------------------------------------

  test "an admin opens a month: the pass and its trackers are made, and QuickBooks is never called" do
    sign_in @admin

    assert_difference -> { garden3d_passes.count }, 1 do
      post open_month_path, params: { month: param(@last_month) }
    end

    pass = garden3d_passes.find_by!(start_of_month: @last_month)
    assert_redirected_to admin_invoice_pass_path(pass)
    assert_match(/#{pass.invoice_month}/, flash[:notice])
    assert_nil flash[:alert]
    trackers = InvoiceTracker.where(invoice_pass_id: pass.id)
    assert_equal [982_001, 982_002], trackers.pluck(:forecast_client_id).sort
    assert_equal [nil, nil], trackers.pluck(:qbo_invoice_id)
  end

  test "it opens a month from before drafting started, which is what it is mostly for" do
    month = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START - 3.months
    sign_in @admin

    post open_month_path, params: { month: param(month) }

    pass = garden3d_passes.find_by!(start_of_month: month)
    assert_redirected_to admin_invoice_pass_path(pass)
    assert_equal 2, InvoiceTracker.where(invoice_pass_id: pass.id).count
    refute Mso::ManagementFeeInvoices.draftable?(pass), "attachable, never draftable"
  end

  test "opening a month that already has its pass changes nothing and goes to it" do
    pass = Mso::ManagementFeeInvoices.ensure_month!(@last_month)
    sign_in @admin

    assert_no_difference [-> { InvoicePass.count }, -> { InvoiceTracker.count }] do
      post open_month_path, params: { month: param(@last_month) }
    end

    assert_redirected_to admin_invoice_pass_path(pass)
  end

  test "a lead is denied by URL, and nothing is made" do
    sign_in @lead

    assert_no_difference [-> { InvoicePass.count }, -> { InvoiceTracker.count }] do
      post open_month_path, params: { month: param(@last_month) }
    end

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
  end

  test "a lead never reaches ensure_month!" do
    Mso::ManagementFeeInvoices.expects(:ensure_month!).never
    sign_in @lead

    post open_month_path, params: { month: param(@last_month) }

    assert_match(/not authorized/i, flash[:error])
  end

  # --- refusals -------------------------------------------------------------------

  test "a legacy month is refused with the reason, and gains no tracker" do
    legacy_pass = garden3d_pass(@last_month)
    ForecastClient.create!(forecast_id: 982_050, name: "garden3d internal")
    legacy = InvoiceTracker.create!(invoice_pass: legacy_pass, forecast_client_id: 982_050, qbo_account: @qbo_account,
                                    blueprint: { "lines" => {} })
    sign_in @admin

    post open_month_path, params: { month: param(@last_month) }

    assert_redirected_to admin_invoice_passes_path
    assert_match(/Forecast-driven tracker/, flash[:alert])
    assert_match(/InvoicePass #{legacy_pass.id}/, flash[:alert])
    assert_nil flash[:notice]
    assert_equal [legacy.id], InvoiceTracker.where(invoice_pass_id: legacy_pass.id).pluck(:id)
  end

  test "any other management fee error is shown as an alert" do
    Enterprise.management_fee_payers.update_all(management_fee_payer: false)
    sign_in @admin

    post open_month_path, params: { month: param(@last_month) }

    assert_redirected_to admin_invoice_passes_path
    assert_match(/No enterprise is flagged as a management fee payer/, flash[:alert])
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: garden3d_passes.select(:id)).count
  end

  test "before the migration has run it says so and makes nothing" do
    stub_management_fee_columns_missing
    Enterprise.expects(:management_fee_payers).never
    sign_in @admin

    assert_no_difference -> { InvoicePass.count } do
      post open_month_path, params: { month: param(@last_month) }
    end

    assert_redirected_to admin_invoice_passes_path
    assert_match(/management fee columns are not on this database yet/, flash[:alert])
  end

  test "a month that is not a month, or is in the future, is refused and makes nothing" do
    sign_in @admin

    ["", "soon", "2026-13", param(@this_month.next_month)].each do |bad|
      assert_no_difference -> { InvoicePass.count }, bad.inspect do
        post open_month_path, params: { month: bad }
      end

      assert_redirected_to admin_invoice_passes_path
      assert_match(/Choose a month/, flash[:alert], bad.inspect)
    end
  end
end
