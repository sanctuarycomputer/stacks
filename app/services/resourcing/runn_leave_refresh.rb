module Resourcing
  # Nightly mirror of Runn per-person leave into runn_leaves so the
  # get_resourcing_projections read never makes N live per-person calls on the request path.
  class RunnLeaveRefresh
    def initialize(runn: Stacks::Runn.new(max_retries: 5))
      @runn = runn
    end

    def run!
      now = Time.current
      people = @runn.get_people.reject { |p| p["isArchived"] }
      people.each do |person|
        pid = person["id"]
        begin
          periods = @runn.get_leave_for_person(pid)
          RunnLeave.transaction do
            RunnLeave.where(runn_person_id: pid).delete_all
            periods.each do |lp|
              RunnLeave.create!(
                runn_person_id: pid,
                start_date: Date.parse(lp["startDate"].to_s),
                end_date: Date.parse(lp["endDate"].to_s),
                minutes_per_day: lp["minutesPerDay"],
                refreshed_at: now, raw: lp,
              )
            end
          end
        rescue StandardError => e
          Rails.logger.warn("[resourcing] leave mirror refresh failed for person #{pid}: #{e.class}")
          Sentry.capture_exception(e) if defined?(Sentry)
        end
      end
      people.size
    end
  end
end
