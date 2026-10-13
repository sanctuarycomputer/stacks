require "test_helper"
require "rake"

# Nothing scheduled may create, change or delete an MSO true-up's QuickBooks
# bill. The nightly bill sync writes a bill for every other ledger item; an
# MSO true-up reaches QuickBooks only from an admin's click on the Money page.
class SyncContributorQboBillsMsoTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 12, 1)

  # Every class the nightly task and Contributor#sync_qbo_bills! DO sync.
  NIGHTLY_KLASSES = [ContributorPayout, ContributorAdjustment, ProfitShare, Reimbursement, Trueup, PayStub].freeze

  setup do
    Stacks::Application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["stacks:sync_contributor_qbo_bills"].reenable

    @qa = garden3d_qbo_account
    pass = garden3d_pass(MONTH)
    @exec = mso_person("nightly-exec")
    ledger = garden3d_ledger(@exec)
    role = mso_role(@exec)
    snapshot = mso_snapshot(pass, lines: [mso_line(role, ledger, trueup: "1200.0")], collected: true)
    # As payable as a true-up gets: accepted, collected, vendor mapped.
    @trueup = mso_trueup(snapshot, role, ledger, amount: "1200", accepted: true)
    vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    ContributorQboVendor.create!(contributor: @exec, qbo_account: @qa, qbo_vendor: vendor)
    assert @trueup.payable?, "sanity: nothing but the caller stands between this row and a bill"

    # The rows the task is meant to sync are not under test, and none of them
    # may reach QuickBooks from here.
    NIGHTLY_KLASSES.each { |klass| klass.any_instance.stubs(:sync_qbo_bill!) }
    Stacks::Notifications.stubs(:report_exception).returns(stub(record: nil))

    # Mocha's expectation errors are not StandardErrors: the task's own
    # per-record rescue cannot swallow them.
    MsoTrueup.any_instance.expects(:sync_qbo_bill!).never
    MsoTrueup.any_instance.expects(:refresh_qbo_bill_mirror!).never
    Quickbooks::Service::Bill.any_instance.expects(:create).never
    Quickbooks::Service::Bill.any_instance.expects(:update).never
    Quickbooks::Service::Bill.any_instance.expects(:delete).never
  end

  teardown do
    clear_enterprise_memos
  end

  test "the nightly bill sync task never syncs an MSO true-up" do
    # A row it DOES sync, so the task demonstrably ran its loop.
    reached = []
    Trueup.any_instance.stubs(:sync_qbo_bill!).with { |**| reached << :trueup }
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: @exec)
    # (The snapshot fixture already made Sanctuary's pass for the month.)
    pass = InvoicePass.find_by!(enterprise: enterprises(:sanctuary), start_of_month: MONTH)
    Trueup.create!(invoice_pass: pass, ledger: sanctuary_ledger, amount: "10", description: "x")

    Rake::Task["stacks:sync_contributor_qbo_bills"].invoke

    assert_includes reached, :trueup
    assert_nil @trueup.reload.qbo_bill_id
    task = SystemTask.where(name: "stacks:sync_contributor_qbo_bills").last
    assert task.settled_at.present?
  end

  test "syncing everything for a contributor never syncs their MSO true-up" do
    assert_includes @exec.mso_trueups, @trueup

    @exec.sync_qbo_bills!

    assert_nil @trueup.reload.qbo_bill_id
  end
end
