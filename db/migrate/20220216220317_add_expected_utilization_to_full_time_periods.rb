class AddExpectedUtilizationToFullTimePeriods < ActiveRecord::Migration[6.0]
  def change
    add_column :full_time_periods, :expected_utilization, :decimal, default: 0.8

    AdminUser.all.each do |a|
      a.full_time_periods.each do |ftp|
        ftp.update(expected_utilization: a.expected_utilization)
      end
    end

    remove_column :admin_users, :expected_utilization
  end
end
