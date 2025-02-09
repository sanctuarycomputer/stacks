class CreateProjectTrackerZenhubWorkspaces < ActiveRecord::Migration[6.0]
  def change
    create_table :project_tracker_zenhub_workspaces do |t|
      t.references :project_tracker, null: false
      t.string :zenhub_workspace_id, null: false

      t.timestamps
    end

    add_index :project_tracker_zenhub_workspaces, [:project_tracker_id, :zenhub_workspace_id], name: 'idx_project_tracker_zenhub_workspace', unique: true
  end
end
