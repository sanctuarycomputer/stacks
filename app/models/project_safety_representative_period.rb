class ProjectSafetyRepresentativePeriod < ApplicationRecord
  belongs_to :project_tracker
  belongs_to :admin_user
  belongs_to :studio
  validate :does_not_overlap
  validate :ended_at_before_started_at?

  def period_started_at
    started_at || (project_tracker.first_recorded_assignment && project_tracker.first_recorded_assignment.start_date) || Date.today
  end

  def period_ended_at
    ended_at
  end

  def does_not_overlap
    overlapping_period =
      project_tracker.project_safety_representative_periods
        .reject{|psrp| psrp.id.nil?}
        .reject{|psrp| psrp == self}
        .find{|psrp| self.overlaps?(psrp)}
    if overlapping_period.present?
      errors.add(:admin_user, "Must not overlap with another Project Safety Rep for #{studio.name}")
    end
  end

  def overlaps?(other)
    return false if studio != other.studio

    period_started_at <= (other.period_ended_at || Date.today) &&
    other.period_started_at <= (period_ended_at || Date.today)
  end

  def ended_at_before_started_at?
    if started_at.present? && ended_at.present?
      unless ended_at > started_at
        errors.add(:started_at, "Must be before ended_at")
      end
    end
  end
end
