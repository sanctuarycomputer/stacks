# A window during which a contributor holds an MSO executive role at a tier.
# Their monthly MSO compensation is the Top-N Sanctuary benchmark multiplied
# by the tier's multiplier (see Mso::Benchmark and Mso::Compensation).
class MsoRolePeriod < ApplicationRecord
  include ActsAsPeriod

  MULTIPLIERS = {
    "head" => BigDecimal("0.70"),
    "svp" => BigDecimal("0.85"),
    "chief" => BigDecimal("1.00"),
    "principal" => BigDecimal("1.15"),
  }.freeze

  # Sentinel for an open-ended period. ActsAsPeriod's default is Date.today,
  # under which two open-ended periods never overlap if the second starts in
  # the future.
  OPEN_ENDED = Date.new(9999, 12, 31)

  belongs_to :contributor

  enum tier: { head: 0, svp: 1, chief: 2, principal: 3 }, _prefix: :tier

  validates :tier, presence: true
  validates :started_at, presence: true
  validates :title, presence: true
  validate :full_months_only

  # Periods that overlap the calendar month containing `date`. Written in SQL
  # rather than on top of period_ended_at, which is a Ruby-side sentinel.
  scope :active_during, ->(date) {
    where("mso_role_periods.started_at <= ?", date.end_of_month)
      .where("mso_role_periods.ended_at IS NULL OR mso_role_periods.ended_at >= ?", date.beginning_of_month)
  }

  def tier_multiplier
    MULTIPLIERS.fetch(tier.to_s)
  end

  def period_ended_at
    ended_at || OPEN_ENDED
  end

  # ActsAsPeriod's version would measure an open period against the
  # year-9999 sentinel.
  def time_held_in_days
    ((ended_at || Date.today) - started_at).to_i
  end

  # ActsAsPeriod compares against these in its overlap validation. With no
  # contributor or no start date there is nothing meaningful to compare, and
  # the presence validations already fail the record.
  def sibling_periods
    return MsoRolePeriod.none if contributor.nil? || started_at.nil?
    # Fresh query: loading the association here would cache a stale list on
    # the shared Contributor instance.
    MsoRolePeriod.where(contributor_id: contributor.id)
  end

  def full_months_only
    if started_at && started_at.day != started_at.beginning_of_month.day
      errors.add(:started_at, "must be the first day of the month")
    end
    if ended_at && ended_at.day != ended_at.end_of_month.day
      errors.add(:ended_at, "must be the last day of the month")
    end
  end
end
