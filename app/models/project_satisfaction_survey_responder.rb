class ProjectSatisfactionSurveyResponder < ApplicationRecord
  belongs_to :project_satisfaction_survey
  belongs_to :admin_user
end