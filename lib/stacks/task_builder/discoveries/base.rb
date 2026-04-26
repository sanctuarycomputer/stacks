module Stacks
  class TaskBuilder
    module Discoveries
      class Base
        def initialize(admin_fallback:)
          @admin_fallback = admin_fallback
        end

        def tasks
          raise NotImplementedError, "#{self.class.name} must implement #tasks"
        end

        protected

        # Build a StacksTask, falling back to the admin team when the natural-owner
        # rule produced no owners. Centralizes the always-has-an-owner invariant.
        def task(subject:, type:, owners:)
          owners = Array(owners).compact.uniq
          owners = @admin_fallback if owners.empty?
          StacksTask.new(type: type, subject: subject, owners: owners)
        end
      end
    end
  end
end
