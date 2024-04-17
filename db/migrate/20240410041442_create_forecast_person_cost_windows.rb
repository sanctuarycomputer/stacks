class CreateForecastPersonCostWindows < ActiveRecord::Migration[6.0]
  def change
    create_table :forecast_person_cost_windows do |t|
      t.references :forecast_person, null: true, foreign_key: {
        primary_key: "forecast_id"
      }, index: {
        name: "idx_forecast_person_cost_windows_on_forecast_person_id"
      }

      t.references :forecast_project, null: true, foreign_key: {
        primary_key: "forecast_id"
      }, index: {
        name: "idx_forecast_person_cost_windows_on_forecast_project_id"
      }

      t.date :start_date, null: false
      t.date :end_date, null: true
      t.decimal :hourly_cost, null: false
      t.boolean :needs_review, null: false, index: true

      t.timestamps
    end
  end
end
