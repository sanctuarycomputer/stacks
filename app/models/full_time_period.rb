class FullTimePeriod < ApplicationRecord
  belongs_to :admin_user
  validates_presence_of :started_at
  validate :all_other_periods_are_closed?
  validate :does_not_overlap
  validate :ended_at_before_started_at?

  def overlaps?(other)
    started_at <= other.ended_at && other.started_at <= ended_at
  end

  def ended_at_or_now
    ended_at || Date.today
  end

  def ended_at_before_started_at?
    unless ended_at_or_now > started_at
      errors.add(:started_at, "must be before ended_at")
    end
  end

  def does_not_overlap
    without_self = admin_user.full_time_periods.reject{|ftp| ftp == self}
    return unless without_self.any?

    overlaps = without_self.all? do |ftp|
      (started_at <= ftp.ended_at_or_now) && (ftp.started_at <= ended_at_or_now)
    end
    if overlaps
      errors.add(:started_at, "overlaps with another full_time_period")
    end
  end

  def all_other_periods_are_closed?
    return if (started_at.present? && ended_at.present?)

    without_self = admin_user.full_time_periods.reject{|ftp| ftp == self}
    return unless without_self.any?

    all_closed = admin_user.full_time_periods.reject{|ftp| ftp == self}.all? do |ftp|
      ftp.ended_at.present?
    end
    if !all_closed
      errors.add(:started_at, "another full_time_period is open")
    end
  end
end
