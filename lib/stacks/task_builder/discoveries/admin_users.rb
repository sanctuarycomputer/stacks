module Stacks
  class TaskBuilder
    module Discoveries
      class AdminUsers < Base
        def tasks
          users = AdminUser.includes(:full_time_periods).not_ignored.to_a

          users.flat_map do |user|
            issues_for(user).map do |type|
              # missing_skill_tree is personal; no_full_time_periods_set is HR/ops.
              owners = (type == :missing_skill_tree) ? [user] : []
              task(subject: user, type: type, owners: owners)
            end
          end
        end

        private

        def issues_for(user)
          out = []
          out << :no_full_time_periods_set if user.full_time_periods.empty?
          # NOTE: :missing_survey_responses intentionally NOT emitted here.
          # The Surveys discovery emits per-survey :survey / :project_satisfaction_survey
          # tasks targeted at the specific person who hasn't responded — more actionable.
          if user.active? && [Enum::ContributorType::FOUR_DAY, Enum::ContributorType::FIVE_DAY].include?(user.current_contributor_type)
            out << :missing_skill_tree if user.skill_tree_level_without_salary == "No Reviews Yet"
          end
          out
        end
      end
    end
  end
end
