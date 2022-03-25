class Studio < ApplicationRecord
  has_many :studio_memberships
  has_many :admin_users, through: :studio_memberships

  def self.okrs
    [{
      name: "Profitability",
      type: :profitability,
      unit: :percentage,
      learn_more_url: "",
    }, {
      name: "Utilization",
      type: :utilization,
      unit: :percentage,
      learn_more_url: "",
    }, {
      name: "Average Hourly Rate",
      type: :average_hourly_rate,
      unit: :usd,
      learn_more_url: "",
    }, {
      name: "Cost per Sellable Hour",
      type: :cost_per_sellable_hour,
      unit: :usd,
      learn_more_url: "",
    }]
  end

  def okrs
    periods = [{
      label: :last_month,
      starts_at: Date.today.last_month.beginning_of_month,
      ends_at: Date.today.last_month.end_of_month,
    }, {
      label: :last_quarter,
      starts_at: Date.today.last_quarter.beginning_of_quarter,
      ends_at: Date.today.last_quarter.end_of_quarter,
    }, {
      label: :last_year,
      starts_at: Date.today.last_year.beginning_of_year,
      ends_at: Date.today.last_year.end_of_year,
    }].map do |period|
      period[:report] = QboProfitAndLossReport.find_or_fetch_for_range(
        period[:starts_at],
        period[:ends_at]
      )
      period
    end

    Studio.okrs.map do |okr|
      base = okr.clone
      periods.each do |period|
        base[period[:label]] = make_okr(okr[:type], period)
      end
      base
    end
  end

  def make_okr(okr_name, period)
    v = aggregated_utilization(
      utilization_by_people([period])
    ).values.first
    cogs = period[:report].cogs_for_studio(self)

    case okr_name
    when :profitability
      {
        value: ((cogs[:net_revenue] / cogs[:revenue]) * 100),
        health: 0
      }
    when :utilization
      return { value: :no_data, health: :unknown } if v.nil?
      total_billable = v[:billable].values.reduce(&:+) || 0
      {
        value: (total_billable / v[:sellable]) * 100,
        health: 0
      }
    when :average_hourly_rate
      return { value: :no_data, health: :unknown } if v.nil?
      {
        value: Stacks::Utils.weighted_average(v[:billable].map{|k, v| [k.to_f, v]}),
        health: 0
      }
    when :cost_per_sellable_hour
      return { value: :no_data, health: :unknown } if v.nil?
      {
        value: (cogs[:cogs] / v[:sellable].to_f),
        health: 0
      }
    end
  end

  # TODO: Should we be including Time Off for 4-day workers
  # in the Time Off count?
  def utilization_by_people(periods)
    preloaded_studios = Studio.all

    ForecastPerson.includes(admin_user: :studios).all.select do |fp|
      next true if is_garden3d? && fp.admin_user.present?
      (fp.try(:admin_user).try(:studios) || []).include?(self)
    end.reduce({}) do |acc, fp|
      acc[fp] = periods.reduce({}) do |agr, period|
        next agr if (
          period[:starts_at] < Stacks::System.singleton_class::UTILIZATION_START_AT
        )

        agr[period[:label]] = fp.utilization_during_range(
          period[:starts_at],
          period[:ends_at],
          Studio.all
        )

        agr[period[:label]][:report] = period[:report]

        if fp.admin_user.present?
          working_days = fp.admin_user.working_days_between(
            period[:starts_at],
            period[:ends_at],
          ).count
          sellable_hours = (working_days * fp.admin_user.expected_utilization * 8)
          non_sellable_hours = (working_days * 8) - sellable_hours
          agr[period[:label]] = agr[period[:label]].merge({
            sellable: sellable_hours,
            non_sellable: non_sellable_hours
          })
        end

        agr
      end
      acc
    end
  end

  def aggregated_utilization(utilization_by_people_data)
    utilization_by_people_data.values.reduce({}) do |acc, periods|
      periods.each do |label, data|
        next acc[label] = data unless acc[label].present?
        acc[label] = acc[label].merge(data) do |k, old, new|
          if old.is_a?(Hash)
            old.merge(new) {|k, o, n| o+n}
          elsif old.is_a?(QboProfitAndLossReport)
            old
          else
            old + new
          end
        end
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

  def qbo_expenses_category
    return "Total Expenses" if is_garden3d?
    "[SC] #{accounting_prefix} Supplies & Materials"
  end

  def qbo_subcontractors_category
    return "Total [SC] Subcontractors" if is_garden3d?
    "[SC] #{accounting_prefix} Subcontractors"
  end
end
