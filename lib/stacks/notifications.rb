class Stacks::Notifications
  class << self
    include Rails.application.routes.url_helpers

    def twist
      @_twist ||= Stacks::Twist.new
    end

    def notifications
      # TODO Forecast Client with malformed term?
      # TODO Users without Full Time Periods or salary
      notifications = []

      finalizations = Finalization.all
      forecast_projects = ForecastProject.all
      forecast_clients = Stacks::System.clients_served_since(Date.today - 3.months, Date.today)
      forecast_people = ForecastPerson.all

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

      # Load Invoice Statuses
      invoice_statuses_thread = Thread.new do
        invoice_trackers = InvoiceTracker.all
        qbo_invoices =
          Stacks::Automator.fetch_invoices_by_ids(
            invoice_trackers.map(&:qbo_invoice_id).compact
          )
        invoice_statuses_need_action =
          invoice_trackers.map do |it|
            it.qbo_invoice(qbo_invoices)
            it.status
          end.inject(Hash.new(0)) do |h, e|
            unless Stacks::System.singleton_class::INVOICE_STATUSES_NEED_ACTION.include?(e)
              next h
            end
            h[e] += 1
            h
          end
      end

      invoice_statuses_need_action, qbo_customers, allocation_data =
        [invoice_statuses_thread, qbo_customers_thread, allocations_thread].map(&:value)
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

      notifications.sort{|a, b| a[:priority] <=> b[:priority] }
    end

    def notify_admins_of_outstanding_notifications_every_tuesday!
      return unless (Date.today.wday == 2)

      n = notifications
      if n.any?
        message = <<~HEREDOC
          Hi, Stacks Admins!

          ⚠️ There are #{n.length} notifications in Stacks that need attention. If these items are not actioned, Stacks will not produce correct results.

          👉 Please review and action the items [here](https://stacks.garden3d.net/admin/notifications) at your earliest convenience.
        HEREDOC

        notify_admins_via_thread(
          "🥞 Stacks Notifications",
          "There are #{n.length} notifications in Stacks that need attention."
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
