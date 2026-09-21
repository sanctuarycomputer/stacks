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

  def tracker!(name: 'Ship Tool Tracker', **attrs)
    pt = ProjectTracker.new({ name: name }.merge(attrs))
    pt.save!(validate: false)
    pt.update_column(:snapshot, SNAPSHOT)
    ProjectTracker.find(pt.id)
  end

  def with_links!(pt)
    pt.project_tracker_links.create!(name: 'MSA', url: 'https://x/msa', link_type: :msa)
    pt.project_tracker_links.create!(name: 'SOW', url: 'https://x/sow', link_type: :sow)
    pt
  end

  def make_doc(title:, message_id: "<#{SecureRandom.hex(6)}@m>", excluded: :not_excluded)
    Document.create!(source: :google_groups, external_id: message_id, title: title,
                     occurred_at: Time.zone.now, excluded: excluded,
                     raw_metadata: { 'group_email' => 'ships@sanctuary.computer',
                                     'gmail_message_ids' => [message_id.delete('<>')] })
  end

  def make_ship(tracker, sent_at:, title:, sender: 'Norm', excluded: :not_excluded)
    ship = WeeklyShip.new(document: make_doc(title: title, excluded: excluded), project_tracker: tracker,
                          sent_at: sent_at, matched_by: :llm, sent_by_name: sender, confidence: 0.9)
    ship.via_sweep = true
    ship.save!
    ship
  end

  # ---- get_project_burnup ------------------------------------------------

  test 'burnup carries the monthly budget, hours_7d, the ongoing flag, the block, and the last ship' do
    tracker = tracker!(name: 'Retainer (ongoing)', monthly_budget_low_end: 6000, monthly_budget_high_end: 6000)
    ProjectTracker.any_instance.stubs(:hours_trailing_7_days).returns(12.5)
    ProjectTracker.any_instance.stubs(:trailing_7_days_value).returns(1875.0)
    make_ship(tracker, sent_at: 10.days.ago, title: 'Older ship')
    newest = make_ship(tracker, sent_at: 2.days.ago, title: 'Weekly Ship: Sep 19')

    p = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: tracker.id.to_s, server_context: {}))

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
    ProjectTracker.any_instance.stubs(:hours_trailing_7_days).returns(4.0)
    ProjectTracker.any_instance.stubs(:trailing_7_days_value).returns(600.0)

    p = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: tracker.id.to_s, server_context: {}))

    assert_equal false, p['considered_ongoing']
    assert_includes p['weekly_ship_block'], "Total Spend to Date: $1,000.00\nBudget Low End: $2,000.00\nBudget High End: $2,500.00"
    assert_nil p['last_weekly_ship']
  end

  test "burnup's last_weekly_ship skips a ship whose document was excluded from the corpus" do
    tracker = tracker!
    older = make_ship(tracker, sent_at: 10.days.ago, title: 'Older, still public')
    make_ship(tracker, sent_at: 2.days.ago, title: 'Newest but walled', excluded: :manually_excluded)

    p = mcp_payload(Mcp::GetProjectBurnupTool.call(tracker: tracker.id.to_s, server_context: {}))
    assert_equal older.id, p['last_weekly_ship']['id']
  end

  # ---- list_weekly_ships ---------------------------------------------------

  test 'list_weekly_ships returns ships newest first with document ids, capped by limit' do
    tracker = tracker!
    make_ship(tracker, sent_at: 21.days.ago, title: 'Ship 1')
    two = make_ship(tracker, sent_at: 14.days.ago, title: 'Ship 2')
    three = make_ship(tracker, sent_at: 7.days.ago, title: 'Ship 3')

    p = mcp_payload(Mcp::ListWeeklyShipsTool.call(tracker: 'ship tool tracker', limit: 2, server_context: {}))

    assert_equal tracker.id, p['id']
    assert_equal ['Ship 3', 'Ship 2'], p['ships'].map { |s| s['subject'] }
    assert_equal [three.document_id, two.document_id], p['ships'].map { |s| s['document_id'] }
    assert p['ships'].all? { |s| s['url'].to_s.start_with?('https://groups.google.com/') }, p['ships'].inspect
  end

  test 'list_weekly_ships omits ships whose document was excluded from the corpus' do
    tracker = tracker!
    make_ship(tracker, sent_at: 7.days.ago, title: 'Public')
    make_ship(tracker, sent_at: 2.days.ago, title: 'Walled', excluded: :manually_excluded)

    p = mcp_payload(Mcp::ListWeeklyShipsTool.call(tracker: tracker.id.to_s, server_context: {}))
    assert_equal ['Public'], p['ships'].map { |s| s['subject'] }
  end

  test 'list_weekly_ships clamps limit: nil and 0 fall back sanely, huge values are capped' do
    tracker = tracker!
    7.times { |i| make_ship(tracker, sent_at: (i + 1).days.ago, title: "Ship #{i}") }

    assert_equal 5, mcp_payload(Mcp::ListWeeklyShipsTool.call(tracker: tracker.id.to_s, limit: nil, server_context: {}))['ships'].size
    assert_equal 1, mcp_payload(Mcp::ListWeeklyShipsTool.call(tracker: tracker.id.to_s, limit: 0, server_context: {}))['ships'].size
    assert_equal 7, mcp_payload(Mcp::ListWeeklyShipsTool.call(tracker: tracker.id.to_s, limit: 500, server_context: {}))['ships'].size
  end

  test 'list_weekly_ships errors on an unknown tracker and is empty for a tracker with no ships' do
    err = mcp_payload(Mcp::ListWeeklyShipsTool.call(tracker: 'nope', server_context: {}))
    assert_match(/Unknown tracker/, err['error'])

    tracker = tracker!(name: 'Quiet')
    p = mcp_payload(Mcp::ListWeeklyShipsTool.call(tracker: tracker.id.to_s, server_context: {}))
    assert_equal [], p['ships']
  end

  # ---- serializer + update tool ------------------------------------------

  test 'list_project_trackers emits every link, the monthly budget, and the ongoing flag' do
    tracker = tracker!(name: 'Linked (retainer)', monthly_budget_low_end: 5000, monthly_budget_high_end: 8000)
    tracker.project_tracker_links.create!(name: 'MSA', url: 'https://x/msa', link_type: :msa)
    tracker.project_tracker_links.create!(name: 'Twist', url: 'https://twist.com/a/1/ch/2', link_type: :twist_channel)
    # A legacy row with embedded credentials (the validation now rejects these on write).
    legacy = tracker.project_tracker_links.build(name: 'Staging', url: 'https://user:secret@staging.example.com/x', link_type: :staging_link)
    legacy.save!(validate: false)

    row = mcp_payload(Mcp::ListProjectTrackersTool.call(name: 'Linked (retainer)', server_context: {})).first

    assert_equal 5000.0, row['monthly_budget_low_end']
    assert_equal 8000.0, row['monthly_budget_high_end']
    assert_equal true, row['considered_ongoing']
    assert_equal 'https://x/msa', row['msa_url']
    assert_equal [%w[MSA https://x/msa msa],
                  ['Twist', 'https://twist.com/a/1/ch/2', 'twist_channel'],
                  ['Staging', 'https://staging.example.com/x', 'staging_link']],
                 row['links'].map { |l| [l['name'], l['url'], l['link_type']] }
    assert_no_match(/secret/, row.to_json)
  end

  test 'update_project_tracker sets a fixed monthly budget from one end and the new links' do
    tracker = with_links!(tracker!(name: 'Updatable'))

    after = mcp_payload(Mcp::UpdateProjectTrackerTool.call(
      project_tracker_id: tracker.id, monthly_budget_low_end: 7000,
      twist_channel_url: 'https://twist.com/a/1/ch/9', notion_homepage_url: 'https://app.notion.com/p/h',
      server_context: {}
    ))['after']

    assert_equal 7000.0, after['monthly_budget_low_end']
    assert_equal 7000.0, after['monthly_budget_high_end']
    types = after['links'].map { |l| l['link_type'] }
    assert_includes types, 'twist_channel'
    assert_includes types, 'notion_homepage'
    assert_equal 'https://twist.com/a/1/ch/9', after['links'].find { |l| l['link_type'] == 'twist_channel' }['url']
  end

  test 'update_project_tracker replaces an existing range with one end, and clears on request' do
    tracker = with_links!(tracker!(name: 'Rebudget', monthly_budget_low_end: 5000, monthly_budget_high_end: 8000))

    after = mcp_payload(Mcp::UpdateProjectTrackerTool.call(
      project_tracker_id: tracker.id, monthly_budget_high_end: 9000, server_context: {}
    ))['after']
    assert_equal [9000.0, 9000.0], [after['monthly_budget_low_end'], after['monthly_budget_high_end']]

    after = mcp_payload(Mcp::UpdateProjectTrackerTool.call(
      project_tracker_id: tracker.id, clear_monthly_budget: true, server_context: {}
    ))['after']
    assert_nil after['monthly_budget_low_end']
    assert_nil after['monthly_budget_high_end']
  end

  test 'update_project_tracker rejects a monthly low end above the high end and a non-positive budget' do
    tracker = with_links!(tracker!(name: 'Backwards'))

    resp = Mcp::UpdateProjectTrackerTool.call(
      project_tracker_id: tracker.id, monthly_budget_low_end: 9000, monthly_budget_high_end: 8000, server_context: {}
    )
    assert_match(/Monthly budget low end/i, mcp_payload(resp)['error'])
    assert_nil tracker.reload.monthly_budget_low_end

    resp = Mcp::UpdateProjectTrackerTool.call(project_tracker_id: tracker.id, monthly_budget_low_end: 0, server_context: {})
    assert_match(/greater than 0/i, mcp_payload(resp)['error'])
  end

  test 'update_project_tracker rejects a non-http link URL and leaves the links untouched' do
    tracker = with_links!(tracker!(name: 'Linky'))

    resp = Mcp::UpdateProjectTrackerTool.call(
      project_tracker_id: tracker.id, twist_channel_url: 'javascript:alert(1)//https://x', server_context: {}
    )
    assert_match(/http or https URL/i, mcp_payload(resp)['error'])
    assert_equal %w[msa sow], tracker.reload.project_tracker_links.map(&:link_type).sort
  end
end
