class AddDeletedAtToNotionPages < ActiveRecord::Migration[6.0]
  def change
    add_column :notion_pages, :deleted_at, :datetime
    add_index :notion_pages, :deleted_at
  end
end
