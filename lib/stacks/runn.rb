class Stacks::Runn
  include HTTParty
  base_uri 'api.runn.io'

  def initialize()
    @headers = {
      "Accept": "application/json",
      "Accept-Version": "1.0.0",
      "Authorization": "Bearer #{Stacks::Utils.config[:runn][:api_token]}",
    }
  end

  def sync_all!
    all_projects = get_projects()

    ActiveRecord::Base.transaction do
      RunnProject.delete_all
      sync_projects!(all_projects)
    end
  end

  def get_people
    values = []
    next_cursor = nil
    loop do
      response = self.class.get("/people?cursor=#{next_cursor}", headers: @headers)
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
      response = self.class.get("/projects?cursor=#{next_cursor}", headers: @headers)
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
    response = self.class.post("/actuals", {
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
    binding.pry
    response
  end
end