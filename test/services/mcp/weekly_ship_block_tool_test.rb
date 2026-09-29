require 'test_helper'

class Mcp::WeeklyShipBlockToolTest < ActiveSupport::TestCase
  SNAPSHOT = { 'generated_at' => '2026-09-21T06:00:00+00:00', 'spend' => [], 'cost' => [], 'hours' => [],
               'hours_total' => 0.0, 'spend_total' => 0.0, 'invoiced_income_total' => 1000.0,
               'invoiced_with_running_spend_total' => 1500.0 }.freeze

  def tracker!(name:, client:, snapshot: SNAPSHOT, **attrs)
    fc = ForecastClient.find_by(name: client) ||
         ForecastClient.create!(forecast_id: rand(1_000_000..9_999_999), name: client, archived: false, updated_at: Time.current)
    fp = ForecastProject.create!(forecast_id: rand(1_000_000..9_999_999), name: name, code: name.upcase.gsub(/[^A-Z]/, '')[0, 6],
                                 client_id: fc.forecast_id, archived: false, tags: [], updated_at: Time.current)
    pt = ProjectTracker.new({ name: name }.merge(attrs))
    pt.save!(validate: false)
    pt.update_column(:snapshot, snapshot) if snapshot
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project_id: fp.forecast_id)
    ProjectTracker.find(pt.id)
  end

  def make_ship(tracker, sent_at:, title:)
    doc = Document.create!(source: :google_groups, external_id: "<#{SecureRandom.hex(6)}@m>", title: title,
                           occurred_at: Time.zone.now,
                           raw_metadata: { 'group_email' => 'ships@sanctuary.computer', 'gmail_message_ids' => [] })
    ship = WeeklyShip.new(document: doc, project_tracker: tracker, sent_at: sent_at, matched_by: :llm, sent_by_name: 'Sam')
    ship.via_sweep = true
    ship.save!
    ship
  end

  setup do
    ProjectTracker.any_instance.stubs(:hours_trailing_7_days).returns(4.0)
    ProjectTracker.any_instance.stubs(:trailing_7_days_value).returns(500.0)
  end

  test 'by trackers: one summed block, weeks_left, ongoing flag, per-tracker budget flags, newest ship' do
    a = tracker!(name: 'Combo Design', client: 'Combo Co', budget_low_end: 10_000, budget_high_end: 12_000)
    b = tracker!(name: 'Combo Dev (ongoing)', client: 'Combo Co', budget_low_end: 20_000, budget_high_end: 20_000)
    make_ship(a, sent_at: 9.days.ago, title: 'Older')
    newest = make_ship(b, sent_at: 2.days.ago, title: 'Newest')

    p = mcp_payload(Mcp::GetWeeklyShipBlockTool.call(trackers: [a.id.to_s, 'combo dev (ongoing)'], server_context: {}))

    assert_equal [a.id, b.id], p['trackers'].map { |t| t['id'] }
    assert_equal [true, true], p['trackers'].map { |t| t['has_budget'] }
    assert_equal 8.0, p['combined']['hours_7d']
    assert_equal 2000.0, p['combined']['invoiced']
    assert_equal 3000.0, p['combined']['total_spend']
    assert_equal({ 'low' => 30_000.0, 'high' => 32_000.0 }, p['combined']['budget'])
    assert_equal false, p['budget_dropped']
    assert_includes p['weekly_ship_block'], "Trailing 7 days: 8.0 hours ($1,000.00)"
    assert_includes p['weekly_ship_block'], "Total Spend to Date: $3,000.00\nBudget Low End: $30,000.00\nBudget High End: $32,000.00"
    assert_equal 27.0, p['weeks_left']
    assert_equal true, p['considered_ongoing']
    assert_equal newest.id, p['last_weekly_ship']['id']
    assert_nil p['combined']['profit']
  end

  test 'a mixed engagement drops the band and says so' do
    a = tracker!(name: 'Mixed Banded', client: 'Mixed Co', budget_low_end: 10_000, budget_high_end: 12_000)
    b = tracker!(name: 'Mixed Retainer', client: 'Mixed Co')

    p = mcp_payload(Mcp::GetWeeklyShipBlockTool.call(trackers: [a.id.to_s, b.id.to_s], server_context: {}))
    assert_equal({ 'low' => nil, 'high' => nil }, p['combined']['budget'])
    assert_equal true, p['budget_dropped']
    assert_equal [true, false], p['trackers'].map { |t| t['has_budget'] }
    assert_not_includes p['weekly_ship_block'], 'Total Spend to Date'
    assert_nil p['weeks_left']
  end

  test 'by client: every open tracker whose ANY forecast project belongs to the client; completed excluded' do
    tracker!(name: 'Acme Design', client: 'Acme', budget_low_end: 1000, budget_high_end: 1000)
    tracker!(name: 'Acme Dev', client: 'Acme', budget_low_end: 2000, budget_high_end: 2000)
    tracker!(name: 'Acme Old', client: 'Acme', budget_low_end: 9000, budget_high_end: 9000, work_completed_at: 1.year.ago)

    p = mcp_payload(Mcp::GetWeeklyShipBlockTool.call(client: 'acme', server_context: {}))
    assert_equal ['Acme Design', 'Acme Dev'], p['trackers'].map { |t| t['name'] }.sort
    assert_includes p['weekly_ship_block'], "Budget: $3,000.00"
  end

  test 'refuses an engagement with an unsnapshotted tracker rather than printing $0' do
    a = tracker!(name: 'Snap Ok', client: 'Snap Co', budget_low_end: 1000, budget_high_end: 1000)
    b = tracker!(name: 'Snap Missing', client: 'Snap Co', snapshot: nil, budget_low_end: 1000, budget_high_end: 1000)

    err = mcp_payload(Mcp::GetWeeklyShipBlockTool.call(trackers: [a.id.to_s, b.id.to_s], server_context: {}))['error']
    assert_match(/Snap Missing.*no generated snapshot/, err)
  end

  test 'errors: unknown tracker, unknown client, neither argument' do
    assert_match(/Unknown tracker/, mcp_payload(Mcp::GetWeeklyShipBlockTool.call(trackers: ['nope'], server_context: {}))['error'])
    assert_match(/No open tracker/, mcp_payload(Mcp::GetWeeklyShipBlockTool.call(client: 'Nobody Inc', server_context: {}))['error'])
    assert_match(/Pass trackers/, mcp_payload(Mcp::GetWeeklyShipBlockTool.call(server_context: {}))['error'])
  end
end
