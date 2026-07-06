require 'test_helper'

class Mcp::CapacityToolTest < ActiveSupport::TestCase
  def person!(email:, archived: false)
    ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email,
                           archived: archived, data: {})
  end

  def util!(person:, starts_at:, ends_at:, gradation: 'month', unsold: 0.0,
            sold: 100.0, internal: 0.0, time_off: 0.0, rate: 0.9)
    ForecastPersonUtilizationReport.create!(
      forecast_person: person, starts_at: starts_at, ends_at: ends_at,
      period_gradation: gradation,
      expected_hours_sold: sold, expected_hours_unsold: unsold,
      actual_hours_sold: sold, actual_hours_internal: internal,
      actual_hours_time_off: time_off, actual_hours_sold_by_rate: {}, utilization_rate: rate
    )
  end

  test 'maps report columns to fields and flags benched people' do
    booked = person!(email: 'booked@sanctuary.computer')
    benched = person!(email: 'benched@sanctuary.computer')
    util!(person: booked, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30), unsold: 0.0, sold: 120.0)
    util!(person: benched, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30), unsold: 60.0, sold: 40.0)
    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    assert_equal 'month', payload['gradation']
    assert_equal '2026-06-30', payload['period']['ends_at']
    assert_equal 1, payload['benched_count']
    b = payload['people'].find { |p| p['person'] == 'benched@sanctuary.computer' }
    assert_equal true, b['benched']
    assert_equal 60.0, b['unsold_hours']
    assert_equal 40.0, b['billable_hours']
    bk = payload['people'].find { |p| p['person'] == 'booked@sanctuary.computer' }
    assert_equal false, bk['benched']
    persons = payload['people'].map { |p| p['person'] }
    assert_equal persons.sort, persons, 'people sorted by person'
  end

  test 'excludes archived people' do
    active = person!(email: 'active@sanctuary.computer')
    gone = person!(email: 'gone@sanctuary.computer', archived: true)
    util!(person: active, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30))
    util!(person: gone, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30))
    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    persons = payload['people'].map { |p| p['person'] }
    assert_includes persons, 'active@sanctuary.computer'
    refute_includes persons, 'gone@sanctuary.computer'
  end

  test 'uses the most recent period for the gradation' do
    p = person!(email: 'p@sanctuary.computer')
    util!(person: p, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31), sold: 1.0)
    util!(person: p, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30), sold: 2.0)
    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    assert_equal '2026-06-30', payload['period']['ends_at']
    assert_equal [2.0], payload['people'].map { |x| x['billable_hours'] }
  end

  test 'invalid gradation errors listing valid values' do
    payload = mcp_payload(Mcp::GetCapacityTool.call(gradation: 'weekly', server_context: {}))
    assert_includes payload['error'], "Invalid gradation 'weekly'"
    assert_includes payload['error'], 'trailing_3_months'
  end

  test 'unknown studio errors listing valid studios' do
    Studio.create!(name: 'Only Studio', mini_name: 'only')
    payload = mcp_payload(Mcp::GetCapacityTool.call(studio: 'nope', server_context: {}))
    assert_includes payload['error'], "Unknown studio 'nope'"
    assert_includes payload['error'], 'Only Studio'
  end

  test 'no reports for the period is a valid empty payload with a consistent period shape' do
    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    assert_equal 0, payload['benched_count']
    assert_equal [], payload['people']
    # period keeps the { starts_at, ends_at } shape (both nil) so consumers
    # never hit a nil period on the empty path.
    assert payload.key?('period')
    assert_nil payload['period']['ends_at']
    assert_nil payload['period']['starts_at']
  end
end
