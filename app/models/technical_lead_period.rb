class TechnicalLeadPeriod < ApplicationRecord
  include ActsAsPeriod
  belongs_to :project_tracker
  belongs_to :admin_user
  belongs_to :studio

  def period_started_at
    started_at || project_tracker.first_recorded_assignment&.start_date || Date.today
  end

  def period_ended_at
    ended_at || project_tracker.last_recorded_assignment&.end_date || Date.today
  end

  def effective_days_in_role_during_range(start_range, end_range)
    project_tracker.dates_with_recorded_assignments_in_range(
      [start_range, period_started_at].max,
      [period_ended_at, end_range].min
    )
  end

  def sibling_periods
    project_tracker.technical_lead_periods
  end

  def overlaps?(other)
    return false if studio != other.studio
    super
  end
end
