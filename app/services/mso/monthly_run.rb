module Mso
  # Computes one month's MSO executive compensation and writes it down: an
  # immutable MsoSnapshot of every input and output, and one MsoTrueup on the
  # garden3d ledger of each executive who is owed money.
  #
  #   Mso::MonthlyRun.call(invoice_pass: garden3ds_pass, run_by: admin)
  #   Mso::MonthlyRun.preview(invoice_pass: garden3ds_pass)  # computes, writes nothing
  #
  # NOTHING SCHEDULED CALLS .call. It is reached from an admin's click on
  # garden3d's pass. It makes one QuickBooks READ per management fee invoice
  # (through Mso::ManagementFeeInvoices.collected?) and no QuickBooks write.
  # It pays nobody: a true-up becomes payable only after its executive
  # accepts it, every other executive accepts theirs, and the fee is confirmed
  # collected; and it reaches QuickBooks only when an admin syncs it from the
  # Money page, where it is checked against a fresh computation first.
  #
  # Running a month again is safe and is how a changed payout is picked up:
  # the snapshot is superseded, not edited, and each true-up is updated in
  # place. A true-up that already has a QuickBooks bill is never changed; if
  # its figure moved, the difference is recorded on the snapshot as drift.
  class MonthlyRun
    # The run would not start, or would not finish. The message is written to
    # be shown to an admin and says what to do.
    class Refused < StandardError; end

    ZERO = BigDecimal("0")

    # How far back the nightly drift check looks (.record_income_drift!).
    # Each snapshot it recomputes costs about a thousand queries.
    DRIFT_WINDOW_MONTHS = 6

    Planned =Struct.new(:period, :ledger, :earned_by_ledger, :output, keyword_init: true) do
      def already_earned
        earned_by_ledger.values.sum(BigDecimal("0"))
      end

      # What is actually owed: the calculator's true-up rounded DOWN to the
      # cent. Earned income is not always whole cents (profit shares are
      # stored unrounded), so `final - earned` can carry a fraction of a cent.
      # Every use of a true-up amount goes through here, or a re-run would see
      # "a different amount" each time and clear the acceptance.
      def amount
        output.trueup.floor(2)
      end
    end

    Computation = Struct.new(:sanctuary_pass, :reconciliation, :benchmark, :result, :planned, :existing,
                             keyword_init: true)

    class << self
      def call(invoice_pass:, run_by: nil, today: Date.today)
        new(invoice_pass: invoice_pass, run_by: run_by, today: today).call
      end

      # What a run would produce right now, without writing anything and
      # without calling QuickBooks: { garden3d ledger id => true-up amount }.
      # Reads the invoice mirrors as stored, so refresh them first if that
      # matters (MsoSnapshot#check_collection! does). Raises Refused exactly
      # where a run would. Used to check a true-up is still right at the
      # moment its QuickBooks bill is first created.
      def preview(invoice_pass:, today: Date.today)
        new(invoice_pass: invoice_pass, run_by: nil, today: today).preview
      end

      # May a run be offered for this pass at all? (Whether it then succeeds
      # depends on the month's state; see #call.)
      def runnable?(invoice_pass)
        invoice_pass.management_fee? &&
          invoice_pass.start_of_month >= Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START &&
          !invoice_pass.legacy_forecast_trackers?
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
                       "End or delete the extra period on the MSO Roles page, then run again."
      end

      # What a person has already earned in the month, per ledger, across ALL
      # their ledgers (netting is not per company). Ledgers with nothing are
      # left out. `excluding:` takes the month's own MSO true-ups: they are
      # qualifying income, and counted here a re-run would net each true-up
      # against itself.
      def already_earned(contributor_id:, month:, excluding: [])
        Ledger.where(contributor_id: contributor_id).order(:id).each_with_object({}) do |ledger, by_ledger|
          amount = Ledger::QualifyingIncome.for(ledger: ledger, month: month, excluding: excluding)
          by_ledger[ledger.id] = amount unless amount.zero?
        end
      end

      # NIGHTLY, DATABASE ONLY. garden3d's stored P&L is re-fetched every
      # night by the existing sync; this compares what it now says for account
      # 4100 with the fee income each live snapshot was computed from, and
      # invalidates a snapshot whose fee has moved (an invoice voided, edited
      # or added after the run). It never fetches: a month with no stored
      # report is skipped. Returns the ids it invalidated.
      def invalidate_snapshots_whose_fee_moved!
        return [] unless MsoTrueup.schema_ready?

        garden3d_account_ids = QboAccount.where(enterprise_id: Enterprise.garden3d.id).pluck(:id)
        MsoSnapshot.current.where(invalidated_at: nil).includes(:invoice_pass).filter_map do |snapshot|
          month = snapshot.invoice_pass.start_of_month
          stored = QboProfitAndLossReport
            .where(qbo_account_id: garden3d_account_ids, starts_at: month, ends_at: month.end_of_month).exists?
          next unless stored # Mso::ManagementFeeIncome would FETCH a missing report; never do that here

          now_reads =
            begin
              Mso::ManagementFeeIncome.for_month(month).to_s("F")
            rescue Mso::ManagementFeeIncome::Error
              "no readable figure"
            end
          next if now_reads == snapshot.fee_income.to_s("F")

          snapshot.invalidate!("Account 4100 now reads #{now_reads} for #{snapshot.invoice_pass.invoice_month}; " \
                               "this run used #{snapshot.fee_income.to_s('F')}. Run the month again.")
          snapshot.id
        end
      end

      # NIGHTLY, DATABASE ONLY. A run nets each executive against everything
      # they earned in the month on every ledger, but only waits for
      # Sanctuary's pass: another company's invoice, a profit share or an
      # adjustment can land afterwards, and so can a roster or payout change.
      # This recomputes each live snapshot of the last DRIFT_WINDOW_MONTHS
      # months (.preview: stored data only) and records, on the snapshot, every
      # executive whose true-up would now be a different amount.
      #
      #   A drifted true-up with NO QuickBooks bill: the snapshot is also
      #   invalidated, as the fee check invalidates it, so the stale figure is
      #   not payable. (Its first bill would be refused anyway; this says so
      #   the next morning instead of at the click.)
      #   A drifted true-up WITH a bill: recorded only. The money is in
      #   QuickBooks; a person decides.
      #
      # It never fetches: a month with no stored P&L is skipped, because
      # computing it would fetch one. It creates, changes and deletes no
      # true-up and no bill, and nothing it meets is allowed to raise out of
      # the nightly job. Returns the ids of the snapshots it flagged.
      #
      # There is no cheap, sound test for "nothing in this month can have
      # changed" (a deleted payout leaves no timestamp behind), so every
      # snapshot in the window is recomputed: one Mso::Benchmark each, about a
      # thousand queries. The window is what bounds it.
      def record_income_drift!(today: Date.today)
        return [] unless MsoTrueup.schema_ready? && MsoSnapshot.tracks_income_drift?

        earliest = today.beginning_of_month - DRIFT_WINDOW_MONTHS.months
        garden3d_account_ids = QboAccount.where(enterprise_id: Enterprise.garden3d.id).pluck(:id)
        snapshots = MsoSnapshot.current.where(invalidated_at: nil).joins(:invoice_pass)
          .where("invoice_passes.start_of_month >= ?", earliest).includes(:invoice_pass).order(:id).to_a

        snapshots.filter_map do |snapshot|
          month = snapshot.invoice_pass.start_of_month
          stored = QboProfitAndLossReport
            .where(qbo_account_id: garden3d_account_ids, starts_at: month, ends_at: month.end_of_month).exists?
          next unless stored # Mso::ManagementFeeIncome would FETCH a missing report; never do that here

          snapshot.id if record_income_drift_on!(snapshot, today)
        rescue StandardError => e
          Rails.logger.error("[mso] income drift check failed for MsoSnapshot #{snapshot.id}: " \
                             "#{e.class}: #{e.message}")
          Sentry.capture_exception(e) if defined?(Sentry)
          nil
        end
      rescue StandardError => e
        Rails.logger.error("[mso] income drift check failed: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        []
      end

      private

      # Writes what the check found (nothing found included, so the page can
      # say when it last looked). True when the snapshot was flagged.
      def record_income_drift_on!(snapshot, today)
        pass = snapshot.invoice_pass
        found = { "checked_at" => Time.current.iso8601, "lines" => [] }
        begin
          found["lines"] = income_drift_lines(snapshot, preview(invoice_pass: pass, today: today))
        rescue Refused => e
          # The month cannot be computed as it stands. Not invalidated here:
          # what stopped it is either the fee (the fee check's business) or
          # something a first bill is refused for anyway.
          found["refused"] = e.message.to_s.truncate(1000)
        end
        snapshot.update_columns(income_drift: found)

        unbilled = found["lines"].reject { |line| line["billed"] }
        if unbilled.any?
          snapshot.invalidate!(
            "A nightly recomputation on #{today} no longer gives this run's true-up for contributor " \
            "#{unbilled.map { |line| line['contributor_id'] }.join(', ')}: income, the roster or the benchmark " \
            "changed after the run. Run the month again.",
          )
        end
        found["lines"].any? || found.key?("refused")
      end

      # `now` is .preview's { garden3d ledger id => amount }. Someone no
      # longer on the roster reads as zero now; someone new, as zero stored.
      def income_drift_lines(snapshot, now)
        stored = snapshot.lines.to_h { |line| [line["ledger_id"], BigDecimal(line["trueup"].to_s)] }
        contributors = snapshot.lines.to_h { |line| [line["ledger_id"], line["contributor_id"]] }
        contributors.merge!(Ledger.where(id: now.keys - stored.keys).pluck(:id, :contributor_id).to_h)
        billed = MsoTrueup.where(invoice_pass_id: snapshot.invoice_pass_id).where.not(qbo_bill_id: nil)
          .pluck(:ledger_id).to_set

        (stored.keys | now.keys).sort.filter_map do |ledger_id|
          was = stored.fetch(ledger_id, ZERO)
          is = now.fetch(ledger_id, ZERO)
          next if was == is

          { "contributor_id" => contributors[ledger_id], "ledger_id" => ledger_id,
            "stored" => was.to_s("F"), "now" => is.to_s("F"), "billed" => billed.include?(ledger_id) }
        end
      end
    end

    def initialize(invoice_pass:, run_by:, today:)
      # A fresh copy: the caller's may carry stale associations.
      @pass = InvoicePass.find(invoice_pass.id)
      @month = @pass.start_of_month
      @run_by = run_by
      @today = today
    end

    def call
      run
    rescue Refused => e
      # Fail closed. Whatever stopped this run (a voided invoice, a variance,
      # a doubled roster row) may also mean the previous run's figures are no
      # longer right. The current snapshot is marked invalid: nothing from it
      # is payable, and Check collection cannot bring it back. Only a run that
      # succeeds (and so writes a new snapshot) clears this.
      invalidate_current!("A later run on #{@today} was refused: #{e.message}")
      raise
    rescue StandardError => e
      invalidate_current!("A later run on #{@today} failed with #{e.class}. Run the month again.")
      raise
    end

    def preview
      assert_runnable!
      computation = compute(sanctuary_pass!, reconcile!)
      computation.planned.to_h { |plan| [plan.ledger.id, plan.amount] }
    end

    private

    def run
      assert_runnable!
      sanctuary_pass = sanctuary_pass!
      # QuickBooks reads happen here, outside the transaction below.
      collected = fee_collected!
      reconciliation = reconcile!

      InvoicePass.transaction do
        # Serialises two runs of one month: the second waits here, then finds
        # the first's snapshot and supersedes it. The partial unique index on
        # mso_snapshots is the backstop.
        @pass.lock!

        computation = compute(sanctuary_pass, reconciliation)
        snapshot = write_snapshot!(computation, collected)
        apply!(snapshot, computation)
        snapshot
      end
    end

    # Everything a run reads from the database, and the calculation. Writes
    # nothing and calls nothing outside the database.
    def compute(sanctuary_pass, reconciliation)
      roster = roster!
      refuse_other_trueups!(roster)
      benchmark = Mso::Benchmark.for_month(@month)
      existing = MsoTrueup.where(invoice_pass_id: @pass.id).order(:id).to_a
      earned = roster.to_h do |period, _ledger|
        [period.contributor_id,
         self.class.already_earned(contributor_id: period.contributor_id, month: @month, excluding: existing)]
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
      planned = roster.map do |period, ledger|
        Planned.new(period: period, ledger: ledger, earned_by_ledger: earned.fetch(period.contributor_id),
                    output: outputs.fetch(period.contributor_id))
      end

      Computation.new(sanctuary_pass: sanctuary_pass, reconciliation: reconciliation, benchmark: benchmark,
                      result: result, planned: planned, existing: existing)
    end

    # --- refusals -----------------------------------------------------------

    def assert_runnable!
      unless @pass.management_fee?
        raise Refused, "MSO compensation is run on #{Enterprise::GARDEN3D_NAME}'s pass; InvoicePass " \
                       "#{@pass.id} belongs to #{@pass.enterprise.name}."
      end
      if @pass.legacy_forecast_trackers?
        raise Refused, "#{@pass.invoice_month}'s pass holds a Forecast-driven tracker from before passes " \
                       "were per-company. MSO compensation is not run for that month."
      end
      start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START
      if @month < start
        raise Refused, "MSO compensation is run from #{start.strftime('%B %Y')} onward; " \
                       "#{@pass.invoice_month} is before that."
      end
      # garden3d's P&L for an unfinished month is whatever the last nightly
      # sync saw: a partial fee, and so a partial cap.
      if @today <= @month.end_of_month
        raise Refused, "#{@pass.invoice_month} has not ended. Its management fee income is still a " \
                       "partial figure; run it after the month closes."
      end
    end

    # Sanctuary's pass must exist, be complete and have payouts. NOT "every
    # payout accepted": one person who never clicks Accept would then freeze
    # every executive's pay. A payout that changes later is picked up by
    # running the month again, and a true-up is checked against a fresh
    # computation before its bill is created (MsoTrueup#sync_qbo_bill!).
    def sanctuary_pass!
      sanctuary = Enterprise.sanctuary
      pass = InvoicePass.find_by(enterprise_id: sanctuary.id, start_of_month: @month)
      if pass.nil?
        raise Refused, "#{sanctuary.name} has no invoice pass for #{@pass.invoice_month}, so there are no " \
                       "payouts to measure the benchmark or anyone's earnings from."
      end
      unless pass.complete?
        raise Refused, "#{sanctuary.name}'s pass for #{@pass.invoice_month} has not finished invoicing."
      end
      has_payouts = ContributorPayout.joins(:invoice_tracker)
        .where(invoice_trackers: { invoice_pass_id: pass.id }).exists?
      unless has_payouts
        raise Refused, "#{sanctuary.name}'s pass for #{@pass.invoice_month} has no contributor payouts yet. " \
                       "Run this after payouts have been calculated."
      end
      pass
    end

    # ONE call per run. It refreshes every attached fee invoice from
    # QuickBooks (a read each) and raises if any cannot be read.
    def fee_collected!
      Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
    rescue Mso::ManagementFeeInvoices::Error => e
      raise Refused, "#{e.message}. Nothing was written; try again."
    end

    # In a run this follows fee_collected!, so it compares against fresh
    # invoices. The fee income is read here, once, before anything is written.
    # There is no override: the message says exactly what was compared and
    # what to do about each cause.
    def reconcile!
      Mso::ManagementFeeIncome.reconcile!(@month)
    rescue Mso::ManagementFeeIncome::RowMissing => e
      raise Refused, "#{e.message} MSO compensation is not run for a month with no management fee income. " \
                     "If a fee was charged for #{@pass.invoice_month}, check that it posts to account 4100 " \
                     "in garden3d's QuickBooks; Stacks sees the change after the nightly sync."
    rescue Mso::ManagementFeeIncome::VarianceError => e
      raise Refused, "#{e.message}. Nothing was written. To clear this: (1) if a paying company's invoice " \
                     "is missing from the list above, attach it to that company's tracker on this pass; " \
                     "(2) if an invoice's Managerial Services figure is lower than its total and the " \
                     "difference is fee, Finance moves that line to the " \
                     "#{Mso::ManagementFeeInvoices::ITEM_NAME} item in QuickBooks; (3) if account 4100 " \
                     "holds income that is not a management fee, Finance moves it to another account, and " \
                     "Stacks sees that after the nightly sync; (4) if an invoice is dated in another month, " \
                     "Finance corrects the date. Then run again."
    rescue Mso::ManagementFeeIncome::Error => e
      raise Refused, "#{e.message}. Nothing was written."
    end

    # [[MsoRolePeriod, garden3d Ledger], ...], one pair per executive.
    def roster!
      periods = MsoRolePeriod.active_during(@month).order(:id).to_a
      self.class.assert_one_period_per_person!(periods)

      periods.map do |period|
        # find_by, not find_or_create: computing must not write. Every
        # contributor has a ledger per company (Ledger.ensure_all!).
        ledger = Ledger.find_by(enterprise_id: @pass.enterprise_id, contributor_id: period.contributor_id)
        if ledger.nil?
          raise Refused, "Contributor #{period.contributor_id} has no #{@pass.enterprise.name} ledger."
        end
        unless ledger.qbo_bound?
          # The Money page lists only QuickBooks-bound ledgers; a true-up on
          # any other would be invisible there and never paid.
          raise Refused, "Ledger #{ledger.id} (contributor #{period.contributor_id} on " \
                         "#{@pass.enterprise.name}) is not QuickBooks-bound, so a true-up on it could not " \
                         "be paid. Migrate the ledger, then run again."
        end
        [period, ledger]
      end
    end

    # A founder true-up (Trueup) for someone on the roster, in this month, is
    # the old arrangement paying for the same month. It is uncapped money on
    # another company's ledger, already billed in that company's QuickBooks by
    # the nightly sync. Netting against it would let it stand outside the cap,
    # so the run stops until a person has removed it.
    def refuse_other_trueups!(roster)
      contributor_ids = roster.map { |period, _ledger| period.contributor_id }
      rows = Trueup.joins(:ledger, :invoice_pass)
        .where(ledgers: { contributor_id: contributor_ids }, invoice_passes: { start_of_month: @month })
        .order("trueups.id").pluck("trueups.id", "ledgers.contributor_id", "trueups.ledger_id")
      return if rows.empty?

      detail = rows.map { |id, contributor_id, ledger_id| "Trueup #{id} (contributor #{contributor_id}, ledger #{ledger_id})" }
      raise Refused, "#{@pass.invoice_month} already has a founder true-up for someone on the MSO roster: " \
                     "#{detail.join('; ')}. The MSO true-up replaces it, so it has to go first. Open it from " \
                     "that ledger and delete it: that also deletes its QuickBooks bill, and is refused if " \
                     "the bill has any payment. If the bill has been paid, that month was paid the old way; " \
                     "void the payment in QuickBooks first, or end the role period so it starts the " \
                     "following month. Then run again."
    end

    # --- writing ------------------------------------------------------------

    # A true-up with a QuickBooks bill is never rewritten (see apply!). Where
    # this run's figure differs from what was billed, say so on the snapshot.
    def drift_for(computation)
      computed = computation.planned.to_h { |plan| [plan.ledger.id, plan.amount] }
      computation.existing.select(&:locked?).filter_map do |row|
        amount = computed.fetch(row.ledger_id, ZERO)
        next if amount == row.amount

        { "mso_trueup_id" => row.id, "ledger_id" => row.ledger_id,
          "billed_amount" => row.amount.to_s("F"), "computed_amount" => amount.to_s("F") }
      end
    end

    # What will actually be owed once this run is applied: a billed row keeps
    # its billed amount whatever was computed. If the fee fell after a bill
    # was written this can exceed the cap; the snapshot page warns when it does.
    def total_as_billed(computation)
      locked = computation.existing.select(&:locked?).index_by(&:ledger_id)
      on_roster = computation.planned.sum(ZERO) do |plan|
        locked.delete(plan.ledger.id)&.amount || plan.amount
      end
      on_roster + locked.values.sum(ZERO, &:amount)
    end

    # A WARNING, never a refusal: a month is run when it is run (August, in
    # October), and waiting for every company and every Accept would let one
    # person freeze every executive's pay. What is listed here is what could
    # still move the figures: netting is across all of a person's ledgers,
    # and only Sanctuary's pass is required to be complete. Ids and counts
    # only. The nightly drift check (.record_income_drift!) catches it if any
    # of it does move.
    def run_warnings(computation)
      incomplete = InvoicePass
        .where(start_of_month: @month, completed_at: nil)
        .where.not(enterprise_id: @pass.enterprise_id)
        .order(:id).pluck(:id, :enterprise_id)

      contributor_ids = computation.planned.map { |plan| plan.period.contributor_id }
      unaccepted = ContributorPayout.joins(:ledger, invoice_tracker: :invoice_pass)
        .where(ledgers: { contributor_id: contributor_ids }, invoice_passes: { start_of_month: @month })
        .where(accepted_at: nil)
        .order("contributor_payouts.id").pluck("ledgers.contributor_id", "contributor_payouts.id")
        .group_by(&:first)

      {
        "incomplete_passes" => incomplete.map do |id, enterprise_id|
          { "invoice_pass_id" => id, "enterprise_id" => enterprise_id }
        end,
        "unaccepted_payouts" => unaccepted.sort.map do |contributor_id, rows|
          { "contributor_id" => contributor_id, "count" => rows.size, "contributor_payout_ids" => rows.map(&:last) }
        end,
      }
    end

    def write_snapshot!(computation, collected)
      now = Time.current
      result = computation.result
      benchmark = computation.benchmark
      previous = MsoSnapshot.current.find_by(invoice_pass_id: @pass.id)
      # Before the insert: the partial unique index allows one current row.
      previous&.update_columns(superseded_at: now)

      # The column arrives in a later, hand-run migration than the table.
      warnings = MsoSnapshot.records_run_warnings? ? { run_warnings: run_warnings(computation) } : {}

      snapshot = MsoSnapshot.create!(
        **warnings,
        invoice_pass: @pass,
        sanctuary_invoice_pass: computation.sanctuary_pass,
        created_by: @run_by,
        fee_income: computation.reconciliation[:account_total],
        # to_s("F"), not to_s: the default is scientific notation ("0.2e5").
        benchmark_average: benchmark.average.to_s("F"),
        configured_n: benchmark.configured_n,
        counted: benchmark.counted,
        small_sample: benchmark.small_sample,
        cap_percentage: Mso::Compensation::DEFAULT_CAP_PERCENTAGE,
        cap: result.cap,
        total_calculated: result.total_calculated.to_s("F"),
        total_trueup: computation.planned.sum(ZERO, &:amount),
        total_trueup_as_billed: total_as_billed(computation),
        benchmark_members: amounts_json(benchmark.members),
        excluded_without_login: amounts_json(benchmark.excluded_without_login),
        lines: computation.planned.map { |plan| line_json(plan) },
        drift: drift_for(computation),
        reconciliation: reconciliation_json(computation.reconciliation),
        fee_collected_at: collected ? now : nil,
      )
      previous&.update_columns(superseded_by_id: snapshot.id)
      snapshot
    end

    def apply!(snapshot, computation)
      # Consumed below: what is left after the roster has been walked belongs
      # to people no longer on it.
      existing_by_ledger = computation.existing.index_by(&:ledger_id)
      computation.planned.each do |plan|
        row = existing_by_ledger.delete(plan.ledger.id)
        if plan.amount.positive?
          write_trueup!(snapshot, plan, row)
        elsif row
          remove!(snapshot, row)
        end
      end
      existing_by_ledger.each_value { |row| remove!(snapshot, row) }
    end

    def write_trueup!(snapshot, plan, row)
      amount = plan.amount
      pointers = { mso_snapshot_id: snapshot.id, mso_role_period_id: plan.period.id }

      # No live row: restore the newest soft-deleted one rather than insert,
      # so the row keeps its id.
      restoring = row.nil?
      row ||= MsoTrueup.with_deleted
        .where(ledger_id: plan.ledger.id, invoice_pass_id: @pass.id)
        .where.not(deleted_at: nil).order(:id).last

      if row
        # The same row lock MsoTrueup#toggle_acceptance! and #sync_qbo_bill!
        # take, and a reload under it. Without this an Accept clicked while
        # the run is writing could land on the new amount unseen, or a bill
        # could be created between our read and our write.
        row.lock!
        # A soft-deleted row is never "locked": its bill was detached when it
        # was removed, and a leftover qbo_bill_id must not make the restored
        # row payable at an amount nobody accepted. It is cleared below.
        if row.locked? && !restoring
          # Its amount is in QuickBooks and may have been paid. Point it at
          # the new snapshot and leave everything else alone.
          row.update_columns(pointers)
          return
        end
      else
        row = MsoTrueup.new(ledger: plan.ledger, invoice_pass: @pass)
      end

      changed = row.new_record? || row.deleted_at.present? || row.amount != amount
      # deleted_at is cleared BEFORE the save, as acts_as_paranoid's own
      # recover does: a row that still reads as deleted cannot be saved.
      row.assign_attributes(pointers.merge(amount: amount, description: description_for(plan), deleted_at: nil))
      row.qbo_bill_id = nil if restoring
      # They accepted a different number. Saved in the same statement as the
      # new amount, under the lock.
      row.accepted_at = nil if changed
      row.save!
    end

    def remove!(snapshot, row)
      row.lock!
      if row.locked?
        row.update_columns(mso_snapshot_id: snapshot.id)
      else
        # A soft delete (acts_as_paranoid). The row has no QuickBooks bill, so
        # its before_destroy has nothing to detach.
        raise "MsoTrueup #{row.id} could not be removed" unless row.destroy
      end
    end

    # After the transaction has rolled back. update_all: no callbacks, and the
    # figure-immutability validation is not in play.
    def invalidate_current!(reason)
      return unless MsoTrueup.schema_ready?

      MsoSnapshot.current.where(invoice_pass_id: @pass.id).update_all(
        invalidated_at: Time.current, invalidated_reason: reason.to_s.truncate(2000), fee_collected_at: nil,
      )
    end

    # --- what is stored -------------------------------------------------------

    def line_json(plan)
      period = plan.period
      output = plan.output
      {
        "mso_role_period_id" => period.id,
        "contributor_id" => period.contributor_id,
        "ledger_id" => plan.ledger.id,
        "tier" => period.tier,
        "title" => period.title,
        "multiplier" => period.tier_multiplier.to_s("F"),
        "started_at" => period.started_at.iso8601,
        "ended_at" => period.ended_at&.iso8601,
        "already_earned" => plan.already_earned.to_s("F"),
        "earned_by_ledger" => plan.earned_by_ledger.to_h { |ledger_id, amount| [ledger_id.to_s, amount.to_s("F")] },
        "calculated" => output.calculated.to_s("F"),
        "final" => output.final.to_s("F"),
        "reduction" => output.reduction.to_s("F"),
        # What is owed, in whole cents; and the figure it was rounded down from.
        "trueup" => plan.amount.to_s("F"),
        "trueup_before_rounding" => output.trueup.to_s("F"),
      }
    end

    def amounts_json(entries)
      entries.map { |entry| { "contributor_id" => entry[:contributor_id], "amount" => entry[:amount].to_s("F") } }
    end

    def reconciliation_json(reconciliation)
      {
        "account_total" => reconciliation[:account_total].to_s("F"),
        "payer_total" => reconciliation[:payer_total].to_s("F"),
        "variance" => reconciliation[:variance].to_s("F"),
        "invoices" => reconciliation[:invoices].map do |invoice|
          {
            "tracker_id" => invoice[:tracker_id],
            "qbo_id" => invoice[:qbo_id],
            "total" => invoice[:total].to_s("F"),
            "managerial_services" => invoice[:managerial_services].to_s("F"),
          }
        end,
      }
    end

    # Shown on the true-up's own page, which only its executive and admins
    # can open. No names: the page already says whose it is.
    def description_for(plan)
      period = plan.period
      role = "#{period.tier.titleize} (#{period.title}), #{period.tier_multiplier.to_s('F')}x"
      <<~MARKDOWN
        # MSO true-up for #{@month.strftime("%B %Y")}
        - **Role:** #{role}
        - **Calculated:** #{money(plan.output.calculated)}
        - **After the cap:** #{money(plan.output.final)}
        - **Already earned this month:** #{money(plan.already_earned)}
        - **True-up:** #{money(plan.amount)}
      MARKDOWN
    end

    def money(amount)
      ActionController::Base.helpers.number_to_currency(amount)
    end
  end
end
