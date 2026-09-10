class CreateNotionBlocks < ActiveRecord::Migration[6.1]
  def change
    create_table :notion_blocks do |t|
      t.string   :notion_id, null: false
      t.string   :parent_id, null: false
      t.string   :page_id, null: false
      t.integer  :position, null: false
      t.boolean  :has_children, null: false, default: false
      t.datetime :children_fetched_at
      t.jsonb    :data, null: false, default: {}
      t.timestamps
    end
    add_index :notion_blocks, :notion_id, unique: true
    add_index :notion_blocks, [:parent_id, :position]
    add_index :notion_blocks, :page_id
  end
end
