require "test_helper"

class AdminMoneyMsoSyncTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  MONTH = Date.new(2094, 4, 1)

  setup do
    @qa = garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @admin = mso_admin
    exec = mso_person("money-exec")
    ledger = garden3d_ledger(exec)
    role = mso_role(exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(role, ledger, trueup: "1200.0")], collected: true)
    @trueup = mso_trueup(@snapshot, role, ledger, amount: "1200", accepted: true)

    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  teardown do
    clear_enterprise_memos
  end

  test "Sync all tells the admin why an MSO true-up was not synced" do
    sign_in @admin

    # No garden3d vendor is mapped for this executive.
    post admin_money_refresh_tab_path(qbo_account_id: @qa.id)

    assert_response :redirect
    assert_match(/MsoTrueup##{@trueup.id}/, flash[:alert])
    assert_match(/no vendor in garden3d, LLC's QuickBooks/, flash[:alert])
    assert_nil @trueup.reload.qbo_bill_id
  end

  test "Refresh from QuickBooks on the pass withdraws the collection stamp" do
    sign_in @admin
    assert @snapshot.fee_collected?

    post refresh_management_fee_invoices_admin_invoice_pass_path(@pass)

    assert_response :redirect
    assert_not @snapshot.reload.fee_collected?
  end
end
