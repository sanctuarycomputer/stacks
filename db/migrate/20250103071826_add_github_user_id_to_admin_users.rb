class AddGithubUserIdToAdminUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :admin_users, :github_user_id, :integer
    add_index :admin_users, :github_user_id, unique: true
  end
end
