class ProjectedAssignment < ApplicationRecord
  KINDS = %w[work time_off reduced].freeze
  MAX_RANGE_DAYS = 366

  belongs_to :project_tracker, optional: true
  delegate :runn_project_id, to: :project_tracker, allow_nil: true

  validates :source_key, presence: true, uniqueness: true
  validates :runn_person_id, presence: true
  validates :start_date, presence: true
  validates :end_date, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :minutes_per_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1440 }
  validates :note, length: { maximum: 2000 }, allow_nil: true
  validate :end_on_or_after_start
  validate :range_within_max

  scope :for_tracker, ->(tracker_id) { where(project_tracker_id: tracker_id) }
  scope :for_person, ->(person_id) { where(runn_person_id: person_id) }
  scope :time_off, -> { where(kind: "time_off") }
  scope :owned, -> { where("jsonb_array_length(runn_assignment_ids) > 0") }

  def owned_runn_assignment_ids
    Array(runn_assignment_ids)
  end

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
