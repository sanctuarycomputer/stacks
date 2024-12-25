class CreateZenhubWorkspaces < ActiveRecord::Migration[6.0]
  def change
    create_table :zenhub_workspaces do |t|
      t.string :zenhub_id
      t.string :name
      t.timestamps
    end
    add_index :zenhub_workspaces, :zenhub_id, unique: true
  end
end
