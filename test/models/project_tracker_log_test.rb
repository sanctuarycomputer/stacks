require 'test_helper'

class ProjectTrackerLogTest < ActiveSupport::TestCase
  include NotionLogFixtures

  test "a tracker's observations and problems are the rows filed under any of its Notion projects" do
    tracker, project_id = log_tracker!
    second = project_page!(title: "Harvey Phase 2").notion_id
    tracker.update_columns(notion_project_ids: [project_id, second])
    mine = observation!(project_ids: [project_id])
    also_mine = observation!(project_ids: [SecureRandom.uuid, second])
    observation!(project_ids: [SecureRandom.uuid])
    observation!(project_ids: [])
    my_problem = problem!(project_ids: [second])
    problem!(project_ids: [SecureRandom.uuid])

    assert_equal [mine.id, also_mine.id].sort, tracker.observations.pluck(:id).sort
    assert_equal [my_problem.id], tracker.problems.pluck(:id)
  end

  test "two trackers that share a project both see its rows" do
    tracker, project_id = log_tracker!
    other = ProjectTracker.new(name: "Sibling", notion_project_ids: [project_id])
    other.save!(validate: false)
    row = observation!(project_ids: [project_id])
    assert_equal [row.id], tracker.observations.pluck(:id)
    assert_equal [row.id], other.observations.pluck(:id)
  end

  test "a tracker with no Notion project has none, without a query that matches everything" do
    tracker, = log_tracker!(project: nil)
    observation!(project_ids: [])
    assert_equal 0, tracker.observations.count
    assert_equal 0, tracker.problems.count
  end

  test "a row trashed by the sync is not returned" do
    tracker, project_id = log_tracker!
    observation!(project_ids: [project_id]).destroy
    assert_equal 0, tracker.observations.count
  end

  test "the relations can be ordered and limited" do
    tracker, project_id = log_tracker!
    old = observation!(project_ids: [project_id], observed_at: 3.days.ago)
    new = observation!(project_ids: [project_id], observed_at: 1.day.ago)
    assert_equal [new.id, old.id], tracker.observations.order(occurred_at: :desc).limit(5).pluck(:id)
  end
end
