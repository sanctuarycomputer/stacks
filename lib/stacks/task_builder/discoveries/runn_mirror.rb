module Stacks
  class TaskBuilder
    module Discoveries
      # Surfaces the data problems that stop the contributor projection from
      # pricing forward Runn hours (the "skipped assignments" on the payables
      # page), as tasks people can act on:
      #
      #   runn_project_not_linked_to_project_tracker — a live Runn project has
      #     forward hours but no ProjectTracker, so nothing on it can be priced.
      #     Owners: the project's Runn managers when they are admin users,
      #     else the admin team.
      #   runn_person_not_in_forecast — a Runn person has forward hours but
      #     their email matches no ForecastPerson, so there is no contributor
      #     to pay. Owners: the admin team.
      #   runn_role_rate_mismatch — a forward assignment's Runn role rate
      #     matches none of the tracker's workstream rates, so the projection
      #     is guessing the workstream. Owners: the tracker's project leads.
      #   runn_sync_stale — the mirror has not completed a sync in
      #     ContributorProjections::STALE_AFTER_DAYS; every projection is
      #     showing the stale pill. Owners: the admin team.
      #
      # Placeholders (unfilled seats) are deliberately not tasks.
      class RunnMirror < Base
        def tasks
          today = Date.today
          forward = RunnAssignment.plannable
            .where("end_date >= ?", today)
            .includes(:runn_project, :runn_person, :runn_role)
            .to_a

          [
            *unlinked_project_tasks(forward),
            *unmatched_person_tasks(forward),
            *rate_mismatch_tasks(forward),
            *stale_sync_tasks,
          ]
        end

        private

        def unlinked_project_tasks(forward)
          linked_ids = ProjectTracker.where.not(runn_project_id: nil).pluck(:runn_project_id).to_set
          projects = forward.map(&:runn_project).compact.uniq
            .reject { |rp| rp.is_archived || rp.is_template || linked_ids.include?(rp.runn_id) }
          return [] if projects.empty?

          manager_ids = projects.flat_map { |rp| Array(rp.data&.dig("managerIds")) }.uniq
          admins_by_runn_person_id = admin_users_by_runn_person_id(manager_ids)

          projects.map do |rp|
            owners = Array(rp.data&.dig("managerIds")).filter_map { |id| admins_by_runn_person_id[id] }
            task(subject: rp, type: :runn_project_not_linked_to_project_tracker, owners: owners)
          end
        end

        def unmatched_person_tasks(forward)
          people = forward.reject(&:is_placeholder).map(&:runn_person).compact.uniq.reject(&:is_archived)
          return [] if people.empty?

          emails = people.map { |p| p.email.to_s.strip.downcase }.reject(&:blank?)
          known = ForecastPerson.where("lower(email) IN (?)", emails).pluck(:email).map { |e| e.to_s.strip.downcase }.to_set

          people
            .reject { |p| known.include?(p.email.to_s.strip.downcase) }
            .map { |p| task(subject: p, type: :runn_person_not_in_forecast, owners: @admin_fallback) }
        end

        def rate_mismatch_tasks(forward)
          project_ids = forward.map(&:project_id).compact.uniq
          trackers = ProjectTracker.where(runn_project_id: project_ids)
            .includes(:forecast_projects, project_lead_periods: :admin_user)
            .index_by(&:runn_project_id)
          return [] if trackers.empty?

          mismatched = forward.each_with_object({}) do |a, acc|
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
