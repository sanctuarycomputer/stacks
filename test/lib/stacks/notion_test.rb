require 'test_helper'

class StacksNotionTest < ActiveSupport::TestCase
  FAKE_CONFIG = { notion: { token: "secret_test" }, stacks: { private_api_key: "k" } }.freeze

  setup do
    Stacks::Utils.stubs(:config).returns(FAKE_CONFIG)
    Stacks::Notion.reset_pacer!
    @saved_rps = ENV["NOTION_RPS"]
    ENV["NOTION_RPS"] = "1000" # no pacing delay unless a test sets it
  end

  teardown do
    # Restore (not delete) so test_helper's process-wide default survives this file.
    ENV["NOTION_RPS"] = @saved_rps
    Stacks::Notion.reset_pacer!
  end

  def fake_response(code:, body:, headers: {})
    resp = mock("response")
    resp.stubs(:success?).returns(code < 400)
    resp.stubs(:code).returns(code)
    resp.stubs(:body).returns(JSON.dump(body))
    resp.stubs(:parsed_response).returns(body.deep_stringify_keys)
    resp.stubs(:headers).returns(headers)
    resp
  end

  test "sends bearer token and Notion-Version 2026-03-11 on every request" do
    Stacks::Notion.expects(:get).with { |path, opts|
      path == "/pages/abc" &&
        opts[:headers]["Authorization"] == "Bearer secret_test" &&
        opts[:headers]["Notion-Version"] == "2026-03-11"
    }.returns(fake_response(code: 200, body: { object: "page", id: "abc" }))
    assert_equal "abc", Stacks::Notion.new.get_page("abc")["id"]
  end

  test "get_block_children passes cursor and page_size as query" do
    Stacks::Notion.expects(:get).with { |path, opts|
      path == "/blocks/b1/children" && opts[:query] == { start_cursor: "c2", page_size: 50 }
    }.returns(fake_response(code: 200, body: { object: "list", results: [] }))
    Stacks::Notion.new.get_block_children("b1", start_cursor: "c2", page_size: 50)
  end

  test "query_data_source and search POST JSON bodies" do
    Stacks::Notion.expects(:post).with { |path, opts|
      path == "/data_sources/ds1/query" && JSON.parse(opts[:body]) == { "page_size" => 1 }
    }.returns(fake_response(code: 200, body: { object: "list", results: [] }))
    Stacks::Notion.new.query_data_source("ds1", { page_size: 1 })

    Stacks::Notion.expects(:post).with { |path, opts|
      path == "/search" && JSON.parse(opts[:body]) == { "query" => "x" }
    }.returns(fake_response(code: 200, body: { object: "list", results: [] }))
    Stacks::Notion.new.search({ query: "x" })
  end

  test "writes use PATCH / DELETE with JSON bodies" do
    Stacks::Notion.expects(:patch).with { |path, opts| path == "/pages/p1" && JSON.parse(opts[:body]) == { "in_trash" => true } }
                  .returns(fake_response(code: 200, body: { object: "page", id: "p1" }))
    Stacks::Notion.new.update_page("p1", { in_trash: true })
    Stacks::Notion.expects(:delete).with { |path, _| path == "/blocks/b1" }
                  .returns(fake_response(code: 200, body: { object: "block", id: "b1" }))
    Stacks::Notion.new.delete_block("b1")
  end

  test "429 sleeps for Retry-After then retries, honouring the cap" do
    client = Stacks::Notion.new(max_retries: 1, retry_after_cap: 3)
    Stacks::Notion.stubs(:get)
                  .returns(fake_response(code: 429, body: { object: "error", code: "rate_limited" }, headers: { "retry-after" => "9" }))
                  .then.returns(fake_response(code: 200, body: { object: "page", id: "p1" }))
    client.expects(:sleep).with(3)
    assert_equal "p1", client.get_page("p1")["id"]
  end

  test "429 beyond max_retries raises RateLimited carrying retry_after and the body" do
    client = Stacks::Notion.new(max_retries: 0)
    Stacks::Notion.stubs(:get).returns(fake_response(code: 429, body: { object: "error", code: "rate_limited" }, headers: { "retry-after" => "7" }))
    err = assert_raises(Stacks::Notion::RateLimited) { client.get_page("p1") }
    assert_equal 7, err.retry_after
    assert_equal 429, err.code
    assert_equal "rate_limited", err.body["code"]
  end

  test "529 is treated like 429" do
    client = Stacks::Notion.new(max_retries: 1, retry_after_cap: 60)
    Stacks::Notion.stubs(:get)
                  .returns(fake_response(code: 529, body: { object: "error", code: "service_overload" }))
                  .then.returns(fake_response(code: 200, body: { object: "page", id: "p1" }))
    client.expects(:sleep).with(2) # default when Retry-After absent
    client.get_page("p1")
  end

  test "5xx retries GET with backoff but not POST" do
    client = Stacks::Notion.new(max_retries: 2)
    Stacks::Notion.stubs(:get)
                  .returns(fake_response(code: 502, body: { object: "error" }))
                  .then.returns(fake_response(code: 200, body: { object: "page", id: "p1" }))
    client.expects(:sleep).with(1)
    client.get_page("p1")

    Stacks::Notion.stubs(:post).returns(fake_response(code: 502, body: { object: "error", code: "internal" }))
    client.expects(:sleep).never
    err = assert_raises(Stacks::Notion::RequestError) { client.search({}) }
    assert_equal 502, err.code
  end

  test "4xx other than 429 raises RequestError immediately with headers" do
    Stacks::Notion.stubs(:get).returns(fake_response(code: 404, body: { object: "error", code: "object_not_found" }, headers: { "content-type" => "application/json" }))
    err = assert_raises(Stacks::Notion::RequestError) { Stacks::Notion.new.get_page("nope") }
    assert_equal 404, err.code
    assert_equal "object_not_found", err.body["code"]
    assert_equal "application/json", err.headers["content-type"]
  end

  test "pacer is class-level and spaces request starts by 1/rps across instances" do
    ENV["NOTION_RPS"] = "10" # 100ms slots
    Stacks::Notion.reset_pacer!
    Stacks::Notion.stubs(:get).returns(fake_response(code: 200, body: { object: "page", id: "p" }))
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    3.times { Stacks::Notion.new.get_page("p") }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    assert_operator elapsed, :>=, 0.19, "three requests at 10 rps need ≥ 2 slots of spacing"
  end

  test "Retry-After survives HTTParty's Net::HTTPHeader (array values)" do
    hdrs = HTTParty::Response::Headers.new({ "Retry-After" => "9" })
    client = Stacks::Notion.new(max_retries: 0)
    Stacks::Notion.stubs(:get).returns(fake_response(code: 429, body: { object: "error" }, headers: hdrs))
    err = assert_raises(Stacks::Notion::RateLimited) { client.get_page("p") }
    assert_equal 9, err.retry_after
    assert_equal "9", err.headers["retry-after"]
  end

  test "a Retry-After sleep does not consume pacer slots (sleep happens outside the pacer)" do
    client = Stacks::Notion.new(max_retries: 1, retry_after_cap: 60)
    Stacks::Notion.stubs(:get)
                  .returns(fake_response(code: 429, body: { object: "error" }, headers: { "retry-after" => "1" }))
                  .then.returns(fake_response(code: 200, body: { object: "page", id: "p" }))
    client.expects(:sleep).with(1)
    Stacks::Notion.expects(:pace!).twice # one slot per attempt, none for the cooldown
    client.get_page("p")
  end

  test "a transport timeout on a GET retries once then raises a Notion-shaped 503" do
    client = Stacks::Notion.new(max_retries: 1)
    Stacks::Notion.stubs(:get).raises(Net::ReadTimeout).then.raises(Net::ReadTimeout)
    client.expects(:sleep).with(1)
    err = assert_raises(Stacks::Notion::RequestError) { client.get_page("p1") }
    assert_equal 503, err.code
    assert_equal "service_unavailable", err.body["code"]
    assert_match(/Net::ReadTimeout/, err.body["message"])
  end

  test "a transport failure on a POST is a 503 with no retry" do
    client = Stacks::Notion.new(max_retries: 3)
    Stacks::Notion.stubs(:post).raises(Errno::ECONNREFUSED)
    client.expects(:sleep).never
    err = assert_raises(Stacks::Notion::RequestError) { client.search({}) }
    assert_equal 503, err.code
    assert_equal "service_unavailable", err.body["code"]
  end

  test "max_wait fails fast with a synthetic 429 instead of parking on a saturated pacer" do
    ENV["NOTION_RPS"] = "0.1" # 10s slots
    Stacks::Notion.reset_pacer!
    Stacks::Notion.stubs(:get).returns(fake_response(code: 200, body: { object: "page", id: "p" }))
    Stacks::Notion.new.get_page("p") # claims the slot; the next one is 10s out
    Stacks::Notion.unstub(:get)

    client = Stacks::Notion.new(max_wait: 1, max_retries: 1, retry_after_cap: 6)
    client.expects(:sleep).never   # the synthetic 429 must not sleep out its own backlog
    Stacks::Notion.expects(:get).never
    err = assert_raises(Stacks::Notion::RateLimited) { client.get_page("p") }
    assert_equal 429, err.code
    assert_equal "rate_limited", err.body["code"]
    assert err.synthetic?
    assert_operator err.retry_after, :>=, 1
  end

  test "a saturated slot is not claimed, so the pacer stays available for the next caller" do
    ENV["NOTION_RPS"] = "0.1"
    Stacks::Notion.reset_pacer!
    assert_nil Stacks::Notion.pace!(max_wait: 5)
    kind, wait = Stacks::Notion.pace!(max_wait: 1)
    assert_equal :saturated, kind
    assert_operator wait, :>, 1
    # Unchanged next slot: a second saturated caller sees the same wait, not a longer one.
    _kind2, wait2 = Stacks::Notion.pace!(max_wait: 1)
    assert_operator wait2, :<=, wait
  end
end
