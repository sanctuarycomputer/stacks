class Studio < ApplicationRecord
  has_many :social_properties, dependent: :delete_all
  accepts_nested_attributes_for :social_properties, allow_destroy: true

  has_many :studio_memberships, dependent: :delete_all
  has_many :admin_users, through: :studio_memberships, dependent: :delete_all

  has_many :studio_coordinator_periods, dependent: :delete_all
  accepts_nested_attributes_for :studio_coordinator_periods, allow_destroy: true

  has_many :mailing_lists, dependent: :destroy
  has_many :okr_period_studios, dependent: :delete_all

  enum studio_type: {
    client_services: 0,
    internal: 1,
    reinvestment: 2,
  }

  HEALTH = {
    0 => {
      health: :failing,
      value: "🚒 Emergency, Break Glass",
      hint: "<a href='https://www.notion.so/garden3d/The-Operating-Modes-of-garden3d-6eefbe5c5f5c463bb5e4679f977a46fa?pvs=4#002d71afc74c468381b5f300b81921fb' target='_blank'>Guidance ↗</a>"
    }, 
    1 => {
      health: :at_risk,
      value: "😾 White Knuckling",
      hint: "<a href='https://www.notion.so/garden3d/The-Operating-Modes-of-garden3d-6eefbe5c5f5c463bb5e4679f977a46fa?pvs=4#82d23c1330a240f7aff1a7926efc6e6d' target='_blank'>Guidance ↗</a>"
    },
    2 => {
      health: :at_risk,
      value: "😾 White Knuckling",
      hint: "<a href='https://www.notion.so/garden3d/The-Operating-Modes-of-garden3d-6eefbe5c5f5c463bb5e4679f977a46fa?pvs=4#82d23c1330a240f7aff1a7926efc6e6d' target='_blank'>Guidance ↗</a>"
    },
    3 => {
      health: :healthy,
      value: "🐻‍❄️ Solid Ice",
      hint: "<a href='https://www.notion.so/garden3d/The-Operating-Modes-of-garden3d-6eefbe5c5f5c463bb5e4679f977a46fa?pvs=4#4472c136ff994809b135de8dc7e2a224' target='_blank'>Guidance ↗</a>"
    },
    4 => {
      health: :exceptional,
      value: "🏝️ Chillin' Island",
      hint: "<a href='https://www.notion.so/garden3d/The-Operating-Modes-of-garden3d-6eefbe5c5f5c463bb5e4679f977a46fa?pvs=4#93b1857723fb44a7a9c721cfa597dd6b' target='_blank'>Guidance ↗</a>"
    }
  }

  def ytd_snapshot
    (snapshot["year"].find{|p| p["label"] == "YTD"} || {})
  end

  def health
    (snapshot["month"] || [{}]).last.dig("cash", "okrs", "Health") || {}
  end

  def net_revenue(accounting_method = "cash")
    ytd_snapshot.dig(accounting_method, "datapoints", "net_revenue", "value").try(:to_f)
  end

  def current_studio_coordinators
    studio_coordinator_periods
      .select{|p| p.started_at <= Date.today && p.ended_at_or_now >= Date.today}
      .map(&:admin_user)
      .select(&:active?)
  end

  def sub_studios(preloaded_studios = Studio.all)
    # If this is an "aggregated studio view" (ie, design@garden3d), split and
    # aggregate the sub studios by matching mini_names
    @_sub_studios ||= (preloaded_studios.select{|s| self.mini_name.split(",").map(&:strip).include?(s.mini_name) })
  end

  def forecast_people(preloaded_studios = Studio.all)
    @_forecast_people ||= (
      people =
        ForecastPerson.includes(admin_user: [:studios, :full_time_periods]).all
      return people if is_garden3d?

      people.select do |fp|
        next true if (fp.try(:admin_user).try(:studios) || []).to_a.intersection(sub_studios(preloaded_studios)).any?
        fp.studios.to_a.intersection(sub_studios(preloaded_studios)).any?
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
        
        g3d = preloaded_studios.find(&:is_garden3d?)
        g3d_utilization_by_period  =
          periods.reduce({}) do |acc, period|
            acc[period] = g3d.utilization_for_period(period, preloaded_studios)
            acc
          end

        acc[gradation] = Parallel.map(periods, in_threads: 5) do |period|
          prev_period = periods[0] == period ? nil : periods[periods.index(period) - 1]

          d = {
            label: period.label,
            period_starts_at: period.starts_at.strftime("%m/%d/%Y"),
            period_ends_at: period.ends_at.strftime("%m/%d/%Y"),
            cash: {},
            accrual: {},
            utilization: utilization_by_period[period].transform_keys {|fp| fp.email.blank? ? "#{fp.first_name} #{fp.last_name}" : fp.email }
          }

          d[:cash][:datapoints] = self.key_datapoints_for_period(
            period,
            prev_period,
            "cash",
            preloaded_studios,
            preloaded_new_biz_notion_pages,
            utilization_by_period[period],
            utilization_by_period[prev_period],
            g3d_utilization_by_period[period],
            g3d_utilization_by_period[prev_period]
          )
          d[:cash][:okrs] = self.okrs_for_period(period, d[:cash][:datapoints])
          d[:accrual][:datapoints] = self.key_datapoints_for_period(
            period,
            prev_period,
            "accrual",
            preloaded_studios,
            preloaded_new_biz_notion_pages,
            utilization_by_period[period],
            utilization_by_period[prev_period],
            g3d_utilization_by_period[period],
            g3d_utilization_by_period[prev_period]
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
      [:month].reduce(snapshot) do |acc, gradation|
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
      # surplus profit we've made in the YTD.
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
    when "free_hours"
      "#{datapoints[:free_hours_count][:value].try(:round, 0)} free hrs of #{datapoints[:sellable_hours][:value].try(:round, 0)} sellable hrs"
    when "cost_per_sellable_hour"
      "#{ActionController::Base.helpers.number_to_currency(datapoints[:cogs][:value])} spent over #{datapoints[:sellable_hours][:value]} sellable hrs"
    when "profit_margin"
      "#{ActionController::Base.helpers.number_to_currency(datapoints[:cogs][:value])} spent, #{ActionController::Base.helpers.number_to_currency(datapoints[:revenue][:value]  )} earnt"
    when "total_social_growth"
      "#{datapoints[:social_growth_count][:value]} new followers"
    else
      ""
    end
  end

  def new_biz_notion_pages
    mini_names = mini_name.split(",").map(&:strip)
    if is_garden3d?
      Stacks::Biz.all_cards
    else
      Stacks::Biz.all_cards.select do |c|
        c.get_prop("Studio").map{|s| s.dig("name").downcase}.intersection(mini_names).any?
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

  def skill_levels_on(date)
    core_members_active_on(date).reduce(Marshal.load(Marshal.dump(Review::LEVELS))) do |acc, member|
      level_key = acc.keys.find{|k| acc[k][:name] == member.skill_tree_level_on_date(date)[:name]}
      if level_key
        acc[level_key][:count] ||= 0
        acc[level_key][:count] += 1
      else
        acc[:unknown] ||= { name: :unknown, count: 0 }
        acc[:unknown][:count] += 1
      end
      acc
    end
  end

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
    prev_period,
    accounting_method,
    preloaded_studios = Studio.all,
    preloaded_new_biz_notion_pages = new_biz_notion_pages,
    utilization_for_period = utilization_for_period(period, preloaded_studios), 
    utilization_for_prev_period = utilization_for_period(prev_period, preloaded_studios), 
    g3d_utilization_for_period = preloaded_studios.find(&:is_garden3d?).utilization_for_period(period, preloaded_studios),
    g3d_utilization_for_prev_period = preloaded_studios.find(&:is_garden3d?).utilization_for_period(prev_period, preloaded_studios)
  )
    # TODO: Fix me - right now I return nil if this period predates utilization data OR
    # there's just no one there

    v, g3dv, sellable_hours_proportion = merged_utilization_data(
      utilization_for_period,
      g3d_utilization_for_period
    )

    cogs = period.report.cogs_for_studio(
      self, 
      preloaded_studios,
      accounting_method,
      period.label,
      sellable_hours_proportion,
    )

    if prev_period.present?
      prev_v, prev_g3dv, prev_sellable_hours_proportion = merged_utilization_data(
        utilization_for_prev_period,
        g3d_utilization_for_prev_period
      )

      prev_cogs = prev_period.report.cogs_for_studio(
        self, 
        preloaded_studios,
        accounting_method,
        prev_period.label,
        prev_sellable_hours_proportion,
      )
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
        unit: :usd,
        growth: prev_cogs ? ((cogs[:revenue].to_f / prev_cogs[:revenue].to_f) * 100) - 100 : nil
      },
      payroll: {
        value: cogs[:payroll],
        unit: :usd
      },
      bonuses: {
        value: cogs[:bonuses],
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
      total_expenses: {
        value: cogs[:expenses][:total],
        unit: :usd
      },
      specific_expenses: {
        value: cogs[:expenses][:specific],
        unit: :usd
      },
      unspecified_split_expenses: {
        value: cogs[:expenses][:unspecified_split],
        unit: :usd
      },
      internal_split_expenses: {
        value: cogs[:expenses][:internal_split],
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
      net_revenue: {
        value: cogs[:net_revenue],
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

    data[:free_hours] = { unit: :percentage, value: nil }
    data[:free_hours_count] = { unit: :count, value: nil }
    unless v.nil?
      free_hours_given = v[:billable]["0.0"] || 0
      data[:free_hours][:value] = v[:sellable] == 0 ? 0 : ((free_hours_given / v[:sellable]) * 100) 
      data[:free_hours_count][:value] = free_hours_given
    end

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
        acc[fp] = acc[fp].merge(
          fp.admin_user.sellable_hours_for_period(period)
        )
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

  def merged_utilization_data(
    utilization_for_period,
    g3d_utilization_for_period 
  )
    # TODO: Fix me - right now I return nil if this period predates utilization data OR
    # there's just no one there
    v = utilization_for_period.reduce(nil) do |acc, tuple|
      fp, data = tuple
      next data if acc.nil?
      acc.merge(data) do |k, old, new|
        old.is_a?(Hash) ? (old.merge(new) {|k, o, n| o+n}) : (old + new)
      end
    end

    g3dv = g3d_utilization_for_period.reduce(nil) do |acc, tuple|
      fp, data = tuple
      next data if acc.nil?
      acc.merge(data) do |k, old, new|
        old.is_a?(Hash) ? (old.merge(new) {|k, o, n| o+n}) : (old + new)
      end
    end

    sellable_hours_proportion = nil
    if v.present? && g3dv.present?
      sellable_hours_proportion =  v[:sellable] / g3dv[:sellable]
    end

    [v, g3dv, sellable_hours_proportion]
  end

  def is_garden3d?
    name == "garden3d" && mini_name == "g3d"
  end

  def qbo_sales_categories
    return "Total Income" if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Services"
    end
  end

  def qbo_bonus_categories
    return "Total [SC] Profit Share, Bonuses & Misc" if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Profit Share, Bonuses & Misc"
    end
  end

  def qbo_payroll_categories
    return "Total [SC] Payroll" if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Payroll"
    end
  end

  def qbo_benefits_categories
    return "Total [SC] Benefits, Contributions & Tax" if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Benefits, Contributions & Tax"
    end
  end

  def qbo_supplies_categories
    return "Total [SC] Supplies & Materials" if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Supplies & Materials"
    end
  end

  def qbo_subcontractors_categories
    return "Total [SC] Subcontractors" if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Subcontractors"
    end
  end
end
