class ForecastAssignment < ApplicationRecord
  self.primary_key = "forecast_id"
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "person_id"
  belongs_to :forecast_project, class_name: "ForecastProject", foreign_key: "project_id"

  attr_accessor :_qbo_service_item

  def qbo_service_item
    @_qbo_service_item ||= (
      service_name = forecast_person.studio.try(:accounting_prefix)
      qbo_items, default_service_item = Stacks::Quickbooks.fetch_all_items
      qbo_items.find do |s|
        s.fully_qualified_name == service_name
      end || default_service_item
    )
  end

  def raw_resourcing_cost_during_range_in_usd(start_of_range, end_of_range)
    cost = 0
    admin_user = self.forecast_person.try(:admin_user)

    start_of_range.upto(end_of_range) do |date|
      next if date < self.start_date
      next if date > self.end_date

      daily_cost = admin_user ?
        admin_user.cost_of_employment_on_date(date) :
        AdminUser.default_cost_of_employment_on_date(date)

      allocation_hrs = allocation_during_range_in_hours(date, date)
      if allocation_hrs >= 8
        cost += daily_cost
      else
        # Test if there's other billable hours on this day for this person
        # and assign cost proportionally
        other_assignments =
          self.forecast_person.forecast_assignments.where(
            'end_date >= ? AND start_date <= ?', date, date
          ).where.not(forecast_id: self.forecast_id)
        other_billable_assignments =
          other_assignments.reject do |fa|
            fa.forecast_project.forecast_client.nil? || fa.forecast_project.forecast_client.is_internal?
          end
        other_billable_assignments_hrs =
          other_assignments.reduce(0) do |acc, fa|
            acc += fa.allocation_during_range_in_hours(date, date)
            acc
          end
        cost += (daily_cost * (allocation_hrs.to_f / (allocation_hrs + other_billable_assignments_hrs)))
      end
    end
    cost
  end

  def value_in_usd
    allocation_in_hours * forecast_project.hourly_rate
  end

  def value_during_range_in_usd(start_of_range, end_of_range)
    hours =
      (allocation_during_range_in_seconds(
        start_of_range,
        end_of_range
      ) / 60 / 60)
    hours * forecast_project.hourly_rate
  end

  def is_time_off?
    forecast_project.name == "Time Off" && forecast_project.forecast_client.nil?
  end

  def is_non_billable?(preloaded_studios)
    is_time_off? || forecast_project.forecast_client && forecast_project.forecast_client.is_internal?(preloaded_studios)
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
