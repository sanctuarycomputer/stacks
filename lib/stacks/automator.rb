class Stacks::Automator
  class << self
    FORTY_HOURS_IN_SECONDS = 144000
    EIGHT_HOURS_IN_SECONDS = 28800

    STUDIO_TO_SERVICE_MAPPING = {
      "XXIX": "Brand Services",
      "Manhattan Hydraulics": "UX Services",
      "Sanctuary Computer": "Development Services",
      "garden3d": "Services",
    }

    STUDIOS = STUDIO_TO_SERVICE_MAPPING.keys

    DEFAULT_HOURLY_RATE = 145 # Override on the project level Forecast
    DEFAULT_PAYMENT_TERM = 15 # Net 15, override in QBO

    QBO_NOTES_FORECAST_MAPPING_BEARER = "automator:forecast_mapping:"
    QBO_NOTES_PAYMENT_TERM_BEARER = "automator:payment_term:"
    CUSTOMER_MEMO = <<~HEREDOC
      EIN: 47-2941554
      W9: https://w9.sanctuary.computer

      WIRE:
      Sanctuary Computer Inc
      EIN: 47-2941554
      Rou #: 021000021
      Acc #: 685028396

      Chase Bank
      405 Lexington Ave
      New York, NY 10174

      QUICKPAY:
      admin@sanctuarycomputer.com

      BILL.COM
      admin@sanctuarycomputer.com
    HEREDOC

    def forecast
      @_forecast ||= Stacks::Forecast.new
    end

    def twist
      @_twist ||= Stacks::Twist.new
    end

    def notion
      @_notion ||= Stacks::Notion.new
    end

    def sync_with_finance_hub
      response = notion.query_database("713b28db4f8a45c68126e9723c65349e")
      block_id = response["results"][0]["id"]
      blocks = notion.get_block_children(block_id)["results"]

      # Attempt to discover the database
      finance_hubs = (blocks.map do |block|
        if block["type"] == "unsupported"
          pd = notion.get_database(block["id"])
          (pd["title"] && pd["title"][0].dig("text", "content") == "Finance Hub") ? pd : nil
        else
          nil
        end
      end).compact

      finance_hub = if finance_hubs.count == 1
          finance_hubs.first
        elsif finance_hubs.count == 0
          notion.create_database(
            { page_id: block_id },
            "Finance Hub",
            {
              "Name": { "title": {} },
              "Spend": { "number": { "format": "dollar" } },
            }
          )
        else
          raise "too_many_finance_hubs"
        end

      finance_hub_children = notion.get_block_children(finance_hub["id"])

      # Pull in all invoices with a note, ensure they exist
      # Ensure the current month exists (July 2020)
      # Update Spend: May 2021 | 37,450
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

    def message_operations_team(message)
      conversation = twist.get_conversation("1165647")
      twist.add_message_to_conversation(conversation["id"], message)
    end

    def attempt_invoicing_for_invoice_pass(invoice_pass)
      # Bug people, and record the folks who needed reminding, so we can change the reminder message each time.
      needed_reminding = remind_people_to_record_hours_prior_to_invoicing(invoice_pass.start_of_month)

      # Record people still missing
      new_reminder_pass = {}
      new_reminder_pass[DateTime.now.iso8601] =
        needed_reminding.reduce({}) { |acc, p| acc[p[:forecast_data]["email"]] = { missing_allocation: p[:missing_allocation] }; acc }
      invoice_pass.update(data: (invoice_pass.data || {}).merge({
                            reminder_passes: ((invoice_pass.data || {})["reminder_passes"] || {}).merge(new_reminder_pass),
                          }))

      return if needed_reminding.any?

      # Everyone's entered their hours, so let's generate invoices!
      run_data = generate_invoices(invoice_pass.start_of_month)
      new_pass = {}
      new_pass[DateTime.now.iso8601] = run_data
      invoice_pass.update(data: (invoice_pass.data || {}).merge({
                            generator_passes: ((invoice_pass.data || {})["generator_passes"] || {}).merge(new_pass),
                          }), completed_at: DateTime.now)

      message = <<~HEREDOC
        We just completed an invoice pass for work done during #{invoice_pass.start_of_month.strftime("%B %Y")}.

        Please review and send invoices [here](https://stacks.garden3d.net/admin/invoice_passes/#{invoice_pass.id}), and resolve any errors necessary.
      HEREDOC
      #message_operations_channel_thread("[#{invoice_pass.start_of_month.strftime("%B %Y")}] Invoicing", message)
    end

    # Designed to run daily, and remind folks to update their hours
    # until everyone has accounted for business_days * 8hrs in the
    # given month.
    def attempt_invoicing_for_previous_month
      # Check if it's the first wednesday of the month (or after)
      first_tuesday_of_month = Date.today.beginning_of_month
      first_tuesday_of_month += 1.days until first_tuesday_of_month.wday == 3
      return unless (first_tuesday_of_month <= Date.today)

      # Ensure we have an Invoice Pass record to track this month
      invoice_pass = InvoicePass.find_by(start_of_month: (Date.today - 1.month).beginning_of_month)
      unless invoice_pass.present?
        invoice_pass = InvoicePass.create!(start_of_month: (Date.today - 1.month).beginning_of_month, data: {})
      end
      return if invoice_pass.complete?

      attempt_invoicing_for_invoice_pass(invoice_pass)
    end

    def remind_people_to_record_hours_prior_to_invoicing(start_of_month)
      people = discover_people_missing_hours_for_month(start_of_month)
      hugh = people.find { |p| p[:twist_data]["email"] == "hugh@sanctuary.computer" }

      needed_reminding = people.filter do |person|
        person[:reminder].present? && person[:twist_data].present? && !person[:forecast_data]["roles"].include?("Subcontractor")
      end

      needed_reminding.each do |person|
        #conversation = twist.get_or_create_conversation("#{person[:twist_data]["id"]},#{hugh[:twist_data]["id"]}")
        #twist.add_message_to_conversation(conversation["id"], person[:reminder])
        #sleep(0.1)
      end

      if needed_reminding.any?
        message_body = needed_reminding.reduce("") do |acc, person|
          acc + "**[#{person[:twist_data]["name"]}](twist-mention://#{person[:twist_data]["id"]})**: `#{person[:missing_allocation] / 60 / 60} missing hrs`"
        end
        message = <<~HEREDOC
          👋 Hi Operations Team!

          We're blocked on invoicing until the following people fill out their missing hours for the entirety of the calendar month:
          #{message_body}

          I've just sent out reminders to these folks. We'll retry this tomorrow.
        HEREDOC
        #message_operations_channel_thread("[#{start_of_month.strftime("%B %Y")}] Invoicing", message)
      end

      needed_reminding
    end

    def make_and_refresh_qbo_access_token
      oauth2_client = OAuth2::Client.new(Stacks::Utils.config[:quickbooks][:client_id], Stacks::Utils.config[:quickbooks][:client_secret], {
        site: "https://appcenter.intuit.com/connect/oauth2",
        authorize_url: "https://appcenter.intuit.com/connect/oauth2",
        token_url: "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer",
      })
      qbo_token = QuickbooksToken.order("created_at").last
      access_token = OAuth2::AccessToken.new(oauth2_client, qbo_token.token, refresh_token: qbo_token.refresh_token)
      access_token = access_token.refresh!
      new_qbo_token = QuickbooksToken.create!(token: access_token.token, refresh_token: access_token.refresh_token)
      QuickbooksToken.where.not(id: new_qbo_token.id).delete_all

      access_token
    end

    def fetch_all_invoices
      access_token = make_and_refresh_qbo_access_token

      invoice_service = Quickbooks::Service::Invoice.new
      invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      invoice_service.access_token = access_token
      invoice_service.all
    end

    def generate_invoices(start_of_month)
      run_data = {
        existing: [],
        generated: [],
        error_missing_qbo_customer: [],
        error_payment_term_malformed: [],
        error_hourly_rate_malformed: [],
      }

      invoice_month = start_of_month.strftime("%B %Y")
      people = forecast.people()["people"]
      projects = forecast.projects()["projects"]

      last_month_assignments = forecast.assignments(
        start_of_month.beginning_of_month,
        start_of_month.end_of_month,
      )["assignments"]

      invoices_to_send = (forecast.clients()["clients"].reject { |c| STUDIOS.include?(:"#{c["name"]}") }.map do |client|
        client_projects = projects.filter { |p| p["client_id"] == client["id"] }
        client_project_ids = client_projects.map { |p| p["id"] }
        client_assignments = last_month_assignments.filter { |a| client_project_ids.include?(a["project_id"]) }
        client_people = client_assignments.map { |a| a["person_id"] }.uniq.map { |person_id| people.find { |p| p["id"] == person_id } }

        invoice_lines = client_people.reduce([]) do |acc, person|
          person_invoice_lines = []
          person_assignments = client_assignments.filter { |a| a["person_id"] == person["id"] }
          acc << person_assignments.reduce([]) do |person_invoice_lines_acc, assignment|
            project = projects.find { |p| p["id"] == assignment["project_id"] }
            invoice_description = "#{project["code"]} #{project["name"]} (#{invoice_month}) #{person["first_name"]} #{person["last_name"]}"
            assignment_start_date = Date.parse(assignment["start_date"])
            assignment_end_date = Date.parse(assignment["end_date"])

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

            days = (end_date - start_date).to_i + 1
            total_allocation = (assignment["allocation"] * days)

            existing = person_invoice_lines_acc.find { |line| line[:description] == invoice_description }
            if existing.present?
              existing[:allocation] = existing[:allocation] += total_allocation
            else
              services = person["roles"].map { |r| STUDIO_TO_SERVICE_MAPPING[:"#{r}"] }.compact
              service = if services.count == 0
                  "Services"
                elsif services.count > 1
                  "Services"
                else
                  services.first
                end

              hourly_rate_tags = project["tags"].filter { |t| t.ends_with?("p/h") }
              hourly_rate = if hourly_rate_tags.count == 0
                  DEFAULT_HOURLY_RATE
                elsif hourly_rate_tags.count > 1
                  :malformed
                else
                  hourly_rate_tags.first.to_f
                end

              person_invoice_lines_acc << {
                description: invoice_description,
                allocation: total_allocation,
                service: service,
                hourly_rate: hourly_rate,
              }
            end
            person_invoice_lines_acc
          end
        end

        {
          client: client,
          invoice_lines: invoice_lines.flatten.sort { |a, b| a[:description] <=> b[:description] },
        }
      end).filter { |i| i[:invoice_lines].any? }

      # Do Quickbooks Things
      access_token = make_and_refresh_qbo_access_token

      # Get all Customers
      service = Quickbooks::Service::Customer.new
      service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      service.access_token = access_token
      qbo_customers = service.all

      # Get all Items (ie, "Development Services")
      items_service = Quickbooks::Service::Item.new
      items_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      items_service.access_token = access_token
      qbo_items = items_service.all

      # Get all terms (ie, "Net 15")
      terms_service = Quickbooks::Service::Term.new
      terms_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      terms_service.access_token = access_token
      qbo_terms = terms_service.all

      # Get all Invoices
      invoice_service = Quickbooks::Service::Invoice.new
      invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      invoice_service.access_token = access_token
      qbo_invoices = invoice_service.all

      invoices_to_send.each do |invoice|
        # Find our QBO Customer
        invoice[:qbo_customer] = qbo_customers.find do |c|
          mapping = (c.notes || "").split(" ").find { |word| word.starts_with?(QBO_NOTES_FORECAST_MAPPING_BEARER) }
          if mapping
            splat = mapping.split(QBO_NOTES_FORECAST_MAPPING_BEARER)[1]
            splat = splat.gsub!(/_/, " ") if splat.include?("_")
            splat == invoice[:client]["name"]
          else
            c.company_name == invoice[:client]["name"]
          end
        end

        # Warn if we're missing QBO Customer
        if invoice[:qbo_customer].nil?
          run_data[:error_missing_qbo_customer] << {
            forecast_client: {
              name: invoice[:client]["name"],
              id: invoice[:client]["id"],
            },
          }
          next
        end

        # Warn if there's more than one hourly rate per project
        if invoice[:invoice_lines].any? { |l| l[:hourly_rate] == :malformed }
          run_data[:error_hourly_rate_malformed] << {
            forecast_client: {
              name: invoice[:client]["name"],
              id: invoice[:client]["id"],
            },
            qbo_customer: {
              id: invoice[:qbo_customer].id,
              company_name: invoice[:qbo_customer].company_name,
            },
          }
          next
        end

        # Find our Term
        term_mapping = (invoice[:qbo_customer].notes || "").split(" ").find { |word| word.starts_with?(QBO_NOTES_PAYMENT_TERM_BEARER) }
        term = if term_mapping.present?
            term_days = term_mapping.split(QBO_NOTES_PAYMENT_TERM_BEARER)[1].to_i
            qbo_terms.find { |t| t.due_days == term_days }
          else
            qbo_terms.find { |t| t.due_days == DEFAULT_PAYMENT_TERM }
          end

        # Warn if the term is not 15, 30, 45, 90, etc
        if term.nil?
          run_data[:error_payment_term_malformed] << {
            forecast_client: {
              name: invoice[:client]["name"],
              id: invoice[:client]["id"],
            },
            qbo_customer: {
              id: invoice[:qbo_customer].id,
              company_name: invoice[:qbo_customer].company_name,
            },
          }
          next
        end

        # Test there's no existing invoice for this month
        qbo_invoices_for_customer = qbo_invoices.select { |i| i.customer_ref.value == invoice[:qbo_customer].id }
        existing = qbo_invoices_for_customer.find { |i| i.private_note == invoice_month }
        if existing.present?
          run_data[:existing] << {
            forecast_client: {
              name: invoice[:client]["name"],
              id: invoice[:client]["id"],
            },
            qbo_customer: {
              id: invoice[:qbo_customer].id,
              company_name: invoice[:qbo_customer].company_name,
            },
            qbo_invoice: {
              id: existing.id,
            },
          }
          next
        end

        # OK! We're good to go!
        qbo_invoice = Quickbooks::Model::Invoice.new
        qbo_invoice.customer_id = invoice[:qbo_customer].id
        qbo_invoice.private_note = invoice_month

        qbo_invoice.bill_email = invoice[:qbo_customer].primary_email_address
        qbo_invoice.sales_term_ref = Quickbooks::Model::BaseReference.new(term.name, value: term.id)
        qbo_invoice.allow_online_ach_payment = true
        qbo_invoice.customer_memo = CUSTOMER_MEMO

        invoice[:invoice_lines].each do |line|
          item = qbo_items.find { |s| s.fully_qualified_name == line[:service] } ||
                 qbo_items.find { |s| s.fully_qualified_name == "Services" }

          hours = (line[:allocation].to_f / 60 / 60)
          hourly_rate = line[:hourly_rate]

          line_item = Quickbooks::Model::InvoiceLineItem.new
          line_item.amount = hours * hourly_rate
          line_item.description = line[:description]
          line_item.sales_item! do |detail|
            detail.unit_price = hourly_rate
            detail.quantity = hours
            detail.item_id = item.id
          end
          qbo_invoice.line_items << line_item
        end
        created_invoice = invoice_service.create(qbo_invoice)

        run_data[:generated] << {
          forecast_client: {
            name: invoice[:client]["name"],
            id: invoice[:client]["id"],
          },
          qbo_customer: {
            id: invoice[:qbo_customer].id,
            company_name: invoice[:qbo_customer].company_name,
          },
          qbo_invoice: {
            id: created_invoice.id,
          },
        }
      end

      run_data
    end

    def discover_people_missing_hours_for_month(start_of_month)
      projects = forecast.projects()["projects"]

      last_month_assignments = forecast.assignments(
        start_of_month.beginning_of_month,
        start_of_month.end_of_month,
      )["assignments"]

      business_days_last_month = (start_of_month.beginning_of_month..start_of_month.end_of_month).select { |d| (1..5).include?(d.wday) }.size
      allocation_expected_last_month = EIGHT_HOURS_IN_SECONDS * business_days_last_month

      twist_users = twist.get_workspace_users.parsed_response

      people = forecast.people["people"].map do |person|
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

            - If you're not sure how to do it, you can [learn about recording hours here](https://www.notion.so/garden3d/w110g3d-fm-715c674c75814a92944da059f37cb1f9), or get in touch with your project lead. We're aiming for everyone to do this autonomously!

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

    def discover_people_missing_hours
      # Do the thing!
      twist_users = twist.get_workspace_users.parsed_response

      # Discover every full week prior to the current week that contains days within this month
      relevant_weeks = find_relevant_weeks
      relevant_weeks.each do |week|
        week[:assignments] = forecast.assignments(
          week[:monday].strftime("%Y-%m-%dT%H:%M:%S.%L%z"),
          week[:friday].strftime("%Y-%m-%dT%H:%M:%S.%L%z")
        )["assignments"]
      end

      # Get the full team & decorate with their assignments
      forecast.people["people"].map do |person|
        twist_user = twist_users.find do |twist_user|
          twist_user["email"].downcase == person["email"].try(:downcase) ||
          twist_user["name"].downcase == "#{person["first_name"]} #{person["last_name"]}".downcase
        end

        assignments_by_week = relevant_weeks.map do |week|
          assignments = week[:assignments].filter { |a| a["person_id"] == person["id"] }
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

            days = (end_date - start_date).to_i + 1
            per_day_allocation = a["allocation"].nil? ? EIGHT_HOURS_IN_SECONDS : a["allocation"]
            acc + (per_day_allocation * days)
          end
          {
            monday: week[:monday],
            friday: week[:friday],
            assignments: assignments,
            total_allocation_in_seconds: total_allocation_in_seconds,
          }
        end

        # Crunch hours missing
        weeks_missing_hours = assignments_by_week.select { |abw| abw[:total_allocation_in_seconds] < FORTY_HOURS_IN_SECONDS }
        reminder_body = if weeks_missing_hours.any?
            weeks_missing_hours.reduce("") do |acc, week|
              acc + "#{week[:monday].to_formatted_s(:short)} - #{week[:friday].to_formatted_s(:short)}: Missing #{(FORTY_HOURS_IN_SECONDS - week[:total_allocation_in_seconds].to_f) / 60 / 60} hours
"
            end
          end

        reminder = if reminder_body.present?
            <<~HEREDOC
              👋 Hi #{person["first_name"]}!

              I just wanted to let you know that we're missing hours for you:

              #{reminder_body}

              - [Please fill them out when you get a chance.](https://forecastapp.com/864444/schedule/team) (And remember that [Time Off](https://help.getharvest.com/forecast/schedule/plan/scheduling-time-off/) or Internal Work also needs to be recorded!)

              - If you worked a long day, then a short day, or something like that, that's totally fine! Just mark the remaining hours of your short day as "Time Off".

              - If you can please fill out your previous week's hours before Tuesday at 11am EST, you won't get this reminder in the future.

              - If you're not sure how to do it, you can [learn about recording hours here](https://www.notion.so/garden3d/w110g3d-fm-715c674c75814a92944da059f37cb1f9), or get in touch with your project lead. We're aiming for everyone to do this autonomously!

              - If you think something here is incorrect, please let me know!

              🙏 Thank you!
            HEREDOC
          end

        {
          forecast_data: person,
          twist_data: twist_user,
          assignments_by_week: assignments_by_week,
          reminder: reminder,
          reminder_body: reminder_body,
          studio: person["roles"].filter { |r| STUDIOS.include?(:"#{r}") }.first,
        }
      end
    end

    def remind_people_to_record_hours
      # We run this with Heroku scheduler, which doesn't do weeks
      return unless (Date.today.strftime("%A") == "Tuesday")
      people = discover_people_missing_hours

      hugh = people.find { |p| p[:twist_data]["email"] == "hugh@sanctuary.computer" }
      people.each do |person|
        if person[:reminder].present? && person[:twist_data].present?
          conversation = twist.get_or_create_conversation("#{person[:twist_data]["id"]},#{hugh[:twist_data]["id"]}")
          twist.add_message_to_conversation(conversation["id"], person[:reminder])
          sleep(0.25)
        end
      end

      needed_reminding = people.select { |p| p[:reminder].present? }
      message = if needed_reminding.any?
          message_body = needed_reminding.reduce("") do |acc, person|
            acc + "**#{person[:forecast_data]["first_name"]} #{person[:forecast_data]["last_name"]} (#{person[:studio]})**
#{person[:reminder_body]}
"
          end
          <<~HEREDOC
            👋 Hi Operations Team!

            I've just reminded the following people to add missing hours:

            #{message_body}

            🙏 Thank you!
          HEREDOC
        end

      message_operations_team(message) if message.present?
    end

    def find_relevant_weeks
      today = Date.today
      ranges = []
      working_day = today
      discovered_all_ranges = false
      looked_back_an_extra_week = false
      loop do
        prev_week_monday = (working_day.beginning_of_week.last_week)
        prev_week_friday = (working_day.beginning_of_week.last_week + 4)
        ranges.push({ monday: prev_week_monday, friday: prev_week_friday, assignments: nil })
        working_day = working_day - 1.week

        discovered_all_ranges = prev_week_friday.month < today.month
        break if discovered_all_ranges
      end
      ranges.reverse
    end
  end
end
