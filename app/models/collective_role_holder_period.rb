class CollectiveRoleHolderPeriod < ApplicationRecord
  include ActsAsPeriod
  belongs_to :collective_role
  belongs_to :admin_user

  def period_started_at
    started_at || Date.new(2024, 1, 1)
  end

  def sibling_periods
    collective_role.collective_role_holder_periods
  end
end