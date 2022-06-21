class Stacks::Biz
  class << self

    def notion
      @_notion ||= Stacks::Notion.new
    end

    def all_cards
      NotionPage.include(:versions).where(
        notion_parent_type: "database_id",
        notion_parent_id: "713b28db-4f8a-45c6-8126-e9723c65349e"
      )
    end

    def sync!
      ActiveRecord::Base.transaction do
        results = []
        next_cursor = nil
        loop do
          response = notion.query_database(
            "0a693aeff882472cac736b19ab9c438a", next_cursor
          )
          results = [*results, *response["results"]]
          next_cursor = response["next_cursor"]
          break if next_cursor.nil?
        end

        # We're using papertrail to capture diffs,
        # so we can't use upsert, which doesn't run
        # callbacks.
        results.each do |r|
          r.delete("icon") # Custom icons have an AWS Expiry that break our diff
          r.delete("cover") # Cover images have an AWS Expiry that break our diff
          parent_type = r.dig("parent", "type")
          parent_id = r.dig("parent", parent_type)
          page =
            NotionPage.find_or_initialize_by(notion_id: r.dig("id"))
          if !page.persisted? || Hashdiff.diff(r, page.data).any?
            page.update_attributes!({
              notion_parent_type: parent_type,
              notion_parent_id: parent_id,
              data: r
            })
          end
        end
      end
    end
  end
end
