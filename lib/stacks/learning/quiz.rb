module Stacks
  module Learning
    # Takes one "quick check" submission. People get Checklist::BASE_ATTEMPTS
    # attempts plus one per QuizRetryGrant, so they read the material rather
    # than guess their way through.
    class Quiz
      Result = Struct.new(:status, :attempt, :message, :attempts_left, keyword_init: true)

      def self.submit!(assignment:, learning_module:, answers:)
        user = assignment.admin_user
        result = nil

        # Row lock on the person: two simultaneous submissions queue up, so the
        # attempt count read below cannot be stale.
        AdminUser.transaction do
          user.lock!
          state = assignment.outstanding? ? Checklist.new(assignment).module_state(learning_module) : nil

          if state.nil? || state.quiz_state != :open
            result = rejected(message_for_closed(state), state)
            next
          end

          questions = state.learning_module.quiz_questions.to_a
          chosen = parse(answers, questions)
          if chosen.nil?
            result = rejected("Answer every question before submitting. This didn't use up an attempt.", state)
            next
          end

          correct = questions.count { |q| chosen[q.id] == q.correct_index }
          passed = correct * 100 >= state.learning_module.quiz_pass_percent * questions.size
          attempt = QuizAttempt.create!(
            admin_user: user, learning_module: state.learning_module,
            answers: chosen.transform_keys(&:to_s), correct_count: correct,
            question_count: questions.size, passed: passed,
          )
          left = passed ? 0 : state.attempts_left - 1
          result = Result.new(
            status: passed ? :passed : :failed, attempt: attempt, attempts_left: left,
            message: passed ? "Passed: #{correct} of #{questions.size}." : failed_message(correct, questions.size, state.learning_module, left),
          )
        end

        Progress.refresh!(user) if result.status == :passed
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

      def self.pass_count(learning_module, total)
        (learning_module.quiz_pass_percent * total / 100.0).ceil
      end
      private_class_method :pass_count

      def self.failed_message(correct, total, learning_module, left)
        need = pass_count(learning_module, total)
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
        Result.new(status: :rejected, attempt: nil, message: message, attempts_left: state&.attempts_left.to_i)
      end
      private_class_method :rejected
    end
  end
end
