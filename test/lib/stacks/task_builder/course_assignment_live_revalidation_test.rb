require "test_helper"

# Production's Rails.cache is a per-process memory store, so clearing it in the
# worker that handled a request leaves the other workers' copies stale for up
# to 24h. The overdue pill is the payout block, so TaskBuilder must drop
# course-assignment tasks that are no longer true on every read.
class StacksTaskBuilderCourseAssignmentLiveRevalidationTest < ActiveSupport::TestCase
  D = Stacks::TaskBuilder::Discoveries::CourseAssignments

  setup do
    @store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@store)
    build_admin!
    @person = learning_person!
    @mod = learning_module!(steps: ["read"])
    @assignment = learning_assign!(@person, learning_course!(modules: [@mod]), due_on: Date.today - 1)
  end

  def cached_types_for(person)
    Stacks::TaskBuilder.new.tasks_for(person).select { |t| t.subject.is_a?(CourseAssignment) }.map(&:type)
  end

  test "a cached overdue task disappears as soon as the assignment is finished, without clearing the cache" do
    assert_equal [D::OVERDUE], cached_types_for(@person)
    count_before = Stacks::TaskBuilder.new.task_count_for(@person)
    cached = @store.read(Stacks::TaskBuilder::CACHE_KEY)

    complete_step!(@person, @mod.module_steps.first)
    Stacks::Learning::Progress.refresh!(@person)
    # Simulate another worker: put the stale descriptors back.
    @store.write(Stacks::TaskBuilder::CACHE_KEY, cached)

    assert_empty cached_types_for(@person)
    assert_equal count_before - 1, Stacks::TaskBuilder.new.task_count_for(@person)
    assert_empty Stacks::TaskBuilder.new.tasks.select { |t| t.subject.is_a?(CourseAssignment) }
  end

  test "a still-true cached task is kept" do
    cached_types_for(@person)
    assert_equal [D::OVERDUE], cached_types_for(@person)
  end

  test "a cached task whose assignment was deleted is dropped" do
    cached_types_for(@person)
    cached = @store.read(Stacks::TaskBuilder::CACHE_KEY)
    @assignment.delete
    @store.write(Stacks::TaskBuilder::CACHE_KEY, cached)
    assert_empty cached_types_for(@person)
  end

  test "a person with no course-assignment task triggers no live re-validation" do
    other = learning_person!
    cached_types_for(@person) # warm the cache
    D.expects(:live_types_by_id).never
    Stacks::TaskBuilder.new.tasks_for(other)
    Stacks::TaskBuilder.new.task_count_for(other)
  end
end
