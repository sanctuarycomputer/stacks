class UpdateAdminUserInfoDefault < ActiveRecord::Migration[6.0]
  def change
    change_column_default :admin_users, :info, {}
    AdminUser.all.each do |a|
      a.update(info: {}) if a.info == "{}"
    end
  end
end
