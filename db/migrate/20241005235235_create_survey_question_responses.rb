class CreateSurveyQuestionResponses < ActiveRecord::Migration[6.0]
  def change
    create_table :survey_question_responses do |t|
      t.references :survey_response, null: false, foreign_key: true
      t.references :survey_question, null: false, foreign_key: true
      t.integer :sentiment, default: 0
      t.string :context
    end
  end
end
