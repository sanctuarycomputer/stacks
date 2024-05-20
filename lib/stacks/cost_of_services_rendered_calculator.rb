class Stacks::CostOfServicesRenderedCalculator
  def initialize(start_date:, end_date:, forecast_project_ids:)
    @start_date = start_date
    @end_date = end_date
    @forecast_project_ids = forecast_project_ids
  end

  def calculate
    daily_snapshots = ForecastAssignmentDailyFinancialSnapshot
      .where(forecast_project_id: @forecast_project_ids)
      .order(effective_date: :asc)
      .where(
        "effective_date >=? AND effective_date <= ?",
        @start_date,
        @end_date
      )
      .pluck(
        :forecast_person_id,
        :forecast_assignment_id,
        :effective_date,
        :hours,
        :hourly_cost,
        :studio_id
      )

    (@start_date..@end_date).reduce({}) do |acc, date|
      acc[date] ||= {}

      while daily_snapshots.length > 0
        (
          forecast_person_id,
          forecast_assignment_id,
          effective_date,
          hours,
          hourly_cost,
          studio_id
        ) = daily_snapshots.first

        break if effective_date > date

        daily_snapshots.shift

        acc[date][studio_id] ||= {
          total_hours: 0,
          total_cost: 0,
          assignment_costs: []
        }

        acc[date][studio_id][:total_hours] += hours.to_f
        acc[date][studio_id][:total_cost] += (hours * hourly_cost).to_f

        acc[date][studio_id][:assignment_costs] << {
          forecast_person_id: forecast_person_id,
          forecast_assignment_id: forecast_assignment_id,
          effective_date: date,
          hours: hours,
          hourly_cost: hourly_cost
        }
      end

      acc
    end
  end
end
