class RecurringAssignment < ApplicationRecord
  HORIZON = 26.weeks

  belongs_to :forecast_person, class_name: "ForecastPerson",
    foreign_key: "forecast_person_id", primary_key: "forecast_id", optional: true
  belongs_to :forecast_project, class_name: "ForecastProject",
    foreign_key: "forecast_project_id", primary_key: "forecast_id", optional: true
  before_destroy :remove_future_forecast_assignments!

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

  # Idempotent. Pass 1 tombstones occurrences deleted in Forecast (absent from the
  # freshly-synced ForecastAssignment mirror); Pass 2 creates any missing occurrence.
  # MUST run after Stacks::Forecast#sync_all! so the mirror is authoritative — see the
  # daily_tasks wiring. Detection runs BEFORE creation so this-run creations are never
  # mistaken for deletions.
  def materialize!(forecast_client: nil)
    return if paused?
    detect_deletions!
    create_missing_occurrences!(forecast_client || Stacks::Forecast.new)
  end

  def expected_occurrence_dates
    last = [ends_on, Date.today + HORIZON].compact.min
    return [] if starts_on > last
    (starts_on..last).select { |d| weekdays.include?(d.wday) }
  end

  # Deletes only FUTURE materialized occurrences from Forecast on rule teardown;
  # past occurrences are left for historical accuracy, tombstoned ones are already gone.
  def remove_future_forecast_assignments!(forecast_client = Stacks::Forecast.new)
    recurring_assignment_occurrences
      .materialized
      .where.not(forecast_assignment_id: nil)
      .where("occurs_on >= ?", Date.today)
      .find_each { |occ| forecast_client.delete_assignment(occ.forecast_assignment_id) }
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

  def detect_deletions!
    # Only occurrences the Forecast sync actually covers are eligible for
    # deletion-detection. sync_all_assignments! walks month-by-month only up to
    # the CURRENT month, so future-dated assignments are never in the mirror —
    # absence there means "not yet synced," NOT "deleted in the UI." Bounding to
    # end-of-current-month prevents falsely tombstoning every future occurrence on
    # the next daily run. (Pass 2 never recreates a date that already has an
    # occurrence row, so a genuinely deleted future assignment is still never
    # recreated; it just isn't labeled deleted until its month enters the sync window.)
    recurring_assignment_occurrences
      .materialized
      .where.not(forecast_assignment_id: nil)
      .where("occurs_on <= ?", Date.today.end_of_month)
      .find_each do |occ|
        next if ForecastAssignment.exists?(forecast_id: occ.forecast_assignment_id)
        occ.update!(status: "deleted")
      end
  end

  def create_missing_occurrences!(forecast_client)
    existing = recurring_assignment_occurrences.pluck(:occurs_on).to_set
    expected_occurrence_dates.each do |date|
      next if existing.include?(date)
      begin
        assignment = forecast_client.create_assignment(
          project_id: forecast_project_id,
          person_id: forecast_person_id,
          start_date: date,
          end_date: date,
          allocation: allocation,
          notes: notes,
          active_on_days_off: active_on_days_off,
        )
        recurring_assignment_occurrences.create!(
          occurs_on: date,
          status: "materialized",
          forecast_assignment_id: assignment["id"],
        )
      rescue => e
        Sentry.capture_exception(e)
      end
    end
  end
end
