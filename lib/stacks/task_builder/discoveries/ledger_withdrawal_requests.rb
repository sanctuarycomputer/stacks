module Stacks
  class TaskBuilder
    module Discoveries
      # Surfaces ONE aggregate task for global Stacks admins whenever
      # there's at least one pending LedgerWithdrawalRequest in the
      # queue — clicking it lands them on the pending scope of the
      # index, not on a specific request. The subject is the oldest
      # pending row so the cache descriptor is stable as long as any
      # row remains pending; the display name + URL on StacksTask
      # treat the request as an indicator for the whole queue.
      class LedgerWithdrawalRequests < Base
        def tasks
          oldest_pending = LedgerWithdrawalRequest
            .pending
            .order(:requested_at)
            .first
          return [] if oldest_pending.nil?

          [
            task(
              subject: oldest_pending,
              type: :ledger_withdrawal_request_needs_processing,
              owners: @admin_fallback,
            ),
          ]
        end
      end
    end
  end
end
