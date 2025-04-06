class CreateProjectSatisfactionSurveys < ActiveRecord::Migration[6.0]
  def change
    create_table :project_satisfaction_surveys do |t|
      t.references :project_capsule, null: false, foreign_key: true
      t.string :title, null: false
      t.text :description, null: false
      t.datetime :closed_at
      t.timestamps
    end
  end
end
