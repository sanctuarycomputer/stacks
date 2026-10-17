require "test_helper"
require "rake"

# The nightly bill sync bills an MSO true-up once it is payable, as it does a
# profit share, and leaves one that is not payable alone.
class SyncContributorQboBillsMsoTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 12, 1)

  # Every other class the nightly task and Contributor#sync_qbo_bills! sync.
  OTHER_KLASSES = [ContributorPayout, ContributorAdjustment, ProfitShare, Reimbursement, Trueup, PayStub].freeze

  setup do
    Stacks::Application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["stacks:sync_contributor_qbo_bills"].reenable

    @qa = garden3d_qbo_account
    fee_collected(MONTH)
    @exec = mso_person("nightly-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @trueup = mso_trueup(mso_report(MONTH), @role, @ledger, amount: "1200", accepted: true)
    assert @trueup.payable?, "sanity"

    OTHER_KLASSES.each { |klass| klass.any_instance.stubs(:sync_qbo_bill!) }
    Stacks::Notifications.stubs(:report_exception).returns(stub(record: nil))
  end

  teardown do
    clear_enterprise_memos
  end

  test "the nightly bill sync bills a payable MSO true-up" do
    synced = []
    MsoTrueup.any_instance.stubs(:sync_qbo_bill!).with { |**| synced << :mso; true }

    Rake::Task["stacks:sync_contributor_qbo_bills"].invoke

    assert_equal [:mso], synced
  end

  test "the nightly bill sync leaves an MSO true-up that is not payable alone" do
    @trueup.update_columns(accepted_at: nil)
    MsoTrueup.any_instance.expects(:sync_qbo_bill!).never

    Rake::Task["stacks:sync_contributor_qbo_bills"].invoke
  end

  test "syncing everything for a contributor bills their payable MSO true-up" do
    synced = []
    MsoTrueup.any_instance.stubs(:sync_qbo_bill!).with { |**| synced << :mso; true }

    @exec.sync_qbo_bills!

    assert_equal [:mso], synced
  end
end
