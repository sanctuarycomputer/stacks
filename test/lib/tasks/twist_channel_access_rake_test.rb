require 'test_helper'
require 'rake'

# The daily check of which project Twist channels the Stacksbot account can
# see, and its ride on the daily Notion sync. Nothing here may reach Twist or
# Notion: the model call, the Notion client and the error notifier are stubbed.
class TwistChannelAccessRakeTest < ActiveSupport::TestCase
  # Trackers checked, then channels the account is and is not in.
  STATS = { checked: 2, accessible: 3, inaccessible: 1 }.freeze

  setup do
    Stacks::Application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task['stacks:sync_twist_channel_access'].reenable
    Rake::Task['stacks:sync_notion'].reenable
    Stacks::Notion.stubs(:new).returns(stub(sync_database: nil))
    # The project log's sync rides on sync_notion too. It is covered in
    # sync_notion_log_rake_test.rb; here it never starts.
    Rake::Task['stacks:sync_notion_log'].reenable
    Stacks::Notion::FilteredSync.stubs(:marks).returns({})
    Stacks::Notion::FilteredSync.stubs(:run!).returns({})
    # The test environment holds a real Twist token and a failed SystemTask
    # posts to a real thread. A test that expects a report says so itself.
    Stacks::Notifications.stubs(:report_exception).raises("unstubbed")
  end

  def last_task(name)
    SystemTask.where(name: name).last
  end

  test 'sync_twist_channel_access records a successful SystemTask on a clean run' do
    ProjectTracker.expects(:sync_twist_channel_access!).once.returns(STATS)
    Stacks::Notifications.expects(:report_exception).never

    assert_difference -> { SystemTask.where(name: 'stacks:sync_twist_channel_access').count }, 1 do
      Rake::Task['stacks:sync_twist_channel_access'].invoke
    end
    task = last_task('stacks:sync_twist_channel_access')
    assert task.settled_at.present?, 'expected the task to settle'
    assert_nil task.notification_id
  end

  test 'sync_twist_channel_access records an error when the check raises' do
    error = Stacks::Twist::Error.new('Twist channels/get failed (500)')
    ProjectTracker.stubs(:sync_twist_channel_access!).raises(error)
    Stacks::Notifications.expects(:report_exception).once.with(error).returns(stub(record: nil))

    assert_difference -> { SystemTask.where(name: 'stacks:sync_twist_channel_access').count }, 1 do
      Rake::Task['stacks:sync_twist_channel_access'].invoke
    end
    assert last_task('stacks:sync_twist_channel_access').settled_at.present?, 'expected the task to settle'
  end

  test 'sync_notion clears the task cache and then runs the Twist channel check' do
    seq = sequence('after the Notion sync')
    Stacks::TaskBuilder.expects(:clear_cache!).once.in_sequence(seq)
    ProjectTracker.expects(:sync_twist_channel_access!).once.in_sequence(seq).returns(STATS)
    Stacks::Notifications.expects(:report_exception).never

    Rake::Task['stacks:sync_notion'].invoke

    assert last_task('stacks:sync_notion').settled_at.present?
    assert last_task('stacks:sync_twist_channel_access').settled_at.present?
  end

  test 'the Twist channel check still runs when the Notion sync fails' do
    boom = RuntimeError.new('notion down')
    Stacks::Notion.stubs(:new).raises(boom)
    Stacks::Notifications.expects(:report_exception).once.with(boom).returns(stub(record: nil))
    ProjectTracker.expects(:sync_twist_channel_access!).once.returns(STATS)

    Rake::Task['stacks:sync_notion'].invoke

    assert last_task('stacks:sync_notion').settled_at.present?
    assert last_task('stacks:sync_twist_channel_access').settled_at.present?
  end

  test 'the Twist channel check still runs when clearing the task cache fails' do
    Stacks::TaskBuilder.stubs(:clear_cache!).raises(RuntimeError, 'cache down')
    Stacks::Notifications.expects(:report_exception).never
    ProjectTracker.expects(:sync_twist_channel_access!).once.returns(STATS)

    Rake::Task['stacks:sync_notion'].invoke

    assert last_task('stacks:sync_notion').settled_at.present?
  end

  test "a failed Twist channel check is reported on its own task, not on the Notion sync's" do
    error = Stacks::Twist::Error.new('Twist channels/get failed (500)')
    ProjectTracker.stubs(:sync_twist_channel_access!).raises(error)
    Stacks::Notifications.expects(:report_exception).once.with(error).returns(stub(record: nil))

    Rake::Task['stacks:sync_notion'].invoke

    assert last_task('stacks:sync_notion').settled_at.present?
    assert last_task('stacks:sync_twist_channel_access').settled_at.present?
  end
end
