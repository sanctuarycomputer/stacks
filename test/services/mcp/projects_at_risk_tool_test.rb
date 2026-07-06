require 'test_helper'

class Mcp::ProjectsAtRiskToolTest < ActiveSupport::TestCase
  # Snapshot-backed tracker factory. Defaults produce a HEALTHY project:
  # margin 50% (>= target 30), free hours 0% (<= target 10), no budget.
  def tracker!(name:, spend: 1000.0, cost: 500.0, hours: 100.0, free_hours: 0.0,
               budget_high: nil, budget_low: nil, margin_target: 30, free_target: 10, snapshot: :default)
    snapshot = {
      'invoiced_with_running_spend_total' => spend,
      'cost_total' => cost,
      'hours_total' => hours,
      'hours_free' => free_hours,
    } if snapshot == :default

    ProjectTracker.create!(
      name: name,
      budget_low_end: budget_low,
      budget_high_end: budget_high,
      target_profit_margin: margin_target,
      target_free_hours_percent: free_target,
      project_tracker_links: [
        ProjectTrackerLink.new(name: 'SOW', url: 'https://example.com/sow', link_type: 'sow'),
        ProjectTrackerLink.new(name: 'MSA', url: 'https://example.com/msa', link_type: 'msa'),
      ],
      snapshot: snapshot
    )
  end

  test 'flags margin below the tracker target with a named reason' do
    tracker!(name: 'Thin Margin', spend: 1000.0, cost: 900.0) # margin 10% < target 30
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    row = payload['projects'].find { |p| p['name'] == 'Thin Margin' }
    assert row['at_risk']
    assert_includes row['risk_reasons'], 'margin_below_target'
    assert_equal 10.0, row['profit_margin']
    assert_equal 30.0, row['target_profit_margin']
  end

  test 'flags free hours above the tracker target' do
    tracker!(name: 'Free Heavy', hours: 100.0, free_hours: 20.0, free_target: 10)
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    row = payload['projects'].find { |p| p['name'] == 'Free Heavy' }
    assert_includes row['risk_reasons'], 'free_hours_above_target'
    assert_equal 20.0, row['free_hours_percent']
  end

  test 'flags spend beyond budget_high_end only when a budget is set' do
    tracker!(name: 'Over Budget', spend: 5000.0, cost: 1000.0, budget_low: 1000.0, budget_high: 4000.0)
    tracker!(name: 'No Budget', spend: 5000.0, cost: 1000.0)
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    over = payload['projects'].find { |p| p['name'] == 'Over Budget' }
    assert_includes over['risk_reasons'], 'over_budget'
    assert_nil payload['projects'].find { |p| p['name'] == 'No Budget' }, 'healthy-but-unbudgeted project must not be flagged'
  end

  test 'only_at_risk: false returns healthy projects too, sorted most-at-risk first' do
    tracker!(name: 'Healthy One')
    tracker!(name: 'Doubly Risky', spend: 5000.0, cost: 4800.0, budget_high: 4000.0, budget_low: 1000.0)
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(only_at_risk: false, server_context: {}))
    names = payload['projects'].map { |p| p['name'] }
    assert_includes names, 'Healthy One'
    assert_equal 'Doubly Risky', names.first, 'most tripped criteria sorts first'
    healthy = payload['projects'].find { |p| p['name'] == 'Healthy One' }
    assert_equal false, healthy['at_risk']
    assert_equal [], healthy['risk_reasons']
  end

  test 'completed trackers are excluded by default and included with include_complete' do
    done = tracker!(name: 'Done Project', spend: 1000.0, cost: 900.0)
    done.update!(work_completed_at: Time.current)
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_nil payload['projects'].find { |p| p['name'] == 'Done Project' }
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(include_complete: true, server_context: {}))
    assert payload['projects'].find { |p| p['name'] == 'Done Project' }
  end

  test 'trackers with a blank snapshot are skipped with a warning, never raise' do
    tracker!(name: 'Unsnapshotted', snapshot: nil)
    tracker!(name: 'Thin Margin', spend: 1000.0, cost: 900.0)
    Rails.logger.expects(:warn).with { |msg| msg.include?('Unsnapshotted') }.at_least_once
    Sentry.expects(:capture_exception).never
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_nil payload['projects'].find { |p| p['name'] == 'Unsnapshotted' }
    assert_equal 1, payload['count']
  end

  test 'a half-configured budget does not crash or drop the tracker; other criteria still judged' do
    # Only budget_high_end set — invalid per validation but possible in legacy
    # rows; ProjectTracker#status raises on this. The tool must still evaluate
    # margin (thin here) and not drop the row via the rescue.
    t = tracker!(name: 'Half Budget', spend: 1000.0, cost: 900.0)
    t.update_column(:budget_high_end, 4000) # bypasses the both-or-neither validation
    Sentry.expects(:capture_exception).never
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    row = payload['projects'].find { |p| p['name'] == 'Half Budget' }
    refute_nil row, 'half-budget tracker must not be silently dropped'
    assert_includes row['risk_reasons'], 'margin_below_target'
    refute_includes row['risk_reasons'], 'over_budget'
  end

  test 'a NULL target column does not crash or drop the tracker; other axes still judged' do
    # target_profit_margin NULL (legacy row; set_targets backfills 0.0 not nil).
    # target_profit_margin_satisfied? would raise on `nil <= 0`. The tracker
    # must still surface its free-hours risk, not vanish through the rescue.
    t = tracker!(name: 'Null Margin Target', hours: 100.0, free_hours: 20.0, free_target: 10)
    t.update_column(:target_profit_margin, nil)
    Sentry.expects(:capture_exception).never
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    row = payload['projects'].find { |p| p['name'] == 'Null Margin Target' }
    refute_nil row, 'NULL-target tracker must not be silently dropped'
    assert_includes row['risk_reasons'], 'free_hours_above_target'
    refute_includes row['risk_reasons'], 'margin_below_target'
  end

  test 'empty result is a valid payload' do
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['projects']
  end

  test 'a tracker whose mapping raises is skipped with warn + Sentry, not fatal' do
    tracker!(name: 'Raises Mid-Map', spend: 1000.0, cost: 900.0)
    ProjectTracker.any_instance.stubs(:external_link).raises(RuntimeError, 'boom')
    Rails.logger.expects(:warn).with { |msg| msg.include?('skipping tracker') }.at_least_once
    Sentry.expects(:capture_exception).at_least_once
    payload = mcp_payload(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['projects']
  end
end
