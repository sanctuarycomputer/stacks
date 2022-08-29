class ForecastPerson < ApplicationRecord
  self.primary_key = "forecast_id"
  has_many :forecast_assignments, class_name: "ForecastAssignment", foreign_key: "person_id"
  has_one :admin_user, class_name: "AdminUser", foreign_key: "email", primary_key: "email"

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

  def utilization_during_range(start_of_range, end_of_range, preloaded_studios)
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
        )
      elsif fa.is_non_billable?(preloaded_studios)
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

  def studios(preloaded_studios = Studio.all)
    preloaded_studios.select{|s| roles.include?(s.name)}
  end

  def studio(preloaded_studios = Studio.all)
    studios(preloaded_studios).first
  end
end
