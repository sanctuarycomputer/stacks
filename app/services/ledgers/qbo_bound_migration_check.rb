module Ledgers
  # Decides whether a legacy Ledger can flip to qbo_bound.
  #
  # The ground-truth gate: does the post-migration Stacks state (balance +
  # unsettled under qbo_bound) match the contributor's QBO vendor AP balance
  # one-to-one? If yes, the qbo_bound ledger will mirror QBO. If no, there's
  # a real reconciliation gap — typically an Expense-to-AP or vendor credit
  # in QBO that Stacks can't see, or an open QBO bill that Stacks doesn't
  # know about.
  #
  # The legacy-vs-qbo_bound Δ is still surfaced as diagnostic info — useful
  # to explain WHY the two Stacks views differ — but it's not the gate.
  class QboBoundMigrationCheck
    TOLERANCE = 0.01

    Result = Struct.new(
      :current_balance, :current_unsettled,
      :proposed_balance, :proposed_unsettled,
      :balance_delta, :unsettled_delta,
      :stacks_open_total, :qbo_vendor_balance, :qbo_diff,
      :qbo_match?, :qbo_vendor_missing?,
      :ready?,
      :removed_neg_cas, :removed_dias, :dropped_paid_hosts, :open_qbo_bills,
      :unsynced_hosts, :unsynced_total,
      keyword_init: true,
    )

    OpenBill = Struct.new(:host, :qbo_bill, :amount, keyword_init: true)
    UnsyncedHost = Struct.new(:host, :amount, keyword_init: true)

    def self.call(ledger)
      legacy_visible = ledger.send(:visible_items)
      qbb_open       = ledger.send(:qbo_bound_open_items)

      legacy_b = legacy_visible.select(&:payable?).sum(&:signed_amount).to_f
      legacy_u = legacy_visible.reject(&:payable?).sum(&:signed_amount).to_f
      new_b    = qbb_open.select(&:payable?).sum { |li| ledger.send(:qbo_bound_contribution, li).to_f }
      new_u    = qbb_open.reject(&:payable?).sum { |li| ledger.send(:qbo_bound_contribution, li).to_f }

      db = (new_b - legacy_b).round(2)
      du = (new_u - legacy_u).round(2)

      stacks_open_total = (new_b + new_u).round(2)
      qa     = ledger.enterprise&.qbo_account
      vendor = qa.present? ? ledger.contributor&.qbo_vendor_for(qa) : nil
      # Only treat the vendor balance as known if it actually parses to a number.
      # `nil.to_f` and `"foo".to_f` both quietly become 0.0, which would let an
      # empty Stacks ledger declare a false-positive "match" against a vendor
      # whose real balance is unknown — silent under-payment when the operator
      # auto-flips on that. Require a strict numeric string.
      raw_balance = vendor&.data.is_a?(Hash) ? vendor.data["balance"] : nil
      qbo_vendor_balance = raw_balance.to_s.match?(/\A-?\d+(\.\d+)?\z/) ? raw_balance.to_f.round(2) : nil
      qbo_diff = qbo_vendor_balance ? (stacks_open_total - qbo_vendor_balance).round(2) : nil
      qbo_match = qbo_diff && qbo_diff.abs < TOLERANCE

      # Trivially empty ledgers: zero on both sides under both rules. Migration
      # changes nothing visible, so no QBO comparison needed — auto-flip them.
      # This catches the cross-product (every Contributor × every Enterprise)
      # ledgers that have no activity and no QBO vendor mapping.
      trivial = legacy_b.abs < TOLERANCE && legacy_u.abs < TOLERANCE &&
                new_b.abs    < TOLERANCE && new_u.abs    < TOLERANCE

      unsynced = collect_unsynced_hosts(qbb_open)
      unsynced_total = unsynced.sum { |h| h.amount.to_f }.round(2)

      Result.new(
        current_balance: legacy_b.round(2),
        current_unsettled: legacy_u.round(2),
        proposed_balance: new_b.round(2),
        proposed_unsettled: new_u.round(2),
        balance_delta: db,
        unsettled_delta: du,
        stacks_open_total: stacks_open_total,
        qbo_vendor_balance: qbo_vendor_balance,
        qbo_diff: qbo_diff,
        qbo_match?: qbo_match,
        qbo_vendor_missing?: vendor.nil?,
        ready?: trivial || (!vendor.nil? && qbo_match),
        removed_neg_cas: legacy_visible.select { |li| li.is_a?(ContributorAdjustment) && li.amount.to_f < 0 },
        removed_dias: legacy_visible.select { |li| li.is_a?(DeelInvoiceAdjustment) && li.payable? },
        dropped_paid_hosts: collect_dropped_paid_hosts(legacy_visible),
        open_qbo_bills: collect_open_qbo_bills(legacy_visible),
        unsynced_hosts: unsynced,
        unsynced_total: unsynced_total,
      )
    end

    # Payable hosts whose QBO bill is Paid. Diagnostic: they drop from
    # qbo_bound balance and explain part of the legacy-vs-qbo_bound Δ.
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

    # Payable hosts that should sync to QBO but have NO qbo_bill_id yet.
    # These contribute to Stacks open total but not to QBO vendor balance —
    # syncing them (via SyncsAsQboBill#sync_qbo_bill!) eliminates the diff.
    def self.collect_unsynced_hosts(items)
      items.filter_map do |li|
        next nil unless li.respond_to?(:qbo_bill)
        next nil unless li.payable?
        next nil unless li.qbo_bill.nil?

        UnsyncedHost.new(host: li, amount: li.signed_amount.to_f)
      end
    end

    # Unpaid QBO bills on the ledger. Marking one Paid in QBO turns it into
    # a dropped paid host and reduces Stacks open total by its amount.
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
