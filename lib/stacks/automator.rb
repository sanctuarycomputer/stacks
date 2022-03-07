class Stacks::Automator
  class << self
    EIGHT_HOURS_IN_SECONDS = 28800

    STUDIO_TO_SERVICE_MAPPING = {
      "XXIX": "Brand Services",
      "Manhattan Hydraulics": "UX Services",
      "Sanctuary Computer": "Development Services",
      "garden3d": "Services",
    }

    STUDIOS = STUDIO_TO_SERVICE_MAPPING.keys

    def forecast
      @_forecast ||= Stacks::Forecast.new
    end

    def twist
      @_twist ||= Stacks::Twist.new
    end

    def message_operations_channel_thread(thread_title, message)
      channel = twist.get_channel("467805")
      thread = twist.get_all_threads(channel["id"]).find do |t|
        t["title"] == thread_title
      end
      if thread.present?
        twist.add_comment_to_thread(thread["id"], message)
      else
        twist.add_thread(channel["id"], thread_title, message)
      end
    end

    def attempt_invoicing_for_invoice_pass(invoice_pass, send_twist_reminders = true)
      needed_reminding = remind_people_to_record_hours_prior_to_invoicing(
        invoice_pass.start_of_month,
        send_twist_reminders
      )
      new_reminder_pass = {}
      new_reminder_pass[DateTime.now.iso8601] = needed_reminding.reduce({}) do |acc, p|
        acc[p[:forecast_data]["email"]] = {
          missing_allocation: p[:missing_allocation]
        }
        acc
      end
      invoice_pass.update(
        data: (invoice_pass.data || {}).merge({
          reminder_passes:
            ((invoice_pass.data || {})["reminder_passes"] || {}).merge(new_reminder_pass),
        })
      )

      return if needed_reminding.any?

      invoice_pass.make_trackers!
      invoice_pass.invoice_trackers.each do |it|
        it.make_invoice!
      end
      invoice_pass.update!(completed_at: DateTime.now)

      message = <<~HEREDOC
        We just completed an invoice pass for work done during #{invoice_pass.start_of_month.strftime("%B %Y")}.

        Please review and send invoices [here](https://stacks.garden3d.net/admin/invoice_passes/#{invoice_pass.id}), and resolve any errors necessary.
      HEREDOC
      message_operations_channel_thread("[#{invoice_pass.start_of_month.strftime("%B %Y")}] Invoicing", message)
    end

    # Designed to run daily, and remind folks to update their hours
    # until everyone has accounted for business_days * 8hrs in the
    # given month.
    def attempt_invoicing_for_previous_month
      # Check if it's the first wednesday of the month (or after)
      first_wednesday_of_month = Date.today.beginning_of_month
      first_wednesday_of_month += 1.days until first_wednesday_of_month.wday == 3
      return unless (first_wednesday_of_month <= Date.today)

      # Ensure we have an Invoice Pass record to track this month
      invoice_pass = InvoicePass.find_by(start_of_month: (Date.today - 1.month).beginning_of_month)
      unless invoice_pass.present?
        invoice_pass = InvoicePass.create!(
          start_of_month: (Date.today - 1.month).beginning_of_month,
          data: {}
        )
      end
      return if invoice_pass.complete?
      attempt_invoicing_for_invoice_pass(invoice_pass)
    end

    def remind_people_to_record_hours_prior_to_invoicing(start_of_month, send_twist_reminders)
      people = discover_people_missing_hours_for_month(start_of_month)

      admin_twist_users = (AdminUser.admin.map do |a|
        people.find{ |p| p[:twist_data]["email"] == a.email }
      end).compact

      needed_reminding = people.filter do |person|
        person[:reminder].present? &&
        person[:twist_data].present? &&
        !person[:forecast_data]["roles"].include?("Subcontractor")
      end

      if send_twist_reminders
        needed_reminding.each do |person|
          participant_ids = admin_twist_users.map{|p| p[:twist_data]["id"]}.join(",")
          conversation = twist.get_or_create_conversation(participant_ids)
          twist.add_message_to_conversation(conversation["id"], person[:reminder])
          sleep(0.1)
        end

        if needed_reminding.any?
          message_body = needed_reminding.reduce("") do |acc, person|
            acc + "- **[#{person[:twist_data]["name"]}](twist-mention://#{person[:twist_data]["id"]})**: `#{person[:missing_allocation] / 60 / 60} missing hrs`\n"
          end

          message = <<~HEREDOC
            👋 Hi Operations Team!

            We're blocked on invoicing until the following people fill out their missing hours for the entirety of the calendar month:
            #{message_body}

            I've just sent out reminders to these folks. We'll retry this tomorrow.
          HEREDOC
          message_operations_channel_thread(
            "[#{start_of_month.strftime("%B %Y")}] Invoicing",
            message
          )
        end
      end

      needed_reminding
    end

    # TODO: move me to Stacks::Quickbooks
    def make_and_refresh_qbo_access_token
      oauth2_client = OAuth2::Client.new(Stacks::Utils.config[:quickbooks][:client_id], Stacks::Utils.config[:quickbooks][:client_secret], {
        site: "https://appcenter.intuit.com/connect/oauth2",
        authorize_url: "https://appcenter.intuit.com/connect/oauth2",
        token_url: "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer",
      })
      qbo_token = QuickbooksToken.order("created_at").last
      access_token = OAuth2::AccessToken.new(
        oauth2_client,
        qbo_token.token,
        refresh_token: qbo_token.refresh_token
      )

      # Refresh the token if it's been longer than 45 minutes
      if ((DateTime.now.to_i - qbo_token.created_at.to_i) / 60) > 45
        access_token = access_token.refresh!
        new_qbo_token =
          QuickbooksToken.create!(
            token: access_token.token,
            refresh_token: access_token.refresh_token
          )
        QuickbooksToken.where.not(id: new_qbo_token.id).delete_all
      end

      access_token
    end

    # TODO: move me to Stacks::Quickbooks
    def fetch_invoices_by_ids(ids = [])
      return [] unless ids.any?

      access_token = make_and_refresh_qbo_access_token

      invoice_service = Quickbooks::Service::Invoice.new
      invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      invoice_service.access_token = access_token

      invoice_service.query(
        "SELECT * FROM Invoice WHERE id in ('#{ids.join("','")}')",
        per_page: 1000
      )
    end

    def discover_people_missing_hours_for_month(start_of_month)
      projects = forecast.projects()["projects"]

      last_month_assignments = forecast.assignments(
        start_of_month.beginning_of_month,
        start_of_month.end_of_month,
      )["assignments"]

      business_days_last_month = (
        start_of_month.beginning_of_month..start_of_month.end_of_month
      ).select { |d| (1..5).include?(d.wday) }.size

      allocation_expected_last_month = EIGHT_HOURS_IN_SECONDS * business_days_last_month

      twist_users = twist.get_workspace_users.parsed_response

      people = forecast.people["people"].reject { |p| p["archived"] }.map do |person|
        twist_user = twist_users.find do |twist_user|
          twist_user["email"].downcase == person["email"].try(:downcase) ||
          twist_user["name"].downcase == "#{person["first_name"]} #{person["last_name"]}".downcase
        end

        assignments = last_month_assignments.filter { |a| a["person_id"] == person["id"] }

        total_allocation_in_seconds = assignments.reduce(0) do |acc, a|
          # A nil allocation is a full day of "Time Off" in Harvest Forecast
          assignment_start_date = Date.parse(a["start_date"])
          assignment_end_date = Date.parse(a["end_date"])

          start_date = if assignment_start_date < start_of_month.beginning_of_month
              start_of_month.beginning_of_month
            else
              assignment_start_date
            end

          end_date = if assignment_end_date > start_of_month.end_of_month
              start_of_month.end_of_month
            else
              assignment_end_date
            end

          project = projects.find { |p| p["id"] == a["project_id"] }
          days = if project["name"] == "Time Off" && a["allocation"].nil?
              # If this allocation is for the "Time Off" project, filter time on weekends!
              (start_date..end_date).select { |d| (1..5).include?(d.wday) }.size
            else
              # This allocation is not for "Time Off", so count work done on weekends.
              (end_date - start_date).to_i + 1
            end

          per_day_allocation = a["allocation"].nil? ? EIGHT_HOURS_IN_SECONDS : a["allocation"]
          acc + (per_day_allocation * days)
        end

        if total_allocation_in_seconds < allocation_expected_last_month
          missing_allocation = allocation_expected_last_month - total_allocation_in_seconds

          reminder = <<~HEREDOC
            👋 Hi #{person["first_name"]}!

            👉 We'd like to send invoices today, but we can't do that until you've accounted for at least 8 hours of time for every business day last month.

            **We're missing at least `#{(missing_allocation.to_f / 60 / 60)} hrs` of your time last month. Please ensure you've accounted for at least 8 hours of time each day between #{start_of_month.beginning_of_month.to_formatted_s(:long)} and #{start_of_month.end_of_month.to_formatted_s(:long)}, then ping me back, so we can send out invoices and get us all paid!**

            - [Please fill them out when you get a chance.](https://forecastapp.com/864444/schedule/team) (And remember that [Time Off](https://help.getharvest.com/forecast/schedule/plan/scheduling-time-off/) or Internal Work also needs to be recorded!)

            - If you worked a long day, then a short day, or something like that, that's totally fine! Just mark the remaining hours of your short day as "Time Off".

            - If you're not sure how to do it, you can [learn about recording hours here](https://www.notion.so/garden3d/How-to-Record-your-Hours-ff971848f66d40cf818b930f05cfc533), or get in touch with your project lead. We're aiming for everyone to do this autonomously!

            - If you think something here is incorrect, please let me know!

            🙏 Thank you!
          HEREDOC
          {
            forecast_data: person,
            twist_data: twist_user,
            missing_allocation: missing_allocation,
            reminder: reminder,
            studio: person["roles"].filter { |r| STUDIOS.include?(:"#{r}") }.first,
          }
        else
          {
            forecast_data: person,
            twist_data: twist_user,
            missing_allocation: 0,
            reminder: nil,
            studio: person["roles"].filter { |r| STUDIOS.include?(:"#{r}") }.first,
          }
        end
      end
    end
  end
end
