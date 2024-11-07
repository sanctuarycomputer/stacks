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

    def report_exception(exception)
      notification = SystemExceptionNotification.with(
        exception: {
          message: exception.try(:to_s),
          klass: exception.try(:class).try(:to_s),
          backtrace: exception.try(:backtrace)
        },
        include_admins: false,
      )
      notification.deliver(AdminUser.find_by(email: "hugh@sanctuary.computer"))

      Sentry.capture_exception(exception)
      notification
    end

    def mark_system_notififcations_read_if_irrelevant!(notification_params = stage_notification_params)
      unread_notifications = System.instance.notifications.send("unread")
      unread_notifications.filter do |n|
        matching_params = notification_params.find do |params|
          begin
            (params.to_a - n.params.to_a | n.params.to_a - params.to_a) == []
          rescue => e
            n.destroy!
            false
          end
        end

        if matching_params.present?
          true
        else
          n.mark_as_read!
          false
        end
      end

      notification_params
    end

    def stage_notification_params
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

      users = AdminUser.not_ignored

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

      archived_users_with_active_accounts =
        user_accounts_report[:archived].select do |u, accounts|
          accounts.values.any?(true)
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

      notifications << {
        subject: invoice_statuses_need_action,
        type: :invoice_tracker,
        link: admin_invoice_passes_path,
        error: :need_action,
        priority: 0
      } if invoice_statuses_need_action.any?

      ForecastAssignmentDailyFinancialSnapshot.needs_review.each do |snapshot|
        notifications << {
          subject: snapshot.forecast_assignment.forecast_project,
          type: :forecast_project,
          forecast_person_email: snapshot.forecast_assignment.forecast_person.email,
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
        } if fc.qbo_customer(Stacks::Quickbooks.fetch_all_customers).nil?
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
      notifications
    end

    def make_notifications!
      # The new school
      Stacks::DataIntegrityManager.new.notify!

      # The old school, eventually will be deprecated.
      notifications = stage_notification_params
      mark_system_notififcations_read_if_irrelevant!(notifications)

      notifications_made = 0
      recent_params = System.instance.notifications
        .where("read_at is NULL OR read_at > ?", 1.week.ago)
        .pluck(:params)

      notifications.each do |n|
        matching_params = recent_params.find do |params|
          (params.to_a - n.to_a | n.to_a - params.to_a) == []
        end

        unless matching_params.present?
          notifications_made += 1
          SystemNotification.with(n).deliver(System.instance)
          recent_params << n
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
