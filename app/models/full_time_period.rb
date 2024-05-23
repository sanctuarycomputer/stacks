class FullTimePeriod < ApplicationRecord
  include ActsAsPeriod

  belongs_to :admin_user
  validates_presence_of :started_at
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

  def include?(date)
    started_at <= date && date <= ended_at_or_now
  end

  def ended_at_or_now
    ended_at_or(Date.today)
  end

  def ended_at_or(date = Date.today)
    ended_at || date
  end

  def sibling_periods
    admin_user.full_time_periods
  end

  private

  def sync_salary_windows!
    syncer = Stacks::AdminUserSalaryWindowSyncer.new(admin_user)
    syncer.sync!
  end
end
