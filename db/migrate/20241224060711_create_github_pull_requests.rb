class CreateGithubPullRequests < ActiveRecord::Migration[6.0]
  def change
    create_table :github_pull_requests do |t|
      t.string :title, default: "", null: false
      t.bigint :time_to_merge
      t.integer :github_id, null: false, limit: 8
      t.integer :github_repo_id, null: false, limit: 8
      t.integer :github_user_id, null: false, limit: 8
      t.jsonb :data, null: false
      t.datetime :merged_at
      t.timestamps
    end
    add_index :github_pull_requests, :github_id, unique: true
    add_index :github_pull_requests, :github_repo_id
    add_index :github_pull_requests, :github_user_id
    add_index :github_pull_requests, :merged_at
  end
end
