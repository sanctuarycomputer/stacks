# Top of the Optix data tree. For now we expect exactly one row, but the
# table exists so we can scope all Optix data by org_id and add additional
# tenants in the future without restructuring.
#
# Credentials currently live in Rails.credentials at the global :optix
# namespace — read by Stacks::Optix. When we add a second tenant we'll
# introduce a per-org credential lookup at that point.
class OptixOrganization < ApplicationRecord
  has_many :optix_locations,      foreign_key: :optix_organization_id, dependent: :destroy
  has_many :optix_plan_templates, foreign_key: :optix_organization_id, dependent: :destroy
  has_many :optix_account_plans,  foreign_key: :optix_organization_id, dependent: :destroy
  has_many :optix_users,          foreign_key: :optix_organization_id, dependent: :destroy

  validates :name, presence: true

  # Convenience: the live API client scoped to this org. Useful for ad-hoc
  # console exploration and as a building block for OptixSync.
  def client
    @client ||= Stacks::Optix.new(self)
  end

  # ---------- member roster ----------

  # All users with at least one ACTIVE or IN_TRIAL plan currently.
  def active_members
    optix_users
      .joins(<<~SQL)
        INNER JOIN optix_account_plans
          ON optix_account_plans.access_usage_user_optix_id = optix_users.optix_id
          AND optix_account_plans.optix_organization_id = optix_users.optix_organization_id
      SQL
      .where(optix_account_plans: { status: %w[ACTIVE IN_TRIAL] })
      .distinct
  end

  # Users who exist but have NO active/in-trial plan right now. Useful as a
  # "former members" / churned roster.
  def inactive_members
    user_ids_with_active_plans = optix_account_plans
      .where(status: %w[ACTIVE IN_TRIAL])
      .where.not(access_usage_user_optix_id: nil)
      .pluck(:access_usage_user_optix_id)
      .uniq

    if user_ids_with_active_plans.any?
      optix_users.where.not(optix_id: user_ids_with_active_plans)
    else
      optix_users.all
    end
  end

  # ---------- time-series counts ----------

  # Number of distinct users who had an active plan at the END of the given
  # month. "Active at time T" means: a plan exists where
  #   start_timestamp <= T AND (end_timestamp IS NULL OR end_timestamp > T)
  #   AND (canceled_timestamp IS NULL OR canceled_timestamp > T)
  #
  # Status-agnostic — derived purely from timestamps so we can backfill from
  # historical data even after Optix changes status fields.
  def active_member_count_at_end_of_month(date)
    t = date.end_of_month.to_time.to_i
    optix_account_plans
      .where("start_timestamp <= ?", t)
      .where("end_timestamp IS NULL OR end_timestamp > ?", t)
      .where("canceled_timestamp IS NULL OR canceled_timestamp > ?", t)
      .where.not(access_usage_user_optix_id: nil)
      .distinct
      .count(:access_usage_user_optix_id)
  end

  # Month-over-month growth/churn metrics for a span of months ending at
  # `through_month`. Returns Array<Hash> with one row per month:
  #
  #   [
  #     { month: Date,
  #       active_count: 42,        # distinct active users at end of month
  #       new_count:    5,         # users newly active this month vs last
  #       churned_count: 2,        # users active last month, not this month
  #       net_change:   3 },       # active_count - prev_active_count
  #     ...
  #   ]
  def membership_history(months: 12, through_month: Date.today)
    history_from_user_ids_fn(months: months, through_month: through_month) do |date|
      active_user_ids_at_end_of_month(date)
    end
  end

  # Pattern that classifies a plan template as a "Patron" tier. Currently a
  # case-insensitive match on the template name; override here (or move to a
  # column on OptixPlanTemplate) if your tier naming convention changes.
  PATRON_PLAN_NAME_PATTERN = /patron/i

  # Snapshot of (week_end × location) → member counts split by patron/non-patron.
  # Designed to be rendered as an HTML table that copy-pastes cleanly into a
  # Google Sheets workbook (or Excel) — each row is one cell-row in the output.
  #
  # Returns Array<Hash>, oldest-first:
  #   [
  #     { week_end: Date, location: "Index | Chinatown",
  #       non_patron: 22, patron: 6, total: 28 },
  #     ...
  #   ]
  #
  # @param weeks [Integer] how many weeks of history (including the current one)
  # @param week_end_wday [Integer] 0..6 — day of week to use as the week-ending
  #                                marker. Default 0 (Sunday) since the example
  #                                workbook uses dates like 3/8/26 which are
  #                                Sundays in 2026. Pass 6 for Saturday.
  def weekly_membership_snapshots(weeks: 16, week_end_wday: 0)
    today = Date.today
    days_ahead = (week_end_wday - today.wday) % 7
    most_recent_week_end = today + days_ahead
    week_ends = (0...weeks).map { |i| most_recent_week_end - (weeks - 1 - i).weeks }

    plans = optix_account_plans
      .where.not(access_usage_user_optix_id: nil)
      .pluck(
        :access_usage_user_optix_id,
        :optix_plan_template_id,
        :start_timestamp,
        :end_timestamp,
        :canceled_timestamp,
      )

    template_meta = optix_plan_templates
      .includes(:optix_locations)
      .each_with_object({}) do |t, h|
        h[t.optix_id] = {
          is_patron:        t.name.to_s.match?(PATRON_PLAN_NAME_PATTERN),
          in_all_locations: t.in_all_locations,
          location_ids:     t.optix_locations.map(&:optix_id),
        }
      end

    locations = optix_locations.order(:name).to_a

    rows = []
    week_ends.each do |week_end|
      t = week_end.end_of_day.to_time.to_i

      locations.each do |loc|
        patron_users     = Set.new
        non_patron_users = Set.new

        plans.each do |user_id, template_id, start_ts, end_ts, canceled_ts|
          next unless start_ts && start_ts <= t
          next if end_ts && end_ts <= t
          next if canceled_ts && canceled_ts <= t

          meta = template_meta[template_id]
          next unless meta
          next unless meta[:in_all_locations] || meta[:location_ids].include?(loc.optix_id)

          if meta[:is_patron]
            patron_users << user_id
          else
            non_patron_users << user_id
          end
        end

        # If a user holds both a patron and non-patron plan simultaneously,
        # patron wins so they aren't double-counted across the two columns.
        non_patron_users -= patron_users

        rows << {
          week_end:   week_end,
          location:   loc.name,
          non_patron: non_patron_users.size,
          patron:     patron_users.size,
          total:      non_patron_users.size + patron_users.size,
        }
      end
    end

    rows
  end

  # Same shape as `membership_history`, but nested per location:
  #   { "All Locations" => [{...}, {...}], "Downtown" => [{...}, {...}], ... }
  # The "All Locations" entry is the org-wide rollup. Plans flagged
  # `in_all_locations` count toward the org-wide rollup AND every specific
  # location bucket — that's intentional, since members on those plans truly
  # are members at every location.
  def membership_history_by_location(months: 12, through_month: Date.today)
    out = { "All Locations" => membership_history(months: months, through_month: through_month) }

    optix_locations.order(:name).each do |location|
      rows = history_from_user_ids_fn(months: months, through_month: through_month) do |date|
        active_user_ids_for_location_at_end_of_month(location, date)
      end
      out[location.name || "(unnamed)"] = rows
    end

    out
  end

  private

  # Generic month-by-month history given a fn that returns active user IDs for
  # a given date. Computes new/churned/net by diffing current vs previous month.
  def history_from_user_ids_fn(months:, through_month:)
    end_month = through_month.beginning_of_month
    start_month = end_month - (months - 1).months

    rows = []
    prev_ids = yield(start_month - 1.month)

    (start_month..end_month).select { |d| d.day == 1 }.each do |month_start|
      current_ids = yield(month_start)
      rows << {
        month:         month_start,
        active_count:  current_ids.size,
        new_count:     (current_ids - prev_ids).size,
        churned_count: (prev_ids - current_ids).size,
        net_change:    current_ids.size - prev_ids.size,
      }
      prev_ids = current_ids
    end

    rows
  end

  # Set of user IDs active at end of the given month, org-wide.
  def active_user_ids_at_end_of_month(date)
    t = date.end_of_month.to_time.to_i
    optix_account_plans
      .where("start_timestamp <= ?", t)
      .where("end_timestamp IS NULL OR end_timestamp > ?", t)
      .where("canceled_timestamp IS NULL OR canceled_timestamp > ?", t)
      .where.not(access_usage_user_optix_id: nil)
      .distinct
      .pluck(:access_usage_user_optix_id)
      .to_set
  end

  # Set of user IDs active at end of the given month, scoped to a specific
  # location. Includes plans flagged `in_all_locations` because those members
  # are entitled to every location.
  def active_user_ids_for_location_at_end_of_month(location, date)
    t = date.end_of_month.to_time.to_i

    base = optix_account_plans
      .where("start_timestamp <= ?", t)
      .where("end_timestamp IS NULL OR end_timestamp > ?", t)
      .where("canceled_timestamp IS NULL OR canceled_timestamp > ?", t)
      .where.not(access_usage_user_optix_id: nil)

    location_specific_ids = base
      .joins(optix_plan_template: :optix_locations)
      .where(optix_locations: { optix_id: location.optix_id })
      .distinct
      .pluck(:access_usage_user_optix_id)

    in_all_ids = base
      .joins(:optix_plan_template)
      .where(optix_plan_templates: { in_all_locations: true })
      .distinct
      .pluck(:access_usage_user_optix_id)

    (location_specific_ids + in_all_ids).to_set
  end
end
