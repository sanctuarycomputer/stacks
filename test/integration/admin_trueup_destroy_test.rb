require "test_helper"

# Deleting a founder true-up deletes its QuickBooks bill in that company's
# books, and for a month the MSO pays, the nightly sync will not write it
# again. Admins only.
class AdminTrueupDestroyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  MONTH = Date.new(2094, 6, 1)

  setup do
    @sanctuary = enterprises(:sanctuary)
    @qa = QboAccount.find_by(enterprise: @sanctuary) ||
          QboAccount.create!(enterprise: @sanctuary, realm_id: "s-#{SecureRandom.hex(4)}", client_id: "x",
                             client_secret: "y")
    @founder = mso_person("tu-founder")
    @ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @founder)
    @pass = sanctuary_pass(MONTH)
    @trueup = Trueup.create!(invoice_pass: @pass, ledger: @ledger, amount: "4000", description: "founder true-up",
                             qbo_bill_id: "5501")
    vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    @bill = QboBill.create!(qbo_account: @qa, qbo_id: "5501", qbo_vendor_id: vendor.qbo_id,
                            data: { "balance" => "4000", "total_amt" => "4000" })

    @admin = mso_admin
    @lead = AdminUser.create!(email: "tu-lead-#{SecureRandom.hex(3)}@example.com", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    # Any QuickBooks call a test did not ask for fails it.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "unexpected QuickBooks read")
    QboBill.any_instance.stubs(:delete_qbo_bill!).raises(RuntimeError, "unexpected QuickBooks bill delete")
  end

  teardown do
    clear_enterprise_memos
  end

  def remote_bill(balance:)
    Quickbooks::Model::Bill.new.tap do |bill|
      bill.id = "5501"
      bill.balance = BigDecimal(balance)
      bill.total = BigDecimal("4000")
    end
  end

  test "a lead cannot delete a founder true-up: the row and its bill are untouched, QuickBooks is not called" do
    sign_in @lead
    QboAccount.any_instance.expects(:fetch_bill_by_id).never
    QboBill.any_instance.expects(:delete_qbo_bill!).never

    delete admin_ledger_trueup_path(@ledger, @trueup)

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error].to_s)
    assert_nil @trueup.reload.deleted_at
    assert_equal "5501", @trueup.qbo_bill_id
    assert QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "5501")
  end

  test "a lead is not offered the delete control; an admin is" do
    sign_in @lead
    get admin_ledger_trueup_path(@ledger, @trueup)
    assert_response :success
    assert_select "a[data-method=delete]", count: 0

    get admin_ledger_trueups_path(@ledger)
    assert_response :success
    assert_select "a[data-method=delete]", count: 0

    sign_out @lead
    sign_in @admin
    get admin_ledger_trueup_path(@ledger, @trueup)
    assert_response :success
    assert_select "a[data-method=delete][href=?]", admin_ledger_trueup_path(@ledger, @trueup)
  end

  test "an admin can delete a founder true-up, and its unpaid bill goes with it" do
    sign_in @admin
    QboAccount.any_instance.expects(:fetch_bill_by_id).with("5501").once.returns(remote_bill(balance: "4000"))
    QboBill.any_instance.expects(:delete_qbo_bill!).once

    delete admin_ledger_trueup_path(@ledger, @trueup)

    assert_response :redirect
    assert Trueup.with_deleted.find(@trueup.id).deleted_at.present?
    assert_nil Trueup.find_by(id: @trueup.id)
    assert_nil QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "5501")
  end

  test "an admin's delete is refused, with the reason, when the bill has a payment" do
    sign_in @admin
    QboAccount.any_instance.expects(:fetch_bill_by_id).with("5501").once.returns(remote_bill(balance: "1500"))
    QboBill.any_instance.expects(:delete_qbo_bill!).never

    delete admin_ledger_trueup_path(@ledger, @trueup)

    assert_response :redirect
    assert_match(/refusing to destroy QBO bill 5501/, flash[:alert])
    assert_nil @trueup.reload.deleted_at
    assert_equal "5501", @trueup.qbo_bill_id
    assert QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "5501")
  end
end
