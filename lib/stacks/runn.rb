class Stacks::Runn
  include HTTParty
  base_uri 'https://api.runn.io'

  def initialize()
    @headers = {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "Accept-Version": "1.0.0",
      "Authorization": "Bearer #{Stacks::Utils.config[:runn][:api_token]}",
    }
  end

  def handle_response(&block)
    return if block.nil?
    retry_count = 0
    begin
      response = block.call
      raise response.to_s unless response.success?
      response
    rescue => e
      raise e unless JSON.parse(e.try(:message))["statusCode"] == 429
      raise e unless retry_count < 5

      retry_count += 1
      puts "~~~> Sleeping 61.seconds then retrying for the #{retry_count} time"
      sleep(61.seconds)
      retry
    end
  end

  def sync_all!
    all_projects = get_projects()

    ActiveRecord::Base.transaction do
      sync_projects!(all_projects)
    end
  end

  def get_people
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/people?cursor=#{next_cursor}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  def get_projects
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/projects?cursor=#{next_cursor}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  def get_roles
    values = []
    next_cursor = nil
    loop do
      response = self.class.get("/roles?cursor=#{next_cursor}", headers: @headers)
      raise response.to_s unless response.success?
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  def get_actuals_for_project(project_id)
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/actuals?projectId=#{project_id}&cursor=#{next_cursor}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  def sync_projects!(all_projects = get_projects())
    data = all_projects.map do |c|
      {
        runn_id: c["id"],
        name: c["name"],
        is_template: c["isTemplate"],
        is_archived: c["isArchived"],
        is_confirmed: c["isConfirmed"],
        pricing_model: c["pricingModel"],
        rate_type: c["rateType"],
        budget: c["budget"],
        expenses_budget: c["expensesBudget"],
        # Stacks doesn't need to know about these for now,
        # but we can backfill in the future if necessary
        #runn_team_id: c["teamId"],
        #runn_client_id: c["clientId"],
        #runn_rate_card_id: c["rateCardId"],
        created_at: c["createdAt"],
        updated_at: c["UpdatedAt"],
        data: c,
      }
    end
    RunnProject.upsert_all(data, unique_by: :runn_id)
  end

  def create_or_update_actual(date, billable_minutes, runn_person_id, runn_project_id, runn_role_id)
    handle_response {
      self.class.post("/actuals", {
        body: JSON.dump({
          "date": date,
          "billableMinutes": billable_minutes,
          "nonbillableMinutes": 0,
          "personId": runn_person_id,
          "projectId": runn_project_id,
          "roleId": runn_role_id
        }),
        headers: @headers
      })
    }
  end

  def create_role(name, default_hour_cost, standard_rate)
     handle_response {
        self.class.post("/roles/", {
        body: JSON.dump({
          "name": name,
          "defaultHourCost": default_hour_cost,
          "standardRate": standard_rate
        }),
        headers: @headers
      })
    }
  end

  def create_person(first_name, last_name, email, role_id)
    handle_response {
      self.class.post("/people/", {
        body: JSON.dump({
          "firstName": first_name,
          "lastName": last_name,
          "email": email,
          "roleId": role_id
        }),
        headers: @headers
      })
    }
  end
end