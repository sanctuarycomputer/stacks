require "test_helper"
require "ostruct"

class MsoTrueupQboRegistrationTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 7, 1)

  def setup
    @qa = garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("qbo-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(@role, @ledger, trueup: "1200.0")], collected: true)
    @trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1200", accepted: true)
    @vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    ContributorQboVendor.create!(contributor: @exec, qbo_account: @qa, qbo_vendor: @vendor)

    # garden3d's chart as it is today: the 6100 catch-all and nothing for MSO.
    QboAccount.any_instance.stubs(:fetch_all_accounts).returns([account("6100", 61)])
    # Anything that would write to QuickBooks fails the test.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(RuntimeError, "unexpected QuickBooks bill write")
    Quickbooks::Service::Bill.any_instance.stubs(:update).raises(RuntimeError, "unexpected QuickBooks bill write")
  end

  def teardown
    clear_enterprise_memos
  end

  def account(num, id)
    OpenStruct.new(acct_num: num, id: id, name: "Acct #{num}")
  end

  def router(item = MsoTrueup.find(@trueup.id))
    Qbo::BillRouter.new(item, accounts_cache: Qbo::AccountsCache.new)
  end

  def bill!(qbo_id, data = { "balance" => "1200", "total_amt" => "1200" })
    QboBill.create!(qbo_account: @qa, qbo_id: qbo_id, qbo_vendor_id: @vendor.qbo_id, data: data)
  end

  # --- routing ---------------------------------------------------------------

  test "an MSO true-up is one line on the mso_compensation concept" do
    lines = router.concept_lines

    assert_equal 1, lines.size
    assert_equal :mso_compensation, lines.first[:concept]
    assert_equal BigDecimal("1200"), lines.first[:amount]
    assert_equal @trueup.bill_description, lines.first[:description]
  end

  test "mso_compensation can never fall back, and garden3d's account is deliberately unmatched" do
    assert_not_includes Qbo::BillRouter::FALLBACKABLE_CONCEPTS, :mso_compensation
    assert_equal "____", Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:garden3d][:mso_compensation]
  end

  test "routing raises rather than filing executive pay under Platform Infrastructure" do
    error = assert_raises(RuntimeError) { router.lines }

    assert_match(/mso_compensation/, error.message)
    assert_match(/____/, error.message)
  end

  test "once the account number is pinned and the account exists, it routes there" do
    QboAccount.any_instance.stubs(:fetch_all_accounts).returns([account("6100", 61), account("6200", 62)])
    pinned = router
    pinned.stubs(:enterprise_gl_map)
      .returns(Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:garden3d].merge(mso_compensation: "6200"))

    assert_equal [62], pinned.lines.map { |line| line[:account].id }
  end

  # --- the Money page ----------------------------------------------------------

  test "a payable true-up is listed as payable, and an unaccepted one is counted as unsettled" do
    payable = Money::PayableQboBills.call(qbo_account: @qa).map(&:host)
    assert_includes payable, @trueup
    before = Money::QboBillSummary.call(qbo_account: @qa)
    assert_includes before.payable_rows.map(&:host), @trueup

    @trueup.update_columns(accepted_at: nil)

    assert_not_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup
    after = Money::QboBillSummary.call(qbo_account: @qa)
    assert_not_includes after.payable_rows.map(&:host), @trueup
    assert_equal before.unsettled_count + 1, after.unsettled_count
    assert_in_delta 1200.0, after.unsettled_total - before.unsettled_total, 0.001
  end

  test "until the table exists the Money page leaves MsoTrueup out and still renders its data" do
    assert_includes Money::PayableQboBills::HOST_KLASSES, MsoTrueup
    assert_includes Money::PayableQboBills.host_klasses, MsoTrueup

    MsoTrueup.stubs(:schema_ready?).returns(false)

    assert_not_includes Money::PayableQboBills.host_klasses, MsoTrueup
    assert_includes Money::PayableQboBills.host_klasses, ContributorPayout
    assert_not_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup
    assert_nothing_raised { Money::QboBillSummary.call(qbo_account: @qa) }
  end

  # --- bill housekeeping ---------------------------------------------------------

  test "when its bill vanishes from QuickBooks the true-up is detached" do
    bill!("501")
    @trueup.update_columns(qbo_bill_id: "501")
    @qa.stubs(:fetch_all_bills).returns([])

    @qa.sync_all_bills!

    assert_nil @trueup.reload.qbo_bill_id
    assert_nil QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "501")
  end

  test "orphan cleanup leaves a live true-up's bill alone" do
    bill!("502")
    @trueup.update_columns(qbo_bill_id: "502")
    @qa.stubs(:fetch_all_bills).returns([OpenStruct.new(id: "502", doc_number: "Stacks_#{@trueup.id}_MT")])
    QboBill.any_instance.stubs(:delete_qbo_bill!).raises(RuntimeError, "unexpected QuickBooks bill delete")
    @qa.stubs(:delete_bill).raises(RuntimeError, "unexpected QuickBooks bill delete")

    @qa.cleanup_orphaned_qbo_objects!

    assert_equal "502", @trueup.reload.qbo_bill_id
    assert QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "502")
  end

  test "orphan cleanup knows the MT code: a soft-deleted true-up's leftover bill is removed" do
    bill!("503")
    @trueup.update_columns(qbo_bill_id: "503", deleted_at: Time.current)
    @qa.stubs(:fetch_all_bills).returns([OpenStruct.new(id: "503", doc_number: "Stacks_#{@trueup.id}_MT")])
    # QboBill#destroy deletes the remote bill; that is the one call allowed here.
    QboBill.any_instance.expects(:delete_qbo_bill!).once

    @qa.cleanup_orphaned_qbo_objects!

    assert_nil MsoTrueup.with_deleted.find(@trueup.id).qbo_bill_id
    assert_nil QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "503")
  end
end
