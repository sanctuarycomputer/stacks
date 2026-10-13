require "test_helper"
require "ostruct"

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

  # A bill someone deleted in QuickBooks: never re-created at the old amount.
  def bill_gone!
    vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    ContributorQboVendor.create!(contributor: @trueup.contributor, qbo_account: @qa, qbo_vendor: vendor)
    QboAccount.any_instance.stubs(:fetch_all_accounts).returns([OpenStruct.new(acct_num: "6200", id: 62)])
    Qbo::BillRouter.any_instance.stubs(:enterprise_gl_map)
      .returns(Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:garden3d].merge(mso_compensation: "6200"))
    QboBill.create!(qbo_account: @qa, qbo_id: "7001", qbo_vendor_id: vendor.qbo_id,
                    data: { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "7001")
    QboAccount.any_instance.stubs(:fetch_bill_by_id)
      .raises(RuntimeError, "Object Not Found: Something you're trying to use has been made inactive")
    Quickbooks::Service::Bill.any_instance.expects(:create).never
    Quickbooks::Service::Bill.any_instance.expects(:update).never
  end

  test "syncing one billed true-up whose bill is gone from QuickBooks says so and creates nothing" do
    bill_gone!
    sign_in @admin

    post admin_money_refresh_bill_path(qbo_account_id: @qa.id, host_class: "MsoTrueup", host_id: @trueup.id)

    assert_response :redirect
    assert_match(/Sync failed for MsoTrueup ##{@trueup.id}/, flash[:alert])
    assert_match(/QuickBooks bill 7001 .*no longer exists/, flash[:alert])
    assert_match(/run the month again/i, flash[:alert])
    @trueup.reload
    assert_nil @trueup.qbo_bill_id
    assert_not @trueup.accepted?
    assert @snapshot.reload.invalidated?
  end

  test "Sync all says a billed true-up's bill is gone, and creates nothing" do
    bill_gone!
    sign_in @admin

    post admin_money_refresh_tab_path(qbo_account_id: @qa.id)

    assert_response :redirect
    assert_match(/MsoTrueup##{@trueup.id}/, flash[:alert])
    assert_match(/no longer exists/, flash[:alert])
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
