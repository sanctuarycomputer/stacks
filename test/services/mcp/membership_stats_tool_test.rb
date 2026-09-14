require 'test_helper'

class Mcp::MembershipStatsToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    # Tuesday. week_end_wday defaults to Sunday (0), so the most recent
    # week-end marker is 2026-08-09 and week ends step back 7 days at a time.
    travel_to Time.zone.parse('2026-08-04 12:00:00')
    @org = OptixOrganization.create!(name: 'Test Org', synced_at: Time.zone.parse('2026-08-04 03:00:00'))
    @annex = OptixLocation.create!(optix_id: 'loc-a', optix_organization: @org, name: 'Annex')
    @brooklyn = OptixLocation.create!(optix_id: 'loc-b', optix_organization: @org, name: 'Brooklyn')

    @patron_tpl = template!('tpl-patron', 'Patron Membership', locations: [@annex])
    @hot_desk_tpl = template!('tpl-hot', 'Hot Desk', locations: [@annex])
    @roamer_tpl = template!('tpl-roam', 'Roamer', in_all_locations: true)
  end

  def template!(optix_id, name, locations: [], in_all_locations: false)
    tpl = OptixPlanTemplate.create!(
      optix_id: optix_id, optix_organization: @org, name: name,
      in_all_locations: in_all_locations,
    )
    locations.each do |loc|
      OptixPlanTemplateLocation.create!(optix_plan_template_id: tpl.optix_id, optix_location_id: loc.optix_id)
    end
    tpl
  end

  def user!(optix_id)
    OptixUser.create!(optix_id: optix_id, optix_organization: @org,
                      email: "#{optix_id}@example.com", name: 'Secret', last_name: 'Person')
  end

  def plan!(user_id, template, status: 'ACTIVE', started:, ended: nil, canceled: nil)
    OptixAccountPlan.create!(
      optix_id: SecureRandom.hex(6),
      optix_organization: @org,
      optix_plan_template_id: template.optix_id,
      access_usage_user_optix_id: user_id,
      status: status,
      start_timestamp: started.to_time.to_i,
      end_timestamp: ended&.to_time&.to_i,
      canceled_timestamp: canceled&.to_time&.to_i,
    )
  end

  def seed_members!
    user!('u-patron')
    plan!('u-patron', @patron_tpl, started: Date.new(2026, 5, 1))

    user!('u-hot')
    plan!('u-hot', @hot_desk_tpl, started: Date.new(2026, 7, 27)) # only in the final 2 weeks

    # Ended before the latest week (timestamp), status ENDED (not paying).
    user!('u-roam')
    plan!('u-roam', @roamer_tpl, status: 'ENDED',
          started: Date.new(2026, 3, 1), ended: Date.new(2026, 8, 1))

    # Holds BOTH a patron and a non-patron plan: patron wins, never
    # double-counted across the two columns.
    user!('u-both')
    plan!('u-both', @patron_tpl, started: Date.new(2026, 5, 1))
    plan!('u-both', @hot_desk_tpl, started: Date.new(2026, 5, 1))
  end

  test 'per-location weekly counts, patron split, plan mix and totals — counts only, no PII' do
    seed_members!

    payload = mcp_payload(Mcp::GetMembershipStatsTool.call(server_context: {}))

    assert_equal '2026-08-04', payload['as_of']
    assert_equal 'Test Org', payload['organization']
    assert_equal @org.synced_at.iso8601, payload['synced_at']
    assert_equal 13, payload['weeks']

    assert_equal %w[Annex Brooklyn], payload['locations'].map { |l| l['location'] }
    annex = payload['locations'].find { |l| l['location'] == 'Annex' }
    brooklyn = payload['locations'].find { |l| l['location'] == 'Brooklyn' }

    # 13 trailing weeks, oldest first, ending at the upcoming Sunday.
    assert_equal 13, annex['weekly_counts'].length
    assert_equal '2026-08-09', annex['weekly_counts'].last['week_end']
    assert_equal '2026-05-17', annex['weekly_counts'].first['week_end']

    # Latest week at Annex: u-patron + u-both patrons; u-hot non-patron;
    # u-roam's all-locations plan ended 2026-08-01 so it no longer counts.
    latest = annex['weekly_counts'].last
    assert_equal 2, latest['patron']
    assert_equal 1, latest['non_patron']
    assert_equal 3, latest['total']
    assert_equal 3, annex['paying_members']
    assert_equal 2, annex['patron_members']
    assert_equal 1, annex['non_patron_members']

    # 4 weeks earlier (2026-07-12): u-patron + u-both patrons, u-roam roams in.
    four_weeks_ago = annex['weekly_counts'][-5]
    assert_equal '2026-07-12', four_weeks_ago['week_end']
    assert_equal 2, four_weeks_ago['patron']
    assert_equal 1, four_weeks_ago['non_patron']
    assert_equal 3, four_weeks_ago['total']
    assert_equal 0.0, annex['growth_4w_pct']

    # Brooklyn only ever saw the all-locations Roamer, gone by the latest week.
    assert_equal 1, brooklyn['weekly_counts'][-5]['total']
    assert_equal 0, brooklyn['weekly_counts'].last['total']
    assert_equal 0, brooklyn['paying_members']
    assert_equal(-100.0, brooklyn['growth_4w_pct'])

    # Plan mix is the CURRENT paying roster (ACTIVE/IN_TRIAL): the ENDED
    # Roamer plan never appears. Patron 2 (u-patron, u-both) + Hot Desk 2
    # (u-hot, u-both) at Annex; Brooklyn has no location-specific paying plans.
    assert_equal(
      [{ 'plan_type' => 'Hot Desk', 'count' => 2 }, { 'plan_type' => 'Patron Membership', 'count' => 2 }],
      annex['plan_mix'].sort_by { |r| r['plan_type'] }
    )
    assert_equal [], brooklyn['plan_mix']

    # Org-wide distinct paying members right now: u-patron, u-hot, u-both.
    assert_equal 3, payload['total_paying_members']

    # NO member PII, ever: no names, no emails, no user ids.
    raw = payload.to_json
    refute_includes raw, 'u-patron'
    refute_includes raw, '@example.com'
    refute_includes raw, 'Secret'
  end

  test 'a stale-sync ACTIVE plan past its end_timestamp is out of the counts but still in plan_mix' do
    # Optix status can lag reality. Weekly counts and total_paying_members are
    # timestamp-derived, so an ACTIVE-status plan whose end_timestamp already
    # passed drops out of both; plan_mix is status-derived, so it stays.
    user!('u-stale')
    plan!('u-stale', @patron_tpl, started: Date.new(2026, 1, 1), ended: Date.new(2026, 7, 1))

    payload = mcp_payload(Mcp::GetMembershipStatsTool.call(server_context: {}))
    annex = payload['locations'].find { |l| l['location'] == 'Annex' }

    assert_equal 0, payload['total_paying_members']
    assert_equal 0, annex['weekly_counts'].last['total']
    assert_equal 0, annex['paying_members']
    assert_equal [{ 'plan_type' => 'Patron Membership', 'count' => 1 }], annex['plan_mix'],
      'the status-derived plan mix still lists the stale ACTIVE plan'
  end

  test 'an in_all_locations plan counts at every location, so per-location sums exceed the distinct total' do
    user!('u-roamer')
    plan!('u-roamer', @roamer_tpl, started: Date.new(2026, 5, 1))

    payload = mcp_payload(Mcp::GetMembershipStatsTool.call(server_context: {}))
    annex = payload['locations'].find { |l| l['location'] == 'Annex' }
    brooklyn = payload['locations'].find { |l| l['location'] == 'Brooklyn' }

    [annex, brooklyn].each do |loc|
      assert_equal [{ 'plan_type' => 'Roamer', 'count' => 1 }], loc['plan_mix'],
        "#{loc['location']} plan_mix must fold the all-locations plan in"
      assert_equal 1, loc['weekly_counts'].last['total'],
        "#{loc['location']} weekly counts must include the all-locations member"
      assert_equal 1, loc['paying_members']
    end

    assert_equal 1, payload['total_paying_members'], 'org-wide the member is distinct-counted once'
    per_location_sum = payload['locations'].sum { |l| l['paying_members'] }
    assert_operator per_location_sum, :>, payload['total_paying_members'],
      'per-location sums exceed the org-wide distinct total by construction'
  end

  test 'an ACTIVE plan canceled mid-window drops from weeks after the cancel, plan_mix keeps it' do
    user!('u-cancel')
    plan!('u-cancel', @patron_tpl, started: Date.new(2026, 1, 1), canceled: Date.new(2026, 7, 15))

    payload = mcp_payload(Mcp::GetMembershipStatsTool.call(server_context: {}))
    annex = payload['locations'].find { |l| l['location'] == 'Annex' }
    by_week = annex['weekly_counts'].to_h { |w| [w['week_end'], w['total']] }

    assert_equal 1, by_week['2026-07-12'], 'still a member the week before the cancel'
    assert_equal 0, by_week['2026-07-19'], 'gone from the first week ending after the cancel'
    assert_equal 0, by_week['2026-08-09']
    assert_equal 0, annex['paying_members']
    assert_equal 0, payload['total_paying_members']
    assert_equal [{ 'plan_type' => 'Patron Membership', 'count' => 1 }], annex['plan_mix'],
      'the status-derived plan mix still lists the canceled-but-ACTIVE plan'
  end

  test 'growth_4w_pct is nil when there is no 4-weeks-ago baseline' do
    user!('u-new')
    plan!('u-new', @patron_tpl, started: Date.new(2026, 8, 3))

    payload = mcp_payload(Mcp::GetMembershipStatsTool.call(server_context: {}))
    annex = payload['locations'].find { |l| l['location'] == 'Annex' }
    assert_equal 1, annex['paying_members']
    assert_nil annex['growth_4w_pct'], 'zero members 4 weeks ago: no growth percentage'
  end

  test 'weeks parameter clamps to 4..26' do
    seed_members!

    payload = mcp_payload(Mcp::GetMembershipStatsTool.call(weeks: 100, server_context: {}))
    assert_equal 26, payload['weeks']
    assert_equal 26, payload['locations'].first['weekly_counts'].length

    payload = mcp_payload(Mcp::GetMembershipStatsTool.call(weeks: 1, server_context: {}))
    assert_equal 4, payload['weeks']
    assert_equal 4, payload['locations'].first['weekly_counts'].length
    assert_nil payload['locations'].first['growth_4w_pct'],
      'a 4-week window has no 4-weeks-earlier row to compare against'
  end

  test 'errors when no Optix organization has been synced' do
    @org.destroy!
    err = mcp_payload(Mcp::GetMembershipStatsTool.call(server_context: {}))
    assert_includes err['error'], 'No Optix organization'
  end
end
