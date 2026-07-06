module Stacks
  class TaskBuilder
    module Discoveries
      class Surveys < Base
        def tasks
          studio_wide + project_satisfaction
        end

        private

        # Studio-wide Surveys. One task per open survey, owners = expected
        # responders who haven't filed a SurveyResponder yet.
        def studio_wide
          Survey.open.flat_map do |s|
            responded = SurveyResponder.where(survey: s).map(&:admin_user)
            owed = (s.expected_responders - responded).uniq
            next [] if owed.empty?
            # Personal task by construction — the owners ARE the people who owe
            # responses. We bypass the admin-fallback because if owed is empty
            # we skip the task entirely.
            [StacksTask.new(type: :survey, subject: s, owners: owed)]
          end
        end

        # Project-satisfaction surveys (per-project). Same shape: one task per
        # open survey, owners = expected_responders who haven't responded.
        def project_satisfaction
          ProjectSatisfactionSurvey.open.flat_map do |pss|
            responded = ProjectSatisfactionSurveyResponder
              .where(project_satisfaction_survey: pss)
              .map(&:admin_user)
            owed = (pss.expected_responders.keys - responded).uniq
            next [] if owed.empty?
            [StacksTask.new(type: :project_satisfaction_survey, subject: pss, owners: owed)]
          end
        end
      end
    end
  end
end
