module Studios
  module Snapshots
    # Monthly per-person utilization for a studio, from monthly-grain
    # ForecastPersonUtilizationReport rows scoped through the
    # studio_forecast_people projection. Field mapping matches legacy
    # Studio#utilization_for_period exactly. Monthly rows are additive per
    # person, so callers fold quarters / years / trailing windows from these.
    class UtilizationByMonth
      def self.call(studio:, from:, through:)
        ForecastPersonUtilizationReport
          .where(period_gradation: :month)
          .where(starts_at: from.beginning_of_month..through)
          .where(
            forecast_person_id: StudioForecastPerson
              .where(studio_id: studio.id)
              .select(:forecast_person_id)
          )
          .includes(:forecast_person)
          .reduce({}) do |acc, report|
            (acc[report.starts_at] ||= {})[report.forecast_person] = {
              time_off: report.actual_hours_time_off,
              billable: report.actual_hours_sold_by_rate,
              non_billable: report.actual_hours_internal,
              non_sellable: report.expected_hours_unsold,
              sellable: report.expected_hours_sold,
            }
            acc
          end
      end
    end
  end
end
