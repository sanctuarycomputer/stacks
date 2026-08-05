require 'test_helper'

class Mcp::CapacityToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Time.zone.parse('2026-07-15 12:00:00')
  end

  def person!(email:, first_name: nil, last_name: nil, archived: false)
    ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email,
                           first_name: first_name, last_name: last_name,
                           archived: archived, data: {})
  end

  def util!(person:, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
            gradation: 'month', sellable: 100.0, unsold: 0.0, by_rate: { '175.0' => 80.0 },
            internal: 10.0, time_off: 8.0)
    ForecastPersonUtilizationReport.create!(
      forecast_person: person, starts_at: starts_at, ends_at: ends_at,
      period_gradation: gradation,
      expected_hours_sold: sellable, expected_hours_unsold: unsold,
      actual_hours_sold: by_rate.values.sum, actual_hours_internal: internal,
      actual_hours_time_off: time_off, actual_hours_sold_by_rate: by_rate,
      utilization_rate: 0.0
    )
  end

  def project!(name: 'Client Work', archived: false)
    @client ||= ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: 'Capacity Client')
    ForecastProject.create!(forecast_id: rand(1..2_000_000_000), name: name, forecast_client: @client,
                            archived: archived, data: {}, tags: ['175p/h'])
  end

  # Placeholder assignments arrive via upsert (no validations): person_id is
  # nil and placeholder_id set. Mirror that by skipping validations here.
  def placeholder_assignment!(project:, start_date:, end_date:, allocation: 14_400, placeholder_id: 999)
    fa = ForecastAssignment.new(forecast_id: rand(1..2_000_000_000), project_id: project.forecast_id,
                                person_id: nil, placeholder_id: placeholder_id,
                                start_date: start_date, end_date: end_date, allocation: allocation)
    fa.save!(validate: false)
    fa
  end

  test 'maps the latest utilization reports to per-person rows with benched_total' do
    ada = person!(email: 'ada@sanctuary.computer', first_name: 'Ada', last_name: 'Lovelace')
    ben = person!(email: 'ben@sanctuary.computer')
    util!(person: ada, sellable: 120.0, unsold: 0.0, by_rate: { '175.0' => 80.0, '150.0' => 20.0 })
    util!(person: ben, sellable: 40.0, unsold: 60.0, by_rate: { '175.0' => 30.0 })

    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))

    assert_equal 'month', payload['gradation']
    assert_equal '2026-06-01', payload['period']['starts_at']
    assert_equal '2026-06-30', payload['period']['ends_at']
    assert_equal %w[ada@sanctuary.computer ben@sanctuary.computer], payload['people'].map { |p| p['email'] }

    ada_row = payload['people'].first
    assert_equal 'Ada Lovelace', ada_row['name']
    assert_equal 120.0, ada_row['sellable']
    assert_equal 0.0, ada_row['benched']
    assert_equal({ '175.0' => 80.0, '150.0' => 20.0 }, ada_row['billable_by_rate'])
    assert_equal 10.0, ada_row['internal']
    assert_equal 8.0, ada_row['time_off']

    ben_row = payload['people'].last
    assert_equal 'ben@sanctuary.computer', ben_row['name'], 'name falls back to email'
    assert_equal 60.0, ben_row['benched']
    assert_equal 60.0, payload['benched_total']
  end

  test 'uses the most recent persisted period for the gradation and excludes archived people' do
    ada = person!(email: 'ada@sanctuary.computer')
    gone = person!(email: 'gone@sanctuary.computer', archived: true)
    util!(person: ada, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31), sellable: 1.0)
    util!(person: ada, sellable: 2.0)
    util!(person: gone)

    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    assert_equal '2026-06-30', payload['period']['ends_at']
    assert_equal ['ada@sanctuary.computer'], payload['people'].map { |p| p['email'] }
    assert_equal [2.0], payload['people'].map { |p| p['sellable'] }
  end

  test 'surfaces unfilled placeholder assignments still open today, skipping past and archived-project ones' do
    ada = person!(email: 'ada@sanctuary.computer')
    util!(person: ada)
    live = project!(name: 'Client Work')
    dead = project!(name: 'Dead Project', archived: true)

    # 3 days x 4h/day = 12 unfilled hours, still open
    placeholder_assignment!(project: live, start_date: Date.new(2026, 7, 20), end_date: Date.new(2026, 7, 22))
    # already ended -> not "unfilled" anymore
    placeholder_assignment!(project: live, start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 5))
    # archived project -> skipped
    placeholder_assignment!(project: dead, start_date: Date.new(2026, 7, 20), end_date: Date.new(2026, 7, 22))
    # a filled (person-backed) assignment is NOT a placeholder
    ForecastAssignment.create!(forecast_id: rand(1..2_000_000_000), forecast_person: ada,
                               forecast_project: live, start_date: Date.new(2026, 7, 20),
                               end_date: Date.new(2026, 7, 22), allocation: 14_400)

    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))

    assert_equal 1, payload['unfilled_placeholders'].length
    ph = payload['unfilled_placeholders'].first
    assert_equal 'Client Work', ph['project']
    assert_equal 12.0, ph['hours']
    assert_equal '2026-07-20', ph['start_date']
    assert_equal '2026-07-22', ph['end_date']
  end

  test 'no persisted reports yields an empty payload with a consistent period shape' do
    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    assert payload.key?('period')
    assert_nil payload['period']['starts_at']
    assert_nil payload['period']['ends_at']
    assert_equal [], payload['people']
    assert_equal 0.0, payload['benched_total']
    assert_equal [], payload['unfilled_placeholders']
  end

  test 'invalid gradation errors listing valid values' do
    err = mcp_payload(Mcp::GetCapacityTool.call(gradation: 'weekly', server_context: {}))
    assert_includes err['error'], "Invalid gradation 'weekly'"
    assert_includes err['error'], 'trailing_3_months'
  end
end
