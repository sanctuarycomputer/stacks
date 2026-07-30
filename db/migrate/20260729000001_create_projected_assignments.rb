class CreateProjectedAssignments < ActiveRecord::Migration[6.1]
  def change
    create_table :projected_assignments do |t|
      t.string :source_key, null: false
      t.references :contributor, null: false, foreign_key: true
      t.references :project_tracker, null: false, foreign_key: true
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :minutes_per_day, null: false, default: 0
      t.bigint :runn_assignment_id            # the 1:1 mirror; null until created in Runn
      t.jsonb :last_synced_runn_state         # CAS baseline for THIS assignment
      t.text :note
      t.string :source_ref
      t.string :managed_by
      t.timestamps
    end
    add_index :projected_assignments, :source_key, unique: true
    add_index :projected_assignments, :runn_assignment_id
  end
end
