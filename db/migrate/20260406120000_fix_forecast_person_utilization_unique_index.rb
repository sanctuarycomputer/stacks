class FixForecastPersonUtilizationUniqueIndex < ActiveRecord::Migration[6.1]
  def change
    remove_index :forecast_person_utilization_reports,
      name: "idx_forecast_person_utilization"

    add_index :forecast_person_utilization_reports,
      [:forecast_person_id, :starts_at, :ends_at, :period_gradation],
      unique: true,
      name: "idx_forecast_person_utilization"
  end
end
