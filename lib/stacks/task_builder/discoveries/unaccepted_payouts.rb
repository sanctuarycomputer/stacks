module Stacks
  class TaskBuilder
    module Discoveries
      class UnacceptedPayouts < Base
        def tasks
          ContributorPayout.where(accepted_at: nil)
            .includes(ledger: { contributor: :forecast_person })
            .group_by { |payout| payout.ledger.contributor }
            .map do |contributor, payouts|
              task(
                subject: contributor,
                type: :unaccepted_payouts,
                owners: [contributor.forecast_person.admin_user],
                ledger: payouts.first.ledger,
              )
            end
        end
      end
    end
  end
end
