class ForecastPerson < ApplicationRecord
  self.primary_key = "forecast_id"
  has_many :forecast_assignments, class_name: "ForecastAssignment", foreign_key: "person_id"
  has_one :admin_user, class_name: "AdminUser", foreign_key: "email", primary_key: "email"

  def display_name
    email
  end

  def missing_allocation_during_range_in_hours(start_of_range, end_of_range)
    missing =
      expected_allocation_during_range_in_seconds(start_of_range, end_of_range) -
      recorded_allocation_during_range_in_seconds(start_of_range, end_of_range)
    return 0 if missing <= 0
    missing / 60 / 60
  end

  def expected_allocation_during_range_in_seconds(start_of_range, end_of_range)
    business_days = (start_of_range..end_of_range).select { |d| (1..5).include?(d.wday) }.size
    Stacks::System.singleton_class::EIGHT_HOURS_IN_SECONDS * business_days
  end

  def recorded_allocation_during_range_in_seconds(start_of_range, end_of_range)
    forecast_assignments.includes(:forecast_project).where(
      'end_date >= ? AND start_date <= ?', start_of_range, end_of_range
    ).reduce(0) do |acc, fa|
      acc += fa.allocation_during_range_in_seconds(start_of_range, end_of_range)
    end || 0
  end

  def edit_link
    "https://forecastapp.com/864444/team/#{forecast_id}/edit"
  end

  def external_link
    edit_link
  end

  def name
    email
  end

  def sync_utilization_reports!
    Stacks::Period.all.each do |period|
      make_utilization_report_for_period!(period)
    end
  end

  def make_utilization_report_for_period!(period)
    assignments = forecast_assignments
      .includes(forecast_project: :forecast_client, forecast_person: :admin_user)
      .where(
        'end_date >= ? AND start_date <= ?', period.starts_at, period.ends_at
      )

    report = assignments.reduce({
      expected: {
        sellable: 0,
        non_sellable: 0,
      },
      actual: {
        sold: 0, # hours billed to clients
        internal: 0, # internal hours
        time_off: 0, # PTO & UPTO
        sold_by_rate: {},
      }
    }) do |r, fa|
      if fa.is_time_off?
        r[:actual][:time_off] += fa.allocation_during_range_in_hours(
          period.starts_at,
          period.ends_at,
          true
        )
      elsif fa.is_non_billable?
        r[:actual][:internal] += fa.allocation_during_range_in_hours(
          period.starts_at,
          period.ends_at
        )
      else
        r[:actual][:sold] += fa.allocation_during_range_in_hours(
          period.starts_at,
          period.ends_at
        )

        r[:actual][:sold_by_rate][fa.forecast_project.hourly_rate.to_s] =
          r[:actual][:sold_by_rate][fa.forecast_project.hourly_rate.to_s] || 0
        r[:actual][:sold_by_rate][fa.forecast_project.hourly_rate.to_s] +=
          fa.allocation_during_range_in_hours(
            period.starts_at,
            period.ends_at
          )
      end
      r
    end

    if admin_user.present?
      report[:expected] = admin_user.sellable_hours_for_period(period)
    else
      report[:expected][:sellable] = report[:actual][:sold]
    end

    utilization_report = ForecastPersonUtilizationReport.where(
      starts_at: period.starts_at,
      ends_at: period.ends_at,
      forecast_person_id: forecast_id
    ).first_or_initialize

    utilization_rate = ((report[:actual][:sold].to_f / report[:expected][:sellable].to_f) * 100).round(2)
    utilization_rate = 100 if utilization_rate.infinite?

    utilization_report.update!({
      expected_hours_sold: report[:expected][:sellable],
      expected_hours_unsold: report[:expected][:non_sellable],
      actual_hours_sold: report[:actual][:sold],
      actual_hours_internal: report[:actual][:internal],
      actual_hours_time_off: report[:actual][:time_off],
      actual_hours_sold_by_rate: report[:actual][:sold_by_rate],
      utilization_rate: utilization_rate,
    })

    utilization_report
  end

  def utilization_during_range(start_of_range, end_of_range)
    assignments = forecast_assignments
      .includes(forecast_project: :forecast_client, forecast_person: :admin_user)
      .where(
        'end_date >= ? AND start_date <= ?', start_of_range, end_of_range
      )
    assignments.reduce({
      time_off: 0,
      non_billable: 0,
      billable: {},
    }) do |acc, fa|
      if fa.is_time_off?
        acc[:time_off] += fa.allocation_during_range_in_hours(
          start_of_range,
          end_of_range,
          true
        )
      elsif fa.is_non_billable?
        acc[:non_billable] += fa.allocation_during_range_in_hours(
          start_of_range,
          end_of_range
        )
      else
        acc[:billable][fa.forecast_project.hourly_rate.to_s] =
          acc[:billable][fa.forecast_project.hourly_rate.to_s] || 0
        acc[:billable][fa.forecast_project.hourly_rate.to_s] +=
          fa.allocation_during_range_in_hours(
            start_of_range,
            end_of_range
          )
      end
      acc
    end
  end

  def studios(all_studios = Studio.all)
    all_studios.select{|s| roles.include?(s.name)}
  end

  def studio(all_studios = Studio.all)
    studios(all_studios).first
  end
end
