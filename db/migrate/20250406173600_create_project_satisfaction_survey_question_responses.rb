class CreateProjectSatisfactionSurveyQuestionResponses < ActiveRecord::Migration[6.0]
  def change
    create_table :project_satisfaction_survey_question_responses do |t|
      t.references :project_satisfaction_survey_response, null: false, foreign_key: true, index: { name: 'idx_pssqr_on_pssr_id' }
      t.references :project_satisfaction_survey_question, null: false, foreign_key: true, index: { name: 'idx_pssqr_on_pssq_id' }
      t.integer :sentiment, default: 0
      t.string :context
    end
  end
end
