class CreateProjectSatisfactionSurveyResponses < ActiveRecord::Migration[6.0]
  def change
    create_table :project_satisfaction_survey_responses do |t|
      t.references :project_satisfaction_survey, null: false, foreign_key: true, index: { name: 'idx_pssr_on_pss_id' }
      t.timestamps
    end
  end
end
