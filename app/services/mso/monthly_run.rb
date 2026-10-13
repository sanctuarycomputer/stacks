module Mso
  # One month's MSO executive compensation, computed from what is stored:
  #
  #   Mso::MonthlyRun.compute(month: Date.new(2026, 8, 1))
  #
  # It WRITES NOTHING. (Its one call outside the database is a QuickBooks
  # READ: garden3d's P&L for the month, fetched when none is stored.)
  # PeriodicReport#sync_mso_trueups! is what turns the answer into MsoTrueups,
  # on an admin's click, and records any Refused raised here as the report's
  # notification.
  class MonthlyRun
    # The month cannot be computed. The message is written to be shown to an
    # admin and says what to do.
    class Refused < StandardError; end

    ZERO = BigDecimal("0")

    # One executive: their role period, their garden3d ledger, what they
    # already earned in the month on each ledger, and the calculator's output.
    Line = Struct.new(:period, :ledger, :earned_by_ledger, :output, keyword_init: true) do
      def already_earned
        earned_by_ledger.values.sum(BigDecimal("0"))
      end

      # What is actually owed: the calculator's true-up rounded DOWN to the
      # cent. Earned income is not always whole cents (profit shares are
      # stored unrounded), so `final - earned` can carry a fraction of a cent,
      # and a sync would otherwise see "a different amount" each time and
      # clear the acceptance.
      def amount
        output.trueup.floor(2)
      end

      # Stored as the MsoTrueup's blueprint.
      def blueprint
        {
          "mso_role_period_id" => period.id,
          "contributor_id" => period.contributor_id,
          "tier" => period.tier,
          "title" => period.title,
          "multiplier" => period.tier_multiplier.to_s("F"),
          "already_earned" => already_earned.to_s("F"),
          "earned_by_ledger" => earned_by_ledger.to_h { |ledger_id, earned| [ledger_id.to_s, earned.to_s("F")] },
          "calculated" => output.calculated.to_s("F"),
          "final" => output.final.to_s("F"),
          "reduction" => output.reduction.to_s("F"),
          "trueup" => amount.to_s("F"),
        }
      end

      # Shown on the true-up's own page. No names: the page says whose it is.
      def description(month)
        money = ActionController::Base.helpers.method(:number_to_currency)
        <<~MARKDOWN
          # MSO true-up for #{month.strftime("%B %Y")}
          - **Role:** #{period.tier.titleize} (#{period.title}), #{period.tier_multiplier.to_s('F')}x
          - **Calculated:** #{money.call(output.calculated)}
          - **After the cap:** #{money.call(output.final)}
          - **Already earned this month:** #{money.call(already_earned)}
          - **True-up:** #{money.call(amount)}
        MARKDOWN
      end
    end

    Computation = Struct.new(:month, :reconciliation, :benchmark, :result, :lines, keyword_init: true) do
      # Stored as the monthly PeriodicReport's blueprint.
      def blueprint
        amounts = ->(entries) { entries.map { |e| { "contributor_id" => e[:contributor_id], "amount" => e[:amount].to_s("F") } } }
        {
          "fee_income" => reconciliation[:account_total].to_s("F"),
          "cap_percentage" => Mso::Compensation::DEFAULT_CAP_PERCENTAGE.to_s("F"),
          "cap" => result.cap.to_s("F"),
          # Unrounded: the average is a division.
          "benchmark_average" => benchmark.average.to_s("F"),
          "configured_n" => benchmark.configured_n,
          "counted" => benchmark.counted,
          "small_sample" => benchmark.small_sample,
          "benchmark_members" => amounts.call(benchmark.members),
          "excluded_without_login" => amounts.call(benchmark.excluded_without_login),
          "total_calculated" => result.total_calculated.to_s("F"),
          "total_trueup" => lines.sum(BigDecimal("0"), &:amount).to_s("F"),
          "reconciliation" => {
            "account_total" => reconciliation[:account_total].to_s("F"),
            "payer_total" => reconciliation[:payer_total].to_s("F"),
            "variance" => reconciliation[:variance].to_s("F"),
            "invoices" => reconciliation[:invoices].map do |invoice|
              { "tracker_id" => invoice[:tracker_id], "qbo_id" => invoice[:qbo_id],
                "total" => invoice[:total].to_s("F"),
                "managerial_services" => invoice[:managerial_services].to_s("F") }
            end,
          },
        }
      end
    end

    class << self
      def compute(month:, today: Date.today)
        new(month: month, today: today).compute
      end

      # One role period per person per month is a model validation only; the
      # database does not enforce it. Two would be two payments.
      def assert_one_period_per_person!(role_periods)
        doubled = role_periods.group_by(&:contributor_id).select { |_, periods| periods.size > 1 }
        return if doubled.empty?

        detail = doubled.map do |contributor_id, periods|
          "contributor #{contributor_id} (role periods #{periods.map(&:id).join(', ')})"
        end
        raise Refused, "More than one MSO role period is active in the month for #{detail.join('; ')}. " \
                       "End or delete the extra period on the MSO Roles page, then sync again."
      end

      # What a person has already earned in the month, per ledger, across ALL
      # their ledgers (netting is not per company). Ledgers with nothing are
      # left out. `excluding:` takes the month's own MSO true-ups: they are
      # qualifying income, and counted here a second sync would net each
      # true-up against itself.
      def already_earned(contributor_id:, month:, excluding: [])
        Ledger.where(contributor_id: contributor_id).order(:id).each_with_object({}) do |ledger, by_ledger|
          amount = Ledger::QualifyingIncome.for(ledger: ledger, month: month, excluding: excluding)
          by_ledger[ledger.id] = amount unless amount.zero?
        end
      end
    end

    def initialize(month:, today:)
      @month = month.beginning_of_month
      @label = @month.strftime("%B %Y")
      @today = today
    end

    def compute
      assert_month!
      assert_sanctuary_pass!
      reconciliation = reconcile!
      roster = roster!
      refuse_founder_trueups!(roster)

      benchmark = Mso::Benchmark.for_month(@month)
      own = MsoTrueup.where(periodic_report_id: PeriodicReport.month.where(period_starts_at: @month).select(:id)).to_a
      earned = roster.to_h do |period, _ledger|
        [period.contributor_id,
         self.class.already_earned(contributor_id: period.contributor_id, month: @month, excluding: own)]
      end

      result = Mso::Compensation.call(
        benchmark_average: benchmark.average,
        lines: roster.map do |period, _ledger|
          Mso::Compensation::Line.new(
            key: period.contributor_id,
            multiplier: period.tier_multiplier,
            already_earned: earned.fetch(period.contributor_id).values.sum(ZERO),
          )
        end,
        fee_income: reconciliation[:account_total],
        cap_percentage: Mso::Compensation::DEFAULT_CAP_PERCENTAGE,
      )
      outputs = result.outputs.index_by(&:key)
      lines = roster.map do |period, ledger|
        Line.new(period: period, ledger: ledger, earned_by_ledger: earned.fetch(period.contributor_id),
                 output: outputs.fetch(period.contributor_id))
      end

      Computation.new(month: @month, reconciliation: reconciliation, benchmark: benchmark, result: result,
                      lines: lines)
    end

    private

    def assert_month!
      start = InvoicePass::INTERCOMPANY_START
      if @month < start
        raise Refused, "MSO compensation starts in #{start.strftime('%B %Y')}; #{@label} is before that."
      end
      # garden3d's P&L for an unfinished month is whatever the last nightly
      # sync saw: a partial fee, and so a partial cap.
      if @today <= @month.end_of_month
        raise Refused, "#{@label} has not ended. Its management fee income is still a partial figure; " \
                       "sync after the month closes."
      end
    end

    # Sanctuary's pass must exist, be complete and have payouts. NOT "every
    # payout accepted": one person who never clicks Accept would then freeze
    # every executive's pay. A payout that changes later is picked up by
    # syncing again, until the month is settled.
    def assert_sanctuary_pass!
      sanctuary = Enterprise.sanctuary
      pass = InvoicePass.find_by(enterprise_id: sanctuary.id, start_of_month: @month)
      if pass.nil?
        raise Refused, "#{sanctuary.name} has no invoice pass for #{@label}, so there are no payouts to " \
                       "measure the benchmark or anyone's earnings from."
      end
      raise Refused, "#{sanctuary.name}'s pass for #{@label} has not finished invoicing." unless pass.complete?

      has_payouts = ContributorPayout.joins(:invoice_tracker)
        .where(invoice_trackers: { invoice_pass_id: pass.id }).exists?
      return if has_payouts

      raise Refused, "#{sanctuary.name}'s pass for #{@label} has no contributor payouts yet. " \
                     "Sync after payouts have been calculated."
    end

    # Account 4100 against the attached invoices' fee lines, as stored. There
    # is no override: the message says what was compared and what to do.
    def reconcile!
      Mso::ManagementFeeIncome.reconcile!(@month)
    rescue Mso::ManagementFeeIncome::RowMissing => e
      raise Refused, "#{e.message} MSO compensation is not computed for a month with no management fee " \
                     "income. If a fee was charged for #{@label}, check that it posts to account 4100 in " \
                     "garden3d's QuickBooks; Stacks sees the change after the nightly sync."
    rescue Mso::ManagementFeeIncome::VarianceError => e
      raise Refused, "#{e.message}. To clear this: (1) if a paying company's invoice is missing from the " \
                     "list above, attach it to that company's tracker on garden3d's pass; (2) if an " \
                     "invoice's Managerial Services figure is lower than its total and the difference is " \
                     "fee, Finance moves that line to the #{Mso::IntercompanyInvoices::ITEM_NAME} item in " \
                     "QuickBooks; (3) if account 4100 holds income that is not a management fee, Finance " \
                     "moves it to another account, and Stacks sees that after the nightly sync; (4) if an " \
                     "invoice is dated in another month, Finance corrects the date. Then sync again."
    rescue Mso::ManagementFeeIncome::Error => e
      raise Refused, e.message
    end

    # [[MsoRolePeriod, garden3d Ledger], ...], one pair per executive.
    def roster!
      periods = MsoRolePeriod.active_during(@month).order(:id).to_a
      self.class.assert_one_period_per_person!(periods)

      garden3d = Enterprise.garden3d
      periods.map do |period|
        # find_by, not find_or_create: computing must not write. Every
        # contributor has a ledger per company (Ledger.ensure_all!).
        ledger = Ledger.find_by(enterprise_id: garden3d.id, contributor_id: period.contributor_id)
        raise Refused, "Contributor #{period.contributor_id} has no #{garden3d.name} ledger." if ledger.nil?
        unless ledger.qbo_bound?
          # The Money page lists only QuickBooks-bound ledgers; a true-up on
          # any other would be invisible there and never paid.
          raise Refused, "Ledger #{ledger.id} (contributor #{period.contributor_id} on #{garden3d.name}) is " \
                         "not QuickBooks-bound, so a true-up on it could not be paid. Migrate the ledger, " \
                         "then sync again."
        end
        [period, ledger]
      end
    end

    # A founder true-up (Trueup) for someone on the roster, in this month, is
    # the old arrangement paying for the same month. It is uncapped money on
    # another company's ledger, already billed in that company's QuickBooks by
    # the nightly sync. Netting against it would let it stand outside the cap,
    # so the month is not computed until a person has removed it.
    def refuse_founder_trueups!(roster)
      contributor_ids = roster.map { |period, _ledger| period.contributor_id }
      rows = Trueup.joins(:ledger, :invoice_pass)
        .where(ledgers: { contributor_id: contributor_ids }, invoice_passes: { start_of_month: @month })
        .order("trueups.id").pluck("trueups.id", "ledgers.contributor_id", "trueups.ledger_id")
      return if rows.empty?

      detail = rows.map { |id, contributor_id, ledger_id| "Trueup #{id} (contributor #{contributor_id}, ledger #{ledger_id})" }
      raise Refused, "#{@label} already has a founder true-up for someone on the MSO roster: " \
                     "#{detail.join('; ')}. The MSO true-up replaces it, so it has to go first. Open it from " \
                     "that ledger and delete it: that also deletes its QuickBooks bill, and is refused if " \
                     "the bill has any payment. If the bill has been paid, that month was paid the old way; " \
                     "void the payment in QuickBooks first, or end the role period so it starts the " \
                     "following month. Then sync again."
    end
  end
end
