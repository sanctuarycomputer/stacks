class CreateRunnAssignments < ActiveRecord::Migration[6.1]
  def change
    create_table :runn_assignments do |t|
      t.bigint :runn_id, null: false
      t.bigint :person_id
      t.bigint :project_id
      t.bigint :role_id
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :minutes_per_day, null: false, default: 0
      t.boolean :is_active, null: false, default: true
      t.boolean :is_billable, null: false, default: true
      t.boolean :is_placeholder, null: false, default: false
      t.boolean :is_template, null: false, default: false
      t.boolean :is_non_working_day, null: false, default: false
      t.text :note
      t.datetime :created_at
      t.datetime :updated_at
      t.jsonb :data
    end
    add_index :runn_assignments, :runn_id, unique: true
    add_index :runn_assignments, :person_id
    add_index :runn_assignments, :project_id
    add_index :runn_assignments, [:start_date, :end_date], using: :gist, name: "idx_runn_assignments_on_daterange"
  end
end
