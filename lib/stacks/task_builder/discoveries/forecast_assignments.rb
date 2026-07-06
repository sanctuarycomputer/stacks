module Stacks
  class TaskBuilder
    module Discoveries
      class ForecastAssignments < Base
        # Recency bound: nobody fixes a rounding error on an assignment from
        # 3 years ago. Historical assignments are not actionable, so we don't
        # surface them as tasks. Also keeps both queries off a full-table
        # scan of millions of rows.
        RECENCY_WINDOW = 60.days

        def tasks
          tasks = []
          window_start = (Date.today - RECENCY_WINDOW)

          # 1) Future-dated assignments (excluding Time Off projects).
          # Bounded above so a "scheduled 2 years out" assignment doesn't
          # nag the dashboard for years.
          ForecastAssignment
            .includes(:forecast_project, forecast_person: :admin_user)
            .where("end_date > ? AND end_date <= ?", Date.today, Date.today + 1.year)
            .each do |fa|
              next if fa.forecast_project&.is_time_off?
              owner = fa.forecast_person&.admin_user
              tasks << task(subject: fa, type: :date_in_future, owners: [owner].compact)
            end

          # 2) Allocations not on a whole-minute boundary, limited to the
          # recency window. The mod() expression isn't indexable, so we lean
          # on the start_date/end_date indexes to keep the scan narrow.
          ForecastAssignment
            .includes(forecast_person: :admin_user)
            .where("end_date >= ?", window_start)
            .where("mod(allocation / 60.0, 1) != 0")
            .each do |fa|
              owner = fa.forecast_person&.admin_user
              tasks << task(subject: fa, type: :allocation_needs_rounding_to_nearest_minute, owners: [owner].compact)
            end

          tasks
        end
      end
    end
  end
end
