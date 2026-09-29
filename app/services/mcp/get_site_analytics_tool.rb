module Mcp
  class GetSiteAnalyticsTool < MCP::Tool
    tool_name 'get_site_analytics'
    description 'Website traffic for our own sites from Google Analytics (GA4), synced daily into Stacks. ' \
                'Answers questions like "did the new campaign lift site visits?": totals for a period vs a ' \
                'comparison period (sessions, users, new users, views, engaged sessions, engagement rate, key ' \
                'events) with changes, the daily sessions series, and the top movers by campaign, by source / ' \
                'medium, or by landing page. Defaults: the last 28 complete days vs the 28 days before. ' \
                'Filter to one campaign with `campaign` (case-insensitive substring of the GA campaign name). ' \
                'Users are the sum of daily users (not unique across days). "(other)" folds each day\'s traffic ' \
                'beyond the top 200 sources/campaigns or top 100 landing pages. Aggregate counts only.'

    DEFAULT_DAYS = 28
    MAX_DAYS = 400
    MOVERS = 10
    BY = %w[campaign source page].freeze
    METRICS = %i[sessions total_users new_users views engaged_sessions key_events].freeze

    input_schema(
      properties: {
        site: { type: 'string', description: 'Site name, domain or GA4 property id. Omit to combine every site.' },
        from: { type: 'string', description: "Start date (YYYY-MM-DD). Default: #{DEFAULT_DAYS} days before `to`." },
        to: { type: 'string', description: 'End date (YYYY-MM-DD), inclusive. Default: yesterday (the last complete day).' },
        compare_from: { type: 'string', description: 'Comparison start (YYYY-MM-DD). Default: the equal-length period just before `from`.' },
        compare_to: { type: 'string', description: 'Comparison end (YYYY-MM-DD), inclusive.' },
        by: { type: 'string', enum: BY, description: 'Breakdown for top movers: campaign (default), source (source / medium) or page (landing page).' },
        campaign: { type: 'string', description: 'Only traffic whose campaign name contains this (case-insensitive).' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(site: nil, from: nil, to: nil, compare_from: nil, compare_to: nil, by: 'campaign', campaign: nil, server_context:)
      unless Stacks::GoogleAnalytics.configured? || AnalyticsDailyMetric.exists?
        return Responses.error('Google Analytics is not configured in Stacks yet (no service-account key), so there is no site traffic data.')
      end

      props = site.present? ? AnalyticsProperty.matching(site).to_a : AnalyticsProperty.active.order(:name).to_a
      if props.empty?
        names = AnalyticsProperty.active.order(:name).pluck(:name)
        return Responses.error(names.empty? ? 'No sites are set up in Stacks yet (Site Analytics → Properties).' : "No site matches \"#{site}\". Sites: #{names.join(', ')}.")
      end

      period = period(from, to)
      return Responses.error('Dates must be YYYY-MM-DD, with from on or before to.') unless period
      compare = compare_period(period, compare_from, compare_to)
      return Responses.error('Comparison dates must be YYYY-MM-DD, with compare_from on or before compare_to.') unless compare

      by = BY.include?(by.to_s) ? by.to_s : 'campaign'
      ids = props.map(&:id)
      current = totals(ids, period, campaign)
      previous = totals(ids, compare, campaign)

      Responses.ok({
        sites: props.map { |p| { name: p.name, site_url: p.site_url, data_through: p.data_through&.iso8601, last_synced_at: p.last_synced_at&.iso8601 } },
        period: { from: period.first.iso8601, to: period.last.iso8601 },
        compare: { from: compare.first.iso8601, to: compare.last.iso8601 },
        campaign_filter: campaign.presence,
        totals: METRICS.to_h { |m| [m, change(current[m], previous[m])] },
        engagement_rate: rate_change(current, previous),
        daily_sessions: daily(ids, period, campaign),
        by: by,
        top_movers: movers(ids, period, compare, by, campaign),
        notes: notes(props, period, compare),
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetSiteAnalyticsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_site_analytics failed; the error was logged')
    end

    def self.period(from, to)
      finish = date(to) || (Date.current - 1)
      start = date(from) || (finish - (DEFAULT_DAYS - 1))
      return nil if (from.present? && !date(from)) || (to.present? && !date(to)) || start > finish

      start = finish - (MAX_DAYS - 1) if (finish - start).to_i >= MAX_DAYS
      start..finish
    end

    def self.compare_period(period, compare_from, compare_to)
      if compare_from.present? || compare_to.present?
        a = date(compare_from)
        b = date(compare_to)
        return nil unless a && b && a <= b

        return a..b
      end
      days = (period.last - period.first).to_i + 1
      (period.first - days)..(period.first - 1)
    end

    def self.date(str)
      return nil if str.blank?

      Date.iso8601(str.to_s)
    rescue ArgumentError
      nil
    end

    # Totals from the exact "total" rows; with a campaign filter, from the matching traffic rows.
    def self.scope(ids, range, campaign, breakdown: nil)
      rel = AnalyticsDailyMetric.where(analytics_property_id: ids, date: range)
      if campaign.present?
        rel.where(breakdown: 'traffic').where('campaign ILIKE ?', "%#{AnalyticsDailyMetric.sanitize_sql_like(campaign)}%")
      else
        rel.where(breakdown: breakdown || 'total')
      end
    end

    def self.totals(ids, range, campaign)
      sums = scope(ids, range, campaign).pluck(*METRICS.map { |m| Arel.sql("COALESCE(SUM(#{m}), 0)") }).first
      METRICS.zip(sums.map { |v| v.to_f }).to_h
    end

    def self.daily(ids, range, campaign)
      scope(ids, range, campaign).group(:date).order(:date).sum(:sessions).map { |d, s| { date: d.iso8601, sessions: s.to_i } }
    end

    def self.change(cur, prev)
      cur = clean(cur)
      prev = clean(prev)
      { current: cur, previous: prev, change: clean(cur - prev), change_pct: prev.zero? ? nil : ((cur - prev).to_f / prev * 100).round(1) }
    end

    def self.rate_change(cur, prev)
      rate = ->(t) { t[:sessions].to_f.zero? ? nil : (t[:engaged_sessions] / t[:sessions] * 100).round(1) }
      c = rate.call(cur)
      p = rate.call(prev)
      { current_pct: c, previous_pct: p, change_pts: c && p ? (c - p).round(1) : nil }
    end

    def self.clean(v)
      v = v.to_f
      v == v.round ? v.round : v.round(2)
    end

    def self.movers(ids, period, compare, by, campaign)
      breakdown = by == 'page' ? 'landing_page' : 'traffic'
      key_cols = { 'campaign' => %i[campaign], 'source' => %i[source medium], 'page' => %i[landing_page] }[by]
      grouped = lambda do |range|
        rel = AnalyticsDailyMetric.where(analytics_property_id: ids, date: range, breakdown: breakdown)
        rel = rel.where('campaign ILIKE ?', "%#{AnalyticsDailyMetric.sanitize_sql_like(campaign)}%") if campaign.present? && breakdown == 'traffic'
        rel.group(*key_cols).sum(:sessions).transform_keys { |k| Array(k).join(' / ') }
      end
      cur = grouped.call(period)
      prev = grouped.call(compare)
      rows = (cur.keys | prev.keys).reject { |k| k.split(' / ').all? { |part| part == AnalyticsDailyMetric::OTHER } }.map do |k|
        c = cur[k].to_i
        p = prev[k].to_i
        { key: k, sessions: c, previous_sessions: p, change: c - p, change_pct: p.zero? ? nil : ((c - p).to_f / p * 100).round(1) }
      end
      {
        up: rows.select { |r| r[:change].positive? }.sort_by { |r| [-r[:change], r[:key]] }.first(MOVERS),
        down: rows.select { |r| r[:change].negative? }.sort_by { |r| [r[:change], r[:key]] }.first(MOVERS),
        top: rows.sort_by { |r| [-r[:sessions], r[:key]] }.first(MOVERS),
      }
    end

    def self.notes(props, period, compare)
      out = []
      stale = props.select { |p| p.data_through.nil? || p.data_through < period.last }
      out << "Data only runs through #{stale.map { |p| "#{p.name}: #{p.data_through&.iso8601 || 'none yet'}" }.join(', ')}; later days read as zero." if stale.any?
      earliest = AnalyticsDailyMetric.where(analytics_property_id: props.map(&:id)).minimum(:date)
      out << "The comparison period starts before the earliest synced day (#{earliest.iso8601}); it reads low." if earliest && compare.first < earliest
      out
    end
  end
end
