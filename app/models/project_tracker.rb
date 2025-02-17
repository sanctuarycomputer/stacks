class ProjectTracker < ApplicationRecord
  validates :name, presence: :true
  validate :has_msa_and_sow_links
  validate :no_forecast_projects_missing_project_code
  validate :no_forecast_project_code_collisions
  after_initialize :set_targets

  validates_presence_of :budget_low_end,
    message: 'We should almost never commit to a fixed budget, but if we must, you can set "Budget Low End" and "Budget High End" to the same value.',
    if: :budget_high_end?
  validates_presence_of :budget_high_end,
    message: 'We should almost never commit to a fixed budget, but if we must, you can set "Budget Low End" and "Budget High End" to the same value.', if: :budget_low_end?
  validates_numericality_of :budget_low_end,
    less_than_or_equal_to: :budget_high_end,
    if: :validate_budgets?
  validates_numericality_of :budget_high_end,
    greater_than_or_equal_to: :budget_low_end,
    if: :validate_budgets?

  has_one :project_capsule, dependent: :delete
  has_many :project_tracker_links, dependent: :delete_all
  accepts_nested_attributes_for :project_tracker_links, allow_destroy: true

  has_many :project_tracker_forecast_to_runn_sync_tasks, dependent: :delete_all

  has_many :adhoc_invoice_trackers, dependent: :delete_all
  accepts_nested_attributes_for :adhoc_invoice_trackers, allow_destroy: true

  has_many :project_tracker_forecast_projects, dependent: :delete_all
  has_many :forecast_projects, through: :project_tracker_forecast_projects
  accepts_nested_attributes_for :project_tracker_forecast_projects, allow_destroy: true

  has_many :project_tracker_zenhub_workspaces, dependent: :delete_all
  has_many :zenhub_workspaces, through: :project_tracker_zenhub_workspaces
  accepts_nested_attributes_for :project_tracker_zenhub_workspaces, allow_destroy: true

  has_many :forecast_assignments, through: :forecast_projects

  belongs_to :runn_project, class_name: "RunnProject", foreign_key: "runn_project_id", primary_key: "runn_id", optional: true

  has_many :project_lead_periods, dependent: :delete_all
  accepts_nested_attributes_for :project_lead_periods, allow_destroy: true
  has_many :project_leads, through: :project_lead_periods, source: :admin_user

  has_many :project_safety_representative_periods, dependent: :delete_all
  accepts_nested_attributes_for :project_safety_representative_periods, allow_destroy: true
  has_many :project_safety_representatives, through: :project_safety_representative_periods, source: :admin_user

  has_many :creative_lead_periods, dependent: :delete_all
  accepts_nested_attributes_for :creative_lead_periods, allow_destroy: true
  has_many :creative_leads, through: :creative_lead_periods, source: :admin_user

  has_many :technical_lead_periods, dependent: :delete_all
  accepts_nested_attributes_for :technical_lead_periods, allow_destroy: true
  has_many :technical_leads, through: :technical_lead_periods, source: :admin_user

  scope :complete, -> {
    where.not(work_completed_at: nil)
      .includes(:project_capsule).where(
        project_capsules: { id: ProjectCapsule.complete }
      )
  }

  scope :in_progress , -> {
    where.not(id: complete)
  }

  def self.capsule_pending
    ProjectTracker.where.not(work_completed_at: nil).select do |pt|
      pt.work_status == :capsule_pending
    end
  end

  def self.likely_complete
    ProjectTracker.where(work_completed_at: nil).select do |pt|
      if pt.last_recorded_assignment
        pt.last_recorded_assignment.end_date < (Date.today -  1.month)
      else
        false
      end
    end.reject do |pt|
      downcased_name = pt.name.downcase
      downcased_name.include?("ongoing") || downcased_name.include?("retainer")
    end
  end

  def forecast_projects
    @_forecast_projects ||= super
  end

  def runn_project
    @_runn_project ||= super
  end

  def external_link
    "https://stacks.garden3d.net/admin/project_trackers/#{id}"
  end

  def considered_ongoing?
    downcased_name = name.downcase
    downcased_name.include?("ongoing") || downcased_name.include?("retainer")
  end

  def likely_should_be_marked_as_completed?
    return false if considered_ongoing?
    if last_recorded_assignment
      last_recorded_assignment.end_date < (Date.today -  1.month)
    else
      false
    end
  end

  def latest_forecast_to_runn_sync_task
    project_tracker_forecast_to_runn_sync_tasks.where.not(settled_at: nil).order('settled_at DESC').first
  end

  def set_targets
    unless self.id.present?
      self.target_free_hours_percent = Stacks::System.singleton_class::DEFAULT_PROJECT_TRACKER_TARGET_FREE_HOURS_PERCENT if self.target_free_hours_percent == 0
      self.target_profit_margin = Stacks::System.singleton_class::DEFAULT_PROJECT_TRACKER_TARGET_PROFIT_MARGIN if self.target_profit_margin == 0
    end
  end

  def considered_successful?
    if work_status == :complete
      client_satisfied? && target_profit_margin_satisfied? && target_free_hours_ratio_satisfied?
    else
      target_profit_margin_satisfied? && target_free_hours_ratio_satisfied?
    end
  end

  def client_satisfied?
    return nil if work_status != :complete
    project_capsule.client_satisfaction_status == "satisfied"
  end

  def target_profit_margin_satisfied?
    return true if target_profit_margin <= 0
    profit_margin >= target_profit_margin
  end

  def target_free_hours_ratio_satisfied?
    (free_hours_ratio * 100) <= target_free_hours_percent
  end

  def has_recorded_hours_after_today?
    (last_recorded_assignment.try(:end_date) || Date.today) > Date.today
  end

  def has_msa_and_sow_links
    unless project_tracker_links.find{|l| l.link_type == "msa"}.present?
      errors.add(:base, "An MSA Project URL must be present.")
    end

    unless project_tracker_links.find{|l| l.link_type == "sow"}.present?
      errors.add(:base, "An SOW/PD Project URL must be present.")
    end
  end

  def no_forecast_projects_missing_project_code
    return if (created_at || Date.today) < Date.new(2024,1,5) # Only apply this validation going forward

    associated_forecast_codes = project_tracker_forecast_projects.map(&:forecast_project).map(&:code)
    if associated_forecast_codes.any?(nil) || associated_forecast_codes.any?("")
      errors.add(:base, "You are trying to connect a Forecast Project that is missing a Project Code. Please add a Project Code in Forecast, wait for Forecast to resync (every 10 minutes), and try again.")
    end
  end

  def no_forecast_project_code_collisions
    return if (created_at || Date.today) < Date.new(2024,1,5) # Only apply this validation going forward

    associated_forecast_codes = project_tracker_forecast_projects.map(&:forecast_project).map(&:code)
    taken_forecast_codes = ForecastProject.forecast_codes_already_associated_to_project_tracker(self.id)
    cant_associate = taken_forecast_codes.intersection(associated_forecast_codes)
    if cant_associate.length > 0
      errors.add(:base, "Forecast Project Codes: #{cant_associate.join(" ,")} are already used by another in Project Tracker. Please either use a new Project Code in Forecast OR add connect this Forecast Project/s to the existing Project Tracker.")
    end
  end

  def make_adhoc_snapshot(period = 7.days)
    preloaded_studios = Studio.all

    snapshot = (
      (Date.today - period)..
      Date.today
    ).reduce({
      hours: [],
      spend: [],
      hours_total: 0,
      spend_total: 0,
    }) do |acc, date|
      hours_by_studio = self.total_hours_during_range_by_studio(preloaded_studios, date, date)
      hours = hours_by_studio.values.reduce(:+) || 0

      acc[:hours].push({
        x: date.iso8601,
        y: acc[:hours_total] += hours
      })

      acc[:spend].push({
        x: date.iso8601,
        y: acc[:spend_total] +=
          self.total_value_during_range(date, date)
      })
      acc
    end
  end

  def generate_snapshot!(bing = false)
    cosr = cost_of_services_rendered
    today = Date.today

    invoiced_income_total = (
      forecast_project_ids = forecast_projects.map(&:forecast_id) || []

      from_generated_invoices =
        invoice_trackers.reduce(0.0) do |acc, it|
          acc += it.qbo_line_items_relating_to_forecast_projects(forecast_projects).map{|qbo_li| qbo_li.dig("amount").to_f}.reduce(&:+) || 0
        end

      from_adhoc_invoices =
        (adhoc_invoice_trackers.reduce(0.0) do |acc, ahit|
          acc += ahit.qbo_line_items_relating_to_forecast_projects(forecast_projects).map{|qbo_li| qbo_li.dig("amount").to_f}.reduce(&:+) || 0
        end || 0)

      from_generated_invoices + from_adhoc_invoices
    )

    invoiced_with_running_spend_total = (
      # At the start of each month, we send invoices for the previous month,
      # but there's a short window when the invoice hasn't been generated by
      # the invoicing team, BUT the month has turned. So here, we check if we're
      # in that window, and if so, we add last month's value to the spend, too.
      last_month_it = invoice_trackers.find do |it|
        it.invoice_pass.start_of_month == (Date.today - 1.month).beginning_of_month
      end
      last_month_invoiced = last_month_it&.qbo_invoice.present?

      if last_month_invoiced
        invoiced_income_total + total_value_during_range(
          Date.today.beginning_of_month,
          Date.today.end_of_month,
        )
      else
        invoiced_income_total + total_value_during_range(
          (Date.today - 1.month).beginning_of_month,
          Date.today.end_of_month,
        )
      end
    )

    aggregate_hours =
      forecast_projects.reduce({
        total: 0,
        free: 0,
      }) do |acc, fp|
        acc[:total] += fp.total_hours
        acc[:free] += fp.total_hours if fp.hourly_rate == 0
        acc
      end

    snapshot = (
      (self.first_recorded_assignment.try(:start_date) || Date.today)..
      [(self.last_recorded_assignment.try(:end_date) || Date.today), today].min
    ).reduce({
      generated_at: DateTime.now.iso8601,
      hours: [],
      spend: [],
      hours_total: 0,
      hours_free: aggregate_hours[:free],
      spend_total: 0,
      invoiced_income_total: invoiced_income_total,
      invoiced_with_running_spend_total: invoiced_with_running_spend_total,
      cash: {
        cosr: [],
        cosr_total: 0,
      },
      accrual: {
        cosr: [],
        cosr_total: 0,
      }
    }) do |acc, date|

      acc[:spend].push({
        x: date.iso8601,
        y: acc[:spend_total] +=
          self.total_value_during_range(date, date)
      })

      cosr_for_date = cosr[date]
      total_cosr_for_date = 0
      total_hours_for_date = 0

      unless cosr_for_date.blank?
        cosr_for_date.each do |studio_id, cosr_data|
          total_cosr_for_date += cosr_data[:total_cost]
          total_hours_for_date += cosr_data[:total_hours]
        end
      end

      acc[:hours].push({
        x: date.iso8601,
        y: acc[:hours_total] += total_hours_for_date
      })

      acc[:cash][:cosr].push({
        x: date.iso8601,
        y: acc[:cash][:cosr_total] += total_cosr_for_date
      })

      acc[:accrual][:cosr].push({
        x: date.iso8601,
        y: acc[:accrual][:cosr_total] += total_cosr_for_date
      })

      acc
    end

    update_attribute('snapshot', snapshot)
  end

  def free_hours_ratio
    return 0 if total_hours == 0
    return 0 if total_free_hours == 0
    total_free_hours / total_hours
  end

  def total_hours
    snapshot["hours_total"].to_f
  end

  def total_free_hours
    snapshot["hours_free"].to_f
  end

  def current_project_safety_representatives
    current_project_safety_representative_periods.map(&:admin_user)
  end

  def current_project_safety_representative_periods
    project_safety_representative_periods.select do |p|
      p.period_started_at <= Date.today && p.ended_at.nil?
    end
  end

  def current_project_leads
    current_project_lead_periods.map(&:admin_user)
  end

  def current_project_lead_periods
    project_lead_periods.select do |p|
      p.period_started_at <= Date.today && p.ended_at.nil?
    end
  end

  def current_creative_leads
    current_creative_lead_periods.map(&:admin_user)
  end

  def current_creative_lead_periods
    creative_lead_periods.select do |p|
      p.period_started_at <= Date.today && p.ended_at.nil?
    end
  end

  def current_technical_leads
    current_technical_lead_periods.map(&:admin_user)
  end

  def current_technical_lead_periods
    technical_lead_periods.select do |p|
      p.period_started_at <= Date.today && p.ended_at.nil?
    end
  end

  def ensure_project_capsule_exists!
    ProjectCapsule.find_or_create_by!(project_tracker: self)
  end

  def validate_budgets?
    budget_low_end.present? && budget_high_end.present?
  end

  def invoice_trackers
    # TODO: Speed me up, I'm naive
    InvoiceTracker
      .includes(:invoice_pass, :qbo_invoice)
      .all
      .select{|it| (it.forecast_project_ids & forecast_projects.map(&:forecast_id)).any?}
      .sort{|a, b| a.invoice_pass.start_of_month <=> b.invoice_pass.start_of_month}
      .reverse
  end

  def last_month_hours
    total_hours_during_range(
      Date.today - 1.month,
      Date.today
    )
  end

  def last_week_value
    total_value_during_range(
      Date.today - 1.week,
      Date.today
    )
  end

  def last_month_value
    total_value_during_range(
      Date.today - 1.month,
      Date.today
    )
  end

  def start_date
    (
      first_recorded_assignment ?
      first_recorded_assignment.start_date :
      Date.today
    )
  end

  def end_date
    (
      last_recorded_assignment ?
      last_recorded_assignment.end_date :
      Date.today
    )
  end

  def lifetime_value
    total_value_during_range(start_date, end_date)
  end

  def spend
    snapshot["invoiced_with_running_spend_total"].to_f
  end

  def estimated_cost(accounting_method)
    return 0 if snapshot.empty? # If new project trackers are made, we'll not have a snapshot yet
    latest = snapshot[accounting_method]["cosr"].try(:last)
    latest ? (latest["y"] || 0) : 0
  end

  def profit
    spend - estimated_cost("cash")
  end

  def profit_margin
    (profit / spend) * 100
  end

  def dates_with_recorded_assignments_in_range(start_range, end_range)
    assignments = forecast_assignments
        .where('forecast_assignments.end_date >= ? AND forecast_assignments.start_date <= ?', start_range, end_range)
    assignments.reduce({}) do |acc, fa|
      (fa.start_date..fa.end_date).each do |date|
        if date >= start_range && date <= end_range
          acc[date] = acc[date] ||= 0
          acc[date] += 1
        end
      end
      acc
    end.keys.count
  end

  def total_hours_during_range_by_studio(preloaded_studios = Studio.all, start_range, end_range)
    assignments =
      ForecastAssignment
        .includes(:forecast_person)
        .where(project_id: forecast_projects.map(&:forecast_id))
        .where('end_date >= ? AND start_date <= ?', start_range, end_range)

    assignments.reduce({}) do |acc, assignment|
      next acc unless assignment.forecast_person.present?
      studio = assignment.forecast_person.studio(preloaded_studios)
      next acc unless studio.present?

      acc[studio] ||= 0
      acc[studio] += assignment.allocation_during_range_in_hours(start_range, end_range)
      acc
    end
  end

  def total_hours_during_range(start_range, end_range)
    forecast_projects.reduce(0) do |acc, fp|
      acc += fp.total_hours_during_range(start_range, end_range)
    end
  end

  def total_value_during_range(start_range, end_range)
    forecast_projects.reduce(0) do |acc, fp|
      acc += fp.total_value_during_range(start_range, end_range)
    end
  end

  def work_status
    if work_completed_at.nil?
      :in_progress
    else
      if (
        project_capsule.present? &&
        project_capsule.complete?
      )
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

    total = spend
    if total < budget_low_end
      :under_budget
    elsif (total >= budget_low_end && total < budget_high_end)
      :at_budget
    else
      :over_budget
    end
  end

  def cost_of_services_rendered
    calculator = Stacks::CostOfServicesRenderedCalculator.new(
      start_date: start_date,
      end_date: end_date,
      forecast_project_ids: forecast_projects.map(&:forecast_id)
    )

    calculator.calculate
  end

  def raw_resourcing_cost_during_range_in_usd(start_range, end_range)
    assignments =
      ForecastAssignment
        .includes(:forecast_project)
        .where(project_id: forecast_projects.map(&:forecast_id))
    assignments.reduce(0) do |acc, a|
      acc += a.raw_resourcing_cost_during_range_in_usd(
        start_range,
        end_range
      )
    end || 0
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
    @_first_recorded_assignment ||= (
      forecast_project_ids = forecast_projects.map(&:forecast_id)
      ForecastAssignment
        .where(project_id: forecast_project_ids)
        .order(start_date: :asc)
        .limit(1)
        .first
    )
  end

  def last_recorded_assignment
    @_last_recorded_assignment ||= (
      forecast_project_ids = forecast_projects.map(&:forecast_id)
      ForecastAssignment
        .where(project_id: forecast_project_ids)
        .order(end_date: :desc)
        .limit(1)
        .first
    )
  end

  def income
    snapshot["invoiced_income_total"].to_f
  end

  def average_time_to_merge_pr_in_days_during_range(start_range, end_range)
    gh_repo_ids = zenhub_workspaces.map(&:github_repos).flatten.map(&:id)
    prs = GithubPullRequest
      .where(merged_at: start_range..end_range)
      .where(github_repo: gh_repo_ids)
      .merged

    ttm = prs.average(:time_to_merge)
    ttm.present? ? (ttm / 86400.to_f) : nil
  end
end
