class AddDefaultProjectSatisfactionSurveyTemplate < ActiveRecord::Migration[6.0]
  def up
    # Adding a comment to indicate this is a seed migration
    execute <<-SQL
      COMMENT ON TABLE project_satisfaction_survey_questions IS 'Table for project satisfaction survey questions';
    SQL

    # Only add opt_out status to project capsules that are older than 6 months
    six_months_ago = Date.today - 6.months

    # Find project capsules with nil project_satisfaction_survey_status and created more than 6 months ago
    ProjectCapsule.where(project_satisfaction_survey_status: nil)
                 .where('created_at < ?', six_months_ago)
                 .update_all(project_satisfaction_survey_status: :opt_out_of_project_satisfaction_survey)
  end

  def down
    # No need to remove anything, as this is just adding data
  end
end
