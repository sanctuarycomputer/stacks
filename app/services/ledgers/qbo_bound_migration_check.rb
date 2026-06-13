module Ledgers
  # Computes whether a legacy Ledger can flip to qbo_bound with zero
  # change to balance or unsettled. Returns a Result struct exposing
  # the deltas and the per-item drivers — items whose treatment differs
  # between the two rules.
  #
  # Driver categories (each contributes to Δbalance):
  #   - removed_neg_cas    — negative CAs ignored under qbo_bound (Δ += |amount|)
  #   - removed_dias       — DIAs ignored under qbo_bound        (Δ += amount)
  #   - dropped_paid_hosts — payable hosts whose QBO bill is Paid (Δ −= amount)
  #
  # open_qbo_bills are unpaid bills on the ledger. They're informational —
  # they contribute equally to balance under both rules (no Δ), but marking
  # one Paid in QBO turns it into a dropped_paid_host on the next check,
  # which is a remedy when Δ > 0.
  class QboBoundMigrationCheck
    TOLERANCE = 0.01

    Result = Struct.new(
      :current_balance, :current_unsettled,
      :proposed_balance, :proposed_unsettled,
      :balance_delta, :unsettled_delta,
      :ready?,
      :removed_neg_cas, :removed_dias, :dropped_paid_hosts, :open_qbo_bills,
      keyword_init: true,
    )

    OpenBill = Struct.new(:host, :qbo_bill, :amount, keyword_init: true)

    def self.call(ledger)
      legacy_visible = ledger.send(:visible_items)
      qbb_visible    = ledger.send(:qbo_bound_visible_items)

      legacy_b = legacy_visible.select(&:payable?).sum(&:signed_amount).to_f
      legacy_u = legacy_visible.reject(&:payable?).sum(&:signed_amount).to_f
      new_b    = qbb_visible.select(&:in_balance_under_qbo_bound?).sum(&:signed_amount).to_f
      new_u    = qbb_visible.reject(&:payable?).sum(&:signed_amount).to_f

      db = (new_b - legacy_b).round(2)
      du = (new_u - legacy_u).round(2)

      Result.new(
        current_balance: legacy_b.round(2),
        current_unsettled: legacy_u.round(2),
        proposed_balance: new_b.round(2),
        proposed_unsettled: new_u.round(2),
        balance_delta: db,
        unsettled_delta: du,
        ready?: db.abs < TOLERANCE && du.abs < TOLERANCE,
        removed_neg_cas: legacy_visible.select { |li| li.is_a?(ContributorAdjustment) && li.amount.to_f < 0 },
        removed_dias: legacy_visible.select { |li| li.is_a?(DeelInvoiceAdjustment) && li.payable? },
        dropped_paid_hosts: collect_dropped_paid_hosts(legacy_visible),
        open_qbo_bills: collect_open_qbo_bills(legacy_visible),
      )
    end

    # Payable hosts whose QBO bill is Paid. They drop from qbo_bound balance,
    # decreasing Δ by their amount.
    def self.collect_dropped_paid_hosts(items)
      items.filter_map do |li|
        next nil if Ledger.audit_only_under_qbo_bound?(li)
        next nil unless li.respond_to?(:qbo_bill)
        next nil unless li.payable?

        qb = li.qbo_bill
        next nil if qb.nil? || !qb.paid?

        OpenBill.new(host: li, qbo_bill: qb, amount: li.amount.to_f)
      end
    end

    # Unpaid QBO bills on the ledger. They don't cause Δ — they contribute
    # equally under both rules — but they're surfaced so the controller can
    # mark them Paid to remedy a positive Δ.
    def self.collect_open_qbo_bills(items)
      items.filter_map do |li|
        next nil if Ledger.audit_only_under_qbo_bound?(li)
        next nil unless li.respond_to?(:qbo_bill)
        next nil unless li.payable?

        qb = li.qbo_bill
        next nil if qb.nil? || qb.paid?

        OpenBill.new(host: li, qbo_bill: qb, amount: li.amount.to_f)
      end
    end
  end
end
