class CreateGithubRepos < ActiveRecord::Migration[6.0]
  def change
    create_table :github_repos do |t|
      t.integer :github_id, null: false, limit: 8
      t.string :name, null: false
      t.jsonb :data, null: false
      t.timestamps
    end
    add_index :github_repos, :github_id, unique: true
  end
end
