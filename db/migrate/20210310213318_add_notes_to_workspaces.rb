class AddNotesToWorkspaces < ActiveRecord::Migration[6.0]
  def change
    add_column :workspaces, :notes, :text
  end
end
