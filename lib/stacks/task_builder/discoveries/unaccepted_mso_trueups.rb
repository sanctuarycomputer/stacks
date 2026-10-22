module Stacks
  class TaskBuilder
    module Discoveries
      # An MSO true-up is payable only once EVERY executive has accepted
      # theirs for the month, so one person not clicking Accept holds up
      # everyone. One task per executive, owned by them, linking to their
      # garden3d ledger. The task carries no amount.
      class UnacceptedMsoTrueups < Base
        def tasks
          # Migrations are run by hand after the deploy.
          return [] unless MsoTrueup.schema_ready?

          MsoTrueup.where(accepted_at: nil)
            .includes(ledger: { contributor: :forecast_person })
            .group_by { |trueup| trueup.ledger.contributor }
            .map do |contributor, trueups|
              task(
                subject: contributor,
                type: :unaccepted_mso_trueup,
                owners: [contributor.forecast_person&.admin_user],
                ledger: trueups.first.ledger,
              )
            end
        end
      end
    end
  end
end
