class AddAttributesToAdminUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :admin_users, :show_skill_tree_data, :boolean, default: true
  end
end
