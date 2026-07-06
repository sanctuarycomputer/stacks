class AddPeriodGradationToForecastPersonUtilizationReports < ActiveRecord::Migration[6.1]
  def change
    add_column :forecast_person_utilization_reports, :period_gradation, :integer, null: false, default: 0
  end
end
