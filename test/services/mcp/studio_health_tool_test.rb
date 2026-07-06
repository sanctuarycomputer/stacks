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

  test 'passes the chosen accounting subtree through verbatim, excluding per-person utilization' do
    studio!(name: 'Sanctuary Test', mini_name: 'sanc')
    payload = mcp_payload(Mcp::GetStudioHealthTool.call(studio: 'sanc', server_context: {}))
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

  test 'resolves a studio by one element of a comma-separated mini_name' do
    studio!(name: 'Comma Studio', mini_name: 'cs, sanctu')
    payload = mcp_payload(Mcp::GetStudioHealthTool.call(studio: 'sanctu', server_context: {}))
    assert_equal 'Comma Studio', payload['studios'].first['studio']
  end

  test 'an exact name match wins over another studio carrying that string as a mini_name alias' do
    studio!(name: 'Alias Holder', mini_name: 'ah, orbit')
    studio!(name: 'Orbit', mini_name: 'orb')
    payload = mcp_payload(Mcp::GetStudioHealthTool.call(studio: 'Orbit', server_context: {}))
    assert_equal 'Orbit', payload['studios'].first['studio'], 'real name must not be shadowed by an alias'
  end

  test 'accrual accounting_method selects the accrual subtree' do
    studio!(name: 'Accrual Studio', mini_name: 'accr')
    payload = mcp_payload(Mcp::GetStudioHealthTool.call(studio: 'accr', accounting_method: 'accrual', server_context: {}))
    assert_equal 2001, payload['studios'].first['periods'].last['datapoints']['income']['value']
  end

  test 'periods param takes the most recent N' do
    studio!(name: 'Many Periods', mini_name: 'many', periods: 10)
    payload = mcp_payload(Mcp::GetStudioHealthTool.call(studio: 'many', periods: 3, server_context: {}))
    labels = payload['studios'].first['periods'].map { |p| p['label'] }
    assert_equal %w[2026-08 2026-09 2026-10], labels
  end

  test 'unknown studio errors listing valid studios; invalid gradation and accounting_method error' do
    studio!(name: 'Only Studio', mini_name: 'only')
    err = mcp_payload(Mcp::GetStudioHealthTool.call(studio: 'nope', server_context: {}))
    assert_includes err['error'], "Unknown studio 'nope'"
    assert_includes err['error'], 'Only Studio'
    err = mcp_payload(Mcp::GetStudioHealthTool.call(gradation: 'weekly', server_context: {}))
    assert_includes err['error'], "Invalid gradation 'weekly'"
    err = mcp_payload(Mcp::GetStudioHealthTool.call(accounting_method: 'both', server_context: {}))
    assert_includes err['error'], "Invalid accounting_method 'both'"
  end

  test 'listing all skips snapshotless studios with a warning; explicit request errors' do
    studio!(name: 'Has Snapshot', mini_name: 'has')
    Studio.create!(name: 'No Snapshot', mini_name: 'none')
    Rails.logger.expects(:warn).with { |msg| msg.include?('No Snapshot') }.at_least_once
    payload = mcp_payload(Mcp::GetStudioHealthTool.call(server_context: {}))
    assert_equal ['Has Snapshot'], payload['studios'].map { |s| s['studio'] }
    err = mcp_payload(Mcp::GetStudioHealthTool.call(studio: 'none', server_context: {}))
    assert_includes err['error'], 'no generated snapshot'
  end

  test 'a studio whose mapping raises is skipped with warn + Sentry, not fatal' do
    studio!(name: 'Raises Mid-Map', mini_name: 'boom')
    Studio.any_instance.stubs(:mini_name).raises(RuntimeError, 'boom')
    Rails.logger.expects(:warn).with { |msg| msg.include?('skipping studio') }.at_least_once
    Sentry.expects(:capture_exception).at_least_once
    payload = mcp_payload(Mcp::GetStudioHealthTool.call(server_context: {}))
    assert_equal [], payload['studios']
  end

  test 'an explicitly requested studio whose snapshot entry is malformed errors instead of returning empty success' do
    s = studio!(name: 'Malformed Studio', mini_name: 'mal')
    # A String entry (instead of a Hash) has no #dig, so `entry.dig(method, ...)` raises
    # NoMethodError while mapping this studio's periods.
    s.update!(snapshot: { 'month' => ['not-a-hash'] })
    Rails.logger.expects(:warn).with { |msg| msg.include?('skipping studio') }.at_least_once
    Sentry.expects(:capture_exception).at_least_once
    err = mcp_payload(Mcp::GetStudioHealthTool.call(studio: 'mal', server_context: {}))
    assert_includes err['error'], "Studio 'Malformed Studio'"
    assert_includes err['error'], "gradation 'month'"
    assert_includes err['error'], 'malformed'
  end
end
