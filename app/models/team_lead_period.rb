class TeamLeadPeriod < ApplicationRecord
  include ActsAsPeriod

  belongs_to :project_tracker
  belongs_to :admin_user

  validate :full_months_only

  def full_months_only
    if started_at && started_at.day != started_at.beginning_of_month.day
      errors.add(:started_at, "must be the first day of the month")
    end
    if ended_at && ended_at.day != ended_at.end_of_month.day
      errors.add(:ended_at, "must be the last day of the month")
    end
  end

  def period_started_at
    started_at || project_tracker.first_recorded_assignment&.start_date || Date.today
  end

  def period_ended_at
    ended_at || project_tracker.last_recorded_assignment&.end_date || Date.today
  end

  def current?
    period_ended_at >= Date.today - 14.days
  end

  def sibling_periods
    project_tracker.team_lead_periods
  end
end