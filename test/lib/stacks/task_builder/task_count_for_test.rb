require 'test_helper'

class StacksTaskBuilderTaskCountForTest < ActiveSupport::TestCase
  test "counts only the given admin's tasks, without hydration, matching tasks_for" do
    admin_a = build_admin!
    admin_b = build_admin!
    builder = Stacks::TaskBuilder.new
    builder.stubs(:build_tasks).returns([
      StacksTask.new(type: :missing_skill_tree, subject: admin_a, owners: [admin_a]),
      StacksTask.new(type: :missing_skill_tree, subject: admin_b, owners: [admin_b]),
      StacksTask.new(type: :no_full_time_periods_set, subject: admin_b, owners: [admin_b]),
    ])

    assert_equal 1, builder.task_count_for(admin_a)
    assert_equal 2, builder.task_count_for(admin_b)
    assert_equal builder.tasks_for(admin_a).length, builder.task_count_for(admin_a)
  end

  test "returns 0 for nil and for an admin with no tasks" do
    admin = build_admin!
    builder = Stacks::TaskBuilder.new
    builder.stubs(:build_tasks).returns([])

    assert_equal 0, builder.task_count_for(nil)
    assert_equal 0, builder.task_count_for(admin)
  end
end
