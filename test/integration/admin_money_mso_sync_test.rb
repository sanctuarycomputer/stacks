require "test_helper"
require "ostruct"

class AdminMoneyMsoSyncTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  MONTH = Date.new(2094, 4, 1)

  setup do
    @qa = garden3d_qbo_account
    fee_collected(MONTH)
    @admin = mso_admin
    exec = mso_person("money-exec")
    ledger = garden3d_ledger(exec)
    role = mso_role(exec)
    @trueup = mso_trueup(mso_report(MONTH), role, ledger, amount: "1200", accepted: true)

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

  test "syncing one true-up that is not payable is refused and writes nothing" do
    fee_collected(MONTH, false)
    Quickbooks::Service::Bill.any_instance.expects(:create).never
    sign_in @admin

    post admin_money_refresh_bill_path(qbo_account_id: @qa.id, host_class: "MsoTrueup", host_id: @trueup.id)

    assert_response :redirect
    assert_match(/not yet payable/, flash[:alert])
    assert_nil @trueup.reload.qbo_bill_id
  end
end
