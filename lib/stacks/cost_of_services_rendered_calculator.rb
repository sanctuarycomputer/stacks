class Stacks::CostOfServicesRenderedCalculator
  def initialize(start_date:, end_date:, forecast_assignments:, studios:)
    @start_date = start_date
    @end_date = end_date
    @forecast_assignments = forecast_assignments
    @studios = studios
  end

  def calculate
    (@start_date..@end_date).reduce({}) do |acc, date|
      @forecast_assignments.each do |assignment|
        hours = assignment.allocation_during_range_in_hours(
          date,
          date,
          only_during_working_days = true
        )

        forecast_person = assignment.forecast_person

        next if hours == 0
        next if forecast_person.blank?

        cost_windows = forecast_person.forecast_person_cost_windows

        cost_window = cost_windows.find do |cost_window|
          cost_window.start_date <= date && cost_window.end_date >= date
        end

        next unless cost_window.present?

        acc[date] ||= {}

        studio = forecast_person.studio(@studios)

        acc[date][studio.id] ||= {
          total_hours: 0,
          total_cost: 0,
          assignment_costs: []
        }

        hourly_cost = cost_window.hourly_cost.to_f

        acc[date][studio.id][:total_hours] += hours
        acc[date][studio.id][:total_cost] += hours * hourly_cost
        acc[date][studio.id][:assignment_costs].push({
          forecast_assignment_id: assignment.forecast_id,
          hourly_cost: hourly_cost,
          hours: hours
        })
      end

      acc
    end
  end
end
