class CreateForecastAssignmentRunnActuals < ActiveRecord::Migration[6.0]
  def change
    create_table :forecast_assignment_runn_actuals do |t|
      t.references :forecast_assignment, null: false, foreign_key: { to_table: :forecast_assignments, primary_key: "forecast_id" }, index: { name: 'idx_forecast_assignment_runn_actuals_on_forecast_assignment_id' }
      t.bigint :runn_actual_id, null: false

      t.timestamps
    end

    add_index :forecast_assignment_runn_actuals, [:forecast_assignment_id, :runn_actual_id], unique: true, name: 'idx_fara_on_fa_id_and_ra_id'
  end
end
