class ExtendNotionPagesForMirror < ActiveRecord::Migration[6.1]
  def up
    change_table :notion_pages do |t|
      t.string   :database_id
      t.string   :data_source_id
      t.datetime :notion_last_edited_at
      t.datetime :page_fetched_at
      t.datetime :root_children_fetched_at
      t.datetime :tree_fetched_for_edited_at
      t.datetime :blocks_stale_at
      t.datetime :recheck_after
      t.datetime :wanted_at
      t.boolean  :in_trash, null: false, default: false
      t.boolean  :access_lost, null: false, default: false
      t.string   :url
    end
    add_index :notion_pages, :database_id
    add_index :notion_pages, :data_source_id
    add_index :notion_pages, :notion_last_edited_at
    add_index :notion_pages, :blocks_stale_at, where: "blocks_stale_at IS NOT NULL"
    add_index :notion_pages, :recheck_after, where: "recheck_after IS NOT NULL"
    add_index :notion_pages, :wanted_at, where: "wanted_at IS NOT NULL"

    # Existing rows are all database rows with dashed parent ids (verified 2026-09-10).
    execute <<~SQL
      UPDATE notion_pages
         SET database_id = notion_parent_id
       WHERE notion_parent_type = 'database_id' AND database_id IS NULL
    SQL
    execute <<~SQL
      UPDATE notion_pages
         SET notion_last_edited_at = (data->>'last_edited_time')::timestamptz,
             url = data->>'url',
             in_trash = COALESCE((data->>'in_trash')::boolean, false)
       WHERE data ? 'last_edited_time'
    SQL
    # The old sync stored only the first rich-text run of the title; join every run.
    execute <<~SQL
      UPDATE notion_pages p
         SET page_title = COALESCE((
               SELECT string_agg(run->>'plain_text', '' ORDER BY ord)
                 FROM jsonb_each(p.data->'properties') AS props(key, val),
                      jsonb_array_elements(val->'title') WITH ORDINALITY AS t(run, ord)
                WHERE val->>'type' = 'title'
             ), p.page_title)
       WHERE p.data ? 'properties'
    SQL
  end

  def down
    remove_index :notion_pages, :database_id
    remove_index :notion_pages, :data_source_id
    remove_index :notion_pages, :notion_last_edited_at
    remove_index :notion_pages, :blocks_stale_at
    remove_index :notion_pages, :recheck_after
    remove_index :notion_pages, :wanted_at
    remove_columns :notion_pages, :database_id, :data_source_id, :notion_last_edited_at, :page_fetched_at,
                   :root_children_fetched_at, :tree_fetched_for_edited_at, :blocks_stale_at, :recheck_after,
                   :wanted_at, :in_trash, :access_lost, :url
  end
end
