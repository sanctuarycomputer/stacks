class CreateRecurringAssignments < ActiveRecord::Migration[6.1]
  def change
    create_table :recurring_assignments do |t|
      t.bigint :forecast_person_id, null: false
      t.bigint :forecast_project_id, null: false
      t.integer :allocation, null: false
      t.boolean :active_on_days_off, null: false, default: false
      t.text :notes, null: false, default: ""
      t.integer :weekdays, array: true, null: false, default: [1, 2, 3, 4, 5]
      t.date :starts_on, null: false
      t.date :ends_on
      t.datetime :paused_at
      t.timestamps
    end
    add_index :recurring_assignments, :forecast_person_id
    add_index :recurring_assignments, :forecast_project_id
    add_index :recurring_assignments, :paused_at
  end
end
