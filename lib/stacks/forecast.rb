class Stacks::Forecast
  include HTTParty
  base_uri 'api.forecastapp.com'

  def initialize()
    @headers = {
      "Forecast-Account-ID": "#{Stacks::Utils.config[:forecast][:account_id]}",
      "Authorization": "Bearer #{Stacks::Utils.config[:forecast][:token]}",
      "User-Agent": "Stacks Automator"
    }
  end

  def sync_all!
    sync_clients!
    sync_people!
    sync_projects!
    sync_all_assignments!
  end

  def sync_clients!
    data = clients()["clients"].map do |c|
      {
        forecast_id: c["id"],
        name: c["name"],
        harvest_id: c["harvest_id"],
        archived: c["archived"],
        updated_at: c["updated_at"],
        updated_by_id: c["updated_by_id"],
        data: c,
      }
    end
    ForecastClient.upsert_all(data, unique_by: :forecast_id)
  end

  def sync_people!
    data = people()["people"].map do |c|
      {
        forecast_id: c["id"],
        first_name: c["first_name"],
        last_name: c["last_name"],
        email: c["email"],
        archived: c["archived"],
        roles: c["roles"],
        updated_at: c["updated_at"],
        updated_by_id: c["updated_by_id"],
        data: c,
      }
    end
    ForecastPerson.upsert_all(data, unique_by: :forecast_id)
  end

  def sync_projects!
    data = projects()["projects"].map do |c|
      {
        forecast_id: c["id"],
        name: c["name"],
        code: c["code"],
        notes: c["notes"],
        start_date: c["start_date"],
        end_date: c["end_date"],
        harvest_id: c["harvest_id"],
        archived: c["archived"],
        client_id: c["client_id"],
        tags: c["tags"],
        updated_at: c["updated_at"],
        updated_by_id: c["updated_by_id"],
        data: c,
      }
    end
    ForecastProject.upsert_all(data, unique_by: :forecast_id)
  end

  def sync_assignments!(start_date = Date.today, end_date = Date.today)
    data = assignments(start_date, end_date)["assignments"].map do |c|
      {
        forecast_id: c["id"],
        start_date: c["start_date"],
        end_date: c["end_date"],
        allocation: c["allocation"],
        notes: c["notes"],
        updated_at: c["updated_at"],
        updated_by_id: c["updated_by_id"],
        project_id: c["project_id"],
        person_id: c["person_id"],
        placeholder_id: c["placeholder_id"],
        repeated_assignment_set_id: c["repeated_assignment_set_id"],
        active_on_days_off: c["active_on_days_off"],
        data: c,
      }
    end
    ForecastAssignment.upsert_all(data, unique_by: :forecast_id)
  end

  def sync_all_assignments!
    time_start = DateTime.parse("1st Jan 2020")
    time_end = 0.seconds.ago
    time = time_start
    while time < time_end
      sync_assignments!(time.beginning_of_month, time.end_of_month)
      time = time.advance(months: 1)
    end
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

  def assignments(start_date, end_date, project_id = nil)
    query = {}
    query["start_date"] = start_date if start_date.present?
    query["end_date"] = end_date if end_date.present?
    query["project_id"] = project_id if project_id.present?
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
