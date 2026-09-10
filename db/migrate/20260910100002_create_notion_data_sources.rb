class CreateNotionDataSources < ActiveRecord::Migration[6.1]
  def change
    create_table :notion_data_sources do |t|
      t.string   :notion_id, null: false
      t.string   :database_id
      t.string   :title, null: false, default: ""
      t.jsonb    :data, null: false, default: {}
      t.datetime :notion_last_edited_at
      t.datetime :fetched_at
      t.boolean  :in_trash, null: false, default: false
      t.timestamps
    end
    add_index :notion_data_sources, :notion_id, unique: true
    add_index :notion_data_sources, :database_id
  end
end
