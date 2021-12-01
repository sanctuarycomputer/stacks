class Stacks::Utilization
  # TODO: DRY these up
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
      time_start = Date.new(2021, 1, 1)
      time_end = 0.seconds.ago
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
        project = projects.find {|p| p["id"] == a["project_id"]}
        client = clients.find {|c| c["id"] == project["client_id"]}

        allocation =
          (allocation_in_seconds_for_assignment(start_of_month, project, a) / 60 / 60)

        is_time_off = project["name"] == "Time Off" && project["harvest_id"].nil?
        is_non_billable = client && STUDIOS.include?(:"#{client["name"]}")

        acc[person["email"]] = acc[person["email"]] || {
          time_off: 0,
          non_billable: 0,
          billable: [],
          total: 0
        }

        acc[person["email"]][:total] += allocation
        if is_time_off
          acc[person["email"]][:time_off] += allocation
        elsif is_non_billable
          acc[person["email"]][:non_billable] += allocation
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
            acc[person["email"]][:billable].find {|u| u[:hourly_rate] == hourly_rate}
          if existing
            existing[:allocation] += allocation
          else
            acc[person["email"]][:billable] << {
              hourly_rate: hourly_rate,
              allocation: allocation
            }
          end
        end

        acc
      end
    end
  end
end
