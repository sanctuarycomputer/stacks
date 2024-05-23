module ActsAsPeriod
  extend ActiveSupport::Concern

  included do
    validate :does_not_overlap
    validate :ended_at_before_started_at?
  end

  # Must implement me
  def sibling_periods
    raise "Please implement sibling_periods in the model including ActsAsPeriod to check for overlaps"
  end

  # Optionally override me
  def period_started_at
    started_at
  end

  # Optionally override me
  def period_ended_at
    ended_at || Date.today
  end

  # Optionally override me
  def current?
    period_ended_at >= Date.today
  end

  # Optionally override me
  def overlaps?(other)
    period_started_at <= (other.period_ended_at || Date.today) &&
    other.period_started_at <= (period_ended_at || Date.today)
  end

  def does_not_overlap
    overlapping_period = sibling_periods.reject{|p| p == self || p.id.nil?}.find{|p| self.overlaps?(p)}
    if overlapping_period.present?
      errors.add(:base, "Overlapping periods")
    end
  end

  def time_held_in_days
    (period_ended_at - period_started_at).to_i
  end

  def ended_at_before_started_at?
    if started_at.present? && ended_at.present?
      unless ended_at > started_at
        errors.add(:started_at, "Must be before ended_at")
      end
    end
  end
end