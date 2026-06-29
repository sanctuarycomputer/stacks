module Money
  # Single-pass aggregator for the Payable QBO Bills screen. Walks every
  # SyncsAsQboBill host row on qbo-enabled ledgers for the given account ONCE
  # and buckets each row as either payable (for the table) or unsettled
  # (count + sum only, for the summary card). Replaces the previous
  # PayableQboBills + UnsettledQboBillCandidates double-pass — payable? on
  # ContributorPayout/PayStub/ProfitShare is expensive (computed aggregates),
  # so iterating once instead of twice roughly halves render time.
  class QboBillSummary
    Stats = Struct.new(:payable_rows, :unsettled_total, :unsettled_count, keyword_init: true)

    # Per-class associations payable? needs — preloading these eliminates
    # the N+1 against InvoiceTracker / PeriodicReport / PayCycle when a
    # ledger has many CPs/PSs/PayStubs to evaluate.
    PRELOADS = {
      ContributorPayout => { invoice_tracker: :contributor_payouts },
      ProfitShare       => { periodic_report: :profit_shares },
      PayStub           => { pay_cycle: :pay_stubs },
      # NOTE: do NOT preload ContributorAdjustment.qbo_invoice. The belongs_to
      # uses primary_key: "qbo_id" without scoping by qbo_account_id, and AR's
      # preloader can match a same-qbo_id QboInvoice from a DIFFERENT account
      # (QBO realms allocate ids independently). HasQboInvoiceViaCompositeKey's
      # accessor would then return the wrong-account invoice from the in-memory
      # cache, potentially flipping payable? based on a different account's
      # invoice status. Pay the N+1 cost — correctness > speed.
    }.freeze

    def self.call(qbo_account:)
      payable_rows = []
      unsettled_total = 0.0
      unsettled_count = 0

      Money::PayableQboBills::HOST_KLASSES.each do |klass|
        relation = klass
          .joins(ledger: { enterprise: :qbo_account })
          .where(qbo_accounts: { id: qbo_account.id })
          .where("'qbo' = ANY(ledgers.payment_methods)")
          .includes(ledger: :contributor)
        relation = relation.includes(PRELOADS[klass]) if PRELOADS[klass]
        relation.find_each do |row|
          next if Ledger.audit_only_under_qbo_bound?(row)

          qb = row.try(:qbo_bill)
          # Paid bills drop from BOTH buckets — they're settled in QBO and
          # mustn't appear in either Total Payable or Total Unsettled.
          # Mirrors Ledger#qbo_bound_open_items (qbo_bill&.paid? → drop).
          next if qb&.paid?

          # Use qbo_bound_balance_amount so partial-paid bills contribute their
          # remaining_balance instead of the host's full amount — same rule as
          # Ledger#qbo_bound_contribution, so per-contributor and per-Money
          # totals agree on the same money.
          contribution = row.respond_to?(:qbo_bound_balance_amount) ? row.qbo_bound_balance_amount.to_f : row.amount.to_f

          if row.payable?
            payable_rows << Money::PayableQboBills::Row.new(
              host: row,
              ledger: row.ledger,
              contributor: row.ledger.contributor,
              qbo_bill: qb,
              amount: contribution,
            )
          else
            unsettled_total += contribution
            unsettled_count += 1
          end
        end
      end

      Stats.new(
        payable_rows: payable_rows.sort_by { |r| [r.contributor.id, r.host.class.name, r.host.id] },
        unsettled_total: unsettled_total.round(2),
        unsettled_count: unsettled_count,
      )
    end
  end
end
