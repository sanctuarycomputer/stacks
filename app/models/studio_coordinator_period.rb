class StudioCoordinatorPeriod < ApplicationRecord
  belongs_to :studio
  belongs_to :admin_user

  validates_presence_of :started_at
  validate :ended_at_before_started_at?

  def ended_at_before_started_at?
    if ended_at.present?
      unless ended_at > started_at
        errors.add(:started_at, "Must be before ended_at")
      end
    end
  end
end
