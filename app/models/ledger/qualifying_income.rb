# One ledger's qualifying compensation for one calendar month: contributor
# payouts, true-ups and pay stubs. Reimbursements, adjustments, profit shares
# and Deel invoice adjustments are not compensation.
#
# Reads live rows only. Ledger#items_grouped_by_month's total_income is a
# different number on purpose — it includes soft-deleted rows so the ledger
# page can show strikethroughs. A deleted payout is not income.
module Ledger::QualifyingIncome
  # class => associations to preload so effective_on_for_display is query-free
  SOURCES = {
    ContributorPayout => { invoice_tracker: :invoice_pass },
    Trueup => :invoice_pass,
    PayStub => :pay_cycle,
  }.freeze

  KLASSES = SOURCES.keys.freeze

  ZERO = BigDecimal("0")

  def self.for(ledger:, month:, excluding: [], klasses: KLASSES)
    unknown = klasses - KLASSES
    raise ArgumentError, "not qualifying income: #{unknown.map(&:name).join(', ')}" if unknown.any?

    range = month.beginning_of_month..month.end_of_month
    excluded = excluding.map { |record| [record.class.name, record.id] }.to_set

    # uniq: naming a class twice must not count its rows twice.
    klasses.uniq.sum(ZERO) do |klass|
      # .to_a first: Relation#sum with both an initial value and a block raises
      # in Rails 6.1.
      klass.where(ledger_id: ledger.id).includes(SOURCES.fetch(klass)).to_a.sum(ZERO) do |item|
        next ZERO if excluded.include?([item.class.name, item.id])

        effective_on = item.effective_on_for_display
        next ZERO unless effective_on && range.cover?(effective_on.to_date)

        BigDecimal(item.amount.to_s)
      end
    end
  end
end
