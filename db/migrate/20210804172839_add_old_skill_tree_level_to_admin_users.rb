class AddOldSkillTreeLevelToAdminUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :admin_users, :old_skill_tree_level, :integer
  end
end
