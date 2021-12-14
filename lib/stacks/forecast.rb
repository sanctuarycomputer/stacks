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
