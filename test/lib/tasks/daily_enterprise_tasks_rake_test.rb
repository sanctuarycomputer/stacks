require 'test_helper'
require 'rake'

# The daily task must reach PayCycles::OpenScheduledCycles even when a QBO
# account is unreachable (revoked token, lockout). A revoked refresh token on
# ONE enterprise's realm must never block payroll for every other enterprise.
class DailyEnterpriseTasksRakeTest < ActiveSupport::TestCase
  setup do
    Stacks::Application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task['stacks:daily_enterprise_tasks'].reenable

    # Neutralize every step that isn't under test so each test can poke
    # exactly one failure point.
    QboTokens::RefreshAll.stubs(:call).returns([])
    QboAccount.any_instance.stubs(:sync_all!)
    QboAccount.any_instance.stubs(:sync_all_vendors!)
    Enterprise.any_instance.stubs(:generate_snapshot!)
    Enterprise.any_instance.stubs(:daily_tasks)
    Contributor.stubs(:ensure_all_for_forecast_people!).returns(0)
    Ledger.stubs(:ensure_all!).returns(0)
    PayCycles::OpenScheduledCycles.stubs(:call).returns([])
    Ledgers::QboBoundMigrationCheck.stubs(:call).returns(stub(ready?: false))
    Stacks::GhostSync.stubs(:sync_all_with_lock!).returns(nil)
    Stacks::Notifications.stubs(:report_exception).returns(stub(record: nil))
  end

  test 'pay cycles still open when a QboAccount#sync_all! raises' do
    QboAccount.any_instance.stubs(:sync_all!).raises(RuntimeError, 'invalid_grant: Incorrect or invalid refresh token')
    PayCycles::OpenScheduledCycles.expects(:call).returns([])

    Rake::Task['stacks:daily_enterprise_tasks'].invoke

    task = SystemTask.where(name: 'stacks:daily_enterprise_tasks').last
    assert task.settled_at.present?, 'expected task to settle'
    assert_nil task.notification_id, 'expected success — a per-account sync failure must be isolated'
  end

  test 'pay cycles still open when an Enterprise#generate_snapshot! raises' do
    Enterprise.any_instance.stubs(:generate_snapshot!).raises(RuntimeError, 'invalid_grant: Incorrect or invalid refresh token')
    PayCycles::OpenScheduledCycles.expects(:call).returns([])

    Rake::Task['stacks:daily_enterprise_tasks'].invoke

    task = SystemTask.where(name: 'stacks:daily_enterprise_tasks').last
    assert task.settled_at.present?, 'expected task to settle'
    assert_nil task.notification_id, 'expected success — a per-enterprise snapshot failure must be isolated'
  end
end
