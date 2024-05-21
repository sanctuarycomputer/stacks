class FullTimePeriod < ApplicationRecord
  belongs_to :admin_user
  validates_presence_of :started_at
  validate :does_not_overlap
  validate :ended_at_before_started_at?

  after_create :sync_salary_windows!

  enum contributor_type: {
    five_day: 0,
    four_day: 1,
    variable_hours: 2
  }

  def psu_earn_rate
    if contributor_type == "five_day"
      return 1
    elsif contributor_type == "four_day"
      return 0.8
    end
    0
  end

  def overlaps?(other)
    started_at <= other.ended_at && other.started_at <= ended_at
  end

  def include?(date)
    started_at <= date && date <= ended_at_or_now
  end

  def ended_at_or_now
    ended_at || Date.today
  end

  def ended_at_or(date = Date.today)
    ended_at || date
  end

  def ended_at_before_started_at?
    if ended_at.present? && ended_at <= started_at
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

  private

  def sync_salary_windows!
    syncer = Stacks::AdminUserSalaryWindowSyncer.new(admin_user)
    syncer.sync!
  end
end
