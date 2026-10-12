require 'test_helper'
require 'rake'

# Copies a Notion project the code before notion_project_ids saved (in the
# superseded notion_project_id column) into the new list. The migration runs
# the same statement; this task picks up a choice saved between the migration
# and the deploy. Nothing here may reach Twist or Notion.
class BackfillNotionProjectIdsRakeTest < ActiveSupport::TestCase
  setup do
    Stacks::Application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task['stacks:backfill_notion_project_ids'].reenable
    Stacks::Notifications.expects(:report_exception).never
    ProjectTracker.expects(:sync_twist_channel_access!).never
    Stacks::Notion.expects(:new).never
    Stacks::Twist.expects(:new).never
  end

  def tracker!(**attrs)
    pt = ProjectTracker.new({ name: "Backfill #{SecureRandom.hex(2)}" }.merge(attrs))
    pt.save!(validate: false)
    pt
  end

  # ProjectTracker ignores the old column, so it is set as the old code's
  # INSERT or UPDATE would have left it.
  def legacy!(pt, value)
    ProjectTracker.connection.exec_update(
      "UPDATE project_trackers SET notion_project_id = $1 WHERE id = $2", "SQL", [value, pt.id]
    )
    pt
  end

  def run_task
    capture_io { Rake::Task['stacks:backfill_notion_project_ids'].invoke }.first
  end

  test "a legacy notion_project_id is copied into the list" do
    id = SecureRandom.uuid
    pt = legacy!(tracker!, id)
    assert_equal [], pt.reload.notion_project_ids

    out = run_task

    assert_equal [id], pt.reload.notion_project_ids
    assert_match(/1 tracker/, out)
  end

  test "a tracker with no legacy id, or a blank one, is left with an empty list" do
    none = tracker!
    blank = legacy!(tracker!, "")
    spaces = legacy!(tracker!, "  ")

    run_task

    assert_equal [], none.reload.notion_project_ids
    assert_equal [], blank.reload.notion_project_ids
    assert_equal [], spaces.reload.notion_project_ids
  end

  test "a list that already has something in it is never overwritten" do
    chosen = SecureRandom.uuid
    pt = legacy!(tracker!, SecureRandom.uuid)
    pt.update_columns(notion_project_ids: [chosen])

    run_task

    assert_equal [chosen], pt.reload.notion_project_ids
  end

  test "running it twice changes nothing the second time" do
    id = SecureRandom.uuid
    pt = legacy!(tracker!, id)

    run_task
    Rake::Task['stacks:backfill_notion_project_ids'].reenable
    out = run_task

    assert_equal [id], pt.reload.notion_project_ids
    assert_match(/0 trackers/, out)
  end

  test "the old column and the tracker's timestamps are left as they were" do
    id = SecureRandom.uuid
    pt = legacy!(tracker!, id)
    stamp = pt.reload.updated_at

    run_task

    assert_equal id, ProjectTracker.connection.select_value("SELECT notion_project_id FROM project_trackers WHERE id = #{pt.id}")
    assert_equal stamp, pt.reload.updated_at
  end

  test "the task cache is cleared, since a copied project settles a task" do
    legacy!(tracker!, SecureRandom.uuid)
    Stacks::TaskBuilder.expects(:clear_cache!).once
    run_task
  end

  test "the migration runs the same statement as the task" do
    statement = ->(text) { text[/UPDATE project_trackers.*?cardinality\(notion_project_ids\) = 0/m].to_s.split.join(" ") }
    migration = statement.call(File.read(Rails.root.join("db/migrate/20261013090000_add_many_project_sources_to_project_trackers.rb")))
    task = statement.call(File.read(Rails.root.join("lib/tasks/stacks.rake")))
    assert migration.present?
    assert_equal migration, task
  end
end
