module Stacks
  class TaskBuilder
    module Discoveries
      class ProjectTrackers < Base
        def tasks
          all = ProjectTracker.includes([
            :old_deal_project_lead_periods,
            :adhoc_invoice_trackers,
            :project_tracker_links,
            # internal_client? reads each Forecast project's client.
            { forecast_projects: :forecast_client },
            { project_capsule: :project_satisfaction_survey },
            { account_lead_periods: :admin_user },
            { project_lead_periods: :admin_user },
          ]).to_a
          # current_project_leads / current_account_leads call
          # period_started_at, which falls back to first_recorded_assignment
          # per tracker when the lead period's started_at is nil. Cache the
          # edge dates in one batched DISTINCT ON query so we don't fire N+1
          # queries against forecast_assignments.
          ProjectTracker.batch_cache_edge_recorded_assignments!(all)

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
            # The project log reads what Stacksbot sees in the project's Twist
            # channel and files it under the project's Notion page. Asked only
            # of live client work: a dormant tracker has nothing to watch.
            if in_progress_ids.include?(pt.id) && !pt.internal_client?
              out << :project_sources_not_linked if pt.twist_channel_id.nil? || !notion_project_ids.include?(pt.notion_project_id)
              out << :stacksbot_not_in_twist_channel if pt.twist_channel_id.present? && pt.twist_channel_accessible == false
            end
          else
            out << :project_capsule_incomplete if pt.work_status == :capsule_pending
            out << :project_capsule_needs_admin_sign_off if pt.project_capsule&.complete_but_for_admin_sign_off?
          end
          out
        end

        def in_progress_ids
          @in_progress_ids ||= ProjectTracker.in_progress.pluck(:id).to_set
        end

        # Ids of Notion Projects pages that still exist (the sync soft-deletes
        # a page removed from Notion).
        def notion_project_ids
          @notion_project_ids ||= NotionPage.projects.pluck(:notion_id).to_set
        end

        def owners_for(pt, type)
          case type
          when :project_capsule_incomplete
            pt.current_project_leads
          when :project_capsule_needs_admin_sign_off
            # Empty → Base#task falls back to AdminUser.admin. Admins own the call.
            []
          when :likely_should_mark_as_work_complete?
            # AL owns the call to mark a project complete — they're closer to
            # the client/billing side and PLs often miss the close-out window.
            pt.current_account_leads
          when :no_project_lead_set
            pt.current_account_leads
          when :no_account_lead_set
            pt.current_project_leads
          when :project_sources_not_linked
            pt.current_project_leads
          when :stacksbot_not_in_twist_channel
            # Admins manage Twist membership.
            []
          end
        end
      end
    end
  end
end
