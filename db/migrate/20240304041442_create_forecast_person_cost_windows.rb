class CreateForecastPersonCostWindows < ActiveRecord::Migration[6.0]
  def change
    create_table :forecast_person_cost_windows do |t|
      t.references :forecast_person, null: false, foreign_key: {
        primary_key: "forecast_id"
      }, index: {
        name: "idx_forecast_person_cost_windows_on_forecast_person_id"
      }

      t.date :started_at
      t.date :ended_at
      t.decimal :hourly_cost

      t.timestamps
    end
  end
end
