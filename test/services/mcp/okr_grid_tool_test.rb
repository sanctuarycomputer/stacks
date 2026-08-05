require 'test_helper'

class Mcp::OkrGridToolTest < ActiveSupport::TestCase
  # One full OKR (matched OkrPeriod: value/unit + target/tolerance/health/
  # surplus/hint), one bare-datapoint OKR (no target was applicable — the
  # okr_period had a nil value, so health_for_value returned no target), and
  # one synthetic row (Profit — okrs_for_period's derived rows carry
  # value/target/health/surplus/hint but NO tolerance).
  def period_entry(label, margin:)
    {
      'label' => label,
      'period_starts_at' => '06/01/2026',
      'period_ends_at' => '06/30/2026',
      'cash' => {
        'datapoints' => { 'income' => { 'value' => 1000.0, 'unit' => 'usd' } },
        'okrs' => {
          'Profit Margin' => { 'value' => margin, 'unit' => 'percentage', 'target' => 30.0,
                               'tolerance' => 5.0, 'health' => 'at_risk', 'surplus' => -8.0,
                               'hint' => '$700.00 spent, $1,000.00 earnt' },
          'Workplace Satisfaction' => { 'value' => nil, 'unit' => 'count', 'health' => nil,
                                        'surplus' => 0, 'tolerance' => 0.5 },
          'Profit' => { 'value' => 220.0, 'target' => 300.0, 'unit' => 'usd',
                        'health' => 'at_risk', 'surplus' => 220.0, 'hint' => 'derived' },
        },
      },
      'accrual' => {
        'datapoints' => {},
        'okrs' => { 'Profit Margin' => { 'value' => margin + 1, 'unit' => 'percentage' } },
      },
    }
  end

  def studio!(name: 'Sanctuary Test', mini_name: 'sanc', periods: 2)
    Studio.create!(
      name: name, mini_name: mini_name,
      snapshot: { 'month' => (1..periods).map { |i| period_entry("2026-%02d" % i, margin: 20.0 + i) } }
    )
  end

  test 'returns the OKR grid: names union + per-period okr cells passed through verbatim' do
    studio!
    payload = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'sanc', server_context: {}))

    assert_equal 'Sanctuary Test', payload['studio']
    assert_equal 'month', payload['gradation']
    assert_equal 'cash', payload['accounting_method']
    assert_equal ['Profit', 'Profit Margin', 'Workplace Satisfaction'], payload['okr_names'],
      'sorted union of okr names across periods (jsonb does not preserve insertion order)'

    period = payload['periods'].last
    assert_equal '2026-02', period['label']
    assert_equal '06/01/2026', period['period_starts_at']
    assert_equal '06/30/2026', period['period_ends_at']

    full = period['okrs']['Profit Margin']
    assert_equal 22.0, full['value']
    assert_equal 30.0, full['target']
    assert_equal 5.0, full['tolerance']
    assert_equal 'at_risk', full['health']
    assert_equal(-8.0, full['surplus'])
    assert_equal '$700.00 spent, $1,000.00 earnt', full['hint']
  end

  test 'target is optional (nil-value okr rows) and synthetic Profit rows carry no tolerance' do
    studio!
    payload = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'sanc', server_context: {}))
    okrs = payload['periods'].last['okrs']

    bare = okrs['Workplace Satisfaction']
    refute bare.key?('target'), 'target must stay absent when the snapshot omitted it'
    assert_nil bare['value']
    assert_nil bare['health']
    assert_equal 0.5, bare['tolerance']

    synthetic = okrs['Profit']
    assert_equal 300.0, synthetic['target']
    refute synthetic.key?('tolerance'), 'synthetic Profit/Surplus Profit rows have no tolerance'
    assert_equal 'usd', synthetic['unit']
  end

  test 'accrual accounting_method selects the accrual okrs subtree' do
    studio!
    payload = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'sanc', accounting_method: 'accrual', server_context: {}))
    assert_equal ['Profit Margin'], payload['okr_names']
    assert_equal 23.0, payload['periods'].last['okrs']['Profit Margin']['value']
  end

  test 'periods param takes the most recent N' do
    studio!(periods: 10)
    payload = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'sanc', periods: 3, server_context: {}))
    assert_equal %w[2026-08 2026-09 2026-10], payload['periods'].map { |p| p['label'] }
  end

  test 'resolves a studio by mini_name alias and prefers an exact name match with data' do
    studio!(name: 'Alias Holder', mini_name: 'ah, orbit')
    payload = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'orbit', server_context: {}))
    assert_equal 'Alias Holder', payload['studio']
  end

  test 'unknown studio / invalid gradation / invalid accounting_method / no snapshot error clearly' do
    studio!(name: 'Only Studio', mini_name: 'only')
    err = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'nope', server_context: {}))
    assert_includes err['error'], "Unknown studio 'nope'"
    assert_includes err['error'], 'Only Studio'

    err = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'only', gradation: 'weekly', server_context: {}))
    assert_includes err['error'], "Invalid gradation 'weekly'"
    assert_includes err['error'], 'month'

    err = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'only', accounting_method: 'both', server_context: {}))
    assert_includes err['error'], "Invalid accounting_method 'both'"

    Studio.create!(name: 'No Snapshot', mini_name: 'none')
    err = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'none', server_context: {}))
    assert_includes err['error'], 'no generated snapshot'
  end

  test 'a malformed period entry is skipped with warn + Sentry, not fatal' do
    s = studio!
    snap = s.snapshot
    snap['month'] << 'not-a-hash'
    s.update!(snapshot: snap)
    Rails.logger.expects(:warn).with { |msg| msg.include?('skipping period') }.at_least_once
    Sentry.expects(:capture_exception).at_least_once
    payload = mcp_payload(Mcp::GetOkrGridTool.call(studio: 'sanc', server_context: {}))
    assert_equal %w[2026-01 2026-02], payload['periods'].map { |p| p['label'] }
  end
end
