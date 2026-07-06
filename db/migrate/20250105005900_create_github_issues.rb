class CreateGithubIssues < ActiveRecord::Migration[6.0]
  def change
    create_table :github_issues do |t|
      t.integer :github_id, null: false, limit: 8
      t.string :github_node_id, null: false
      t.string :title, null: false
      t.jsonb :data, null: false
      t.integer :github_repo_id, null: false, limit: 8
      t.integer :github_user_id, null: false, limit: 8
      t.timestamps
    end

    add_index :github_issues, :github_id, unique: true
    add_index :github_issues, :github_node_id, unique: true
  end
end
