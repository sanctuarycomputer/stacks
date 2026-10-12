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
    assert_match(/Management fee draft created/, flash[:notice])
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

  test "a lead editing a legacy garden3d tracker is shown no invoices at all" do
    other = make_payer("Legacy Edit #{SecureRandom.hex(3)}")
    legacy = fee_tracker(@pass, other)
    legacy.update!(blueprint: { "lines" => {} })
    orphan_invoice!(@qbo_account, "G-ORPHAN-2")
    sign_in @lead

    get edit_admin_invoice_pass_invoice_tracker_path(@pass, legacy)

    assert_response :success
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
end
