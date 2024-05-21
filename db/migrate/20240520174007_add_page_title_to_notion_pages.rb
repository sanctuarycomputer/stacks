class AddPageTitleToNotionPages < ActiveRecord::Migration[6.0]
  def change
    add_column :notion_pages, :page_title, :string, default: "", null: false
    NotionPage.all.each do |np|
      np.update!(page_title: (np.data.dig("properties", "Name", "title")[0] || {}).dig("plain_text") || "")
    end
  end
end
