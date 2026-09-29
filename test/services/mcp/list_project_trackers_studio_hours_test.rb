require 'test_helper'

# hours_by_studio_90d (opt-in): scheduled Forecast hours per studio over the last 90 days, for the daily
# entity-registry build that derives each project's studio (stacksbot lib/studio.mjs).
class Mcp::ListProjectTrackersStudioHoursTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup { travel_to Time.zone.parse('2026-09-29 12:00:00') }

  def payload(resp) = JSON.parse(resp.content.first[:text])

  test 'per tracker: hours by studio over the last 90 days, only when asked, in one pass over all trackers' do
    xxix = Studio.create!(name: 'XXIX', accounting_prefix: 'Design', mini_name: 'xxix', snapshot: {})
    sanc = Studio.create!(name: 'Sanctuary Computer', accounting_prefix: 'Development', mini_name: 'sanctu', snapshot: {})
    ada = make_admin_user!(xxix, Date.new(2026, 1, 1), nil, 'ada@example.com')
    bo = make_admin_user!(sanc, Date.new(2026, 1, 1), nil, 'bo@example.com')

    fp1, = make_forecast_project!('Client One', 'Site')
    fp2, = make_forecast_project!('Client Two', 'App')
    t1 = make_project_tracker!([fp1])
    t2 = make_project_tracker!([fp2])

    # t1: ada 2 days x 8h (XXIX), bo 1 day x 8h (Sanctuary); plus an assignment long before the window.
    ForecastAssignment.create!(forecast_id: 91_001, forecast_person: ada.forecast_person, forecast_project: fp1, start_date: Date.new(2026, 9, 21), end_date: Date.new(2026, 9, 22), allocation: 28_800)
    ForecastAssignment.create!(forecast_id: 91_002, forecast_person: bo.forecast_person, forecast_project: fp1, start_date: Date.new(2026, 9, 23), end_date: Date.new(2026, 9, 23), allocation: 28_800)
    ForecastAssignment.create!(forecast_id: 91_003, forecast_person: bo.forecast_person, forecast_project: fp1, start_date: Date.new(2026, 1, 5), end_date: Date.new(2026, 1, 9), allocation: 28_800)
    # t2: bo only.
    ForecastAssignment.create!(forecast_id: 91_004, forecast_person: bo.forecast_person, forecast_project: fp2, start_date: Date.new(2026, 9, 24), end_date: Date.new(2026, 9, 24), allocation: 28_800)

    rows = payload(Mcp::ListProjectTrackersTool.call(include_hours_by_studio: true, server_context: {}))
    by_id = rows.index_by { |r| r['id'] }
    assert_equal({ 'XXIX' => 16.0, 'Sanctuary Computer' => 8.0 }, by_id[t1.id]['hours_by_studio_90d'])
    assert_equal({ 'Sanctuary Computer' => 8.0 }, by_id[t2.id]['hours_by_studio_90d'])

    plain = payload(Mcp::ListProjectTrackersTool.call(server_context: {}))
    assert plain.none? { |r| r.key?('hours_by_studio_90d') }, 'not computed unless asked'
  end

  test 'a tracker with no assignments in the window reads as an empty hash, not an error' do
    studio, = make_studio!
    fp, = make_forecast_project!
    t = make_project_tracker!([fp])
    rows = payload(Mcp::ListProjectTrackersTool.call(include_hours_by_studio: true, server_context: {}))
    assert_equal({}, rows.find { |r| r['id'] == t.id }['hours_by_studio_90d'])
  end
end
