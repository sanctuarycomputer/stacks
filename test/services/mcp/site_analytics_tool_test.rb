require 'test_helper'

class Mcp::SiteAnalyticsToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Time.zone.parse('2026-09-29 12:00:00')
    Stacks::GoogleAnalytics.stubs(:configured?).returns(true)
    @site = AnalyticsProperty.create!(name: 'garden3d.net', ga4_property_id: '111', site_url: 'https://www.garden3d.net', data_through: Date.new(2026, 9, 28))
    @other = AnalyticsProperty.create!(name: 'sanctuary.computer', ga4_property_id: '222', site_url: 'https://sanctuary.computer', data_through: Date.new(2026, 9, 28))
  end

  def row!(prop, date, breakdown, sessions, **dims)
    AnalyticsDailyMetric.create!(analytics_property: prop, date: date, breakdown: breakdown, sessions: sessions,
                                 total_users: sessions / 2, new_users: sessions / 4, views: sessions * 2,
                                 engaged_sessions: sessions / 2, key_events: 1, **dims)
  end

  def call(**args)
    JSON.parse(Mcp::GetSiteAnalyticsTool.call(**args, server_context: {}).content.first[:text])
  end

  test 'not configured and no data: says so' do
    Stacks::GoogleAnalytics.stubs(:configured?).returns(false)
    assert_match(/not configured/, call['error'])
  end

  test 'did the campaign lift visits: totals vs the prior period, movers, campaign filter' do
    # Prior period (Sep 1–14) and current (Sep 15–28).
    row!(@site, Date.new(2026, 9, 5), 'total', 100)
    row!(@site, Date.new(2026, 9, 20), 'total', 160)
    row!(@site, Date.new(2026, 9, 5), 'traffic', 10, source: 'news', medium: 'email', campaign: 'fall-launch')
    row!(@site, Date.new(2026, 9, 20), 'traffic', 70, source: 'news', medium: 'email', campaign: 'fall-launch')
    row!(@site, Date.new(2026, 9, 5), 'traffic', 90, source: 'google', medium: 'organic', campaign: '(organic)')
    row!(@site, Date.new(2026, 9, 20), 'traffic', 90, source: 'google', medium: 'organic', campaign: '(organic)')
    row!(@other, Date.new(2026, 9, 20), 'total', 999)

    r = call(site: 'garden3d', from: '2026-09-15', to: '2026-09-28')
    assert_equal ['garden3d.net'], r['sites'].map { |s| s['name'] }
    assert_equal({ 'from' => '2026-09-01', 'to' => '2026-09-14' }, r['compare'])
    assert_equal({ 'current' => 160, 'previous' => 100, 'change' => 60, 'change_pct' => 60.0 }, r['totals']['sessions'])
    assert_equal 'fall-launch', r['top_movers']['up'].first['key']
    assert_equal 60, r['top_movers']['up'].first['change']
    assert_equal [{ 'date' => '2026-09-20', 'sessions' => 160 }], r['daily_sessions']

    f = call(site: 'garden3d.net', from: '2026-09-15', to: '2026-09-28', campaign: 'FALL')
    assert_equal 'FALL', f['campaign_filter']
    assert_equal({ 'current' => 70, 'previous' => 10, 'change' => 60, 'change_pct' => 600.0 }, f['totals']['sessions'])
  end

  test 'site omitted combines every site; defaults are the last 28 complete days' do
    row!(@site, Date.new(2026, 9, 20), 'total', 10)
    row!(@other, Date.new(2026, 9, 21), 'total', 5)
    r = call
    assert_equal 2, r['sites'].size
    assert_equal({ 'from' => '2026-09-01', 'to' => '2026-09-28' }, r['period'])
    assert_equal 15, r['totals']['sessions']['current']
  end

  test 'unknown site lists the sites; bad dates are an error; (other) is never a mover' do
    assert_match(/Sites: garden3d.net, sanctuary.computer/, call(site: 'nope')['error'])
    assert_match(/YYYY-MM-DD/, call(from: 'last week')['error'])
    row!(@site, Date.new(2026, 9, 20), 'traffic', 50, source: '(other)', medium: '(other)', campaign: '(other)')
    assert_empty call(site: '111', by: 'source')['top_movers']['up']
  end

  test 'notes flag data that stops before the period ends' do
    @site.update!(data_through: Date.new(2026, 9, 20))
    assert_match(/garden3d.net: 2026-09-20/, call(site: 'garden3d.net').dig('notes', 0))
  end
end
