class AddTargetsToProjectTrackers < ActiveRecord::Migration[6.0]
  def change
    add_column :project_trackers, :target_free_hours_percent, :decimal, default: 1.0
    add_column :project_trackers, :target_profit_margin, :decimal, default: 32.0
  end
end
