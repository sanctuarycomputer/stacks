class DropArchivedAtFromAdminUsers < ActiveRecord::Migration[6.0]
  def change
    remove_column :admin_users, :archived_at
  end
end
