module Mcp
  class GetMembershipStatsTool < MCP::Tool
    tool_name 'get_membership_stats'
    description 'Coworking membership stats from the synced Optix mirror: per-location ' \
                'trailing weekly paying-member counts split Patron / Non-Patron (derived from ' \
                'plan start/end/cancel timestamps, so weekly history is computed, not stored), ' \
                'the current plan mix per location (ACTIVE/IN_TRIAL plans by plan-template ' \
                'name), 4-week growth, and the org-wide distinct paying-member total. ' \
                'plan_mix folds all-locations plans into EVERY location\'s mix — the admin ' \
                'tier panel buckets those separately. total_paying_members is ' \
                'timestamp-derived at call time, so it differs from the admin\'s status-based ' \
                'Active Members figure (which also counts UPCOMING plans) and from the weekly ' \
                'rows, which count at each Sunday end-of-day. Members on an all-locations ' \
                'plan count at every location, so per-location totals can sum past the ' \
                'org-wide distinct total. COUNTS AND PLAN NAMES ONLY — never member names, ' \
                'emails, or ids. Figures are as of the last Optix sync (see synced_at).'

    MIN_WEEKS = 4
    MAX_WEEKS = 26
    DEFAULT_WEEKS = 13

    input_schema(
      properties: {
        weeks: { type: 'integer', description: "Trailing weeks of history per location (default #{DEFAULT_WEEKS}, clamped #{MIN_WEEKS}..#{MAX_WEEKS})." },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(weeks: DEFAULT_WEEKS, server_context:)
      org = OptixOrganization.order(:id).first
      unless org
        return Responses.error('No Optix organization has been synced yet; membership stats are unavailable.')
      end

      weeks = weeks.to_i.clamp(MIN_WEEKS, MAX_WEEKS)
      # Timestamp-derived, DB-only — never touches the live Optix API (H1).
      weekly_rows = org.weekly_membership_snapshots(weeks: weeks).group_by { |r| r[:location] }

      locations = org.optix_locations.order(:name).map do |loc|
        location_block(org, loc, Array(weekly_rows[loc.name]))
      rescue StandardError => e
        Rails.logger.warn("[Mcp::GetMembershipStatsTool] skipping location '#{loc.name}': #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end.compact

      Responses.ok({
        as_of: Date.today.iso8601,
        organization: org.name,
        synced_at: org.synced_at&.iso8601,
        weeks: weeks,
        total_paying_members: total_paying_members(org),
        locations: locations,
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetMembershipStatsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_membership_stats failed; the error was logged')
    end

    def self.location_block(org, loc, rows)
      weekly_counts = rows.map do |r|
        { week_end: r[:week_end].iso8601, patron: r[:patron], non_patron: r[:non_patron], total: r[:total] }
      end
      latest = weekly_counts.last || { patron: 0, non_patron: 0, total: 0 }

      {
        location: loc.name,
        paying_members: latest[:total],
        patron_members: latest[:patron],
        non_patron_members: latest[:non_patron],
        growth_4w_pct: growth_4w_pct(weekly_counts),
        weekly_counts: weekly_counts,
        plan_mix: plan_mix(org, loc),
      }
    end

    # Latest week vs 4 weeks earlier ([-5] in a weekly series that includes
    # the current week). nil when the window is too short or the baseline is
    # zero — a percentage against nothing is noise, not signal.
    def self.growth_4w_pct(weekly_counts)
      return nil if weekly_counts.length < 5
      baseline = weekly_counts[-5][:total]
      return nil if baseline.zero?
      (((weekly_counts.last[:total] - baseline) / baseline.to_f) * 100).round(1)
    end

    # Current paying (ACTIVE/IN_TRIAL) plans by plan-template name, for plans
    # scoped to this location plus all-locations plans (their holders are
    # members here too — same inclusion the weekly counts use). NOTE: the
    # weekly series is timestamp-derived while this mix is status-derived,
    # exactly as the two admin panels differ.
    def self.plan_mix(org, loc)
      specific = org.optix_account_plans.paying
        .joins(optix_plan_template: :optix_plan_template_locations)
        .where(optix_plan_template_locations: { optix_location_id: loc.optix_id })
        .group('optix_plan_templates.name')
        .count
      in_all = org.optix_account_plans.paying
        .joins(:optix_plan_template)
        .where(optix_plan_templates: { in_all_locations: true })
        .group('optix_plan_templates.name')
        .count

      specific.merge(in_all) { |_name, a, b| a + b }
        .map { |name, count| { plan_type: name, count: count } }
        .sort_by { |r| [-r[:count], r[:plan_type].to_s] }
    end

    # Org-wide DISTINCT members with a currently-running plan, derived from
    # timestamps like the weekly series (status-agnostic), so all-locations
    # members are counted once here even though they appear at every location.
    def self.total_paying_members(org)
      org.optix_account_plans
        .active_at(Time.current)
        .where.not(access_usage_user_optix_id: nil)
        .distinct
        .count(:access_usage_user_optix_id)
    end
  end
end
