class CreateProjectedAssignments < ActiveRecord::Migration[6.1]
  def change
    create_table :projected_assignments do |t|
      t.string :source_key, null: false
      t.references :project_tracker, null: true, foreign_key: true
      t.bigint :runn_person_id, null: false
      t.bigint :runn_role_id
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :minutes_per_day, null: false, default: 0
      t.string :kind, null: false, default: "work"
      t.integer :capacity_pct
      t.boolean :is_placeholder, null: false, default: false
      t.text :note
      t.string :source_ref
      t.jsonb :runn_assignment_ids, null: false, default: []
      t.jsonb :last_synced_runn_state
      t.string :managed_by
      t.timestamps
    end
    add_index :projected_assignments, :source_key, unique: true
    add_index :projected_assignments, :runn_person_id
  end
end
