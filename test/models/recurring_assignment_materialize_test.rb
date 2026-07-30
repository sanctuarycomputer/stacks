require "test_helper"

class RecurringAssignmentMaterializeTest < ActiveSupport::TestCase
  def build_client
    Stacks::Forecast.allocate.tap { |c| c.instance_variable_set(:@headers, {}) }
  end

  def rule(overrides = {})
    RecurringAssignment.create!({
      forecast_person_id: 324711, forecast_project_id: 3033811, allocation: 900,
      weekdays: [1], starts_on: Date.new(2026, 8, 3), ends_on: Date.new(2026, 8, 24),
    }.merge(overrides))
  end

  test "creates one Forecast assignment per expected weekday and records occurrences" do
    ra = rule # Mondays 2026-08-03,10,17,24 => 4 occurrences
    client = build_client
    client.expects(:create_assignment).times(4).returns(
      { "id" => 1 }, { "id" => 2 }, { "id" => 3 }, { "id" => 4 }
    )

    ra.materialize!(forecast_client: client)

    occ = ra.recurring_assignment_occurrences.order(:occurs_on)
    assert_equal 4, occ.count
    assert_equal [Date.new(2026,8,3), Date.new(2026,8,10), Date.new(2026,8,17), Date.new(2026,8,24)], occ.map(&:occurs_on)
    assert occ.all? { |o| o.status == "materialized" && o.forecast_assignment_id.present? }
  end

  test "is idempotent — a second run POSTs nothing new" do
    ra = rule
    c1 = build_client
    c1.stubs(:create_assignment).returns({ "id" => 1 })
    ra.materialize!(forecast_client: c1)
    assert_equal 4, ra.recurring_assignment_occurrences.count

    c2 = build_client
    c2.expects(:create_assignment).never
    ra.materialize!(forecast_client: c2)
    assert_equal 4, ra.recurring_assignment_occurrences.count
  end

  test "tombstones an occurrence whose Forecast assignment was deleted in the UI" do
    ra = rule(ends_on: Date.new(2026, 8, 3)) # single Monday
    # present-in-mirror occurrence stays materialized; absent one gets tombstoned.
    # save!(validate: false) skips the required belongs_to person/project — we only
    # need a bare mirror row for the exists?(forecast_id:) check.
    ForecastAssignment.new(forecast_id: 555).save!(validate: false)
    kept = ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 3), status: "materialized", forecast_assignment_id: 555)
    gone = ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 7, 27), status: "materialized", forecast_assignment_id: 999)

    client = build_client
    client.expects(:create_assignment).never # both dates already have occurrence rows
    ra.materialize!(forecast_client: client)

    assert_equal "materialized", kept.reload.status
    assert_equal "deleted", gone.reload.status
  end

  test "never recreates a tombstoned occurrence" do
    ra = rule(ends_on: Date.new(2026, 8, 3)) # single Monday 08-03
    ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 3), status: "deleted", forecast_assignment_id: 111)

    client = build_client
    client.expects(:create_assignment).never
    ra.materialize!(forecast_client: client)

    assert_equal 1, ra.recurring_assignment_occurrences.count
    assert_equal "deleted", ra.recurring_assignment_occurrences.first.status
  end

  test "open-ended rule stops at the 26-week horizon" do
    ra = rule(starts_on: Date.today, ends_on: nil, weekdays: [Date.today.wday])
    dates = ra.expected_occurrence_dates
    assert dates.max <= Date.today + RecurringAssignment::HORIZON
    assert dates.max > Date.today + (RecurringAssignment::HORIZON - 1.week)
  end

  test "does not tombstone a future occurrence merely absent from the month-bounded mirror" do
    # Future-dated assignments are never in the ForecastAssignment mirror (sync only
    # walks up to the current month), so absence must NOT be read as a UI deletion.
    ra = rule(starts_on: Date.today, ends_on: Date.today)
    future = ra.recurring_assignment_occurrences.create!(
      occurs_on: Date.today.next_month.beginning_of_month + 10,
      status: "materialized", forecast_assignment_id: 424242,
    )
    client = build_client
    client.stubs(:create_assignment).returns({ "id" => 1 })

    ra.materialize!(forecast_client: client)

    assert_equal "materialized", future.reload.status, "future occurrence must not be falsely tombstoned"
  end

  test "tombstones a past occurrence absent from the mirror" do
    ra = rule(starts_on: Date.today - 60, ends_on: Date.today - 60)
    past = ra.recurring_assignment_occurrences.create!(
      occurs_on: Date.today - 40, status: "materialized", forecast_assignment_id: 777,
    )
    client = build_client
    client.stubs(:create_assignment).returns({ "id" => 1 })

    ra.materialize!(forecast_client: client)

    assert_equal "deleted", past.reload.status
  end
end
