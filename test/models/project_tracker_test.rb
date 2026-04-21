require "test_helper"

class ProjectTrackerTest < ActiveSupport::TestCase
  test "likely_complete? is true when snapshot end date is old and capsule is not complete" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "last_forecast_assignment_end_date" => (Date.today - 2.months).iso8601,
    })

    assert_predicate pt, :likely_complete?
  end

  test "likely_complete? is false when name matches considered_ongoing?" do
    pt = ProjectTracker.new(name: "Something ongoing")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "last_forecast_assignment_end_date" => (Date.today - 2.months).iso8601,
    })

    assert_not pt.likely_complete?
  end

  test "likely_complete? is false when snapshot end date is recent" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "last_forecast_assignment_end_date" => Date.today.iso8601,
    })

    assert_not pt.likely_complete?
  end

  test "likely_complete? is false when snapshot end date is missing" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {})

    assert_not pt.likely_complete?
  end

  test "likely_complete? is false when project_capsule has all four statuses set" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "last_forecast_assignment_end_date" => (Date.today - 2.months).iso8601,
    })
    ProjectCapsule.create!(
      project_tracker: pt,
      client_feedback_survey_status: :no_response_from_client,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
    )

    assert_not pt.reload.likely_complete?
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
