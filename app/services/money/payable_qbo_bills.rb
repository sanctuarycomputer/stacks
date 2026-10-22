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
      MsoTrueup,
    ].freeze

    # HOST_KLASSES, less any class whose table is not on this database yet.
    # Migrations are run by hand after the deploy; iterate THIS, not the
    # constant, or the Money page raises until then.
    def self.host_klasses
      HOST_KLASSES.select { |klass| !klass.respond_to?(:schema_ready?) || klass.schema_ready? }
    end

    Row = Struct.new(:host, :ledger, :contributor, :qbo_bill, :amount, keyword_init: true)

    def self.call(qbo_account:)
      rows = host_klasses.flat_map do |klass|
        klass
          .joins(ledger: { enterprise: :qbo_account })
          .where(qbo_accounts: { id: qbo_account.id })
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
