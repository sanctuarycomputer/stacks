require 'test_helper'

class Mcp::NotionToolsTest < ActiveSupport::TestCase
  PAGE = "3bf131fe-a2c7-8092-87f3-c668e91d5332"
  DS   = "8ac2bac5-bc47-4674-851e-d1b1e4f779f2"

  setup do
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page_obj = { "object" => "page", "id" => PAGE, "last_edited_time" => "2026-09-10T10:00:00.000Z", "in_trash" => false, "parent" => { "type" => "workspace", "workspace" => true }, "properties" => { "title" => { "type" => "title", "title" => [{ "plain_text" => "Guide" }] } }, "url" => "https://www.notion.so/x" }
  def payload(resp) = JSON.parse(resp.content.first[:text])

  test "the three tools are registered under Notion's MCP names" do
    names = Mcp::Server::TOOLS.map(&:tool_name)
    assert_includes names, "notion-fetch"
    assert_includes names, "notion-search"
    assert_includes names, "notion-query-data-sources"
  end

  test "notion-fetch walks the tree and returns markdown, properties, and freshness" do
    Stacks::Notion.any_instance.expects(:get_page).with(PAGE).returns(page_obj)
    Stacks::Notion.any_instance.expects(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns({ "object" => "list", "results" => [{ "id" => "b1", "type" => "paragraph", "has_children" => false, "paragraph" => { "rich_text" => [{ "plain_text" => "hi", "annotations" => {}, "href" => nil }] } }], "next_cursor" => nil, "has_more" => false })
    out = payload(Mcp::NotionFetchTool.call(id: PAGE.delete("-"), server_context: nil))
    assert_equal PAGE, out["id"]
    assert_equal "Guide", out["title"]
    assert_equal "hi\n", out["markdown"]
    assert_equal false, out["truncated"]
    assert out["properties"].key?("title")
    assert out["fetched_at"].present?
  end

  test "notion-fetch reports truncated when the deadline stops the walk and resumes next call" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    Stacks::Notion::TreeFetcher.expects(:new).with(anything, deadline: Mcp::NotionFetchTool::DEADLINE).returns(stub(walk: { complete: false, requests: 3 }))
    out = payload(Mcp::NotionFetchTool.call(id: PAGE, server_context: nil))
    assert_equal true, out["truncated"]
  end

  test "notion-fetch surfaces a Notion error as a tool error" do
    Stacks::Notion.any_instance.stubs(:get_page).raises(Stacks::Notion::RequestError.new(404, { "object" => "error", "code" => "object_not_found", "message" => "nope" }))
    out = payload(Mcp::NotionFetchTool.call(id: PAGE, server_context: nil))
    assert_match(/object_not_found/, out["error"])
  end

  test "notion-search passes through and returns compact results" do
    Stacks::Notion.any_instance.expects(:search).with({ "query" => "guide", "page_size" => 10 }).returns({ "object" => "list", "results" => [page_obj], "next_cursor" => nil, "has_more" => false })
    out = payload(Mcp::NotionSearchTool.call(query: "guide", server_context: nil))
    assert_equal [{ "object" => "page", "id" => PAGE, "title" => "Guide", "url" => "https://www.notion.so/x", "last_edited_time" => "2026-09-10T10:00:00.000Z" }], out["results"]
    assert NotionPage.exists?(notion_id: PAGE)
  end

  test "notion-query-data-sources passes the filter through verbatim" do
    filter = { "property" => "Lead Status", "status" => { "equals" => "Active" } }
    live = { "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false }
    Stacks::Notion.any_instance.expects(:query_data_source).with(DS, { "filter" => filter, "page_size" => 100 }).returns(live)
    out = payload(Mcp::NotionQueryDataSourcesTool.call(data_source_id: DS.delete("-"), filter: filter, server_context: nil))
    assert_equal live, out
  end
end
