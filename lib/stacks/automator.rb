class Stacks::Automator
  class << self
    EIGHT_HOURS_IN_SECONDS = 28800

    def forecast
      @_forecast ||= Stacks::Forecast.new
    end

    def twist
      @_twist ||= Stacks::Twist.new
    end

    def send_stale_task_digests_every_thursday
      return unless Time.now.thursday?

      raw_digest =
        Stacks::Notion::Task.stale.reduce({}) do |acc, task|
          stewards_emails = task.stewards.map{|p| p.dig("person", "email")}
          stewards_emails.compact.each do |e|
            acc[e] = acc[e] || { tasks_stewarding: [], tasks_assigned: [] }
            acc[e][:tasks_stewarding] = [*acc[e][:tasks_stewarding], task.notion_page]
          end

          assignees_emails = task.assignees.map{|p| p.dig("person", "email")}
          assignees_emails.compact.each do |e|
            acc[e] = acc[e] || { tasks_stewarding: [], tasks_assigned: [] }
            acc[e][:tasks_assigned] = [*acc[e][:tasks_assigned], task.notion_page]
          end

          acc
        end

      raw_digest.each do |k, v|
        a = AdminUser.find_by(email: k)
        if a.present?
          StaleTasksNotification.with(
            digest: v,
            include_admins: false,
          ).deliver(a)
        end
      end
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
        acc[p[:forecast_data].email] = {
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
      message_operations_channel_thread(
        "[#{invoice_pass.start_of_month.strftime("%B %Y")}] Invoicing",
        message
      )
    end

    # Designed to run on every Tuesday that is not the first
    # week of the month (when invoicing happens).
    def remind_people_to_record_hours_weekly
      twist_users = twist.get_workspace_users.parsed_response

      first_tuesday = Date.today.beginning_of_month
      first_tuesday += 1.days until first_tuesday.wday == 2
      next_tuesday = Date.today
      next_tuesday += 1.days until next_tuesday.wday == 2
      return if next_tuesday == first_tuesday
      return if next_tuesday != Date.today

      end_of_last_week = (Date.today - 1.week).end_of_week
      ForecastPerson.includes(:admin_user).all.reject(&:archived).each do |fp|
        next unless fp.admin_user.present?
        next if fp.admin_user.contributor_type == Enum::ContributorType::VARIABLE_HOURS

        missing_hours = fp.missing_allocation_during_range_in_hours(
          Date.today.beginning_of_month, end_of_last_week
        )
        next if missing_hours == 0

        WeeklyHoursReminderNotification.with(
          missing_hours: missing_hours,
          include_admins: false,
        ).deliver(fp.admin_user)
      end
    end

    # Designed to run daily, and remind folks to update their hours
    # until everyone has accounted for business_days * 8hrs in the
    # given month.
    def attempt_invoicing_for_previous_month
      invoice_pass = InvoicePass.find_by(
        start_of_month: (Date.today - 1.month).beginning_of_month
      )
      unless invoice_pass.present?
        invoice_pass = InvoicePass.create!(
          start_of_month: (Date.today - 1.month).beginning_of_month,
          data: {}
        )
      end
      return if invoice_pass.complete?

      # Invoicing happens on the first day of the month
      return unless Date.today >= Date.today.beginning_of_month
      attempt_invoicing_for_invoice_pass(invoice_pass)
    end

    def remind_people_to_record_hours_prior_to_invoicing(start_of_month, send_twist_reminders)
      twist_users = twist.get_workspace_users.parsed_response
      people = discover_people_missing_hours_for_month(twist_users, start_of_month)

      admin_twist_users = (AdminUser.admin.map do |a|
        twist_users.find{ |tu| tu["email"] == a.email }
      end).compact

      studios = Studio.all
      studio_coordinator_twist_users = studios.reduce({}) do |acc, s|
        acc[s] = (s.current_studio_coordinators.map do |a|
          twist_users.find{ |tu| tu["email"] == a.email }
        end).compact
        acc
      end

      needed_reminding = people.filter do |person|
        person[:reminder].present? &&
        person[:twist_data].present? &&
        !person[:forecast_data].roles.include?("Subcontractor")
      end

      if send_twist_reminders
        needed_reminding.each do |person|
          sc_twist_users =
            studio_coordinator_twist_users[person[:forecast_data].studio(studios)]
          participant_ids = [
            *(sc_twist_users.any? ? sc_twist_users : admin_twist_users).map{|tu| tu["id"]},
            person[:twist_data]["id"]
          ].join(",")
          conversation = twist.get_or_create_conversation(participant_ids)
          twist.add_message_to_conversation(conversation["id"], person[:reminder])
          sleep(0.1)
        end

        if needed_reminding.any?
          message_body = needed_reminding.reduce("") do |acc, person|
            acc + "- **[#{person[:twist_data]["name"]}](twist-mention://#{person[:twist_data]["id"]})**: `#{person[:missing_allocation]} missing hrs`\n"
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

    def discover_people_missing_hours_for_month(twist_users, start_of_month)
      ForecastPerson.all.reject(&:archived).map do |fp|
        twist_user = twist_users.find do |twist_user|
          twist_user["email"].downcase == fp.email.try(:downcase) ||
          twist_user["name"].downcase == "#{fp.first_name} #{fp.last_name}".downcase
        end

        missing_hours = fp.missing_allocation_during_range_in_hours(
          start_of_month.beginning_of_month,
          start_of_month.end_of_month,
        )
        next nil unless missing_hours > 0

        reminder = <<~HEREDOC
          👋 Hi #{fp.first_name}!

          👉 We'd like to send invoices today, but we can't do that until you've accounted for at least 8 hours of time for every business day last month.

          **We're missing at least `#{missing_hours} hrs` of your time last month. Please ensure you've accounted for at least 8 hours of time each day between #{start_of_month.beginning_of_month.to_formatted_s(:long)} and #{start_of_month.end_of_month.to_formatted_s(:long)}, then ping me back, so we can send out invoices and get us all paid!**

          - [Please fill them out when you get a chance.](https://forecastapp.com/864444/schedule/team) (And remember that [Time Off](https://help.getharvest.com/forecast/schedule/plan/scheduling-time-off/) or Internal Work also needs to be recorded!)

          - If you worked a long day, then a short day, or something like that, that's totally fine! Just mark the remaining hours of your short day as "Time Off".

          - If you're not sure how to do it, you can [learn about recording hours here](https://www.notion.so/garden3d/How-to-Record-your-Hours-ff971848f66d40cf818b930f05cfc533), or get in touch with your project lead. We're aiming for everyone to do this autonomously!

          - If you think something here is incorrect, please let someone know!

          🙏 Thank you!
        HEREDOC

        {
          forecast_data: fp,
          twist_data: twist_user,
          missing_allocation: missing_hours,
          reminder: reminder,
        }
      end.compact
    end
  end
end
