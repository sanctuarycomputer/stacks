module Mso
  # The average income of Sanctuary's top N earners for a month — the figure
  # each MSO executive's tier multiplier is applied to.
  #
  # Current month only; no smoothing across months.
  #
  # This is a live calculation, not a record: it reads today's roster and
  # today's payouts, so a backdated roster change or a re-run payout changes
  # the answer for a past month. Whatever pays people from it must store the
  # members and the average it used. The average is unrounded — store it in
  # full (average.to_s), not to two decimals, or a later recomputation from
  # the stored figure can differ from what was paid by a cent.
  class Benchmark
    # Everything that is payment for work — payouts, pay stubs, profit shares
    # and positive adjustments such as recruiting fees — but not true-ups. A
    # true-up is a top-up, not earnings: today every true-up is the monthly
    # founder true-up, which lifts one person to exactly the highest earner's
    # figure, so counting it would put a copy of the top earner in the pool.
    KLASSES = (Ledger::QualifyingIncome::KLASSES - [Trueup]).freeze

    Result = Struct.new(:average, :configured_n, :counted, :members, :small_sample,
                        :excluded_without_login, keyword_init: true)

    ZERO = BigDecimal("0")

    def self.for_month(date, top_n: System.mso_top_n)
      new(date, top_n).call
    end

    def initialize(date, top_n)
      raise ArgumentError, "top_n must be at least 1 (got #{top_n.inspect})" if top_n.to_i < 1
      @date = date
      @top_n = top_n.to_i
    end

    def call
      with_login, without_login = earners.partition { |entry| entry[:login] }
      members = rank(with_login).first(@top_n)
      average = members.empty? ? ZERO : members.sum(ZERO) { |m| m[:amount] } / members.size

      # Having no login is a proxy for "outside party", and it also leaves out
      # ordinary contractors. Report anyone it removed who would have ranked.
      threshold = members.size < @top_n ? ZERO : members.last[:amount]
      # >= so that someone who ties the last counted member is reported too.
      excluded = rank(without_login).select { |entry| entry[:amount] >= threshold }

      Result.new(
        average: average,
        configured_n: @top_n,
        counted: members.size,
        members: members.map { |m| m.slice(:contributor_id, :amount) },
        small_sample: members.size < @top_n,
        excluded_without_login: excluded.map { |m| m.slice(:contributor_id, :amount) },
      )
    end

    private

    def rank(entries)
      entries.sort_by { |entry| [-entry[:amount], entry[:contributor_id]] }
    end

    def earners
      pool.filter_map do |ledger|
        amount = Ledger::QualifyingIncome.for(ledger: ledger, month: @date, klasses: KLASSES)
        next unless amount.positive?

        {
          contributor_id: ledger.contributor_id,
          amount: amount,
          login: ledger.contributor&.forecast_person&.admin_user.present?,
        }
      end
    end

    # Sanctuary ledgers, minus anyone who holds or has held an MSO role by the
    # end of this month: an executive's own earnings must not set their
    # benchmark, and a departed executive's must not set their former peers'.
    def pool
      Ledger
        .where(enterprise: Enterprise.sanctuary)
        .where.not(contributor_id: executive_contributor_ids)
        .includes(contributor: { forecast_person: :admin_user })
    end

    def executive_contributor_ids
      MsoRolePeriod.where("started_at <= ?", @date.end_of_month).distinct.pluck(:contributor_id)
    end
  end
end
