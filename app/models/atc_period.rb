class AtcPeriod < ApplicationRecord
  belongs_to :project_tracker
  belongs_to :admin_user
  validate :does_not_overlap
  validate :ended_at_before_started_at?

  def period_started_at
    started_at || (project_tracker.first_recorded_assignment && project_tracker.first_recorded_assignment.start_date) || Date.today
  end

  def period_ended_at
    ended_at
  end

  def does_not_overlap
    overlapping_atc_period =
      project_tracker.atc_periods
        .reject{|atcp| atcp.id.nil?}
        .reject{|atcp| atcp == self}
        .find{|atcp| self.overlaps?(atcp)}
    if overlapping_atc_period.present?
      errors.add(:admin_user, "Must not overlap with another ATC")
    end
  end

  def overlaps?(other)
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
