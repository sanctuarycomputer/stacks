module Stacks
  class TaskBuilder
    module Discoveries
      class ForecastPeople < Base
        def tasks
          ForecastPerson.all.flat_map do |fp|
            next [] if fp.archived
            next [] if fp.studios.count == 1

            type = fp.studios.count.zero? ? :no_studio_in_forecast : :multiple_studios_in_forecast
            # No clear personal owner — this is HR/ops territory. Falls back to admins.
            [task(subject: fp, type: type, owners: [])]
          end
        end
      end
    end
  end
end
