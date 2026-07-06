class AddExpectedUtilizationToAdminUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :admin_users, :expected_utilization, :decimal, default: 0.8
  end
end
