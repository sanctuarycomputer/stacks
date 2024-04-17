class CreateForecastAssignmentDailyFinancialSnapshots < ActiveRecord::Migration[6.0]
  def change
    create_table :forecast_assignment_daily_financial_snapshots do |t|
      t.bigint :forecast_assignment_id, null: false, index: {
        name: "idx_snapshots_on_forecast_assignment_id"
      }
      t.bigint :forecast_person_id, null: false, index: {
        name: "idx_snapshots_on_forecast_person_id"
      }
      t.bigint :forecast_project_id, null: false, index: {
        name: "idx_snapshots_on_forecast_project_id"
      }
      t.date :effective_date, null: false
      t.bigint :studio_id, null: false
      t.decimal :hourly_cost, null: false
      t.decimal :hours, null: false
      t.boolean :needs_review, null: false, index: {
        name: "idx_snapshots_on_needs_review"
      }

      t.timestamps
    end
  end
end
