class ProjectedAssignment < ApplicationRecord
  MAX_RANGE_DAYS = 366

  belongs_to :contributor
  belongs_to :project_tracker
  delegate :runn_project_id, to: :project_tracker

  validates :source_key, presence: true, uniqueness: true
  validates :start_date, :end_date, presence: true
  validates :minutes_per_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1440 }
  validates :note, length: { maximum: 2000 }, allow_nil: true
  validate :end_on_or_after_start
  validate :range_within_max

  scope :owned, -> { where.not(runn_assignment_id: nil) }

  private

  def end_on_or_after_start
    return if start_date.blank? || end_date.blank?

    errors.add(:end_date, "must be on or after start_date") if end_date < start_date
  end

  def range_within_max
    return if start_date.blank? || end_date.blank?

    errors.add(:end_date, "range exceeds #{MAX_RANGE_DAYS} days") if (end_date - start_date).to_i > MAX_RANGE_DAYS
  end
end
