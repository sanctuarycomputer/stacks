class Stacks::CostOfServicesRenderedCalculator
  def initialize(start_date:, end_date:, assignments:, cost_windows:, studios:)
    @start_date = start_date
    @end_date = end_date
    @assignments = assignments
    @cost_windows = cost_windows
    @studios = studios
  end

  def calculate
    (@start_date..@end_date).reduce({}) do |acc, date|
      @assignments.each do |assignment|
        hours = assignment.allocation_during_range_in_hours(
          date,
          date,
          only_during_working_days = true
        )

        next if hours == 0

        cost_window = @cost_windows.find do |cost_window|
          next false unless cost_window.forecast_person_id == assignment.forecast_person.id
          next false unless cost_window.started_at <= date && cost_window.ended_at >= date

          true
        end

        next unless cost_window.present?

        acc[date] ||= {}

        studio = assignment.forecast_person.studio(@studios)

        acc[date][studio.id] ||= {
          total_hours: 0,
          total_cost: 0,
          assignment_costs: []
        }

        acc[date][studio.id][:total_hours] += hours
        acc[date][studio.id][:total_cost] += hours * cost_window.hourly_cost
        acc[date][studio.id][:assignment_costs].push({
          forecast_assignment_id: assignment.forecast_id,
          hourly_cost: cost_window.hourly_cost,
          hours: hours
        })
      end

      acc
    end
  end
end
