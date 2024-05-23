class StudioMembership < ApplicationRecord
  include ActsAsPeriod
  belongs_to :studio
  belongs_to :admin_user

  def sibling_periods
    admin_user.studio_memberships
  end
end