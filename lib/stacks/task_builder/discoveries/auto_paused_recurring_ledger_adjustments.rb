module Stacks
  class TaskBuilder
    module Discoveries
      # Surfaces RecurringLedgerAdjustments that were auto-paused by
      # `RecurringLedgerAdjustment#materialize!` when their ledger became
      # qbo_bound and their amount was negative — every materialization would
      # otherwise have landed an audit-only CA that never deducts. The auto-
      # pause prevents silent over-payment, but the operator needs to see it
      # in their Tasks dashboard so they can either re-design the recurring
      # (e.g. as a QBO bill credit) or formally retire it.
      class AutoPausedRecurringLedgerAdjustments < Base
        def tasks
          rows = RecurringLedgerAdjustment
            .joins(:ledger)
            .where.not(paused_at: nil)
            .where(ledgers: { mode: Ledger.modes[:qbo_bound] })
            .where("amount < 0")
            .includes(ledger: [:contributor, :enterprise])
            .to_a

          rows.map do |recurring|
            task(
              subject: recurring,
              type: :auto_paused_recurring_on_qbo_bound,
              owners: @admin_fallback,
            )
          end
        end
      end
    end
  end
end
