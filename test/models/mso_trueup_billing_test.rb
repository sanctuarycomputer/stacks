require "test_helper"
require "ostruct"

class MsoTrueupBillingTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 11, 1)

  def setup
    @qa = garden3d_qbo_account
    fee_collected(MONTH)
    @report = mso_report(MONTH)
    @exec = mso_person("bill-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @trueup = mso_trueup(@report, @role, @ledger, amount: "1200", accepted: true)
    @vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    @mapping = ContributorQboVendor.create!(contributor: @exec, qbo_account: @qa, qbo_vendor: @vendor)

    # A chart that HAS an MSO compensation account, and a router that knows
    # its number: the state after Finance has done their part.
    QboAccount.any_instance.stubs(:fetch_all_accounts)
      .returns([OpenStruct.new(acct_num: "6100", id: 61), OpenStruct.new(acct_num: "6200", id: 62)])
    @pinned = Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:garden3d].merge(mso_compensation: "6200")
    Qbo::BillRouter.any_instance.stubs(:enterprise_gl_map).returns(@pinned)

    # Any QuickBooks write a test did not ask for fails it.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token).returns(:token)
    Quickbooks::Service::Bill.any_instance.stubs(:access_token=)
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(RuntimeError, "unexpected QuickBooks bill write")
    Quickbooks::Service::Bill.any_instance.stubs(:update).raises(RuntimeError, "unexpected QuickBooks bill write")
    Quickbooks::Service::Bill.any_instance.stubs(:delete).raises(RuntimeError, "unexpected QuickBooks bill delete")
    QboBill.any_instance.stubs(:delete_qbo_bill!).raises(RuntimeError, "unexpected QuickBooks bill delete")
  end

  def teardown
    clear_enterprise_memos
  end

  def fresh
    MsoTrueup.find(@trueup.id)
  end

  def remote_bill(id, balance: "1200", total: "1200")
    Quickbooks::Model::Bill.new.tap do |bill|
      bill.id = id
      bill.balance = BigDecimal(balance)
      bill.total = BigDecimal(total)
      bill.vendor_ref = Quickbooks::Model::BaseReference.new(@vendor.qbo_id)
    end
  end

  test "with no garden3d vendor the sync raises and says what to do, instead of doing nothing" do
    @mapping.destroy

    error = assert_raises(MsoTrueup::MissingVendor) { fresh.sync_qbo_bill! }

    assert_kind_of MsoTrueup::SyncRefused, error
    assert_match(/no vendor in garden3d, LLC's QuickBooks/, error.message)
    assert_match(/Contributor record/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "with no MSO compensation account the sync raises and says who has to act" do
    Qbo::BillRouter.any_instance.unstub(:enterprise_gl_map) # the real 6130, which this chart lacks

    error = assert_raises(MsoTrueup::AccountNotConfigured) { fresh.sync_qbo_bill! }

    assert_match(/mso_compensation/, error.message)
    assert_match(/Finance/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "a QuickBooks failure reading the chart of accounts is not reported as a missing MSO account" do
    QboAccount.any_instance.stubs(:fetch_all_accounts).raises(RuntimeError, "QuickBooks is down")

    error = assert_raises(RuntimeError) { fresh.sync_qbo_bill! }

    assert_not_kind_of MsoTrueup::SyncRefused, error
    assert_match(/QuickBooks is down/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "not payable: refused before anything is asked of QuickBooks" do
    fee_collected(MONTH, false)
    QboAccount.any_instance.expects(:fetch_all_accounts).never
    QboAccount.any_instance.expects(:make_and_refresh_qbo_access_token).never

    assert_raises(MsoTrueup::NotPayable) { fresh.sync_qbo_bill! }

    assert_nil fresh.qbo_bill_id
  end

  test "a payable true-up gets one bill, dated the month's last day; syncing again updates it" do
    created = nil
    Quickbooks::Service::Bill.any_instance.expects(:create).once.with { |bill| created = bill }
      .returns(remote_bill("900"))

    fresh.sync_qbo_bill!

    assert_equal "900", fresh.qbo_bill_id
    assert_equal Date.new(2090, 11, 30), created.txn_date.to_date
    assert_equal Date.new(2090, 11, 30), created.due_date.to_date
    assert_equal "Stacks_#{@trueup.id}_MT", created.doc_number
    assert QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "900")

    QboAccount.any_instance.stubs(:fetch_bill_by_id).returns(remote_bill("900"))
    Quickbooks::Service::Bill.any_instance.expects(:update).once.returns(remote_bill("900"))

    fresh.sync_qbo_bill!

    assert_equal "900", fresh.qbo_bill_id
    assert_equal 1, QboBill.where(qbo_account_id: @qa.id).count
  end

  test "the Money page's sync-all contains each refusal and carries its message" do
    @mapping.destroy
    failures = nil

    assert_nothing_raised { failures = Money::RefreshPayableQboBills.call(qbo_account: @qa) }

    mine = failures.select { |host, _| host.is_a?(MsoTrueup) }
    assert_equal [@trueup.id], mine.map { |host, _| host.id }
    assert_kind_of MsoTrueup::MissingVendor, mine.first.last
  end

  test "once its bill is paid in the stored copy, it leaves the Money page" do
    QboBill.create!(qbo_account: @qa, qbo_id: "910", qbo_vendor_id: @vendor.qbo_id,
                    data: { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "910")
    assert_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup

    QboBill.where(qbo_account_id: @qa.id, qbo_id: "910").update_all(data: { "balance" => "0", "total_amt" => "1200" })

    assert_not_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup
  end

  # --- a paid bill ---------------------------------------------------------------

  test "a bill with any payment is never rewritten; Stacks' copy shows the payment" do
    QboBill.create!(qbo_account: @qa, qbo_id: "920", qbo_vendor_id: @vendor.qbo_id,
                    data: { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "920")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).with("920").returns(remote_bill("920", balance: "200"))
    Quickbooks::Service::Bill.any_instance.expects(:update).never

    fresh.sync_qbo_bill!

    assert_equal "200.0", QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "920").data["balance"].to_s
  end
end
