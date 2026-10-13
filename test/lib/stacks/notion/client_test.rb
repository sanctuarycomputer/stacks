require 'test_helper'

class StacksNotionClientTest < ActiveSupport::TestCase
  DB = "390131fea2c7808bb216c38b46c3ba55".freeze
  FILTER = { and: [{ property: "Projects", relation: { is_not_empty: true } }] }.freeze

  setup do
    @client = Stacks::Notion.allocate
    @slept = []
    @client.sleeper = ->(seconds) { @slept << seconds }
  end

  test "normalize_page! strips what changes on every read and returns the title" do
    row = { "icon" => { "x" => 1 }, "cover" => { "y" => 2 },
            "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => "Hello" }, { "plain_text" => " there" }] },
                              "Docs" => { "type" => "files", "files" => [{ "name" => "a.pdf", "type" => "file", "file" => { "url" => "s3" } }] } } }
    assert_equal "Hello", Stacks::Notion.normalize_page!(row), "the first fragment, as sync_database has always stored it"
    assert_not row.key?("icon")
    assert_not row.key?("cover")
    assert_equal [{ "name" => "a.pdf", "type" => "file" }], row["properties"]["Docs"]["files"]
  end

  test "normalize_page! returns an empty title for a row with no title or no properties" do
    assert_equal "", Stacks::Notion.normalize_page!({ "properties" => { "Name" => { "type" => "title", "title" => [] } } })
    assert_equal "", Stacks::Notion.normalize_page!({ "properties" => nil })
    assert_equal "", Stacks::Notion.normalize_page!({})
  end

  test "a filtered query posts the filter, sort, cursor and page size and returns the body" do
    sorts = [{ timestamp: "last_edited_time", direction: "descending" }]
    @client.expects(:post_json).once.with(
      "/databases/#{DB}/query", { page_size: 100, filter: FILTER, sorts: sorts, start_cursor: "c1" }
    ).returns([200, nil, { "results" => [{ "id" => "a" }], "next_cursor" => nil }])
    out = @client.query_database_filtered(DB, filter: FILTER, sorts: sorts, start_cursor: "c1")
    assert_equal [{ "id" => "a" }], out["results"]
    assert_empty @slept
  end

  test "the first page sends no cursor" do
    @client.expects(:post_json).with("/databases/#{DB}/query", { page_size: 50, filter: FILTER }).returns([200, nil, {}])
    @client.query_database_filtered(DB, filter: FILTER, page_size: 50)
  end

  test "a 429 waits as long as Notion asks, then tries again" do
    @client.stubs(:post_json).returns([429, "7", { "code" => "rate_limited" }]).then.returns([200, nil, { "results" => [] }])
    assert_equal({ "results" => [] }, @client.query_database_filtered(DB, filter: FILTER))
    assert_equal [7.0], @slept
  end

  test "a 5xx backs off 1, 2, 4, 8 seconds and then raises with the status and Notion's message" do
    @client.stubs(:post_json).returns([502, nil, { "code" => "bad_gateway", "message" => "upstream" }])
    error = assert_raises(Stacks::Notion::Error) { @client.query_database_filtered(DB, filter: FILTER) }
    assert_equal [1, 2, 4, 8], @slept
    assert_equal 502, error.status
    assert_equal "bad_gateway", error.code
    assert_match(/502/, error.message)
    assert_match(/upstream/, error.message)
  end

  test "a wait is never longer than 30 seconds" do
    @client.stubs(:post_json).returns([429, "600", {}]).then.returns([200, nil, {}])
    @client.query_database_filtered(DB, filter: FILTER)
    assert_equal [30], @slept
  end

  test "a 400 is not retried: the filter is wrong and will stay wrong" do
    @client.expects(:post_json).once.returns([400, nil, { "code" => "validation_error", "message" => "bad filter" }])
    error = assert_raises(Stacks::Notion::Error) { @client.query_database_filtered(DB, filter: FILTER) }
    assert_equal 400, error.status
    assert_empty @slept
  end

  test "a timeout is retried like a 5xx" do
    @client.stubs(:post_json).raises(Net::ReadTimeout).then.returns([200, nil, { "results" => [] }])
    assert_equal({ "results" => [] }, @client.query_database_filtered(DB, filter: FILTER))
    assert_equal [1], @slept
  end

  test "fetch_page returns the page, and a 404 as an answer, not an error" do
    @client.stubs(:get_json).with("/pages/abc").returns([200, nil, { "id" => "abc" }])
    assert_equal({ status: 200, body: { "id" => "abc" } }, @client.fetch_page("abc"))
    @client.stubs(:get_json).with("/pages/gone").returns([404, nil, { "code" => "object_not_found" }])
    assert_equal 404, @client.fetch_page("gone")[:status]
    assert_empty @slept
  end

  test "fetch_page raises on a 403 and retries a 429" do
    @client.stubs(:get_json).returns([403, nil, { "code" => "restricted_resource" }])
    assert_equal 403, assert_raises(Stacks::Notion::Error) { @client.fetch_page("abc") }.status
    @client.stubs(:get_json).returns([429, nil, {}]).then.returns([200, nil, { "id" => "abc" }])
    assert_equal 200, @client.fetch_page("abc")[:status]
    assert_equal [1], @slept
  end
end
