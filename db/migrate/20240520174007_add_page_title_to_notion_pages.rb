class AddPageTitleToNotionPages < ActiveRecord::Migration[6.0]
  def change
    add_column :notion_pages, :page_title, :string, default: "", null: false
    NotionPage.all.each do |np|
      begin
        np.update!(page_title: np.page_title)
      rescue => e
        binding.pry
      end
    end
  end
end
