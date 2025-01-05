class CreateZenhubWorkspaceIssueConnections < ActiveRecord::Migration[6.0]
  def change
    create_table :zenhub_workspace_issue_connections do |t|
      t.string :zenhub_workspace_id, null: false
      t.string :zenhub_issue_id, null: false
    end

    add_index :zenhub_workspace_issue_connections, [:zenhub_workspace_id, :zenhub_issue_id], unique: true, name: 'idx_zenhub_workspace_issue_connections_on_workspace_and_issue'

    ZenhubIssue.all.each do |issue|
      ZenhubWorkspaceIssueConnection.create!(zenhub_workspace_id: issue.zenhub_workspace_id, zenhub_issue_id: issue.id)
    end

    remove_column :zenhub_issues, :zenhub_workspace_id
  end
end
