class CreateZenhubWorkspaceGithubRepositoryConnections < ActiveRecord::Migration[6.0]
  def change
    create_table :zenhub_workspace_github_repository_connections do |t|
      t.string :zenhub_id
      t.string :zenhub_workspace_id
      t.integer :github_repo_id
    end
    add_index :zenhub_workspace_github_repository_connections, :zenhub_id, unique: true, name: 'idx_zenhub_workspace_github_repo_connections_zenhub_id'
    add_index :zenhub_workspace_github_repository_connections, [:zenhub_workspace_id, :github_repo_id], unique: true, name: 'idx_zenhub_workspace_github_repo_connections'
  end
end
