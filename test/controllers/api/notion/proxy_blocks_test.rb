require 'test_helper'

class Api::Notion::ProxyBlocksTest < ActionDispatch::IntegrationTest
  PAGE = "3bf131fe-a2c7-8092-87f3-c668e91d5332"

  setup do
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @key = { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }
    Stacks::Notion::Mirror.upsert_page(
      { "object" => "page", "id" => PAGE, "last_edited_time" => "2026-09-10T10:00:00.000Z", "in_trash" => false,
        "parent" => { "type" => "workspace", "workspace" => true }, "properties" => {}, "url" => "u" }
    )
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def block(id, parent, has_children: false)
    { "object" => "block", "id" => id, "type" => "paragraph", "has_children" => has_children,
      "parent" => { "type" => "page_id", "page_id" => parent }, "paragraph" => { "rich_text" => [] } }
  end

  def list(results, next_cursor: nil)
    { "object" => "list", "results" => results, "next_cursor" => next_cursor, "has_more" => !next_cursor.nil?, "type" => "block", "block" => {}, "request_id" => "r" }
  end

  test "never fetched: proxies the single cursor page live, stores rows, completes a single-page level" do
    Stacks::Notion.any_instance.expects(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns(list([block("b1", PAGE), block("b2", PAGE, has_children: true)]))
    get "/api/notion/v1/blocks/#{PAGE.delete('-')}/children", headers: @key
    assert_response :success
    assert_equal "miss", response.headers["X-Stacks-Cache"]
    assert response.headers["X-Stacks-Fetched-At"].present?
    body = JSON.parse(response.body)
    assert_equal %w[b1 b2], body["results"].map { |b| b["id"] }
    assert_equal false, body["has_more"]
    assert body.key?("request_id"), "a live pass-through keeps Notion's request_id"
    assert NotionPage.find_by!(notion_id: PAGE).root_children_fetched_at.present?
    assert_equal %w[b1 b2], NotionBlock.children_of(PAGE).pluck(:notion_id)
  end

  test "a multi-page level is stored but not marked complete" do
    Stacks::Notion.any_instance.expects(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns(list([block("b1", PAGE)], next_cursor: "b2"))
    get "/api/notion/v1/blocks/#{PAGE}/children", headers: @key
    assert_equal "b2", JSON.parse(response.body)["next_cursor"]
    assert_nil NotionPage.find_by!(notion_id: PAGE).root_children_fetched_at
    assert_equal %w[b1], NotionBlock.children_of(PAGE).pluck(:notion_id)

    # the second cursor page is still live
    Stacks::Notion.any_instance.expects(:get_block_children).with(PAGE, start_cursor: "b2", page_size: 100).returns(list([block("b2", PAGE)]))
    get "/api/notion/v1/blocks/#{PAGE}/children", params: { start_cursor: "b2" }, headers: @key
    assert_equal "miss", response.headers["X-Stacks-Cache"]
  end

  test "a fresh level is served from cache with local pagination and no request" do
    blocks = (1..5).map { |i| block("b#{i}", PAGE) }
    Stacks::Notion::Mirror.replace_level(parent_id: PAGE, page_id: PAGE, blocks: blocks, fetched_at: Time.current)
    Stacks::Notion.any_instance.expects(:get_block_children).never

    get "/api/notion/v1/blocks/#{PAGE}/children", params: { page_size: 2 }, headers: @key
    assert_equal "hit", response.headers["X-Stacks-Cache"]
    assert_equal NotionPage.find_by!(notion_id: PAGE).root_children_fetched_at.utc.iso8601, response.headers["X-Stacks-Fetched-At"]
    body = JSON.parse(response.body)
    assert_equal %w[b1 b2], body["results"].map { |b| b["id"] }
    assert_equal "b3", body["next_cursor"]
    assert_equal true, body["has_more"]
    assert_equal "block", body["type"]
    assert_equal({}, body["block"])
    refute body.key?("request_id")

    get "/api/notion/v1/blocks/#{PAGE}/children", params: { page_size: 2, start_cursor: "b3" }, headers: @key
    body = JSON.parse(response.body)
    assert_equal %w[b3 b4], body["results"].map { |b| b["id"] }
    assert_equal "b5", body["next_cursor"]

    get "/api/notion/v1/blocks/#{PAGE}/children", params: { page_size: 2, start_cursor: "b5" }, headers: @key
    body = JSON.parse(response.body)
    assert_equal %w[b5], body["results"].map { |b| b["id"] }
    assert_nil body["next_cursor"]
    assert_equal false, body["has_more"]
  end

  test "a nested level resolves its page through the cached parent block" do
    Stacks::Notion::Mirror.replace_level(parent_id: PAGE, page_id: PAGE, blocks: [block("b1", PAGE, has_children: true)], fetched_at: Time.current)
    Stacks::Notion.any_instance.expects(:get_block_children).with("b1", start_cursor: nil, page_size: 100).returns(list([block("b9", "b1")]))
    get "/api/notion/v1/blocks/b1/children", headers: @key
    assert_equal "miss", response.headers["X-Stacks-Cache"]
    assert_equal PAGE, NotionBlock.find_by!(notion_id: "b9").page_id
    assert NotionBlock.find_by!(notion_id: "b1").children_fetched_at.present?
  end

  test "a stale level (blocks_stale_at newer than its marker) refetches the caller's cursor page" do
    Stacks::Notion::Mirror.replace_level(parent_id: PAGE, page_id: PAGE, blocks: [block("b1", PAGE)], fetched_at: 1.hour.ago)
    NotionPage.find_by!(notion_id: PAGE).update!(blocks_stale_at: Time.current)
    Stacks::Notion.any_instance.expects(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns(list([block("b1", PAGE), block("b2", PAGE)]))
    get "/api/notion/v1/blocks/#{PAGE}/children", headers: @key
    assert_equal "stale", response.headers["X-Stacks-Cache"]
    assert response.headers["X-Stacks-Fetched-At"].present?
    assert_equal %w[b1 b2], NotionBlock.children_of(PAGE).pluck(:notion_id)
    assert_operator NotionPage.find_by!(notion_id: PAGE).root_children_fetched_at, :>, NotionPage.find_by!(notion_id: PAGE).blocks_stale_at
  end

  test "an unknown block id passes through live without storing" do
    Stacks::Notion.any_instance.expects(:get_block_children).with("zzz", start_cursor: nil, page_size: 100).returns(list([block("q", "zzz")]))
    get "/api/notion/v1/blocks/zzz/children", headers: @key
    assert_equal "live", response.headers["X-Stacks-Cache"]
    assert_nil response.headers["X-Stacks-Fetched-At"]
    refute NotionBlock.exists?(notion_id: "q")
  end

  test "an invalid start_cursor on a fresh level returns Notion-style 400 without a request" do
    Stacks::Notion::Mirror.replace_level(parent_id: PAGE, page_id: PAGE, blocks: [block("b1", PAGE), block("b2", PAGE)], fetched_at: Time.current)
    Stacks::Notion.any_instance.expects(:get_block_children).never

    get "/api/notion/v1/blocks/#{PAGE}/children", params: { start_cursor: "nope" }, headers: @key
    assert_response :bad_request
    assert_equal "validation_error", JSON.parse(response.body)["code"]
  end
end
