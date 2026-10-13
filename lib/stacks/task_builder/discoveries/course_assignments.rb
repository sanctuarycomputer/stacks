module Stacks
  class TaskBuilder
    module Discoveries
      # Two tasks per outstanding CourseAssignment:
      #   overdue  — owned by the person, once past due_on and only while they
      #              still have something of their own to do. An admin's delay
      #              (a sign-off, a quiz retry grant) never makes someone overdue,
      #              because the pending-task pill on payables holds their payout.
      #   sign-off — owned by every admin except the assignee, while a sign-off
      #              step is ready, or once past due while an admin-owned
      #              auto-check (payment profile) is still outstanding.
      class CourseAssignments < Base
        OVERDUE = :course_assignment_overdue
        SIGN_OFF = :course_assignment_needs_admin_sign_off

        def tasks
          CourseAssignment.outstanding.includes(:course, admin_user: :full_time_periods).flat_map do |assignment|
            self.class.task_types_for(assignment).filter_map do |type|
              owners = type == OVERDUE ? [assignment.admin_user] : @admin_fallback.reject { |a| a.id == assignment.admin_user_id }
              # Not Base#task: its empty-owner fallback would hand an admin the
              # sign-off on their own checklist.
              next nil if owners.empty?
              StacksTask.new(type: type, subject: assignment, owners: owners)
            end
          end
        end

        def self.task_types_for(assignment, today: Date.today)
          return [] unless assignment.outstanding? && eligible?(assignment.admin_user, today)

          checklist = Stacks::Learning::Checklist.new(assignment)
          types = []
          types << OVERDUE if checklist.overdue?(today)
          # Past due and only an admin can unblock it (link a payment profile,
          # allow another quiz attempt): the admins get the task, the person
          # never does.
          types << SIGN_OFF if checklist.ready_sign_off_steps.any? || checklist.waiting_on_admin?(today)
          types
        end

        # Used by TaskBuilder to re-validate cached descriptors on every read.
        def self.live_types_by_id(ids)
          CourseAssignment.where(id: ids).includes(:course, admin_user: :full_time_periods)
            .to_h { |assignment| [assignment.id, task_types_for(assignment)] }
        end

        # Not ignored, and not departed. AdminUser.active alone would exclude
        # every brand-new account (no full-time period yet), which is exactly
        # who this is for.
        def self.eligible?(admin_user, today)
          return false if admin_user.nil? || admin_user.ignore?
          periods = admin_user.full_time_periods
          periods.empty? || periods.any? { |p| p.started_at <= today && (p.ended_at.nil? || p.ended_at >= today) }
        end
      end
    end
  end
end
