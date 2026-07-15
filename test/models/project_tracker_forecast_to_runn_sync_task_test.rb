require "test_helper"

class ProjectTrackerForecastToRunnSyncTaskTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    Thread.current[:sanctuary_enterprise] = nil
    # Fixture dates live in 2030; freeze "today" just past them so the
    # future-date clamp (Runn refuses future actuals) is inert for the
    # existing cases and testable for the new ones.
    travel_to Time.zone.local(2030, 5, 2, 12)

    @date = Date.new(2030, 4, 29)
    @runn_role = { "id" => 999_999, "name" => "$195.00 p/h", "standardRate" => 195.0 }
    @runn_person = { "id" => 88_888, "email" => "t@example.com" }

    @fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "TestClient-#{SecureRandom.hex(2)}")
    @fp_maintenance = ForecastProject.create!(
      forecast_id: rand(1..2_000_000_000),
      client_id: @fc.forecast_id,
      name: "Maintenance #{SecureRandom.hex(2)}",
      tags: ["195p/h"],
    )
    @fp_light = ForecastProject.create!(
      forecast_id: rand(1..2_000_000_000),
      client_id: @fc.forecast_id,
      name: "Light III #{SecureRandom.hex(2)}",
      tags: ["195p/h"],
    )

    @forecast_person = ForecastPerson.create!(
      forecast_id: rand(1..2_000_000_000),
      email: "lucy#{SecureRandom.hex(2)}@example.com",
      data: { "first_name" => "Lucy", "last_name" => "Jane" },
    )

    @task = ProjectTrackerForecastToRunnSyncTask.new(project_tracker_id: 1)
    @task.stubs(:find_or_create_runn_role_for_forecast_project).returns(@runn_role)
    @task.stubs(:find_or_create_runn_person_for_forecast_person).returns(@runn_person)
  end

  # The bug: two FAs on the same day/role/person but with DIFFERENT
  # billableMinutes used to be left as separate entries (because the
  # original `era == ra` Hash equality also compared billableMinutes).
  # Step 2 of sync! would then match BOTH against the same single Runn
  # actual and the writes would overwrite instead of summing.
  test "build_forecast_actuals collapses same (date, role, person) FAs with different billableMinutes" do
    fa_six_hours = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_maintenance.forecast_id,
      start_date: @date, end_date: @date,
      allocation: 6 * 60 * 60,  # 6 hours in seconds
    )
    fa_two_hours = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_light.forecast_id,
      start_date: @date, end_date: @date,
      allocation: 2 * 60 * 60,  # 2 hours in seconds
    )

    result = @task.send(:build_forecast_actuals, [fa_six_hours, fa_two_hours])

    assert_equal 1, result.size, "expected single collapsed actual; got #{result.inspect}"
    assert_equal 480.0, result.first["billableMinutes"], "expected 360 + 120 = 480 minutes"
    assert_equal @date.to_s, result.first["date"]
    assert_equal @runn_role["id"], result.first["roleId"]
    assert_equal @runn_person["id"], result.first["personId"]
  end

  test "build_forecast_actuals collapses same (date, role, person) FAs with IDENTICAL billableMinutes" do
    # This was the only case the old `era == ra` check handled correctly.
    fa1 = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_maintenance.forecast_id,
      start_date: @date, end_date: @date,
      allocation: 2 * 60 * 60,
    )
    fa2 = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_light.forecast_id,
      start_date: @date, end_date: @date,
      allocation: 2 * 60 * 60,
    )

    result = @task.send(:build_forecast_actuals, [fa1, fa2])

    assert_equal 1, result.size
    assert_equal 240.0, result.first["billableMinutes"]
  end

  test "build_forecast_actuals keeps FAs on different dates separate" do
    fa1 = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_maintenance.forecast_id,
      start_date: @date, end_date: @date,
      allocation: 6 * 60 * 60,
    )
    fa2 = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_maintenance.forecast_id,
      start_date: @date + 1, end_date: @date + 1,
      allocation: 6 * 60 * 60,
    )

    result = @task.send(:build_forecast_actuals, [fa1, fa2])

    assert_equal 2, result.size, "expected separate entries for two distinct dates"
    assert_equal [@date.to_s, (@date + 1).to_s].sort, result.map { |r| r["date"] }.sort
  end

  test "build_forecast_actuals keeps different people separate even on same date/role" do
    other_person = ForecastPerson.create!(
      forecast_id: rand(1..2_000_000_000),
      email: "other#{SecureRandom.hex(2)}@example.com",
      data: { "first_name" => "Other", "last_name" => "Person" },
    )
    other_runn_person = { "id" => 77_777, "email" => "other@example.com" }

    fa1 = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_maintenance.forecast_id,
      start_date: @date, end_date: @date,
      allocation: 6 * 60 * 60,
    )
    fa2 = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: other_person.forecast_id,
      project_id: @fp_maintenance.forecast_id,
      start_date: @date, end_date: @date,
      allocation: 2 * 60 * 60,
    )

    # Override the person stub to return the right Runn person per FA.
    @task.unstub(:find_or_create_runn_person_for_forecast_person)
    @task.stubs(:find_or_create_runn_person_for_forecast_person).with(@forecast_person).returns(@runn_person)
    @task.stubs(:find_or_create_runn_person_for_forecast_person).with(other_person).returns(other_runn_person)

    result = @task.send(:build_forecast_actuals, [fa1, fa2])

    assert_equal 2, result.size
    person_ids = result.map { |r| r["personId"] }.sort
    assert_equal [@runn_person["id"], other_runn_person["id"]].sort, person_ids
  end

  test "build_forecast_actuals raises when a per-day allocation includes seconds (Runn requires whole minutes)" do
    fa = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_maintenance.forecast_id,
      start_date: @date, end_date: @date,
      allocation: 89,  # 89 seconds = 1.4833... minutes
    )
    assert_raises(Stacks::Errors::Base) { @task.send(:build_forecast_actuals, [fa]) }
  end

  # raise_if_skip_required! pre-flight: archived / non-billable / missing
  # Runn project should raise Stacks::Errors::Skipped — the reason flows
  # through run!'s existing rescue, persists into a Notification row, and
  # surfaces on the project tracker admin page. Sentry/Twist suppressed.
  test "raise_if_skip_required! raises Skipped when Runn project is archived" do
    pt = mock("project_tracker")
    pt.stubs(:id).returns(1)
    pt.stubs(:name).returns("Archived PT")
    pt.stubs(:runn_project).returns(stub(is_archived: true, pricing_model: "tm"))
    @task.stubs(:project_tracker).returns(pt)
    err = assert_raises(Stacks::Errors::Skipped) { @task.send(:raise_if_skip_required!) }
    assert_match(/archived/, err.message)
  end

  test "raise_if_skip_required! raises Skipped when Runn project is non-billable" do
    pt = mock("project_tracker")
    pt.stubs(:id).returns(1)
    pt.stubs(:name).returns("Non-Billable PT")
    pt.stubs(:runn_project).returns(stub(is_archived: false, pricing_model: "nb"))
    @task.stubs(:project_tracker).returns(pt)
    err = assert_raises(Stacks::Errors::Skipped) { @task.send(:raise_if_skip_required!) }
    assert_match(/non-billable/, err.message)
  end

  test "raise_if_skip_required! raises Skipped when Runn project is missing entirely" do
    pt = mock("project_tracker")
    pt.stubs(:id).returns(1)
    pt.stubs(:name).returns("Unlinked PT")
    pt.stubs(:runn_project).returns(nil)
    @task.stubs(:project_tracker).returns(pt)
    err = assert_raises(Stacks::Errors::Skipped) { @task.send(:raise_if_skip_required!) }
    assert_match(/no linked Runn project/, err.message)
  end

  test "raise_if_skip_required! is a no-op for a normal billable, non-archived project" do
    pt = mock("project_tracker")
    pt.stubs(:id).returns(1)
    pt.stubs(:name).returns("Normal PT")
    pt.stubs(:runn_project).returns(stub(is_archived: false, pricing_model: "tm"))
    @task.stubs(:project_tracker).returns(pt)
    assert_nothing_raised { @task.send(:raise_if_skip_required!) }
  end

  # raise_skipped_if_runn_project_state_error! — defensive runtime catch for
  # the cases where our local runn_project mirror is stale relative to Runn.
  test "raise_skipped_if_runn_project_state_error! converts 'Project not found' into Skipped" do
    pt = mock("project_tracker")
    pt.stubs(:id).returns(1)
    pt.stubs(:name).returns("Stale PT")
    @task.stubs(:project_tracker).returns(pt)

    err = RuntimeError.new('{"error":"Bad Request","message":"Project not found","statusCode":400}')
    assert_raises(Stacks::Errors::Skipped) do
      @task.send(:raise_skipped_if_runn_project_state_error!, err)
    end
  end

  test "raise_skipped_if_runn_project_state_error! converts bulk-actuals 'Project with id X not found' into Skipped" do
    # POST /actuals/bulk emits this variant (with the runn project id
    # embedded in the message) when the project has been deleted upstream.
    pt = mock("project_tracker")
    pt.stubs(:id).returns(1)
    pt.stubs(:name).returns("Stale PT")
    @task.stubs(:project_tracker).returns(pt)

    err = RuntimeError.new('{"error":"Bad Request","message":"{ actuals[0]: \'Project with id 834099 not found.\', actuals[1]: \'Project with id 834099 not found.\' }","statusCode":400}')
    assert_raises(Stacks::Errors::Skipped) do
      @task.send(:raise_skipped_if_runn_project_state_error!, err)
    end
  end

  test "raise_skipped_if_runn_project_state_error! converts 'non-billable project' into Skipped" do
    pt = mock("project_tracker")
    pt.stubs(:id).returns(1)
    pt.stubs(:name).returns("Non-Billable PT")
    @task.stubs(:project_tracker).returns(pt)

    err = RuntimeError.new('{"error":"Bad Request","message":"Cannot add billable minutes to non-billable project","statusCode":400}')
    assert_raises(Stacks::Errors::Skipped) do
      @task.send(:raise_skipped_if_runn_project_state_error!, err)
    end
  end

  test "raise_skipped_if_runn_project_state_error! is a no-op for unrelated errors (caller will re-raise)" do
    pt = mock("project_tracker")
    pt.stubs(:id).returns(1)
    pt.stubs(:name).returns("PT")
    @task.stubs(:project_tracker).returns(pt)

    assert_nothing_raised { @task.send(:raise_skipped_if_runn_project_state_error!, RuntimeError.new("connection refused")) }
    assert_nothing_raised { @task.send(:raise_skipped_if_runn_project_state_error!, RuntimeError.new('{"statusCode":500}')) }
  end

  # --------------------------------------------------------------------------
  # future-date clamp + tentative auto-confirm (nightly failures of 2026-07)
  # --------------------------------------------------------------------------

  test "build_forecast_actuals never emits future-dated actuals" do
    # frozen today = 2030-05-02; FA runs 05-01 → 05-04
    fa = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_maintenance.forecast_id,
      start_date: Date.new(2030, 5, 1), end_date: Date.new(2030, 5, 4),
      allocation: 2 * 60 * 60,
    )

    result = @task.send(:build_forecast_actuals, [fa])

    assert_equal ["2030-05-01", "2030-05-02"], result.map { |r| r["date"] }.sort,
      "days after today must not sync (Runn: 'Cannot create actual for future date')"
  end

  test "build_forecast_actuals skips assignments that are entirely in the future" do
    fa = ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      person_id: @forecast_person.forecast_id,
      project_id: @fp_maintenance.forecast_id,
      start_date: Date.new(2030, 5, 3), end_date: Date.new(2030, 5, 6),
      allocation: 2 * 60 * 60,
    )

    assert_equal [], @task.send(:build_forecast_actuals, [fa])
  end

  test "confirm_runn_project_if_needed! flips a tentative project before actuals flow" do
    runn_project = RunnProject.create!(runn_id: 77_100, name: "Storm King Test", is_confirmed: false, data: {})
    tracker = ProjectTracker.new(name: "Storm King Test Tracker", runn_project_id: 77_100)
    assert tracker.save(validate: false)
    task = ProjectTrackerForecastToRunnSyncTask.new(project_tracker_id: tracker.id)
    task.stubs(:project_tracker).returns(tracker)

    runn = mock("runn")
    runn.expects(:update_project).once.with(77_100, is_confirmed: true).returns({ "id" => 77_100, "isConfirmed" => true })
    task.send(:runn, runn)

    task.send(:confirm_runn_project_if_needed!)

    assert_equal true, runn_project.reload.is_confirmed, "local mirror must flip too"
  end

  test "confirm_runn_project_if_needed! is a no-op for confirmed projects" do
    runn_project = RunnProject.create!(runn_id: 77_200, name: "Confirmed Test", is_confirmed: true, data: {})
    tracker = ProjectTracker.new(name: "Confirmed Test Tracker", runn_project_id: 77_200)
    assert tracker.save(validate: false)
    task = ProjectTrackerForecastToRunnSyncTask.new(project_tracker_id: tracker.id)
    task.stubs(:project_tracker).returns(tracker)

    runn = mock("runn")
    runn.expects(:update_project).never
    task.send(:runn, runn)

    task.send(:confirm_runn_project_if_needed!)
  end
end
