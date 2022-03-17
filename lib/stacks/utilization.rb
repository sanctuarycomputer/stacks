class Stacks::Utilization
  # TODO: DRY these up
  START_AT = Date.new(2021, 6, 1)
  EIGHT_HOURS_IN_SECONDS = 28800
  DEFAULT_HOURLY_RATE = 145
  STUDIO_TO_SERVICE_MAPPING = {
    "XXIX": "Brand Services",
    "Manhattan Hydraulics": "UX Services",
    "Sanctuary Computer": "Development Services",
    "garden3d": "Services",
  }
  STUDIOS = STUDIO_TO_SERVICE_MAPPING.keys

  class << self
    def forecast
      @_forecast ||= Stacks::Forecast.new
    end

    def calculate
      data = {}
      time_start = START_AT
      time_end = Date.today.last_month.end_of_month
      time = time_start
      while time < time_end
        year_as_sym = time.strftime("%Y").to_sym
        month_as_sym = time.strftime("%B").downcase.to_sym
        data[year_as_sym] = data[year_as_sym] || {}
        data[year_as_sym][month_as_sym] =
          data[year_as_sym][month_as_sym] || {}

        data[year_as_sym][month_as_sym] = make_utilizations_for_month(time)
        time = time.advance(months: 1)
      end

      new_utilization_pass = UtilizationPass.create!(data: data)
      UtilizationPass.where.not(id: new_utilization_pass.id).delete_all
    end

    def allocation_in_seconds_for_assignment(start_of_month, project, a)
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

      days = if project["name"] == "Time Off" && a["allocation"].nil?
          # If this allocation is for the "Time Off" project, filter time on weekends!
          (start_date..end_date).select { |d| (1..5).include?(d.wday) }.size
        else
          # This allocation is not for "Time Off", so count work done on weekends.
          (end_date - start_date).to_i + 1
        end

      # Time Off has a nil allocation
      per_day_allocation = a["allocation"].nil? ? EIGHT_HOURS_IN_SECONDS : a["allocation"]
      (per_day_allocation * days).to_f
    end

    # TODO: Use Stacks::Utils.studios_for_email
    def studio_for_forecast_person(person)
      studios = (STUDIOS.map(&:to_s) & person["roles"])
      return studios.first if studios.length >= 1
      "None"
    end

    def make_utilizations_for_month(start_of_month)
      people = forecast.people()["people"]
      projects = forecast.projects()["projects"]
      clients = forecast.clients()["clients"]
      assignments = forecast.assignments(
        start_of_month.beginning_of_month,
        start_of_month.end_of_month,
      )["assignments"]

      assignments.reduce({}) do |acc, a|
        person = people.find {|p| p["id"] == a["person_id"]}
        user = AdminUser.find_by(email: person["email"])
        next acc unless user.present?

        studio = studio_for_forecast_person(person)
        project = projects.find {|p| p["id"] == a["project_id"]}
        client = clients.find {|c| c["id"] == project["client_id"]}

        allocation =
          (allocation_in_seconds_for_assignment(start_of_month, project, a) / 60 / 60)

        #fa = ForecastAssignment.find(a["id"])
        #binding.pry if fa.allocation_in_hours != allocation

        is_time_off = project["name"] == "Time Off" && project["harvest_id"].nil?
        is_non_billable = client && STUDIOS.include?(:"#{client["name"]}")

        acc[studio] = acc[studio] || {}
        acc[studio][person["email"]] = acc[studio][person["email"]] || {
          time_off: 0,
          non_billable: 0,
          billable: [],
          sellable: (user.working_days_between(
            start_of_month.beginning_of_month,
            start_of_month.end_of_month
          ).count * user.expected_utilization * 8),
          non_sellable: (user.working_days_between(
            start_of_month.beginning_of_month,
            start_of_month.end_of_month
          ).count * (1 - user.expected_utilization) * 8),
        }

        if is_time_off
          acc[studio][person["email"]][:time_off] += allocation
        elsif is_non_billable
          acc[studio][person["email"]][:non_billable] += allocation
        else
          hourly_rate_tags = project["tags"].filter { |t| t.ends_with?("p/h") }
          hourly_rate = if hourly_rate_tags.count == 0
              DEFAULT_HOURLY_RATE
            elsif hourly_rate_tags.count > 1
              raise :malformed
            else
              hourly_rate_tags.first.to_f
            end

          existing =
            acc[studio][person["email"]][:billable].find {|u| u[:project_id] == project["id"]}
          if existing
            existing[:allocation] += allocation
          else
            acc[studio][person["email"]][:billable] << {
              hourly_rate: hourly_rate,
              allocation: allocation,
              project_id: project["id"]
            }
          end
        end

        acc
      end
    end
  end
end
