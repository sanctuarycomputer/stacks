class AddDefaultProjectSatisfactionSurveyTemplate < ActiveRecord::Migration[6.0]
  def up
    # Adding a comment to indicate this is a seed migration
    execute <<-SQL
      COMMENT ON TABLE project_satisfaction_survey_questions IS 'Table for project satisfaction survey questions';
    SQL

    # Add code to handle existing project capsules
    ProjectCapsule.where(project_satisfaction_survey_status: nil).update_all(project_satisfaction_survey_status: :opt_out_of_project_satisfaction_survey)
  end

  def down
    # No need to remove anything, as this is just adding data
  end
end
