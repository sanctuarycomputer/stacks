require 'test_helper'

class Mcp::ProjectBurnupToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Time.zone.parse('2026-08-04 12:00:00')
  end

  SNAPSHOT = {
    'generated_at' => '2026-08-01T02:00:00+00:00',
    'spend' => [
      { 'x' => '2026-06-01', 'y' => 1000.0 },
      { 'x' => '2026-06-02', 'y' => 2000.0 },
      { 'x' => '2026-06-03', 'y' => 3000.0 },
    ],
    'cost' => [{ 'x' => '2026-06-30', 'y' => 1500.0 }],
    'hours' => [
      { 'x' => '2026-06-01', 'y' => 10.0 },
      { 'x' => '2026-06-02', 'y' => 20.0 },
      { 'x' => '2026-06-03', 'y' => 30.0 },
    ],
    'hours_total' => 30.0,
    'hours_free' => 0.0,
    'spend_total' => 3000.0,
    'cost_total' => 1500.0,
    'invoiced_income_total' => 2500.0,
    'invoiced_with_running_spend_total' => 3000.0,
    'first_forecast_assignment_start_date' => '2026-06-01',
    'last_forecast_assignment_end_date' => '2026-06-03',
  }.freeze

  def tracker!(budget_low: nil, budget_high: nil, snapshot: SNAPSHOT)
    pt = ProjectTracker.new(name: 'Burnup Test Tracker', budget_low_end: budget_low, budget_high_end: budget_high)
    pt.save!(validate: false)
    pt.update_column(:snapshot, snapshot)
    ProjectTracker.find(pt.id)
  end

  test 'returns the snapshot series, income series, money totals and overage' do
    tracker = tracker!(budget_low: 2000, budget_high: 2500)

    payload = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: tracker.id.to_s, server_context: {}))

    assert_equal 'Burnup Test Tracker', payload['tracker']
    assert_equal tracker.id, payload['id']
    assert_equal tracker.external_link, payload['url']
    assert_equal({ 'low' => 2000.0, 'high' => 2500.0 }, payload['budget'])

    # Snapshot series pass through verbatim; income comes from
    # ProjectTrackers::IncomeSeries (no invoices here, so just the seed point
    # at the first assignment date, and nothing skipped).
    assert_equal SNAPSHOT['spend'], payload['series']['spend']
    assert_equal SNAPSHOT['cost'], payload['series']['cost']
    assert_equal SNAPSHOT['hours'], payload['series']['hours']
    assert_equal [{ 'x' => '2026-06-01', 'y' => 0 }], payload['series']['income']
    assert_equal 0, payload['skipped_invoices']

    totals = payload['totals']
    assert_equal 2500.0, totals['invoiced']
    assert_equal 500.0, totals['running_spend']
    assert_equal 3000.0, totals['total_spend']
    assert_equal 1500.0, totals['estimated_cost']
    assert_equal 1500.0, totals['profit']
    assert_equal 50.0, totals['profit_margin']
    assert_equal 0.0, totals['commissions']

    # spend 3000 vs low 2000 / high 2500
    assert_equal({ 'at_budget' => 1000.0, 'over_budget' => 500.0 }, payload['overage'])
    assert_equal 'over_budget', payload['status']
    assert_equal 'likely_complete', payload['work_status']
    assert_equal true, payload['considered_successful']
    assert_equal '2026-08-01T02:00:00+00:00', payload['generated_at']
  end

  test 'completion math mirrors the admin page: under budget-low uses the low end' do
    tracker!(budget_low: 5000, budget_high: 8000)
    ProjectTracker.any_instance.stubs(:trailing_7_days_value).returns(350.0)
    ProjectTracker.any_instance.stubs(:trailing_30_days_value).returns(1000.0)

    payload = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: 'burnup test tracker', server_context: {}))

    completion = payload['completion']
    assert_equal 350.0, completion['trailing_7d_spend']
    assert_equal 1000.0, completion['trailing_30d_spend']
    assert_equal ((5000 - 3000) / 350.0).round(1), completion['weeks_left']
    assert_equal 2.0, completion['months_left']
    assert_equal 'budget_low_end', completion['budget_reference']
    assert_equal 'under_budget', payload['status']
  end

  test 'completion math between low and high budgets counts toward the high end' do
    tracker!(budget_low: 2500, budget_high: 8000)
    ProjectTracker.any_instance.stubs(:trailing_7_days_value).returns(350.0)
    ProjectTracker.any_instance.stubs(:trailing_30_days_value).returns(1000.0)

    completion = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: 'Burnup Test Tracker', server_context: {}))['completion']

    assert_equal ((8000 - 3000) / 350.0).round(1), completion['weeks_left']
    assert_equal 5.0, completion['months_left']
    assert_equal 'budget_high_end', completion['budget_reference']
  end

  test 'no time-remaining estimate when overbudget or when there is no recent spend' do
    tracker = tracker!(budget_low: 2000, budget_high: 2500)
    ProjectTracker.any_instance.stubs(:trailing_7_days_value).returns(350.0)
    ProjectTracker.any_instance.stubs(:trailing_30_days_value).returns(1000.0)

    completion = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: tracker.id.to_s, server_context: {}))['completion']
    assert_nil completion['weeks_left'], 'overbudget projects get an overage, not a time estimate'
    assert_nil completion['months_left']
    assert_nil completion['budget_reference']

    # No spend in the trailing 30 days: the admin hides the whole block.
    ProjectTracker.any_instance.stubs(:trailing_7_days_value).returns(0.0)
    ProjectTracker.any_instance.stubs(:trailing_30_days_value).returns(0.0)
    completion = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: tracker.id.to_s, server_context: {}))['completion']
    assert_nil completion['weeks_left']
    assert_nil completion['months_left']
  end

  test 'unknown tracker and snapshotless tracker return errors' do
    err = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: 'nope', server_context: {}))
    assert_includes err['error'], "Unknown tracker 'nope'"
    assert_includes err['error'], 'list_project_trackers'

    bare = ProjectTracker.new(name: 'No Snapshot Yet')
    bare.save!(validate: false)
    err = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: bare.id.to_s, server_context: {}))
    assert_includes err['error'], 'no generated snapshot'
  end
end
