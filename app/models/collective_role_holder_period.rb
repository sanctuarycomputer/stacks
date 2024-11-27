class CollectiveRoleHolderPeriod < ApplicationRecord
  include ActsAsPeriod
  belongs_to :collective_role
  belongs_to :admin_user

  def period_started_at
    started_at || admin_user.start_date || Date.new(2024, 1, 1)
  end

  def period_ended_at
    [ended_at, admin_user.left_at].compact.min || Date.today
  end

  def effective_days_in_role_during_range(start_range, end_range)
    [period_ended_at, end_range].min - [start_range, period_started_at].max
  end

  def sibling_periods
    collective_role.collective_role_holder_periods
  end
end