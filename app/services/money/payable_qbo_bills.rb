module Money
  # Selects open QBO bills payable through Stacks: every SyncsAsQboBill host
  # row whose ledger has 'qbo' in payment_methods, where the row is payable?
  # AND the QboBill mirror is still open. Tabbed per QBO account.
  class PayableQboBills
    HOST_KLASSES = [
      ContributorPayout,
      ContributorAdjustment,
      ProfitShare,
      Trueup,
      PayStub,
    ].freeze

    Row = Struct.new(:host, :ledger, :contributor, :qbo_bill, :amount, keyword_init: true)

    def self.call(qbo_account:)
      rows = HOST_KLASSES.flat_map do |klass|
        klass
          .where.not(qbo_bill_id: nil)
          .joins(ledger: { enterprise: :qbo_account })
          .where(qbo_accounts: { id: qbo_account.id })
          .where("'qbo' = ANY(ledgers.payment_methods)")
          .includes(ledger: :contributor)
          .find_each.filter_map do |row|
            next nil unless row.payable?
            qb = (row.qbo_bill rescue nil)
            next nil if qb.nil? || qb.paid?

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
