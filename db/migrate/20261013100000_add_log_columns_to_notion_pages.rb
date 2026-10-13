# What the project log needs to find and order Stacksbot's rows without
# scanning notion_pages: the Notion project ids a row is filed under, the date
# it sorts by, and when the filtered sync last saw it.
#
# This runs on production while the code before it is live. That code writes
# an explicit column list (Stacks::Notion#sync_database), so new columns with
# defaults are invisible to it. Indexes are built concurrently. Safe to run
# twice. If a concurrent build is interrupted it leaves an INVALID index: drop
# that index by name and run this again.
class AddLogColumnsToNotionPages < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  PROJECTS_INDEX = "index_notion_pages_on_project_ids".freeze
  PARENT_INDEX = "index_notion_pages_on_parent_and_occurred_at".freeze

  def up
    unless column_exists?(:notion_pages, :project_ids)
      add_column :notion_pages, :project_ids, :string, array: true, default: [], null: false
    end
    add_column :notion_pages, :occurred_at, :datetime unless column_exists?(:notion_pages, :occurred_at)
    add_column :notion_pages, :synced_at, :datetime unless column_exists?(:notion_pages, :synced_at)

    unless index_name_exists?(:notion_pages, PROJECTS_INDEX)
      add_index :notion_pages, :project_ids, using: :gin, algorithm: :concurrently, name: PROJECTS_INDEX
    end
    unless index_name_exists?(:notion_pages, PARENT_INDEX)
      add_index :notion_pages, [:notion_parent_id, :occurred_at], algorithm: :concurrently, name: PARENT_INDEX
    end
  end

  def down
    remove_index :notion_pages, name: PARENT_INDEX, algorithm: :concurrently if index_name_exists?(:notion_pages, PARENT_INDEX)
    remove_index :notion_pages, name: PROJECTS_INDEX, algorithm: :concurrently if index_name_exists?(:notion_pages, PROJECTS_INDEX)
    remove_column :notion_pages, :synced_at if column_exists?(:notion_pages, :synced_at)
    remove_column :notion_pages, :occurred_at if column_exists?(:notion_pages, :occurred_at)
    remove_column :notion_pages, :project_ids if column_exists?(:notion_pages, :project_ids)
  end
end
