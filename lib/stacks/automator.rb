class Stacks::Automator
  class << self
    FORTY_HOURS_IN_SECONDS = 144000
    EIGHT_HOURS_IN_SECONDS = 28800

    def remind_people_to_record_hours
      forecast = Stacks::Automator::Forecast.new
      twist = Stacks::Automator::Twist.new
      twist_users = twist.get_workspace_users.parsed_response

      # Discover every full week prior to the current week that contains days within this month
      relevant_weeks = find_relevant_weeks
      relevant_weeks.each do |week|
        week[:assignments] = forecast.assignments(
          week[:monday].strftime('%Y-%m-%dT%H:%M:%S.%L%z'),
          week[:friday].strftime('%Y-%m-%dT%H:%M:%S.%L%z')
        )["assignments"]
      end

      # Get the full team & decorate with their assignments
      people = forecast.people["people"].reject{|p| p["archived"] }.map do |person|
        twist_user = twist_users.find do |twist_user|
          twist_user["email"].downcase == person["email"].downcase ||
          twist_user["name"].downcase == "#{person["first_name"]} #{person["last_name"]}".downcase
        end

        assignments_by_week = relevant_weeks.map do |week|
          assignments = week[:assignments].filter{|a| a["person_id"] == person["id"]}
          total_allocation_in_seconds = assignments.reduce(0) do |acc, a|
            # A nil allocation is a full day of "Time Off" in Harvest Forecast
            days = (Date.parse(a["end_date"]) - Date.parse(a["start_date"])).to_i + 1

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
        weeks_missing_hours = assignments_by_week.select{|abw| abw[:total_allocation_in_seconds] < FORTY_HOURS_IN_SECONDS}
        reminder_body =
          if weeks_missing_hours.any?
            weeks_missing_hours.reduce("") do |acc, week|
              acc + "#{week[:monday].to_formatted_s(:short)} - #{week[:friday].to_formatted_s(:short)}: Missing #{(FORTY_HOURS_IN_SECONDS - week[:total_allocation_in_seconds].to_f) / 60 / 60} hours\n"
            end
          end

        reminder =
          if reminder_body.present?
            <<~HEREDOC
              👋 Hi #{person["first_name"]}!

              I just wanted to let you know that we're missing hours for you:

              #{reminder_body}

              - [Please fill them out when you get a chance.](https://forecastapp.com/864444/schedule/team) (And remember that [Time Off](https://help.getharvest.com/forecast/schedule/plan/scheduling-time-off/) or Internal Work also needs to be recorded!)

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
          reminder: reminder
        }
      end

      hugh = people.find{|p| p[:twist_data]["email"] == "hugh@sanctuary.computer" }
      people.each do |person|
        if person[:reminder].present? && person[:twist_data].present?
          conversation = twist.get_or_create_conversation("#{person[:twist_data]["id"]},#{hugh[:twist_data]["id"]}")
          twist.add_message_to_conversation(conversation["id"], person[:reminder])
          sleep(1)
        end
      end

      needed_reminding = people.select{|p| p[:reminder].present?}
      conversation = twist.get_or_create_conversation("#{hugh[:twist_data]["id"]}")
      twist.add_message_to_conversation(conversation["id"], "Reminder Successful. #{needed_reminding.count}x people needed reminding!")
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

        # Check if the Friday is in the previous month
        discovered_all_ranges = prev_week_friday.month < today.month
        break if discovered_all_ranges

        ranges.push({ monday: prev_week_monday, friday: prev_week_friday, assignments: nil })
        working_day = working_day - 1.week
      end
      ranges.reverse
    end
  end

  class Twist
    include HTTParty
    base_uri 'api.twist.com/api/v3'

    def initialize()
      @headers = {
        "Authorization": "Bearer #{Stacks::Utils.config[:twist][:token]}",
      }
    end

    def get_default_workspace
      self.class.get("/workspaces/get_default", headers: @headers)
    end

    def get_workspace_users
      self.class.get("/workspaces/get_users?id=#{Stacks::Utils.config[:twist][:workspace_id]}", headers: @headers)
    end

    def get_or_create_conversation(user_ids_as_comma_seperated_string)
      self.class.post("/conversations/get_or_create", {
        headers: @headers,
        body: {
          workspace_id: Stacks::Utils.config[:twist][:workspace_id],
          user_ids: "[#{user_ids_as_comma_seperated_string}]"
        }
      })
    end

    def add_message_to_conversation(conversation_id, content)
      self.class.post("/conversation_messages/add", {
        headers: @headers,
        body: {
          conversation_id: conversation_id,
          content: content,
        }
      })
    end
  end


  class Forecast
    include HTTParty
    base_uri 'api.forecastapp.com'

    def initialize()
      @headers = {
        "Forecast-Account-ID": "#{Stacks::Utils.config[:forecast][:account_id]}",
        "Authorization": "Bearer #{Stacks::Utils.config[:forecast][:token]}",
        "User-Agent": "Stacks Automator"
      }
    end

    def current_user
      self.class.get("/current_user", headers: @headers)
    end

    def clients
      self.class.get("/clients", headers: @headers)
    end

    def people
      self.class.get("/people", headers: @headers)
    end

    def projects
      self.class.get("/projects", headers: @headers)
    end

    def assignments(start_date, end_date)
      query = {}
      query["start_date"] = start_date if start_date.present?
      query["end_date"] = end_date if end_date.present?
      self.class.get("/assignments", headers: @headers, query: query)
    end

    # Date.new(2001,2,25)
    def milestones(start_date, end_date)
      query = {}
      query["start_date"] = start_date if start_date.present?
      query["end_date"] = end_date if end_date.present?
      self.class.get("/milestones", headers: @headers, query: query)
    end

    def roles
      self.class.get("/roles", headers: @headers)
    end
  end
end
