class ProjectTracker < ApplicationRecord
  has_many :project_tracker_forecast_projects
  has_many :forecast_projects, through: :project_tracker_forecast_projects
  accepts_nested_attributes_for :project_tracker_forecast_projects, allow_destroy: true

  def hours_billed
    data = {}
    time_start = Date.new(2021, 1, 1)
    time_end = 0.seconds.ago
    time = time_start
    while time < time_end
      year_as_sym = time.strftime("%Y").to_sym
      month_as_sym = time.strftime("%B").downcase.to_sym
      data[year_as_sym] = data[year_as_sym] || {}
      data[year_as_sym][month_as_sym] =
        data[year_as_sym][month_as_sym] || {}

      data[year_as_sym][month_as_sym] = hours_billed_for_month(time)
      time = time.advance(months: 1)
    end
  end

  def hours_billed_for_month(date)
    forecast_project_ids = forecast_projects.map(&:forecast_id)

    forecast = Stacks::Forecast.new
    assignments = forecast.assignments(
      date.beginning_of_month,
      date.end_of_month,
    )["assignments"]

    project_assignments =
      assignments.filter do |a|
        forecast_project_ids.include?(a["project_id"].to_s)
      end

    # TODO: Pickup here
    binding.pry if project_assignments.any?
  end
end
