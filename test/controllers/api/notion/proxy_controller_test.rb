require 'test_helper'

class Api::Notion::ProxyControllerTest < ActionDispatch::IntegrationTest
  PAGE = "3bf131fe-a2c7-8092-87f3-c668e91d5332"
  DS   = "8ac2bac5-bc47-4674-851e-d1b1e4f779f2"
  DB   = "4d9b46b8-bad5-4250-9f14-4347db37964d"

  setup do
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @key = { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page_obj(last_edited: "2026-09-10T10:00:00.000Z")
    { "object" => "page", "id" => PAGE, "last_edited_time" => last_edited, "in_trash" => false,
      "parent" => { "type" => "workspace", "workspace" => true },
      "properties" => { "title" => { "type" => "title", "title" => [{ "plain_text" => "Guide" }] } },
      "url" => "https://www.notion.so/x", "request_id" => "req-1" }
  end

  test "rejects a missing key in Notion's error shape" do
    get "/api/notion/v1/pages/#{PAGE}"
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "error", body["object"]
    assert_equal "unauthorized", body["code"]
    assert_equal 401, body["status"]
  end

  test "GET pages/:id misses, fetches, stores, and serves the body minus request_id" do
    Stacks::Notion.any_instance.expects(:get_page).with(PAGE).returns(page_obj)
    get "/api/notion/v1/pages/#{PAGE.delete('-')}", headers: @key
    assert_response :success
    assert_equal "miss", response.headers["X-Stacks-Cache"]
    assert response.headers["X-Stacks-Fetched-At"].present?
    body = JSON.parse(response.body)
    assert_equal PAGE, body["id"]
    refute body.key?("request_id")
    assert NotionPage.exists?(notion_id: PAGE)
  end

  test "GET pages/:id hits without calling Notion, with a dashless id" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    Stacks::Notion.any_instance.expects(:get_page).never
    get "/api/notion/v1/pages/#{PAGE.delete('-')}", headers: @key
    assert_response :success
    assert_equal "hit", response.headers["X-Stacks-Cache"]
    assert_equal "Guide", JSON.parse(response.body).dig("properties", "title", "title", 0, "plain_text")
  end

  test "a soft-deleted or access_lost row is a miss" do
    Stacks::Notion::Mirror.upsert_page(page_obj).destroy
    Stacks::Notion.any_instance.expects(:get_page).with(PAGE).returns(page_obj)
    get "/api/notion/v1/pages/#{PAGE}", headers: @key
    assert_equal "miss", response.headers["X-Stacks-Cache"]
    refute NotionPage.find_by!(notion_id: PAGE).deleted?
  end

  test "Notion 404 passes through with status and body, marks access_lost, and is not sent to Sentry" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    NotionPage.find_by!(notion_id: PAGE).update!(access_lost: true)
    err = Stacks::Notion::RequestError.new(404, { "object" => "error", "status" => 404, "code" => "object_not_found", "message" => "nope" }, { "content-type" => "application/json" })
    Stacks::Notion.any_instance.stubs(:get_page).raises(err)
    Sentry.expects(:capture_exception).never
    get "/api/notion/v1/pages/#{PAGE}", headers: @key
    assert_response :not_found
    assert_equal "object_not_found", JSON.parse(response.body)["code"]
    assert NotionPage.find_by!(notion_id: PAGE).access_lost
  end

  test "Notion 429 passes through with Retry-After" do
    err = Stacks::Notion::RateLimited.new(429, { "object" => "error", "status" => 429, "code" => "rate_limited", "message" => "slow down" }, { "retry-after" => "12" })
    Stacks::Notion.any_instance.stubs(:get_page).raises(err)
    get "/api/notion/v1/pages/#{PAGE}", headers: @key
    assert_response 429
    assert_equal "12", response.headers["Retry-After"]
    assert_equal "rate_limited", JSON.parse(response.body)["code"]
  end

  test "Notion 5xx errors are reported to Sentry" do
    err = Stacks::Notion::RequestError.new(502, { "object" => "error", "status" => 502, "code" => "internal_server_error", "message" => "boom" })
    Stacks::Notion.any_instance.stubs(:get_page).raises(err)
    Sentry.expects(:capture_exception).once
    get "/api/notion/v1/pages/#{PAGE}", headers: @key
    assert_response 502
    assert_equal "internal_server_error", JSON.parse(response.body)["code"]
  end

  test "GET blocks/:id misses, stores when the owning page is known, and serves live" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    Stacks::Notion.any_instance.expects(:get_block).with("b1").returns(
      { "object" => "block", "id" => "b1", "type" => "paragraph", "has_children" => false,
        "parent" => { "type" => "page_id", "page_id" => PAGE },
        "paragraph" => { "rich_text" => [] }, "request_id" => "r" }
    )
    get "/api/notion/v1/blocks/b1", headers: @key
    assert_response :success
    assert_equal "live", response.headers["X-Stacks-Cache"]
    body = JSON.parse(response.body)
    assert body.key?("request_id")
    block = NotionBlock.find_by!(notion_id: "b1")
    assert_equal PAGE, block.page_id
    refute block.data.key?("request_id")

    Stacks::Notion.any_instance.expects(:get_block).never
    get "/api/notion/v1/blocks/b1", headers: @key
    assert_response :success
    assert_equal "hit", response.headers["X-Stacks-Cache"]
    refute JSON.parse(response.body).key?("request_id")
  end

  test "GET blocks/:id with an unknown parent serves live and stores nothing" do
    Stacks::Notion.any_instance.expects(:get_block).with("b2").returns(
      { "object" => "block", "id" => "b2", "type" => "paragraph", "has_children" => false,
        "parent" => { "type" => "page_id", "page_id" => SecureRandom.uuid },
        "paragraph" => { "rich_text" => [] } }
    )
    get "/api/notion/v1/blocks/b2", headers: @key
    assert_response :success
    assert_equal "live", response.headers["X-Stacks-Cache"]
    refute NotionBlock.exists?(notion_id: "b2")
  end

  test "GET data_sources/:id and databases/:id miss then hit" do
    Stacks::Notion.any_instance.expects(:get_data_source).with(DS).returns({ "object" => "data_source", "id" => DS, "title" => [{ "plain_text" => "Leads" }], "parent" => { "type" => "database_id", "database_id" => DB }, "properties" => {}, "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false, "request_id" => "r" })
    get "/api/notion/v1/data_sources/#{DS}", headers: @key
    assert_equal "miss", response.headers["X-Stacks-Cache"]
    get "/api/notion/v1/data_sources/#{DS}", headers: @key
    assert_equal "hit", response.headers["X-Stacks-Cache"]
    refute JSON.parse(response.body).key?("request_id")

    Stacks::Notion.any_instance.expects(:get_database).with(DB).returns({ "object" => "database", "id" => DB, "title" => [{ "plain_text" => "Leads" }], "data_sources" => [{ "id" => DS, "name" => "Leads" }], "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false })
    get "/api/notion/v1/databases/#{DB}", headers: @key
    assert_equal "miss", response.headers["X-Stacks-Cache"]
    get "/api/notion/v1/databases/#{DB}", headers: @key
    assert_equal "hit", response.headers["X-Stacks-Cache"]
  end

  test "a malformed id is a Notion-style 400" do
    get "/api/notion/v1/pages/not-an-id", headers: @key
    assert_response :bad_request
    assert_equal "validation_error", JSON.parse(response.body)["code"]
  end

  test "an unknown route is a Notion-style 404" do
    get "/api/notion/v1/users", headers: @key
    assert_response :not_found
    assert_equal "object_not_found", JSON.parse(response.body)["code"]
  end
end
