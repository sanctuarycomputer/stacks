module Stacks
  class TaskBuilder
    module Discoveries
      class ProjectTrackers < Base
        def tasks
          all = ProjectTracker.includes([
            :old_deal_project_lead_periods,
            :adhoc_invoice_trackers,
            :forecast_projects,
          ]).to_a
          ProjectTracker.preload_for_render(all)

          all.flat_map do |pt|
            issues_for(pt).map do |type|
              task(subject: pt, type: type, owners: owners_for(pt, type))
            end
          end
        end

        private

        def issues_for(pt)
          out = []
          if pt.work_completed_at.nil?
            out << :no_project_lead_set if pt.current_project_leads.empty?
            out << :no_account_lead_set if pt.current_account_leads.empty?
            out << :likely_should_mark_as_work_complete? if pt.likely_should_be_marked_as_completed?
          else
            out << :project_capsule_incomplete if pt.work_status == :capsule_pending
          end
          out
        end

        def owners_for(pt, type)
          case type
          when :project_capsule_incomplete
            pt.current_project_leads
          when :likely_should_mark_as_work_complete?
            # AL owns the call to mark a project complete — they're closer to
            # the client/billing side and PLs often miss the close-out window.
            pt.current_account_leads
          when :no_project_lead_set
            pt.current_account_leads
          when :no_account_lead_set
            pt.current_project_leads
          end
        end
      end
    end
  end
end
