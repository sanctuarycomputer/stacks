class CreateProjectSatisfactionSurveyResponders < ActiveRecord::Migration[6.0]
  def change
    create_table :project_satisfaction_survey_responders do |t|
      t.references :project_satisfaction_survey, null: false, foreign_key: true, index: { name: 'idx_pssr_on_ps_survey_id' }
      t.references :admin_user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :project_satisfaction_survey_responders,
      [:project_satisfaction_survey_id, :admin_user_id],
      unique: true,
      name: 'idx_ps_survey_responders_on_survey_id_and_admin_user_id'
  end
end
