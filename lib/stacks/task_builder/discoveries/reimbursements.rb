module Stacks
  class TaskBuilder
    module Discoveries
      class Reimbursements < Base
        def tasks
          Reimbursement.pending.map do |r|
            # No clear individual approver — falls back to admins.
            task(subject: r, type: :pending_acceptance, owners: [])
          end
        end
      end
    end
  end
end
