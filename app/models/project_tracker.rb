class ProjectTracker < ApplicationRecord
  include BustsTaskCache

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

  has_many :forecast_assignments, through: :forecast_projects

  belongs_to :runn_project, class_name: "RunnProject", foreign_key: "runn_project_id", primary_key: "runn_id", optional: true

  has_many :old_deal_project_lead_periods, dependent: :delete_all
  has_many :old_deal_project_leads, through: :old_deal_project_lead_periods, source: :admin_user

  has_many :old_deal_project_safety_representative_periods, dependent: :delete_all
  has_many :old_deal_project_safety_representatives, through: :old_deal_project_safety_representative_periods, source: :admin_user

  has_many :old_deal_creative_lead_periods, dependent: :delete_all
  has_many :old_deal_creative_leads, through: :old_deal_creative_lead_periods, source: :admin_user

  has_many :old_deal_technical_lead_periods, dependent: :delete_all
  has_many :old_deal_technical_leads, through: :old_deal_technical_lead_periods, source: :admin_user

  has_many :account_lead_periods, dependent: :delete_all
  accepts_nested_attributes_for :account_lead_periods, allow_destroy: true
  has_many :account_leads, through: :account_lead_periods, source: :admin_user

  has_many :project_lead_periods, dependent: :delete_all
  accepts_nested_attributes_for :project_lead_periods, allow_destroy: true
  has_many :project_leads, through: :project_lead_periods, source: :admin_user

  scope :complete, -> {
    where.not(work_completed_at: nil)
      .includes(:project_capsule).where(
        project_capsules: { id: ProjectCapsule.complete }
      )
  }

  scope :in_progress, -> {
    where.not(id: complete)
      .where.not(id: dormant)
  }

  # Uses assignment bounds written by `generate_snapshot!` into jsonb `snapshot` (not live joins).
  scope :dormant, -> {
    threshold = Date.today - 1.month
    where.not(id: complete)
      .where("(snapshot->>'last_forecast_assignment_end_date') IS NOT NULL")
      .where("(snapshot->>'last_forecast_assignment_end_date')::date < ?", threshold)
  }

  def capsule_complete?
    project_capsule.present? && project_capsule.complete?
  end

  def self.capsule_pending
    ProjectTracker.where.not(work_completed_at: nil).select do |pt|
      pt.work_status == :capsule_pending
    end
  end

  def self.likely_complete
    ProjectTracker.dormant.reject(&:considered_ongoing?)
  end

  # Preloads every association a rendered ProjectTracker row needs (runn_project,
  # forecast_projects, capsule + satisfaction survey, lead periods + admin users) and
  # batch-caches assignment edge bounds. Idempotent — associations already loaded are
  # skipped. Use this on any page that iterates a list of trackers and renders columns
  # depending on considered_successful?, work_status, current_*_leads, etc.
  def self.preload_for_render(trackers)
    list = Array(trackers).compact
    return list if list.empty?

    ActiveRecord::Associations::Preloader.new.preload(list, [
      :runn_project,
      :forecast_projects,
      { project_capsule: :project_satisfaction_survey },
      { account_lead_periods: :admin_user },
      { project_lead_periods: :admin_user }
    ])
    batch_cache_edge_recorded_assignments!(list)
    list
  end

  # Sets @_first_recorded_assignment and @_last_recorded_assignment from one
  # ForecastAssignment query per batch (min/max start_date and end_date across each
  # tracker’s linked forecast projects). Call after forecast_projects are preloaded.
  def self.batch_cache_edge_recorded_assignments!(project_trackers)
    list = Array(project_trackers).compact
    return if list.empty?

    all_fp_ids = list.flat_map { |t| t.forecast_projects.map(&:forecast_id) }.compact.uniq
    return if all_fp_ids.empty?

    assignments = ForecastAssignment.where(project_id: all_fp_ids).to_a
    list.each do |pt|
      fpids = pt.forecast_projects.map { |fp| fp.forecast_id.to_i }.to_set
      rel = assignments.select { |a| fpids.include?(a.project_id.to_i) }
      if rel.empty?
        pt.instance_variable_set(:@_first_recorded_assignment, nil)
        pt.instance_variable_set(:@_last_recorded_assignment, nil)
      else
        pt.instance_variable_set(:@_first_recorded_assignment, rel.min_by(&:start_date))
        pt.instance_variable_set(:@_last_recorded_assignment, rel.max_by(&:end_date))
      end
    end
  end

  def likely_complete?
    return false if considered_ongoing?
    return false if capsule_complete_by_statuses?
    last_end = date_from_snapshot_key("last_forecast_assignment_end_date")
    return false unless last_end
    last_end < (Date.today - 1.month)
  end

  private def capsule_complete_by_statuses?
    pc = project_capsule
    pc.present? &&
      pc.client_feedback_survey_status.present? &&
      pc.internal_marketing_status.present? &&
      pc.capsule_status.present? &&
      pc.project_satisfaction_survey_status.present?
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

    last_end = last_recorded_assignment_end_date
    return false unless last_end

    last_end < (Date.today - 1.month)
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
    project_capsule&.client_satisfaction_status == "satisfied"
  end

  def target_profit_margin_satisfied?
    return true if target_profit_margin <= 0
    # Compare using whole percentage points (round up) so float noise / display rounding
    # (e.g. 29.9% shown vs 30% goal) does not mark a project unsuccessful.
    profit_margin.ceil >= target_profit_margin.to_f
  end

  def target_free_hours_ratio_satisfied?
    (free_hours_ratio * 100) <= target_free_hours_percent
  end

  def has_recorded_hours_after_today?
    (last_recorded_assignment_end_date || Date.today) > Date.today
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

    # Trailing N days ending today (inclusive on both ends), e.g. period=7.days → 7 days.
    snapshot = (
      (Date.today - period + 1.day)..
      Date.today
    ).reduce({
      hours: [],
      spend: [],
      hours_total: 0,
      spend_total: 0,
    }) do |acc, date|
      acc[:hours].push({
        x: date.iso8601,
        y: acc[:hours_total] += self.total_hours_during_range(date, date)
      })

      acc[:spend].push({
        x: date.iso8601,
        y: acc[:spend_total] +=
          self.total_value_during_range(date, date)
      })
      acc
    end
  end

  def generate_snapshot!
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

    assignment_range_start, assignment_range_end = assignment_bounds_from_forecast_table

    snapshot = (
      assignment_range_start..
      [assignment_range_end, today].min
    ).reduce({
      generated_at: DateTime.now.iso8601,
      hours: [],
      spend: [],
      cost: [],
      hours_total: 0,
      hours_free: aggregate_hours[:free],
      spend_total: 0,
      cost_total: 0,
      invoiced_income_total: invoiced_income_total,
      invoiced_with_running_spend_total: invoiced_with_running_spend_total,
    }) do |acc, date|
      acc[:spend].push({
        x: date.iso8601,
        y: acc[:spend_total] +=
          self.total_value_during_range(date, date)
      })

      acc[:hours].push({
        x: date.iso8601,
        y: acc[:hours_total] += self.total_hours_during_range(date, date)
      })

      acc
    end

    snapshot = monthly_cosr.reduce(snapshot) do |acc, (date, cosr)|
      acc[:cost].push({
        x: date.iso8601,
        y: acc[:cost_total] += cosr.values.sum{|c| c[:amount]}.round(2)
      })
      acc
    end

    snapshot["first_forecast_assignment_start_date"] = assignment_range_start.iso8601
    snapshot["last_forecast_assignment_end_date"] = assignment_range_end.iso8601

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

  def all_contributors
    forecast_assignments
      .includes(forecast_person: :admin_user)
      .map(&:forecast_person)
      .compact
      .map(&:admin_user)
      .compact
      .uniq
  end

  def all_contributors_with_roles
    # Get all admin users who were assigned to this project
    project_members = {}

    # Add all contributors
    all_contributors.reduce(project_members) do |acc, admin_user|
      acc[admin_user] = acc[admin_user] || {
        roles: []
      }
      acc[admin_user][:roles] << { name: :contributor }
      acc
    end

    account_lead_periods.reduce(project_members) do |acc, period|
      acc[period.admin_user] = acc[period.admin_user] || {
        roles: []
      }
      acc[period.admin_user][:roles] << { name: :account_lead, started_at: period.started_at, ended_at: period.ended_at }
      acc
    end

    project_lead_periods.reduce(project_members) do |acc, period|
      acc[period.admin_user] = acc[period.admin_user] || {
        roles: []
      }
      acc[period.admin_user][:roles] << { name: :project_lead, started_at: period.started_at, ended_at: period.ended_at }
      acc
    end

    # Add project leads (Old Deal)
    old_deal_project_lead_periods.reduce(project_members) do |acc, period|
      acc[period.admin_user] = acc[period.admin_user] || {
        roles: []
      }
      acc[period.admin_user][:roles] << { name: :old_deal_project_lead, started_at: period.started_at, ended_at: period.ended_at }
      acc
    end

    # Add creative leads (Old Deal)
    old_deal_creative_lead_periods.reduce(project_members) do |acc, period|
      acc[period.admin_user] = acc[period.admin_user] || {
        roles: []
      }
      acc[period.admin_user][:roles] << { name: :old_deal_creative_lead, started_at: period.started_at, ended_at: period.ended_at }
      acc
    end

    # Add technical leads (Old Deal)
    old_deal_technical_lead_periods.reduce(project_members) do |acc, period|
      acc[period.admin_user] = acc[period.admin_user] || {
        roles: []
      }
      acc[period.admin_user][:roles] << { name: :old_deal_technical_lead, started_at: period.started_at, ended_at: period.ended_at }
      acc
    end

    # Add project safety representatives (Old Deal)
    old_deal_project_safety_representative_periods.reduce(project_members) do |acc, period|
      acc[period.admin_user] = acc[period.admin_user] || {
        roles: []
      }
      acc[period.admin_user][:roles] << { name: :old_deal_project_safety_representative, started_at: period.started_at, ended_at: period.ended_at }
      acc
    end

    project_members
  end

  def current_old_deal_project_safety_representatives
    current_old_deal_project_safety_representative_periods.map(&:admin_user)
  end

  def current_old_deal_project_safety_representative_periods
    old_deal_project_safety_representative_periods.select do |p|
      p.period_started_at <= Date.today && p.ended_at.nil?
    end
  end

  def current_account_leads
    current_account_lead_periods.map(&:admin_user)
  end

  def current_account_lead_periods
    account_lead_periods.select do |p|
      p.period_started_at <= Date.today && (p.ended_at.nil? || p.ended_at >= Date.today)
    end
  end

  def project_lead_for_month(date)
    project_lead_periods.find do |p|
      p.period_started_at.beginning_of_month <= date && p.period_ended_at.end_of_month >= date
    end.try(:admin_user)
  end

  def account_lead_for_month(date)
    account_lead_periods.find do |p|
      p.period_started_at.beginning_of_month <= date && p.period_ended_at.end_of_month >= date
    end.try(:admin_user)
  end

  def current_project_leads
    current_project_lead_periods.map(&:admin_user)
  end

  def current_project_lead_periods
    project_lead_periods.select do |p|
      p.period_started_at <= Date.today && (p.ended_at.nil? || p.ended_at >= Date.today)
    end
  end

  def current_old_deal_project_leads
    current_old_deal_project_lead_periods.map(&:admin_user)
  end

  def current_old_deal_project_lead_periods
    old_deal_project_lead_periods.select do |p|
      p.period_started_at <= Date.today && p.ended_at.nil?
    end
  end

  def current_old_deal_creative_leads
    current_old_deal_creative_lead_periods.map(&:admin_user)
  end

  def current_old_deal_creative_lead_periods
    old_deal_creative_lead_periods.select do |p|
      p.period_started_at <= Date.today && p.ended_at.nil?
    end
  end

  def current_old_deal_technical_leads
    current_old_deal_technical_lead_periods.map(&:admin_user)
  end

  def current_old_deal_technical_lead_periods
    old_deal_technical_lead_periods.select do |p|
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

  def trailing_7_days_value
    total_value_during_range(
      Date.today - 6.days,
      Date.today
    )
  end

  def trailing_30_days_value
    total_value_during_range(
      Date.today - 29.days,
      Date.today
    )
  end

  # Prefers bounds persisted on snapshot by generate_snapshot!; falls back to querying Forecast.
  def first_recorded_assignment_start_date
    date_from_snapshot_key("first_forecast_assignment_start_date") ||
      first_recorded_assignment&.start_date
  end

  def last_recorded_assignment_end_date
    date_from_snapshot_key("last_forecast_assignment_end_date") ||
      last_recorded_assignment&.end_date
  end

  def start_date
    first_recorded_assignment_start_date || Date.today
  end

  def end_date
    last_recorded_assignment_end_date || Date.today
  end

  def lifetime_value
    total_value_during_range(start_date, end_date)
  end

  def spend
    snapshot["invoiced_with_running_spend_total"].to_f
  end

  def profit
    spend - estimated_cost
  end

  def monthly_cosr
    fpids = forecast_project_ids

    # First, collect all the contributor payouts
    monthly_cosr = ContributorPayout.includes(invoice_tracker: :invoice_pass).where(invoice_tracker_id: invoice_trackers.pluck(:id)).reduce({}) do |acc, cp|
      acc[cp.accrual_date] ||= {}

      # Contributor payouts are on the client level, so lets filter out
      # any parts of the payout that are not due to work done against this
      # specific project tracker
      amount_for_this_tracker = cp.amount
      bp = cp.blueprint || {}
      legacy_team_lead_keys = bp.keys.sort == ["AccountLead", "IndividualContributor", "TeamLead"].sort
      project_lead_keys = bp.keys.sort == ["AccountLead", "IndividualContributor", "ProjectLead"].sort
      if bp.is_a?(Hash) && (legacy_team_lead_keys || project_lead_keys)
        amount_for_this_tracker = 0
        amount_for_this_tracker = bp.values.flatten.reduce(0) do |acc, v|
          if fpids.include?(v.try(:dig, "blueprint_metadata", "forecast_project"))
            acc += v.try(:dig, "amount").to_f
          end
          acc
        end
      end

      next acc unless amount_for_this_tracker > 0
      acc[cp.accrual_date][cp.contributor.forecast_person] = {
        amount: amount_for_this_tracker.round(2),
        type: :contributor_payout,
      }
      acc
    end

    # Next, check if any forecast assignments were recorded for the old deal
    assignments =
      ForecastAssignment
        .includes(forecast_person: [admin_user: :full_time_periods])
        .where(project_id: forecast_projects.map(&:forecast_id))

    cosr_range_start, cosr_range_end = assignment_bounds_from_forecast_table

    (cosr_range_start..cosr_range_end).reduce(monthly_cosr) do |acc, date|
      assignments.where('end_date >= ? AND start_date <= ?', date, date).each do |fa|
        admin_user = fa.forecast_person.try(:admin_user)
        next acc unless admin_user.present?

        ftp = admin_user.full_time_period_at(date)
        next acc unless ftp.present? && (ftp.four_day? || ftp.five_day?)

        acc[date.end_of_month] ||= {}
        allocation_hrs = fa.allocation_during_range_in_hours(date, date)
        daily_cost = admin_user.cost_of_employment_on_date(date)
        assignment_cosr = allocation_hrs >= 8 ? daily_cost : (daily_cost * (allocation_hrs.to_f / 8))
        acc[date.end_of_month][fa.forecast_person] ||= {
          amount: 0,
          type: :salary,
        }
        acc[date.end_of_month][fa.forecast_person][:amount] += assignment_cosr
      end
      acc
    end.sort_by{|date, cosr| date}.to_h
  end

  def estimated_cost
    snapshot["cost_total"].try(:to_f) || 0
  end

  def profit_margin
    return 100 if spend == 0
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
    return @_work_status if defined?(@_work_status)
    @_work_status =
      if work_completed_at.nil?
        if likely_complete?
          :likely_complete
        else
          :in_progress
        end
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
    elsif (total >= budget_low_end && total <= budget_high_end)
      :at_budget
    else
      :over_budget
    end
  end

  def first_recorded_assignment
    return @_first_recorded_assignment if instance_variable_defined?(:@_first_recorded_assignment)

    forecast_project_ids = forecast_projects.map(&:forecast_id)
    @_first_recorded_assignment = ForecastAssignment
      .where(project_id: forecast_project_ids)
      .order(start_date: :asc)
      .limit(1)
      .first
  end

  def last_recorded_assignment
    return @_last_recorded_assignment if instance_variable_defined?(:@_last_recorded_assignment)

    forecast_project_ids = forecast_projects.map(&:forecast_id)
    @_last_recorded_assignment = ForecastAssignment
      .where(project_id: forecast_project_ids)
      .order(end_date: :desc)
      .limit(1)
      .first
  end

  private def date_from_snapshot_key(key)
    raw = snapshot[key]
    return nil if raw.blank?

    Date.iso8601(raw.to_s)
  rescue ArgumentError
    nil
  end

  # Bounds read live from Forecast (used by generate_snapshot! and monthly_cosr so we never
  # use stale snapshot JSON while regenerating).
  private def assignment_bounds_from_forecast_table
    [
      first_recorded_assignment&.start_date || Date.today,
      last_recorded_assignment&.end_date || Date.today
    ]
  end

  def income
    snapshot["invoiced_income_total"].to_f
  end
end
