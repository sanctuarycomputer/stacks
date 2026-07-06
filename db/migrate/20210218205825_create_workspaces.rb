class CreateWorkspaces < ActiveRecord::Migration[6.0]
  def change
    create_table :workspaces do |t|
      t.references :reviewable, polymorphic: true, null: false

      t.timestamps
    end
  end
end
