require 'test_helper'

class Mcp::ExploreOkrToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    # Pin "today" so Stacks::Period.for_gradation(:month) ends at July 2026
    # and the snapshot labels below line up with the live period objects.
    travel_to Time.zone.parse('2026-08-04 12:00:00')
  end

  def month_entry(label, starts_at, ends_at, datapoints: {}, utilization: {})
    {
      'label' => label,
      'period_starts_at' => starts_at,
      'period_ends_at' => ends_at,
      'cash' => { 'datapoints' => datapoints, 'okrs' => {} },
      'accrual' => { 'datapoints' => {}, 'okrs' => {} },
      'utilization' => utilization,
    }
  end

  def studio!(utilization: {})
    july_datapoints = {
      'average_hourly_rate' => { 'value' => 150.0, 'unit' => 'usd' },
      'successful_projects' => { 'value' => 100.0, 'unit' => 'percentage' },
      'successful_proposals' => { 'value' => 100.0, 'unit' => 'percentage' },
      'client_revenue_concentration' => {
        'value' => 35.0, 'unit' => 'percentage',
        'extras' => { 'top_client_name' => 'Big Client', 'top_client_amount' => 3500.0, 'total_revenue' => 10_000.0 },
      },
    }
    Studio.create!(
      name: 'Thoughtbot', mini_name: 'tb', accounting_prefix: 'Development',
      snapshot: {
        'month' => [
          month_entry('May, 2026', '05/01/2026', '05/31/2026'),
          month_entry('June, 2026', '06/01/2026', '06/30/2026'),
          month_entry('July, 2026', '07/01/2026', '07/31/2026',
                      datapoints: july_datapoints, utilization: utilization),
        ],
      }
    )
  end

  def lead_page!(title:, studio_name: 'Thoughtbot', proposal_sent: nil, settled: nil, won: nil)
    properties = { 'Studio' => { 'type' => 'multi_select', 'multi_select' => [{ 'name' => studio_name }] } }
    properties['✨ Proposal Sent'] = { 'type' => 'date', 'date' => { 'start' => proposal_sent } } if proposal_sent
    properties['Settled Date'] = { 'type' => 'formula', 'formula' => { 'string' => settled } } if settled
    properties['✨ Status: Won'] = { 'type' => 'date', 'date' => { 'start' => won } } if won
    NotionPage.create!(
      notion_id: SecureRandom.uuid,
      notion_parent_type: 'database_id',
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]),
      page_title: title,
      data: { 'properties' => properties }
    )
  end

  test 'average_hourly_rate exposes the per-person rate-to-hours utilization map (the one sanctioned place)' do
    studio!(utilization: {
      'ada@thoughtbot.com' => { 'billable' => { '185.0' => 10.0, '0.0' => 2.0 }, 'time_off' => 8.0 },
      'grace@thoughtbot.com' => { 'billable' => { '150.0' => 20.0 } },
      'no-hours@thoughtbot.com' => { 'billable' => 120 }, # legacy non-map shape must not crash
    })
    payload = mcp_payload(Mcp::ExploreOkrTool.call(studio: 'tb', okr: 'average_hourly_rate', server_context: {}))

    assert_equal 'Thoughtbot', payload['studio']
    assert_equal 'average_hourly_rate', payload['okr']
    assert_equal 'month', payload['gradation']
    assert_equal %w[May,\ 2026 June,\ 2026 July,\ 2026], payload['periods'].map { |p| p['label'] }

    july = payload['periods'].last
    assert_equal 150.0, july['value']
    assert_equal 'usd', july['unit']
    rows = july['evidence'].sort_by { |r| [r['person'], r['rate']] }
    assert_equal [
      { 'person' => 'ada@thoughtbot.com', 'rate' => 0.0, 'hours' => 2.0 },
      { 'person' => 'ada@thoughtbot.com', 'rate' => 185.0, 'hours' => 10.0 },
      { 'person' => 'grace@thoughtbot.com', 'rate' => 150.0, 'hours' => 20.0 },
    ], rows
    assert_equal [], payload['periods'].first['evidence'], 'periods with no utilization map have empty evidence'
  end

  test 'successful_projects computes live per-tracker evidence from recorded time in each period' do
    studio = studio!
    fp = ForecastPerson.create!(forecast_id: 88_001, email: 'ada@thoughtbot.com', roles: [studio.name])
    fproject, = make_forecast_project!
    tracker = make_project_tracker!([fproject])
    tracker.update!(snapshot: {
      'hours_total' => 100.0,
      'hours_free' => 0.0,
      'invoiced_with_running_spend_total' => 1000.0,
      'cost_total' => 500.0,
      'last_forecast_assignment_end_date' => '2026-07-20',
    })
    ForecastAssignment.create!(
      forecast_id: 77_001, forecast_person: fp, forecast_project: fproject,
      start_date: Date.new(2026, 7, 6), end_date: Date.new(2026, 7, 10), allocation: 28_800
    )

    payload = mcp_payload(Mcp::ExploreOkrTool.call(studio: 'tb', okr: 'successful_projects', server_context: {}))

    july = payload['periods'].last
    assert_equal 'July, 2026', july['label']
    assert_equal 100.0, july['value']
    assert_equal 1, july['evidence'].length
    row = july['evidence'].first
    assert_equal 'Healthcare.gov Project Tracker', row['tracker']
    assert_equal tracker.external_link, row['url']
    assert_equal 50.0, row['profit_margin'], '(spend - cost) / spend * 100'
    assert_equal 1000.0, row['spend']
    assert_equal 500.0, row['estimated_cost']
    assert_equal 100.0, row['total_hours']
    assert_equal 0.0, row['total_free_hours']
    assert_equal 0.0, row['free_hours_ratio']
    assert_equal false, row['client_satisfied']
    assert_equal true, row['considered_successful']

    assert_equal [], payload['periods'].first['evidence'], 'no recorded time in May means no evidence'
  end

  test 'successful_proposals lists leads settled in each period with proposal outcomes' do
    studio!
    lead_page!(title: 'Won Lead', proposal_sent: '2026-06-20', settled: '2026-07-15', won: '2026-07-15')
    lead_page!(title: 'Lost Lead', proposal_sent: '2026-05-05', settled: '2026-06-10')
    lead_page!(title: 'Other Studio Lead', studio_name: 'Elsewhere', proposal_sent: '2026-06-20', settled: '2026-07-15', won: '2026-07-15')
    lead_page!(title: 'Never Proposed', settled: '2026-07-02')

    payload = mcp_payload(Mcp::ExploreOkrTool.call(studio: 'tb', okr: 'successful_proposals', server_context: {}))

    july = payload['periods'].last
    assert_equal 1, july['evidence'].length
    row = july['evidence'].first
    assert_equal 'Won Lead', row['lead']
    assert_match %r{\Ahttps://www.notion.so/garden3d/}, row['url']
    assert_equal '2026-06-20', row['proposal_sent_at']
    assert_equal '2026-07-15', row['settled_at']
    assert_equal '2026-07-15', row['won_at']
    assert_equal true, row['considered_successful']

    june = payload['periods'][1]
    assert_equal ['Lost Lead'], june['evidence'].map { |r| r['lead'] }
    assert_equal false, june['evidence'].first['considered_successful']
    assert_nil june['evidence'].first['won_at']
  end

  test 'the generic client KPIs return the datapoint and its extras verbatim' do
    studio!
    payload = mcp_payload(Mcp::ExploreOkrTool.call(studio: 'tb', okr: 'client_revenue_concentration', server_context: {}))
    july = payload['periods'].last
    assert_equal 35.0, july['value']
    assert_equal 'percentage', july['unit']
    assert_equal [
      { 'top_client_name' => 'Big Client', 'top_client_amount' => 3500.0, 'total_revenue' => 10_000.0 },
    ], july['evidence']
    assert_equal [], payload['periods'].first['evidence'], 'no datapoint means no extras'
  end

  test 'periods clamps to at most 6 (live evidence is heavy) and snapshotless labels return nil values' do
    studio!
    payload = mcp_payload(Mcp::ExploreOkrTool.call(studio: 'tb', okr: 'average_hourly_rate', periods: 99, server_context: {}))
    assert_equal 6, payload['periods'].length
    feb = payload['periods'].first
    assert_equal 'February, 2026', feb['label']
    assert_nil feb['value'], 'a period with no snapshot entry still appears, with nil value'
  end

  test 'invalid okr / unknown studio / invalid gradation error listing valid values' do
    studio!
    err = mcp_payload(Mcp::ExploreOkrTool.call(studio: 'tb', okr: 'profit_margin', server_context: {}))
    assert_includes err['error'], "Invalid okr 'profit_margin'"
    assert_includes err['error'], 'average_hourly_rate'
    assert_includes err['error'], 'forecasted_sales_revenue'

    err = mcp_payload(Mcp::ExploreOkrTool.call(studio: 'nope', okr: 'average_hourly_rate', server_context: {}))
    assert_includes err['error'], "Unknown studio 'nope'"

    err = mcp_payload(Mcp::ExploreOkrTool.call(studio: 'tb', okr: 'average_hourly_rate', gradation: 'weekly', server_context: {}))
    assert_includes err['error'], "Invalid gradation 'weekly'"

    err = mcp_payload(Mcp::ExploreOkrTool.call(studio: 'tb', okr: 'average_hourly_rate', accounting_method: 'both', server_context: {}))
    assert_includes err['error'], "Invalid accounting_method 'both'"
  end
end
