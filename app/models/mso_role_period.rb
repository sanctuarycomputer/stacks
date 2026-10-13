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
  # Only when the start date is being set: a period already on file with an
  # earlier start can still be ended.
  validate :not_before_mso_compensation_began, if: -> { new_record? || started_at_changed? }
  validate :months_with_trueups_are_not_changed, on: :update
  before_destroy :refuse_destroy_once_paid_from

  # CALLERS: one period per contributor per month is enforced by a model
  # validation only (no database constraint), so two can exist after a
  # validate: false save or two simultaneous creates. Anything that pays
  # from this must check it has one row per contributor_id and refuse to
  # run otherwise.
  #
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

  # The first day of every month that has an ACCEPTED MSO true-up computed
  # from this role period. A true-up records the period's id in its
  # blueprint. Until someone accepts, a month is recomputed on every sync, so
  # a mistyped tier is corrected by editing the period and syncing again.
  def months_with_trueups
    return [] if new_record? || !MsoTrueup.schema_ready?

    MsoTrueup.where.not(accepted_at: nil).joins(:periodic_report)
      .where("mso_trueups.blueprint @> ?", { mso_role_period_id: id }.to_json)
      .distinct.pluck("periodic_reports.period_starts_at").sort
  end

  # Once someone has accepted a true-up from this period, what the period
  # says about that month stays: they agreed to a figure built on it, and
  # removing the month would let the nightly founder true-up come back for a
  # month paid through the MSO. Ending the period going forward
  # stays possible; a promotion is "end this period and start a new one".
  def months_with_trueups_are_not_changed
    months = months_with_trueups
    return if months.empty?

    span = "#{months.first.strftime('%B %Y')} to #{months.last.strftime('%B %Y')}"
    advice = "Accepted MSO true-ups exist for this role period (#{span}). To change someone's tier, " \
             "end this period and start a new one."
    errors.add(:tier, advice) if tier_changed?
    errors.add(:contributor, advice) if contributor_id_changed?
    if started_at_changed? && started_at && started_at > months.first
      errors.add(:started_at, "cannot move past #{months.first.strftime('%B %Y')}, which has a true-up. #{advice}")
    end
    if ended_at_changed? && ended_at && ended_at < months.last.end_of_month
      errors.add(:ended_at, "cannot be before the end of #{months.last.strftime('%B %Y')}, which has a " \
                            "true-up. #{advice}")
    end
  end

  def refuse_destroy_once_paid_from
    months = months_with_trueups
    return if months.empty?

    errors.add(:base, "Accepted MSO true-ups exist for this role period " \
                      "(#{months.map { |month| month.strftime('%B %Y') }.join(', ')}), so it cannot be deleted. " \
                      "Give it an end date instead.")
    throw :abort
  end

  # No month before this is ever computed, so an earlier start pays nothing more.
  # What it does do is silent: Stacks stops writing the founder true-up for
  # every month from the start date on, and Mso::Benchmark drops the person
  # from the pool for those months. A mistyped year would do both.
  def not_before_mso_compensation_began
    start = InvoicePass::INTERCOMPANY_START
    return if started_at.nil? || started_at >= start

    errors.add(:started_at, "cannot be before #{start.strftime('%B %Y')}, the first month MSO compensation " \
                            "is run for")
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
