class Studio < ApplicationRecord
  has_many :social_properties
  accepts_nested_attributes_for :social_properties, allow_destroy: true

  has_many :studio_memberships
  has_many :admin_users, through: :studio_memberships

  has_many :studio_coordinator_periods
  accepts_nested_attributes_for :studio_coordinator_periods, allow_destroy: true

  has_many :mailing_lists

  HEALTH = {
    0 => {
      health: :failing,
      value: "🚒 Emergency, Break Glass",
      hint: ""
    }, 
    1 => {
      health: :at_risk,
      value: "😾 White Knuckling",
      hint: ""
    },
    2 => {
      health: :healthy,
      value: "🐻‍❄️ Thinning Ice",
      hint: ""
    },
    3 => {
      health: :exceptional,
      value: "🏝️ Chillin' Island",
      hint: ""
    },
    4 => {
      health: :exceptional,
      value: "🏝️ Chillin' Island",
      hint: ""
    }
  }

  def current_studio_coordinators
    studio_coordinator_periods
      .select{|p| p.started_at <= Date.today && p.ended_at_or_now >= Date.today}
      .map(&:admin_user)
      .select(&:active?)
  end

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
      [:year, :month, :quarter, :trailing_3_months, :trailing_4_months, :trailing_6_months, :trailing_12_months].reduce({
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

    # HACK: Here we use sellable_hours_sold to bolt on
    # another faux OKR that gives an aggregate studio health.
    # We need to do it in this context because it has to look
    # back at multiple periods
    snapshot = 
      [:year, :month, :quarter].reduce(snapshot) do |acc, gradation|
        acc[gradation] = snapshot[gradation].map do |d|
          # We need at least 4 periods to make this datapoint
          idx = snapshot[gradation].index(d)
          if idx < 3
            d[:cash][:okrs]["Health"] = {:health=>nil, :surplus=>0, :unit=>:display, :value=>nil, :hint=>""}
            d[:accrual][:okrs]["Health"] = {:health=>nil, :surplus=>0, :unit=>:display, :value=>nil, :hint=>""}
            next d
          end
          
          # We need to ensure those periods actually have sellable_hours_sold data
          prev_four_periods = [d, snapshot[gradation][idx - 1], snapshot[gradation][idx - 2], snapshot[gradation][idx - 3]]
          unless prev_four_periods.map{|d| d.dig(:cash, :okrs, "Sellable Hours Sold", :value).present? && d.dig(:accrual, :okrs, "Sellable Hours Sold", :value).present? }.all?
            d[:cash][:okrs]["Health"] = {:health=>nil, :surplus=>0, :unit=>:display, :value=>nil, :hint=>""}
            d[:accrual][:okrs]["Health"] = {:health=>nil, :surplus=>0, :unit=>:display, :value=>nil, :hint=>""}
            next d
          end

          health = prev_four_periods
            .map{|d| d.dig(:cash, :okrs, "Sellable Hours Sold", :health) }
            .count{|v| [:exceptional, :healthy].include?(v) }

          d[:cash][:okrs]["Health"] = d[:accrual][:okrs]["Health"] = {
            "hint"=>HEALTH[health][:hint],
            "unit"=>"display",
            "value"=>HEALTH[health][:value],
            "health"=>HEALTH[health][:health],
            "target"=>4,
            "surplus"=>1
          }
          d
        end
        acc
      end

    update!(snapshot: snapshot)
  end

  def okrs_for_period(period, datapoints)
    okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio }}).all
    okrs.reduce({}) do |acc, okr|
      okrps_for_studio = okr.okr_periods
        .select{|okrp| okrp.okr_period_studios.map(&:studio).include?(self)}
        .sort_by{|okrp| okrp.period_starts_at}
      next acc if okrps_for_studio.empty?

      period_range = period.starts_at..period.ends_at
      okrp_candidate = okrps_for_studio.reduce({ overlap_days: nil, okrp: nil }) do |agg, okrp|
        okrp_range = okrp.period_starts_at..okrp.period_ends_at 
        overlap_days = (period_range.to_a & okrp_range.to_a).count
        next { overlap_days: overlap_days, okrp: okrp } if (agg[:overlap_days].nil? || overlap_days >= agg[:overlap_days])
        agg
      end

      data = datapoints[okr.datapoint.to_sym]
      okrp = okrp_candidate[:okrp]
      acc[okr.name] = data
      next acc if okrp.nil?
      
      acc[okr.name] = 
        okrp.health_for_value(data[:value]).merge(data).merge({ hint: hint_for_okr(okr, datapoints) })

      # HACK: It's helpful for reinvestment to know how much
      # surplus profit we've made.
      if okrp.okr.datapoint == "profit_margin"
        target_usd = 
          datapoints[:revenue][:value] * (acc[okrp.okr.name][:target]/100)
        surplus_usd =
          datapoints[:revenue][:value] - datapoints[:cogs][:value]
        acc["Profit"] = {
          health: acc[okrp.okr.name][:health],
          hint: acc[okrp.okr.name][:hint],
          surplus: surplus_usd,
          value: surplus_usd,
          target: target_usd,
          unit: :usd
        }

        target_usd = 
          datapoints[:revenue][:value] * (acc[okrp.okr.name][:target]/100)
        surplus_usd =
          datapoints[:revenue][:value] * (acc[okrp.okr.name][:surplus]/100)
        acc["Surplus Profit"] = {
          health: acc[okrp.okr.name][:health],
          hint: acc[okrp.okr.name][:hint],
          surplus: surplus_usd,
          value: surplus_usd,
          target: target_usd,
          unit: :usd
        }
      end
      acc
    end
  end

  def hint_for_okr(okr, datapoints)
    case okr.datapoint
    when "sellable_hours_sold"
      "#{datapoints[:billable_hours][:value].try(:round, 0)} hrs sold of #{datapoints[:sellable_hours][:value].try(:round, 0)} sellable hrs"
    when "cost_per_sellable_hour"
      "#{ActionController::Base.helpers.number_to_currency(datapoints[:cogs][:value])} spent over #{datapoints[:sellable_hours][:value]} sellable hrs"
    when "profit_margin"
      "#{ActionController::Base.helpers.number_to_currency(datapoints[:cogs][:value])} spent, #{ActionController::Base.helpers.number_to_currency(datapoints[:revenue][:value]  )} earnt"
    when "total_social_growth"
      "#{datapoints[:social_growth_count][:value]} followers added"
    else
      ""
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

  def self.garden3d
    @@g3d_instance ||= Studio.find_by(name: "garden3d", mini_name: "g3d")
  end

  # TODO
  def core_members_active_on(date)
    if is_garden3d?
      AdminUser
        .joins(:full_time_periods)
        .where("started_at <= ? AND coalesce(ended_at, 'infinity') >= ? AND contributor_type IN (0, 1)", date, date)
    else
      admin_users
        .joins(:full_time_periods)
        .where("started_at <= ? AND coalesce(ended_at, 'infinity') >= ? AND contributor_type IN (0, 1)", date, date)
    end
  end

  def studio_members_that_left_during_period(period)
    users =
      (is_garden3d? ? AdminUser : admin_users)
        .includes(:full_time_periods)
        .joins(:full_time_periods)
        .where("ended_at >= ? AND coalesce(ended_at, 'infinity') <= ? AND contributor_type IN (0, 1)", period.starts_at, period.ends_at)

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

    diff = aggregate_social_following[closest_period_end_date_sample] - aggregate_social_following[closest_period_start_date_sample]
    percent_change = ((
      aggregate_social_following[closest_period_end_date_sample].to_f /
      aggregate_social_following[closest_period_start_date_sample].to_f
    ) * 100.0) - 100
    [diff, percent_change]
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

    social_growth_count, social_growth_percentage = 
      aggregate_social_growth_for_period(aggregate_social_following, period)

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
      cogs: {
        value: cogs[:cogs],
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
      social_growth_count: {
        value: social_growth_count,
        unit: :count
      },
      total_social_growth: {
        value: social_growth_percentage,
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
            (ftp.contributor_type == "four_day" && (1..4).include?(date.wday)) || 
            (ftp.contributor_type == "five_day" && (1..5).include?(date.wday))
          if is_working_day
            acc[:sellable] += 8 * ftp.expected_utilization
            acc[:non_sellable] += 8 - (8 * ftp.expected_utilization)
          end
          acc
        end
        acc[fp] = acc[fp].merge(d)
      else
        # Probably a contractor with an external email address
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
