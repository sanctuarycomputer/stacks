class CreateForecastAssignments < ActiveRecord::Migration[6.0]
  def change
    create_table :forecast_assignments do |t|
      t.string :forecast_id
      t.datetime :updated_at
      t.string :updated_by_id
      t.integer :allocation
      t.date :start_date
      t.date :end_date
      t.text :notes
      t.string :project_id
      t.string :person_id
      t.string :placeholder_id
      t.string :repeated_assignment_set_id
      t.boolean :active_on_days_off
      t.jsonb :data
    end

    add_index :forecast_assignments, :forecast_id, unique: true
    add_index :forecast_assignments, :project_id
    add_index :forecast_assignments, :person_id
  end
end
