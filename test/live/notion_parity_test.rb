# Live parity against api.notion.com. Runs ONLY with NOTION_LIVE=1 (it spends
# real Notion requests and needs the dev token in credentials).
require 'test_helper'

class NotionParityLiveTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    skip "set NOTION_LIVE=1 to run the live Notion parity test" unless ENV["NOTION_LIVE"] == "1"
    ENV["NOTION_RPS"] ||= "2"
    # Clear only the rows this run exercises so the cold pass is a real miss.
    guide = Stacks::Notion::Ids.normalize(Stacks::Notion::Parity::HOM_GUIDE_PAGE)
    NotionBlock.where(page_id: guide).delete_all
    NotionPage.with_deleted.where(notion_id: guide).each(&:destroy_fully!) # delete_all is a soft delete under acts_as_paranoid
    NotionDataSource.where(notion_id: Stacks::Notion::Parity::LEADS_DS).delete_all
    NotionDatabase.where(notion_id: Stacks::Notion::Ids.normalize(Stacks::Notion::Parity::LEADS_DB)).delete_all
    @started = Time.current
  end

  # This test is non-transactional (it drives the proxy through the real app),
  # so remove every mirror row it wrote; leftovers otherwise contaminate later
  # test runs on the shared test DB (soft-deleted rows hide under the paranoid
  # default scope and collide on the unique notion_id index).
  teardown do
    next unless @started
    pages = NotionPage.with_deleted.where("page_fetched_at >= ?", @started)
    NotionBlock.where(page_id: pages.pluck(:notion_id)).delete_all
    pages.each(&:destroy_fully!) # delete_all would only soft-delete
    NotionDataSource.where("updated_at >= ?", @started).delete_all
    NotionDatabase.where("updated_at >= ?", @started).delete_all
  end

  test "the proxy mirrors Notion one-to-one" do
    result = Stacks::Notion::Parity.run(io: $stdout)
    assert_equal 0, result[:failed], result[:failures].join("\n")
    assert_operator result[:passed], :>=, 9
  end
end
