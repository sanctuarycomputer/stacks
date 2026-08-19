class CreateWeeklyShips < ActiveRecord::Migration[6.1]
  def change
    create_table :weekly_ships do |t|
      t.references :document, null: false, foreign_key: true
      t.references :project_tracker, null: false, foreign_key: true
      t.datetime :sent_at, null: false
      t.string :sent_by_email
      t.string :sent_by_name
      t.integer :matched_by, null: false
      t.float :confidence
      t.text :rationale
      t.timestamps
    end
    add_index :weekly_ships, [:document_id, :project_tracker_id], unique: true
    add_index :weekly_ships, [:project_tracker_id, :sent_at]
  end
end
