module Studios
  module Snapshots
    # Monthly per-person utilization for a studio, from monthly-grain
    # ForecastPersonUtilizationReport rows scoped through the
    # studio_forecast_people projection. Field mapping matches legacy
    # Studio#utilization_for_period exactly. Monthly rows are additive per
    # person, so callers fold quarters / years / trailing windows from these.
    #
    # Rows are plucked, not hydrated: a full studio-history read touches
    # thousands of monthly rows (each with a jsonb rate column), and building
    # an AR object per row dominated call time (~33ms of a ~42ms GradationRows
    # call in profiling). We pluck the six needed columns and hydrate only the
    # handful of ForecastPerson keys once. The returned shape is unchanged:
    # { Date(month) => { ForecastPerson => {time_off:, billable:, non_billable:,
    # non_sellable:, sellable:} } }.
    class UtilizationByMonth
      # Order must match the destructure in `call`.
      COLUMNS = %i[
        forecast_person_id
        starts_at
        actual_hours_time_off
        actual_hours_sold_by_rate
        actual_hours_internal
        expected_hours_unsold
        expected_hours_sold
      ].freeze

      def self.call(studio:, from:, through:)
        rows = ForecastPersonUtilizationReport
          .where(period_gradation: :month)
          .where(starts_at: from.beginning_of_month..through)
          .where(
            forecast_person_id: StudioForecastPerson
              .where(studio_id: studio.id)
              .select(:forecast_person_id)
          )
          .pluck(*COLUMNS)

        return {} if rows.empty?

        # forecast_person_id stores the forecast_id value (ForecastPerson
        # overrides its primary key to forecast_id), so key the lookup by
        # forecast_id — which is also ForecastPerson#id.
        people_by_id = ForecastPerson
          .where(forecast_id: rows.map(&:first).uniq)
          .index_by(&:id)

        rows.each_with_object({}) do |(fp_id, starts_at, time_off, by_rate, internal, unsold, sellable), acc|
          person = people_by_id[fp_id]
          unless person
            # Unreachable today (people are upserted, never deleted; no FK
            # cleanup orphans a row), but if that invariant ever breaks, warn
            # rather than skip silently — a dropped person would otherwise
            # surface only as an unexplained oracle diff.
            Rails.logger.warn(
              "[Studios::Snapshots::UtilizationByMonth] skipping utilization row " \
              "for unknown forecast_person_id=#{fp_id}"
            )
            next
          end
          (acc[starts_at] ||= {})[person] = {
            time_off: time_off,
            billable: by_rate,
            non_billable: internal,
            non_sellable: unsold,
            sellable: sellable,
          }
        end
      end
    end
  end
end
