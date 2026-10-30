# One ledger's qualifying compensation for one calendar month: anything that
# is payment for doing work.
#
#   Counts:         contributor payouts, pay stubs, profit shares, true-ups
#                   (the founder's and the MSO's), and POSITIVE contributor
#                   adjustments (recruiting fees, advances and the like).
#   Does not count: reimbursements; Deel invoice adjustments; and NEGATIVE
#                   contributor adjustments. Negative adjustments are not pay
#                   cuts — they are the old ledger style's record of money
#                   paid OUT to someone (a QuickBooks payment mirrored onto the
#                   ledger so its balance read earned-minus-paid). Counting
#                   them would subtract what a person was paid from what they
#                   earned.
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
    ProfitShare => :periodic_report,
    ContributorAdjustment => nil,
    # An executive's MSO true-up. Mso::MonthlyRun passes the month's own
    # true-ups as `excluding:`, or a second sync would net each against itself.
    MsoTrueup => :periodic_report,
  }.freeze

  # Mso::Benchmark deliberately narrows this (its own KLASSES leaves out
  # true-ups and profit shares): a true-up is a top-up, not earnings, and a
  # quarter's profit share would lift one month. Both stay in here because
  # they are money a person has already received.
  KLASSES = SOURCES.keys.freeze

  # Classes whose negative rows are payment records rather than income.
  POSITIVE_ONLY = [ContributorAdjustment].freeze

  ZERO = BigDecimal("0")

  def self.for(ledger:, month:, excluding: [], klasses: KLASSES)
    unknown = klasses - KLASSES
    raise ArgumentError, "not qualifying income: #{unknown.map(&:name).join(', ')}" if unknown.any?

    range = month.beginning_of_month..month.end_of_month
    excluded = excluding.map { |record| [record.class.name, record.id] }.to_set

    # uniq: naming a class twice must not count its rows twice.
    klasses.uniq.sum(ZERO) do |klass|
      # Migrations are run by hand after the deploy: a class whose table is
      # not there yet has no rows.
      next ZERO if klass.respond_to?(:schema_ready?) && !klass.schema_ready?

      rows = klass.where(ledger_id: ledger.id)
      preloads = SOURCES.fetch(klass)
      rows = rows.includes(preloads) if preloads

      # .to_a first: Relation#sum with both an initial value and a block raises
      # in Rails 6.1.
      rows.to_a.sum(ZERO) do |item|
        next ZERO if excluded.include?([item.class.name, item.id])

        effective_on = item.effective_on_for_display
        next ZERO unless effective_on && range.cover?(effective_on.to_date)

        amount = BigDecimal(item.amount.to_s)
        next ZERO if POSITIVE_ONLY.include?(klass) && !amount.positive?

        amount
      end
    end
  end
end
