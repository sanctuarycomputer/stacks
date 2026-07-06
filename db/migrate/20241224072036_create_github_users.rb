class CreateGithubUsers < ActiveRecord::Migration[6.0]
  def change
    create_table :github_users do |t|
      t.integer :github_id, null: false, limit: 8
      t.string :login, null: false
      t.jsonb :data, null: false
    end
    add_index :github_users, :github_id, unique: true
  end
end
