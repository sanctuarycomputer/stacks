require 'test_helper'
require 'rake'

# The filtered Notion sync for the project log, and its ride on the daily
# Notion sync. Nothing here may reach Notion or Twist: the sync, the Notion
# client, the Twist check and the error notifier are all stubbed.
class SyncNotionLogRakeTest < ActiveSupport::TestCase
  STATS = { observations: { created: 3 }, problems: { created: 1 } }.freeze

  setup do
    Stacks::Application.load_tasks if Rake::Task.tasks.empty?
    %w[stacks:sync_notion stacks:sync_notion_log stacks:preview_notion_log_sync stacks:sync_twist_channel_access].each do |name|
      Rake::Task[name].reenable
    end
    Stacks::Notion.stubs(:new).returns(stub(sync_database: nil))
    ProjectTracker.stubs(:sync_twist_channel_access!).returns({ checked: 0, accessible: 0, inaccessible: 0 })
    Stacks::TaskBuilder.stubs(:clear_cache!)
    # The test environment holds a real Twist token and a failed SystemTask
    # posts to a real thread. A test that expects a report says so itself.
    Stacks::Notifications.stubs(:report_exception).raises("unstubbed")
    # No test here builds a real sync: one that forgets to stub it fails loudly.
    Stacks::Notion::FilteredSync.stubs(:run!).raises("unstubbed")
  end

  def last_task(name)
    SystemTask.where(name: name).last
  end

  test "sync_notion_log records a successful SystemTask on a clean run" do
    Stacks::Notion::FilteredSync.expects(:run!).once.with.returns(STATS)
    Stacks::Notifications.expects(:report_exception).never
    assert_difference -> { SystemTask.where(name: "stacks:sync_notion_log").count }, 1 do
      Rake::Task["stacks:sync_notion_log"].invoke
    end
    task = last_task("stacks:sync_notion_log")
    assert task.settled_at.present?
    assert_nil task.notification_id
  end

  test "sync_notion_log records an error when the sync raises" do
    error = Stacks::Notion::Error.new("Notion query of database x failed (400): bad filter", status: 400)
    Stacks::Notion::FilteredSync.stubs(:run!).raises(error)
    Stacks::Notifications.expects(:report_exception).once.with(error).returns(stub(record: nil))
    Rake::Task["stacks:sync_notion_log"].invoke
    assert last_task("stacks:sync_notion_log").settled_at.present?
  end

  test "a run skipped because another holds the lock is a success, not an error" do
    Stacks::Notion::FilteredSync.stubs(:run!).returns({ skipped: "another run holds the lock" })
    Stacks::Notifications.expects(:report_exception).never
    Rake::Task["stacks:sync_notion_log"].invoke
    assert_nil last_task("stacks:sync_notion_log").notification_id
  end

  test "the preview is a dry run, prints the counts and records no SystemTask" do
    Stacks::Notion::FilteredSync.expects(:run!).once.with(dry_run: true, mode: nil).returns(STATS)
    Stacks::Notifications.expects(:report_exception).never
    out, = capture_io do
      assert_no_difference -> { SystemTask.count } do
        Rake::Task["stacks:preview_notion_log_sync"].invoke
      end
    end
    assert_equal 3, JSON.parse(out).dig("observations", "created")
  end

  test "the preview can be made in the later runs' shape, and refuses any other word" do
    Stacks::Notion::FilteredSync.expects(:run!).once.with(dry_run: true, mode: :incremental).returns(STATS)
    capture_io { Rake::Task["stacks:preview_notion_log_sync"].invoke("incremental") }
    Rake::Task["stacks:preview_notion_log_sync"].reenable
    Stacks::Notion::FilteredSync.expects(:run!).never
    assert_raises(ArgumentError) { capture_io { Rake::Task["stacks:preview_notion_log_sync"].invoke("everything") } }
  end

  test "the daily Notion sync does not start the log sync until a first run has been made by hand" do
    Stacks::Notion::FilteredSync.stubs(:marks).returns({})
    Stacks::Notion::FilteredSync.expects(:run!).never
    Stacks::Notifications.expects(:report_exception).never
    Rake::Task["stacks:sync_notion"].invoke
    assert_nil last_task("stacks:sync_notion_log")
    assert last_task("stacks:sync_twist_channel_access").settled_at.present?
  end

  test "once there is a mark, the daily Notion sync runs the log sync after the Twist check" do
    Stacks::Notion::FilteredSync.stubs(:marks).returns({ "OBSERVATIONS" => "2026-10-12T05:00:00Z" })
    seq = sequence("after the Notion sync")
    ProjectTracker.expects(:sync_twist_channel_access!).once.in_sequence(seq).returns({})
    Stacks::Notion::FilteredSync.expects(:run!).once.in_sequence(seq).returns(STATS)
    Stacks::Notifications.expects(:report_exception).never
    Rake::Task["stacks:sync_notion"].invoke
    assert last_task("stacks:sync_notion_log").settled_at.present?
  end

  test "the log sync still runs when the Twist check fails, and its own failure is its own task's" do
    Stacks::Notion::FilteredSync.stubs(:marks).returns({ "OBSERVATIONS" => "2026-10-12T05:00:00Z" })
    twist_error = Stacks::Twist::Error.new("Twist channels/get failed (500)")
    ProjectTracker.stubs(:sync_twist_channel_access!).raises(twist_error)
    notion_error = Stacks::Notion::Error.new("Notion query failed (502)", status: 502)
    Stacks::Notion::FilteredSync.expects(:run!).once.raises(notion_error)
    Stacks::Notifications.expects(:report_exception).with(twist_error).once.returns(stub(record: nil))
    Stacks::Notifications.expects(:report_exception).with(notion_error).once.returns(stub(record: nil))
    Rake::Task["stacks:sync_notion"].invoke
    assert_nil last_task("stacks:sync_notion").notification_id, "the whole-database sync itself succeeded"
    assert last_task("stacks:sync_notion_log").settled_at.present?
  end

  test "reading the mark cannot break the daily Notion sync" do
    Stacks::Notion::FilteredSync.stubs(:marks).raises(RuntimeError, "settings unreadable")
    Stacks::Notion::FilteredSync.expects(:run!).never
    Stacks::Notifications.expects(:report_exception).never
    Rake::Task["stacks:sync_notion"].invoke
    assert last_task("stacks:sync_notion").settled_at.present?
  end
end
