module Stacks
  module Learning
    # Read-only picture of one CourseAssignment for its person: which steps are
    # done, each module's quiz state, and which admin sign-offs are ready.
    # Loads everything in a handful of queries; build a new one after writing.
    class Checklist
      BASE_ATTEMPTS = 2

      StepState = Struct.new(:step, :completion, :ready, keyword_init: true) do
        def done?
          completion.present?
        end
      end

      class ModuleState
        attr_reader :learning_module, :steps, :attempts, :attempts_allowed, :completion

        def initialize(learning_module:, steps:, attempts:, attempts_allowed:, completion:)
          @learning_module = learning_module
          @steps = steps
          @attempts = attempts
          @attempts_allowed = attempts_allowed
          @completion = completion
        end

        def steps_done?
          steps.all?(&:done?)
        end

        def has_quiz?
          learning_module.quiz_questions.any?
        end

        def passed?
          attempts.any?(&:passed)
        end

        def attempts_left
          [attempts_allowed - attempts.size, 0].max
        end

        def quiz_state
          return :none unless has_quiz?
          return :passed if passed? || completion.present?
          return :not_open unless steps_done?
          attempts_left.zero? ? :locked : :open
        end

        # Sticky: a ModuleCompletion row keeps a module done even if steps or
        # questions are added to it later.
        def done?
          completion.present? || (steps_done? && (!has_quiz? || passed?))
        end
      end

      attr_reader :assignment, :modules

      def initialize(assignment)
        @assignment = assignment
        @modules = build
      end

      def module_state(learning_module)
        id = learning_module.respond_to?(:id) ? learning_module.id : learning_module.to_s.to_i
        modules.find { |m| m.learning_module.id == id }
      end

      def step_state(step)
        id = step.respond_to?(:id) ? step.id : step.to_s.to_i
        modules.each do |m|
          found = m.steps.find { |s| s.step.id == id }
          return found if found
        end
        nil
      end

      def all_done?
        modules.any? && modules.all?(&:done?)
      end

      # True when the person still has something only they can do. Admin
      # sign-offs and quizzes locked pending an admin's retry grant are not theirs.
      def own_work_remaining?
        modules.any? do |m|
          next false if m.done?
          m.steps.any? { |s| !s.done? && s.step.kind != "admin_sign_off" } || m.quiz_state == :open
        end
      end

      def ready_sign_off_steps
        modules.flat_map { |m| m.steps.select(&:ready).map(&:step) }
      end

      def steps_total
        modules.sum { |m| m.steps.size }
      end

      def steps_done
        modules.sum { |m| m.steps.count(&:done?) }
      end

      private

      def build
        user_id = assignment.admin_user_id
        learning_modules = assignment.course.course_modules
          .includes(learning_module: [:module_steps, :quiz_questions])
          .map(&:learning_module)
        module_ids = learning_modules.map(&:id)
        step_ids = learning_modules.flat_map { |m| m.module_steps.map(&:id) }

        completions = StepCompletion.where(admin_user_id: user_id, module_step_id: step_ids)
          .includes(:completed_by).index_by(&:module_step_id)
        attempts = QuizAttempt.where(admin_user_id: user_id, learning_module_id: module_ids)
          .order(:created_at, :id).group_by(&:learning_module_id)
        retry_grants = QuizRetryGrant.where(admin_user_id: user_id, learning_module_id: module_ids)
          .group(:learning_module_id).count
        module_completions = ModuleCompletion.where(admin_user_id: user_id, learning_module_id: module_ids)
          .index_by(&:learning_module_id)

        earlier_modules_done = true
        learning_modules.map do |mod|
          earlier_steps_done = true
          steps = mod.module_steps.map do |step|
            completion = completions[step.id]
            # A step added to a module the person already finished is never
            # "ready": the module stays done, so nobody is asked to sign it.
            ready = step.kind == "admin_sign_off" && completion.nil? && module_completions[mod.id].nil? &&
              earlier_modules_done && earlier_steps_done
            earlier_steps_done &&= completion.present?
            StepState.new(step: step, completion: completion, ready: ready)
          end
          state = ModuleState.new(
            learning_module: mod,
            steps: steps,
            attempts: attempts[mod.id] || [],
            attempts_allowed: BASE_ATTEMPTS + retry_grants[mod.id].to_i,
            completion: module_completions[mod.id],
          )
          earlier_modules_done &&= state.done?
          state
        end
      end
    end
  end
end
