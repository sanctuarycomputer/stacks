class CreateZenhubIssues < ActiveRecord::Migration[6.0]
  def change
    create_table :zenhub_issues do |t|
      t.string :zenhub_id, null: false
      t.string :zenhub_workspace_id, null: false
      t.integer :github_repo_id, null: false
      t.integer :github_user_id
      t.integer :issue_type, default: 0, null: false
      t.integer :issue_state, default: 0, null: false
      t.integer :estimate
      t.integer :number
      t.integer :github_issue_id
      t.string :github_issue_node_id
      t.string :title
      t.boolean :is_pull_request, default: false, null: false
      t.datetime :closed_at
      t.timestamps
    end

    add_index :zenhub_issues, :zenhub_id, unique: true
    add_index :zenhub_issues, :closed_at
  end
end
