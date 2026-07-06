class CreateProjectSatisfactionSurveyFreeTextQuestionResponses < ActiveRecord::Migration[6.0]
  def change
    create_table :project_satisfaction_survey_free_text_question_responses do |t|
      t.references :project_satisfaction_survey_response, null: false, foreign_key: true, index: { name: 'idx_pssftqr_on_pssr_id' }
      t.references :project_satisfaction_survey_free_text_question, null: false, foreign_key: true, index: { name: 'idx_pssftqr_on_pssftq_id' }
      t.string :response
    end
  end
end
