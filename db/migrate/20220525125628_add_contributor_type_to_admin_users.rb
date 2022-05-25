class AddContributorTypeToAdminUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :admin_users, :contributor_type, :integer, default: 0
  end
end
