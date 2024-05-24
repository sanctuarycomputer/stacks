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

  def four_day?
    contributor_type == Enum::ContributorType::FOUR_DAY
  end

  def five_day?
    contributor_type == Enum::ContributorType::FIVE_DAY
  end

  def psu_earn_rate
    if five_day?
      1
    elsif four_day?
      0.8
    else
      0
    end
  end

  def include?(date)
    started_at <= date && date <= period_ended_at
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
