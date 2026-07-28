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

  test "batch-cached edge assignments expose Date bounds, not raw SQL strings" do
    pt = ProjectTracker.new(name: "Edge assignment bounds")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {}) # no snapshot bounds -> forces the edge-assignment fallback

    fp = ForecastProject.new(forecast_id: 987_654, name: "FP", client_id: 123_456)
    fp.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: fp)
    fa = ForecastAssignment.new(
      project_id: fp.forecast_id,
      start_date: Date.new(2021, 6, 23),
      end_date: Date.new(2022, 3, 31),
    )
    fa.save!(validate: false)

    # preload_for_render runs batch_cache_edge_recorded_assignments!, the path the
    # admin index uses (and the only path that populates @_first_recorded_assignment
    # from raw SQL).
    ProjectTracker.preload_for_render([pt])

    assert_instance_of Date, pt.first_recorded_assignment_start_date
    assert_equal Date.new(2021, 6, 23), pt.first_recorded_assignment_start_date
    assert_instance_of Date, pt.last_recorded_assignment_end_date
    assert_equal Date.new(2022, 3, 31), pt.last_recorded_assignment_end_date
  end

  test "lifetime_commissions_paid sums as_commission across all CPs on this tracker's invoices" do
    pt = ProjectTracker.new(name: "Commission Total Test")
    pt.save!(validate: false)

    cp1 = ContributorPayout.new(amount: 50, blueprint: { "Commission" => [{ "amount" => 50 }] })
    cp2 = ContributorPayout.new(amount: 30, blueprint: { "Commission" => [{ "amount" => 30 }] })
    cp3 = ContributorPayout.new(amount: 100, blueprint: { "IndividualContributor" => [{ "amount" => 100 }] })

    invoice_tracker = mock("invoice_tracker")
    invoice_tracker.stubs(:contributor_payouts).returns([cp1, cp2, cp3])
    pt.stubs(:invoice_trackers).returns([invoice_tracker])

    assert_in_delta 80.0, pt.lifetime_commissions_paid, 0.001
  end
end
