require 'test_helper'

# The weekly-ship inputs over MCP: get_project_burnup's new fields,
# list_weekly_ships, the serializer's links, and update_project_tracker's
# monthly budget + link params.
class Mcp::WeeklyShipToolsTest < ActiveSupport::TestCase
  SNAPSHOT = {
    'generated_at' => '2026-09-21T06:00:00+00:00',
    'spend' => [{ 'x' => '2026-09-01', 'y' => 1000.0 }],
    'cost' => [], 'hours' => [],
    'hours_total' => 10.0, 'hours_free' => 0.0, 'spend_total' => 1000.0, 'cost_total' => 500.0,
    'invoiced_income_total' => 600.0,
    'invoiced_with_running_spend_total' => 1000.0,
    'first_forecast_assignment_start_date' => '2026-09-01',
    'last_forecast_assignment_end_date' => '2026-09-20',
  }.freeze

  def payload(resp)
    JSON.parse(resp.content.first[:text])
  end

  def tracker!(name: 'Ship Tool Tracker', **attrs)
    pt = ProjectTracker.new({ name: name }.merge(attrs))
    pt.save!(validate: false)
    pt.update_column(:snapshot, SNAPSHOT)
    ProjectTracker.find(pt.id)
  end

  def make_doc(title:, message_id: "<#{SecureRandom.hex(6)}@m>")
    Document.create!(source: :google_groups, external_id: message_id, title: title,
                     occurred_at: Time.zone.now,
                     raw_metadata: { 'group_email' => 'ships@sanctuary.computer',
                                     'gmail_message_ids' => [message_id.delete('<>')] })
  end

  def make_ship(tracker, sent_at:, title:, sender: 'Norm')
    ship = WeeklyShip.new(document: make_doc(title: title), project_tracker: tracker,
                          sent_at: sent_at, matched_by: :llm, sent_by_name: sender, confidence: 0.9)
    ship.via_sweep = true
    ship.save!
    ship
  end

  # ---- get_project_burnup ------------------------------------------------

  test 'burnup carries the monthly budget, hours_7d, the ongoing flag, the block, and the last ship' do
    tracker = tracker!(name: 'Retainer (ongoing)', monthly_budget_low_end: 6000, monthly_budget_high_end: 6000)
    ProjectTracker.any_instance.stubs(:hours_trailing_7_days).returns(12.5)
    ProjectTracker.any_instance.stubs(:make_adhoc_snapshot).returns({ hours_total: 12.5, spend_total: 1875.0 })
    make_ship(tracker, sent_at: 10.days.ago, title: 'Older ship')
    newest = make_ship(tracker, sent_at: 2.days.ago, title: 'Weekly Ship: Sep 19')

    p = payload(Mcp::GetProjectBurnupTool.call(tracker: tracker.id.to_s, server_context: {}))

    assert_equal({ 'low' => 6000.0, 'high' => 6000.0 }, p['monthly_budget'])
    assert_equal({ 'low' => nil, 'high' => nil }, p['budget'])
    assert_equal true, p['considered_ongoing']
    assert_equal 12.5, p['hours_7d']
    assert_equal 'no_budget', p['status']

    block = p['weekly_ship_block']
    assert_includes block, "Trailing 7 days: 12.5 hours ($1,875.00)"
    assert_includes block, "Invoiced: $600.00\nSpend this Month: $400.00\nMonthly Budget: $6,000.00"
    assert_not_includes block, 'Total Spend to Date'

    last = p['last_weekly_ship']
    assert_equal newest.id, last['id']
    assert_equal newest.document_id, last['document_id']
    assert_equal 'Weekly Ship: Sep 19', last['subject']
    assert_equal 'Norm', last['sent_by']
    assert_equal 'llm', last['matched_by']
  end

  test 'burnup for a banded tracker prints total spend to date in the block and no last ship when none' do
    tracker = tracker!(name: 'Banded', budget_low_end: 2000, budget_high_end: 2500)
    ProjectTracker.any_instance.stubs(:make_adhoc_snapshot).returns({ hours_total: 4, spend_total: 600.0 })

    p = payload(Mcp::GetProjectBurnupTool.call(tracker: tracker.id.to_s, server_context: {}))

    assert_equal false, p['considered_ongoing']
    assert_includes p['weekly_ship_block'], "Total Spend to Date: $1,000.00\nBudget Low End: $2,000.00\nBudget High End: $2,500.00"
    assert_nil p['last_weekly_ship']
  end

  # ---- list_weekly_ships ---------------------------------------------------

  test 'list_weekly_ships returns ships newest first with document ids, capped by limit' do
    tracker = tracker!
    make_ship(tracker, sent_at: 21.days.ago, title: 'Ship 1')
    two = make_ship(tracker, sent_at: 14.days.ago, title: 'Ship 2')
    three = make_ship(tracker, sent_at: 7.days.ago, title: 'Ship 3')

    p = payload(Mcp::ListWeeklyShipsTool.call(tracker: 'ship tool tracker', limit: 2, server_context: {}))

    assert_equal tracker.id, p['id']
    assert_equal ['Ship 3', 'Ship 2'], p['ships'].map { |s| s['subject'] }
    assert_equal [three.document_id, two.document_id], p['ships'].map { |s| s['document_id'] }
    assert p['ships'].all? { |s| s['url'].to_s.start_with?('https://groups.google.com/') }, p['ships'].inspect
  end

  test 'list_weekly_ships errors on an unknown tracker and is empty for a tracker with no ships' do
    err = payload(Mcp::ListWeeklyShipsTool.call(tracker: 'nope', server_context: {}))
    assert_match(/Unknown tracker/, err['error'])

    tracker = tracker!(name: 'Quiet')
    p = payload(Mcp::ListWeeklyShipsTool.call(tracker: tracker.id.to_s, server_context: {}))
    assert_equal [], p['ships']
  end

  test 'list_weekly_ships is registered on the read server' do
    assert_includes Mcp::Server::TOOLS, Mcp::ListWeeklyShipsTool
  end

  # ---- serializer + update tool ------------------------------------------

  test 'list_project_trackers emits every link, the monthly budget, and the ongoing flag' do
    tracker = tracker!(name: 'Linked (retainer)', monthly_budget_low_end: 5000, monthly_budget_high_end: 8000)
    tracker.project_tracker_links.create!(name: 'MSA', url: 'https://x/msa', link_type: :msa)
    tracker.project_tracker_links.create!(name: 'Twist', url: 'https://twist.com/a/1/ch/2', link_type: :twist_channel)

    row = payload(Mcp::ListProjectTrackersTool.call(name: 'Linked (retainer)', server_context: {})).first

    assert_equal 5000.0, row['monthly_budget_low_end']
    assert_equal 8000.0, row['monthly_budget_high_end']
    assert_equal true, row['considered_ongoing']
    assert_equal 'https://x/msa', row['msa_url']
    assert_equal [%w[MSA https://x/msa msa], ['Twist', 'https://twist.com/a/1/ch/2', 'twist_channel']],
                 row['links'].map { |l| [l['name'], l['url'], l['link_type']] }
  end

  test 'update_project_tracker sets a fixed monthly budget from one end and the new links' do
    tracker = tracker!(name: 'Updatable')
    tracker.project_tracker_links.create!(name: 'MSA', url: 'https://x/msa', link_type: :msa)
    tracker.project_tracker_links.create!(name: 'SOW', url: 'https://x/sow', link_type: :sow)

    resp = Mcp::UpdateProjectTrackerTool.call(
      project_tracker_id: tracker.id, monthly_budget_low_end: 7000,
      twist_channel_url: 'https://twist.com/a/1/ch/9', notion_homepage_url: 'https://app.notion.com/p/h',
      server_context: {}
    )
    after = payload(resp)['after']

    assert_equal 7000.0, after['monthly_budget_low_end']
    assert_equal 7000.0, after['monthly_budget_high_end']
    types = after['links'].map { |l| l['link_type'] }
    assert_includes types, 'twist_channel'
    assert_includes types, 'notion_homepage'
    assert_equal 'https://twist.com/a/1/ch/9', after['links'].find { |l| l['link_type'] == 'twist_channel' }['url']
  end

  test 'update_project_tracker rejects a monthly low end above the high end' do
    tracker = tracker!(name: 'Backwards')
    tracker.project_tracker_links.create!(name: 'MSA', url: 'https://x/msa', link_type: :msa)
    tracker.project_tracker_links.create!(name: 'SOW', url: 'https://x/sow', link_type: :sow)

    resp = Mcp::UpdateProjectTrackerTool.call(
      project_tracker_id: tracker.id, monthly_budget_low_end: 9000, monthly_budget_high_end: 8000, server_context: {}
    )
    assert_match(/Monthly budget low end/i, payload(resp)['error'])
    assert_nil tracker.reload.monthly_budget_low_end
  end
end
