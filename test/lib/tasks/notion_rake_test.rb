require "test_helper"
require "rake"

class NotionRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("stacks:notion:sweep")
    %w[stacks:notion:sweep stacks:notion:backfill stacks:notion:reconcile].each { |t| Rake::Task[t].reenable if Rake::Task.task_defined?(t) }
  end

  test "sweep records a SystemTask and success" do
    Stacks::Notion::Sweep.expects(:run_with_lock!).returns({ requests_spent: 0 })
    Rake::Task["stacks:notion:sweep"].invoke
    task = SystemTask.order(:id).last
    assert_equal "stacks:notion:sweep", task.name
    assert task.settled_at.present?
    assert_nil task.notification
  end

  test "sweep records an error" do
    Stacks::Notion::Sweep.expects(:run_with_lock!).raises(RuntimeError.new("boom"))
    Stacks::Notifications.stubs(:report_exception).returns(stub(record: nil))
    Rake::Task["stacks:notion:sweep"].invoke
    assert SystemTask.order(:id).last.settled_at.present?
  end
end
