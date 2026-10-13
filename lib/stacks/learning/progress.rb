module Stacks
  module Learning
    # The only writer of derived progress. Idempotent and additive: it never
    # removes a completion or a grant.
    class Progress
      # When an admin's step lands close to (or after) the due date, the person
      # gets at least this long to finish what it unblocked.
      ADMIN_DELAY_GRACE_DAYS = 3

      # Called whenever a step only an admin could complete gets completed. An
      # admin's delay must never make the person overdue, so if what it unblocks
      # (a quiz, later steps) would otherwise open already past due, push the
      # due date out.
      def self.allow_for_admin_delay!(assignment, today: Date.today)
        earliest = today + ADMIN_DELAY_GRACE_DAYS
        return unless assignment.outstanding? && assignment.due_on < earliest
        assignment.update!(due_on: earliest)
      end

      def self.refresh!(admin_user, context: nil)
        context ||= AutoChecks::Context.new
        first_error = nil
        admin_user.course_assignments.outstanding.includes(:course).each do |assignment|
          refresh_assignment!(admin_user, assignment, context)
        rescue => e
          Rails.logger.error("Stacks::Learning::Progress.refresh! failed for CourseAssignment##{assignment.id}: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) if defined?(Sentry)
          first_error ||= e
        end
        raise first_error if first_error
      end

      def self.refresh_assignment!(admin_user, assignment, context)
        complete_auto_checks(assignment, admin_user, context)

        checklist = Checklist.new(assignment)
        checklist.modules.each do |state|
          next unless state.done?
          if state.completion.nil?
            ensure_row(ModuleCompletion, admin_user_id: admin_user.id, learning_module_id: state.learning_module.id) do |row|
              row.completed_at = Time.current
            end
          end
          # Granted even when the completion row already existed, so a grant
          # that failed last time self-heals.
          grant(admin_user, state.learning_module.qualification)
        end

        return unless checklist.all_done?
        ActiveRecord::Base.transaction(requires_new: true) do
          assignment.update!(completed_at: Time.current)
          grant(admin_user, assignment.course.qualification)
        end
      end
      private_class_method :refresh_assignment!

      def self.refresh_all!
        context = AutoChecks::Context.new
        AdminUser.where(id: CourseAssignment.outstanding.select(:admin_user_id)).find_each do |admin_user|
          refresh!(admin_user, context: context)
        rescue => e
          Rails.logger.error("Stacks::Learning::Progress.refresh! failed for AdminUser##{admin_user.id}: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) if defined?(Sentry)
        end
      end

      def self.complete_auto_checks(assignment, admin_user, context)
        Checklist.new(assignment).modules.each do |state|
          state.steps.each do |step_state|
            step = step_state.step
            next if step_state.done? || step.kind != "auto_check"
            next unless AutoChecks.passed?(step.auto_check_key, admin_user, context)
            ensure_row(StepCompletion, admin_user_id: admin_user.id, module_step_id: step.id) do |row|
              row.completed_at = Time.current
              row.source = "auto"
            end
            allow_for_admin_delay!(assignment) if AutoChecks.owner(step.auto_check_key) == :admin
          end
        end
      end
      private_class_method :complete_auto_checks

      def self.grant(admin_user, qualification)
        return if qualification.nil?
        ensure_row(QualificationGrant, admin_user_id: admin_user.id, qualification_id: qualification.id) do |row|
          row.granted_at = Time.current
        end
      end
      private_class_method :grant

      # find_or_create_by! that tolerates a concurrent insert of the same row.
      def self.ensure_row(klass, attrs, &block)
        klass.find_or_create_by!(attrs, &block)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        klass.find_by(attrs) || raise(e)
      end
      private_class_method :ensure_row
    end
  end
end
