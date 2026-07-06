class AddProjectSatisfactionSurveyRelationshipToProjectCapsule < ActiveRecord::Migration[6.0]
  def change
    add_column :project_capsules, :project_satisfaction_survey_status, :integer
  end
end
