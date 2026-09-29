require 'test_helper'

class Stacks::SiteAnalyticsSyncTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # Answers runReport from a per-breakdown table of { "YYYYMMDD" => [[dims..., metrics...]] }.
  class FakeClient
    attr_reader :calls

    def initialize(days)
      @days = days
      @calls = []
    end

    def run_report(property_id, date_from:, date_to:, dimensions:, metrics:, order_by_metric: nil)
      @calls << { property_id: property_id, from: date_from, to: date_to, dimensions: dimensions }
      key = dimensions.drop(1)
      (date_from..date_to).flat_map do |d|
        Array(@days.dig(key, d.strftime('%Y%m%d'))).map do |row|
          dims, nums = row.partition { |x| x.is_a?(String) }
          { dimensions: [d.strftime('%Y%m%d'), *dims], metrics: nums.map(&:to_f) }
        end
      end
    end
  end

  # sessions, users, new users, views, engaged sessions, key events
  DAY = {
    [] => { '20260927' => [[100, 80, 30, 250, 60, 4]] },
    %w[sessionSource sessionMedium sessionCampaignName] => {
      '20260927' => [['google', 'cpc', 'fall-launch', 50, 40, 20, 120, 35, 3], ['(direct)', '(none)', '(direct)', 30, 25, 5, 80, 15, 1],
                     ['news', 'email', 'digest', 12, 10, 3, 30, 7, 0], ['x', 'social', '(not set)', 8, 5, 2, 20, 3, 0]],
    },
    %w[landingPage sessionCampaignName] => { '20260927' => [['/', 'fall-launch', 50, 40, 15, 100, 30, 2], ['/', '(direct)', 20, 15, 5, 50, 10, 0], ['/work', '(direct)', 30, 25, 10, 100, 20, 2]] },
  }.freeze

  setup do
    travel_to Time.zone.parse('2026-09-29 09:00:00')
    @prop = AnalyticsProperty.create!(name: 'garden3d.net', ga4_property_id: 'properties/123456', site_url: 'https://www.garden3d.net')
  end

  test 'not configured: skips without calling Google' do
    Stacks::GoogleAnalytics.stubs(:configured?).returns(false)
    assert_equal({ skipped: 'not configured' }, Stacks::SiteAnalyticsSync.sync_all_with_lock!)
    assert_equal 0, AnalyticsDailyMetric.count
  end

  test 'the property id is normalised from "properties/<id>"' do
    assert_equal '123456', @prop.ga4_property_id
    refute AnalyticsProperty.new(name: 'x', ga4_property_id: 'G-ABC123').valid?
  end

  test 'first sync backfills 13 months, month by month, oldest first; data_through = yesterday' do
    client = FakeClient.new(DAY)
    Stacks::SiteAnalyticsSync.new(client).sync_all!(today: Date.new(2026, 9, 29))
    froms = client.calls.map { |c| c[:from] }.uniq
    assert_equal Date.new(2025, 8, 29), froms.first
    assert_equal Date.new(2026, 9, 28), client.calls.map { |c| c[:to] }.max
    assert_equal froms.sort, froms
    assert_equal Date.new(2026, 9, 28), @prop.reload.data_through
    assert_nil @prop.last_sync_error
    assert_equal 100, AnalyticsDailyMetric.where(breakdown: 'total').sum(:sessions)
    assert_equal 'success', SourceSync.find_by(source: 'google_analytics').status
  end

  test 'later syncs refresh the last 3 days, and re-syncing replaces rather than doubles' do
    @prop.update!(data_through: Date.new(2026, 9, 28))
    client = FakeClient.new(DAY)
    sync = Stacks::SiteAnalyticsSync.new(client)
    2.times { sync.sync_property!(@prop, today: Date.new(2026, 9, 29)) }
    assert_equal [Date.new(2026, 9, 26)], client.calls.map { |c| c[:from] }.uniq
    assert_equal 100, AnalyticsDailyMetric.where(breakdown: 'total').sum(:sessions)
    assert_equal 100, AnalyticsDailyMetric.where(breakdown: 'traffic').sum(:sessions), 'the traffic breakdown sums to the total'
  end

  test 'a gap since data_through is filled' do
    @prop.update!(data_through: Date.new(2026, 9, 10))
    client = FakeClient.new(DAY)
    Stacks::SiteAnalyticsSync.new(client).sync_property!(@prop, today: Date.new(2026, 9, 29))
    assert_equal Date.new(2026, 9, 11), client.calls.first[:from]
  end

  test 'rows past the daily top N fold into one (other) row, keeping the sum' do
    @prop.update!(data_through: Date.new(2026, 9, 28))
    Stacks::SiteAnalyticsSync.new(FakeClient.new(DAY), traffic_top_n: 2).sync_property!(@prop, today: Date.new(2026, 9, 29))
    traffic = AnalyticsDailyMetric.where(breakdown: 'traffic')
    assert_equal 3, traffic.count
    other = traffic.find_by(campaign: AnalyticsDailyMetric::OTHER)
    assert_equal [20, 15, 10], [other.sessions, other.total_users, other.engaged_sessions]
    assert_equal 100, traffic.sum(:sessions)
  end

  test 'one failing site is recorded and does not stop the others' do
    AnalyticsProperty.create!(name: 'sanctuary.computer', ga4_property_id: '999')
    client = FakeClient.new(DAY)
    client.define_singleton_method(:run_report) do |property_id, **kw|
      raise Stacks::GoogleAnalytics::Error, 'GA4 403: no access' if property_id == '999'

      super(property_id, **kw)
    end
    result = Stacks::SiteAnalyticsSync.new(client).sync_all!(today: Date.new(2026, 9, 29))
    assert_equal ['garden3d.net'], result[:synced]
    assert_match(/403/, result[:failed]['sanctuary.computer'])
    assert_match(/403/, AnalyticsProperty.find_by(name: 'sanctuary.computer').last_sync_error)
    assert_equal 'partial', SourceSync.find_by(source: 'google_analytics').status
  end

  test 'landing pages carry their campaign, so a campaign filter works on pages' do
    @prop.update!(data_through: Date.new(2026, 9, 28))
    Stacks::SiteAnalyticsSync.new(FakeClient.new(DAY)).sync_property!(@prop, today: Date.new(2026, 9, 29))
    pages = AnalyticsDailyMetric.where(breakdown: 'landing_page')
    assert_equal 100, pages.sum(:sessions)
    assert_equal 50, pages.find_by(landing_page: '/', campaign: 'fall-launch').sessions
  end

  test 'refresh_only (the admin Sync now) never backfills a site with no data' do
    client = FakeClient.new(DAY)
    assert_equal :needs_backfill, Stacks::SiteAnalyticsSync.new(client).sync_property!(@prop, today: Date.new(2026, 9, 29), refresh_only: true)
    assert_empty client.calls
  end

  test 'a site another run is syncing is Busy (no interleaved delete + insert), and sync_all! skips it' do
    # Tests share one AR connection across threads, so hold the lock from a separate raw PG session.
    cfg = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(dbname: cfg[:database], host: cfg[:host], port: cfg[:port], user: cfg[:username], password: cfg[:password])
    other.exec("SELECT pg_advisory_lock(#{Stacks::SiteAnalyticsSync::SITE_LOCK_NAMESPACE}, #{@prop.id})")
    sync = Stacks::SiteAnalyticsSync.new(FakeClient.new(DAY))
    assert_raises(Stacks::SiteAnalyticsSync::Busy) { sync.sync_property!(@prop, today: Date.new(2026, 9, 29)) }
    assert_raises(Stacks::SiteAnalyticsSync::Busy) { sync.backfill!(@prop, today: Date.new(2026, 9, 29)) }
    assert_equal ['garden3d.net'], sync.sync_all!(today: Date.new(2026, 9, 29))[:busy]
    assert_equal 0, AnalyticsDailyMetric.count
  ensure
    other&.close
  end

  test 'the unique index refuses a second copy of the same row (backstop against double counts)' do
    AnalyticsDailyMetric.create!(analytics_property: @prop, date: Date.new(2026, 9, 27), breakdown: 'traffic', source: 'a', medium: 'b', campaign: 'c', sessions: 1)
    assert_raises(ActiveRecord::RecordNotUnique) do
      AnalyticsDailyMetric.create!(analytics_property: @prop, date: Date.new(2026, 9, 27), breakdown: 'traffic', source: 'a', medium: 'b', campaign: 'c', sessions: 1)
    end
  end

  test 'changing the GA4 property id drops the old property rows and restarts from a backfill' do
    AnalyticsDailyMetric.create!(analytics_property: @prop, date: Date.new(2026, 9, 27), breakdown: 'total', sessions: 5)
    @prop.update!(data_through: Date.new(2026, 9, 28), last_sync_error: 'x')
    @prop.update!(name: 'garden3d (renamed)')
    assert_equal 1, @prop.analytics_daily_metrics.count, 'a rename keeps the data'
    @prop.update!(ga4_property_id: '654321')
    assert_equal 0, @prop.analytics_daily_metrics.count
    assert_nil @prop.reload.data_through
    assert_nil @prop.last_sync_error
  end

  test 'discover! adds every visible property once, never touches existing sites, and names collisions' do
    client = FakeClient.new(DAY)
    client.define_singleton_method(:account_summaries) do
      [{ property_id: '123456', display_name: 'garden3d.net (GA)', account: 'accounts/1' },
       { property_id: '777', display_name: 'Index Space', account: 'accounts/1' },
       { property_id: '888', display_name: 'garden3d.net', account: 'accounts/2' }]
    end
    client.define_singleton_method(:web_stream_uri) { |id| id == '777' ? 'https://index-space.org' : raise('no streams') }
    @prop.update!(active: false)
    sync = Stacks::SiteAnalyticsSync.new(client)
    assert_equal ['Index Space', 'garden3d.net (888)'], sync.discover!
    assert_equal 'https://index-space.org', AnalyticsProperty.find_by(ga4_property_id: '777').site_url
    refute @prop.reload.active, 'an existing site is never re-enabled or edited'
    assert_equal [], sync.discover!, 'idempotent'
  end

  test 'a failing discovery never stops the daily sync' do
    client = FakeClient.new(DAY)
    client.define_singleton_method(:account_summaries) { raise Stacks::GoogleAnalytics::Error, 'GA4 403: Analytics Admin API has not been used' }
    result = Stacks::SiteAnalyticsSync.sync_all_with_lock!(client: client, today: Date.new(2026, 9, 29))
    assert_equal({ error: 'Stacks::GoogleAnalytics::Error' }, result[:discovered])
    assert_equal ['garden3d.net'], result[:synced]
  end
end
