module Stacks
  class TaskBuilder
    module Discoveries
      # Surfaces every pending LedgerWithdrawalRequest as a task for global
      # Stacks admins (mirrors MissingQboVendors — the per-enterprise admins
      # don't have the QBO Bill Pay UI surfaced to them, so this lands on
      # the financial controller / super-admin cohort).
      class LedgerWithdrawalRequests < Base
        def tasks
          LedgerWithdrawalRequest
            .pending
            .includes(:ledger)
            .map do |req|
              task(
                subject: req,
                type: :ledger_withdrawal_request_needs_processing,
                owners: @admin_fallback,
              )
            end
        end
      end
    end
  end
end
