class CreateProjectCapsules < ActiveRecord::Migration[6.0]
  def change
    create_table :project_capsules do |t|
      t.references :project_tracker, index: true, foreign_key: true, null: false
      t.text :postpartum_notes
      t.integer :client_feedback_survey_status
      t.string :client_feedback_survey_url
      t.integer :internal_marketing_status
      t.integer :capsule_status

      t.timestamps
    end
  end
end
