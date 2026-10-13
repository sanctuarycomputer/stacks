module Stacks
  module Learning
    # Takes one "quick check" submission. People get Checklist::BASE_ATTEMPTS
    # attempts plus one per QuizRetryGrant, so they read the material rather
    # than guess their way through.
    class Quiz
      Result = Struct.new(:status, :attempt, :message, :attempts_left, keyword_init: true)

      STALE_MESSAGE = "These questions were just updated. Please answer them again.".freeze

      # Identifies the exact questions (and their answer key) a form was built
      # from, so an edit between load and submit can't be scored against.
      def self.fingerprint(learning_module)
        parts = learning_module.quiz_questions.map { |q| [q.id, q.prompt, q.choices, q.correct_index] }
        Digest::SHA256.hexdigest(parts.to_json)
      end

      # fingerprint: nil skips the check (internal callers); a given value,
      # including a blank string, must match the current questions.
      def self.submit!(assignment:, learning_module:, answers:, fingerprint: nil)
        user = assignment.admin_user
        result = nil

        # Row lock on the person: two simultaneous submissions queue up, so the
        # attempt count read below cannot be stale.
        AdminUser.transaction do
          user.lock!
          # Re-read under the lock so a waive or completion committed just
          # before is honoured.
          assignment.reload
          state = assignment.outstanding? ? Checklist.new(assignment).module_state(learning_module) : nil

          if state.nil? || state.quiz_state != :open
            result = rejected(message_for_closed(state), state)
            next
          end

          questions = state.learning_module.quiz_questions.to_a
          if !fingerprint.nil? && fingerprint.to_s != self.fingerprint(state.learning_module)
            result = rejected(STALE_MESSAGE, state)
            next
          end

          chosen = parse(answers, questions)
          if chosen.nil?
            result = rejected("Answer every question before submitting. This didn't use up an attempt.", state)
            next
          end

          correct = questions.count { |q| chosen[q.id] == q.correct_index }
          needed = needed_count(state.learning_module, questions.size)
          passed = correct >= needed
          attempt = QuizAttempt.create!(
            admin_user: user, learning_module: state.learning_module,
            answers: chosen.transform_keys(&:to_s), correct_count: correct,
            question_count: questions.size, passed: passed,
          )
          left = passed ? 0 : state.attempts_left - 1
          result = Result.new(
            status: passed ? :passed : :failed, attempt: attempt, attempts_left: left,
            message: passed ? "Passed: #{correct} of #{questions.size}." : failed_message(correct, questions.size, needed, left),
          )
        end

        if result.status == :passed
          # The pass is already recorded; a failed refresh must not turn it into
          # an error for the person (the daily refresh picks it up).
          begin
            Progress.refresh!(user)
          rescue StandardError => e
            Rails.logger.error("Stacks::Learning::Quiz refresh failed for AdminUser##{user.id}: #{e.class}: #{e.message}")
            Sentry.capture_exception(e) if defined?(Sentry)
          end
        end
        result
      end

      # question id (Integer) => chosen index (Integer), or nil unless every
      # question has an in-range integer answer.
      def self.parse(answers, questions)
        return nil unless answers.respond_to?(:key?)
        chosen = {}
        questions.each do |q|
          raw = answers[q.id.to_s] || answers[q.id]
          return nil unless raw.to_s.match?(/\A\d{1,2}\z/)
          index = raw.to_s.to_i
          return nil unless index.between?(0, q.choices.size - 1)
          chosen[q.id] = index
        end
        chosen
      end
      private_class_method :parse

      # Smallest correct count that meets the pass mark (integer ceiling).
      # Public: the form shows the same number.
      def self.needed_count(learning_module, total)
        (learning_module.quiz_pass_percent * total + 99) / 100
      end

      def self.failed_message(correct, total, need, left)
        tail = left.positive? ? "You have #{left} #{"attempt".pluralize(left)} left, so re-read the pages first." : "You're out of attempts. Ask an admin to allow another."
        "You got #{correct} of #{total}; you need #{need}. #{tail}"
      end
      private_class_method :failed_message

      def self.message_for_closed(state)
        return "This quick check isn't part of your checklist." if state.nil?
        case state.quiz_state
        when :passed then "You've already passed this quick check."
        when :locked then "You're out of attempts. Ask an admin to allow another."
        when :not_open then "Finish the steps above before the quick check."
        else "There is no quick check here."
        end
      end
      private_class_method :message_for_closed

      def self.rejected(message, state)
        Result.new(status: :rejected, attempt: nil, message: message, attempts_left: state ? state.attempts_left.to_i : 0)
      end
      private_class_method :rejected
    end
  end
end
