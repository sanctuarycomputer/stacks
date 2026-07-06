class CreateSurveyResponders < ActiveRecord::Migration[6.0]
  def change
    create_table :survey_responders do |t|
      t.references :survey, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :survey_responders,
      [:survey_id, :admin_user_id],
      unique: true,
      name: 'idx_survey_responders_on_survey_id_and_admin_user_id'
  end
end
