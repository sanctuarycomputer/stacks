# Daily Google Analytics (GA4) sync for each active AnalyticsProperty (Stacks::GoogleAnalytics).
#
# Per property and day it stores three breakdowns in analytics_daily_metrics:
#   total        — the day's totals (the exact daily users figure);
#   traffic      — by session source / medium / campaign, top TRAFFIC_TOP_N per day;
#   landing_page — by landing page × campaign, top PAGES_TOP_N per day (so a campaign filter works on pages).
# Rows past a day's top N fold into one "(other)" row, so each breakdown still sums to the day's total.
#
# A property with no data yet is backfilled BACKFILL_MONTHS (month by month); after that each run
# re-fetches the last REFRESH_DAYS (GA4 keeps revising the last ~48h) plus any gap since data_through.
# Inert without the key: sync_all! returns { skipped: "not configured" } and calls nothing.
# Every write for a site runs under that site's advisory lock (with_site_lock), so the daily run, "Sync now"
# and the backfill rake never interleave; the unique index on dims_key is the backstop.
class Stacks::SiteAnalyticsSync
  ADVISORY_LOCK_KEY = 7_311_904_552_118
  BACKFILL_MONTHS = 13
  REFRESH_DAYS = 3
  TRAFFIC_TOP_N = 200
  PAGES_TOP_N = 300
  SITE_LOCK_NAMESPACE = 731_190
  LANDING_PAGE_MAX = 500
  METRICS = %w[sessions totalUsers newUsers screenPageViews engagedSessions keyEvents].freeze
  COLUMNS = %i[sessions total_users new_users views engaged_sessions key_events].freeze
  BREAKDOWNS = {
    "total" => { dimensions: [], columns: [] },
    "traffic" => { dimensions: %w[sessionSource sessionMedium sessionCampaignName], columns: %i[source medium campaign] },
    "landing_page" => { dimensions: %w[landingPage sessionCampaignName], columns: %i[landing_page campaign] },
  }.freeze

  def self.sync_all_with_lock!(client: nil, today: Date.current)
    return { skipped: "not configured" } unless client || Stacks::GoogleAnalytics.configured?

    conn = ActiveRecord::Base.connection
    return nil unless conn.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")

    begin
      sync = new(client || Stacks::GoogleAnalytics.new)
      discovered = begin
        sync.discover!
      rescue StandardError => e
        # Discovery failing (Admin API off, no access) never stops the sync of the sites we already have.
        Rails.logger.warn("[Stacks::SiteAnalyticsSync] property discovery failed: #{e.class}: #{e.message.to_s[0, 300]}")
        Sentry.capture_exception(e) if defined?(Sentry)
        { error: e.class.name }
      end
      sync.sync_all!(today: today).merge(discovered: discovered)
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
    end
  end

  # Creates an AnalyticsProperty for every GA4 property the service account can see that Stacks doesn't have
  # yet (name = GA display name, site_url = its web stream). Never deletes or edits an existing site: admins
  # rename or deactivate them. Returns the names created.
  def discover!
    created = []
    @client.account_summaries.each do |summary|
      next if summary[:property_id].blank? || AnalyticsProperty.exists?(ga4_property_id: summary[:property_id])

      name = summary[:display_name].presence || summary[:property_id]
      name = "#{name} (#{summary[:property_id]})" if AnalyticsProperty.exists?(name: name)
      url = begin
        @client.web_stream_uri(summary[:property_id])
      rescue StandardError
        nil
      end
      AnalyticsProperty.create!(name: name, ga4_property_id: summary[:property_id], site_url: url)
      created << name
    end
    created
  end

  def initialize(client, traffic_top_n: TRAFFIC_TOP_N, pages_top_n: PAGES_TOP_N)
    @client = client
    @top_n = { "total" => nil, "traffic" => traffic_top_n, "landing_page" => pages_top_n }
  end

  class Busy < StandardError; end

  # { properties: n, synced: [names], busy: [names], failed: { name => error } }. One property's failure never
  # stops the rest; a site another run is syncing right now is skipped (busy).
  def sync_all!(today: Date.current)
    result = { properties: 0, synced: [], busy: [], failed: {} }
    AnalyticsProperty.active.order(:name).each do |prop|
      result[:properties] += 1
      sync_property!(prop, today: today)
      result[:synced] << prop.name
    rescue Busy
      result[:busy] << prop.name
    rescue StandardError => e
      result[:failed][prop.name] = "#{e.class}: #{e.message}"[0, 500]
      prop.update_columns(last_sync_error: result[:failed][prop.name], updated_at: Time.current)
      Rails.logger.error("[Stacks::SiteAnalyticsSync] #{prop.name} (#{prop.ga4_property_id}) failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
    end
    SourceSync.for("google_analytics").advance!(stats: result, status: result[:failed].empty? ? "success" : "partial")
    result
  end

  # Backfill when there is no data yet (unless refresh_only: the admin's "Sync now" must not run a 13-month
  # backfill inside a web request); otherwise refresh the recent days and any gap. Raises Busy when another
  # run holds this site's lock. Returns :backfilled, :refreshed or :needs_backfill.
  def sync_property!(prop, today: Date.current, refresh_only: false)
    with_site_lock(prop) do
      prop.reload
      if prop.data_through.nil?
        next :needs_backfill if refresh_only

        backfill_range!(prop, BACKFILL_MONTHS, today)
        :backfilled
      else
        sync_range!(prop, [prop.data_through + 1, today - REFRESH_DAYS].min, today - 1)
        :refreshed
      end
    end
  end

  def backfill!(prop, months: BACKFILL_MONTHS, today: Date.current)
    with_site_lock(prop) { backfill_range!(prop, months, today) }
  end

  def with_site_lock(prop)
    conn = ActiveRecord::Base.connection
    got = conn.select_value("SELECT pg_try_advisory_lock(#{SITE_LOCK_NAMESPACE}, #{Integer(prop.id)})")
    raise Busy, "#{prop.name} is being synced by another run" unless got

    begin
      yield
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{SITE_LOCK_NAMESPACE}, #{Integer(prop.id)})")
    end
  end

  private

  def backfill_range!(prop, months, today)
    yesterday = today - 1
    start = (yesterday << months) + 1
    while start <= yesterday
      finish = [start.end_of_month, yesterday].min
      sync_range!(prop, start, finish)
      start = finish + 1
    end
  end

  def sync_range!(prop, from, to)
    return if from > to

    batches = BREAKDOWNS.to_h do |breakdown, spec|
      raw = @client.run_report(prop.ga4_property_id, date_from: from, date_to: to,
                               dimensions: ["date", *spec[:dimensions]], metrics: METRICS)
      [breakdown, rows_for(prop, breakdown, spec, raw)]
    end

    now = Time.current
    AnalyticsDailyMetric.transaction do
      AnalyticsDailyMetric.where(analytics_property_id: prop.id, date: from..to).delete_all
      batches.each_value do |rows|
        rows.each_slice(1_000) { |slice| AnalyticsDailyMetric.insert_all!(slice.map { |r| r.merge(created_at: now, updated_at: now) }) }
      end
      prop.update!(data_through: [prop.data_through, to].compact.max, last_synced_at: now, last_sync_error: nil)
    end
  end

  # GA rows → our rows: truncated dimension values merged, then each day's top N kept and the rest
  # folded into "(other)".
  def rows_for(prop, breakdown, spec, raw)
    by_day = Hash.new { |h, k| h[k] = {} }
    raw.each do |r|
      date = Date.strptime(r[:dimensions].first, "%Y%m%d")
      dims = spec[:columns].zip(r[:dimensions].drop(1)).to_h { |col, v| [col, clean(col, v)] }
      metrics = COLUMNS.zip(r[:metrics]).to_h
      acc = by_day[date][dims] ||= COLUMNS.to_h { |c| [c, 0] }
      COLUMNS.each { |c| acc[c] += metrics[c].to_f }
    end

    by_day.flat_map do |date, groups|
      ranked = groups.sort_by { |dims, m| [-m[:sessions], dims.values.join("\u0000")] }
      top_n = @top_n[breakdown]
      kept, rest = top_n ? [ranked.first(top_n), ranked.drop(top_n)] : [ranked, []]
      if rest.any?
        other = COLUMNS.to_h { |c| [c, rest.sum { |_d, m| m[c] }] }
        kept += [[spec[:columns].to_h { |c| [c, AnalyticsDailyMetric::OTHER] }, other]]
      end
      kept.map do |dims, m|
        row = { analytics_property_id: prop.id, date: date, breakdown: breakdown, source: "", medium: "", campaign: "", landing_page: "" }.merge(dims)
        row.merge(dims_key: AnalyticsDailyMetric.dims_key(row[:source], row[:medium], row[:campaign], row[:landing_page]))
           .merge(COLUMNS.to_h { |c| [c, c == :key_events ? m[c].round(2) : m[c].round] })
      end
    end
  end

  def clean(col, value)
    v = value.to_s
    col == :landing_page ? v[0, LANDING_PAGE_MAX] : v[0, 255]
  end
end
