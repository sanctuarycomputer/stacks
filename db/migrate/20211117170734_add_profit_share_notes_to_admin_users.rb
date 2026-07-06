class AddProfitShareNotesToAdminUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :admin_users, :profit_share_notes, :text
  end
end
