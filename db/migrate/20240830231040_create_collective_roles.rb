class CreateCollectiveRoles < ActiveRecord::Migration[6.0]
  def change
    create_table :collective_roles do |t|
      t.string :name, null: false, unique: true
      t.string :notion_link, null: false, unique: true

      t.timestamps
    end
  end
end
