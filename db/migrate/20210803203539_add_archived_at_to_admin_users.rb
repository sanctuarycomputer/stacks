class AddArchivedAtToAdminUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :admin_users, :archived_at, :datetime
  end
end
