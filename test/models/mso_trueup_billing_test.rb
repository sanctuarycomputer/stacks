require "test_helper"
require "ostruct"

class MsoTrueupBillingTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 11, 1)

  def setup
    @qa = garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("bill-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(@role, @ledger, trueup: "1200.0")], collected: true)
    @trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1200", accepted: true)
    @vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    @mapping = ContributorQboVendor.create!(contributor: @exec, qbo_account: @qa, qbo_vendor: @vendor)

    # A chart that HAS an MSO compensation account, and a router that knows
    # its number: the state after Finance has done their part.
    QboAccount.any_instance.stubs(:fetch_all_accounts)
      .returns([OpenStruct.new(acct_num: "6100", id: 61), OpenStruct.new(acct_num: "6200", id: 62)])
    @pinned = Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:garden3d].merge(mso_compensation: "6200")
    Qbo::BillRouter.any_instance.stubs(:enterprise_gl_map).returns(@pinned)

    # The two checks made before a first bill. Tests override these.
    Mso::ManagementFeeInvoices.stubs(:collected?).returns(true)
    Mso::MonthlyRun.stubs(:preview).returns({ @ledger.id => BigDecimal("1200") })

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

  def mirror!(qbo_id, data)
    QboBill.create!(qbo_account: @qa, qbo_id: qbo_id, qbo_vendor_id: @vendor.qbo_id, data: data)
  end

  # --- the first bill ----------------------------------------------------------

  test "with no garden3d vendor the sync raises and says what to do, instead of doing nothing" do
    @mapping.destroy

    error = assert_raises(MsoTrueup::MissingVendor) { fresh.sync_qbo_bill! }

    assert_kind_of MsoTrueup::SyncRefused, error
    assert_match(/no vendor in garden3d, LLC's QuickBooks/, error.message)
    assert_match(/Contributor record/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "with no MSO compensation account the sync raises and says who has to act" do
    Qbo::BillRouter.any_instance.unstub(:enterprise_gl_map) # back to the real "____"

    error = assert_raises(MsoTrueup::AccountNotConfigured) { fresh.sync_qbo_bill! }

    assert_match(/mso_compensation/, error.message)
    assert_match(/Finance/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "collection is re-checked live before the first bill, and an unpaid fee stops it" do
    Mso::ManagementFeeInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(false)

    error = assert_raises(MsoTrueup::NotCollected) { fresh.sync_qbo_bill! }

    assert_match(/has not been collected/, error.message)
    assert_nil fresh.qbo_bill_id
    assert_not @snapshot.reload.fee_collected?, "and the stamp is withdrawn, not rolled back with the refusal"
    assert_equal false, fresh.payable?
  end

  test "a fee invoice that cannot be read stops the first bill" do
    Mso::ManagementFeeInvoices.stubs(:collected?)
      .raises(Mso::ManagementFeeInvoices::RefreshFailed, "Could not read the QuickBooks invoice on InvoiceTracker 9")

    error = assert_raises(MsoTrueup::NotCollected) { fresh.sync_qbo_bill! }

    assert_match(/Could not read/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "the first bill is refused when a fresh computation gives a different figure" do
    Mso::MonthlyRun.expects(:preview).with(invoice_pass: @pass).once.returns({ @ledger.id => BigDecimal("1150.25") })

    error = assert_raises(MsoTrueup::FiguresChanged) { fresh.sync_qbo_bill! }

    assert_match(/1200\.0/, error.message)
    assert_match(/1150\.25/, error.message)
    assert_match(/run the month again/i, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "the first bill is refused when the month can no longer be computed, or the person has left it" do
    Mso::MonthlyRun.stubs(:preview).raises(Mso::MonthlyRun::Refused, "a reconcile variance")
    assert_match(/a reconcile variance/, assert_raises(MsoTrueup::FiguresChanged) { fresh.sync_qbo_bill! }.message)

    Mso::MonthlyRun.stubs(:preview).returns({})
    assert_match(/0\.0/, assert_raises(MsoTrueup::FiguresChanged) { fresh.sync_qbo_bill! }.message)
    assert_nil fresh.qbo_bill_id
  end

  test "when everything holds, one bill is created; syncing again updates it without re-checking" do
    Mso::ManagementFeeInvoices.expects(:collected?).once.returns(true)
    Mso::MonthlyRun.expects(:preview).once.returns({ @ledger.id => BigDecimal("1200") })
    Quickbooks::Service::Bill.any_instance.expects(:create).once.returns(remote_bill("900"))

    fresh.sync_qbo_bill!

    assert_equal "900", fresh.qbo_bill_id
    assert QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "900")

    QboAccount.any_instance.stubs(:fetch_bill_by_id).returns(remote_bill("900"))
    Quickbooks::Service::Bill.any_instance.expects(:update).once.returns(remote_bill("900"))

    fresh.sync_qbo_bill!

    assert_equal "900", fresh.qbo_bill_id
    assert_equal 1, QboBill.where(qbo_account_id: @qa.id).count
  end

  # Accrual dating (owner decision O2): the bill is dated the last day of the
  # fee month. If garden3d's books for that month are already closed,
  # QuickBooks rejects it; say so in words Finance can act on.
  test "if the books are closed for the bill's date, the refusal says so and what to do" do
    closed = Quickbooks::IntuitRequestException.new(
      "The account period has closed and the account books cannot be updated through through QBO Services API. " \
      "Please use the QBO website to make these changes.",
    )
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(closed)

    error = assert_raises(MsoTrueup::BooksClosed) { fresh.sync_qbo_bill! }

    assert_match(%r{closed for 11/30/2090}, error.message)
    assert_match(/reopen/i, error.message)
    assert_match(/before the month is closed/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "any other QuickBooks rejection is passed on as it is" do
    Quickbooks::Service::Bill.any_instance.stubs(:create)
      .raises(Quickbooks::IntuitRequestException.new("Duplicate Document Number Error"))

    error = assert_raises(Quickbooks::IntuitRequestException) { fresh.sync_qbo_bill! }
    assert_match(/Duplicate Document Number/, error.message)
  end

  test "the Money page's sync-all contains each refusal and carries its message" do
    @mapping.destroy
    failures = nil

    assert_nothing_raised { failures = Money::RefreshPayableQboBills.call(qbo_account: @qa) }

    mine = failures.select { |host, _| host.is_a?(MsoTrueup) }
    assert_equal [@trueup.id], mine.map { |host, _| host.id }
    assert_kind_of MsoTrueup::MissingVendor, mine.first.last
  end

  # --- a bill that has gone from QuickBooks ------------------------------------

  GONE = "Object Not Found: Something you're trying to use has been made inactive".freeze

  test "a billed true-up whose bill was deleted in QuickBooks is refused, never re-created" do
    mirror!("910", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "910")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, GONE)
    Quickbooks::Service::Bill.any_instance.expects(:create).never
    Quickbooks::Service::Bill.any_instance.expects(:update).never
    # The first-bill checks are not what stops it: they would pass.
    Mso::ManagementFeeInvoices.expects(:collected?).never

    error = assert_raises(MsoTrueup::BillGone) { fresh.sync_qbo_bill! }

    assert_kind_of MsoTrueup::SyncRefused, error
    assert_match(/QuickBooks bill 910 .*no longer exists/, error.message)
    assert_match(/run the month again/i, error.message)
    assert_match(/No bill was written/, error.message)
    assert_nil fresh.qbo_bill_id
    assert_not fresh.locked?
    assert_not fresh.accepted?
    assert_equal false, fresh.payable?
    assert @snapshot.reload.invalidated?
    assert_nil QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "910")
  end

  test "the same when the row was already unaccepted and its snapshot already invalid" do
    @trueup.update_columns(qbo_bill_id: "911", accepted_at: nil)
    @snapshot.invalidate!("a later run was refused")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, GONE)
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    assert_raises(MsoTrueup::BillGone) { fresh.sync_qbo_bill! }

    assert_nil fresh.qbo_bill_id
    assert_equal false, fresh.payable?
  end

  # The override cannot reach bill CREATION except straight from the
  # first-bill checks: here the bill vanishes between the check that it
  # exists and the write.
  test "a bill that vanishes between the existence check and the write is not re-created either" do
    mirror!("912", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "912")
    MsoTrueup.any_instance.stubs(:refresh_qbo_bill_mirror!).returns(:refreshed)
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, GONE)
    QboBill.any_instance.stubs(:delete_qbo_bill!)
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    error = assert_raises(MsoTrueup::BillUnreadable) { fresh.sync_qbo_bill! }

    assert_kind_of MsoTrueup::SyncRefused, error
    assert_match(/No bill was written/, error.message)
  end

  test "a billed true-up whose bill cannot be read at the write is not given a second bill" do
    mirror!("913", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "913")
    MsoTrueup.any_instance.stubs(:refresh_qbo_bill_mirror!).returns(:refreshed)
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "execution expired")
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    assert_raises(MsoTrueup::BillUnreadable) { fresh.sync_qbo_bill! }

    assert_equal "913", fresh.qbo_bill_id
    assert fresh.accepted?
  end

  test "a QuickBooks failure reading a billed true-up's bill is passed on, and nothing is written" do
    mirror!("914", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "914")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "execution expired")
    Quickbooks::Service::Bill.any_instance.expects(:create).never

    assert_match(/execution expired/, assert_raises(RuntimeError) { fresh.sync_qbo_bill! }.message)

    assert_equal "914", fresh.qbo_bill_id
    assert fresh.accepted?
    assert_not @snapshot.reload.invalidated?
  end

  test "the Money page's sync-all refuses a vanished bill, says why, and carries on with the other rows" do
    other_exec = mso_person("bill-other")
    other_ledger = garden3d_ledger(other_exec)
    other_role = mso_role(other_exec)
    other = MsoTrueup.create!(ledger: other_ledger, invoice_pass: @pass, mso_snapshot: @snapshot,
                              mso_role_period: other_role, amount: "800", description: "MSO true-up",
                              accepted_at: Time.current)
    other_vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    ContributorQboVendor.create!(contributor: other_exec, qbo_account: @qa, qbo_vendor: other_vendor)
    mirror!("915", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "915")
    mirror!("916", { "balance" => "800", "total_amt" => "800" })
    other.update_columns(qbo_bill_id: "916")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).with("915").raises(RuntimeError, GONE)
    QboAccount.any_instance.stubs(:fetch_bill_by_id).with("916")
      .returns(remote_bill("916", balance: "800", total: "800"))
    Quickbooks::Service::Bill.any_instance.expects(:create).never
    Quickbooks::Service::Bill.any_instance.expects(:update).once
      .returns(remote_bill("916", balance: "800", total: "800"))

    failures = Money::RefreshPayableQboBills.call(qbo_account: @qa)

    assert_equal [@trueup.id], failures.map { |host, _| host.id }
    assert_kind_of MsoTrueup::BillGone, failures.first.last
    assert_nil fresh.qbo_bill_id
    assert_equal "916", other.reload.qbo_bill_id
  end

  # --- after the bill --------------------------------------------------------------

  test "a billed true-up stays in the balance when its snapshot is invalidated, and leaves it when the bill is paid" do
    mirror!("901", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "901")
    @snapshot.invalidate!("a later run was refused")

    ledger = Ledger.find(@ledger.id)
    assert_equal true, fresh.payable?
    assert_equal 1200.0, ledger.balance.to_f
    assert_equal 0.0, ledger.unsettled.to_f
    assert_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup

    QboBill.where(qbo_account_id: @qa.id, qbo_id: "901").update_all(data: { "balance" => "0", "total_amt" => "1200" })

    ledger = Ledger.find(@ledger.id)
    assert_equal 0.0, ledger.balance.to_f
    assert_equal 0.0, ledger.unsettled.to_f
    assert_not_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup
  end

  test "removing the bill clears the acceptance and invalidates the snapshot" do
    @trueup.update_columns(qbo_bill_id: "902")
    # The existing guard: re-reads the bill, refuses if paid, deletes it.
    MsoTrueup.any_instance.expects(:detach_and_destroy_qbo_bill).once

    fresh.remove_qbo_bill!

    assert_not fresh.accepted?
    assert @snapshot.reload.invalidated?
    assert_not @snapshot.fee_collected?
    assert_match(/bill for MsoTrueup #{@trueup.id} was removed/, @snapshot.invalidated_reason)
  end

  test "a paid bill cannot be removed, and nothing changes" do
    @trueup.update_columns(qbo_bill_id: "903")
    MsoTrueup.any_instance.stubs(:detach_and_destroy_qbo_bill)
      .raises(SyncsAsQboBill::PaidQboBillError, "refusing to destroy QBO bill 903")

    assert_raises(SyncsAsQboBill::PaidQboBillError) { fresh.remove_qbo_bill! }

    assert_equal "903", fresh.qbo_bill_id
    assert fresh.accepted?
    assert_not @snapshot.reload.invalidated?
  end

  # --- the nightly, read-only refresh ---------------------------------------------

  test "the mirror refresh reads the bill and writes nothing to QuickBooks" do
    mirror!("904", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "904")
    QboAccount.any_instance.expects(:fetch_bill_by_id).with("904").once.returns(remote_bill("904", balance: "0"))

    assert_equal :refreshed, fresh.refresh_qbo_bill_mirror!

    assert QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "904").paid?
    assert_equal "904", fresh.qbo_bill_id
    assert_equal 0.0, Ledger.find(@ledger.id).balance.to_f
  end

  test "a bill deleted in QuickBooks unlocks the true-up without another QuickBooks call" do
    mirror!("905", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "905")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "Object Not Found: Something you're trying to use has been made inactive")

    assert_equal :bill_gone, fresh.refresh_qbo_bill_mirror!

    assert_nil fresh.qbo_bill_id
    assert_not fresh.accepted?
    assert_nil QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "905")
    assert @snapshot.reload.invalidated?
  end

  test "the batch refresh skips bills settled long ago and contains a failure" do
    long_after = Date.new(2091, 6, 15) # the true-up's month, November, is seven months back
    mirror!("906", { "balance" => "0", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "906")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "unexpected QuickBooks read")

    assert_equal [], MsoTrueup.refresh_bill_mirrors!(today: long_after)

    QboBill.where(qbo_account_id: @qa.id, qbo_id: "906").update_all(data: { "balance" => "1200", "total_amt" => "1200" })
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "QuickBooks is down")

    failures = MsoTrueup.refresh_bill_mirrors!(today: long_after)

    assert_equal [@trueup.id], failures.map(&:first)
    assert_match(/QuickBooks is down/, failures.first.last)
    assert_equal "906", fresh.qbo_bill_id
  end

  test "a bill settled in the last six months is still refreshed, so a payment voided later is seen" do
    mirror!("907", { "balance" => "0", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "907")
    assert_equal 0.0, Ledger.find(@ledger.id).balance.to_f
    QboAccount.any_instance.expects(:fetch_bill_by_id).with("907").once.returns(remote_bill("907", balance: "1200"))

    # November is six months before May.
    assert_equal [], MsoTrueup.refresh_bill_mirrors!(today: Date.new(2091, 5, 31))

    assert_not QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "907").paid?
    assert_equal 1200.0, Ledger.find(@ledger.id).balance.to_f
  end

  # --- what withdraws a stamp or invalidates a snapshot --------------------------------

  test "nightly: a snapshot whose fee income no longer matches account 4100 is invalidated, from stored data only" do
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range).raises(RuntimeError, "unexpected QuickBooks read")

    # No stored report for the month at all: skipped, never fetched.
    assert_equal [], Mso::MonthlyRun.invalidate_snapshots_whose_fee_moved!
    assert_not @snapshot.reload.invalidated?

    report = fee_report(MONTH, "100000.0") # what the snapshot used
    assert_equal [], Mso::MonthlyRun.invalidate_snapshots_whose_fee_moved!
    assert @snapshot.reload.fee_collected?

    report.destroy
    fee_report(MONTH, "90000.0") # an invoice was voided after the run

    assert_equal [@snapshot.id], Mso::MonthlyRun.invalidate_snapshots_whose_fee_moved!
    @snapshot.reload
    assert @snapshot.invalidated?
    assert_match(/now reads 90000\.0/, @snapshot.invalidated_reason)
    assert_equal false, fresh.payable?
  end

  test "garden3d's nightly step runs the fee check, the drift check and the read-only refresh, and nothing that writes a bill" do
    Mso::ManagementFeeInvoices.stubs(:ensure_previous_month!)
    Mso::MonthlyRun.expects(:invalidate_snapshots_whose_fee_moved!).once.returns([])
    Mso::MonthlyRun.expects(:record_income_drift!).once.returns([])
    MsoTrueup.expects(:refresh_bill_mirrors!).once.returns([])
    Mso::MonthlyRun.stubs(:call).raises(RuntimeError, "the nightly step ran the month")
    MsoTrueup.any_instance.stubs(:sync_qbo_bill!).raises(RuntimeError, "the nightly step synced a bill")

    Enterprise.find(garden3d.id).daily_tasks
    # Another company's nightly step does neither: a second call would exceed `once`.
    Enterprise.find(enterprises(:sanctuary).id).daily_tasks
  end

  test "a nightly garden3d step that fails does not skip the others; every failure is reported and none leaves" do
    Mso::ManagementFeeInvoices.expects(:ensure_previous_month!).once.raises(RuntimeError, "step one broke")
    Mso::MonthlyRun.expects(:invalidate_snapshots_whose_fee_moved!).once.raises(ActiveRecord::StatementInvalid, "step two broke")
    Mso::MonthlyRun.expects(:record_income_drift!).once.returns([])
    MsoTrueup.expects(:refresh_bill_mirrors!).once.returns([[@trueup.id, "RuntimeError: QuickBooks is down"]])
    Sentry.expects(:capture_exception).twice.with { |error| error.message.match?(/step (one|two) broke/) }
    Sentry.expects(:capture_message).once.with do |message, **|
      message.include?("MsoTrueup #{@trueup.id}") && message.include?("QuickBooks is down")
    end

    assert_nothing_raised { Enterprise.find(garden3d.id).daily_tasks }
  end

  test "the nightly garden3d steps are quiet when nothing fails" do
    Mso::ManagementFeeInvoices.stubs(:ensure_previous_month!)
    Mso::MonthlyRun.stubs(:invalidate_snapshots_whose_fee_moved!).returns([])
    Mso::MonthlyRun.stubs(:record_income_drift!).returns([])
    MsoTrueup.stubs(:refresh_bill_mirrors!).returns([])
    Sentry.expects(:capture_exception).never
    Sentry.expects(:capture_message).never

    Enterprise.find(garden3d.id).daily_tasks
  end

  test "a QuickBooks failure reading the chart of accounts is not reported as a missing MSO account" do
    QboAccount.any_instance.stubs(:fetch_all_accounts).raises(RuntimeError, "QuickBooks is down")

    error = assert_raises(RuntimeError) { fresh.sync_qbo_bill! }

    assert_not_kind_of MsoTrueup::SyncRefused, error
    assert_match(/QuickBooks is down/, error.message)
    assert_no_match(/mso_compensation/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "attaching or detaching a fee invoice withdraws the collection stamp" do
    payer = make_payer("Stamp Payer #{SecureRandom.hex(3)}", customer_id: "2")
    tracker = fee_tracker(@pass, payer)
    @snapshot.update_columns(fee_collected_at: Time.current)

    attach_invoice(tracker, qbo_id: "9100", total: "100000.0", balance: "0.0", sent: true)
    assert_not @snapshot.reload.fee_collected?

    @snapshot.update_columns(fee_collected_at: Time.current)
    InvoiceTracker.find(tracker.id).update!(qbo_invoice_id: nil)
    assert_not @snapshot.reload.fee_collected?

    # A change that is not about the invoice leaves the stamp alone.
    @snapshot.update_columns(fee_collected_at: Time.current)
    InvoiceTracker.find(tracker.id).update!(notes: "a note")
    assert @snapshot.reload.fee_collected?
  end
end
