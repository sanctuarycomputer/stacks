module Stacks
  class TaskBuilder
    module Discoveries
      # Surfaces every legacy ledger that has at least one payable host row
      # AND whose enterprise has a connected QBO account. Each emits a
      # :legacy_ledger_needs_qbo_migration task routed to the admin fallback.
      class LegacyLedgersPendingQboMigration < Base
        PAYABLE_TABLES = %w[
          contributor_payouts
          contributor_adjustments
          profit_shares
          pay_stubs
          trueups
          reimbursements
        ].freeze

        def tasks
          ledgers = Ledger
            .where(mode: :legacy)
            .joins(:enterprise)
            .where(enterprises: { id: Enterprise.joins(:qbo_account).select(:id) })
            .where("EXISTS (#{any_payable_subquery})")
            .includes(:contributor, enterprise: :qbo_account)
            .to_a

          ledgers.map do |ledger|
            task(
              subject: ledger,
              type: :legacy_ledger_needs_qbo_migration,
              owners: @admin_fallback,
            )
          end
        end

        private

        def any_payable_subquery
          # Every PAYABLE_TABLES model is acts_as_paranoid, so the raw SQL has
          # to filter deleted_at IS NULL — otherwise a ledger whose only payable
          # rows are soft-deleted still surfaces a migration task that the
          # readiness check then declares trivial (visible_items is empty),
          # spamming the Tasks dashboard.
          PAYABLE_TABLES.map do |t|
            "SELECT 1 FROM #{t} WHERE #{t}.ledger_id = ledgers.id AND #{t}.deleted_at IS NULL"
          end.join(" UNION ALL ")
        end
      end
    end
  end
end
