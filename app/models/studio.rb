class Studio < ApplicationRecord
  has_many :studio_key_meetings, dependent: :delete_all
  has_many :key_meetings, through: :studio_key_meetings
  accepts_nested_attributes_for :studio_key_meetings, allow_destroy: true

  has_many :social_properties
  accepts_nested_attributes_for :social_properties, allow_destroy: true

  has_many :studio_memberships
  has_many :admin_users, through: :studio_memberships

  has_many :studio_coordinator_periods
  accepts_nested_attributes_for :studio_coordinator_periods, allow_destroy: true

  has_many :mailing_lists

  def forecast_people(preloaded_studios = Studio.all)
    @_forecast_people ||= (
      people =
        ForecastPerson.includes(admin_user: [:studios, :full_time_periods]).all
      return people if is_garden3d?
      people.select do |fp|
        next true if (fp.try(:admin_user).try(:studios) || []).include?(self)
        fp.studios(preloaded_studios).include?(self)
      end
    )
  end

  def generate_snapshot!(
    preloaded_studios = Studio.all,
    preloaded_new_biz_notion_pages = new_biz_notion_pages
  )
    snapshot =
      [:year, :month, :quarter].reduce({
        generated_at: DateTime.now.iso8601,
      }) do |acc, gradation|
        periods = Stacks::Period.for_gradation(gradation)

        utilization_by_period  =
          periods.reduce({}) do |acc, period|
            acc[period] = utilization_for_period(period, preloaded_studios)
            acc
          end

        acc[gradation] = Parallel.map(periods, in_threads: 5) do |period|
          d = {
            label: period.label,
            cash: {},
            accrual: {},
            utilization: utilization_by_period[period].transform_keys {|fp| fp.email.blank? ? "#{fp.first_name} #{fp.last_name}" : fp.email }
          }
          d[:cash][:datapoints] = self.key_datapoints_for_period(
            period,
            "cash",
            preloaded_studios,
            preloaded_new_biz_notion_pages,
            utilization_by_period[period]
          )
          d[:cash][:okrs] = self.okrs_for_period(period, d[:cash][:datapoints])
          d[:accrual][:datapoints] = self.key_datapoints_for_period(
            period,
            "accrual",
            preloaded_studios,
            preloaded_new_biz_notion_pages,
            utilization_by_period[period]
          )
          d[:accrual][:okrs] = self.okrs_for_period(period, d[:accrual][:datapoints])
          d
        end
        acc
      end
    update!(snapshot: snapshot)
  end

  def okrs_for_period(period, datapoints)
    okr_periods =
      OkrPeriodStudio
        .includes(okr_period: :okr)
        .where(studio: self)
        .select{|ops| ops.applies_to?(period)}
        .map(&:okr_period)
    okr_periods.reduce({}) do |acc, okrp|
      data = datapoints[okrp.okr.datapoint.to_sym]
      acc[okrp.okr.name] = okrp.health_for_value(data[:value]).merge(data)

      # HACK: It's helpful for reinvestment to know how much
      # surplus profit we've made.
      if okrp.okr.datapoint == "profit_margin"
        surplus_usd =
          datapoints[:revenue][:value] * (acc[okrp.okr.name][:surplus]/100)
        acc["Surplus Profit"] = {
          health: acc[okrp.okr.name][:health],
          surplus: surplus_usd,
          value: surplus_usd,
          unit: :usd
        }
      end
      acc
    end
  end

  def new_biz_notion_pages
    if is_garden3d?
      Stacks::Biz.all_cards
    else
      Stacks::Biz.all_cards.select do |c|
        c.get_prop("Studio").map{|s| s.dig("name").downcase}.include?(self.mini_name.downcase)
      end
    end
  end

  def biz_leads_in_period(leads = new_biz_notion_pages, period)
    leads.select do |l|
      period.include?(DateTime.parse(l.data.dig("created_time")).to_date)
    end
  end

  def biz_leads_status_changed_in_period(
    leads = new_biz_notion_pages,
    to_status,
    period
  )
    return nil unless period.has_new_biz_version_history?
    to_status = to_status.kind_of?(Array) ? to_status : [to_status]
    leads.select do |l|
      l.status_history.select do |h|
        period.include?(h[:changed_at]) && to_status.include?(h[:current_status])
      end.any?
    end
  end

  def core_members_active_on(date)
    if is_garden3d?
      AdminUser
        .where(contributor_type: :core)
        .joins(:full_time_periods)
        .where("started_at <= ? AND coalesce(ended_at, 'infinity') >= ?", date, date)
    else
      admin_users
        .where(contributor_type: :core)
        .joins(:full_time_periods)
        .where("started_at <= ? AND coalesce(ended_at, 'infinity') >= ?", date, date)
    end
  end

  def key_meeting_attendance_for_period(period)
    return nil if key_meetings.empty?

    events =
      GoogleCalendarEvent.includes(:google_meet_attendance_records).where(
        summary: key_meetings.map(&:name),
        start: period.starts_at...period.ends_at
      )
    return nil if events.empty?

    arr = events.map(&:attendance_rate)
    arr.inject(0.0) { |sum, el| sum + el } / arr.size
  end

  def studio_members_that_left_during_period(period)
    users =
      (is_garden3d? ? AdminUser : admin_users)
        .includes(:full_time_periods)
        .where(contributor_type: :core)
        .joins(:full_time_periods)
        .where("ended_at >= ? AND coalesce(ended_at, 'infinity') <= ?", period.starts_at, period.ends_at)

    users.select do |u|
      # It's possible that a user has another full time period
      # following the one that ended in this period if their
      # utilization was adjusted or they switched to 4-day work
      # week.

      # However, someone like Alicia who left for a period and
      # returned should be counted in the attrition numbers, so
      # instead, we check that there's not another full_time_period
      # immediately following the one that ended in this period (we
      # give a 7 day window for this).
      last_ending_ftp_in_period = u
        .full_time_periods
        .where("ended_at >= ? AND coalesce(ended_at, 'infinity') <= ?", period.starts_at, period.ends_at)
        .order(started_at: :desc)
        .last
      u.full_time_periods.where(
        "started_at >= ? AND started_at <= ?",
        last_ending_ftp_in_period.ended_at + 1.day,
        last_ending_ftp_in_period.ended_at + 7.days
      ).empty?
    end
  end

  def aggregate_social_growth_for_period(aggregate_social_following, period)
    closest_period_start_date_sample =
      aggregate_social_following.keys.sort.reduce(nil) do |closest, sample_date|
        next closest if sample_date > period.starts_at
        next sample_date if closest.nil?
        closest < sample_date ? sample_date : closest
      end

    closest_period_end_date_sample =
      aggregate_social_following.keys.sort.reduce(nil) do |closest, sample_date|
        next closest if sample_date > period.ends_at
        next sample_date if closest.nil?
        closest < sample_date ? sample_date : closest
      end

    return nil unless closest_period_start_date_sample && closest_period_end_date_sample

    (
      aggregate_social_following[closest_period_end_date_sample] /
      aggregate_social_following[closest_period_start_date_sample]
    ) * 100
  end

  def all_social_properties
    if is_garden3d?
      SocialProperty.all
    else
      social_properties
    end
  end

  def all_mailing_lists
    if is_garden3d?
      MailingList.all
    else
      mailing_lists
    end
  end

  def key_datapoints_for_period(
    period,
    accounting_method,
    preloaded_studios = Studio.all,
    preloaded_new_biz_notion_pages = new_biz_notion_pages,
    utilization_for_period = utilization_for_period(period)
  )
    cogs = period.report.cogs_for_studio(self, accounting_method)
    v = utilization_for_period.reduce(nil) do |acc, tuple|
      fp, data = tuple
      next data if acc.nil?
      acc.merge(data) do |k, old, new|
        old.is_a?(Hash) ? (old.merge(new) {|k, o, n| o+n}) : (old + new)
      end
    end

    aggregate_social_following =
      SocialProperty.aggregate!(all_social_properties)

    leaving_members =
      studio_members_that_left_during_period(period)

    biz_settled_count = 
      biz_leads_status_changed_in_period(preloaded_new_biz_notion_pages, ['Active', 'Passed', 'Lost/Stale'], period).try(:length) || 0
    
    biz_won_count =
      biz_leads_status_changed_in_period(preloaded_new_biz_notion_pages, 'Active', period).try(:length) || 0

    data = {
      attrition: {
        value: leaving_members.map do |m|
          {
            gender_identity_ids: m.gender_identity_ids,
            cultural_background_ids: m.cultural_background_ids,
            racial_background_ids: m.racial_background_ids,
          }
        end,
        unit: :compound
      },
      key_meeting_attendance: {
        value: key_meeting_attendance_for_period(period),
        unit: :percentage
      },
      revenue: {
        value: cogs[:revenue],
        unit: :usd
      },
      payroll: {
        value: cogs[:payroll],
        unit: :usd
      },
      benefits: {
        value: cogs[:benefits],
        unit: :usd
      },
      supplies: {
        value: cogs[:supplies],
        unit: :usd
      },
      expenses: {
        value: cogs[:expenses],
        unit: :usd
      },
      subcontractors: {
        value: cogs[:subcontractors],
        unit: :usd
      },
      profit_margin: {
        value: cogs[:profit_margin],
        unit: :percentage
      },
      biz_leads: {
        value: biz_leads_in_period(preloaded_new_biz_notion_pages, period).length,
        unit: :count
      },
      settled_biz_leads: {
        value: biz_settled_count,
        unit: :count
      },
      total_social_growth: {
        value: aggregate_social_growth_for_period(aggregate_social_following, period),
        unit: :percentage
      },
      biz_win_rate: {
        value: (biz_settled_count > 0) ? ((biz_won_count.to_f / biz_settled_count) * 100) : 0,
        unit: :percentage
      },
      biz_won: {
        value: biz_won_count,
        unit: :count
      },
      biz_passed: {
        value: biz_leads_status_changed_in_period(preloaded_new_biz_notion_pages, 'Passed', period).try(:length),
        unit: :count
      },
      biz_lost: {
        value: biz_leads_status_changed_in_period(preloaded_new_biz_notion_pages, 'Lost/Stale', period).try(:length),
        unit: :count
      },
    }

    data[:sellable_hours] = { unit: :hours, value: nil }
    unless v.nil?
      data[:sellable_hours][:value] = v[:sellable]
    end

    data[:non_sellable_hours] = { unit: :hours, value: nil }
    unless v.nil?
      data[:non_sellable_hours][:value] = v[:non_sellable]
    end

    data[:billable_hours] = { unit: :hours, value: nil }
    unless v.nil?
      total_billable = v[:billable].values.reduce(&:+) || 0
      data[:billable_hours][:value] = total_billable
    end

    data[:non_billable_hours] = { unit: :hours, value: nil }
    unless v.nil?
      data[:non_billable_hours][:value] = v[:non_billable]
    end

    data[:time_off] = { unit: :hours, value: nil }
    unless v.nil?
      data[:time_off][:value] = v[:time_off]
    end

    data[:sellable_hours_sold] = { unit: :percentage, value: nil }
    unless v.nil?
      total_billable = v[:billable].values.reduce(&:+) || 0
      begin
        data[:sellable_hours_sold][:value] = (total_billable / v[:sellable]) * 100
      rescue ZeroDivisionError
        data[:sellable_hours_sold][:value] = 0
      end
    end

    data[:sellable_hours_ratio] = { unit: :percentage, value: nil }
    unless v.nil?
      begin
        data[:sellable_hours_ratio][:value] =
          (v[:sellable] / (v[:sellable] + v[:non_sellable])) * 100
      rescue ZeroDivisionError
        data[:sellable_hours_ratio][:value] = 0
      end
    end

    data[:average_hourly_rate] = { unit: :usd, value: nil }
    unless v.nil?
      data[:average_hourly_rate][:value] =
        Stacks::Utils.weighted_average(v[:billable].map{|k, v| [k.to_f, v]})
    end

    data[:cost_per_sellable_hour] = { unit: :usd, value: nil }
    unless v.nil?
      data[:cost_per_sellable_hour][:value] = cogs[:cogs] / v[:sellable].to_f
    end

    data[:actual_cost_per_hour_sold] = { unit: :usd, value: nil }
    unless v.nil?
      total_billable = v[:billable].values.reduce(&:+) || 0
      data[:actual_cost_per_hour_sold][:value] = cogs[:cogs] / total_billable
    end

    data
  end

  def utilization_for_period(period, preloaded_studios = Studio.all)
    return {} unless period.has_utilization_data?

    forecast_people(preloaded_studios).reduce({}) do |acc, fp|
      acc[fp] = fp.utilization_during_range(
        period.starts_at,
        period.ends_at,
        preloaded_studios
      )

      if fp.admin_user.present?
        # Probably a fulltimer
        d = (period.starts_at..period.ends_at).reduce({
          sellable: 0,
          non_sellable: 0
        }) do |acc, date|
          ftp = fp.admin_user.full_time_period_at(date)
          next acc unless ftp.present?
          is_working_day =
            ftp.multiplier == 0.8 ? (1..4).include?(date.wday) : (1..5).include?(date.wday)
          if is_working_day
            acc[:sellable] += 8 * ftp.expected_utilization
            acc[:non_sellable] += 8 - (8 * ftp.expected_utilization)
          end
          acc
        end
        acc[fp] = acc[fp].merge(d)
      else
        # Probably a contractor
        acc[fp] = acc[fp].merge({
          sellable: acc[fp][:billable].values.reduce(:+) || 0,
          non_sellable: 0
        })
      end
      acc
    end
  end

  def is_garden3d?
    name == "garden3d" && mini_name == "g3d"
  end

  def qbo_sales_category
    return "Total Income" if is_garden3d?
    "[SC] #{accounting_prefix} Services"
  end

  def qbo_payroll_category
    return "Total [SC] Payroll" if is_garden3d?
    "[SC] #{accounting_prefix} Payroll"
  end

  def qbo_benefits_category
    return "Total [SC] Benefits, Contributions & Tax" if is_garden3d?
    "[SC] #{accounting_prefix} Benefits, Contributions & Tax"
  end

  def qbo_supplies_category
    return "Total [SC] Supplies & Materials" if is_garden3d?
    "[SC] #{accounting_prefix} Supplies & Materials"
  end

  def qbo_subcontractors_category
    return "Total [SC] Subcontractors" if is_garden3d?
    "[SC] #{accounting_prefix} Subcontractors"
  end
end
