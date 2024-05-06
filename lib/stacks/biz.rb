class Stacks::Biz
  class << self

    def notion
      @_notion ||= Stacks::Notion.new
    end

    def all_cards
      NotionPage.includes(versions: :item).where(
        notion_parent_type: "database_id",
        notion_parent_id: "713b28db-4f8a-45c6-8126-e9723c65349e"
      )
    end

    def sync!
      notion.sync_database("0a693aeff882472cac736b19ab9c438a")
    end
  end
end
