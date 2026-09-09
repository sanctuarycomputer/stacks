module Stacks
  class TaskBuilder
    module Discoveries
      # Surfaces the data problems that stop the contributor projection from
      # pricing forward Runn hours (the "skipped assignments" on the payables
      # page), as tasks people can act on. The window and the rules mirror
      # ContributorProjections::Build so a task exists iff the projection
      # would skip something:
      #
      #   runn_project_not_linked_to_project_tracker — a live Runn project has
      #     hours inside the projection horizon but no ProjectTracker, so
      #     nothing on it can be priced. Owners: the project's Runn managers
      #     when they are admin users (rare — most Runn projects carry no
      #     managers, so this usually falls to the admin team).
      #   runn_person_not_in_forecast — a Runn person has hours in the horizon
      #     but resolves to no Contributor by email, so there is no ledger to
      #     pay. Owners: the admin team.
      #   runn_role_rate_mismatch — a billable assignment's Runn role rate
      #     matches none of the tracker's workstream rates, so the projection
      #     is guessing the workstream. Owners: the tracker's project leads.
      #   runn_sync_stale — the mirror has not completed a sync in
      #     ContributorProjections::STALE_AFTER_DAYS; every projection is
      #     showing the stale pill. Owners: the admin team.
      #
      # Placeholders (unfilled seats) never produce a task of any kind.
      class RunnMirror < Base
        def tasks
          horizon = ContributorProjections::Horizon.current
          forward = RunnAssignment.plannable
            .overlapping(horizon.starts_at, horizon.ends_at)
            .where(is_placeholder: false)
            .includes(:runn_project, :runn_person, :runn_role)
            .to_a
            .select { |a| live_project?(a.runn_project) }

          [
            *unlinked_project_tasks(forward),
            *unmatched_person_tasks(forward),
            *rate_mismatch_tasks(forward),
            *stale_sync_tasks,
          ]
        end

        private

        def live_project?(rp)
          rp.present? && !rp.is_archived && !rp.is_template
        end

        def unlinked_project_tasks(forward)
          linked_ids = ProjectTracker.where.not(runn_project_id: nil).pluck(:runn_project_id).to_set
          projects = forward.map(&:runn_project).uniq.reject { |rp| linked_ids.include?(rp.runn_id) }
          return [] if projects.empty?

          manager_ids = projects.flat_map { |rp| Array(rp.data&.dig("managerIds")) }.uniq
          admins_by_runn_person_id = admin_users_by_runn_person_id(manager_ids)

          projects.map do |rp|
            owners = Array(rp.data&.dig("managerIds")).filter_map { |id| admins_by_runn_person_id[id] }
            task(subject: rp, type: :runn_project_not_linked_to_project_tracker, owners: owners)
          end
        end

        # Same identity rule as the engine: a Runn person is "known" only when
        # a Contributor exists for a Forecast person with that email.
        def unmatched_person_tasks(forward)
          people = forward.map(&:runn_person).compact.uniq.reject(&:is_archived)
          return [] if people.empty?

          emails = people.map { |p| p.email.to_s.strip.downcase }.reject(&:blank?)
          known =
            if emails.empty?
              Set.new
            else
              Contributor.joins(:forecast_person).where("lower(forecast_people.email) IN (?)", emails)
                .pluck("forecast_people.email").map { |e| e.to_s.strip.downcase }.to_set
            end

          people
            .reject { |p| known.include?(p.email.to_s.strip.downcase) }
            .map { |p| task(subject: p, type: :runn_person_not_in_forecast, owners: @admin_fallback) }
        end

        def rate_mismatch_tasks(forward)
          billable = forward.select(&:is_billable)
          project_ids = billable.map(&:project_id).compact.uniq
          return [] if project_ids.empty?

          trackers = ProjectTracker.where(runn_project_id: project_ids)
            .includes(:forecast_projects, project_lead_periods: :admin_user)
            .index_by(&:runn_project_id)
          return [] if trackers.empty?

          mismatched = billable.each_with_object({}) do |a, acc|
            tracker = trackers[a.project_id]
            rate = a.runn_role&.standard_rate
            next if tracker.nil? || rate.nil? || tracker.forecast_projects.empty?
            next if tracker.forecast_projects.any? { |ws| ws.hourly_rate.to_f == rate.to_f }
            acc[tracker] = true
          end

          mismatched.keys.map do |tracker|
            task(subject: tracker, type: :runn_role_rate_mismatch, owners: tracker.current_project_leads)
          end
        end

        def stale_sync_tasks
          # ::System — inside the Stacks namespace, bare System is Stacks::System.
          system = ::System.first
          return [] if system.nil?
          return [] unless ContributorProjections.stale?(system.runn_synced_at)

          [task(subject: system, type: :runn_sync_stale, owners: @admin_fallback)]
        end

        # Runn manager ids → the AdminUser with the same email, where one exists.
        def admin_users_by_runn_person_id(runn_person_ids)
          return {} if runn_person_ids.empty?

          people = RunnPerson.where(runn_id: runn_person_ids).to_a
          emails = people.map { |p| p.email.to_s.strip.downcase }.reject(&:blank?)
          admins = emails.empty? ? {} : AdminUser.where("lower(email) IN (?)", emails).index_by { |a| a.email.to_s.strip.downcase }
          people.each_with_object({}) do |p, h|
            admin = admins[p.email.to_s.strip.downcase]
            h[p.runn_id] = admin if admin
          end
        end
      end
    end
  end
end
