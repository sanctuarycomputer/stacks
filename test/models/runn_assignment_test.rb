require "test_helper"

class RunnAssignmentTest < ActiveSupport::TestCase
  def build(start_date:, end_date:, minutes_per_day: 480, is_non_working_day: false)
    RunnAssignment.new(runn_id: 1, person_id: 1, project_id: 1, role_id: 1,
                       start_date: start_date, end_date: end_date,
                       minutes_per_day: minutes_per_day, is_non_working_day: is_non_working_day)
  end

  # 2026-09-07 is a Monday; 2026-09-13 a Sunday.
  test "working_days_between counts Monday to Friday inside the overlap" do
    a = build(start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 13))
    assert_equal 5, a.working_days_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30))
  end

  test "working_days_between clips to the window on both sides" do
    a = build(start_date: Date.new(2026, 8, 24), end_date: Date.new(2026, 10, 9))
    # Sep 2026: 22 weekdays (Sep 1 is a Tuesday, Sep 30 a Wednesday)
    assert_equal 22, a.working_days_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30))
  end

  test "working_days_between is zero when there is no overlap" do
    a = build(start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 5))
    assert_equal 0, a.working_days_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30))
  end

  test "non-working-day assignments count every calendar day" do
    a = build(start_date: Date.new(2026, 9, 12), end_date: Date.new(2026, 9, 13), is_non_working_day: true)
    assert_equal 2, a.working_days_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30))
  end

  test "hours_between multiplies working days by minutes_per_day" do
    a = build(start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 11), minutes_per_day: 120)
    assert_in_delta 10.0, a.hours_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30)), 0.001
  end

  test "overlapping scope finds rows touching the range and plannable excludes templates and inactive rows" do
    RunnAssignment.create!(runn_id: 9001, person_id: 1, project_id: 1, role_id: 1, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 5), minutes_per_day: 60)
    RunnAssignment.create!(runn_id: 9002, person_id: 1, project_id: 1, role_id: 1, start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 5), minutes_per_day: 60)
    RunnAssignment.create!(runn_id: 9003, person_id: 1, project_id: 1, role_id: 1, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 5), minutes_per_day: 60, is_template: true)
    RunnAssignment.create!(runn_id: 9004, person_id: 1, project_id: 1, role_id: 1, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 5), minutes_per_day: 60, is_active: false)

    ids = RunnAssignment.plannable.overlapping(Date.new(2026, 9, 1), Date.new(2026, 9, 30)).pluck(:runn_id)
    assert_equal [9001], ids
  end

  test "associations resolve through runn_id" do
    RunnPerson.create!(runn_id: 501, first_name: "A", last_name: "B", email: "AB@Example.com")
    RunnRole.create!(runn_id: 601, name: "$195.00 p/h", standard_rate: 195, default_hour_cost: 0)
    RunnProject.create!(runn_id: 701, name: "P")
    a = RunnAssignment.create!(runn_id: 9005, person_id: 501, project_id: 701, role_id: 601, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 5), minutes_per_day: 60)
    assert_equal "A", a.runn_person.first_name
    assert_equal 195, a.runn_role.standard_rate
    assert_equal "P", a.runn_project.name
    assert_equal [a], RunnProject.find(701).runn_assignments.to_a
  end

  test "RunnPerson#contributor matches a forecast person by lowercased email" do
    fp = ForecastPerson.create!(forecast_id: 880_001, email: "match-me@example.com", data: {})
    person = RunnPerson.create!(runn_id: 502, first_name: "M", last_name: "E", email: "Match-Me@Example.com")
    assert_equal fp.contributor, person.contributor
    assert_nil RunnPerson.new(runn_id: 503, email: "").contributor
  end

  test "System#runn_synced_at round-trips through settings" do
    s = System.first || System.create!(settings: {})
    assert_nil s.runn_synced_at
    t = Time.current.change(usec: 0)
    s.update!(runn_synced_at: t)
    assert_equal t.to_i, System.first.runn_synced_at.to_i
  end

  test "RunnPerson#link points at the person's Runn page" do
    assert_equal "https://app.runn.io/people/504", RunnPerson.new(runn_id: 504).link
    assert_equal "https://app.runn.io/planner", RunnPerson::PLANNER_URL
  end
end
