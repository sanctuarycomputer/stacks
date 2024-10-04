class CollectiveRoleHolderPeriod < ApplicationRecord
  include ActsAsPeriod
  belongs_to :collective_role
  belongs_to :admin_user

  def period_started_at
    started_at || Date.new(2024, 1, 1)
  end

  def period_ended_at
    [ended_at, admin_user.left_at].compact.min
  end

  def sibling_periods
    collective_role.collective_role_holder_periods
  end
end