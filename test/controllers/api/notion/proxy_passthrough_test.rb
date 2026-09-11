require 'test_helper'

class Api::Notion::ProxyPassthroughTest < ActionDispatch::IntegrationTest
  PAGE = "3bf131fe-a2c7-8092-87f3-c668e91d5332"
  DS   = "8ac2bac5-bc47-4674-851e-d1b1e4f779f2"
  DB   = "4d9b46b8-bad5-4250-9f14-4347db37964d"

  setup do
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @key = { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page_obj(id = PAGE, last_edited: "2026-09-10T10:00:00.000Z")
    { "object" => "page", "id" => id, "last_edited_time" => last_edited, "in_trash" => false,
      "parent" => { "type" => "data_source_id", "data_source_id" => DS, "database_id" => DB },
      "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => "Row" }] } }, "url" => "u" }
  end

  test "query passes the body through verbatim, keeps request_id, and upserts rows" do
    filter = { "filter" => { "property" => "Lead Status", "status" => { "equals" => "Active" } }, "page_size" => 5 }
    live = { "object" => "list", "results" => [page_obj], "next_cursor" => nil, "has_more" => false, "type" => "page_or_data_source", "page_or_data_source" => {}, "request_status" => {}, "request_id" => "r1" }
    Stacks::Notion.any_instance.expects(:query_data_source).with(DS, filter).returns(live)
    post "/api/notion/v1/data_sources/#{DS.delete('-')}/query", params: filter.to_json, headers: @key
    assert_response :success
    assert_equal "live", response.headers["X-Stacks-Cache"]
    assert_equal live, JSON.parse(response.body)
    assert_equal "Row", NotionPage.find_by!(notion_id: PAGE).page_title
  end

  test "an unfiltered query is still live (the mirror cannot know a data source is complete)" do
    Stacks::Notion.any_instance.expects(:query_data_source).with(DS, {}).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })
    post "/api/notion/v1/data_sources/#{DS}/query", headers: @key
    assert_equal "live", response.headers["X-Stacks-Cache"]
  end

  test "search passes through and upserts pages and data sources" do
    ds = { "object" => "data_source", "id" => DS, "title" => [{ "plain_text" => "Leads" }], "parent" => { "type" => "database_id", "database_id" => DB }, "properties" => {}, "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false }
    Stacks::Notion.any_instance.expects(:search).with({ "query" => "lead" }).returns({ "object" => "list", "results" => [page_obj, ds], "next_cursor" => nil, "has_more" => false })
    post "/api/notion/v1/search", params: { query: "lead" }.to_json, headers: @key
    assert_equal "live", response.headers["X-Stacks-Cache"]
    assert NotionPage.exists?(notion_id: PAGE)
    assert_equal "Leads", NotionDataSource.find_by!(notion_id: DS).title
  end

  test "POST pages and PATCH pages/:id pass through and upsert the response page" do
    body = { "parent" => { "data_source_id" => DS }, "properties" => {} }
    Stacks::Notion.any_instance.expects(:create_page).with(body).returns(page_obj)
    post "/api/notion/v1/pages", params: body.to_json, headers: @key
    assert_response :success
    assert_equal "Row", NotionPage.find_by!(notion_id: PAGE).page_title

    Stacks::Notion.any_instance.expects(:update_page).with(PAGE, { "in_trash" => true }).returns(page_obj.merge("in_trash" => true, "last_edited_time" => "2026-09-10T11:00:00.000Z"))
    patch "/api/notion/v1/pages/#{PAGE}", params: { in_trash: true }.to_json, headers: @key
    assert_response :success
    assert NotionPage.find_by!(notion_id: PAGE).in_trash
  end

  test "block writes pass through and mark the owning page stale" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    Stacks::Notion::Mirror.replace_level(parent_id: PAGE, page_id: PAGE, blocks: [{ "object" => "block", "id" => "b1", "type" => "paragraph", "has_children" => false, "parent" => { "type" => "page_id", "page_id" => PAGE } }], fetched_at: Time.current)

    Stacks::Notion.any_instance.expects(:append_block_children).with(PAGE, { "children" => [] }).returns({ "object" => "list", "results" => [] })
    patch "/api/notion/v1/blocks/#{PAGE}/children", params: { children: [] }.to_json, headers: @key
    assert_response :success
    assert NotionPage.find_by!(notion_id: PAGE).blocks_stale_at.present?

    NotionPage.find_by!(notion_id: PAGE).update!(blocks_stale_at: nil)
    Stacks::Notion.any_instance.expects(:update_block).with("b1", { "paragraph" => {} }).returns({ "object" => "block", "id" => "b1", "parent" => { "type" => "page_id", "page_id" => PAGE } })
    patch "/api/notion/v1/blocks/b1", params: { paragraph: {} }.to_json, headers: @key
    assert NotionPage.find_by!(notion_id: PAGE).blocks_stale_at.present?

    NotionPage.find_by!(notion_id: PAGE).update!(blocks_stale_at: nil)
    Stacks::Notion.any_instance.expects(:delete_block).with("b1").returns({ "object" => "block", "id" => "b1", "in_trash" => true, "parent" => { "type" => "page_id", "page_id" => PAGE } })
    delete "/api/notion/v1/blocks/b1", headers: @key
    assert NotionPage.find_by!(notion_id: PAGE).blocks_stale_at.present?
  end

  test "a Notion 400 on a write passes through unchanged" do
    err = Stacks::Notion::RequestError.new(400, { "object" => "error", "status" => 400, "code" => "validation_error", "message" => "body failed validation" })
    Stacks::Notion.any_instance.stubs(:create_page).raises(err)
    post "/api/notion/v1/pages", params: {}.to_json, headers: @key
    assert_response :bad_request
    assert_equal "body failed validation", JSON.parse(response.body)["message"]
  end

  test "a malformed JSON body with Content-Type: application/json returns invalid_json before the action runs" do
    post "/api/notion/v1/search", params: "{not json", headers: @key
    assert_response :bad_request
    assert_equal "invalid_json", JSON.parse(response.body)["code"]
  end
end
