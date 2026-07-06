class CreateProjectSatisfactionSurveyFreeTextQuestions < ActiveRecord::Migration[6.0]
  def change
    create_table :project_satisfaction_survey_free_text_questions do |t|
      t.references :project_satisfaction_survey, null: false, foreign_key: true, index: { name: 'idx_pssftq_on_pss_id' }
      t.string :prompt, null: false
      t.timestamps
    end
  end
end
