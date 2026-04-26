module Stacks
  class TaskBuilder
    module Discoveries
      class ForecastAssignments < Base
        def tasks
          tasks = []

          # 1) Future-dated assignments (excluding Time Off projects).
          ForecastAssignment
            .includes(:forecast_project, forecast_person: :admin_user)
            .where("end_date > ?", Date.today)
            .each do |fa|
              next if fa.forecast_project&.is_time_off?
              owner = fa.forecast_person&.admin_user
              tasks << task(subject: fa, type: :date_in_future, owners: [owner].compact)
            end

          # 2) Allocations not on a whole-minute boundary.
          ForecastAssignment
            .includes(forecast_person: :admin_user)
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
