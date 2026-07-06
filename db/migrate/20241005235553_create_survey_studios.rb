class CreateSurveyStudios < ActiveRecord::Migration[6.0]
  def change
    create_table :survey_studios do |t|
      t.references :survey, null: false, foreign_key: true
      t.references :studio, null: false, foreign_key: true
      t.timestamps
    end
  end
end
