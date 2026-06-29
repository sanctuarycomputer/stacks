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
  validate :payment_methods_are_known
  validate :qbo_bound_requires_qbo_payment_method

  before_validation :default_payment_methods, on: :create

  # Inferred default payment methods for a contributor.
  #   no DeelPerson           → ["qbo"]
  #   DeelPerson, country=US  → ["qbo"]   (US Deel contractors paid via QBO bills)
  #   DeelPerson, otherwise   → ["deel"]  (non-US, OR country unknown — Deel's
  #                                        primary use case is overseas payment,
  #                                        and assuming non-US preserves the
  #                                        Deel withdrawal workflow even when
  #                                        addresses data is incomplete)
  # Shared between the schema backfill, the ensure_* bulk paths, and the
  # per-record before_validation hook. Uses DeelPerson#country (reads from
  # data["addresses"].first["country"], the actual Deel API shape — top-level
  # data["country"] is always nil in prod).
  def self.payment_methods_for(contributor)
    return %w[qbo] if contributor.nil?
    dp = contributor.deel_person
    return %w[qbo] if dp.nil?
    return %w[qbo] if dp.country.to_s.upcase == "US"
    %w[deel]
  end

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
  # The mode default in the DB is qbo_bound (=1) so newly added pairs land
  # qbo_bound automatically. But a Deel-only ledger MUST stay legacy — the
  # qbo_bound path drops DeelInvoiceAdjustments as audit-only via
  # `audit_only_under_qbo_bound?`, which would silently mask every Deel
  # payout. Bulk-insert paths use this helper so the row's mode tracks its
  # payment_methods at INSERT time.
  def self.mode_for_payment_methods(pm)
    pm.include?("qbo") ? modes[:qbo_bound] : modes[:legacy]
  end

  def self.ensure_all!
    existing = pluck(:enterprise_id, :contributor_id).to_set
    contributors = Contributor.includes(:deel_person).index_by(&:id)
    enterprise_ids = Enterprise.pluck(:id)
    rows = []
    now = Time.current
    contributors.each_value do |contributor|
      pm = payment_methods_for(contributor)
      enterprise_ids.each do |e_id|
        next if existing.include?([e_id, contributor.id])
        rows << { enterprise_id: e_id, contributor_id: contributor.id, payment_methods: "{#{pm.join(",")}}", mode: mode_for_payment_methods(pm), created_at: now, updated_at: now }
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
    pm = payment_methods_for(contributor)
    rows = []
    now = Time.current
    Enterprise.pluck(:id).each do |e_id|
      next if existing_enterprise_ids.include?(e_id)
      rows << { enterprise_id: e_id, contributor_id: contributor.id, payment_methods: "{#{pm.join(",")}}", mode: mode_for_payment_methods(pm), created_at: now, updated_at: now }
    end
    insert_all(rows) if rows.any?
    rows.size
  end

  # Creates a Ledger for this enterprise against every existing contributor.
  # Invoked from Enterprise.after_create when a new enterprise is added.
  def self.ensure_for_enterprise!(enterprise)
    existing_contributor_ids = where(enterprise_id: enterprise.id).pluck(:contributor_id).to_set
    contributors = Contributor.where.not(id: existing_contributor_ids).includes(:deel_person)
    rows = []
    now = Time.current
    contributors.each do |contributor|
      pm = payment_methods_for(contributor)
      rows << { enterprise_id: enterprise.id, contributor_id: contributor.id, payment_methods: "{#{pm.join(",")}}", mode: mode_for_payment_methods(pm), created_at: now, updated_at: now }
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
    sum_for_bucket(payable: true)
  end

  def unsettled
    sum_for_bucket(payable: false)
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

  # qbo_bound mode: drop audit-only rows. The remaining items are then split
  # by `qbo_bound_open_items` (paid bills drop too) and bucketed by `payable?`.
  def qbo_bound_visible_items
    visible_items.reject { |li| self.class.audit_only_under_qbo_bound?(li) }
  end

  # qbo_bound mode: items that should still appear somewhere (balance or
  # unsettled). Audit-only items are dropped, AND any host whose QBO bill
  # is fully Paid is dropped — paid bills are settled in QBO and shouldn't
  # show up in Stacks at all. Partial-paid bills survive (their remaining
  # balance is the contribution).
  def qbo_bound_open_items
    qbo_bound_visible_items.reject { |li| li.try(:qbo_bill)&.paid? }
  end

  # qbo_bound mode: per-item dollar amount. Uses the QBO bill's remaining
  # balance when a bill exists so partial payments are reflected one-to-one
  # with QBO's vendor AP; falls back to the host's signed_amount otherwise.
  def qbo_bound_contribution(li)
    if li.respond_to?(:qbo_bound_balance_amount)
      li.qbo_bound_balance_amount
    else
      li.signed_amount
    end
  end

  private

  def default_payment_methods
    return unless payment_methods.blank?
    self.payment_methods = self.class.payment_methods_for(contributor)
    # If the inferred payment_methods doesn't include 'qbo', force mode back to
    # legacy. Without this, the DB default (qbo_bound) would silently bind a
    # Deel-only ledger to the qbo_bound code path, where audit_only_under_qbo_bound?
    # drops every DeelInvoiceAdjustment — the contributor's balance would never
    # decrease when they got paid via Deel.
    self.mode = :legacy if payment_methods.exclude?("qbo")
  end

  def sum_for_bucket(payable:)
    if legacy?
      visible_items.select { |li| li.payable? == payable }.sum(&:signed_amount)
    elsif qbo_bound?
      qbo_bound_open_items.select { |li| li.payable? == payable }.sum { |li| qbo_bound_contribution(li) }
    else
      raise "Unknown ledger mode: #{mode.inspect}"
    end
  end

  def payment_methods_are_known
    return if payment_methods.blank?
    bad = payment_methods - PAYMENT_METHODS
    errors.add(:payment_methods, "contains unknown value(s): #{bad.join(", ")}") if bad.any?
  end

  # Cross-field invariant: qbo_bound mode + payment_methods that don't include
  # 'qbo' is unsafe — the qbo_bound balance computation calls
  # audit_only_under_qbo_bound? which drops every DeelInvoiceAdjustment, so a
  # Deel-only ledger in qbo_bound mode silently loses every Deel payment from
  # its balance. (Also catches the payment_methods=[] edge case — `present?`
  # is false for empty arrays so we can't gate on it.)
  def qbo_bound_requires_qbo_payment_method
    return unless qbo_bound?
    return if payment_methods.is_a?(Array) && payment_methods.include?("qbo")
    errors.add(:mode, "cannot be qbo_bound on a ledger without 'qbo' in payment_methods (DIA contributions would be filtered as audit-only and never deducted from balance)")
  end

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
