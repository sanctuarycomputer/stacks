class CreateProjectTrackerForecastToRunnSyncTasks < ActiveRecord::Migration[6.0]
  def change
    create_table :project_tracker_forecast_to_runn_sync_tasks do |t|
      t.references :project_tracker, foreign_key: true, index: { name: 'idx_pt_forecast_to_runn_sync_tasks_on_pt_id' }
      t.datetime :settled_at
      t.references :notification, null: true, foreign_key: true, index: { name: 'idx_pt_forecast_to_runn_sync_tasks_on_notification_id' }

      t.timestamps
    end
  end
end
