class CreateSurveyFreeTextQuestionResponses < ActiveRecord::Migration[6.0]
  def change
    create_table :survey_free_text_question_responses do |t|
      t.references :survey_response, null: false, foreign_key: true
      t.references :survey_free_text_question, null: false, foreign_key: true, index: { name: 'idx_sftqr_on_sftq_id' }
      t.string :response
    end
  end
end
