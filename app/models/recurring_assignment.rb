class RecurringAssignment < ApplicationRecord
  belongs_to :forecast_person, class_name: "ForecastPerson",
    foreign_key: "forecast_person_id", primary_key: "forecast_id", optional: true
  belongs_to :forecast_project, class_name: "ForecastProject",
    foreign_key: "forecast_project_id", primary_key: "forecast_id", optional: true

  # Destroying a rule stops future materialization and drops its occurrence tracking
  # rows, but deliberately leaves the already-created Forecast assignments intact —
  # under retrospect-only materialization every one is a record of allocation that
  # already happened, so it's historical, not ours to erase.
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

  # Normalize incoming weekdays to a clean integer array. HTML checkbox forms submit
  # strings plus a hidden "" (Formtastic's unchecked placeholder); the "" casts to nil
  # in the integer[] column, which then fails the 0..6 range validation. Strip blanks
  # and coerce to Integer so form/MCP/API callers all land on the same shape.
  def weekdays=(value)
    super(Array(value).map { |v| v.to_s.strip }.reject(&:empty?).map(&:to_i))
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

  # Occurrences are only ever created on/before today — never in advance. A rule with
  # a blank ends_on "never ends"; it simply materializes each day's occurrence once
  # that day arrives. Bounding creation to today (rather than a future horizon) also
  # guarantees every occurrence falls inside the Forecast sync window, which is what
  # keeps deletion-detection safe (see detect_deletions!).
  def expected_occurrence_dates
    last = [ends_on, Date.today].compact.min
    return [] if starts_on.nil? || starts_on > last
    (starts_on..last).select { |d| weekdays.include?(d.wday) }
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
    # Tombstone occurrences whose Forecast assignment vanished from the freshly-synced
    # mirror (i.e. deleted in the Forecast UI). Two independent guards keep this safe:
    #   1. materialize! creates occurrences only on/before today (never in advance), and
    #   2. we only judge occurrences the sync actually covers — sync_all_assignments!
    #      walks month-by-month up to the CURRENT month, so we bound detection to
    #      end-of-current-month.
    # Together these guarantee an in-window occurrence absent from the mirror was
    # deleted, not merely "not yet synced." Detection runs BEFORE creation so this
    # run's fresh rows (created after this pass) are never judged before their next
    # sync. A false tombstone is permanent — Pass 2 never recreates a date that
    # already has a row — so the bound is deliberately conservative defense-in-depth.
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
