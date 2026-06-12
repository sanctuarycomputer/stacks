module Ledgers
  # Computes whether a legacy Ledger can flip to qbo_bound with zero
  # change to balance or unsettled. Returns a Result struct exposing
  # the deltas and the open QBO bills that explain any gap.
  class QboBoundMigrationCheck
    TOLERANCE = 0.01.freeze

    Result = Struct.new(
      :current_balance, :current_unsettled,
      :proposed_balance, :proposed_unsettled,
      :balance_delta, :unsettled_delta,
      :ready?, :blocking_bills, :ignored_negative_cas,
      keyword_init: true,
    )

    BlockingBill = Struct.new(:host, :qbo_bill, :amount, keyword_init: true)

    def self.call(ledger)
      legacy_visible = ledger.send(:visible_items)
      qbb_visible    = ledger.send(:qbo_bound_visible_items)

      legacy_b = legacy_visible.select(&:payable?).sum(&:signed_amount).to_f
      legacy_u = legacy_visible.reject(&:payable?).sum(&:signed_amount).to_f
      new_b    = qbb_visible.select(&:in_balance_under_qbo_bound?).sum(&:signed_amount).to_f
      new_u    = qbb_visible.reject(&:in_balance_under_qbo_bound?).sum(&:signed_amount).to_f

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
        blocking_bills: collect_blocking_bills(legacy_visible),
        ignored_negative_cas: legacy_visible.select { |li| li.is_a?(ContributorAdjustment) && li.amount.to_f < 0 },
      )
    end

    def self.collect_blocking_bills(items)
      items.filter_map do |li|
        next nil if li.is_a?(DeelInvoiceAdjustment)
        next nil if li.is_a?(ContributorAdjustment) && li.amount.to_f < 0
        next nil unless li.respond_to?(:qbo_bill)
        next nil unless li.respond_to?(:payable?) && li.payable?

        qb = (li.qbo_bill rescue nil)
        next nil if qb.nil? || qb.paid?

        BlockingBill.new(host: li, qbo_bill: qb, amount: li.amount.to_f)
      end
    end
  end
end
