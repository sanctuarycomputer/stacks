class DropOldTables < ActiveRecord::Migration[6.1]
  def change
    drop_table :dei_rollups
    drop_table :admin_user_racial_backgrounds
    drop_table :admin_user_cultural_backgrounds
    drop_table :admin_user_gender_identities
    drop_table :admin_user_communities
    drop_table :admin_user_interests
    drop_table :racial_backgrounds
    drop_table :cultural_backgrounds
    drop_table :gender_identities
    drop_table :communities
    drop_table :interests
    drop_table :collective_role_holder_periods
    drop_table :collective_roles
    drop_table :studio_coordinator_periods

    remove_column :admin_users, :github_user_id
    drop_table :github_issues
    drop_table :github_pull_requests
    drop_table :github_repos
    drop_table :github_users
    drop_table :project_tracker_zenhub_workspaces
    drop_table :zenhub_issue_assignees
    drop_table :zenhub_issue_connected_pull_requests
    drop_table :zenhub_issues
    drop_table :zenhub_workspace_github_repository_connections
    drop_table :zenhub_workspace_issue_connections
    drop_table :zenhub_workspaces

  end
end
