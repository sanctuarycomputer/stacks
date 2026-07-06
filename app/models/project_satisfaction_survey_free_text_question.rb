class ProjectSatisfactionSurveyFreeTextQuestion < ApplicationRecord
  belongs_to :project_satisfaction_survey

  def name
    prompt
  end
end