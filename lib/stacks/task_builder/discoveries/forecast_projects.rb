module Stacks
  class TaskBuilder
    module Discoveries
      class ForecastProjects < Base
        def tasks
          tasks = []

          # Build a fp_forecast_id → ProjectTracker map for owner routing.
          # The join table stores forecast_project_id == ForecastProject.forecast_id.
          ptfps = ProjectTrackerForecastProject.includes(:project_tracker).to_a
          fp_to_pt = ptfps.each_with_object({}) do |ptfp, h|
            h[ptfp.forecast_project_id] = ptfp.project_tracker
          end
          # Preload PT lead associations once for routing.
          ProjectTracker.preload_for_render(fp_to_pt.values.compact.uniq)

          # 1) Forecast projects on completed PTs that aren't archived → needs_archiving
          ProjectTracker.includes(:forecast_projects).complete.each do |pt|
            pt.forecast_projects.each do |fp|
              next if fp.archived?
              owners = pt.current_project_leads + pt.current_account_leads
              tasks << task(subject: fp, type: :needs_archiving, owners: owners)
            end
          end

          # 2) External (non-internal), active forecast projects with rate / linkage issues
          all_external_active = ForecastProject.includes(:forecast_client).active.reject(&:is_internal?)
          linked_fp_ids = ptfps.map(&:forecast_project_id).to_set

          all_external_active.each do |fp|
            linked_pt = fp_to_pt[fp.forecast_id]
            al_owners = linked_pt ? linked_pt.current_account_leads : []

            if fp.has_no_explicit_hourly_rate?
              tasks << task(subject: fp, type: :no_explicit_hourly_rate_set, owners: al_owners)
            end
            if fp.has_multiple_hourly_rates?
              tasks << task(subject: fp, type: :multiple_hourly_rates_set, owners: al_owners)
            end
            if fp.code.present? && !linked_fp_ids.include?(fp.forecast_id)
              # No PT exists yet — the absence IS the problem. Falls back to admins.
              tasks << task(subject: fp, type: :not_linked_to_project_tracker, owners: [])
            end
          end

          tasks
        end
      end
    end
  end
end
