require 'test_helper'

class Mcp::ProjectContributorsToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Time.zone.parse('2026-08-04 12:00:00')
  end

  test 'lists contributors with role periods and the per-workstream hours/rate/spend table' do
    studio, = make_studio!
    ada = make_admin_user!(studio, Date.new(2026, 1, 1), nil, 'ada@thoughtbot.com')
    lead = make_admin_user!(studio, Date.new(2026, 1, 1), nil, 'lead@thoughtbot.com')

    fproject, = make_forecast_project!
    fproject.update!(tags: ['150p/h'], data: {})
    tracker = make_project_tracker!([fproject])

    # ada records time: 8h on Jul 10 (inside trailing 30d), then 8h/day
    # Jul 30 - Aug 2 (4 days, inside trailing 7d), plus 16h back in June.
    ForecastAssignment.create!(
      forecast_id: 79_001, forecast_person: ada.forecast_person, forecast_project: fproject,
      start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 2), allocation: 28_800
    )
    ForecastAssignment.create!(
      forecast_id: 79_002, forecast_person: ada.forecast_person, forecast_project: fproject,
      start_date: Date.new(2026, 7, 10), end_date: Date.new(2026, 7, 10), allocation: 28_800
    )
    ForecastAssignment.create!(
      forecast_id: 79_003, forecast_person: ada.forecast_person, forecast_project: fproject,
      start_date: Date.new(2026, 7, 30), end_date: Date.new(2026, 8, 2), allocation: 28_800
    )

    AccountLeadPeriod.create!(
      project_tracker: tracker, admin_user: lead,
      started_at: Date.new(2026, 1, 1), ended_at: Date.new(2026, 6, 30)
    )
    ProjectLeadPeriod.create!(
      project_tracker: tracker, admin_user: ada,
      started_at: Date.new(2026, 7, 1), ended_at: nil
    )

    payload = mcp_payload(Mcp::GetProjectContributorsTool.call(tracker: tracker.id.to_s, server_context: {}))

    assert_equal 'Healthcare.gov Project Tracker', payload['tracker']
    assert_equal tracker.id, payload['id']
    assert_equal tracker.external_link, payload['url']

    assert_equal %w[ada@thoughtbot.com lead@thoughtbot.com], payload['contributors'].map { |c| c['email'] }
    ada_row = payload['contributors'].first
    assert_equal 'ada@thoughtbot.com', ada_row['name']
    assert_equal [
      { 'role' => 'contributor', 'started_at' => nil, 'ended_at' => nil },
      { 'role' => 'project_lead', 'started_at' => '2026-07-01', 'ended_at' => nil },
    ], ada_row['roles'].sort_by { |r| r['role'] }
    lead_row = payload['contributors'].last
    assert_equal [
      { 'role' => 'account_lead', 'started_at' => '2026-01-01', 'ended_at' => '2026-06-30' },
    ], lead_row['roles'], 'a lead who never recorded time appears with only the lead role'

    assert_equal 1, payload['workstreams'].length
    ws = payload['workstreams'].first
    assert_equal fproject.display_name, ws['name']
    assert_equal 150.0, ws['rate']
    assert_equal 32.0, ws['hours_7d'], 'trailing 7 days covers Jul 29 - Aug 4'
    assert_equal 40.0, ws['hours_30d'], 'trailing 30 days covers Jul 6 - Aug 4'
    assert_equal 56.0, ws['hours_total']
    assert_equal 8400.0, ws['spend_total'], 'total hours x hourly rate, as the admin table computes it'
  end

  test 'unknown tracker returns an error pointing at list_project_trackers' do
    err = mcp_payload(Mcp::GetProjectContributorsTool.call(tracker: 'nope', server_context: {}))
    assert_includes err['error'], "Unknown tracker 'nope'"
    assert_includes err['error'], 'list_project_trackers'
  end
end
