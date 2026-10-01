class AddHumanOperatingManualRequirementFlagsToAdminUsers < ActiveRecord::Migration[6.1]
  def change
    add_column :admin_users, :requires_human_operating_manual, :boolean, null: false, default: true
    add_column :admin_users, :requires_superpowers_assessment, :boolean, null: false, default: true
  end
end
