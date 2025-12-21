class Studio < ApplicationRecord
  has_many :studio_memberships, dependent: :delete_all
  has_many :admin_users, through: :studio_memberships, dependent: :delete_all

  has_many :mailing_lists, dependent: :destroy
  has_many :okr_period_studios, dependent: :delete_all

  has_many :survey_studios
  has_many :surveys, through: :survey_studios

  enum studio_type: {
    client_services: 0,
    internal: 1,
    reinvestment: 2,
    collective: 3,
  }

  def ytd_snapshot
    (snapshot["year"].find{|p| p["label"] == "YTD"} || {})
  end

  def last_year_snapshot
    (snapshot["year"].find{|p| p["label"] == (Date.today.year - 1).to_s} || {})
  end

  def net_revenue(accounting_method = "cash", date = Date.today)
    rel_snapshot = ytd_snapshot
    if date.year != Date.today.year
      rel_snapshot = snapshot["year"].find{|s| s["label"] == "#{date.year}"}
    end
    rel_snapshot.dig(accounting_method, "datapoints", "net_revenue", "value").try(:to_f)
  end

  def forecast_people(all_studios = Studio.all)
    @_forecast_people ||= (
      people =
        ForecastPerson.includes(admin_user: [:studios, :full_time_periods]).all
      return people if is_garden3d?
      people.select do |fp|
        next true if fp.admin_user&.studios&.include?(self)
        fp.studios(all_studios).include?(self)
      end
    )
  end

  def generate_snapshot!(
    preloaded_studios = Studio.all,
    preloaded_new_biz_leads = new_biz_leads
  )
    all_forecast_people = forecast_people(preloaded_studios)
    all_okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio }}).all

    snapshot =
      [:year, :month, :quarter, :trailing_3_months, :trailing_4_months, :trailing_6_months, :trailing_12_months].reduce({
        started_at: DateTime.now.iso8601,
      }) do |acc, gradation|
        periods = Stacks::Period.for_gradation(gradation)

        utilization_by_period =
          periods.reduce({}) do |acc, period|
            acc[period] = utilization_for_period(period, all_forecast_people)
            acc
          end

        g3d = preloaded_studios.find(&:is_garden3d?)
        g3d_utilization_by_period  =
          periods.reduce({}) do |acc, period|
            acc[period] = g3d.utilization_for_period(period, preloaded_studios)
            acc
          end

        acc[gradation] = Parallel.map(periods, in_threads: 6) do |period|
          prev_period = periods[0] == period ? nil : periods[periods.index(period) - 1]

          d = {
            label: period.label,
            period_starts_at: period.starts_at.strftime("%m/%d/%Y"),
            period_ends_at: period.ends_at.strftime("%m/%d/%Y"),
            cash: {},
            accrual: {},
            utilization: utilization_by_period[period].transform_keys {|fp| fp.email.blank? ? "#{fp.first_name} #{fp.last_name}" : fp.email }
          }

          # When we run garden3d, we want to give the end user the option to show OKRs with and
          # without the reinvestment studios factored in. These passess do that for us.
          if is_garden3d?
            cash_base_datapoints, cash_datapoints_excluding_reinvestment = self.key_datapoints_for_period(
              period,
              prev_period,
              "cash",
              preloaded_studios,
              preloaded_new_biz_leads,
              utilization_by_period[period],
              utilization_by_period[prev_period],
              g3d_utilization_by_period[period],
              g3d_utilization_by_period[prev_period],
            )
            d[:cash][:datapoints] = cash_base_datapoints
            d[:cash][:okrs] = self.okrs_for_period(period, d[:cash][:datapoints], all_okrs)
            d[:cash][:datapoints_excluding_reinvestment] = cash_datapoints_excluding_reinvestment
            d[:cash][:okrs_excluding_reinvestment] = self.okrs_for_period(period, d[:cash][:datapoints_excluding_reinvestment], all_okrs)

            accrual_base_datapoints, accrual_datapoints_excluding_reinvestment = self.key_datapoints_for_period(
              period,
              prev_period,
              "accrual",
              preloaded_studios,
              preloaded_new_biz_leads,
              utilization_by_period[period],
              utilization_by_period[prev_period],
              g3d_utilization_by_period[period],
              g3d_utilization_by_period[prev_period],
            )
            d[:accrual][:datapoints] = accrual_base_datapoints
            d[:accrual][:okrs] = self.okrs_for_period(period, d[:accrual][:datapoints], all_okrs)
            d[:accrual][:datapoints_excluding_reinvestment] = accrual_datapoints_excluding_reinvestment
            d[:accrual][:okrs_excluding_reinvestment] = self.okrs_for_period(period, d[:accrual][:datapoints_excluding_reinvestment], all_okrs)
          else
            d[:cash][:datapoints] = self.key_datapoints_for_period(
              period,
              prev_period,
              "cash",
              preloaded_studios,
              preloaded_new_biz_leads,
              utilization_by_period[period],
              utilization_by_period[prev_period],
              g3d_utilization_by_period[period],
              g3d_utilization_by_period[prev_period],
            ).first # The first scenario is base
            d[:cash][:okrs] = self.okrs_for_period(period, d[:cash][:datapoints], all_okrs)

            d[:accrual][:datapoints] = self.key_datapoints_for_period(
              period,
              prev_period,
              "accrual",
              preloaded_studios,
              preloaded_new_biz_leads,
              utilization_by_period[period],
              utilization_by_period[prev_period],
              g3d_utilization_by_period[period],
              g3d_utilization_by_period[prev_period],
            ).first # The first scenario is base
            d[:accrual][:okrs] = self.okrs_for_period(period, d[:accrual][:datapoints], all_okrs)
          end

          d
        end
        acc[:finished_at] = DateTime.now.iso8601
        acc
      end

    update!(snapshot: snapshot)
  end

  def okrs_for_period(period, datapoints, okrs)
    okrs.reduce({}) do |acc, okr|
      # Find all OKR periods that are associated with this studio
      okrps_for_studio = okr.okr_periods
        .select{|okrp| okrp.okr_period_studios.map(&:studio).include?(self)}
        .sort_by{|okrp| okrp.period_starts_at}
      next acc if okrps_for_studio.empty?

      # Find the OKR period that has the most overlap with the period
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
        okrp.health_for_value(data[:value], period.total_days)
          .merge(data)
          .merge({ hint: hint_for_okr(okr, datapoints) })

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
    when "time_to_merge_pr"
      "#{datapoints[:prs_merged][:value].try(:round, 0)} PRs merged, taking #{datapoints[:time_to_merge_pr][:value].try(:round, 2)} days (average)"
    when "story_points_per_billable_week"
      "#{datapoints[:story_points][:value].try(:round, 0)} story points closed, #{((datapoints[:billable_hours][:value] || 0) / 40.0).try(:round, 2)} weeks sold"
    when "cost_per_story_point"
      "#{ActionController::Base.helpers.number_to_currency(datapoints[:cogs][:value])} spent, #{datapoints[:story_points][:value].try(:round, 0)} story points closed"
    when "sellable_hours_sold"
      "#{datapoints[:billable_hours][:value].try(:round, 0)} hrs sold of #{datapoints[:sellable_hours][:value].try(:round, 0)} sellable hrs"
    when "free_hours"
      "#{datapoints[:free_hours_count][:value].try(:round, 0)} free hrs of #{datapoints[:sellable_hours][:value].try(:round, 0)} sellable hrs"
    when "profit_margin"
      "#{ActionController::Base.helpers.number_to_currency(datapoints[:cogs][:value])} spent, #{ActionController::Base.helpers.number_to_currency(datapoints[:revenue][:value])} earnt"
    when "revenue_growth"
      "#{ActionController::Base.helpers.number_to_currency(datapoints[:revenue][:value])} revenue recieved"
    when "lead_growth"
      "#{datapoints[:lead_count][:value]} leads recieved"
    else
      ""
    end
  end

  def new_biz_leads
    @_new_biz_leads ||= (
      leads = NotionPage.lead.map(&:as_lead)
      mini_names = mini_name.split(",").map(&:strip)

      if is_garden3d?
        leads
      else
        leads.select do |l|
          studios = l.get_prop_value("studio")
          studios.find{|s| s["name"] == self.name} if studios.present?
        end
      end
    )
  end

  def project_trackers_with_recorded_time_in_period(period, all_studios = Studio.all)
    assignments =
      ForecastAssignment
        .includes(
          forecast_person: [:admin_user],
          forecast_project: [:forecast_client]
        ).where(
          'end_date >= ? AND start_date <= ? AND person_id in (?)',
          period.starts_at,
          period.ends_at,
          forecast_people(all_studios).map(&:forecast_id)
        )

    forecast_projects = assignments.map(&:forecast_project).uniq.reject do |fp|
      fp.is_internal?
    end

    ProjectTrackerForecastProject
      .includes(:project_tracker)
      .where(forecast_project_id: forecast_projects.map(&:forecast_id))
      .map(&:project_tracker)
      .uniq
  end

  def leads_recieved_in_period(leads = new_biz_leads, period)
    leads.select do |l|
      next false unless l.received_at
      period.include?(DateTime.parse(l.received_at).to_date)
    end
  end

  def sent_proposals_settled_in_period(leads = new_biz_leads, period)
    leads.select do |l|
      next false unless (l.settled_at && l.proposal_sent_at)
      period.include?(DateTime.parse(l.settled_at).to_date)
    end
  end

  def self.garden3d
    Studio.find_by(name: "garden3d", mini_name: "g3d")
  end

  def self.all_studios
    @all_studios ||= Studio.all
  end

  def core_members_active_on(date)
    if is_garden3d?
      AdminUser
        .includes(:forecast_person)
        .joins(:full_time_periods)
        .where("
          full_time_periods.started_at <= :date AND
          coalesce(full_time_periods.ended_at, 'infinity') >= :date AND
          full_time_periods.contributor_type IN (0, 1)
        ", { date: date }).distinct
    else
      admin_users
        .includes(:forecast_person)
        .joins(:full_time_periods, :studio_memberships)
        .where("
          full_time_periods.started_at <= :date AND
          coalesce(full_time_periods.ended_at, 'infinity') >= :date AND
          full_time_periods.contributor_type IN (0, 1) AND
          studio_memberships.started_at <= :date AND
          coalesce(studio_memberships.ended_at, 'infinity') >= :date AND
          studio_memberships.studio_id = :studio_id
        ", { date: date, studio_id: self.id }).distinct
    end
  end

  def key_datapoints_for_period(
    period,
    prev_period,
    accounting_method,
    preloaded_studios = Studio.all,
    preloaded_new_biz_leads = new_biz_leads,
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

    cogs_scenarios = period.report.cogs_for_studio(
      self,
      preloaded_studios,
      accounting_method,
      period.label,
      sellable_hours_proportion
    )

    leads_recieved = leads_recieved_in_period(preloaded_new_biz_leads, period)

    if prev_period.present?
      prev_v, prev_g3dv, prev_sellable_hours_proportion = merged_utilization_data(
        utilization_for_prev_period,
        g3d_utilization_for_prev_period
      )

      prev_cogs_scenarios = prev_period.report.cogs_for_studio(
        self,
        preloaded_studios,
        accounting_method,
        prev_period.label,
        prev_sellable_hours_proportion
      )

      prev_leads_recieved = leads_recieved_in_period(preloaded_new_biz_leads, prev_period)
    end

    all_projects = project_trackers_with_recorded_time_in_period(period, preloaded_studios)

    all_proposals = sent_proposals_settled_in_period(preloaded_new_biz_leads, period)
    latest_survey_closed =
      surveys.where.not(closed_at: nil).order(closed_at: :desc).find do |s|
        # Assume we only do one of these a year, and it's results apply for that full year
        s.closed_at.beginning_of_year <= period.starts_at
      end

    cogs_scenarios.map.with_index do |cogs, idx|
      prev_cogs = prev_cogs_scenarios[idx] if prev_cogs_scenarios.present?

      data = {
        revenue: {
          value: cogs[:revenue],
          unit: :usd,
          growth: prev_cogs ? ((cogs[:revenue].to_f / prev_cogs[:revenue].to_f) * 100) - 100 : nil
        },
        revenue_growth: {
          value: prev_cogs ? ((cogs[:revenue].to_f / prev_cogs[:revenue].to_f) * 100) - 100 : nil,
          unit: :percentage
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
        lead_count: {
          value: leads_recieved.length,
          unit: :count,
          growth: prev_period ? ((leads_recieved.length.to_f / prev_leads_recieved.length.to_f) * 100) - 100 : nil
        },
        lead_growth: {
          value: prev_period ? ((leads_recieved.length.to_f / prev_leads_recieved.length.to_f) * 100) - 100 : nil,
          unit: :percentage
        },
        total_projects: {
          value: all_projects.count,
          unit: :count
        },
        successful_projects: {
          value: ((all_projects.map(&:considered_successful?).count{|v| !!v} / all_projects.count.to_f) * 100),
          unit: :percentage
        },
        successful_proposals: {
          value: ((all_proposals.map(&:considered_successful?).count{|v| !!v} / all_proposals.count.to_f) * 100),
          unit: :percentage
        },
        workplace_satisfaction: {
          value: latest_survey_closed.try(:results).try(:dig, :overall),
          unit: :count
        }
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
  end

  def utilization_for_period(period, forecast_people)
    return {} unless period.has_utilization_data?

    ForecastPersonUtilizationReport.where(
      forecast_person_id: forecast_people.map(&:id),
      starts_at: period.starts_at,
      ends_at: period.ends_at
    ).includes(:forecast_person).reduce({}) do |acc, report|
      acc[report.forecast_person] = {
        time_off: report.actual_hours_time_off,
        billable: report.actual_hours_sold_by_rate,
        non_billable: report.actual_hours_internal, # Internal
        non_sellable: report.expected_hours_unsold,
        sellable: report.expected_hours_sold,
      }
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

  def is_sanctuary?
    name == "Sanctuary Computer" && mini_name == "sanctu"
  end

  def qbo_sales_categories
    return ["Total Income"] if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Services"
    end
  end

  def qbo_bonus_categories
    return ["Total [SC] Profit Share, Bonuses & Misc"] if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Profit Share, Bonuses & Misc"
    end
  end

  def qbo_payroll_categories
    return ["Total [SC] Payroll"] if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Payroll"
    end
  end

  def qbo_benefits_categories
    return ["Total [SC] Benefits, Contributions & Tax"] if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Benefits, Contributions & Tax"
    end
  end

  def qbo_supplies_categories
    return ["Total [SC] Supplies & Materials"] if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Supplies & Materials"
    end
  end

  def qbo_subcontractors_categories
    return ["Total [SC] Subcontractors"] if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "[SC] #{p} Subcontractors"
    end
  end
end
