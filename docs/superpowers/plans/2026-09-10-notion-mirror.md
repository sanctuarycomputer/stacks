# Notion Mirror Implementation Plan (phases 1 + 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Stacks a one-to-one caching reverse proxy of Notion's REST API (plus three MCP tools mirroring Notion's MCP), backed by tables that mirror Notion's objects, kept fresh by a 10-minute sweep, with a live parity test proving proxy responses equal Notion's.

**Architecture:** The existing `Stacks::Notion` HTTParty client is upgraded (version `2026-03-11`, class-level pacer, Retry-After handling). `Stacks::Notion::Mirror` upserts raw Notion objects into `notion_pages` / `notion_blocks` / `notion_data_sources` / `notion_databases`. `Api::Notion::ProxyController` serves `/api/notion/v1/*` from the mirror and fills on miss. `Stacks::Notion::Sweep` walks `POST /search` by `last_edited_time` every 10 minutes and refreshes stale block trees. Spec: `docs/superpowers/specs/2026-09-10-notion-mirror-design.md`. Phase 3 (webhook, corpus connector) is a separate plan.

**Tech Stack:** Rails 6.1, Ruby 3.1.7, Postgres, HTTParty, minitest + mocha, rake + Heroku Scheduler + `SystemTask` + `SourceSync`. No new gems.

## Global Constraints

- Work ONLY in the worktree `/Users/hhff/Documents/Code/stacks/.claude/worktrees/notion-read-cache` on branch `worktree-notion-read-cache`. Before every commit run `git rev-parse --abbrev-ref HEAD`; if it does not print `worktree-notion-read-cache`, STOP and report BLOCKED.
- `Notion-Version` is exactly `2026-03-11`. Database rows have `parent: {type: "data_source_id", data_source_id, database_id}`; `in_trash` not `archived`; queries are `POST /v1/data_sources/:id/query`.
- Every Notion id is stored and looked up in dashed-uuid form via `Stacks::Notion::Ids.normalize`.
- `db/schema.rb` is hand-curated. After `bin/rails db:migrate`, run `git diff db/schema.rb` and revert every hunk that is not your own table/column/index/version change (pgvector, `content_tsv`, and the trigger are deliberately absent). Never `db:schema:dump`.
- Test commands: `bin/rails test test/path/to/file_test.rb` (one file) — never wrap in `$(...)`. Full suite: `bin/rails test --exclude "/EtlRakeTest/"` (the excluded test opens a live Google connection). Check `ps -o pid,etime,command -ax | grep "[r]ails test"` first; never run the suite while another `rails test` process exists.
- The test DB uses the `localhost:3000` credentials block (`Stacks::Utils.config`), which holds `notion.token` and `stacks.private_api_key`. Unit tests must stub HTTP (`Stacks::Notion.stubs(:get)` / `.stubs(:post)` or `client.stubs(:get_page)`), never hit the network. Only `test/live/notion_parity_test.rb` may, and only under `NOTION_LIVE=1`.
- All new code paces through `Stacks::Notion`; nothing else calls api.notion.com.
- Commit messages: conventional style (`feat:`, `fix:`, `test:`, `docs:`), each ending with
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01LWRCs8SgcVwVQBNTQEP59V`.
- Existing tests that must keep passing unchanged: `test/lib/stacks/notion/lead_test.rb`, `test/lib/stacks/notion/human_operating_manual_test.rb`, `test/lib/stacks/task_builder/discoveries/notion_leads_test.rb`, `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb`, `test/lib/stacks/task_builder/human_operating_manual_hydration_test.rb`, `test/services/mcp/explore_okr_tool_test.rb`.

## File map

| File | Responsibility |
| --- | --- |
| `lib/stacks/notion/ids.rb` | `Ids.normalize(id)` → dashed uuid or nil |
| `lib/stacks/notion.rb` | existing client: version, `request`, pacer, retries, endpoints, `sync_database` |
| `db/migrate/20260910*_extend_notion_pages_for_mirror.rb`, `..._create_notion_blocks.rb`, `..._create_notion_data_sources.rb`, `..._create_notion_databases.rb` | schema |
| `app/models/notion_page.rb`, `notion_block.rb`, `notion_data_source.rb`, `notion_database.rb` | models |
| `lib/stacks/notion/mirror.rb` | `upsert_page`, `upsert_data_source`, `upsert_database`, `replace_level`, `owning_page_id` |
| `lib/stacks/notion/tree_fetcher.rb` | level walks with deadline; markers; `recheck_after` |
| `lib/stacks/notion/sweep.rb`, `backfill.rb`, `reconcile.rb` | freshness tasks; shared `ADVISORY_LOCK_KEY` |
| `lib/stacks/notion/markdown.rb` | block tree → markdown (MCP `notion-fetch` only) |
| `app/controllers/api/notion/proxy_controller.rb` + `config/routes.rb` | REST proxy |
| `app/services/mcp/notion_fetch_tool.rb`, `notion_search_tool.rb`, `notion_query_data_sources_tool.rb`, `app/services/mcp/server.rb` | MCP tools |
| `lib/tasks/notion.rake` | `stacks:notion:sweep`, `backfill`, `reconcile`, `verify_parity` |
| `test/live/notion_parity_test.rb` | live parity (skips unless `NOTION_LIVE=1`) |
| `docs/notion-mirror-deploy.md` | env vars, Scheduler entries, deploy order |

---

### Task 1: Id normalization

**Files:**
- Create: `lib/stacks/notion/ids.rb`
- Test: `test/lib/stacks/notion/ids_test.rb`

**Interfaces:**
- Produces: `Stacks::Notion::Ids.normalize(id) → String (dashed uuid) | nil`; `Stacks::Notion::Ids.valid?(id) → Boolean`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/notion/ids_test.rb
require 'test_helper'

class StacksNotionIdsTest < ActiveSupport::TestCase
  DASHED = "4d9b46b8-bad5-4250-9f14-4347db37964d"

  test "normalize keeps a dashed uuid" do
    assert_equal DASHED, Stacks::Notion::Ids.normalize(DASHED)
  end

  test "normalize dashes a 32-hex id" do
    assert_equal DASHED, Stacks::Notion::Ids.normalize("4d9b46b8bad542509f144347db37964d")
  end

  test "normalize downcases and strips whitespace" do
    assert_equal DASHED, Stacks::Notion::Ids.normalize("  4D9B46B8BAD542509F144347DB37964D ")
  end

  test "normalize returns nil for garbage or nil" do
    assert_nil Stacks::Notion::Ids.normalize(nil)
    assert_nil Stacks::Notion::Ids.normalize("not-an-id")
    assert_nil Stacks::Notion::Ids.normalize("4d9b46b8bad542509f144347db3796")
  end

  test "valid? mirrors normalize" do
    assert Stacks::Notion::Ids.valid?(DASHED)
    refute Stacks::Notion::Ids.valid?("zzz")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/stacks/notion/ids_test.rb`
Expected: `NameError: uninitialized constant Stacks::Notion::Ids`

- [ ] **Step 3: Implement**

```ruby
# lib/stacks/notion/ids.rb
# Notion ids arrive dashed (API bodies) or as 32 hex chars (URLs, ntn, DATABASE_IDS).
# The mirror stores and looks up the dashed form everywhere.
module Stacks::Notion::Ids
  HEX32 = /\A[0-9a-f]{32}\z/.freeze

  def self.normalize(id)
    return nil if id.nil?
    hex = id.to_s.strip.downcase.delete("-")
    return nil unless hex.match?(HEX32)
    hex.unpack("A8 A4 A4 A4 A12").join("-")
  end

  def self.valid?(id)
    !normalize(id).nil?
  end
end
```

- [ ] **Step 4: Run the test**

Run: `bin/rails test test/lib/stacks/notion/ids_test.rb`
Expected: `5 runs, 7 assertions, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/notion/ids.rb test/lib/stacks/notion/ids_test.rb
git commit -m "feat: Stacks::Notion::Ids.normalize — one dashed id form for the mirror"
```

---

### Task 2: Upgrade the `Stacks::Notion` client (version, pacer, retries, endpoints)

**Files:**
- Modify: `lib/stacks/notion.rb` (whole file replaced except `DATABASE_IDS` and `sync_database`, which Task 5 rewrites)
- Test: `test/lib/stacks/notion_test.rb`

**Interfaces:**
- Produces: `Stacks::Notion.new(max_retries: 3, retry_after_cap: 60)`; instance methods `get_page(id)`, `get_block(id)`, `get_block_children(id, start_cursor: nil, page_size: 100)`, `get_database(id)`, `get_data_source(id)`, `query_data_source(id, body = {})`, `search(body = {})`, `create_page(body)`, `update_page(id, body)`, `append_block_children(id, body)`, `update_block(id, body)`, `delete_block(id)`, `get_users` — each returns the **parsed Hash** body on 2xx and raises otherwise; `Stacks::Notion::RequestError#code/#body/#headers`; `Stacks::Notion::RateLimited < RequestError` with `#retry_after` (Integer seconds); `Stacks::Notion::NOTION_VERSION`; class-level `Stacks::Notion.rps` (Float, from `ENV["NOTION_RPS"]`, default 0.6) and `Stacks::Notion.reset_pacer!` (tests).
- Consumes: nothing new. Existing callers `Stacks::Notifications#notion` and `stacks:sync_notion` (Task 5) keep working.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/lib/stacks/notion_test.rb
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
    ENV["NOTION_RPS"] = @saved_rps # restore, never delete: test_helper sets a process-wide default
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
end
```

Also add to `test/test_helper.rb`, right after `require 'minitest/autorun'`, so no test that reaches an un-stubbed client path sleeps on the 0.6 rps default:

```ruby
# The Notion client paces requests per process (NOTION_RPS, default 0.6/s). Tests stub
# HTTP, so pacing is only latency here; individual tests override as needed.
ENV["NOTION_RPS"] ||= "1000"
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/stacks/notion_test.rb`
Expected: failures such as `NoMethodError: undefined method 'reset_pacer!'` / `ArgumentError: wrong number of arguments` for `Stacks::Notion.new(max_retries: …)`.

- [ ] **Step 3: Replace the client (keep `DATABASE_IDS`; leave `sync_database` in place for Task 5)**

Replace everything in `lib/stacks/notion.rb` above `def sync_database` with:

```ruby
require 'uri'

# Stacks' only Notion HTTP client. Every request goes through #request, which
# paces starts to NOTION_RPS per process and honours Retry-After on 429/529.
# Spec: docs/superpowers/specs/2026-09-10-notion-mirror-design.md
class Stacks::Notion
  include HTTParty
  base_uri 'https://api.notion.com/v1'

  NOTION_VERSION = "2026-03-11".freeze
  DEFAULT_RPS = 0.6
  RETRYABLE_5XX = [500, 502, 503, 504].freeze

  DATABASE_IDS = {
    LEADS: "4d9b46b8bad542509f144347db37964d",
    HUMAN_OPERATING_MANUALS: "5d59dcd95bfb458a9747ce7d6ce9e009"
  }

  class RequestError < StandardError
    attr_reader :code, :body, :headers

    def initialize(code, body, headers = {})
      @code = code.to_i
      @body = body.is_a?(Hash) ? body : (JSON.parse(body.to_s) rescue { "message" => body.to_s })
      # HTTParty::Response::Headers is a Net::HTTPHeader: to_h gives Array values.
      @headers = headers.to_h.each_with_object({}) do |(k, v), h|
        h[k.to_s.downcase] = v.is_a?(Array) ? v.first : v
      end
      super("Notion API #{@code}: #{@body['code'] || @body['message']}")
    end

    def rate_limited?
      [429, 529].include?(code)
    end
  end

  class RateLimited < RequestError
    # Integer seconds Notion asked us to wait (default 2 when absent).
    def retry_after
      raw = headers["retry-after"]
      raw.to_s =~ /\A\d+\z/ ? raw.to_i : 2
    end
  end

  # ---- class-level pacer -------------------------------------------------
  # One Mutex + next-slot timestamp per PROCESS, so the proxy (a client per
  # request) and the sweep (one client) share the same spacing. The slot is
  # claimed under the mutex; the sleep happens outside it.
  @pacer_mutex = Mutex.new
  @next_slot = 0.0

  class << self
    def rps
      Float(ENV.fetch("NOTION_RPS", DEFAULT_RPS))
    end

    def reset_pacer!
      @pacer_mutex.synchronize { @next_slot = 0.0 }
    end

    def pace!
      interval = 1.0 / rps
      wait = @pacer_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        start_at = [now, @next_slot].max
        @next_slot = start_at + interval
        start_at - now
      end
      sleep(wait) if wait.positive?
    end
  end

  def initialize(max_retries: 3, retry_after_cap: 60)
    @max_retries = max_retries
    @retry_after_cap = retry_after_cap
    @headers = {
      "Authorization" => "Bearer #{Stacks::Utils.config[:notion][:token]}",
      "Notion-Version" => NOTION_VERSION,
      "Content-Type" => "application/json"
    }
  end

  # ---- endpoints (all return the parsed body Hash) ------------------------
  def get_users = request(:get, "/users")
  def get_page(page_id) = request(:get, "/pages/#{page_id}")
  def get_block(block_id) = request(:get, "/blocks/#{block_id}")

  def get_block_children(block_id, start_cursor: nil, page_size: 100)
    query = { page_size: page_size }
    query[:start_cursor] = start_cursor if start_cursor.present?
    request(:get, "/blocks/#{block_id}/children", query: query)
  end

  def get_database(database_id) = request(:get, "/databases/#{database_id}")
  def get_data_source(data_source_id) = request(:get, "/data_sources/#{data_source_id}")
  def query_data_source(data_source_id, body = {}) = request(:post, "/data_sources/#{data_source_id}/query", body: body)
  def search(body = {}) = request(:post, "/search", body: body)
  def create_page(body) = request(:post, "/pages", body: body)
  def update_page(page_id, body) = request(:patch, "/pages/#{page_id}", body: body)
  def append_block_children(block_id, body) = request(:patch, "/blocks/#{block_id}/children", body: body)
  def update_block(block_id, body) = request(:patch, "/blocks/#{block_id}", body: body)
  def delete_block(block_id) = request(:delete, "/blocks/#{block_id}")

  # Back-compat for callers that resolved rows by database id.
  def query_database_all(database_id)
    ds_id = get_database(database_id).dig("data_sources", 0, "id")
    results = []
    cursor = nil
    loop do
      page = query_data_source(ds_id, cursor ? { start_cursor: cursor } : {})
      results.concat(page["results"])
      cursor = page["next_cursor"]
      break if cursor.nil?
    end
    results
  end

  private

  def request(method, path, body: nil, query: nil)
    attempt = 0
    begin
      self.class.pace!
      opts = { headers: @headers }
      opts[:query] = query if query
      opts[:body] = body.to_json if body
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = self.class.public_send(method, path, opts)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.logger.info("[Stacks::Notion] #{method.to_s.upcase} #{path} #{response.code} #{ms}ms#{" retry_after=#{response.headers['retry-after']}" if response.code == 429}")
      return response.parsed_response if response.success?

      raise (response.code == 429 || response.code == 529 ? RateLimited : RequestError).new(response.code, response.parsed_response, response.headers)
    rescue RateLimited => e
      raise e if attempt >= @max_retries
      attempt += 1
      sleep([e.retry_after, @retry_after_cap].min)
      retry
    rescue RequestError => e
      raise e unless method == :get && RETRYABLE_5XX.include?(e.code) && attempt < @max_retries
      attempt += 1
      sleep(2**(attempt - 1))
      retry
    end
  end

  public
```

Keep the existing `def sync_database(database_id) … end` and the closing `end` of the class below the `public` line; Task 5 rewrites `sync_database` (and removes `query_database`, `get_users`' old body, and the `create_database` method — delete `create_database` now, nothing calls it).

- [ ] **Step 4: Run the client tests**

Run: `bin/rails test test/lib/stacks/notion_test.rb`
Expected: `12 runs, 0 failures`. The pacer test needs real time (about 0.2 s).

The pacer's structural guarantee (slot claimed under the mutex, sleep outside it, Retry-After sleep never inside `synchronize`) is enforced by the code shape in `pace!` and `request`; keep the comment there.

- [ ] **Step 5: Check existing consumers still load**

Run: `bin/rails test test/lib/stacks/notion/lead_test.rb test/lib/stacks/notion/human_operating_manual_test.rb test/lib/stacks/notifications_test.rb`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/notion.rb test/lib/stacks/notion_test.rb test/test_helper.rb
git commit -m "feat: Stacks::Notion on Notion-Version 2026-03-11 with class-level pacer and Retry-After handling"
```

---

### Task 3: Schema — extend `notion_pages`, add blocks / data sources / databases; model changes

**Files:**
- Create: `db/migrate/20260910100000_extend_notion_pages_for_mirror.rb`, `db/migrate/20260910100001_create_notion_blocks.rb`, `db/migrate/20260910100002_create_notion_data_sources.rb`, `db/migrate/20260910100003_create_notion_databases.rb`
- Modify: `db/schema.rb` (hand-edit: version + the four tables), `app/models/notion_page.rb`
- Create: `app/models/notion_block.rb`, `app/models/notion_data_source.rb`, `app/models/notion_database.rb`
- Test: `test/models/notion_page_test.rb`

**Interfaces:**
- Produces: `NotionPage` columns `database_id`, `data_source_id`, `notion_last_edited_at`, `page_fetched_at`, `root_children_fetched_at`, `tree_fetched_for_edited_at`, `blocks_stale_at`, `recheck_after`, `wanted_at`, `in_trash`, `access_lost`, `url`; scopes `NotionPage.lead`, `.human_operating_manual` on `database_id` + `in_trash: false`; `NotionPage.for_database(dashed_id)`; `NotionBlock(notion_id, parent_id, page_id, position, has_children, children_fetched_at, data)` with scope `children_of(parent_id)`; `NotionDataSource(notion_id, database_id, title, data, notion_last_edited_at, fetched_at, in_trash)`; `NotionDatabase(notion_id, title, data, notion_last_edited_at, fetched_at, in_trash)`.

- [ ] **Step 1: Write the failing model test**

```ruby
# test/models/notion_page_test.rb
require 'test_helper'

class NotionPageTest < ActiveSupport::TestCase
  LEADS_DB = Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])

  def page!(database_id:, in_trash: false, deleted: false, **attrs)
    p = NotionPage.create!({ notion_id: SecureRandom.uuid, database_id: database_id, in_trash: in_trash,
                             data: { "properties" => {} } }.merge(attrs))
    p.destroy if deleted
    p
  end

  test "lead scope selects by database_id and excludes trashed and soft-deleted rows" do
    live = page!(database_id: LEADS_DB)
    page!(database_id: LEADS_DB, in_trash: true)
    page!(database_id: LEADS_DB, deleted: true)
    page!(database_id: SecureRandom.uuid)
    assert_equal [live.id], NotionPage.lead.pluck(:id)
  end

  test "human_operating_manual scope selects by database_id" do
    hom = page!(database_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:HUMAN_OPERATING_MANUALS]))
    assert_equal [hom.id], NotionPage.human_operating_manual.pluck(:id)
  end

  test "created_at is nil-safe when data has no created_time" do
    p = page!(database_id: LEADS_DB)
    assert_nil p.created_at
    p.update!(data: { "created_time" => "2024-01-02T03:04:00.000Z" })
    assert_equal DateTime.parse("2024-01-02T03:04:00.000Z"), p.created_at
  end

  test "Stacks::Notion::Lead.all uses the lead scope" do
    page!(database_id: LEADS_DB)
    assert_equal 1, Stacks::Notion::Lead.all.size
    assert_kind_of Stacks::Notion::Lead, Stacks::Notion::Lead.all.first
  end

  test "status_history is gone" do
    refute NotionPage.new.respond_to?(:status_history)
  end

  test "new tables exist with unique notion_id" do
    NotionBlock.create!(notion_id: "b1", parent_id: "p1", page_id: "p1", position: 0, has_children: false, data: {})
    assert_raises(ActiveRecord::RecordNotUnique) { NotionBlock.create!(notion_id: "b1", parent_id: "p1", page_id: "p1", position: 1, has_children: false, data: {}) }
    NotionDataSource.create!(notion_id: "ds1", database_id: "db1", title: "T", data: {})
    NotionDatabase.create!(notion_id: "db1", title: "T", data: {})
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/notion_page_test.rb`
Expected: errors about unknown attribute `database_id` / uninitialized constant `NotionBlock`.

- [ ] **Step 3: Write the migrations**

```ruby
# db/migrate/20260910100000_extend_notion_pages_for_mirror.rb
class ExtendNotionPagesForMirror < ActiveRecord::Migration[6.1]
  def up
    change_table :notion_pages do |t|
      t.string   :database_id
      t.string   :data_source_id
      t.datetime :notion_last_edited_at
      t.datetime :page_fetched_at
      t.datetime :root_children_fetched_at
      t.datetime :tree_fetched_for_edited_at
      t.datetime :blocks_stale_at
      t.datetime :recheck_after
      t.datetime :wanted_at
      t.boolean  :in_trash, null: false, default: false
      t.boolean  :access_lost, null: false, default: false
      t.string   :url
    end
    add_index :notion_pages, :database_id
    add_index :notion_pages, :data_source_id
    add_index :notion_pages, :notion_last_edited_at
    add_index :notion_pages, :blocks_stale_at, where: "blocks_stale_at IS NOT NULL"
    add_index :notion_pages, :recheck_after, where: "recheck_after IS NOT NULL"
    add_index :notion_pages, :wanted_at, where: "wanted_at IS NOT NULL"

    # Existing rows are all database rows with dashed parent ids (verified 2026-09-10).
    execute <<~SQL
      UPDATE notion_pages
         SET database_id = notion_parent_id
       WHERE notion_parent_type = 'database_id' AND database_id IS NULL
    SQL
    execute <<~SQL
      UPDATE notion_pages
         SET notion_last_edited_at = (data->>'last_edited_time')::timestamptz,
             url = data->>'url',
             in_trash = COALESCE((data->>'in_trash')::boolean, false)
       WHERE data ? 'last_edited_time'
    SQL
    # The old sync stored only the first rich-text run of the title; join every run.
    execute <<~SQL
      UPDATE notion_pages p
         SET page_title = COALESCE((
               SELECT string_agg(run->>'plain_text', '' ORDER BY ord)
                 FROM jsonb_each(p.data->'properties') AS props(key, val),
                      jsonb_array_elements(val->'title') WITH ORDINALITY AS t(run, ord)
                WHERE val->>'type' = 'title'
             ), p.page_title)
       WHERE p.data ? 'properties'
    SQL
  end

  def down
    remove_index :notion_pages, :database_id
    remove_index :notion_pages, :data_source_id
    remove_index :notion_pages, :notion_last_edited_at
    remove_index :notion_pages, :blocks_stale_at
    remove_index :notion_pages, :recheck_after
    remove_index :notion_pages, :wanted_at
    remove_columns :notion_pages, :database_id, :data_source_id, :notion_last_edited_at, :page_fetched_at,
                   :root_children_fetched_at, :tree_fetched_for_edited_at, :blocks_stale_at, :recheck_after,
                   :wanted_at, :in_trash, :access_lost, :url
  end
end
```

```ruby
# db/migrate/20260910100001_create_notion_blocks.rb
class CreateNotionBlocks < ActiveRecord::Migration[6.1]
  def change
    create_table :notion_blocks do |t|
      t.string   :notion_id, null: false
      t.string   :parent_id, null: false
      t.string   :page_id, null: false
      t.integer  :position, null: false
      t.boolean  :has_children, null: false, default: false
      t.datetime :children_fetched_at
      t.jsonb    :data, null: false, default: {}
      t.timestamps
    end
    add_index :notion_blocks, :notion_id, unique: true
    add_index :notion_blocks, [:parent_id, :position]
    add_index :notion_blocks, :page_id
  end
end
```

```ruby
# db/migrate/20260910100002_create_notion_data_sources.rb
class CreateNotionDataSources < ActiveRecord::Migration[6.1]
  def change
    create_table :notion_data_sources do |t|
      t.string   :notion_id, null: false
      t.string   :database_id
      t.string   :title, null: false, default: ""
      t.jsonb    :data, null: false, default: {}
      t.datetime :notion_last_edited_at
      t.datetime :fetched_at
      t.boolean  :in_trash, null: false, default: false
      t.timestamps
    end
    add_index :notion_data_sources, :notion_id, unique: true
    add_index :notion_data_sources, :database_id
  end
end
```

```ruby
# db/migrate/20260910100003_create_notion_databases.rb
class CreateNotionDatabases < ActiveRecord::Migration[6.1]
  def change
    create_table :notion_databases do |t|
      t.string   :notion_id, null: false
      t.string   :title, null: false, default: ""
      t.jsonb    :data, null: false, default: {}
      t.datetime :notion_last_edited_at
      t.datetime :fetched_at
      t.boolean  :in_trash, null: false, default: false
      t.timestamps
    end
    add_index :notion_databases, :notion_id, unique: true
  end
end
```

- [ ] **Step 4: Migrate, then hand-fix `db/schema.rb`**

Run: `bin/rails db:migrate` then `RAILS_ENV=test bin/rails db:migrate`
Then: `git diff db/schema.rb`. Keep ONLY: the `version:` bump to `2026_09_10_100003`, the new `notion_pages` columns/indexes, and the three new `create_table` blocks. Revert every other hunk (`git checkout -p db/schema.rb` on unrelated hunks). Confirm with `git diff --stat db/schema.rb` that the diff is small and that `grep -c "create_table" db/schema.rb` grew by exactly 3.

- [ ] **Step 5: Update `NotionPage` and add the three models**

Replace `app/models/notion_page.rb` with:

```ruby
class NotionPage < ApplicationRecord
  acts_as_paranoid

  # Rows of a Notion database, by dashed database id. in_trash rows are kept
  # (served one-to-one by the proxy) but are not "in" the database for Stacks.
  scope :for_database, ->(dashed_database_id) { where(database_id: dashed_database_id, in_trash: false) }

  scope :lead, -> { for_database(Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])) }
  scope :human_operating_manual, -> { for_database(Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:HUMAN_OPERATING_MANUALS])) }

  def as_lead
    Stacks::Notion::Lead.new(self)
  end

  def as_human_operating_manual
    Stacks::Notion::HumanOperatingManual.new(self)
  end

  def notion_link
    "https://www.notion.so/garden3d/#{notion_id.gsub('-', '')}"
  end

  def external_link
    notion_link
  end

  # For active admin to set the title on the show page
  def name
    page_title
  end

  def get_prop(name)
    prop_type = data.dig("properties", name, "type")
    data.dig("properties", name, prop_type)
  end

  # Notion's created_time when present; nil otherwise (notion_pages has no
  # created_at column, so there is nothing to fall back to).
  def created_at
    created_time = data.is_a?(Hash) ? data["created_time"] : nil
    created_time.present? ? DateTime.parse(created_time) : nil
  end
end
```

In `lib/stacks/notion/lead.rb`, replace the `all` class method (it still queries the old parent pair, which the new API version never writes) with:

```ruby
  class << self
    def all
      NotionPage.lead.map(&:as_lead)
    end
  end
```

```ruby
# app/models/notion_block.rb
# One row per Notion block, raw object in `data`. Children of X are
# where(parent_id: X).order(:position). page_id is the root page, for invalidation.
class NotionBlock < ApplicationRecord
  scope :children_of, ->(parent_id) { where(parent_id: parent_id).order(:position) }
end
```

```ruby
# app/models/notion_data_source.rb
class NotionDataSource < ApplicationRecord
end
```

```ruby
# app/models/notion_database.rb
class NotionDatabase < ApplicationRecord
end
```

- [ ] **Step 6: Run the model test and every existing Notion consumer test**

Run: `bin/rails test test/models/notion_page_test.rb test/lib/stacks/notion/lead_test.rb test/lib/stacks/notion/human_operating_manual_test.rb test/lib/stacks/task_builder/discoveries/notion_leads_test.rb test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb test/lib/stacks/task_builder/human_operating_manual_hydration_test.rb test/services/mcp/explore_okr_tool_test.rb`
Expected: all pass. If a test fails because its helper creates rows with `notion_parent_type: 'database_id', notion_parent_id: …` but no `database_id`, that helper is the ONE kind of change allowed in existing tests: add `database_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])` (or `[:HUMAN_OPERATING_MANUALS]`) to its `NotionPage.create!` call. Change nothing else in those files.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/notion_page.rb app/models/notion_block.rb app/models/notion_data_source.rb app/models/notion_database.rb lib/stacks/notion/lead.rb test/models/notion_page_test.rb test/services/mcp/explore_okr_tool_test.rb test/lib/stacks/task_builder
git commit -m "feat: mirror schema — extend notion_pages, add notion_blocks/data_sources/databases; scopes on database_id"
```

---

### Task 4: `Stacks::Notion::Mirror` — upserts from raw Notion objects

**Files:**
- Create: `lib/stacks/notion/mirror.rb`
- Test: `test/lib/stacks/notion/mirror_test.rb`

**Interfaces:**
- Consumes: `Stacks::Notion::Ids.normalize` (Task 1); models (Task 3).
- Produces:
  - `Stacks::Notion::Mirror.upsert_page(obj, fetched_at: Time.current) → NotionPage` — `obj` is a Notion page Hash from GET, search, or query. Strips `request_id`/`request_status`. Looks up `with_deleted`. Recovers a soft-deleted row iff `obj["in_trash"] == false`. Never moves `notion_last_edited_at` backwards (returns the row untouched if the incoming stamp is older). Sets `blocks_stale_at` when `tree_fetched_for_edited_at` is set and differs from the new stamp.
  - `Stacks::Notion::Mirror.upsert_data_source(obj, fetched_at:) → NotionDataSource`, `.upsert_database(obj, fetched_at:) → NotionDatabase`.
  - `Stacks::Notion::Mirror.replace_level(parent_id:, page_id:, blocks:, fetched_at:) → Array<NotionBlock>` — `blocks` is the concatenated `results` of a full level walk; deletes rows `where(parent_id:)` not in the new set, upserts the rest by `notion_id` (updating `parent_id`/`position` in place), in one transaction; stamps the marker (`root_children_fetched_at` on the page when `parent_id == page_id`, else `children_fetched_at` on the parent block).
  - `Stacks::Notion::Mirror.store_blocks(parent_id:, page_id:, blocks:, position_offset:)` — upsert without deleting or stamping (for a single live cursor page).
  - `Stacks::Notion::Mirror.title_of(obj) → String` (all rich-text runs joined; `""` when absent).
  - `Stacks::Notion::Mirror.owning_page_id(block_or_page_id) → String | nil` — the dashed page id for a cached page or block id.
  - `Stacks::Notion::Mirror.strip(obj) → Hash` — deep-dup minus `request_id`/`request_status`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/lib/stacks/notion/mirror_test.rb
require 'test_helper'

class StacksNotionMirrorTest < ActiveSupport::TestCase
  M = Stacks::Notion::Mirror
  PAGE_ID = "3d6131fe-a2c7-8068-ac6e-d49df344d405"
  DS_ID   = "e5d5d0da-a85e-4b3f-b900-9fd06a315622"
  DB_ID   = "438196be-db11-412e-b8e7-37bc1bd75b2b"

  def page_obj(last_edited: "2026-09-10T21:55:00.000Z", in_trash: false, request_id: "req-1", title_runs: ["In 2024, ", "xxix.co Better"])
    {
      "object" => "page", "id" => PAGE_ID, "created_time" => "2026-09-01T00:00:00.000Z",
      "last_edited_time" => last_edited, "in_trash" => in_trash, "is_archived" => false, "is_locked" => false,
      "parent" => { "type" => "data_source_id", "data_source_id" => DS_ID, "database_id" => DB_ID },
      "properties" => { "Name" => { "id" => "title", "type" => "title", "title" => title_runs.map { |t| { "plain_text" => t } } } },
      "url" => "https://www.notion.so/x-#{PAGE_ID.delete('-')}", "public_url" => nil,
      "request_id" => request_id
    }.compact
  end

  test "upsert_page stores the raw object minus request_id and fills the lookup columns" do
    page = M.upsert_page(page_obj, fetched_at: Time.zone.parse("2026-09-10T22:00:00Z"))
    assert_equal PAGE_ID, page.notion_id
    assert_equal DB_ID, page.database_id
    assert_equal DS_ID, page.data_source_id
    assert_equal "data_source_id", page.notion_parent_type
    assert_equal DS_ID, page.notion_parent_id
    assert_equal Time.zone.parse("2026-09-10T21:55:00Z"), page.notion_last_edited_at
    assert_equal "In 2024, xxix.co Better", page.page_title
    assert_equal "https://www.notion.so/x-#{PAGE_ID.delete('-')}", page.url
    refute page.data.key?("request_id")
    assert_equal Time.zone.parse("2026-09-10T22:00:00Z"), page.page_fetched_at
    refute page.in_trash
  end

  test "a search-result object (no request_id) and a GET object land on the same row" do
    a = M.upsert_page(page_obj(request_id: nil))
    b = M.upsert_page(page_obj(request_id: "req-9"))
    assert_equal a.id, b.id
    assert_equal 1, NotionPage.with_deleted.where(notion_id: PAGE_ID).count
    assert_equal a.data, b.reload.data
  end

  test "an older last_edited_time never moves the row backwards" do
    M.upsert_page(page_obj(last_edited: "2026-09-10T21:55:00.000Z"))
    page = M.upsert_page(page_obj(last_edited: "2026-09-10T21:50:00.000Z", title_runs: ["old"]))
    assert_equal "In 2024, xxix.co Better", page.page_title
    assert_equal Time.zone.parse("2026-09-10T21:55:00Z"), page.notion_last_edited_at
  end

  test "a soft-deleted row is found with_deleted and recovered only when in_trash is false" do
    M.upsert_page(page_obj).destroy
    trashed = M.upsert_page(page_obj(in_trash: true, last_edited: "2026-09-10T22:00:00.000Z"))
    assert trashed.deleted?
    assert trashed.in_trash
    live = M.upsert_page(page_obj(in_trash: false, last_edited: "2026-09-10T22:05:00.000Z"))
    refute live.deleted?
    refute live.in_trash
  end

  test "a newer stamp marks a walked tree stale" do
    page = M.upsert_page(page_obj)
    page.update!(tree_fetched_for_edited_at: page.notion_last_edited_at)
    M.upsert_page(page_obj(last_edited: "2026-09-10T22:10:00.000Z"))
    assert page.reload.blocks_stale_at.present?
    # same stamp again: not re-flagged after it was cleared
    page.update!(blocks_stale_at: nil, tree_fetched_for_edited_at: Time.zone.parse("2026-09-10T22:10:00Z"))
    M.upsert_page(page_obj(last_edited: "2026-09-10T22:10:00.000Z"))
    assert_nil page.reload.blocks_stale_at
  end

  test "title_of handles plain pages, missing titles, and nil runs" do
    assert_equal "Guide", M.title_of("properties" => { "title" => { "type" => "title", "title" => [{ "plain_text" => "Guide" }] } })
    assert_equal "", M.title_of("properties" => {})
    assert_equal "", M.title_of({})
    assert_equal "DS", M.title_of("object" => "data_source", "title" => [{ "plain_text" => "DS" }])
  end

  test "upsert_data_source and upsert_database" do
    ds = M.upsert_data_source({ "object" => "data_source", "id" => DS_ID, "title" => [{ "plain_text" => "Tasks" }],
                                "parent" => { "type" => "database_id", "database_id" => DB_ID },
                                "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false, "properties" => {}, "request_id" => "r" })
    assert_equal DB_ID, ds.database_id
    assert_equal "Tasks", ds.title
    refute ds.data.key?("request_id")
    db = M.upsert_database({ "object" => "database", "id" => DB_ID, "title" => [{ "plain_text" => "Tasks" }],
                             "data_sources" => [{ "id" => DS_ID, "name" => "Tasks" }], "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false })
    assert_equal "Tasks", db.title
    assert_equal DS_ID, db.data.dig("data_sources", 0, "id")
  end

  def block(id, parent, has_children: false)
    { "object" => "block", "id" => id, "type" => "paragraph", "has_children" => has_children,
      "parent" => { "type" => "page_id", "page_id" => parent }, "paragraph" => { "rich_text" => [] } }
  end

  test "replace_level replaces rows, updates moved blocks in place, and stamps the marker" do
    page = M.upsert_page(page_obj)
    M.replace_level(parent_id: PAGE_ID, page_id: PAGE_ID, blocks: [block("b1", PAGE_ID), block("b2", PAGE_ID, has_children: true)], fetched_at: Time.current)
    assert_equal %w[b1 b2], NotionBlock.children_of(PAGE_ID).pluck(:notion_id)
    assert page.reload.root_children_fetched_at.present?

    # b2 gains a child level; then b1 moves under b2 and b3 appears at root
    M.replace_level(parent_id: "b2", page_id: PAGE_ID, blocks: [block("b1", "b2")], fetched_at: Time.current)
    M.replace_level(parent_id: PAGE_ID, page_id: PAGE_ID, blocks: [block("b2", PAGE_ID, has_children: true), block("b3", PAGE_ID)], fetched_at: Time.current)
    assert_equal %w[b2 b3], NotionBlock.children_of(PAGE_ID).pluck(:notion_id)
    assert_equal %w[b1], NotionBlock.children_of("b2").pluck(:notion_id)
    assert NotionBlock.find_by(notion_id: "b2").children_fetched_at.present?
    assert_equal 3, NotionBlock.where(page_id: PAGE_ID).count
  end

  test "owning_page_id resolves pages and cached blocks, nil otherwise" do
    M.upsert_page(page_obj)
    M.replace_level(parent_id: PAGE_ID, page_id: PAGE_ID, blocks: [block("b1", PAGE_ID)], fetched_at: Time.current)
    assert_equal PAGE_ID, M.owning_page_id(PAGE_ID.delete("-"))
    assert_equal PAGE_ID, M.owning_page_id("b1")
    assert_nil M.owning_page_id("nope")
  end

  test "upsert_data_source with fetched_at: nil never clears an existing fetched_at" do
    obj = { "object" => "data_source", "id" => DS_ID, "title" => [], "parent" => {}, "properties" => {}, "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false }
    M.upsert_data_source(obj, fetched_at: Time.current)
    row = M.upsert_data_source(obj, fetched_at: nil)
    assert row.fetched_at.present?
    fresh = M.upsert_data_source(obj.merge("id" => SecureRandom.uuid), fetched_at: nil)
    assert_nil fresh.fetched_at
  end

  test "a workspace-parented page stores a nil parent id" do
    obj = page_obj.merge("parent" => { "type" => "workspace", "workspace" => true })
    page = M.upsert_page(obj)
    assert_equal "workspace", page.notion_parent_type
    assert_nil page.notion_parent_id
    assert_nil page.database_id
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/stacks/notion/mirror_test.rb`
Expected: `NameError: uninitialized constant Stacks::Notion::Mirror`

- [ ] **Step 3: Implement**

```ruby
# lib/stacks/notion/mirror.rb
# Upserts raw Notion objects into the mirror tables. Nothing here calls Notion.
module Stacks::Notion::Mirror
  VOLATILE_KEYS = %w[request_id request_status].freeze

  class << self
    def strip(obj)
      obj.deep_dup.tap { |o| VOLATILE_KEYS.each { |k| o.delete(k) } }
    end

    def title_of(obj)
      runs =
        if obj["object"] == "data_source" || obj["object"] == "database"
          obj["title"]
        else
          prop = (obj["properties"] || {}).values.find { |v| v.is_a?(Hash) && v["type"] == "title" }
          prop && prop["title"]
        end
      Array(runs).map { |r| r["plain_text"].to_s }.join
    end

    def upsert_page(obj, fetched_at: Time.current)
      id = Stacks::Notion::Ids.normalize(obj["id"]) or raise ArgumentError, "page id missing"
      stamp = parse_time(obj["last_edited_time"])
      parent = obj["parent"] || {}
      parent_type = parent["type"]

      NotionPage.transaction do
        page = NotionPage.with_deleted.lock.find_or_initialize_by(notion_id: id)
        if page.persisted? && page.notion_last_edited_at && stamp && stamp < page.notion_last_edited_at
          return page
        end

        walked = page.tree_fetched_for_edited_at
        # acts_as_paranoid 0.7: save! on a soft-deleted row updates through the
        # default scope, matches 0 rows and raises RecordNotSaved. Recover first
        # when the object is live; write a still-trashed row with update_all.
        page.recover! if page.persisted? && page.deleted? && obj["in_trash"] == false

        attrs = {
          data: strip(obj),
          page_title: title_of(obj),
          notion_parent_type: parent_type,
          notion_parent_id: parent_type == "workspace" ? nil : (Stacks::Notion::Ids.normalize(parent[parent_type]) || parent[parent_type]),
          database_id: Stacks::Notion::Ids.normalize(parent["database_id"]),
          data_source_id: Stacks::Notion::Ids.normalize(parent["data_source_id"]),
          notion_last_edited_at: stamp,
          page_fetched_at: fetched_at,
          in_trash: obj["in_trash"] == true,
          access_lost: false,
          url: obj["url"]
        }
        attrs[:blocks_stale_at] = page.blocks_stale_at || fetched_at if walked && stamp && walked != stamp

        if page.persisted? && page.deleted?
          NotionPage.with_deleted.where(id: page.id).update_all(attrs)
          NotionPage.with_deleted.find(page.id)
        else
          page.assign_attributes(attrs)
          page.save!
          page
        end
      end
    end

    def upsert_data_source(obj, fetched_at: Time.current)
      id = Stacks::Notion::Ids.normalize(obj["id"]) or raise ArgumentError, "data source id missing"
      row = NotionDataSource.find_or_initialize_by(notion_id: id)
      row.assign_attributes(
        data: strip(obj), title: title_of(obj),
        database_id: Stacks::Notion::Ids.normalize(obj.dig("parent", "database_id")),
        notion_last_edited_at: parse_time(obj["last_edited_time"]),
        in_trash: obj["in_trash"] == true
      )
      # A feed-sourced object (fetched_at: nil) must not clear a fetched_at learned
      # from GET /data_sources/:id — the backfill relies on nil meaning "schema not fetched".
      row.fetched_at = fetched_at if fetched_at || row.new_record?
      row.save!
      row
    end

    def upsert_database(obj, fetched_at: Time.current)
      id = Stacks::Notion::Ids.normalize(obj["id"]) or raise ArgumentError, "database id missing"
      row = NotionDatabase.find_or_initialize_by(notion_id: id)
      row.update!(
        data: strip(obj), title: title_of(obj),
        notion_last_edited_at: parse_time(obj["last_edited_time"]),
        fetched_at: fetched_at, in_trash: obj["in_trash"] == true
      )
      row
    end

    # Full level replace: rows not in `blocks` are deleted, the rest upserted by
    # notion_id with parent_id/position updated in place (a moved block never
    # collides on the unique index). Stamps the level marker.
    def replace_level(parent_id:, page_id:, blocks:, fetched_at: Time.current)
      parent_id = Stacks::Notion::Ids.normalize(parent_id) || parent_id
      page_id = Stacks::Notion::Ids.normalize(page_id) || page_id
      NotionBlock.transaction do
        rows = store_blocks(parent_id: parent_id, page_id: page_id, blocks: blocks, position_offset: 0)
        NotionBlock.where(parent_id: parent_id).where.not(notion_id: rows.map(&:notion_id)).delete_all
        if parent_id == page_id
          NotionPage.with_deleted.where(notion_id: page_id).update_all(root_children_fetched_at: fetched_at)
        else
          NotionBlock.where(notion_id: parent_id).update_all(children_fetched_at: fetched_at)
        end
        rows
      end
    end

    def store_blocks(parent_id:, page_id:, blocks:, position_offset: 0)
      parent_id = Stacks::Notion::Ids.normalize(parent_id) || parent_id
      page_id = Stacks::Notion::Ids.normalize(page_id) || page_id
      blocks.each_with_index.map do |obj, i|
        bid = Stacks::Notion::Ids.normalize(obj["id"]) || obj["id"]
        row = NotionBlock.find_or_initialize_by(notion_id: bid)
        row.update!(parent_id: parent_id, page_id: page_id, position: position_offset + i,
                    has_children: obj["has_children"] == true, data: strip(obj))
        row
      end
    end

    def owning_page_id(id)
      norm = Stacks::Notion::Ids.normalize(id) || id
      return norm if NotionPage.with_deleted.where(notion_id: norm).exists?
      NotionBlock.where(notion_id: norm).pick(:page_id)
    end

    private

    def parse_time(str)
      str.present? ? Time.zone.parse(str) : nil
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/stacks/notion/mirror_test.rb`
Expected: `11 runs, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/notion/mirror.rb test/lib/stacks/notion/mirror_test.rb
git commit -m "feat: Stacks::Notion::Mirror upserts raw Notion objects into the mirror tables"
```

---

### Task 5: Rewrite `sync_database` on the mirror (soft deletes on `database_id`), serial rake task

**Files:**
- Modify: `lib/stacks/notion.rb` (replace `sync_database`; delete `query_database`, `create_database`, `query_database_all` if still present from the old file)
- Modify: `lib/tasks/stacks.rake:397-413` (`sync_notion` task)
- Test: `test/lib/stacks/notion_sync_database_test.rb`

**Interfaces:**
- Consumes: `Stacks::Notion#get_database`, `#query_data_source` (Task 2); `Stacks::Notion::Mirror.upsert_page` (Task 4); `NotionPage.for_database` (Task 3).
- Produces: `Stacks::Notion#sync_database(database_id_any_form) → { upserted: Integer, removed: Integer }`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/notion_sync_database_test.rb
require 'test_helper'

class StacksNotionSyncDatabaseTest < ActiveSupport::TestCase
  LEADS_DB = Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])
  DS = "8ac2bac5-bc47-4674-851e-d1b1e4f779f2"

  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
  end

  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def row(id, title, last_edited: "2026-09-01T00:00:00.000Z", in_trash: false)
    { "object" => "page", "id" => id, "last_edited_time" => last_edited, "in_trash" => in_trash,
      "parent" => { "type" => "data_source_id", "data_source_id" => DS, "database_id" => LEADS_DB },
      "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => title }] } }, "url" => "u" }
  end

  test "upserts every row across pages and soft-deletes rows missing from the query" do
    gone = NotionPage.create!(notion_id: SecureRandom.uuid, database_id: LEADS_DB, data: {}, page_title: "gone")
    other_db = NotionPage.create!(notion_id: SecureRandom.uuid, database_id: SecureRandom.uuid, data: {}, page_title: "other")
    client = Stacks::Notion.new
    client.stubs(:get_database).with(Stacks::Notion::DATABASE_IDS[:LEADS]).returns({ "data_sources" => [{ "id" => DS }] })
    client.stubs(:query_data_source).with(DS, {}).returns({ "results" => [row("a" * 32, "A")], "next_cursor" => "c2", "has_more" => true })
    client.stubs(:query_data_source).with(DS, { start_cursor: "c2" }).returns({ "results" => [row("b" * 32, "B")], "next_cursor" => nil, "has_more" => false })

    stats = client.sync_database(Stacks::Notion::DATABASE_IDS[:LEADS])

    assert_equal({ upserted: 2, removed: 1 }, stats)
    assert_equal %w[A B].sort, NotionPage.lead.pluck(:page_title).sort
    assert NotionPage.with_deleted.find(gone.id).deleted?
    refute NotionPage.find(other_db.id).deleted?
  end

  test "a row that comes back after being soft-deleted is recovered" do
    id = Stacks::Notion::Ids.normalize("c" * 32)
    NotionPage.create!(notion_id: id, database_id: LEADS_DB, data: {}, page_title: "C").destroy
    client = Stacks::Notion.new
    client.stubs(:get_database).returns({ "data_sources" => [{ "id" => DS }] })
    client.stubs(:query_data_source).returns({ "results" => [row("c" * 32, "C")], "next_cursor" => nil })
    client.sync_database(Stacks::Notion::DATABASE_IDS[:LEADS])
    refute NotionPage.find_by!(notion_id: id).deleted?
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/stacks/notion_sync_database_test.rb`
Expected: failures (old `sync_database` calls `query_database`, which no longer exists, or returns nil).

- [ ] **Step 3: Replace `sync_database` in `lib/stacks/notion.rb`**

Delete the old `sync_database` (and any leftover `query_database` / `create_database` / `query_database_all`) and add, still inside the class, after the `public` line:

```ruby
  # Full reconcile of one Stacks-owned database (Leads, Human Operating Manuals):
  # every row is upserted through the mirror; rows of that database_id that
  # Notion no longer returns are soft-deleted (TaskBuilder relies on them
  # disappearing). Rows that come back are recovered by Mirror.upsert_page.
  def sync_database(database_id)
    dashed_db = Stacks::Notion::Ids.normalize(database_id) or raise ArgumentError, "bad database id #{database_id.inspect}"
    ds_id = get_database(database_id).dig("data_sources", 0, "id") or raise "database #{database_id} has no data source"
    seen = []
    cursor = nil
    loop do
      page = query_data_source(ds_id, cursor ? { start_cursor: cursor } : {})
      page["results"].each do |obj|
        seen << Stacks::Notion::Mirror.upsert_page(obj).notion_id
      end
      cursor = page["next_cursor"]
      break if cursor.nil?
    end
    # An empty result must never wipe the database: where.not(notion_id: []) is 1=1.
    return { upserted: 0, removed: 0 } if seen.empty?

    removed = NotionPage.where(database_id: dashed_db).where.not(notion_id: seen).to_a
    removed.each(&:destroy)
    { upserted: seen.size, removed: removed.size }
  end
```

- [ ] **Step 4: Make the rake task serial**

In `lib/tasks/stacks.rake`, replace the body of `task :sync_notion` so the `Parallel.map(..., in_threads: 3)` becomes a plain `each`:

```ruby
  desc "Sync Notion"
  task :sync_notion => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_notion")
    begin
      notion = Stacks::Notion.new
      Stacks::Notion::DATABASE_IDS.each_value do |db_id|
        stats = notion.sync_database(db_id)
        Rails.logger.info("[stacks:sync_notion] #{db_id}: #{stats.inspect}")
      rescue => e
        Rails.logger.error("Notion sync failed for database #{db_id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
    rescue => e
      system_task.mark_as_error(e)
    else
      system_task.mark_as_success
    end
  end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/stacks/notion_sync_database_test.rb test/lib/stacks/notion_test.rb`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/notion.rb lib/tasks/stacks.rake test/lib/stacks/notion_sync_database_test.rb
git commit -m "feat: sync_database reconciles on database_id through the mirror with soft deletes"
```

---

### Task 6: `Stacks::Notion::TreeFetcher` — full-level walks with a deadline

**Files:**
- Create: `lib/stacks/notion/tree_fetcher.rb`
- Test: `test/lib/stacks/notion/tree_fetcher_test.rb`

**Interfaces:**
- Consumes: `Stacks::Notion#get_block_children`, `#get_page` (Task 2); `Mirror.replace_level`, `Mirror.upsert_page` (Task 4).
- Produces: `Stacks::Notion::TreeFetcher.new(client, deadline: nil | Float seconds).walk(page_id) → { complete: Boolean, requests: Integer }`. Walk semantics: ensure the page row exists (GET it if missing); then breadth-first over the page tree, fetching every level whose marker is missing or older than `blocks_stale_at`, one full level at a time (all cursor pages), via `Mirror.replace_level`. Stops when the deadline passes (returns `complete: false`, sets `wanted_at`). When every `has_children` block has a fresh marker: reload the page; if `notion_last_edited_at` still equals the stamp observed at walk start, set `tree_fetched_for_edited_at = stamp`, clear `blocks_stale_at` and `wanted_at`; if the walk started within 60 s of that stamp, set `recheck_after = stamp + 60s`. If the stamp moved during the walk, leave `blocks_stale_at` set (complete: false).
- Also: `Stacks::Notion::TreeFetcher.fetch_level(client, parent_id:, page_id:) → Array<Hash>` — all cursor pages of one level, concatenated (used by the sweep and by this class).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/lib/stacks/notion/tree_fetcher_test.rb
require 'test_helper'

class StacksNotionTreeFetcherTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  PAGE = "3bf131fe-a2c7-8092-87f3-c668e91d5332"

  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @client = Stacks::Notion.new
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page_obj(last_edited: "2026-09-10T10:00:00.000Z")
    { "object" => "page", "id" => PAGE, "last_edited_time" => last_edited, "in_trash" => false,
      "parent" => { "type" => "workspace", "workspace" => true },
      "properties" => { "title" => { "type" => "title", "title" => [{ "plain_text" => "Guide" }] } }, "url" => "u" }
  end

  def block(id, parent, has_children: false)
    { "object" => "block", "id" => id, "type" => "paragraph", "has_children" => has_children,
      "parent" => { "type" => "page_id", "page_id" => parent }, "paragraph" => { "rich_text" => [] } }
  end

  def list(results, next_cursor: nil)
    { "object" => "list", "results" => results, "next_cursor" => next_cursor, "has_more" => !next_cursor.nil?, "type" => "block", "block" => {} }
  end

  test "walks every level, paginating, and stamps tree_fetched_for_edited_at" do
    travel_to Time.zone.parse("2026-09-10T12:00:00Z")
    Stacks::Notion::Mirror.upsert_page(page_obj)
    @client.expects(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns(list([block("b1", PAGE, has_children: true)], next_cursor: "c2"))
    @client.expects(:get_block_children).with(PAGE, start_cursor: "c2", page_size: 100).returns(list([block("b2", PAGE)]))
    @client.expects(:get_block_children).with("b1", start_cursor: nil, page_size: 100).returns(list([block("b3", "b1")]))

    result = Stacks::Notion::TreeFetcher.new(@client).walk(PAGE)

    assert_equal({ complete: true, requests: 3 }, result)
    page = NotionPage.find_by!(notion_id: PAGE)
    assert_equal Time.zone.parse("2026-09-10T10:00:00Z"), page.tree_fetched_for_edited_at
    assert_nil page.blocks_stale_at
    assert_nil page.recheck_after
    assert_equal %w[b1 b2], NotionBlock.children_of(PAGE).pluck(:notion_id)
    assert_equal %w[b3], NotionBlock.children_of("b1").pluck(:notion_id)
  end

  test "fetches the page object first when the row is missing" do
    @client.expects(:get_page).with(PAGE).returns(page_obj)
    @client.stubs(:get_block_children).returns(list([]))
    Stacks::Notion::TreeFetcher.new(@client).walk(PAGE)
    assert NotionPage.exists?(notion_id: PAGE)
  end

  test "a fresh tree makes no requests" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    Stacks::Notion::Mirror.replace_level(parent_id: PAGE, page_id: PAGE, blocks: [block("b1", PAGE)], fetched_at: Time.current)
    NotionPage.find_by!(notion_id: PAGE).update!(tree_fetched_for_edited_at: Time.zone.parse("2026-09-10T10:00:00Z"))
    @client.expects(:get_block_children).never
    assert_equal({ complete: true, requests: 0 }, Stacks::Notion::TreeFetcher.new(@client).walk(PAGE))
  end

  test "a stale page refetches only levels older than blocks_stale_at" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    Stacks::Notion::Mirror.replace_level(parent_id: PAGE, page_id: PAGE, blocks: [block("b1", PAGE, has_children: true)], fetched_at: 1.hour.ago)
    Stacks::Notion::Mirror.replace_level(parent_id: "b1", page_id: PAGE, blocks: [block("b3", "b1")], fetched_at: 1.minute.from_now)
    NotionPage.find_by!(notion_id: PAGE).update!(blocks_stale_at: Time.current, tree_fetched_for_edited_at: 1.day.ago)
    @client.expects(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns(list([block("b1", PAGE, has_children: true)]))
    @client.expects(:get_block_children).with("b1", start_cursor: nil, page_size: 100).never
    assert_equal({ complete: true, requests: 1 }, Stacks::Notion::TreeFetcher.new(@client).walk(PAGE))
    assert_nil NotionPage.find_by!(notion_id: PAGE).blocks_stale_at
  end

  test "the deadline stops the walk, sets wanted_at, and the next walk resumes" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    @client.stubs(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns(list([block("b1", PAGE, has_children: true), block("b2", PAGE, has_children: true)]))
    @client.stubs(:get_block_children).with("b1", start_cursor: nil, page_size: 100).returns(list([]))
    @client.stubs(:get_block_children).with("b2", start_cursor: nil, page_size: 100).returns(list([]))

    fetcher = Stacks::Notion::TreeFetcher.new(@client, deadline: 0.0) # expires after the first level
    assert_equal({ complete: false, requests: 1 }, fetcher.walk(PAGE))
    assert NotionPage.find_by!(notion_id: PAGE).wanted_at.present?

    assert_equal({ complete: true, requests: 2 }, Stacks::Notion::TreeFetcher.new(@client).walk(PAGE))
    assert_nil NotionPage.find_by!(notion_id: PAGE).wanted_at
  end

  test "an edit during the walk leaves the page stale" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    # The sweep is what normally moves the stamp mid-walk; simulate it from inside the stub.
    @client.stubs(:get_block_children)
           .with { |*| Stacks::Notion::Mirror.upsert_page(page_obj(last_edited: "2026-09-10T10:05:00.000Z")); true }
           .returns(list([block("b1", PAGE)]))
    result = Stacks::Notion::TreeFetcher.new(@client).walk(PAGE)
    refute result[:complete]
    assert NotionPage.find_by!(notion_id: PAGE).blocks_stale_at.present?
  end

  test "a walk within 60s of the edit stamp sets recheck_after" do
    travel_to Time.zone.parse("2026-09-10T10:00:30Z")
    Stacks::Notion::Mirror.upsert_page(page_obj(last_edited: "2026-09-10T10:00:00.000Z"))
    @client.stubs(:get_block_children).returns(list([]))
    Stacks::Notion::TreeFetcher.new(@client).walk(PAGE)
    assert_equal Time.zone.parse("2026-09-10T10:01:00Z"), NotionPage.find_by!(notion_id: PAGE).recheck_after
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/stacks/notion/tree_fetcher_test.rb`
Expected: `NameError: uninitialized constant Stacks::Notion::TreeFetcher`

- [ ] **Step 3: Implement**

```ruby
# lib/stacks/notion/tree_fetcher.rb
# Fills and refreshes a page's block tree level by level (every cursor page of a
# level in one go), under an optional wall-clock deadline. Idempotent and
# resumable: only levels whose marker is missing or older than blocks_stale_at
# are fetched, so a walk cut short by the deadline continues on the next call.
class Stacks::Notion::TreeFetcher
  MINUTE_GUARD = 60.seconds

  def self.fetch_level(client, parent_id:, page_id:)
    blocks = []
    cursor = nil
    requests = 0
    loop do
      list = client.get_block_children(parent_id, start_cursor: cursor, page_size: 100)
      requests += 1
      blocks.concat(list["results"])
      cursor = list["next_cursor"]
      break if cursor.nil?
    end
    [blocks, requests]
  end

  def initialize(client, deadline: nil)
    @client = client
    @deadline = deadline
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @requests = 0
  end

  def walk(page_id)
    page_id = Stacks::Notion::Ids.normalize(page_id) || page_id
    page = NotionPage.with_deleted.find_by(notion_id: page_id) || fetch_page!(page_id)
    stamp_at_start = page.notion_last_edited_at
    walk_started_at = Time.current
    stale_at = page.blocks_stale_at

    queue = [page_id]
    until queue.empty?
      parent_id = queue.shift
      if level_stale?(page, parent_id, stale_at)
        blocks, n = self.class.fetch_level(@client, parent_id: parent_id, page_id: page_id)
        @requests += n
        Stacks::Notion::Mirror.replace_level(parent_id: parent_id, page_id: page_id, blocks: blocks, fetched_at: Time.current)
        enqueue_children!(queue, parent_id)
        # Checked AFTER the level so every walk makes progress; the next call
        # resumes because fresh levels are skipped.
        return give_up(page) if expired? && queue.any?
        next
      end
      enqueue_children!(queue, parent_id)
    end

    refresh_page_stamp!(page) if stamp_at_start.nil?
    page.reload
    if page.notion_last_edited_at != stamp_at_start && !stamp_at_start.nil?
      update_page!(page, blocks_stale_at: page.blocks_stale_at || Time.current)
      return { complete: false, requests: @requests }
    end

    attrs = { tree_fetched_for_edited_at: page.notion_last_edited_at, blocks_stale_at: nil, wanted_at: nil }
    if page.notion_last_edited_at && walk_started_at < page.notion_last_edited_at + MINUTE_GUARD
      attrs[:recheck_after] = page.notion_last_edited_at + MINUTE_GUARD
    end
    update_page!(page, attrs)
    { complete: true, requests: @requests }
  end

  private

  def enqueue_children!(queue, parent_id)
    NotionBlock.where(parent_id: parent_id, has_children: true).order(:position).pluck(:notion_id).each { |id| queue << id }
  end

  # update_all through with_deleted: `update!` on a soft-deleted row raises
  # RecordNotSaved under acts_as_paranoid 0.7 (default scope matches 0 rows).
  def update_page!(page, attrs)
    NotionPage.with_deleted.where(id: page.id).update_all(attrs)
  end

  def fetch_page!(page_id)
    obj = @client.get_page(page_id)
    @requests += 1
    Stacks::Notion::Mirror.upsert_page(obj)
  end

  # Re-read the page object (1 request) so a stamp learned mid-walk is current.
  def refresh_page_stamp!(page)
    obj = @client.get_page(page.notion_id)
    @requests += 1
    Stacks::Notion::Mirror.upsert_page(obj)
    true
  end

  def level_stale?(page, parent_id, stale_at)
    marker =
      if parent_id == page.notion_id
        page.root_children_fetched_at
      else
        NotionBlock.where(notion_id: parent_id).pick(:children_fetched_at)
      end
    marker.nil? || (stale_at && marker < stale_at)
  end

  def expired?
    @deadline && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started) >= @deadline
  end

  def give_up(page)
    update_page!(page, wanted_at: page.wanted_at || Time.current)
    { complete: false, requests: @requests }
  end
end
```

With `deadline: 0.0` the first stale level is still fetched (the deadline is checked after each level), which is what the resume test's `requests: 1` then `requests: 2` asserts.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/stacks/notion/tree_fetcher_test.rb`
Expected: `7 runs, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/notion/tree_fetcher.rb test/lib/stacks/notion/tree_fetcher_test.rb
git commit -m "feat: Stacks::Notion::TreeFetcher — resumable level walks with deadline and minute-resolution recheck"
```

---

### Task 7: REST proxy — routes, auth in Notion's shape, single-object GETs, error pass-through

**Files:**
- Create: `app/controllers/api/notion/proxy_controller.rb`
- Modify: `config/routes.rb` (inside `namespace :api`)
- Test: `test/controllers/api/notion/proxy_controller_test.rb`

**Interfaces:**
- Consumes: `Stacks::Notion` (Task 2), `Mirror` (Task 4).
- Produces: routes `GET /api/notion/v1/pages/:id`, `GET /api/notion/v1/data_sources/:id`, `GET /api/notion/v1/databases/:id`, `GET /api/notion/v1/blocks/:id` (Task 8 adds `blocks/:id/children`; Task 9 adds query/search/writes). Response headers `X-Stacks-Cache` (`hit|stale|miss|live`) and `X-Stacks-Fetched-At`. Controller helpers used by Tasks 8–9: `client` (memoized `Stacks::Notion.new(max_retries: 1, retry_after_cap: 6)`), `render_cached(row, state:)`, `render_live(body, status: 200)`, `notion_error(status, code, message)`, `normalized_id!`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/controllers/api/notion/proxy_controller_test.rb
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/api/notion/proxy_controller_test.rb`
Expected: routing errors (`No route matches`).

- [ ] **Step 3: Add routes**

In `config/routes.rb`, inside `namespace :api do` (after the `/mcp/write` line), add:

```ruby
    # One-to-one caching reverse proxy of Notion's REST API.
    # Spec: docs/superpowers/specs/2026-09-10-notion-mirror-design.md
    scope "notion/v1", module: "notion", as: "notion", defaults: { format: :json } do
      get    "pages/:id",            to: "proxy#get_page"
      get    "blocks/:id",           to: "proxy#get_block"
      get    "blocks/:id/children",  to: "proxy#get_block_children"
      get    "data_sources/:id",     to: "proxy#get_data_source"
      get    "databases/:id",        to: "proxy#get_database"
      post   "data_sources/:id/query", to: "proxy#query_data_source"
      post   "search",               to: "proxy#search"
      post   "pages",                to: "proxy#create_page"
      patch  "pages/:id",            to: "proxy#update_page"
      patch  "blocks/:id/children",  to: "proxy#append_block_children"
      patch  "blocks/:id",           to: "proxy#update_block"
      delete "blocks/:id",           to: "proxy#delete_block"
      match  "*path",                to: "proxy#not_found", via: :all
    end
```

- [ ] **Step 4: Write the controller (Tasks 8 and 9 fill in the remaining actions; stub them now)**

```ruby
# app/controllers/api/notion/proxy_controller.rb
# One-to-one caching reverse proxy of Notion's REST API. Same paths, bodies and
# responses as api.notion.com; cache hits never touch Notion; misses fill through
# Stacks::Notion (paced). Spec: docs/superpowers/specs/2026-09-10-notion-mirror-design.md
class Api::Notion::ProxyController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :require_api_key!

  # Child rescue_from wins over ApiController's blanket StandardError handler:
  # Notion's own error is passed through, untouched and without Sentry.
  rescue_from Stacks::Notion::RequestError, with: :render_notion_error

  # ---- single objects ------------------------------------------------------
  def get_page
    id = normalized_id!
    row = NotionPage.with_deleted.find_by(notion_id: id)
    return render_cached(row.data, fetched_at: row.page_fetched_at, state: "hit") if row && !row.deleted? && !row.access_lost

    obj = with_access_tracking(NotionPage.with_deleted.where(notion_id: id)) { client.get_page(id) }
    page = Stacks::Notion::Mirror.upsert_page(obj)
    render_cached(page.data, fetched_at: page.page_fetched_at, state: "miss")
  end

  def get_data_source
    id = normalized_id!
    row = NotionDataSource.find_by(notion_id: id)
    return render_cached(row.data, fetched_at: row.fetched_at, state: "hit") if row&.fetched_at

    row = Stacks::Notion::Mirror.upsert_data_source(client.get_data_source(id))
    render_cached(row.data, fetched_at: row.fetched_at, state: "miss")
  end

  def get_database
    id = normalized_id!
    row = NotionDatabase.find_by(notion_id: id)
    return render_cached(row.data, fetched_at: row.fetched_at, state: "hit") if row&.fetched_at

    row = Stacks::Notion::Mirror.upsert_database(client.get_database(id))
    render_cached(row.data, fetched_at: row.fetched_at, state: "miss")
  end

  def get_block
    id = normalized_id!
    row = NotionBlock.find_by(notion_id: id)
    return render_cached(row.data, fetched_at: row.updated_at, state: "hit") if row

    obj = client.get_block(id)
    parent_id = obj.dig("parent", "page_id") || obj.dig("parent", "block_id")
    page_id = Stacks::Notion::Mirror.owning_page_id(parent_id)
    if page_id
      Stacks::Notion::Mirror.store_blocks(parent_id: parent_id, page_id: page_id, blocks: [obj], position_offset: NotionBlock.where(parent_id: parent_id).count)
    end
    render_live(obj)
  end

  # Tasks 8 and 9 replace these bodies.
  def get_block_children = not_found
  def query_data_source = not_found
  def search = not_found
  def create_page = not_found
  def update_page = not_found
  def append_block_children = not_found
  def update_block = not_found
  def delete_block = not_found

  def not_found
    notion_error(404, "object_not_found", "Could not find route #{request.method} #{request.path}")
  end

  private

  def client
    @client ||= Stacks::Notion.new(max_retries: 1, retry_after_cap: 6)
  end

  def require_api_key!
    provided = request.headers["X-Api-Key"].to_s
    expected = Stacks::Utils.config.dig(:stacks, :private_api_key).to_s
    return if expected.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected)

    notion_error(401, "unauthorized", "API token is invalid.")
  end

  def normalized_id!
    Stacks::Notion::Ids.normalize(params[:id]) or
      raise Stacks::Notion::RequestError.new(400, { "object" => "error", "status" => 400, "code" => "validation_error", "message" => "path.id should be a valid uuid, instead was `#{params[:id]}`." })
  end

  def json_body
    request.body.rewind
    raw = request.body.read
    raw.blank? ? {} : JSON.parse(raw)
  rescue JSON::ParserError
    raise Stacks::Notion::RequestError.new(400, { "object" => "error", "status" => 400, "code" => "invalid_json", "message" => "Error parsing JSON body." })
  end

  def render_cached(body, fetched_at:, state:)
    response.set_header("X-Stacks-Cache", state)
    response.set_header("X-Stacks-Fetched-At", fetched_at.utc.iso8601) if fetched_at
    render json: body, status: 200
  end

  def render_live(body, status: 200)
    response.set_header("X-Stacks-Cache", "live")
    render json: body, status: status
  end

  def notion_error(status, code, message)
    render json: { "object" => "error", "status" => status, "code" => code, "message" => message }, status: status
  end

  def render_notion_error(err)
    response.set_header("Retry-After", err.headers["retry-after"]) if err.headers["retry-after"].present?
    render json: err.body, status: err.code
  end

  # 403/404 from Notion on a page we track: remember that we lost it, then re-raise.
  def with_access_tracking(scope)
    yield
  rescue Stacks::Notion::RequestError => e
    scope.update_all(access_lost: true) if [403, 404].include?(e.code)
    raise
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/controllers/api/notion/proxy_controller_test.rb`
Expected: `9 runs, 0 failures`. If the "not sent to Sentry" assertion fails because `HandlesExceptions` still runs, confirm the `rescue_from` is declared in this controller (child handlers are checked first in Rails 6.1).

- [ ] **Step 6: Commit**

```bash
git add app/controllers/api/notion/proxy_controller.rb config/routes.rb test/controllers/api/notion/proxy_controller_test.rb
git commit -m "feat: /api/notion/v1 proxy — auth in Notion's shape, single-object GETs, error pass-through"
```

---

### Task 8: Proxy — `GET blocks/:id/children` level cache

**Files:**
- Modify: `app/controllers/api/notion/proxy_controller.rb` (replace `get_block_children`)
- Test: `test/controllers/api/notion/proxy_blocks_test.rb`

**Interfaces:**
- Consumes: `Mirror.owning_page_id`, `Mirror.replace_level`, `Mirror.store_blocks` (Task 4); `client.get_block_children` (Task 2).
- Produces: the level-cache rule from the spec. Cached levels are served in Notion's list envelope `{object:"list", results, next_cursor, has_more, type:"block", block:{}}` where `next_cursor` is the `notion_id` of the first block of the next slice (Notion's cursors are opaque; ours are block ids) and `page_size` defaults to 100, max 100.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/controllers/api/notion/proxy_blocks_test.rb
require 'test_helper'

class Api::Notion::ProxyBlocksTest < ActionDispatch::IntegrationTest
  PAGE = "3bf131fe-a2c7-8092-87f3-c668e91d5332"

  setup do
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @key = { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }
    Stacks::Notion::Mirror.upsert_page(
      "object" => "page", "id" => PAGE, "last_edited_time" => "2026-09-10T10:00:00.000Z", "in_trash" => false,
      "parent" => { "type" => "workspace", "workspace" => true }, "properties" => {}, "url" => "u"
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
    assert_equal %w[b1 b2], NotionBlock.children_of(PAGE).pluck(:notion_id)
    assert_operator NotionPage.find_by!(notion_id: PAGE).root_children_fetched_at, :>, NotionPage.find_by!(notion_id: PAGE).blocks_stale_at
  end

  test "an unknown block id passes through live without storing" do
    Stacks::Notion.any_instance.expects(:get_block_children).with("zzz", start_cursor: nil, page_size: 100).returns(list([block("q", "zzz")]))
    get "/api/notion/v1/blocks/zzz/children", headers: @key
    assert_equal "live", response.headers["X-Stacks-Cache"]
    refute NotionBlock.exists?(notion_id: "q")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/api/notion/proxy_blocks_test.rb`
Expected: 404s from the stub action.

- [ ] **Step 3: Replace `get_block_children` in the controller**

```ruby
  # Level cache: fresh → local slice; stale/never → the caller's ONE cursor page
  # live, stored opportunistically; unknown parent → live, not stored.
  def get_block_children
    parent_id = Stacks::Notion::Ids.normalize(params[:id]) || params[:id].to_s
    page_id = Stacks::Notion::Mirror.owning_page_id(parent_id)
    page_size = [[params[:page_size].to_i, 1].max, 100].min
    page_size = 100 if params[:page_size].blank?
    cursor = params[:start_cursor].presence

    return render_live(client.get_block_children(parent_id, start_cursor: cursor, page_size: page_size)) if page_id.nil?

    page = NotionPage.with_deleted.find_by!(notion_id: page_id)
    marker = parent_id == page_id ? page.root_children_fetched_at : NotionBlock.where(notion_id: parent_id).pick(:children_fetched_at)
    fresh = marker.present? && (page.blocks_stale_at.nil? || marker > page.blocks_stale_at)

    if fresh
      rows = NotionBlock.children_of(parent_id).to_a
      start = cursor ? rows.index { |r| r.notion_id == Stacks::Notion::Ids.normalize(cursor) || r.notion_id == cursor } : 0
      raise Stacks::Notion::RequestError.new(400, { "object" => "error", "status" => 400, "code" => "validation_error", "message" => "start_cursor is invalid" }) if start.nil?
      slice = rows[start, page_size] || []
      nxt = rows[start + page_size]
      return render_cached(
        { "object" => "list", "results" => slice.map(&:data), "next_cursor" => nxt&.notion_id, "has_more" => !nxt.nil?, "type" => "block", "block" => {} },
        fetched_at: marker, state: "hit"
      )
    end

    live = client.get_block_children(parent_id, start_cursor: cursor, page_size: 100)
    offset = cursor ? NotionBlock.where(parent_id: parent_id).count : 0
    if cursor.nil? && live["next_cursor"].nil?
      Stacks::Notion::Mirror.replace_level(parent_id: parent_id, page_id: page_id, blocks: live["results"], fetched_at: Time.current)
    else
      Stacks::Notion::Mirror.store_blocks(parent_id: parent_id, page_id: page_id, blocks: live["results"], position_offset: offset)
    end
    response.set_header("X-Stacks-Cache", marker.present? ? "stale" : "miss")
    response.set_header("X-Stacks-Fetched-At", Time.current.utc.iso8601)
    render json: live, status: 200
  end
```

Note: on a miss/stale we always ask Notion for `page_size: 100` (so a single-page level can be completed) but return Notion's body as-is, so the caller's `page_size` is honoured only on hits. Document this in the deviations list in Task 12's docs step.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/controllers/api/notion/proxy_blocks_test.rb test/controllers/api/notion/proxy_controller_test.rb`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/notion/proxy_controller.rb test/controllers/api/notion/proxy_blocks_test.rb
git commit -m "feat: proxy GET blocks/:id/children — level cache with single-page live fill"
```

---

### Task 9: Proxy — query and search pass-through, writes with invalidation

**Files:**
- Modify: `app/controllers/api/notion/proxy_controller.rb` (replace the remaining stub actions)
- Test: `test/controllers/api/notion/proxy_passthrough_test.rb`

**Interfaces:**
- Consumes: `client.query_data_source`, `client.search`, `client.create_page`, `client.update_page`, `client.append_block_children`, `client.update_block`, `client.delete_block` (Task 2); `Mirror.upsert_page`, `upsert_data_source`, `owning_page_id` (Task 4).
- Produces: `POST /api/notion/v1/data_sources/:id/query` and `POST /api/notion/v1/search` always live (`X-Stacks-Cache: live`), results upserted; writes live, then the owning page is upserted (page writes) or marked `blocks_stale_at` (block writes).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/controllers/api/notion/proxy_passthrough_test.rb
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
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/api/notion/proxy_passthrough_test.rb`
Expected: 404s from the stub actions.

- [ ] **Step 3: Replace the stub actions in the controller**

```ruby
  # ---- lists: always live; results warm the cache --------------------------
  def query_data_source
    id = normalized_id!
    live = client.query_data_source(id, json_body)
    upsert_results(live["results"])
    render_live(live)
  end

  def search
    live = client.search(json_body)
    upsert_results(live["results"])
    render_live(live)
  end

  # ---- writes: live, then invalidate ---------------------------------------
  def create_page
    obj = client.create_page(json_body)
    Stacks::Notion::Mirror.upsert_page(obj)
    render_live(obj)
  end

  def update_page
    obj = client.update_page(normalized_id!, json_body)
    Stacks::Notion::Mirror.upsert_page(obj)
    render_live(obj)
  end

  def append_block_children
    parent_id = Stacks::Notion::Ids.normalize(params[:id]) || params[:id].to_s
    live = client.append_block_children(parent_id, json_body)
    mark_page_stale(parent_id)
    render_live(live)
  end

  def update_block
    block_id = Stacks::Notion::Ids.normalize(params[:id]) || params[:id].to_s
    obj = client.update_block(block_id, json_body)
    mark_page_stale(block_id, obj)
    render_live(obj)
  end

  def delete_block
    block_id = Stacks::Notion::Ids.normalize(params[:id]) || params[:id].to_s
    obj = client.delete_block(block_id)
    mark_page_stale(block_id, obj)
    render_live(obj)
  end
```

and, under `private`:

```ruby
  def upsert_results(results)
    Array(results).each do |obj|
      case obj["object"]
      when "page" then Stacks::Notion::Mirror.upsert_page(obj)
      when "data_source" then Stacks::Notion::Mirror.upsert_data_source(obj)
      end
    end
  end

  # The owning page of a block id: a cached page/block, or the parent the
  # response reports. Unknown → nothing to invalidate.
  def mark_page_stale(block_or_page_id, obj = nil)
    page_id = Stacks::Notion::Mirror.owning_page_id(block_or_page_id)
    page_id ||= Stacks::Notion::Mirror.owning_page_id(obj.dig("parent", "page_id") || obj.dig("parent", "block_id")) if obj
    return unless page_id
    NotionPage.with_deleted.where(notion_id: page_id).update_all(blocks_stale_at: Time.current)
  end
```

- [ ] **Step 4: Run all proxy tests**

Run: `bin/rails test test/controllers/api/notion/proxy_passthrough_test.rb test/controllers/api/notion/proxy_blocks_test.rb test/controllers/api/notion/proxy_controller_test.rb`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/notion/proxy_controller.rb test/controllers/api/notion/proxy_passthrough_test.rb
git commit -m "feat: proxy query/search pass-through and writes with page invalidation"
```

---

### Task 10: `Stacks::Notion::Sweep` + `stacks:notion:sweep`

**Files:**
- Create: `lib/stacks/notion/sweep.rb`, `lib/tasks/notion.rake`
- Test: `test/lib/stacks/notion/sweep_test.rb`, `test/lib/tasks/notion_rake_test.rb`

**Interfaces:**
- Consumes: `client.search`, `client.get_page` (Task 2); `Mirror.upsert_page`, `upsert_data_source` (Task 4); `TreeFetcher` (Task 6); `SourceSync.for(:notion_mirror)`.
- Produces: `Stacks::Notion::Sweep::ADVISORY_LOCK_KEY = 728534292` (shared with Backfill and Reconcile in Task 11); `Stacks::Notion::Sweep.run_with_lock!(client = Stacks::Notion.new) → Hash stats | nil (lock held)`; `Stacks::Notion::Sweep.new(client, now: Time.current, run_deadline: 5.minutes, recheck_limit: 50, overlap: ENV NOTION_SWEEP_OVERLAP seconds default 300).run → { feed_requests:, pages_upserted:, data_sources_upserted:, rechecks:, trees_refreshed:, pages_still_stale:, requests_spent:, watermark: }`; rake `stacks:notion:sweep` wrapped in `SystemTask`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/lib/stacks/notion/sweep_test.rb
require 'test_helper'

class StacksNotionSweepTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  DS = "e5d5d0da-a85e-4b3f-b900-9fd06a315622"
  DB = "438196be-db11-412e-b8e7-37bc1bd75b2b"

  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @client = Stacks::Notion.new
    travel_to Time.zone.parse("2026-09-10T12:00:00Z")
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page(id, last_edited)
    { "object" => "page", "id" => id, "last_edited_time" => last_edited, "in_trash" => false,
      "parent" => { "type" => "data_source_id", "data_source_id" => DS, "database_id" => DB },
      "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => id[0, 4] }] } }, "url" => "u" }
  end

  def ds(id, last_edited)
    { "object" => "data_source", "id" => id, "title" => [{ "plain_text" => "DS" }], "parent" => { "type" => "database_id", "database_id" => DB },
      "properties" => {}, "last_edited_time" => last_edited, "in_trash" => false }
  end

  def feed(results, next_cursor: nil)
    { "object" => "list", "results" => results, "next_cursor" => next_cursor, "has_more" => !next_cursor.nil?, "type" => "page_or_data_source", "page_or_data_source" => {} }
  end

  def sort_desc = { "timestamp" => "last_edited_time", "direction" => "descending" }

  test "walks the feed back to watermark minus overlap, dedupes across pages, upserts pages and data sources" do
    SourceSync.for(:notion_mirror).advance!(cursor: { "watermark" => "2026-09-10T11:30:00Z" })
    a, b, c, d = 4.times.map { SecureRandom.uuid }
    @client.expects(:search).with({ "page_size" => 100, "sort" => sort_desc }).returns(feed([page(a, "2026-09-10T11:58:00.000Z"), ds(b, "2026-09-10T11:40:00.000Z")], next_cursor: "c2"))
    @client.expects(:search).with({ "page_size" => 100, "sort" => sort_desc, "start_cursor" => "c2" }).returns(feed([page(a, "2026-09-10T11:58:00.000Z"), page(c, "2026-09-10T11:26:00.000Z"), page(d, "2026-09-10T11:20:00.000Z")]))

    stats = Stacks::Notion::Sweep.new(@client).run

    assert_equal 2, stats[:feed_requests]
    assert_equal 2, stats[:pages_upserted], "a (deduped) and c (inside the 5-minute overlap); d is older than watermark-overlap"
    assert_equal 1, stats[:data_sources_upserted]
    assert NotionPage.exists?(notion_id: c)
    refute NotionPage.exists?(notion_id: d)
    assert_equal "2026-09-10T11:58:00Z", SourceSync.for(:notion_mirror).reload.cursor["watermark"]
  end

  test "the watermark never passes run_started_at" do
    a = SecureRandom.uuid
    @client.stubs(:search).returns(feed([page(a, "2026-09-10T12:30:00.000Z")]))
    Stacks::Notion::Sweep.new(@client).run
    assert_equal "2026-09-10T12:00:00Z", SourceSync.for(:notion_mirror).reload.cursor["watermark"]
  end

  test "a walked page whose stamp moved is marked stale and its tree refreshed within the run" do
    a = SecureRandom.uuid
    Stacks::Notion::Mirror.upsert_page(page(a, "2026-09-10T11:00:00.000Z"))
    NotionPage.find_by!(notion_id: a).update!(tree_fetched_for_edited_at: Time.zone.parse("2026-09-10T11:00:00Z"), root_children_fetched_at: 1.hour.ago)
    @client.stubs(:search).returns(feed([page(a, "2026-09-10T11:50:00.000Z")]))
    @client.expects(:get_block_children).with(a, start_cursor: nil, page_size: 100).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })

    stats = Stacks::Notion::Sweep.new(@client).run

    assert_equal 1, stats[:trees_refreshed]
    row = NotionPage.find_by!(notion_id: a)
    assert_nil row.blocks_stale_at
    assert_equal Time.zone.parse("2026-09-10T11:50:00Z"), row.tree_fetched_for_edited_at
  end

  test "wanted_at pages are refreshed first and pages never walked are skipped" do
    never, wanted, stale = 3.times.map { SecureRandom.uuid }
    [never, wanted, stale].each { |id| Stacks::Notion::Mirror.upsert_page(page(id, "2026-09-10T11:00:00.000Z")) }
    NotionPage.find_by!(notion_id: wanted).update!(wanted_at: Time.current)
    NotionPage.find_by!(notion_id: stale).update!(blocks_stale_at: Time.current, tree_fetched_for_edited_at: 1.day.ago, root_children_fetched_at: 1.day.ago)
    @client.stubs(:search).returns(feed([]))
    seq = sequence("refresh order")
    empty = { "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false }
    @client.expects(:get_block_children).with(wanted, start_cursor: nil, page_size: 100).returns(empty).in_sequence(seq)
    @client.expects(:get_block_children).with(stale, start_cursor: nil, page_size: 100).returns(empty).in_sequence(seq)
    @client.expects(:get_block_children).with(never, start_cursor: nil, page_size: 100).never

    stats = Stacks::Notion::Sweep.new(@client).run
    assert_equal 2, stats[:trees_refreshed]
  end

  test "the run deadline stops tree refresh and leaves the pages flagged" do
    wanted, stale = 2.times.map { SecureRandom.uuid }
    [wanted, stale].each { |id| Stacks::Notion::Mirror.upsert_page(page(id, "2026-09-10T11:00:00.000Z")) }
    NotionPage.find_by!(notion_id: wanted).update!(wanted_at: Time.current)
    NotionPage.find_by!(notion_id: stale).update!(blocks_stale_at: Time.current, tree_fetched_for_edited_at: 1.day.ago, root_children_fetched_at: 1.day.ago)
    @client.stubs(:search).returns(feed([]))
    @client.expects(:get_block_children).never

    stats = Stacks::Notion::Sweep.new(@client, run_deadline: 0.seconds).run
    assert_equal 0, stats[:trees_refreshed]
    assert_equal 2, stats[:pages_still_stale]
  end

  test "recheck_after pages get one GET and are re-flagged only if the stamp moved" do
    a, b = 2.times.map { SecureRandom.uuid }
    [a, b].each do |id|
      Stacks::Notion::Mirror.upsert_page(page(id, "2026-09-10T11:00:00.000Z"))
      NotionPage.find_by!(notion_id: id).update!(recheck_after: 1.minute.ago, tree_fetched_for_edited_at: Time.zone.parse("2026-09-10T11:00:00Z"), root_children_fetched_at: 1.hour.ago)
    end
    @client.stubs(:search).returns(feed([]))
    @client.expects(:get_page).with(a).returns(page(a, "2026-09-10T11:00:00.000Z"))
    @client.expects(:get_page).with(b).returns(page(b, "2026-09-10T11:01:00.000Z"))
    @client.stubs(:get_block_children).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })

    stats = Stacks::Notion::Sweep.new(@client, run_deadline: 0.seconds).run

    assert_equal 2, stats[:rechecks]
    assert_nil NotionPage.find_by!(notion_id: a).recheck_after
    assert_nil NotionPage.find_by!(notion_id: a).blocks_stale_at
    assert NotionPage.find_by!(notion_id: b).blocks_stale_at.present?
  end

  test "the feed failing leaves the watermark alone" do
    SourceSync.for(:notion_mirror).advance!(cursor: { "watermark" => "2026-09-10T11:30:00Z" })
    @client.stubs(:search).raises(Stacks::Notion::RequestError.new(502, { "object" => "error" }))
    assert_raises(Stacks::Notion::RequestError) { Stacks::Notion::Sweep.new(@client).run }
    assert_equal "2026-09-10T11:30:00Z", SourceSync.for(:notion_mirror).reload.cursor["watermark"]
  end

  test "run_with_lock! returns nil when the advisory lock is held elsewhere" do
    other = ActiveRecord::Base.connection_pool.checkout
    other.execute("SELECT pg_advisory_lock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    assert_nil Stacks::Notion::Sweep.run_with_lock!(@client)
  ensure
    other.execute("SELECT pg_advisory_unlock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    ActiveRecord::Base.connection_pool.checkin(other)
  end
end
```

```ruby
# test/lib/tasks/notion_rake_test.rb
require "test_helper"
require "rake"

class NotionRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("stacks:notion:sweep")
    %w[stacks:notion:sweep stacks:notion:backfill stacks:notion:reconcile].each { |t| Rake::Task[t].reenable if Rake::Task.task_defined?(t) }
  end

  test "sweep records a SystemTask and success" do
    Stacks::Notion::Sweep.expects(:run_with_lock!).returns({ requests_spent: 0 })
    Rake::Task["stacks:notion:sweep"].invoke
    task = SystemTask.order(:id).last
    assert_equal "stacks:notion:sweep", task.name
    assert task.settled_at.present?
    assert_nil task.notification
  end

  test "sweep records an error" do
    Stacks::Notion::Sweep.expects(:run_with_lock!).raises(RuntimeError.new("boom"))
    Stacks::Notifications.stubs(:report_exception).returns(stub(record: nil))
    Rake::Task["stacks:notion:sweep"].invoke
    assert SystemTask.order(:id).last.settled_at.present?
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/stacks/notion/sweep_test.rb test/lib/tasks/notion_rake_test.rb`
Expected: `NameError: uninitialized constant Stacks::Notion::Sweep`; rake task not defined.

- [ ] **Step 3: Implement the sweep**

```ruby
# lib/stacks/notion/sweep.rb
# Every 10 minutes: walk Notion's search feed (newest first) back to the last
# watermark, upsert what changed, then refresh stale block trees until the run
# deadline. Search returns full page objects, so properties cost 1–3 requests.
class Stacks::Notion::Sweep
  # Shared by Sweep, Backfill and Reconcile — they are mutually exclusive.
  ADVISORY_LOCK_KEY = 728534292
  SOURCE = :notion_mirror

  def self.run_with_lock!(client = Stacks::Notion.new)
    conn = ActiveRecord::Base.connection
    return nil unless conn.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    begin
      new(client).run
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
    end
  end

  def initialize(client, now: Time.current, run_deadline: 5.minutes, recheck_limit: 50,
                 overlap: Integer(ENV.fetch("NOTION_SWEEP_OVERLAP", 300)).seconds)
    @client = client
    @now = now
    @run_deadline = run_deadline
    @recheck_limit = recheck_limit
    @overlap = overlap
    @stats = Hash.new(0)
  end

  def run
    sync = SourceSync.for(SOURCE)
    watermark = sync.cursor["watermark"].present? ? Time.zone.parse(sync.cursor["watermark"]) : nil
    newest = walk_feed(watermark)
    recheck!
    refresh_trees!
    new_watermark = [newest, @now].compact.min
    @stats[:watermark] = new_watermark&.utc&.iso8601
    sync.advance!(cursor: { "watermark" => @stats[:watermark] }, stats: @stats.transform_keys(&:to_s))
    @stats
  end

  private

  def walk_feed(watermark)
    floor = watermark && (watermark - @overlap)
    seen = Set.new
    newest = nil
    cursor = nil
    loop do
      body = { "page_size" => 100, "sort" => { "timestamp" => "last_edited_time", "direction" => "descending" } }
      body["start_cursor"] = cursor if cursor
      list = @client.search(body)
      @stats[:feed_requests] += 1
      @stats[:requests_spent] += 1
      stop = false
      list["results"].each do |obj|
        stamp = Time.zone.parse(obj["last_edited_time"].to_s)
        newest = [newest, stamp].compact.max
        if floor && stamp && stamp < floor
          stop = true
          break
        end
        next unless seen.add?(obj["id"])
        case obj["object"]
        when "page"
          Stacks::Notion::Mirror.upsert_page(obj, fetched_at: @now)
          @stats[:pages_upserted] += 1
        when "data_source"
          Stacks::Notion::Mirror.upsert_data_source(obj, fetched_at: @now)
          @stats[:data_sources_upserted] += 1
        end
      end
      cursor = list["next_cursor"]
      break if stop || cursor.nil?
    end
    newest
  end

  # Pages whose tree was walked within a minute of their edit stamp: re-read
  # the page object once so a same-minute edit is not missed.
  def recheck!
    NotionPage.where("recheck_after <= ?", @now).order(:recheck_after).limit(@recheck_limit).each do |page|
      obj = @client.get_page(page.notion_id)
      @stats[:requests_spent] += 1
      @stats[:rechecks] += 1
      Stacks::Notion::Mirror.upsert_page(obj, fetched_at: @now) # marks stale if the stamp moved
      NotionPage.with_deleted.where(id: page.id).update_all(recheck_after: nil)
    rescue Stacks::Notion::RequestError => e
      Rails.logger.warn("[Stacks::Notion::Sweep] recheck #{page.notion_id} failed: #{e.message}")
      NotionPage.with_deleted.where(id: page.id).update_all(recheck_after: nil)
    end
  end

  def refresh_trees!
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    candidates = NotionPage.where.not(wanted_at: nil).order(:wanted_at).to_a +
                 NotionPage.where(wanted_at: nil).where.not(blocks_stale_at: nil).where.not(root_children_fetched_at: nil).order(notion_last_edited_at: :desc).to_a
    candidates.uniq(&:id).each do |page|
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= @run_deadline
        @stats[:pages_still_stale] += 1
        next
      end
      result = Stacks::Notion::TreeFetcher.new(@client).walk(page.notion_id)
      @stats[:requests_spent] += result[:requests]
      if result[:complete]
        @stats[:trees_refreshed] += 1
      else
        @stats[:pages_still_stale] += 1
      end
    rescue Stacks::Notion::RequestError => e
      Rails.logger.warn("[Stacks::Notion::Sweep] tree #{page.notion_id} failed: #{e.message}")
      @stats[:pages_still_stale] += 1
    end
  end
end
```

- [ ] **Step 4: Add the rake file (backfill/reconcile tasks are filled in by Task 11)**

```ruby
# lib/tasks/notion.rake
namespace :stacks do
  namespace :notion do
    desc "Notion mirror: walk the search feed and refresh stale block trees (every 10 min)"
    task sweep: :environment do
      system_task = SystemTask.create!(name: "stacks:notion:sweep")
      begin
        stats = Stacks::Notion::Sweep.run_with_lock!
        Rails.logger.info(stats ? "[stacks:notion:sweep] #{stats.inspect}" : "[stacks:notion:sweep] skipped: lock held")
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/stacks/notion/sweep_test.rb test/lib/tasks/notion_rake_test.rb`
Expected: all pass. The `SystemTask#mark_as_error` path calls `Stacks::Notifications.report_exception`, which posts to Twist; the rake test stubs it.

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/notion/sweep.rb lib/tasks/notion.rake test/lib/stacks/notion/sweep_test.rb test/lib/tasks/notion_rake_test.rb
git commit -m "feat: Stacks::Notion::Sweep — search-feed sweep with recheck and deadline-bounded tree refresh"
```

---

### Task 11: Backfill and Reconcile + rake tasks

**Files:**
- Create: `lib/stacks/notion/backfill.rb`, `lib/stacks/notion/reconcile.rb`
- Modify: `lib/tasks/notion.rake`
- Test: `test/lib/stacks/notion/backfill_test.rb`, `test/lib/stacks/notion/reconcile_test.rb`

**Interfaces:**
- Consumes: `client.search`, `get_data_source`, `get_database`, `get_page` (Task 2); `Mirror` (Task 4); `TreeFetcher` (Task 6); `Sweep::ADVISORY_LOCK_KEY` (Task 10).
- Produces:
  - `Stacks::Notion::Backfill.run_with_lock!(client = Stacks::Notion.new, seed_ids: ENV NOTION_SEED_PAGE_IDS) → stats | nil`. Phases recorded in `SourceSync.for(:notion_backfill).cursor` as `{ "phase" => "feed"|"schemas"|"seeds"|"done", "next_cursor" => …, "schemas_done" => [ids] }` so a killed run resumes. Feed phase: whole `POST /search` walk (no watermark), upserting pages and data sources. Schemas phase: for every `NotionDataSource` with `fetched_at` nil, `get_data_source` + `get_database` (its `database_id`), upsert both. Seeds phase: `TreeFetcher.new(client).walk(id)` for each seed id (defaults `329131fea2c780718aa8f222b25c76e8`, `dc51296819394138869baaefd534816a`).
  - `Stacks::Notion::Reconcile.run_with_lock!(client = Stacks::Notion.new, disambiguation_limit: 200) → { seen:, checked:, trashed:, access_lost:, drift: }`. Full feed walk collecting seen ids and stamps; then every `NotionPage` (not deleted, not `in_trash`, not `access_lost`) and `NotionDataSource` not seen gets one GET, bounded: `in_trash: true` → `in_trash = true`; 403/404 → `access_lost = true`. `drift` counts cached pages whose `notion_last_edited_at` is older than the feed's stamp (the feed upserts them too, so this is a report of how far the sweep had fallen behind).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/lib/stacks/notion/backfill_test.rb
require 'test_helper'

class StacksNotionBackfillTest < ActiveSupport::TestCase
  DS = "8ac2bac5-bc47-4674-851e-d1b1e4f779f2"
  DB = "4d9b46b8-bad5-4250-9f14-4347db37964d"
  SEED = "329131fe-a2c7-8071-8aa8-f222b25c76e8"

  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @client = Stacks::Notion.new
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page(id) = { "object" => "page", "id" => id, "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false, "parent" => { "type" => "workspace", "workspace" => true }, "properties" => {}, "url" => "u" }
  def ds_obj = { "object" => "data_source", "id" => DS, "title" => [{ "plain_text" => "Leads" }], "parent" => { "type" => "database_id", "database_id" => DB }, "properties" => { "Name" => {} }, "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false }
  def feed(results, next_cursor: nil) = { "object" => "list", "results" => results, "next_cursor" => next_cursor, "has_more" => !next_cursor.nil? }

  test "walks the whole feed, fetches schemas for unfetched data sources, walks seeds, and records done" do
    @client.expects(:search).with({ "page_size" => 100, "sort" => { "timestamp" => "last_edited_time", "direction" => "descending" } }).returns(feed([page(SEED), ds_obj], next_cursor: "c2"))
    @client.expects(:search).with({ "page_size" => 100, "sort" => { "timestamp" => "last_edited_time", "direction" => "descending" }, "start_cursor" => "c2" }).returns(feed([page(SecureRandom.uuid)]))
    @client.expects(:get_data_source).with(DS).returns(ds_obj.merge("request_id" => "r"))
    @client.expects(:get_database).with(DB).returns({ "object" => "database", "id" => DB, "title" => [{ "plain_text" => "Leads" }], "data_sources" => [{ "id" => DS, "name" => "Leads" }], "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false })
    @client.expects(:get_block_children).with(SEED, start_cursor: nil, page_size: 100).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })

    stats = Stacks::Notion::Backfill.new(@client, seed_ids: [SEED.delete("-")]).run

    assert_equal 2, stats[:pages]
    assert_equal 1, stats[:schemas]
    assert_equal 1, stats[:seeds]
    assert NotionDataSource.find_by!(notion_id: DS).fetched_at.present?
    assert NotionDatabase.exists?(notion_id: DB)
    assert_equal "done", SourceSync.for(:notion_backfill).reload.cursor["phase"]
  end

  test "resumes the feed from the stored cursor and skips fetched schemas" do
    SourceSync.for(:notion_backfill).advance!(cursor: { "phase" => "feed", "next_cursor" => "c9" })
    NotionDataSource.create!(notion_id: DS, database_id: DB, title: "Leads", data: {}, fetched_at: Time.current)
    NotionDatabase.create!(notion_id: DB, title: "Leads", data: {})
    @client.expects(:search).with { |body| body["start_cursor"] == "c9" }.returns(feed([]))
    @client.expects(:get_data_source).never
    Stacks::Notion::Backfill.new(@client, seed_ids: []).run
    assert_equal "done", SourceSync.for(:notion_backfill).reload.cursor["phase"]
  end

  test "a failure mid-feed keeps the cursor for resume" do
    @client.stubs(:search).returns(feed([page(SecureRandom.uuid)], next_cursor: "c2")).then.raises(Stacks::Notion::RequestError.new(502, {}))
    assert_raises(Stacks::Notion::RequestError) { Stacks::Notion::Backfill.new(@client, seed_ids: []).run }
    assert_equal({ "phase" => "feed", "next_cursor" => "c2" }, SourceSync.for(:notion_backfill).reload.cursor)
  end
end
```

```ruby
# test/lib/stacks/notion/reconcile_test.rb
require 'test_helper'

class StacksNotionReconcileTest < ActiveSupport::TestCase
  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @client = Stacks::Notion.new
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page(id, last_edited: "2026-09-01T00:00:00.000Z", in_trash: false) = { "object" => "page", "id" => id, "last_edited_time" => last_edited, "in_trash" => in_trash, "parent" => { "type" => "workspace", "workspace" => true }, "properties" => {}, "url" => "u" }

  test "unseen pages are disambiguated: trashed → in_trash, 404 → access_lost; drift is counted" do
    seen, trashed, gone, drifted = 4.times.map { SecureRandom.uuid }
    [seen, trashed, gone].each { |id| Stacks::Notion::Mirror.upsert_page(page(id)) }
    Stacks::Notion::Mirror.upsert_page(page(drifted, last_edited: "2026-08-01T00:00:00.000Z"))
    @client.stubs(:search).returns({ "object" => "list", "results" => [page(seen), page(drifted, last_edited: "2026-09-05T00:00:00.000Z")], "next_cursor" => nil, "has_more" => false })
    @client.expects(:get_page).with(trashed).returns(page(trashed, in_trash: true))
    @client.expects(:get_page).with(gone).raises(Stacks::Notion::RequestError.new(404, { "object" => "error", "code" => "object_not_found" }))

    stats = Stacks::Notion::Reconcile.new(@client).run

    assert_equal({ seen: 2, checked: 2, trashed: 1, access_lost: 1, drift: 1 }, stats)
    assert NotionPage.find_by!(notion_id: trashed).in_trash
    assert NotionPage.find_by!(notion_id: gone).access_lost
    assert_equal Time.zone.parse("2026-09-05T00:00:00Z"), NotionPage.find_by!(notion_id: drifted).notion_last_edited_at
  end

  test "the disambiguation limit bounds requests across pages and data sources" do
    ids = 3.times.map { SecureRandom.uuid }
    ids.each { |id| Stacks::Notion::Mirror.upsert_page(page(id)) }
    NotionDataSource.create!(notion_id: SecureRandom.uuid, title: "DS", data: {})
    @client.stubs(:search).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })
    @client.expects(:get_page).twice.with { |id| ids.include?(id) }.returns { |id| page(id, in_trash: true) }
    @client.expects(:get_data_source).never
    stats = Stacks::Notion::Reconcile.new(@client, disambiguation_limit: 2).run
    assert_equal 2, stats[:checked]
    assert_equal 2, stats[:trashed]
  end

  test "unseen data sources are disambiguated too" do
    ds = NotionDataSource.create!(notion_id: SecureRandom.uuid, title: "DS", data: {})
    @client.stubs(:search).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })
    @client.expects(:get_data_source).with(ds.notion_id).raises(Stacks::Notion::RequestError.new(404, { "object" => "error" }))
    stats = Stacks::Notion::Reconcile.new(@client).run
    assert_equal 1, stats[:access_lost]
    assert ds.reload.in_trash
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/stacks/notion/backfill_test.rb test/lib/stacks/notion/reconcile_test.rb`
Expected: `NameError` for both constants.

- [ ] **Step 3: Implement**

```ruby
# lib/stacks/notion/backfill.rb
# One-off, resumable: load every page + data source the integration can see
# (properties only), then every data source schema + database object, then
# the seed page trees. Progress lives in SourceSync(:notion_backfill).cursor.
class Stacks::Notion::Backfill
  SOURCE = :notion_backfill
  DEFAULT_SEEDS = %w[329131fea2c780718aa8f222b25c76e8 dc51296819394138869baaefd534816a].freeze
  FEED_BODY = { "page_size" => 100, "sort" => { "timestamp" => "last_edited_time", "direction" => "descending" } }.freeze

  def self.run_with_lock!(client = Stacks::Notion.new, seed_ids: ENV.fetch("NOTION_SEED_PAGE_IDS", DEFAULT_SEEDS.join(",")).split(","))
    conn = ActiveRecord::Base.connection
    return nil unless conn.select_value("SELECT pg_try_advisory_lock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    begin
      new(client, seed_ids: seed_ids).run
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    end
  end

  def initialize(client, seed_ids:)
    @client = client
    @seed_ids = seed_ids.map { |s| Stacks::Notion::Ids.normalize(s) }.compact
    @stats = Hash.new(0)
  end

  def run
    sync = SourceSync.for(SOURCE)
    cursor = sync.cursor.presence || { "phase" => "feed" }
    walk_feed(sync, cursor) if cursor["phase"] == "feed"
    fetch_schemas(sync) if %w[feed schemas].include?(sync.reload.cursor["phase"])
    walk_seeds(sync)
    sync.advance!(cursor: { "phase" => "done" }, stats: @stats.transform_keys(&:to_s))
    @stats
  end

  private

  def walk_feed(sync, cursor)
    next_cursor = cursor["next_cursor"]
    loop do
      body = FEED_BODY.dup
      body["start_cursor"] = next_cursor if next_cursor
      list = @client.search(body)
      list["results"].each do |obj|
        case obj["object"]
        when "page" then Stacks::Notion::Mirror.upsert_page(obj); @stats[:pages] += 1
        when "data_source" then Stacks::Notion::Mirror.upsert_data_source(obj, fetched_at: nil); @stats[:data_sources] += 1
        end
      end
      next_cursor = list["next_cursor"]
      sync.advance!(cursor: { "phase" => "feed", "next_cursor" => next_cursor })
      break if next_cursor.nil?
    end
    sync.advance!(cursor: { "phase" => "schemas" })
  end

  def fetch_schemas(sync)
    NotionDataSource.where(fetched_at: nil).find_each do |ds|
      Stacks::Notion::Mirror.upsert_data_source(@client.get_data_source(ds.notion_id))
      if ds.database_id && !NotionDatabase.where(notion_id: ds.database_id).where.not(fetched_at: nil).exists?
        Stacks::Notion::Mirror.upsert_database(@client.get_database(ds.database_id))
      end
      @stats[:schemas] += 1
    rescue Stacks::Notion::RequestError => e
      raise unless [403, 404].include?(e.code)
      ds.update!(fetched_at: Time.current, in_trash: true)
      Rails.logger.warn("[Stacks::Notion::Backfill] data source #{ds.notion_id} inaccessible: #{e.message}")
    end
    sync.advance!(cursor: { "phase" => "seeds" })
  end

  def walk_seeds(sync)
    @seed_ids.each do |id|
      Stacks::Notion::TreeFetcher.new(@client).walk(id)
      @stats[:seeds] += 1
    rescue Stacks::Notion::RequestError => e
      Rails.logger.warn("[Stacks::Notion::Backfill] seed #{id} failed: #{e.message}")
    end
  end
end
```

`Mirror.upsert_data_source(obj, fetched_at: nil)` (Task 4) leaves `fetched_at` nil for feed-sourced data source objects, so the schemas phase knows which ones still need `GET /data_sources/:id`.

```ruby
# lib/stacks/notion/reconcile.rb
# Daily: full feed walk; anything cached that the feed no longer returns gets
# one GET to tell "trashed" from "lost access". Reports sweep drift.
class Stacks::Notion::Reconcile
  FEED_BODY = Stacks::Notion::Backfill::FEED_BODY

  def self.run_with_lock!(client = Stacks::Notion.new, disambiguation_limit: 200)
    conn = ActiveRecord::Base.connection
    return nil unless conn.select_value("SELECT pg_try_advisory_lock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    begin
      new(client, disambiguation_limit: disambiguation_limit).run
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    end
  end

  def initialize(client, disambiguation_limit: 200)
    @client = client
    @limit = disambiguation_limit
  end

  def run
    before = NotionPage.pluck(:notion_id, :notion_last_edited_at).to_h
    seen_pages = {}
    seen_ds = Set.new
    cursor = nil
    loop do
      body = FEED_BODY.dup
      body["start_cursor"] = cursor if cursor
      list = @client.search(body)
      list["results"].each do |obj|
        id = Stacks::Notion::Ids.normalize(obj["id"])
        case obj["object"]
        when "page"
          Stacks::Notion::Mirror.upsert_page(obj) # feed objects are full: brings drifted rows current
          seen_pages[id] = Time.zone.parse(obj["last_edited_time"].to_s)
        when "data_source"
          Stacks::Notion::Mirror.upsert_data_source(obj, fetched_at: nil)
          seen_ds << id
        end
      end
      cursor = list["next_cursor"]
      break if cursor.nil?
    end

    drift = seen_pages.count { |id, stamp| before.key?(id) && (before[id].nil? || (stamp && before[id] < stamp)) }
    stats = { seen: seen_pages.size, checked: 0, trashed: 0, access_lost: 0, drift: drift }

    NotionPage.where(in_trash: false, access_lost: false).where.not(notion_id: seen_pages.keys)
              .order(:notion_last_edited_at).limit(@limit).each do |page|
      stats[:checked] += 1
      obj = @client.get_page(page.notion_id)
      Stacks::Notion::Mirror.upsert_page(obj)
      stats[:trashed] += 1 if obj["in_trash"] == true
    rescue Stacks::Notion::RequestError => e
      raise unless [403, 404].include?(e.code)
      page.update!(access_lost: true)
      stats[:access_lost] += 1
    end

    NotionDataSource.where(in_trash: false).where.not(notion_id: seen_ds.to_a)
                    .order(:notion_last_edited_at).limit([@limit - stats[:checked], 0].max).each do |ds|
      stats[:checked] += 1
      obj = @client.get_data_source(ds.notion_id)
      Stacks::Notion::Mirror.upsert_data_source(obj)
      stats[:trashed] += 1 if obj["in_trash"] == true
    rescue Stacks::Notion::RequestError => e
      raise unless [403, 404].include?(e.code)
      ds.update!(in_trash: true)
      stats[:access_lost] += 1
    end
    stats
  end
end
```

- [ ] **Step 4: Add the rake tasks**

Append inside `namespace :notion` in `lib/tasks/notion.rake`:

```ruby
    desc "Notion mirror: one-off, resumable full load of pages, data sources, schemas and seed trees"
    task backfill: :environment do
      system_task = SystemTask.create!(name: "stacks:notion:backfill")
      begin
        stats = Stacks::Notion::Backfill.run_with_lock!
        Rails.logger.info(stats ? "[stacks:notion:backfill] #{stats.inspect}" : "[stacks:notion:backfill] skipped: lock held")
        puts stats.inspect if stats
      rescue => e
        system_task.mark_as_error(e)
        raise # a one-off `heroku run` must exit non-zero so the operator re-runs it
      else
        system_task.mark_as_success
      end
    end

    desc "Notion mirror: daily full-feed reconcile (trash / access-lost / drift)"
    task reconcile: :environment do
      system_task = SystemTask.create!(name: "stacks:notion:reconcile")
      begin
        stats = Stacks::Notion::Reconcile.run_with_lock!
        Rails.logger.info(stats ? "[stacks:notion:reconcile] #{stats.inspect}" : "[stacks:notion:reconcile] skipped: lock held")
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/stacks/notion/backfill_test.rb test/lib/stacks/notion/reconcile_test.rb test/lib/stacks/notion/mirror_test.rb test/lib/tasks/notion_rake_test.rb`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/notion/backfill.rb lib/stacks/notion/reconcile.rb lib/tasks/notion.rake test/lib/stacks/notion/backfill_test.rb test/lib/stacks/notion/reconcile_test.rb
git commit -m "feat: Notion mirror backfill (resumable) and daily reconcile with trash/access-lost disambiguation"
```

---

### Task 12: Markdown renderer (for the `notion-fetch` MCP tool only)

**Files:**
- Create: `lib/stacks/notion/markdown.rb`
- Test: `test/lib/stacks/notion/markdown_test.rb`, fixtures `test/fixtures/files/notion/blocks_tree.json`, `test/fixtures/files/notion/blocks_tree.md`

**Interfaces:**
- Produces: `Stacks::Notion::Markdown.render(page_id) → String` — reads `NotionBlock.children_of` recursively from the mirror (no Notion calls). `Stacks::Notion::Markdown.render_blocks(blocks_by_parent, root_id) → String` — pure function over `{ parent_id => [block Hash, …] }` for tests.

- [ ] **Step 1: Write the fixture and failing golden test**

`test/fixtures/files/notion/blocks_tree.json` (a hash of parent id → block objects; `p` is the page):

```json
{
  "p": [
    {"id":"h1","type":"heading_1","has_children":false,"heading_1":{"rich_text":[{"plain_text":"Title","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}]}},
    {"id":"para","type":"paragraph","has_children":false,"paragraph":{"rich_text":[{"plain_text":"Hello ","annotations":{"bold":true,"italic":false,"strikethrough":false,"code":false},"href":null},{"plain_text":"world","annotations":{"bold":false,"italic":true,"strikethrough":false,"code":false},"href":"https://example.com"}]}},
    {"id":"tog","type":"toggle","has_children":true,"toggle":{"rich_text":[{"plain_text":"More","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}]}},
    {"id":"todo","type":"to_do","has_children":false,"to_do":{"checked":true,"rich_text":[{"plain_text":"Done","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}]}},
    {"id":"call","type":"callout","has_children":false,"callout":{"icon":{"type":"emoji","emoji":"💡"},"rich_text":[{"plain_text":"Note","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}]}},
    {"id":"code","type":"code","has_children":false,"code":{"language":"ruby","rich_text":[{"plain_text":"puts 1","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}]}},
    {"id":"div","type":"divider","has_children":false,"divider":{}},
    {"id":"child","type":"child_page","has_children":true,"child_page":{"title":"Sub"}},
    {"id":"img","type":"image","has_children":false,"image":{"type":"external","external":{"url":"https://img/x.png"},"caption":[]}},
    {"id":"cols","type":"column_list","has_children":true,"column_list":{}},
    {"id":"tbl","type":"table","has_children":true,"table":{"has_column_header":true}},
    {"id":"toc","type":"table_of_contents","has_children":false,"table_of_contents":{}},
    {"id":"weird","type":"synced_block_thing","has_children":false,"synced_block_thing":{}}
  ],
  "tog": [
    {"id":"li1","type":"bulleted_list_item","has_children":false,"bulleted_list_item":{"rich_text":[{"plain_text":"one","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":true},"href":null}]}},
    {"id":"li2","type":"numbered_list_item","has_children":false,"numbered_list_item":{"rich_text":[{"plain_text":"two","annotations":{"bold":false,"italic":false,"strikethrough":true,"code":false},"href":null}]}}
  ],
  "cols": [
    {"id":"c1","type":"column","has_children":true,"column":{}},
    {"id":"c2","type":"column","has_children":true,"column":{}}
  ],
  "c1": [{"id":"c1p","type":"paragraph","has_children":false,"paragraph":{"rich_text":[{"plain_text":"left","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}]}}],
  "c2": [{"id":"c2p","type":"paragraph","has_children":false,"paragraph":{"rich_text":[{"plain_text":"right","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}]}}],
  "tbl": [
    {"id":"r1","type":"table_row","has_children":false,"table_row":{"cells":[[{"plain_text":"A","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}],[{"plain_text":"B","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}]]}},
    {"id":"r2","type":"table_row","has_children":false,"table_row":{"cells":[[{"plain_text":"1","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}],[{"plain_text":"2","annotations":{"bold":false,"italic":false,"strikethrough":false,"code":false},"href":null}]]}}
  ]
}
```

`test/fixtures/files/notion/blocks_tree.md` (exact bytes, one trailing newline; the ```` ```ruby ```` fence inside it is fixture content, not plan markup — the fixture file is everything between the outer ```` ```markdown ```` fences):

```markdown
# Title

**Hello **[*world*](https://example.com)

▸ More
  - `one`
  1. ~~two~~

- [x] Done

> 💡 Note

```ruby
puts 1
```

---

[Sub](notion://page/child)

![image](https://img/x.png)

left

right

| A | B |
| --- | --- |
| 1 | 2 |

<!-- unsupported: synced_block_thing -->
```

```ruby
# test/lib/stacks/notion/markdown_test.rb
require 'test_helper'

class StacksNotionMarkdownTest < ActiveSupport::TestCase
  test "renders the fixture tree to the golden markdown" do
    tree = JSON.parse(file_fixture("notion/blocks_tree.json").read)
    golden = file_fixture("notion/blocks_tree.md").read
    assert_equal golden, Stacks::Notion::Markdown.render_blocks(tree, "p")
  end

  test "render reads from the mirror" do
    page = "3bf131fe-a2c7-8092-87f3-c668e91d5332"
    Stacks::Notion::Mirror.replace_level(parent_id: page, page_id: page, blocks: [
      { "id" => "x", "type" => "paragraph", "has_children" => false, "paragraph" => { "rich_text" => [{ "plain_text" => "hi", "annotations" => {}, "href" => nil }] } }
    ], fetched_at: Time.current)
    assert_equal "hi\n", Stacks::Notion::Markdown.render(page)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/stacks/notion/markdown_test.rb`
Expected: `NameError: uninitialized constant Stacks::Notion::Markdown`

- [ ] **Step 3: Implement**

```ruby
# lib/stacks/notion/markdown.rb
# Block tree → markdown. Deterministic; the only renderer in the mirror, used by
# the notion-fetch MCP tool. The REST proxy never renders anything.
module Stacks::Notion::Markdown
  FLATTEN = %w[column_list column synced_block].freeze
  SKIP = %w[table_of_contents breadcrumb].freeze
  LIST_TYPES = %w[bulleted_list_item numbered_list_item to_do].freeze

  class << self
    def render(page_id)
      page_id = Stacks::Notion::Ids.normalize(page_id) || page_id
      rows = NotionBlock.where(page_id: page_id).order(:position)
      by_parent = rows.group_by(&:parent_id).transform_values { |rs| rs.map(&:data) }
      render_blocks(by_parent, page_id)
    end

    def render_blocks(by_parent, root_id)
      out = []
      render_children(by_parent, root_id, 0, out)
      text = out.join("\n").gsub(/\n{3,}/, "\n\n").strip
      text.empty? ? "" : text + "\n"
    end

    private

    def render_children(by_parent, parent_id, depth, out)
      blocks = by_parent[parent_id] || []
      numbered = 0
      blocks.each_with_index do |b, i|
        type = b["type"]
        numbered = type == "numbered_list_item" ? numbered + 1 : 0
        lines = render_block(by_parent, b, depth, numbered)
        next if lines.nil?
        out.concat(lines)
        nxt = blocks[i + 1]
        # No blank line inside a run of list items; one after everything else.
        next if LIST_TYPES.include?(type) && nxt && LIST_TYPES.include?(nxt["type"])
        out << ""
      end
    end

    def render_block(by_parent, b, depth, numbered)
      type = b["type"]
      body = b[type] || {}
      indent = "  " * depth
      text = rich(body["rich_text"])
      case type
      when *SKIP then nil
      when *FLATTEN
        sub = []
        render_children(by_parent, b["id"], depth, sub)
        sub
      when "paragraph" then [indent + text]
      when "heading_1" then [indent + "# " + text]
      when "heading_2" then [indent + "## " + text]
      when "heading_3" then [indent + "### " + text]
      when "quote" then [indent + "> " + text]
      when "callout"
        icon = body.dig("icon", "emoji")
        [indent + "> " + [icon, text].compact.join(" ")]
      when "bulleted_list_item" then [indent + "- " + text] + nested(by_parent, b, depth)
      when "numbered_list_item" then [indent + "#{numbered}. " + text] + nested(by_parent, b, depth)
      when "to_do" then [indent + (body["checked"] ? "- [x] " : "- [ ] ") + text] + nested(by_parent, b, depth)
      when "toggle" then [indent + "▸ " + text] + nested(by_parent, b, depth)
      when "code"
        lang = body["language"].to_s
        [indent + "```" + lang, indent + text, indent + "```"]
      when "divider" then [indent + "---"]
      when "child_page" then [indent + "[#{body['title']}](notion://page/#{b['id']})"]
      when "child_database" then [indent + "[#{body['title']}](notion://database/#{b['id']})"]
      when "link_to_page"
        target = body["page_id"] || body["database_id"]
        [indent + "[page](notion://page/#{target})"]
      when "image", "file", "pdf", "video", "bookmark", "embed"
        url = body.dig("external", "url") || body.dig("file", "url") || body["url"]
        caption = rich(body["caption"])
        [indent + "![#{caption.presence || type}](#{url})"]
      when "table"
        rows = (by_parent[b["id"]] || []).map { |r| (r.dig("table_row", "cells") || []).map { |cell| rich(cell) } }
        return [] if rows.empty?
        width = rows.map(&:length).max
        header = body["has_column_header"] ? rows.shift : Array.new(width, "")
        lines = [indent + "| " + header.join(" | ") + " |", indent + "| " + Array.new(width, "---").join(" | ") + " |"]
        lines + rows.map { |r| indent + "| " + r.join(" | ") + " |" }
      else
        [indent + "<!-- unsupported: #{type} -->"]
      end
    end

    def nested(by_parent, b, depth)
      return [] unless b["has_children"]
      sub = []
      render_children(by_parent, b["id"], depth + 1, sub)
      sub.reject(&:empty?)
    end

    def rich(runs)
      Array(runs).map do |r|
        t = r["plain_text"].to_s
        a = r["annotations"] || {}
        t = "`#{t}`" if a["code"]
        t = "**#{t}**" if a["bold"]
        t = "*#{t}*" if a["italic"]
        t = "~~#{t}~~" if a["strikethrough"]
        r["href"] ? "[#{t}](#{r['href']})" : t
      end.join
    end
  end
end
```

If the golden test fails on whitespace, fix the **renderer**, not the golden file, until the output matches exactly; the golden file defines the contract (page-mention links, list nesting by two spaces, one blank line between top-level blocks, none inside lists).

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/stacks/notion/markdown_test.rb`
Expected: `2 runs, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/notion/markdown.rb test/lib/stacks/notion/markdown_test.rb test/fixtures/files/notion
git commit -m "feat: Stacks::Notion::Markdown — block tree to markdown with golden fixture"
```

---

### Task 13: MCP tools mirroring Notion's MCP names

**Files:**
- Create: `app/services/mcp/notion_fetch_tool.rb`, `app/services/mcp/notion_search_tool.rb`, `app/services/mcp/notion_query_data_sources_tool.rb`
- Modify: `app/services/mcp/server.rb` (append the three to `TOOLS`)
- Test: `test/services/mcp/notion_tools_test.rb`

**Interfaces:**
- Consumes: `TreeFetcher` (Task 6), `Markdown.render` (Task 12), `Mirror` (Task 4), `Stacks::Notion` (Task 2), `Mcp::Responses`.
- Produces: tools `notion-fetch(id)`, `notion-search(query, page_size = 10, filter = nil)`, `notion-query-data-sources(data_source_id, filter = nil, sorts = nil, page_size = 100, start_cursor = nil)`. All tools build `Stacks::Notion.new(max_retries: 1, retry_after_cap: 6)`; a `Stacks::Notion::RequestError` becomes `Responses.error("Notion #{code} #{body['code']}: #{body['message']}")`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/mcp/notion_tools_test.rb
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/services/mcp/notion_tools_test.rb`
Expected: `NameError: uninitialized constant Mcp::NotionFetchTool`

- [ ] **Step 3: Implement the tools**

```ruby
# app/services/mcp/notion_fetch_tool.rb
module Mcp
  # Mirrors Notion MCP's `notion-fetch`: one page as markdown, from the Stacks
  # mirror. Walks the block tree under a wall-clock deadline; `truncated: true`
  # means call again (the walk resumes) or wait for the next sweep.
  class NotionFetchTool < MCP::Tool
    DEADLINE = 6.0

    tool_name 'notion-fetch'
    description 'Fetch a Notion page (title, properties, markdown body) from the Stacks Notion mirror. truncated=true means call again to finish loading.'
    input_schema(properties: { id: { type: 'string', description: 'Notion page id or URL id (dashed or not)' } }, required: ['id'])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(id:, server_context:)
      page_id = Stacks::Notion::Ids.normalize(id)
      return Responses.error("invalid Notion id: #{id}") unless page_id

      client = Stacks::Notion.new(max_retries: 1, retry_after_cap: 6)
      result = Stacks::Notion::TreeFetcher.new(client, deadline: DEADLINE).walk(page_id)
      page = NotionPage.with_deleted.find_by!(notion_id: page_id)
      Responses.ok(
        id: page.notion_id, title: page.page_title, url: page.url,
        last_edited_time: page.notion_last_edited_at&.utc&.iso8601,
        properties: page.data["properties"] || {},
        markdown: Stacks::Notion::Markdown.render(page_id),
        truncated: !result[:complete],
        fetched_at: page.page_fetched_at&.utc&.iso8601
      )
    rescue Stacks::Notion::RequestError => e
      Responses.error("Notion #{e.code} #{e.body['code']}: #{e.body['message']}")
    end
  end
end
```

```ruby
# app/services/mcp/notion_search_tool.rb
module Mcp
  # Mirrors Notion MCP's `notion-search` (title search). Always live through the
  # paced client; results warm the mirror.
  class NotionSearchTool < MCP::Tool
    tool_name 'notion-search'
    description 'Search Notion page and database titles (live, paced). Returns id, title, url, last_edited_time.'
    input_schema(
      properties: {
        query: { type: 'string' },
        page_size: { type: 'integer', description: '1-100, default 10' },
        filter: { type: 'object', description: 'Notion search filter, e.g. {"property":"object","value":"page"}' }
      },
      required: ['query']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(query:, page_size: 10, filter: nil, server_context:)
      body = { "query" => query, "page_size" => page_size.to_i.clamp(1, 100) }
      body["filter"] = filter if filter.present?
      live = Stacks::Notion.new(max_retries: 1, retry_after_cap: 6).search(body)
      results = Array(live["results"]).map do |obj|
        case obj["object"]
        when "page" then Stacks::Notion::Mirror.upsert_page(obj)
        when "data_source" then Stacks::Notion::Mirror.upsert_data_source(obj)
        end
        { object: obj["object"], id: obj["id"], title: Stacks::Notion::Mirror.title_of(obj), url: obj["url"], last_edited_time: obj["last_edited_time"] }
      end
      Responses.ok(results: results, next_cursor: live["next_cursor"], has_more: live["has_more"])
    rescue Stacks::Notion::RequestError => e
      Responses.error("Notion #{e.code} #{e.body['code']}: #{e.body['message']}")
    end
  end
end
```

```ruby
# app/services/mcp/notion_query_data_sources_tool.rb
module Mcp
  # Mirrors Notion MCP's `notion-query-data-sources` with REST-shaped arguments:
  # the filter/sorts are Notion's own JSON, passed through verbatim (live, paced).
  class NotionQueryDataSourcesTool < MCP::Tool
    tool_name 'notion-query-data-sources'
    description 'Query a Notion data source with Notion-style filter/sorts (POST /v1/data_sources/:id/query, live, paced). Returns Notion\'s list envelope.'
    input_schema(
      properties: {
        data_source_id: { type: 'string' },
        filter: { type: 'object' },
        sorts: { type: 'array' },
        page_size: { type: 'integer', description: '1-100, default 100' },
        start_cursor: { type: 'string' }
      },
      required: ['data_source_id']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(data_source_id:, filter: nil, sorts: nil, page_size: 100, start_cursor: nil, server_context:)
      ds_id = Stacks::Notion::Ids.normalize(data_source_id)
      return Responses.error("invalid data source id: #{data_source_id}") unless ds_id

      body = { "page_size" => page_size.to_i.clamp(1, 100) }
      body["filter"] = filter if filter.present?
      body["sorts"] = sorts if sorts.present?
      body["start_cursor"] = start_cursor if start_cursor.present?
      live = Stacks::Notion.new(max_retries: 1, retry_after_cap: 6).query_data_source(ds_id, body)
      Array(live["results"]).each { |obj| Stacks::Notion::Mirror.upsert_page(obj) if obj["object"] == "page" }
      Responses.ok(live)
    rescue Stacks::Notion::RequestError => e
      Responses.error("Notion #{e.code} #{e.body['code']}: #{e.body['message']}")
    end
  end
end
```

In `app/services/mcp/server.rb`, append to `TOOLS` after `Mcp::GetClientRevenueTool,`:

```ruby
      Mcp::NotionFetchTool,
      Mcp::NotionSearchTool,
      Mcp::NotionQueryDataSourcesTool,
```

The filter test in Step 1 expects the tool to send `{"filter" => …, "page_size" => 100}` — key order does not matter for the mocha `with` hash comparison.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/services/mcp/notion_tools_test.rb`
Expected: `6 runs, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add app/services/mcp/notion_fetch_tool.rb app/services/mcp/notion_search_tool.rb app/services/mcp/notion_query_data_sources_tool.rb app/services/mcp/server.rb test/services/mcp/notion_tools_test.rb
git commit -m "feat: notion-fetch / notion-search / notion-query-data-sources MCP tools over the mirror"
```

---

### Task 14: Live parity test and `stacks:notion:verify_parity`

**Files:**
- Create: `test/live/notion_parity_test.rb`, `lib/stacks/notion/parity.rb`
- Modify: `lib/tasks/notion.rake`

**Interfaces:**
- Produces: `Stacks::Notion::Parity.run(app_base_url: nil, api_key: nil, io: $stdout) → { passed: Integer, failed: Integer, failures: [String] }`. When `app_base_url` is nil it exercises the Rails app in-process via `ActionDispatch::Integration::Session`; when given (e.g. `https://stacks.garden3d.net`) it uses HTTParty against the deployed app. Direct Notion calls use `Stacks::Notion` with `NOTION_RPS` as configured. Comparison ignores `request_id` and `request_status` at the top level.

- [ ] **Step 1: Write the parity runner**

```ruby
# lib/stacks/notion/parity.rb
# Proves the proxy is a one-to-one mirror: for a fixed set of real ids, the
# proxy's response (cold, then warm) must equal Notion's own, ignoring the
# per-request keys. Run by test/live/notion_parity_test.rb (NOTION_LIVE=1) and
# by `bin/rails stacks:notion:verify_parity`. Makes real Notion requests.
class Stacks::Notion::Parity
  IGNORED = Stacks::Notion::Mirror::VOLATILE_KEYS
  HOM_GUIDE_PAGE = "3bf131fea2c7809287f3c668e91d5332"   # plain page (title property key "title")
  LEADS_DB       = "4d9b46b8bad542509f144347db37964d"
  LEADS_DS       = "8ac2bac5-bc47-4674-851e-d1b1e4f779f2"
  TASKS_DS       = "e5d5d0da-a85e-4b3f-b900-9fd06a315622"

  def initialize(app_base_url: nil, api_key: nil, io: $stdout)
    @base = app_base_url
    @key = api_key || Stacks::Utils.config[:stacks][:private_api_key]
    @io = io
    @notion = Stacks::Notion.new
    @result = { passed: 0, failed: 0, failures: [] }
  end

  def self.run(**opts) = new(**opts).run

  def run
    leads_row = @notion.query_data_source(LEADS_DS, { "page_size" => 1 })["results"].first["id"]

    check("GET pages/:id (plain page) cold=miss")   { compare_get("/pages/#{HOM_GUIDE_PAGE}", @notion.get_page(HOM_GUIDE_PAGE), expect: "miss") }
    check("GET pages/:id (plain page) warm=hit")    { compare_get("/pages/#{HOM_GUIDE_PAGE}", @notion.get_page(HOM_GUIDE_PAGE), expect: "hit") }
    check("GET pages/:id (database row) cold/warm") { compare_get("/pages/#{leads_row}", @notion.get_page(leads_row)); compare_get("/pages/#{leads_row}", @notion.get_page(leads_row), expect: "hit") }
    check("GET databases/:id")                      { compare_get("/databases/#{LEADS_DB}", @notion.get_database(LEADS_DB)); compare_get("/databases/#{LEADS_DB}", @notion.get_database(LEADS_DB), expect: "hit") }
    check("GET data_sources/:id")                   { compare_get("/data_sources/#{LEADS_DS}", @notion.get_data_source(LEADS_DS)); compare_get("/data_sources/#{LEADS_DS}", @notion.get_data_source(LEADS_DS), expect: "hit") }
    check("GET blocks/:id/children every cursor page, cold then warm") { compare_level(HOM_GUIDE_PAGE) }
    check("POST data_sources/:id/query with filter (live)") do
      body = { "filter" => { "timestamp" => "last_edited_time", "last_edited_time" => { "after" => 7.days.ago.utc.iso8601 } }, "page_size" => 5 }
      compare_post("/data_sources/#{TASKS_DS}/query", body, @notion.query_data_source(TASKS_DS, body), expect: "live", tolerate_edit_drift: true)
    end
    check("POST search (live)") do
      body = { "query" => "Human Operating Manual", "page_size" => 3 }
      compare_post("/search", body, @notion.search(body), expect: "live", tolerate_edit_drift: true)
    end
    check("row seeded from a search result then GET pages/:id equals Notion's GET") do
      hit = @notion.search({ "query" => "Leads", "page_size" => 5, "filter" => { "property" => "object", "value" => "page" } })["results"].first
      NotionPage.with_deleted.where(notion_id: Stacks::Notion::Ids.normalize(hit["id"])).each(&:destroy_fully!)
      Stacks::Notion::Mirror.upsert_page(hit)
      compare_get("/pages/#{hit['id']}", @notion.get_page(hit["id"]), expect: "hit")
    end

    @io.puts "parity: #{@result[:passed]} passed, #{@result[:failed]} failed"
    @result[:failures].each { |f| @io.puts "  FAIL #{f}" }
    @result
  end

  private

  def check(name)
    yield
    @result[:passed] += 1
    @io.puts "  ok   #{name}"
  rescue => e
    @result[:failed] += 1
    @result[:failures] << "#{name}: #{e.message.lines.first&.strip}"
    @io.puts "  FAIL #{name}: #{e.message}"
  end

  def scrub(h) = h.deep_dup.tap { |x| IGNORED.each { |k| x.delete(k) } }

  def compare_get(path, notion_body, expect: nil)
    status, headers, body = proxy(:get, path)
    raise "proxy #{status}: #{body}" unless status == 200
    raise "expected X-Stacks-Cache=#{expect}, got #{headers['X-Stacks-Cache']}" if expect && headers["X-Stacks-Cache"] != expect
    diff = Hashdiff.diff(scrub(notion_body), scrub(body))
    raise "body differs: #{diff.first(5).inspect}" unless diff.empty?
  end

  def compare_post(path, req_body, notion_body, expect:, tolerate_edit_drift: false)
    status, headers, body = proxy(:post, path, req_body)
    raise "proxy #{status}: #{body}" unless status == 200
    raise "expected X-Stacks-Cache=#{expect}, got #{headers['X-Stacks-Cache']}" if headers["X-Stacks-Cache"] != expect
    a = scrub(notion_body); b = scrub(body)
    if tolerate_edit_drift
      a = a.merge("results" => a["results"].map { |r| r["id"] }); b = b.merge("results" => b["results"].map { |r| r["id"] })
      a.delete("next_cursor"); b.delete("next_cursor")
    end
    diff = Hashdiff.diff(a, b)
    raise "body differs: #{diff.first(5).inspect}" unless diff.empty?
  end

  def compare_level(parent)
    cursor = nil
    loop do
      notion = @notion.get_block_children(parent, start_cursor: cursor, page_size: 100)
      status, _headers, body = proxy(:get, "/blocks/#{parent}/children#{cursor ? "?start_cursor=#{cursor}" : ""}")
      raise "proxy #{status}" unless status == 200
      diff = Hashdiff.diff(scrub(notion).except("next_cursor"), scrub(body).except("next_cursor"))
      raise "cold level differs at cursor=#{cursor.inspect}: #{diff.first(5).inspect}" unless diff.empty?
      cursor = notion["next_cursor"]
      break if cursor.nil?
    end
    # warm: the whole level must now come from cache and equal Notion's concatenation
    notion_all = Stacks::Notion::TreeFetcher.fetch_level(@notion, parent_id: parent, page_id: parent).first.map { |b| scrub(b) }
    proxied = []
    cursor = nil
    loop do
      status, headers, body = proxy(:get, "/blocks/#{parent}/children#{cursor ? "?start_cursor=#{cursor}" : ""}")
      raise "proxy #{status}" unless status == 200
      raise "warm level not a hit (#{headers['X-Stacks-Cache']})" unless headers["X-Stacks-Cache"] == "hit"
      proxied.concat(body["results"].map { |b| scrub(b) })
      cursor = body["next_cursor"]
      break if cursor.nil?
    end
    diff = Hashdiff.diff(notion_all, proxied)
    raise "warm level differs: #{diff.first(5).inspect}" unless diff.empty?
  end

  # → [status, headers, parsed_body]
  def proxy(method, path, body = nil)
    if @base
      resp = HTTParty.send(method, "#{@base}/api/notion/v1#{path}", headers: { "X-Api-Key" => @key, "Content-Type" => "application/json" }, body: body&.to_json)
      # HTTParty headers are a Net::HTTPHeader: to_h yields Array values.
      headers = resp.headers.to_h.each_with_object({}) do |(k, v), h|
        h[k.to_s.split("-").map(&:capitalize).join("-")] = v.is_a?(Array) ? v.first : v
      end
      [resp.code, headers, resp.parsed_response]
    else
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.host! "localhost"
      session.send(method, "/api/notion/v1#{path}", params: body&.to_json, headers: { "X-Api-Key" => @key, "Content-Type" => "application/json" })
      [session.response.status, session.response.headers, JSON.parse(session.response.body)]
    end
  end
end
```

`destroy_fully!` is acts_as_paranoid 0.7's hard delete (there is no `really_destroy!` in this version).

- [ ] **Step 2: Write the live test (self-skipping) and the rake task**

```ruby
# test/live/notion_parity_test.rb
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
```

Append to `lib/tasks/notion.rake` inside `namespace :notion`:

```ruby
    desc "Notion mirror: live parity check against api.notion.com (optional APP_BASE_URL for a deployed app)"
    task verify_parity: :environment do
      result = Stacks::Notion::Parity.run(app_base_url: ENV["APP_BASE_URL"].presence, api_key: ENV["STACKS_API_KEY"].presence)
      abort("parity FAILED") if result[:failed].positive?
    end
```

- [ ] **Step 3: Confirm the test skips in a normal run**

Run: `bin/rails test test/live/notion_parity_test.rb`
Expected: `1 runs, 0 assertions, 0 failures, 0 errors, 1 skips`

- [ ] **Step 4: Run it live (this spends ~40 Notion requests)**

Run: `NOTION_LIVE=1 NOTION_RPS=2 bin/rails test test/live/notion_parity_test.rb`
Expected: every check prints `ok`, `1 runs, 2 assertions, 0 failures`. If a check fails, the **proxy** is wrong, not the check: fix the controller/mirror until the bodies match. Two known-legitimate differences may appear and are handled by the runner: `request_id`/`request_status` (ignored) and live lists (compared by result ids). If a body differs on a key the spec did not anticipate (for example a field present on GET but absent on search objects), STOP and report it — that is a spec deviation the owner must see.

Save the output: `NOTION_LIVE=1 NOTION_RPS=2 bin/rails test test/live/notion_parity_test.rb 2>&1 | tee docs/notion-mirror-parity-2026-09-10.txt`

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/notion/parity.rb test/live/notion_parity_test.rb lib/tasks/notion.rake docs/notion-mirror-parity-2026-09-10.txt
git commit -m "test: live Notion parity check (NOTION_LIVE=1) and stacks:notion:verify_parity"
```

---

### Task 15: Deploy doc, full suite, PR

**Files:**
- Create: `docs/notion-mirror-deploy.md`

- [ ] **Step 1: Write the deploy doc**

```markdown
# Notion mirror — deploy notes

Spec: `docs/superpowers/specs/2026-09-10-notion-mirror-design.md`.

## Env / config vars (Heroku)

| var | web dynos | scheduler commands |
| --- | --- | --- |
| `NOTION_RPS` | `0.6` | `1.2` (set inline on each command) |
| `NOTION_SEED_PAGE_IDS` | — | optional; default `329131fea2c780718aa8f222b25c76e8,dc51296819394138869baaefd534816a` |
| `NOTION_SWEEP_OVERLAP` | — | optional, seconds, default 300 |

Credentials (every host block): `notion.token` (existing), `stacks.private_api_key` (existing).

## Deploy order (phase 1 ships the migration)

1. `heroku run bin/rails db:migrate` **before** the release goes live (no `release:` phase in the Procfile).
2. Push / release.
3. Scheduler: add `NOTION_RPS=1.2 bin/rails stacks:notion:sweep` every 10 minutes and `NOTION_RPS=1.2 bin/rails stacks:notion:reconcile` daily. `stacks:sync_notion` stays as it is.
4. One-off: `heroku run NOTION_RPS=1.2 bin/rails stacks:notion:backfill` — re-run until `SourceSync(notion_backfill).cursor.phase == "done"`.
5. Parity against prod: `APP_BASE_URL=https://stacks.garden3d.net STACKS_API_KEY=… bin/rails stacks:notion:verify_parity` from a laptop with the dev token.
6. Switch stacksbot reads: `TOOLS.md` `## Notion` reads → `https://stacks.garden3d.net/api/notion/v1/...` with `X-Api-Key`; `notion-query-dump.mjs` / `ops-preread-dump.mjs` gain `NOTION_BASE_URL` + auth header. Writes stay on `ntn`.

## Behavioural notes (deviations from a pure mirror)

- Responses carry `X-Stacks-Cache: hit|stale|miss|live` and `X-Stacks-Fetched-At`.
- Cached bodies omit `request_id` (and `request_status`); live pass-throughs keep them.
- `GET blocks/:id/children` on a miss asks Notion for `page_size=100` regardless of the caller's `page_size`; the caller's `page_size` is honoured on hits.
- Notion file URLs expire ~1 h after fetch; a cached body may carry an expired one.
- Trashed pages and lost access are learned by the daily reconcile, not the sweep.
- Queries and searches are never served from cache.

## Watching it

ActiveAdmin → Dashboard → ETL: Source syncs: `notion_mirror` (watermark + per-run stats: `requests_spent`, `trees_refreshed`, `pages_still_stale`), `notion_backfill` (phase). Request log lines: `[Stacks::Notion] GET /pages/… 200 412ms`.
```

- [ ] **Step 2: Run every new test file, then the full suite**

Run: `bin/rails test test/lib/stacks/notion_test.rb test/lib/stacks/notion_sync_database_test.rb test/lib/stacks/notion test/models/notion_page_test.rb test/controllers/api/notion test/services/mcp/notion_tools_test.rb test/lib/tasks/notion_rake_test.rb`
Expected: all pass.

Then check no other `rails test` is running (`ps -o pid,etime,command -ax | grep "[r]ails test"`) and run: `bin/rails test --exclude "/EtlRakeTest/"`
Expected: 0 failures, 0 errors (the count grows by roughly 60 tests over the 1,306 baseline). If `AdminUserTest#test_It_creates_the_user's_initial_salary_window_on_create` fails between 20:00 and 24:00 ET, that is the known time-zone flake, not this work.

- [ ] **Step 3: Commit and open the PR**

```bash
git add docs/notion-mirror-deploy.md
git commit -m "docs: Notion mirror deploy notes"
git push -u origin worktree-notion-read-cache
gh pr create --title "feat: Notion mirror — one-to-one caching proxy of Notion's API" --body-file - <<'EOF'
## Summary
- `Stacks::Notion` on Notion-Version 2026-03-11 with a class-level pacer and Retry-After handling
- Mirror tables (`notion_pages` extended, `notion_blocks`, `notion_data_sources`, `notion_databases`) holding raw Notion objects
- `/api/notion/v1/*` caching reverse proxy (same paths/bodies/responses as Notion), `X-Api-Key` auth
- `notion-fetch`, `notion-search`, `notion-query-data-sources` MCP tools
- `stacks:notion:sweep` (10 min), `backfill` (one-off), `reconcile` (daily)
- Live parity test (`NOTION_LIVE=1`) — output in `docs/notion-mirror-parity-2026-09-10.txt`

Spec: `docs/superpowers/specs/2026-09-10-notion-mirror-design.md`. Deploy: `docs/notion-mirror-deploy.md` (migrate before release).

## Test plan
- [ ] full suite green locally (excluding EtlRakeTest)
- [ ] live parity run attached
- [ ] Heroku CI green

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01LWRCs8SgcVwVQBNTQEP59V
EOF
```

---

## Self-review notes (done while writing)

- Spec coverage: Ids (T1), client (T2), schema + scopes + dead code (T3), mirror + paranoid rules + title (T4), `sync_database` on `database_id` (T5), TreeFetcher with deadline/recheck/wanted (T6), proxy auth/errors/single objects (T7), level cache (T8), queries/search/writes (T9), sweep (T10), backfill/reconcile (T11), renderer (T12), MCP tools (T13), parity (T14), deploy doc + Scheduler entries (T15). Webhook and corpus connector are deliberately phase 3.
- Type consistency: `Mirror.upsert_page(obj, fetched_at:)`, `Mirror.replace_level(parent_id:, page_id:, blocks:, fetched_at:)`, `Mirror.store_blocks(parent_id:, page_id:, blocks:, position_offset:)`, `TreeFetcher.new(client, deadline:)#walk(page_id) → {complete:, requests:}`, `TreeFetcher.fetch_level(client, parent_id:, page_id:) → [blocks, requests]`, `Sweep::ADVISORY_LOCK_KEY` used by Backfill/Reconcile, `Stacks::Notion.new(max_retries:, retry_after_cap:)` everywhere.
- Known simplification vs spec: `GET blocks/:id/children` on a miss returns Notion's live body (with its `request_id`), which is why that test asserts the key is present; cached hits omit it.
