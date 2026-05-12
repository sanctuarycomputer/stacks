class Ledger < ApplicationRecord
  belongs_to :enterprise
  belongs_to :contributor

  has_many :contributor_payouts
  has_many :contributor_adjustments
  has_many :trueups
  has_many :reimbursements
  has_many :profit_shares
  has_many :ledger_withdrawals

  validates :enterprise_id, uniqueness: { scope: :contributor_id }

  def self.find_or_create_for(enterprise:, contributor:)
    find_or_create_by!(enterprise: enterprise, contributor: contributor)
  end

  # Balance/unsettled at the per-ledger (per-enterprise) level. Excludes soft-deleted rows
  # via the default acts_as_paranoid scope. Each host's `payable?` decides which bucket the
  # row lands in; `signed_amount` lets withdrawals deduct.
  def balance
    visible_items.select(&:payable?).sum(&:signed_amount)
  end

  def unsettled
    visible_items.reject(&:payable?).sum(&:signed_amount)
  end

  # Per-ledger by-month grouping for display. Includes soft-deleted rows so the contributor
  # admin show page can render strikethrough lines. No elevated_service / total_hours /
  # partial_salary / fulltime — those are cross-enterprise concepts and live on Contributor.
  def items_grouped_by_month(override_starts_at = nil, override_ends_at = nil)
    all_items = all_items_with_deleted

    ledger_ends_at =
      if override_ends_at.present?
        override_ends_at
      else
        (all_items.map(&:effective_on_for_display).compact.max || Date.today) + 2.months
      end

    ledger_starts_at = override_starts_at || Stacks::System.singleton_class::NEW_DEAL_START_AT

    periods = Stacks::Period.for_gradation(:month, ledger_starts_at, ledger_ends_at).reverse
    periods.reduce({ all: [], by_month: {} }) do |acc, period|
      items_in_period = all_items.select do |li|
        d = li.effective_on_for_display
        d.present? && d >= period.starts_at && d <= period.ends_at
      end

      sorted = items_in_period.sort_by { |li| li.effective_on_for_display }.reverse

      total_income = sorted.sum do |li|
        (li.is_a?(ContributorPayout) || li.is_a?(Trueup)) ? li.amount.to_f : 0
      end

      acc[:all] = acc[:all] + sorted
      acc[:by_month][period] = {
        items: sorted,
        total_income: total_income,
      }
      acc
    end
  end

  private

  # Non-deleted only — used by balance/unsettled sums.
  def visible_items
    [
      contributor_payouts.to_a,
      contributor_adjustments.to_a,
      trueups.to_a,
      reimbursements.to_a,
      profit_shares.to_a,
      ledger_withdrawals.to_a,
    ].flatten
  end

  # Includes soft-deleted rows — used by items_grouped_by_month for display.
  def all_items_with_deleted
    [
      ContributorPayout.with_deleted.includes(invoice_tracker: :invoice_pass).where(ledger_id: id).to_a,
      ContributorAdjustment.with_deleted.where(ledger_id: id).to_a,
      Trueup.with_deleted.includes(:invoice_pass).where(ledger_id: id).to_a,
      Reimbursement.with_deleted.where(ledger_id: id).to_a,
      ProfitShare.with_deleted.includes(:periodic_report).where(ledger_id: id).to_a,
      LedgerWithdrawal.with_deleted.where(ledger_id: id).to_a,
    ].flatten
  end
end
