class ProjectLeadPeriod < ApplicationRecord
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

  def current?
    period_ended_at >= Date.today - 14.days
  end

  def sibling_periods
    project_tracker.project_lead_periods
  end

  def overlaps?(other)
    return false if studio != other.studio
    super
  end
end