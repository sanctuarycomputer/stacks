class AddStatusToWorkspaces < ActiveRecord::Migration[6.0]
  def change
    add_column :workspaces, :status, :integer, default: 0
  end
end
