class ProjectSafetyRepresentativePeriod < ApplicationRecord
  include ActsAsPeriod
  belongs_to :project_tracker
  belongs_to :admin_user
  belongs_to :studio

  def period_started_at
    started_at || (project_tracker.first_recorded_assignment && project_tracker.first_recorded_assignment.start_date) || Date.today
  end

  def sibling_periods
    project_tracker.project_safety_representative_periods
  end

  def overlaps?(other)
    return false if studio != other.studio
    super
  end
end
