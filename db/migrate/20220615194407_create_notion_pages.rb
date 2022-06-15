class CreateNotionPages < ActiveRecord::Migration[6.0]
  def change
    create_table :notion_pages do |t|
      t.string :notion_id, null: false
      t.string :notion_parent_type
      t.string :notion_parent_id
      t.jsonb :data, null: false, default: {}
    end

    add_index :notion_pages, :notion_id, unique: true
  end
end
