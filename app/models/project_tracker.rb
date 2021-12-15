# Ensure that deletes are cascading
# Running Spend should not call Forecast's API
class ProjectTracker < ApplicationRecord
  validates :notion_proposal_url, url: true, allow_blank: true
  validates :name, presence: :true
  validates_numericality_of :budget_low_end,
    if: :validate_budgets?
  validates_numericality_of :budget_high_end,
    greater_than_or_equal_to: :budget_low_end, if: :validate_budgets?

  has_many :project_tracker_forecast_projects
  has_many :forecast_projects, through: :project_tracker_forecast_projects
  accepts_nested_attributes_for :project_tracker_forecast_projects, allow_destroy: true

  def validate_budgets?
    budget_low_end.present? || budget_high_end.present?
  end

  def status
    if budget_low_end.nil? && budget_high_end.nil?
      return :no_budget
    end

    total = invoiced_spend + running_spend
    if total < budget_low_end
      :under_budget
    elsif (total >= budget_low_end && total < budget_high_end)
      :at_budget
    else
      :over_budget
    end
  end

  def tracker_allocations
    forecast_project_ids = forecast_projects.map(&:forecast_id)
    data = {}
    time_start = Stacks::Utilization::START_AT
    time_end = Date.today.last_month.end_of_month
    time = time_start
    while time < time_end
      year_as_sym = time.strftime("%Y").to_sym
      month_as_sym = time.strftime("%B").downcase.to_sym
      data[year_as_sym] = data[year_as_sym] || {}
      data[year_as_sym][month_as_sym] =
        data[year_as_sym][month_as_sym] || {}
      data[year_as_sym][month_as_sym] = tracker_allocations_for_month(
        year_as_sym,
        month_as_sym,
        forecast_project_ids
      )
      time = time.advance(months: 1)
    end
    data
  end

  def invoiced_spend
    tracker_allocations
      .values
      .map{|t| t.values.flatten}
      .flatten
      .map{|r| r["allocation"] * r["hourly_rate"]}
      .reduce(:+) || 0
  end

  def running_spend
    forecast_project_ids = forecast_projects.map(&:forecast_id)

    forecast = Stacks::Forecast.new
    projects = forecast.projects()["projects"]
    today = Date.today
    assignments = forecast.assignments(
      today.beginning_of_month,
      today.end_of_month,
    )["assignments"]

    assignments.reduce(0) do |acc, a|
      next acc unless forecast_project_ids.include?(a["project_id"].to_s)

      project = projects.find {|p| p["id"] == a["project_id"]}
      hourly_rate_tags = project["tags"].filter { |t| t.ends_with?("p/h") }
      hourly_rate = if hourly_rate_tags.count == 0
          Stacks::Utilization::DEFAULT_HOURLY_RATE
        elsif hourly_rate_tags.count > 1
          raise :malformed
        else
          hourly_rate_tags.first.to_f
        end
        hours =
          (Stacks::Utilization.allocation_in_seconds_for_assignment(
            today.beginning_of_month,
            project,
            a
          ) / 60 / 60)
      acc += (hours * hourly_rate)
      acc
    end || 0
  end

  def tracker_allocations_for_month(year_as_sym, month_as_sym, forecast_project_ids)
    utilization_pass = UtilizationPass.first
    monthly_data =
      utilization_pass.data[year_as_sym.to_s][month_as_sym.to_s]
    monthly_data.values.reduce([]) do |acc, u|
      allocations = (u.values.map do |v|
        allocation = v["billable"].find do |r|
          forecast_project_ids.include?(r["project_id"].to_s)
        end
      end).compact
      [*acc, *allocations]
    end
  end
end
