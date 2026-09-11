# Live parity against api.notion.com. Runs ONLY with NOTION_LIVE=1 (it spends
# real Notion requests and needs the dev token in credentials).
require 'test_helper'

class NotionParityLiveTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    skip "set NOTION_LIVE=1 to run the live Notion parity test" unless ENV["NOTION_LIVE"] == "1"
    ENV["NOTION_RPS"] ||= "2"
    NotionBlock.delete_all
    NotionPage.with_deleted.where(notion_id: [Stacks::Notion::Ids.normalize(Stacks::Notion::Parity::HOM_GUIDE_PAGE)]).delete_all
    NotionDataSource.where(notion_id: Stacks::Notion::Parity::LEADS_DS).delete_all
    NotionDatabase.where(notion_id: Stacks::Notion::Ids.normalize(Stacks::Notion::Parity::LEADS_DB)).delete_all
  end

  test "the proxy mirrors Notion one-to-one" do
    result = Stacks::Notion::Parity.run(io: $stdout)
    assert_equal 0, result[:failed], result[:failures].join("\n")
    assert_operator result[:passed], :>=, 9
  end
end
