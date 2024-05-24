class Stacks::Notifications
  class << self
    include Rails.application.routes.url_helpers

    def twist
      @_twist ||= Stacks::Twist.new
    end

    def notion
      @_notion ||= Stacks::Notion.new
    end

    def forecast
      @_forecast ||= Stacks::Forecast.new
    end

    def make_notifications!
      # TODO Forecast Client with malformed term?
      notifications = []

      finalizations = Finalization
        .includes(review: :workspace)
        .includes(:workspace)
        .all
      forecast_projects = ForecastProject.includes(:forecast_client).active.reject(&:is_internal?)
      forecast_clients = Stacks::System.clients_served_since(Date.today - 3.months, Date.today)
      forecast_people = ForecastPerson.all

      twist_users = twist.get_workspace_users.parsed_response
      notion_users = notion.get_users
      sanctu_google_users = Stacks::Team
        .fetch_from_google_workspace("sanctuary.computer")
        .map{|u| u.emails.find{|e| e["primary"]}.dig("address")}
      xxix_google_users = Stacks::Team
        .fetch_from_google_workspace("xxix.co")
        .map{|u| u.emails.find{|e| e["primary"]}.dig("address")}
      google_users = [*sanctu_google_users, *xxix_google_users]
      latest_forecast_people = forecast.people["people"]

      users = AdminUser
        .includes([
          :full_time_periods,
          :admin_user_racial_backgrounds,
          :racial_backgrounds,
          :admin_user_cultural_backgrounds,
          :cultural_backgrounds,
          :admin_user_gender_identities,
          :gender_identities,
        ]).not_ignored

      user_accounts_report =
        users.reduce({
          active: {},
          archived: {}
        }) do |acc, u|
          twist_user = twist_users.find{|t| t["email"] == u.email}
          forecast_user = latest_forecast_people.find{|p| p["email"] == u.email}
          report = {
            twist: twist_user ? !twist_user["removed"] : false,
            notion: notion_users["results"].find{|r| r.dig("person", "email") == u.email}.present?,
            google: google_users.find{|e| e == u.email}.present?,
            forecast: forecast_user ? !forecast_user["archived"] : false,
          }
          u.active? ? acc[:active][u] = report : acc[:archived][u] = report
          acc
        end

      active_users_with_inactive_accounts =
        user_accounts_report[:active].select do |u, accounts|
          accounts.values.any?(false)
        end
      archived_users_with_active_accounts =
        user_accounts_report[:archived].select do |u, accounts|
          accounts.values.any?(true)
        end

      users_without_full_time_periods = users.select do |u|
        u.full_time_periods.empty?
      end

      active_users = users.select(&:active?)

      users_without_dei_response = active_users.select do |u|
        next false unless [
          Enum::ContributorType::FOUR_DAY,
          Enum::ContributorType::FIVE_DAY
        ].include?(u.current_contributor_type)

        u.should_nag_for_dei_data?
      end

      users_with_unknown_salary = active_users.select do |u|
        next false unless [
          Enum::ContributorType::FOUR_DAY,
          Enum::ContributorType::FIVE_DAY
        ].include?(u.current_contributor_type)

        u.skill_tree_level_without_salary == "No Reviews Yet"
      end

      active_project_trackers = ProjectTracker
        .includes([
          :project_lead_periods,
          :adhoc_invoice_trackers,
          :forecast_projects
        ]).where(work_completed_at: nil)
      completed_project_trackers = ProjectTracker
        .includes([
          :project_capsule
        ]).where.not(work_completed_at: nil)

      project_trackers_no_project_lead = active_project_trackers.select do |pt|
        pt.current_project_leads.empty?
      end

      project_trackers_over_budget = active_project_trackers.select do |pt|
        pt.status == :over_budget
      end

      project_trackers_need_capsule = completed_project_trackers.select do |pt|
        pt.work_status == :capsule_pending
      end

      project_trackers_seemingly_complete = active_project_trackers.select do |pt|
        if pt.last_recorded_assignment
          pt.last_recorded_assignment.end_date < (Date.today -  1.month)
        else
          false
        end
      end.reject do |pt|
        pt.name.downcase.include?("(ongoing)")
      end

      # Load Allocation Data
      allocations_thread = Thread.new do
        allocations, allocation_errors =
          Stacks::Availability.load_allocations_from_notion
        allocations_today =
          Stacks::Availability.allocations_on_date(allocations, Date.today)
        [allocations, allocation_errors, allocations_today]
      end

      # Load QBO Customers
      qbo_customers_thread = Thread.new do
        Stacks::Quickbooks.fetch_all_customers
      end

      invoice_trackers = InvoiceTracker.includes(:qbo_invoice).all
      invoice_statuses_need_action =
        invoice_trackers.map do |it|
          it.status
        end.inject(Hash.new(0)) do |h, e|
          unless Stacks::System.singleton_class::INVOICE_STATUSES_NEED_ACTION.include?(e)
            next h
          end
          h[e] += 1
          h
        end

      qbo_customers, allocation_data =
        [qbo_customers_thread, allocations_thread].map(&:value)
      allocations, allocation_errors, allocations_today = allocation_data

      notifications << {
        subject: invoice_statuses_need_action,
        type: :invoice_tracker,
        link: admin_invoice_passes_path,
        error: :need_action,
        priority: 0
      } if invoice_statuses_need_action.any?

      allocations_today.each do |k, v|
        notifications << {
          subject: k,
          type: :assignment,
          link: Stacks::System.singleton_class::NOTION_ASSIGNMENTS_LINK,
          error: :over_assigned,
          priority: 0
        } if v > 1.0
      end

      allocation_errors.each do |ae|
        notifications << {
          subject: ae[:email],
          type: :assignment,
          link: ae[:url],
          error: ae[:error],
          priority: 2
        }
      end

      forecast_projects.each do |fp|
        notifications << {
          subject: fp,
          type: :forecast_project,
          link: fp.edit_link,
          error: :multiple_hourly_rates,
          priority: 1
        } if fp.has_multiple_hourly_rates?

        notifications << {
          subject: fp,
          type: :forecast_project,
          link: fp.edit_link,
          error: :no_explicit_hourly_rate,
          priority: 0
        } if fp.has_no_explicit_hourly_rate?
      end

			ForecastAssignmentDailyFinancialSnapshot.needs_review.each do |snapshot|
        notifications << {
          subject: snapshot.forecast_assignment,
          type: :forecast_project,
          link: snapshot.forecast_assignment.forecast_project.edit_link,
          error: :person_missing_hourly_rate,
          priority: 1
        }
      end

      forecast_clients.each do |fc|
        notifications << {
          subject: fc,
          type: :forecast_client,
          link: fc.edit_link,
          error: :no_qbo_customer,
          priority: 1
        } if fc.qbo_customer(qbo_customers).nil?
      end

      forecast_people.each do |fp|
        next if fp.archived

        notifications << {
          subject: fp,
          type: :forecast_person,
          link: fp.edit_link,
          error: :multiple_studios,
          priority: 2
        } if fp.studios.count > 1

        notifications << {
          subject: fp,
          type: :forecast_person,
          link: fp.edit_link,
          error: :no_studio,
          priority: 0
        } if fp.studios.count == 0
      end

      finalizations.each do |f|
        notifications << {
          subject: f,
          type: :finalization,
          link: edit_admin_finalization_path(f),
          error: :needs_archiving,
          priority: 0
        } if f.review.status == "finalized"
      end

      project_trackers_over_budget.each do |pt|
        notifications << {
          subject: pt,
          type: :project_tracker,
          link: admin_project_tracker_path(pt),
          error: :over_budget,
          priority: 0
        }
      end

      project_trackers_need_capsule.each do |pt|
        notifications << {
          subject: pt,
          type: :project_tracker,
          link: admin_project_tracker_path(pt),
          error: :capsule_pending,
          priority: 2
        }
      end

      project_trackers_seemingly_complete.each do |pt|
        notifications << {
          subject: pt,
          type: :project_tracker,
          link: admin_project_tracker_path(pt),
          error: :seemingly_complete,
          priority: 2
        }
      end

      project_trackers_no_project_lead.each do |pt|
        notifications << {
          subject: pt,
          type: :project_tracker,
          link: admin_project_tracker_path(pt),
          error: :no_project_lead,
          priority: 2
        }
      end

      users_without_dei_response.each do |u|
        notifications << {
          subject: u,
          type: :user,
          link: edit_admin_admin_user_path(u),
          error: :no_dei_response,
          priority: 2
        }
      end

      users_with_unknown_salary.each do |u|
        notifications << {
          subject: u,
          type: :user,
          link: edit_admin_admin_user_path(u),
          error: :unknown_salary,
          priority: 2
        }
      end

      users_without_full_time_periods.each do |u|
        notifications << {
          subject: u,
          type: :user,
          link: edit_admin_admin_user_path(u),
          error: :no_full_time_periods,
          priority: 0
        }
      end

      active_users_with_inactive_accounts.each do |user, report|
        notifications << {
          subject: user,
          type: :user,
          error: :active_but_missing_accounts,
          priority: 1
        }
      end

      archived_users_with_active_accounts.each do |user, report|
        notifications << {
          subject: user,
          type: :user,
          link: "https://www.notion.so/garden3d/Offboard-a-team-member-b5bad91e92a644eab342ca98673ba1f2",
          error: :archived_with_active_accounts,
          priority: 0
        }
      end

      notifications.sort{|a, b| a[:priority] <=> b[:priority] }

      notifications_made = 0
      recent_notifications =
        System.instance.notifications.where("read_at is NULL OR read_at > ?", 1.week.ago)

      notifications.each do |n|
        recent_notification = recent_notifications.find do |existing|
          begin
            (existing.params.to_a - n.to_a | n.to_a - existing.params.to_a) == []
          rescue => e
            # In rare cases, Notification might exist that references a deleted user.
            existing.destroy!
            false
          end
        end

        unless recent_notification.present?
          notifications_made += 1
          SystemNotification.with(n).deliver(System.instance)
        end
      end

      puts "~> Delivered #{notifications_made} new notifications"
    end

    def notify_admins_of_outstanding_notifications_every_tuesday!
      return unless (Date.today.wday == 2)

      n = System.instance.notifications.unread
      if n.any?
        message = <<~HEREDOC
          Hi, Stacks Admins!

          ⚠️ There are #{n.length} notifications in Stacks that need attention. If these items are not actioned, Stacks will not produce correct results.

          👉 Please review and action the items [here](https://stacks.garden3d.net/admin/system) at your earliest convenience.
        HEREDOC

        notify_admins_via_thread(
          "🥞 Stacks Notifications",
          message
        )
      end
    end

    def notify_admins_via_thread(thread_title, message)
      twist_users = twist.get_workspace_users.parsed_response
      stacks_admin_twist_user_ids = (AdminUser.admin.map do |a|
        twist_users.find{ |u| u["email"] == a.email }
      end).compact.map{|u| u["id"]}.compact

      channel = twist.get_channel("484267")
      thread = twist.get_all_threads(channel["id"]).find do |t|
        t["title"] == thread_title
      end
      if thread.present?
        twist.add_comment_to_thread(thread["id"], message, stacks_admin_twist_user_ids)
      else
        twist.add_thread(channel["id"], thread_title, message, stacks_admin_twist_user_ids)
      end
    end
  end
end
