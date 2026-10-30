# A window during which a contributor is included in profit share on top of
# the automatic rule (Sanctuary-billed work, company email). In the months it
# covers, their work at every enterprise counts towards elevated service and
# the email rule is waived. Time Off still never counts, and an MSO role still
# excludes them (see PeriodicReport#tentative_profit_shares_by_contributor).
class ProfitShareManualInclusionPeriod < ApplicationRecord
  include ActsAsPeriod

  # Sentinel for an open-ended period, as MsoRolePeriod::OPEN_ENDED.
  OPEN_ENDED = Date.new(9999, 12, 31)

  belongs_to :contributor

  validates :started_at, presence: true
  validates :note, presence: true
  validate :full_months_only

  # Periods that overlap the calendar month containing `date`.
  scope :active_during, ->(date) {
    where("profit_share_manual_inclusion_periods.started_at <= ?", date.end_of_month)
      .where("profit_share_manual_inclusion_periods.ended_at IS NULL OR " \
             "profit_share_manual_inclusion_periods.ended_at >= ?", date.beginning_of_month)
  }

  def period_ended_at
    ended_at || OPEN_ENDED
  end

  def sibling_periods
    return ProfitShareManualInclusionPeriod.none if contributor.nil? || started_at.nil?
    ProfitShareManualInclusionPeriod.where(contributor_id: contributor.id)
  end

  def covers?(date)
    started_at <= date.end_of_month && (ended_at.nil? || ended_at >= date.beginning_of_month)
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
