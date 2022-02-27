class ForecastAssignment < ApplicationRecord
  self.primary_key = "forecast_id"
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "person_id"
  belongs_to :forecast_project, class_name: "ForecastProject", foreign_key: "project_id"

  def value_during_range_in_usd(start_of_range, end_of_range)
    hours =
      (allocation_during_range_in_seconds(
        start_of_range,
        end_of_range
      ) / 60 / 60)
    hours * forecast_project.hourly_rate
  end

  def allocation_in_seconds
    days = if forecast_project.name == "Time Off" && allocation.nil?
        # If this allocation is for the "Time Off" project, filter time on weekends!
        (self.start_date..self.end_date).select { |d| (1..5).include?(d.wday) }.size
      else
        # This allocation is not for "Time Off", so count work done on weekends.
        (self.end_date - self.start_date).to_i + 1
      end
    days = [days, 0].max

    per_day_allocation = (
      allocation.nil? ?
      Stacks::Utilization::EIGHT_HOURS_IN_SECONDS :
      allocation
    )
    (per_day_allocation * days).to_f
  end

  def allocation_in_hours
    allocation_in_seconds / 60 / 60
  end

  def allocation_during_range_in_hours(start_of_range, end_of_range)
    (allocation_during_range_in_seconds(
      start_of_range,
      end_of_range
    ) / 60 / 60)
  end

  def allocation_during_range_in_seconds(start_of_range, end_of_range)
    start_date =
      (self.start_date < start_of_range ? start_of_range : self.start_date)
    end_date =
      (self.end_date > end_of_range ? end_of_range : self.end_date)

    days = if forecast_project.name == "Time Off" && allocation.nil?
        # If this allocation is for the "Time Off" project, filter time on weekends!
        (start_date..end_date).select { |d| (1..5).include?(d.wday) }.size
      else
        # This allocation is not for "Time Off", so count work done on weekends.
        (end_date - start_date).to_i + 1
      end
    days = [days, 0].max

    # Time Off has a nil allocation
    per_day_allocation = (
      allocation.nil? ?
      Stacks::Utilization::EIGHT_HOURS_IN_SECONDS :
      allocation
    )
    (per_day_allocation * days).to_f
  end
end
