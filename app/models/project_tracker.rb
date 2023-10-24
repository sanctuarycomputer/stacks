class ProjectTracker < ApplicationRecord
  validates :name, presence: :true
  validate :has_msa_and_sow_links

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

  has_many :adhoc_invoice_trackers, dependent: :delete_all
  accepts_nested_attributes_for :adhoc_invoice_trackers, allow_destroy: true

  has_many :project_tracker_forecast_projects, dependent: :delete_all
  has_many :forecast_projects, through: :project_tracker_forecast_projects
  accepts_nested_attributes_for :project_tracker_forecast_projects, allow_destroy: true

  has_many :atc_periods, dependent: :delete_all
  accepts_nested_attributes_for :atc_periods, allow_destroy: true

  belongs_to :atc, class_name: "AdminUser", optional: true

  scope :complete, -> {
    where.not(work_completed_at: nil)
      .includes(:project_capsule).where(
        project_capsules: { id: ProjectCapsule.complete}
      )
  }

  scope :in_progress , -> {
    where.not(id: complete)
  }

  def forecast_projects
    @_forecast_projects ||= super
  end

  def has_recorded_hours_after_today?
    (last_recorded_assignment.try(:end_date) || Date.today) > Date.today
  end

  def has_msa_and_sow_links
    unless project_tracker_links.find{|l| l.link_type == "msa"}.present?
      errors.add(:base, "An MSA Project URL must be present.")
    end

    unless project_tracker_links.find{|l| l.link_type == "sow"}.present?
      errors.add(:base, "An SOW Project URL must be present.")
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

  def generate_snapshot!
    cosr = cost_of_services_rendered("month")
    preloaded_studios = Studio.all
    today = Date.today

    snapshot = (
      (self.first_recorded_assignment.try(:start_date) || Date.today)..
      [(self.last_recorded_assignment.try(:end_date) || Date.today), today].min
    ).reduce({
      generated_at: DateTime.now.iso8601,
      hours: [],
      spend: [],
      hours_total: 0,
      spend_total: 0,
      cash: {
        cosr: [],
        cosr_total: 0,
      },
      accrual: {
        cosr: [],
        cosr_total: 0,
      }
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

      cosrp = cosr.keys.find{|p| p.starts_at <= date && p.ends_at >= date}
      cosr_for_date = hours_by_studio.reduce({ cash: 0, accrual: 0 }) do |acc, s|
        studio, hours = s
        data = cosr[cosrp][studio]
        acc[:cash] += hours * data[:cash][:actual_cost_per_hour_sold]
        acc[:accrual] += hours * data[:accrual][:actual_cost_per_hour_sold]
        acc
      end
      
      acc[:cash][:cosr].push({
        x: date.iso8601,
        y: acc[:cash][:cosr_total] += cosr_for_date[:cash]
      })

      acc[:accrual][:cosr].push({
        x: date.iso8601,
        y: acc[:accrual][:cosr_total] += cosr_for_date[:accrual]
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
    forecast_projects.reduce(0) do |acc, fp|
      acc += fp.total_hours
    end
  end

  def total_free_hours
    forecast_projects.reduce(0) do |acc, fp|
      acc += fp.total_hours if fp.hourly_rate == 0
      acc
    end
  end

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
    budget_low_end.present? && budget_high_end.present?
  end

  def invoice_trackers
    its = InvoiceTracker
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

  def spend
    latest = snapshot["spend"].try(:last)
    latest ? latest["y"] : 0
  end

  def estimated_cost(accounting_method)
    return 0 if snapshot.empty? # If new project trackers are made, we'll not have a snapshot yet
    latest = snapshot[accounting_method]["cosr"].try(:last)
    latest ? (latest["y"] || 0) : 0
  end

  def profit
    income - estimated_cost("cash")
  end

  def profit_margin
    cost = estimated_cost("cash")
    ((income - cost) / cost) * 100
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

  def cost_of_services_rendered(mode)
    today = Date.today
    preloaded_studios = Studio.all
    g3d = preloaded_studios.find(&:is_garden3d?)
    periods = {}
    time = (
      first_recorded_assignment ?
      first_recorded_assignment.start_date.beginning_of_month :
      Date.new(2020, 1, 1)
    )
    end_time = [(
      last_recorded_assignment ?
      last_recorded_assignment.end_date.beginning_of_month :
      Date.today.beginning_of_month
    ), today].min

    assignments =
      ForecastAssignment
        .includes(:forecast_person)
        .where(project_id: forecast_projects.map(&:forecast_id))

    while time <= end_time
      period = Stacks::Period.new(
        time.strftime("%B, %Y"),
        time.beginning_of_month,
        time.end_of_month
      )

      periods[period] = assignments.reduce({}) do |acc, assignment|
        next acc unless assignment.forecast_person.present?

        studio = assignment.forecast_person.studio(preloaded_studios)
        # Old records (like Joshie) never got assigned a studio in Forecast. That's a long time ago
        # so no need to worry about that :)
        next acc unless studio.present?

        # Find the snapshot for the corresponding month, or (if it's the current month and thus
        # not in the snapshot), fallback to the studio's latest monthly snapshot
        snapshot = 
          studio.snapshot["month"].find{|v| v["label"] == period.label} || studio.snapshot["month"].last

        acc[studio] = acc[studio] || {
          cash: {
            cost_per_sellable_hour: 
              snapshot.try(:dig, "cash", "datapoints", "cost_per_sellable_hour", "value").try(:to_f) || 0,
            actual_cost_per_hour_sold: 
              snapshot.try(:dig, "cash", "datapoints", "actual_cost_per_hour_sold", "value").try(:to_f) || 0
          },
          accrual: {
            cost_per_sellable_hour: 
              snapshot.try(:dig, "accrual", "datapoints", "cost_per_sellable_hour", "value").try(:to_f) || 0,
            actual_cost_per_hour_sold: 
              snapshot.try(:dig, "accrual", "datapoints", "actual_cost_per_hour_sold", "value").try(:to_f) || 0
          },
          forecast_people: {},
        }
      
        acc[studio][:forecast_people][assignment.forecast_person] = 
          acc[studio][:forecast_people][assignment.forecast_person] || { hours: 0 }

        acc[studio][:forecast_people][assignment.forecast_person][:hours] +=
          assignment.allocation_during_range_in_hours(period.starts_at, [period.ends_at, today].min)
        acc
      end

      time = time.advance(months: 1)
    end

    periods.each do |p|
      period, by_studio = p
      
      by_studio.each do |s|
        studio, data = s
        data[:total_studio_hours] = 
          by_studio[studio][:forecast_people].reduce(0) do |acc, pd|
            forecast_person, hours_data = pd
            acc += hours_data[:hours]
            acc
          end
      end
    end

    periods
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
        .order(start_date: :desc)
        .limit(1)
        .first
    )
  end

  def income
    forecast_project_ids = forecast_projects.map(&:forecast_id) || []

    from_generated_invoices =
      invoice_trackers.reduce(0.0) do |acc, it|
        acc += it.qbo_line_items_relating_to_forecast_projects(forecast_projects).map{|qbo_li| qbo_li.dig("amount").to_f}.reduce(&:+) || 0
      end

    from_adhoc_invoices =
      (adhoc_invoice_trackers.reduce(0.0) do |acc, ahit|
        acc += ahit.qbo_invoice.try(:total) || 0
      end || 0)

    from_generated_invoices + from_adhoc_invoices
  end
end
