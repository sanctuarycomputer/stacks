class RecurringAssignment < ApplicationRecord
  HORIZON = 26.weeks

  belongs_to :forecast_person, class_name: "ForecastPerson",
    foreign_key: "forecast_person_id", primary_key: "forecast_id", optional: true
  belongs_to :forecast_project, class_name: "ForecastProject",
    foreign_key: "forecast_project_id", primary_key: "forecast_id", optional: true
  has_many :recurring_assignment_occurrences, dependent: :destroy

  validates :forecast_person_id, presence: true
  validates :forecast_project_id, presence: true
  validates :allocation, presence: true, numericality: { greater_than: 0, only_integer: true }
  validates :starts_on, presence: true
  validate :weekdays_valid
  validate :ends_on_not_before_starts_on

  scope :active, -> { where(paused_at: nil) }

  def paused?
    paused_at.present?
  end

  def allocation_in_hours
    allocation && allocation / 3600.0
  end

  def allocation_in_hours=(hours)
    self.allocation = (hours.to_f * 3600).round
  end

  private

  def weekdays_valid
    if weekdays.blank?
      errors.add(:weekdays, "must include at least one day")
    elsif weekdays.any? { |d| !(0..6).cover?(d) }
      errors.add(:weekdays, "must be integers 0 (Sun) through 6 (Sat)")
    end
  end

  def ends_on_not_before_starts_on
    return if ends_on.blank? || starts_on.blank?
    errors.add(:ends_on, "cannot be before starts_on") if ends_on < starts_on
  end
end
