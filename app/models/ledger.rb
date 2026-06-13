class Ledger < ApplicationRecord
  belongs_to :enterprise
  belongs_to :contributor

  enum mode: { legacy: 0, qbo_bound: 1 }

  PAYMENT_METHODS = %w[deel qbo].freeze

  def deel_enabled?
    payment_methods.include?("deel")
  end

  def qbo_enabled?
    payment_methods.include?("qbo")
  end

  has_many :contributor_payouts
  has_many :contributor_adjustments
  has_many :trueups
  has_many :reimbursements
  has_many :profit_shares
  has_many :deel_invoice_adjustments
  has_many :pay_stubs
  has_many :recurring_ledger_adjustments, dependent: :destroy

  validates :enterprise_id, uniqueness: { scope: :contributor_id }

  def self.find_or_create_for(enterprise:, contributor:)
    find_or_create_by!(enterprise: enterprise, contributor: contributor)
  end

  # Idempotently creates a Ledger row for every (Enterprise, Contributor) pair.
  # Runs from:
  #   - the BackfillAllLedgers migration (so an empty timeline is filled at deploy)
  #   - stacks:daily_enterprise_tasks (belt-and-suspenders against drift)
  #   - Contributor.after_create / Enterprise.after_create (eager fill on add)
  # Bulk-loads existing pairs to avoid N+1; only INSERTS missing rows.
  # Returns the count of rows inserted.
  def self.ensure_all!
    existing = pluck(:enterprise_id, :contributor_id).to_set
    contributor_ids = Contributor.pluck(:id)
    enterprise_ids = Enterprise.pluck(:id)
    rows = []
    now = Time.current
    contributor_ids.each do |c_id|
      enterprise_ids.each do |e_id|
        next if existing.include?([e_id, c_id])
        rows << { enterprise_id: e_id, contributor_id: c_id, created_at: now, updated_at: now }
      end
    end
    insert_all(rows) if rows.any?
    rows.size
  end

  # Creates a Ledger for this contributor against every existing enterprise.
  # Invoked from Contributor.after_create so a brand-new contributor immediately
  # has a ledger for every enterprise — no manual setup, no waiting on cron.
  def self.ensure_for_contributor!(contributor)
    existing_enterprise_ids = where(contributor_id: contributor.id).pluck(:enterprise_id).to_set
    rows = []
    now = Time.current
    Enterprise.pluck(:id).each do |e_id|
      next if existing_enterprise_ids.include?(e_id)
      rows << { enterprise_id: e_id, contributor_id: contributor.id, created_at: now, updated_at: now }
    end
    insert_all(rows) if rows.any?
    rows.size
  end

  # Creates a Ledger for this enterprise against every existing contributor.
  # Invoked from Enterprise.after_create when a new enterprise is added.
  def self.ensure_for_enterprise!(enterprise)
    existing_contributor_ids = where(enterprise_id: enterprise.id).pluck(:contributor_id).to_set
    rows = []
    now = Time.current
    Contributor.pluck(:id).each do |c_id|
      next if existing_contributor_ids.include?(c_id)
      rows << { enterprise_id: enterprise.id, contributor_id: c_id, created_at: now, updated_at: now }
    end
    insert_all(rows) if rows.any?
    rows.size
  end

  # Balance/unsettled split.
  #   legacy:    balance = payable items, unsettled = non-payable items.
  #   qbo_bound: balance = payable items whose QBO bill isn't paid yet;
  #              unsettled = non-payable items (waiting on Stacks-side approval).
  #              Items where the QBO bill IS paid drop from BOTH buckets — they're
  #              settled in QBO and shouldn't show up in either Stacks total. This
  #              keeps the qbo_bound ledger one-to-one with the QBO vendor record.
  def balance
    if legacy?
      visible_items.select(&:payable?).sum(&:signed_amount)
    elsif qbo_bound?
      qbo_bound_visible_items.select(&:in_balance_under_qbo_bound?).sum do |li|
        li.respond_to?(:qbo_bound_balance_amount) ? li.qbo_bound_balance_amount : li.signed_amount
      end
    else
      raise "Unknown ledger mode: #{mode.inspect}"
    end
  end

  def unsettled
    if legacy?
      visible_items.reject(&:payable?).sum(&:signed_amount)
    elsif qbo_bound?
      qbo_bound_visible_items.reject(&:payable?).sum(&:signed_amount)
    else
      raise "Unknown ledger mode: #{mode.inspect}"
    end
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
        (li.is_a?(ContributorPayout) || li.is_a?(Trueup) || li.is_a?(PayStub)) ? li.amount.to_f : 0
      end

      acc[:all] = acc[:all] + sorted
      acc[:by_month][period] = {
        items: sorted,
        total_income: total_income,
      }
      acc
    end
  end

  # Rows that are bookkeeping-only under qbo_bound. Shared between
  # qbo_bound_visible_items and Ledgers::QboBoundMigrationCheck so the
  # two cannot drift.
  def self.audit_only_under_qbo_bound?(item)
    item.is_a?(DeelInvoiceAdjustment) ||
      (item.is_a?(ContributorAdjustment) && item.amount.to_f < 0)
  end

  protected

  # Non-deleted only — used by balance/unsettled sums.
  def visible_items
    [
      contributor_payouts.to_a,
      contributor_adjustments.to_a,
      trueups.to_a,
      reimbursements.to_a,
      profit_shares.to_a,
      deel_invoice_adjustments.to_a,
      pay_stubs.to_a,
    ].flatten
  end

  # qbo_bound mode: drop audit-only rows; everything else flows through
  # the per-host predicate in_balance_under_qbo_bound?.
  def qbo_bound_visible_items
    visible_items.reject { |li| self.class.audit_only_under_qbo_bound?(li) }
  end

  private

  # Includes soft-deleted rows — used by items_grouped_by_month for display.
  def all_items_with_deleted
    [
      ContributorPayout.with_deleted.includes(invoice_tracker: :invoice_pass).where(ledger_id: id).to_a,
      ContributorAdjustment.with_deleted.where(ledger_id: id).to_a,
      Trueup.with_deleted.includes(:invoice_pass).where(ledger_id: id).to_a,
      Reimbursement.with_deleted.where(ledger_id: id).to_a,
      ProfitShare.with_deleted.includes(:periodic_report).where(ledger_id: id).to_a,
      DeelInvoiceAdjustment.with_deleted.where(ledger_id: id).to_a,
      PayStub.with_deleted.includes(:pay_cycle).where(ledger_id: id).to_a,
    ].flatten
  end
end
