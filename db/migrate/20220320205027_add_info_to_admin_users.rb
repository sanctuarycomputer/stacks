class AddInfoToAdminUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :admin_users, :info, :jsonb, default: '{}'
  end
end
