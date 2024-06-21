class ProjectLeadPeriod < ApplicationRecord
  include ActsAsPeriod

  belongs_to :project_tracker
  belongs_to :admin_user
  belongs_to :studio

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
