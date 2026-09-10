class CreateNotionDatabases < ActiveRecord::Migration[6.1]
  def change
    create_table :notion_databases do |t|
      t.string   :notion_id, null: false
      t.string   :title, null: false, default: ""
      t.jsonb    :data, null: false, default: {}
      t.datetime :notion_last_edited_at
      t.datetime :fetched_at
      t.boolean  :in_trash, null: false, default: false
      t.timestamps
    end
    add_index :notion_databases, :notion_id, unique: true
  end
end
