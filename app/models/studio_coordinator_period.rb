class StudioCoordinatorPeriod < ApplicationRecord
  include ActsAsPeriod

  belongs_to :studio
  belongs_to :admin_user

  validates_presence_of :started_at
  validate :ended_at_before_started_at?

  def sibling_periods
    admin_user.studio_coordinator_periods
  end
end
