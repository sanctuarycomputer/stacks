class ProjectTracker < ApplicationRecord
  validates :name, presence: :true
  validates_numericality_of :budget_low_end,
    if: :validate_budgets?
  validates_numericality_of :budget_high_end,
    greater_than_or_equal_to: :budget_low_end, if: :validate_budgets?

  has_one :project_capsule, dependent: :delete
  has_many :project_tracker_links, dependent: :delete_all
  accepts_nested_attributes_for :project_tracker_links, allow_destroy: true

  has_many :project_tracker_forecast_projects, dependent: :delete_all
  has_many :forecast_projects, through: :project_tracker_forecast_projects
  accepts_nested_attributes_for :project_tracker_forecast_projects, allow_destroy: true

  has_many :atc_periods, dependent: :delete_all
  accepts_nested_attributes_for :atc_periods, allow_destroy: true

  belongs_to :atc, class_name: "AdminUser", optional: true

  def current_atc
    current_atc_period.try(:admin_user)
  end

  def current_atc_period
    atc_periods.find do |atc_period|
      atc_period.period_started_at <= Date.today && atc_period.period_ended_at.nil?
    end
  end

  def ensure_project_capsule_exists!
    ProjectCapsule.find_or_create_by!(project_tracker: self)
  end

  def validate_budgets?
    budget_low_end.present? || budget_high_end.present?
  end

  def invoice_trackers
    its = InvoiceTracker
      .includes(:invoice_pass)
      .all
      .select{|it| (it.forecast_project_ids & forecast_projects.map(&:forecast_id)).any?}
      .sort{|a, b| a.invoice_pass.start_of_month <=> b.invoice_pass.start_of_month}
      .reverse
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
        :capsule_pending
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

  def first_recorded_assignment
    forecast_project_ids = forecast_projects.map(&:forecast_id)
    ForecastAssignment
      .where(project_id: forecast_project_ids)
      .order(start_date: :asc)
      .limit(1)
      .first
  end

  def last_recorded_assignment
    forecast_project_ids = forecast_projects.map(&:forecast_id)
    ForecastAssignment
      .where(project_id: forecast_project_ids)
      .order(start_date: :desc)
      .limit(1)
      .first
  end

  def invoiced_spend
    forecast_project_ids = forecast_projects.map(&:forecast_id) || []
    invoice_trackers.map(&:blueprint_diff).reduce(0.0) do |acc, itbd|
      acc +=
        (itbd["lines"].values.reduce(0.0) do |agr, line|
          next agr unless forecast_project_ids.include?(line["forecast_project"])
          next agr if line["diff_state"] == "removed"
          quantity = line["quantity"].is_a?(Array) ? line["quantity"][1] : line["quantity"]
          unit_price = line["unit_price"].is_a?(Array) ? line["unit_price"][1] : line["unit_price"]
          agr += (quantity * unit_price)
        end || 0.0)
    end
  end

  def running_spend
    forecast_project_ids = forecast_projects.map(&:forecast_id)
    today = Date.today

    assignments =
      ForecastAssignment
        .includes(:forecast_project)
        .where(project_id: forecast_project_ids)

    if invoice_trackers.any?
      last_day_covered_by_invoice_trackers = invoice_trackers
        .first
        .invoice_pass
        .start_of_month
        .end_of_month
      assignments = assignments
        .where(
          'end_date >= ? AND start_date <= ?',
          last_day_covered_by_invoice_trackers + 1.day,
          today + 1.year
        )
      assignments.reduce(0) do |acc, a|
        acc += a.value_during_range_in_usd(
          last_day_covered_by_invoice_trackers + 1.day,
          today + 1.year
        )
      end || 0
    else
      assignments.reduce(0) do |acc, a|
        acc += a.value_in_usd
      end || 0
    end
  end
end
