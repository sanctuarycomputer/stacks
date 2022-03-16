# Ensure that deletes are cascading
class ProjectTracker < ApplicationRecord
  validates :name, presence: :true
  validates_numericality_of :budget_low_end,
    if: :validate_budgets?
  validates_numericality_of :budget_high_end,
    greater_than_or_equal_to: :budget_low_end, if: :validate_budgets?

  has_one :project_capsule
  has_many :project_tracker_links
  accepts_nested_attributes_for :project_tracker_links, allow_destroy: true

  has_many :project_tracker_forecast_projects
  has_many :forecast_projects, through: :project_tracker_forecast_projects
  accepts_nested_attributes_for :project_tracker_forecast_projects, allow_destroy: true

  def ensure_project_capsule_exists!
    ProjectCapsule.find_or_create_by!(project_tracker: self)
  end

  def validate_budgets?
    budget_low_end.present? || budget_high_end.present?
  end

  def invoice_trackers
    its =
      InvoiceTracker
        .includes(:invoice_pass)
        .all
        .select{|it| (it.forecast_project_ids & forecast_projects.map(&:forecast_id)).any?}
        .sort{|a, b| a.invoice_pass.start_of_month <=> b.invoice_pass.start_of_month}
        .reverse
    qbo_invoice_ids =
      its.map(&:qbo_invoice_id).compact
    qbo_invoices =
      Stacks::Automator.fetch_invoices_by_ids(qbo_invoice_ids).reduce({}) do |acc, qbo_inv|
        acc[qbo_inv.id] = qbo_inv
        acc
      end
    its.each do |it|
      it._qbo_invoice = qbo_invoices[it.qbo_invoice_id] if it.qbo_invoice_id.present?
    end
    its
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

  def work_status
    if work_completed_at.nil?
      :in_progress
    else
      if project_capsule.present? && project_capsule.complete?
        :complete
      else
        :project_capsule_pending
      end
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

  def revenue
    current_spend = (invoiced_spend + running_spend)
    if budget_high_end.present?
      [current_spend, budget_high_end].min
    elsif budget_low_end.present?
      [current_spend, budget_low_end].min
    else
      current_spend
    end
  end

  def estimated_cost
    cost = 0
    units_rollup = Stacks::Economics.units_rollup

    # We use a weighted average for December, as
    # that's the month we'll usually give out profit
    # share, so that throws the values here out of whack.
    a = units_rollup.map do |k, v|
      next nil if k.include?("December")
      [v["cost_per_billable_hour"], v["billable"]]
    end.compact
    average_cost_per_billable_hour =
      a.reduce(0) { |m,r| m += r[0] * r[1] } / a.reduce(0) { |m,r| m += r[1] }.to_f

    time = Date.new(2020, 1, 1)
    while time <= Date.today.beginning_of_month
      hours =
        forecast_projects.reduce(0) do |acc, fp|
          acc += fp.total_hours_during_range(time.beginning_of_month, time.end_of_month)
        end

      if hours > 0
        month = time.strftime("%B")
        label = "#{time.strftime("%B")}, #{time.year}"
        cost_per_billable_hour =
          if month == "December" || units_rollup[label].nil?
            average_cost_per_billable_hour
          else
            (units_rollup[label] && units_rollup[label]["cost_per_billable_hour"])
          end
        cost += hours * cost_per_billable_hour
      end

      time = time.advance(months: 1)
    end

    cost
  end

  def raw_resourcing_cost
    forecast_project_ids = forecast_projects.map(&:forecast_id)
    today = Date.today

    assignments =
      ForecastAssignment
        .includes(:forecast_project)
        .where(project_id: forecast_project_ids)

    assignments.reduce(0) do |acc, a|
      acc += a.raw_resourcing_cost_during_range_in_usd(
        Date.new(2015, 1, 1),
        today
      )
    end || 0
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
