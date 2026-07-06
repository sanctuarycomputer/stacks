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

  def payload_for(resp)
    JSON.parse(resp.content.first[:text])
  end

  test 'flags margin below the tracker target with a named reason' do
    tracker!(name: 'Thin Margin', spend: 1000.0, cost: 900.0) # margin 10% < target 30
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    row = payload['projects'].find { |p| p['name'] == 'Thin Margin' }
    assert row['at_risk']
    assert_includes row['risk_reasons'], 'margin_below_target'
    assert_equal 10.0, row['profit_margin']
    assert_equal 30.0, row['target_profit_margin']
  end

  test 'flags free hours above the tracker target' do
    tracker!(name: 'Free Heavy', hours: 100.0, free_hours: 20.0, free_target: 10)
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    row = payload['projects'].find { |p| p['name'] == 'Free Heavy' }
    assert_includes row['risk_reasons'], 'free_hours_above_target'
    assert_equal 20.0, row['free_hours_percent']
  end

  test 'flags spend beyond budget_high_end only when a budget is set' do
    tracker!(name: 'Over Budget', spend: 5000.0, cost: 1000.0, budget_low: 1000.0, budget_high: 4000.0)
    tracker!(name: 'No Budget', spend: 5000.0, cost: 1000.0)
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    over = payload['projects'].find { |p| p['name'] == 'Over Budget' }
    assert_includes over['risk_reasons'], 'over_budget'
    assert_nil payload['projects'].find { |p| p['name'] == 'No Budget' }, 'healthy-but-unbudgeted project must not be flagged'
  end

  test 'only_at_risk: false returns healthy projects too, sorted most-at-risk first' do
    tracker!(name: 'Healthy One')
    tracker!(name: 'Doubly Risky', spend: 5000.0, cost: 4800.0, budget_high: 4000.0, budget_low: 1000.0)
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(only_at_risk: false, server_context: {}))
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
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_nil payload['projects'].find { |p| p['name'] == 'Done Project' }
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(include_complete: true, server_context: {}))
    assert payload['projects'].find { |p| p['name'] == 'Done Project' }
  end

  test 'trackers with a blank snapshot are skipped with a warning, never raise' do
    tracker!(name: 'Unsnapshotted', snapshot: nil)
    tracker!(name: 'Thin Margin', spend: 1000.0, cost: 900.0)
    Rails.logger.expects(:warn).with { |msg| msg.include?('Unsnapshotted') }.at_least_once
    Sentry.expects(:capture_exception).never
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_nil payload['projects'].find { |p| p['name'] == 'Unsnapshotted' }
    assert_equal 1, payload['count']
  end

  test 'empty result is a valid payload' do
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['projects']
  end

  test 'a tracker whose mapping raises is skipped with warn + Sentry, not fatal' do
    tracker!(name: 'Raises Mid-Map', spend: 1000.0, cost: 900.0)
    ProjectTracker.any_instance.stubs(:external_link).raises(RuntimeError, 'boom')
    Rails.logger.expects(:warn).with { |msg| msg.include?('skipping tracker') }.at_least_once
    Sentry.expects(:capture_exception).at_least_once
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['projects']
  end
end
