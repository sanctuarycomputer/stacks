require 'test_helper'

class Mcp::StudioHealthToolTest < ActiveSupport::TestCase
  def period_entry(label, income:, okr_health: 'healthy')
    {
      'label' => label,
      'period_starts_at' => '01/01/2026',
      'period_ends_at' => '01/31/2026',
      'cash' => {
        'datapoints' => { 'income' => { 'value' => income, 'unit' => 'usd' },
                          'lead_count' => { 'value' => 3, 'unit' => 'count' } },
        'okrs' => { 'Profit Margin' => { 'health' => okr_health, 'target' => 30 } },
      },
      'accrual' => {
        'datapoints' => { 'income' => { 'value' => income + 1, 'unit' => 'usd' } },
        'okrs' => {},
      },
      'utilization' => { 'someone@sanctuary.computer' => { 'billable' => 120 } },
    }
  end

  def studio!(name:, mini_name:, periods: 2)
    Studio.create!(
      name: name, mini_name: mini_name,
      snapshot: { 'month' => (1..periods).map { |i| period_entry("2026-%02d" % i, income: i * 1000) } }
    )
  end

  def payload_for(resp)
    JSON.parse(resp.content.first[:text])
  end

  test 'passes the chosen accounting subtree through verbatim, excluding per-person utilization' do
    studio!(name: 'Sanctuary Test', mini_name: 'sanc')
    payload = payload_for(Mcp::GetStudioHealthTool.call(studio: 'sanc', server_context: {}))
    s = payload['studios'].first
    assert_equal 'Sanctuary Test', s['studio']
    assert_equal 'month', s['gradation']
    assert_equal 'cash', s['accounting_method']
    period = s['periods'].last
    assert_equal({ 'value' => 2000, 'unit' => 'usd' }, period['datapoints']['income'])
    assert_equal 'healthy', period['okrs']['Profit Margin']['health']
    assert_nil period['utilization'], 'per-person utilization must never be emitted'
    refute s['periods'].first.key?('utilization')
  end

  test 'accrual accounting_method selects the accrual subtree' do
    studio!(name: 'Accrual Studio', mini_name: 'accr')
    payload = payload_for(Mcp::GetStudioHealthTool.call(studio: 'accr', accounting_method: 'accrual', server_context: {}))
    assert_equal 2001, payload['studios'].first['periods'].last['datapoints']['income']['value']
  end

  test 'periods param takes the most recent N' do
    studio!(name: 'Many Periods', mini_name: 'many', periods: 10)
    payload = payload_for(Mcp::GetStudioHealthTool.call(studio: 'many', periods: 3, server_context: {}))
    labels = payload['studios'].first['periods'].map { |p| p['label'] }
    assert_equal %w[2026-08 2026-09 2026-10], labels
  end

  test 'unknown studio errors listing valid studios; invalid gradation and accounting_method error' do
    studio!(name: 'Only Studio', mini_name: 'only')
    err = payload_for(Mcp::GetStudioHealthTool.call(studio: 'nope', server_context: {}))
    assert_includes err['error'], "Unknown studio 'nope'"
    assert_includes err['error'], 'Only Studio'
    err = payload_for(Mcp::GetStudioHealthTool.call(gradation: 'weekly', server_context: {}))
    assert_includes err['error'], "Invalid gradation 'weekly'"
    err = payload_for(Mcp::GetStudioHealthTool.call(accounting_method: 'both', server_context: {}))
    assert_includes err['error'], "Invalid accounting_method 'both'"
  end

  test 'listing all skips snapshotless studios with a warning; explicit request errors' do
    studio!(name: 'Has Snapshot', mini_name: 'has')
    Studio.create!(name: 'No Snapshot', mini_name: 'none')
    Rails.logger.expects(:warn).with { |msg| msg.include?('No Snapshot') }.at_least_once
    payload = payload_for(Mcp::GetStudioHealthTool.call(server_context: {}))
    assert_equal ['Has Snapshot'], payload['studios'].map { |s| s['studio'] }
    err = payload_for(Mcp::GetStudioHealthTool.call(studio: 'none', server_context: {}))
    assert_includes err['error'], 'no generated snapshot'
  end

  test 'a studio whose mapping raises is skipped with warn + Sentry, not fatal' do
    studio!(name: 'Raises Mid-Map', mini_name: 'boom')
    Studio.any_instance.stubs(:mini_name).raises(RuntimeError, 'boom')
    Rails.logger.expects(:warn).with { |msg| msg.include?('Raises Mid-Map') }.at_least_once
    Sentry.expects(:capture_exception).at_least_once
    payload = payload_for(Mcp::GetStudioHealthTool.call(server_context: {}))
    assert_equal [], payload['studios']
  end
end
