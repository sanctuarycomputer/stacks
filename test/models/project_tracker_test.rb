require "test_helper"

class ProjectTrackerTest < ActiveSupport::TestCase
  test "likely_complete? is true when in dormant scope and name is not ongoing or retainer" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)

    chain = mock("chain")
    ProjectTracker.expects(:dormant).returns(chain)
    chain.expects(:where).with(id: pt.id).returns(chain)
    chain.expects(:exists?).returns(true)

    assert_predicate pt, :likely_complete?
  end

  test "likely_complete? is false when name matches considered_ongoing?" do
    pt = ProjectTracker.new(name: "Something ongoing")
    pt.save!(validate: false)

    chain = mock("chain")
    ProjectTracker.expects(:dormant).returns(chain)
    chain.expects(:where).with(id: pt.id).returns(chain)
    chain.expects(:exists?).returns(true)

    assert_not pt.likely_complete?
  end

  test "likely_complete? is false when not in dormant scope" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)

    chain = mock("chain")
    ProjectTracker.expects(:dormant).returns(chain)
    chain.expects(:where).with(id: pt.id).returns(chain)
    chain.expects(:exists?).returns(false)

    assert_not pt.likely_complete?
  end

  test "dormant scope filters on snapshot last_forecast_assignment_end_date" do
    sql = ProjectTracker.dormant.to_sql
    assert_includes sql, "last_forecast_assignment_end_date"
    assert_includes sql, "snapshot"
  end

  test "in_progress scope generates SQL without loading ids in Ruby" do
    sql = ProjectTracker.in_progress.to_sql
    assert_predicate sql, :present?
    assert_includes sql, "project_trackers"
  end

  test "first_recorded_assignment_start_date and last_recorded_assignment_end_date read snapshot when set" do
    pt = ProjectTracker.new(name: "Snapshot bounds")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "first_forecast_assignment_start_date" => "2024-01-10",
      "last_forecast_assignment_end_date" => "2024-06-30",
    })

    assert_equal Date.new(2024, 1, 10), pt.reload.first_recorded_assignment_start_date
    assert_equal Date.new(2024, 6, 30), pt.last_recorded_assignment_end_date
  end
end
