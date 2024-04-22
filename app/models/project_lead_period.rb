class ProjectLeadPeriod < ApplicationRecord
  belongs_to :project_tracker
  belongs_to :admin_user
  belongs_to :studio
  validate :does_not_overlap
  validate :ended_at_before_started_at?

  def period_started_at
    started_at || project_tracker.first_recorded_assignment&.start_date || Date.today
  end

  def period_ended_at
    ended_at || project_tracker.last_recorded_assignment&.end_date || Date.today
  end

  def time_held_in_days
    (period_ended_at - period_started_at).to_i
  end

  def does_not_overlap
    overlapping_project_lead_period =
      project_tracker.project_lead_periods
        .reject{|p| p.id.nil?}
        .reject{|p| p == self}
        .find{|p| self.overlaps?(p)}
    if overlapping_project_lead_period.present?
      errors.add(:admin_user, "Must not overlap with another Project Lead for this studio")
    end
  end

  def overlaps?(other)
    return false if studio != other.studio

    period_started_at <= (other.ended_at || Date.today) &&
    other.period_started_at <= (ended_at || Date.today)
  end

  def ended_at_before_started_at?
    if started_at.present? && ended_at.present?
      unless ended_at > started_at
        errors.add(:started_at, "Must be before ended_at")
      end
    end
  end
end