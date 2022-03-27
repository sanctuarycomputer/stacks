class Studio < ApplicationRecord
  has_many :studio_memberships
  has_many :admin_users, through: :studio_memberships

  has_many :studio_coordinator_periods
  accepts_nested_attributes_for :studio_coordinator_periods, allow_destroy: true

  def key_datapoints_for_period(period)
    cogs = period.report.cogs_for_studio(self)
    v = aggregated_utilization(
      utilization_by_people([period])
    ).values.first

    data = {
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
      }
    }

    data[:sellable_hours] = { unit: :hours, value: :no_data }
    unless v.nil?
      data[:sellable_hours][:value] = v[:sellable]
    end

    data[:non_sellable_hours] = { unit: :hours, value: :no_data }
    unless v.nil?
      data[:non_sellable_hours][:value] = v[:non_sellable]
    end

    data[:billable_hours] = { unit: :hours, value: :no_data }
    unless v.nil?
      total_billable = v[:billable].values.reduce(&:+) || 0
      data[:billable_hours][:value] = total_billable
    end

    data[:non_billable_hours] = { unit: :hours, value: :no_data }
    unless v.nil?
      data[:non_billable_hours][:value] = v[:non_billable]
    end

    data[:time_off] = { unit: :hours, value: :no_data }
    unless v.nil?
      data[:time_off][:value] = v[:time_off]
    end

    data[:utilization] = { unit: :percentage, value: :no_data }
    unless v.nil?
      total_billable = v[:billable].values.reduce(&:+) || 0
      data[:utilization][:value] = (total_billable / v[:sellable]) * 100
    end

    data[:average_hourly_rate] = { unit: :usd, value: :no_data }
    unless v.nil?
      data[:average_hourly_rate][:value] =
        Stacks::Utils.weighted_average(v[:billable].map{|k, v| [k.to_f, v]})
    end

    data[:cost_per_sellable_hour] = { unit: :usd, value: :no_data }
    unless v.nil?
      data[:cost_per_sellable_hour][:value] = cogs[:cogs] / v[:sellable].to_f
    end

    data[:actual_cost_per_hour_sold] = { unit: :usd, value: :no_data }
    unless v.nil?
      total_billable = v[:billable].values.reduce(&:+) || 0
      data[:actual_cost_per_hour_sold][:value] = cogs[:cogs] / total_billable
    end

    data
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
        next agr unless period.has_utilization_data?

        agr[period.label] = fp.utilization_during_range(
          period.starts_at,
          period.ends_at,
          Studio.all
        )

        agr[period.label][:report] = period.report

        if fp.admin_user.present?
          working_days = fp.admin_user.working_days_between(
            period.starts_at,
            period.ends_at,
          ).count
          sellable_hours = (working_days * fp.admin_user.expected_utilization * 8)
          non_sellable_hours = (working_days * 8) - sellable_hours
          agr[period.label] = agr[period.label].merge({
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
