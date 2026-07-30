require "test_helper"

class RecurringAssignmentMaterializeTest < ActiveSupport::TestCase
  def build_client
    Stacks::Forecast.allocate.tap { |c| c.instance_variable_set(:@headers, {}) }
  end

  # Monday of the current week — always on/before today (weeks start Monday),
  # so it's a safe anchor for "retrospective" occurrence dates in any run.
  def recent_monday
    Date.today.beginning_of_week
  end

  def rule(overrides = {})
    RecurringAssignment.create!({
      forecast_person_id: 324711, forecast_project_id: 3033811, allocation: 900,
      weekdays: [1], starts_on: recent_monday - 3.weeks, ends_on: nil,
    }.merge(overrides))
  end

  test "creates one Forecast assignment per past weekday occurrence, up to today" do
    ra = rule # Mondays: recent_monday-3w, -2w, -1w, recent_monday (all <= today)
    client = build_client
    client.expects(:create_assignment).times(4).returns(
      { "id" => 1 }, { "id" => 2 }, { "id" => 3 }, { "id" => 4 }
    )

    ra.materialize!(forecast_client: client)

    occ = ra.recurring_assignment_occurrences.order(:occurs_on)
    assert_equal 4, occ.count
    assert_equal [recent_monday - 3.weeks, recent_monday - 2.weeks, recent_monday - 1.week, recent_monday],
      occ.map(&:occurs_on)
    assert occ.all? { |o| o.status == "materialized" && o.forecast_assignment_id.present? }
    assert occ.all? { |o| o.occurs_on <= Date.today }, "no occurrence may be in the future"
  end

  test "never creates an occurrence after today, even with a future or blank end date" do
    ra = rule(weekdays: (0..6).to_a, starts_on: Date.today - 2, ends_on: Date.today + 30)
    client = build_client
    client.stubs(:create_assignment).returns({ "id" => 1 })

    ra.materialize!(forecast_client: client)

    dates = ra.recurring_assignment_occurrences.order(:occurs_on).map(&:occurs_on)
    assert_equal [Date.today - 2, Date.today - 1, Date.today], dates
    assert dates.all? { |d| d <= Date.today }, "must never create a future-dated occurrence"
  end

  test "is idempotent — a second run POSTs nothing new" do
    ra = rule
    c1 = build_client
    c1.stubs(:create_assignment).returns({ "id" => 1 })
    ra.materialize!(forecast_client: c1)
    count = ra.recurring_assignment_occurrences.count
    assert count.positive?

    c2 = build_client
    c2.expects(:create_assignment).never
    ra.materialize!(forecast_client: c2)
    assert_equal count, ra.recurring_assignment_occurrences.count
  end

  test "tombstones an occurrence whose Forecast assignment was deleted in the UI" do
    ra = rule(starts_on: recent_monday - 1.week, ends_on: recent_monday)
    # present-in-mirror occurrence stays materialized; absent one gets tombstoned.
    # save!(validate: false) skips the required belongs_to person/project — we only
    # need a bare mirror row for the exists?(forecast_id:) check.
    ForecastAssignment.new(forecast_id: 555).save!(validate: false)
    kept = ra.recurring_assignment_occurrences.create!(occurs_on: recent_monday, status: "materialized", forecast_assignment_id: 555)
    gone = ra.recurring_assignment_occurrences.create!(occurs_on: recent_monday - 1.week, status: "materialized", forecast_assignment_id: 999)

    client = build_client
    client.expects(:create_assignment).never # both dates already have occurrence rows
    ra.materialize!(forecast_client: client)

    assert_equal "materialized", kept.reload.status
    assert_equal "deleted", gone.reload.status
  end

  test "never recreates a tombstoned occurrence" do
    ra = rule(starts_on: recent_monday, ends_on: recent_monday) # single past Monday
    ra.recurring_assignment_occurrences.create!(occurs_on: recent_monday, status: "deleted", forecast_assignment_id: 111)

    client = build_client
    client.expects(:create_assignment).never
    ra.materialize!(forecast_client: client)

    assert_equal 1, ra.recurring_assignment_occurrences.count
    assert_equal "deleted", ra.recurring_assignment_occurrences.first.status
  end

  test "does not tombstone an out-of-window occurrence absent from the mirror (defense-in-depth)" do
    # Detection is bounded to end-of-current-month — the sync's coverage edge — so a
    # row dated beyond it (which retrospect-only creation never produces, but which we
    # guard against anyway) is never judged against the mirror and can't be falsely
    # tombstoned. Permanent tombstones warrant the belt-and-suspenders.
    ra = rule(starts_on: recent_monday, ends_on: recent_monday)
    out_of_window = ra.recurring_assignment_occurrences.create!(
      occurs_on: Date.today.next_month.beginning_of_month + 10,
      status: "materialized", forecast_assignment_id: 424242,
    )
    client = build_client
    client.stubs(:create_assignment).returns({ "id" => 1 })

    ra.materialize!(forecast_client: client)

    assert_equal "materialized", out_of_window.reload.status
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
