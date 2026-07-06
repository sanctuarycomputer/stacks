class AddProjectIdEndDateIndexToForecastAssignments < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def change
    add_index :forecast_assignments,
      [:project_id, :end_date],
      algorithm: :concurrently,
      if_not_exists: true
  end
end
