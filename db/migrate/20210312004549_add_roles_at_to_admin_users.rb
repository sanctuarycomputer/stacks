class AddRolesAtToAdminUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :admin_users, :roles, :string, array: true, default: []
  end
end
