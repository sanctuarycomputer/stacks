module Stacks
  class TaskBuilder
    module Discoveries
      # Surfaces ledgers where the contributor has been paid (via any of the
      # SyncsAsQboBill host types) but has no ContributorQboVendor mapping
      # for the ledger's enterprise QBO account. Without that mapping
      # SyncsAsQboBill#sync_qbo_bill! short-circuits and the bill silently
      # doesn't push to QuickBooks. Enterprise admins own these.
      class MissingQboVendors < Base
        # Tables on the contributor side that mean "this person was paid
        # against this ledger" — drives which ledgers we check.
        PAYABLE_TABLES = %w[
          contributor_payouts
          contributor_adjustments
          profit_shares
          pay_stubs
        ].freeze

        def tasks
          ledgers = Ledger
            .includes(:contributor, enterprise: [:qbo_account, { enterprise_admins: :admin_user }])
            .where("EXISTS (#{any_payable_subquery})")
            .to_a

          ledgers.filter_map do |ledger|
            qa = ledger.enterprise.qbo_account
            next nil if qa.nil? # no connected QBO → nothing to map
            next nil if ledger.contributor.qbo_vendor_for(qa).present?

            task(
              subject: ledger,
              type: :missing_qbo_vendor_for_contributor,
              owners: ledger.enterprise.admin_users.to_a,
            )
          end
        end

        private

        # Single EXISTS subquery so we only touch ledgers that actually have
        # at least one payable row attached (avoids checking every empty
        # ledger across the org).
        def any_payable_subquery
          PAYABLE_TABLES.map do |t|
            "SELECT 1 FROM #{t} WHERE #{t}.ledger_id = ledgers.id"
          end.join(" UNION ALL ")
        end
      end
    end
  end
end
