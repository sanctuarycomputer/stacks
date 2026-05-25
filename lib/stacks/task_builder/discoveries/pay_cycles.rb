module Stacks
  class TaskBuilder
    module Discoveries
      # Nag enterprise admins to approve a PayCycle when their team has done its
      # part: all stubs in the cycle are accepted, but the cycle itself hasn't
      # been approved yet. Approval is the gate that flips stubs to payable
      # (see PayStub#payable? — accepted? && cycle all_accepted && approved?).
      class PayCycles < Base
        def tasks
          PayCycle
            .includes(:pay_stubs, enterprise: { enterprise_admins: :admin_user })
            .where(approved_at: nil)
            .select { |cycle| cycle.pay_stubs.exists? }
            .map do |cycle|
              task(
                subject: cycle,
                type: :pay_cycle_needs_approval,
                owners: cycle.enterprise.admin_users.to_a,
              )
            end
        end
      end
    end
  end
end
