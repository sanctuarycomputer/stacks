class CreateForecastPersonUtilizationReports < ActiveRecord::Migration[6.0]
  def change
    create_table :forecast_person_utilization_reports do |t|
      t.integer :forecast_person_id, null: false
      t.date :starts_at, null: false
      t.date :ends_at, null: false
      t.decimal :expected_hours_sold, precision: 10, scale: 2, null: false
      t.decimal :expected_hours_unsold, precision: 10, scale: 2, null: false
      t.decimal :actual_hours_sold, precision: 10, scale: 2, null: false
      t.decimal :actual_hours_internal, precision: 10, scale: 2, null: false
      t.decimal :actual_hours_time_off, precision: 10, scale: 2, null: false
      t.jsonb :actual_hours_sold_by_rate, null: false
      t.decimal :utilization_rate, precision: 10, scale: 2, null: false

      t.timestamps
    end

    add_index :forecast_person_utilization_reports, :forecast_person_id
    add_index :forecast_person_utilization_reports, [:forecast_person_id, :starts_at, :ends_at], unique: true, name: "idx_forecast_person_utilization"
  end
end
