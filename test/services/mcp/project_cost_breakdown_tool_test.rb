require 'test_helper'

class Mcp::ProjectCostBreakdownToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Time.zone.parse('2026-08-04 12:00:00')
  end

  test 'computes the salary path live from assignments, one row per person per month' do
    studio, = make_studio!
    admin = make_admin_user!(studio, Date.new(2026, 1, 1), nil, 'ada@thoughtbot.com')
    fproject, = make_forecast_project!
    tracker = make_project_tracker!([fproject])
    ForecastAssignment.create!(
      forecast_id: 78_001,
      forecast_person: admin.forecast_person,
      forecast_project: fproject,
      start_date: Date.new(2026, 7, 6),
      end_date: Date.new(2026, 7, 10), # Mon-Fri
      allocation: 28_800 # 8h/day
    )
    # Pin the daily employment cost so the assertion is exact: 5 weekdays x $100.
    AdminUser.any_instance.stubs(:cost_of_employment_on_date).returns(100.0)

    payload = mcp_payload(Mcp::GetProjectCostBreakdownTool.call(tracker: tracker.id.to_s, server_context: {}))

    assert_equal 'Healthcare.gov Project Tracker', payload['tracker']
    assert_equal tracker.id, payload['id']
    assert_equal tracker.external_link, payload['url']
    assert_equal 1, payload['months'].length

    month = payload['months'].first
    assert_equal '2026-07-31', month['month'], 'salary costs accrue at end of month'
    assert_equal [
      { 'name' => 'ada@thoughtbot.com', 'type' => 'salary', 'amount' => 500.0 },
    ], month['people']
    assert_equal 500.0, month['total']
    assert_equal 500.0, payload['total']
  end

  test 'serializes mixed salary and contributor_payout months in date order with totals' do
    fproject, = make_forecast_project!
    tracker = make_project_tracker!([fproject])
    ada = ForecastPerson.create!(forecast_id: 88_101, email: 'ada@thoughtbot.com')
    grace = ForecastPerson.create!(forecast_id: 88_102, email: 'grace@thoughtbot.com')
    ProjectTracker.any_instance.stubs(:monthly_cosr).returns({
      Date.new(2026, 6, 30) => {
        ada => { amount: 1200.559, type: :contributor_payout },
      },
      Date.new(2026, 7, 31) => {
        grace => { amount: 25.0, type: :salary },
        ada => { amount: 50.0, type: :salary },
      },
    })

    payload = mcp_payload(Mcp::GetProjectCostBreakdownTool.call(tracker: 'healthcare.gov project tracker', server_context: {}))

    assert_equal %w[2026-06-30 2026-07-31], payload['months'].map { |m| m['month'] }
    june, july = payload['months']
    assert_equal [
      { 'name' => 'ada@thoughtbot.com', 'type' => 'contributor_payout', 'amount' => 1200.56 },
    ], june['people']
    assert_equal 1200.56, june['total']
    assert_equal [
      { 'name' => 'ada@thoughtbot.com', 'type' => 'salary', 'amount' => 50.0 },
      { 'name' => 'grace@thoughtbot.com', 'type' => 'salary', 'amount' => 25.0 },
    ], july['people'], 'people sorted by name within a month'
    assert_equal 75.0, july['total']
    assert_equal 1275.56, payload['total']
  end

  test 'a tracker with no recorded costs returns empty months' do
    fproject, = make_forecast_project!
    tracker = make_project_tracker!([fproject])

    payload = mcp_payload(Mcp::GetProjectCostBreakdownTool.call(tracker: tracker.id.to_s, server_context: {}))

    assert_equal [], payload['months']
    assert_equal 0.0, payload['total']
  end

  test 'unknown tracker returns an error pointing at list_project_trackers' do
    err = mcp_payload(Mcp::GetProjectCostBreakdownTool.call(tracker: 'nope', server_context: {}))
    assert_includes err['error'], "Unknown tracker 'nope'"
    assert_includes err['error'], 'list_project_trackers'
  end
end
