module Money
  # All payable ledger items targeting QBO: every SyncsAsQboBill host row whose
  # ledger has 'qbo' in payment_methods AND the row is payable?. Rows whose
  # QboBill exists AND is paid are dropped (settled in QBO). Rows with no
  # QboBill yet (sync hasn't fired, or failed) are included with `qbo_bill: nil`
  # so the view can surface them as "needs sync" errors instead of hiding them.
  # Tabbed per QBO account.
  class PayableQboBills
    HOST_KLASSES = [
      ContributorPayout,
      ContributorAdjustment,
      ProfitShare,
      Trueup,
      PayStub,
      Reimbursement,
    ].freeze

    Row = Struct.new(:host, :ledger, :contributor, :qbo_bill, :amount, keyword_init: true)

    def self.call(qbo_account:)
      rows = HOST_KLASSES.flat_map do |klass|
        klass
          .joins(ledger: { enterprise: :qbo_account })
          .where(qbo_accounts: { id: qbo_account.id })
          .where("'qbo' = ANY(ledgers.payment_methods)")
          .where(ledgers: { mode: Ledger.modes[:qbo_bound] })
          .includes(ledger: :contributor)
          .find_each.filter_map do |row|
            next nil unless row.payable?
            # Negative ContributorAdjustments (and DIAs, already excluded by HOST_KLASSES)
            # are audit-only under qbo_bound — bookkeeping reductions, not bills to sync.
            # Mirrors Ledger.audit_only_under_qbo_bound? so this page stays consistent
            # with the per-contributor qbo_bound balance computation.
            next nil if Ledger.audit_only_under_qbo_bound?(row)
            qb = row.try(:qbo_bill)
            next nil if qb&.paid?

            Row.new(
              host: row,
              ledger: row.ledger,
              contributor: row.ledger.contributor,
              qbo_bill: qb,
              amount: row.amount.to_f,
            )
          end
      end

      rows.sort_by { |r| [r.contributor.id, r.host.class.name, r.host.id] }
    end
  end
end
