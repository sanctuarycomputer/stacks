# Ensure that deletes are cascading
class ProjectTracker < ApplicationRecord
  validates :notion_proposal_url, url: true, allow_blank: true
  validates :name, presence: :true
  validates_numericality_of :budget_low_end,
    if: :validate_budgets?
  validates_numericality_of :budget_high_end,
    greater_than_or_equal_to: :budget_low_end, if: :validate_budgets?

  has_many :project_tracker_links
  accepts_nested_attributes_for :project_tracker_links, allow_destroy: true

  has_many :project_tracker_forecast_projects
  has_many :forecast_projects, through: :project_tracker_forecast_projects
  accepts_nested_attributes_for :project_tracker_forecast_projects, allow_destroy: true

  def validate_budgets?
    budget_low_end.present? || budget_high_end.present?
  end

  def last_month_hours
    forecast_projects.reduce(0) do |acc, fp|
      acc += fp.total_hours_during_range(Date.today.last_month.beginning_of_month, Date.today.last_month.end_of_month)
    end
  end

  def last_month_value
    forecast_projects.reduce(0) do |acc, fp|
      acc += fp.total_value_during_range(Date.today.last_month.beginning_of_month, Date.today.last_month.end_of_month)
    end
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

  def invoiced_spend
    forecast_project_ids = forecast_projects.map(&:forecast_id)
    today = Date.today

    assignments =
      ForecastAssignment
        .includes(:forecast_project)
        .where(project_id: forecast_project_ids)

    assignments.reduce(0) do |acc, a|
      acc += a.value_during_range_in_usd(
        Date.new(2015, 1, 1),
        today.last_month.end_of_month
      )
    end || 0
  end

  def running_spend
    forecast_project_ids = forecast_projects.map(&:forecast_id)
    today = Date.today

    assignments =
      ForecastAssignment
        .includes(:forecast_project)
        .where(project_id: forecast_project_ids)
        .where('end_date >= ? AND start_date <= ?', today.beginning_of_month, today.end_of_month)

    assignments.reduce(0) do |acc, a|
      acc += a.value_during_range_in_usd(
        today.beginning_of_month,
        today.end_of_month
      )
    end || 0
  end
end
