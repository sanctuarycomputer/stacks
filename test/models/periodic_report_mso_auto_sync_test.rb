require "test_helper"

# The nightly garden3d step syncs a month's MSO true-ups once every garden3d
# invoice for that month is paid. It re-reads the invoices first (QuickBooks
# READS only) and never creates a bill.
class PeriodicReportMsoAutoSyncTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2093, 5, 1)
  TODAY = Date.new(2093, 6, 10)

  def setup
    build_mso_month(MONTH)
    @report = mso_report(MONTH)
    Stacks::Notifications.stubs(:twist).returns(stub(add_comment_to_thread: nil))
    # No QuickBooks bill may be written by anything here.
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(RuntimeError, "unexpected QuickBooks bill write")
    Quickbooks::Service::Bill.any_instance.stubs(:update).raises(RuntimeError, "unexpected QuickBooks bill write")
  end

  def teardown
    clear_enterprise_memos
  end

  def collected(answer)
    Mso::IntercompanyInvoices.stubs(:collected?).returns(answer)
  end

  def run_nightly
    PeriodicReport.sync_collected_mso_months!(today: TODAY)
  end

  def trueups
    MsoTrueup.where(periodic_report_id: @report.id)
  end

  test "a finished month whose invoices are all paid is synced, unaccepted, with no bill" do
    collected(true)

    assert_equal [], run_nightly

    assert_equal 2, trueups.count
    assert trueups.all? { |trueup| trueup.accepted_at.nil? && trueup.qbo_bill_id.nil? }
  end

  test "a month whose invoices are not all paid is left alone" do
    collected(false)

    run_nightly

    assert_equal 0, trueups.count
  end

  test "the current month is not synced, and neither is a month before the MSO began" do
    current = mso_report(TODAY.beginning_of_month)
    Mso::IntercompanyInvoices.expects(:collected?).with { |invoice_pass:| invoice_pass.start_of_month == MONTH }
      .once.returns(false)

    run_nightly

    assert_equal 0, MsoTrueup.where(periodic_report_id: current.id).count
  end

  test "a settled month is not re-read or recomputed" do
    collected(true)
    run_nightly
    trueups.each { |trueup| trueup.update_columns(accepted_at: Time.current) }
    Mso::IntercompanyInvoices.expects(:collected?).never
    PeriodicReport.any_instance.expects(:sync_mso_trueups!).never

    run_nightly
  end

  test "a month whose last sync failed is skipped until an admin syncs it again" do
    collected(true)
    Mso::MonthlyRun.stubs(:compute).raises(Mso::MonthlyRun::Refused, "a founder true-up is still there")
    run_nightly
    assert @report.reload.notification.present?, "sanity: the failure is recorded on the report"

    Mso::MonthlyRun.unstub(:compute)
    PeriodicReport.any_instance.expects(:sync_mso_trueups!).never
    run_nightly

    assert_equal 0, trueups.count
  end

  test "a QuickBooks read that fails is handed back, and the next month is still tried" do
    later = mso_report(MONTH.next_month)
    garden3d_pass(MONTH.next_month)
    Mso::IntercompanyInvoices.stubs(:collected?).with { |invoice_pass:| invoice_pass.start_of_month == MONTH }
      .raises(Mso::IntercompanyInvoices::RefreshFailed, "QuickBooks is down")
    Mso::IntercompanyInvoices.stubs(:collected?).with { |invoice_pass:| invoice_pass.start_of_month == MONTH.next_month }
      .returns(false)

    failures = PeriodicReport.sync_collected_mso_months!(today: Date.new(2093, 7, 10))

    assert_equal [@report.id], failures.map(&:first)
    assert_match(/QuickBooks is down/, failures.first.last)
    assert_equal 0, MsoTrueup.where(periodic_report_id: later.id).count
  end

  test "garden3d's nightly tasks run the sync" do
    PeriodicReport.expects(:sync_collected_mso_months!).once.returns([])

    Enterprise.garden3d.daily_tasks
  end
end
