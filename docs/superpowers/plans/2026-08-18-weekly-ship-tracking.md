# Weekly Ship Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect ingested ships@sanctuary.computer emails to ProjectTrackers via an in-app LLM matcher (`Stacks::AI` facade → Anthropic), surface each tracker's last weekly ship in the admin index with overdue flagging, and link out to Google Groups.

**Architecture:** Two new tables (`weekly_ships` links, `ship_scans` content-hash-keyed scan state), a provider-agnostic `Stacks::AI.extract` facade (HTTParty Anthropic adapter, native structured outputs), a nightly sweep chained into `stacks:etl:sync_all`, an index column fed by one bulk query, and a thin ActiveAdmin audit/override resource.

**Tech Stack:** Rails 6.1 / Ruby 3.1.7, minitest + mocha, HTTParty (no new gems).

**Spec:** `docs/superpowers/specs/2026-08-18-weekly-ship-tracking-design.md` (rev 2 — read it; it encodes decisions from an adversarial review against live data).

## Global Constraints

- Anthropic model id for tier `:fast` (verbatim): `claude-haiku-4-5`. API version header (verbatim): `anthropic-version: 2023-06-01`. Endpoint: `POST https://api.anthropic.com/v1/messages`. Auth header: `x-api-key`.
- Structured output via `output_config: {format: {type: "json_schema", schema: ...}}` — NEVER the deprecated top-level `output_format`. Schemas must set `"additionalProperties" => false` and `"required"`. JSON-schema numeric ranges (minimum/maximum) are NOT supported — validate confidence range in Ruby.
- A response with `stop_reason == "max_tokens"` is an error, not a result.
- Retry 429 and 529 (and 5xx) twice with backoff before raising `Stacks::AI::Error`; respect a `retry-after` header when present. 400/401/403 raise immediately.
- Credentials: `Stacks::Utils.config[:anthropic][:api_key]` (may be nil → `Stacks::AI.configured?` false). Provider selection `Stacks::Utils.config.dig(:ai, :provider)` defaulting to `"anthropic"`.
- Group email (verbatim): `ships@sanctuary.computer`. Backfill LLM bound: documents older than 90 days at scan time → `out_of_scope`, NO LLM call.
- Confidence threshold: `Stacks::WeeklyShips::Sweep::CONFIDENCE_THRESHOLD = 0.6`.
- Sweep candidate rule: no ship_scan row OR `documents.content_hash != ship_scans.scanned_content_hash`; never touch `human_locked` scans. Re-scan refreshes `sent_at`/`sent_by_*` and may ADD links; never auto-removes.
- Candidate trackers: `ProjectTracker.where(work_completed_at: nil)`.
- Permalink id preference: `raw_metadata["gmail_message_ids"].first`, fallback `external_id`; strip angle brackets; CGI-escape; nil for non-google_groups documents.
- Own-brand tokens the LLM system prompt must warn about: Sanctuary, Sanctuary Computer, XXIX, Manhattan Hydraulics, Index, Garden3D.
- Tests: `bin/rails test <path>`. Run ONLY targeted test files locally (full suite is CI's job). All targeted tests green before each commit.
- Commit trailer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Migrations + `WeeklyShip` / `ShipScan` models + `Document#google_groups_permalink`

**Files:**
- Create: `db/migrate/<timestamp>_create_weekly_ships.rb`, `db/migrate/<timestamp>_create_ship_scans.rb` (use `bin/rails g migration` to get timestamps, then replace bodies)
- Create: `app/models/weekly_ship.rb`, `app/models/ship_scan.rb`
- Modify: `app/models/document.rb` (add `google_groups_permalink` + a `ships_group` scope)
- Test: `test/models/weekly_ship_test.rb`, `test/models/document_permalink_test.rb`

**Interfaces:**
- Produces: `WeeklyShip` (belongs_to :document, :project_tracker; enum `matched_by: {llm: 0, human: 1}`; fields sent_at, sent_by_email, sent_by_name, confidence, rationale; `via_sweep` attr_accessor — when NOT set, any create/update/destroy human-locks the document's scan). `ShipScan` (belongs_to :document; enum `outcome: {linked: 0, no_match: 1, not_a_ship: 2, out_of_scope: 3}`; scanned_content_hash, scanned_at, human_locked). `Document.ships_group` scope; `Document#google_groups_permalink` → String or nil.

- [ ] **Step 1: Write migrations**

```ruby
class CreateWeeklyShips < ActiveRecord::Migration[6.1]
  def change
    create_table :weekly_ships do |t|
      t.references :document, null: false, foreign_key: true
      t.references :project_tracker, null: false, foreign_key: true
      t.datetime :sent_at, null: false
      t.string :sent_by_email
      t.string :sent_by_name
      t.integer :matched_by, null: false
      t.float :confidence
      t.text :rationale
      t.timestamps
    end
    add_index :weekly_ships, [:document_id, :project_tracker_id], unique: true
    add_index :weekly_ships, [:project_tracker_id, :sent_at]
  end
end
```

```ruby
class CreateShipScans < ActiveRecord::Migration[6.1]
  def change
    create_table :ship_scans do |t|
      t.references :document, null: false, foreign_key: true, index: { unique: true }
      t.integer :outcome, null: false
      t.string :scanned_content_hash
      t.datetime :scanned_at, null: false
      t.boolean :human_locked, null: false, default: false
      t.timestamps
    end
  end
end
```

Run `bin/rails db:migrate` (also migrates the test DB via schema load on next test run).

- [ ] **Step 2: Write the failing tests**

`test/models/weekly_ship_test.rb`:

```ruby
require 'test_helper'

class WeeklyShipTest < ActiveSupport::TestCase
  def make_document(external_id: "<root-#{SecureRandom.hex(4)}@mail.gmail.com>", gmail_ids: nil)
    Document.create!(
      source: :google_groups,
      external_id: external_id,
      title: "[Client] Weekly Ship",
      occurred_at: Time.zone.now,
      raw_metadata: { "group_email" => "ships@sanctuary.computer",
                      "gmail_message_ids" => gmail_ids || [external_id] }
    )
  end

  def make_tracker(name: "Client Project")
    ProjectTracker.create!(name: name)
  end

  test "human create locks the document's scan as linked" do
    doc = make_document
    WeeklyShip.create!(document: doc, project_tracker: make_tracker,
                       sent_at: Time.zone.now, matched_by: :human)
    scan = ShipScan.find_by(document: doc)
    assert scan.human_locked?
    assert scan.linked?
  end

  test "human destroy of the last link marks the scan no_match and locked" do
    doc = make_document
    ship = WeeklyShip.create!(document: doc, project_tracker: make_tracker,
                              sent_at: Time.zone.now, matched_by: :human)
    ship.destroy!
    scan = ShipScan.find_by(document: doc)
    assert scan.human_locked?
    assert scan.no_match?
  end

  test "sweep-created ships (via_sweep) do not human-lock the scan" do
    doc = make_document
    ship = WeeklyShip.new(document: doc, project_tracker: make_tracker,
                          sent_at: Time.zone.now, matched_by: :llm)
    ship.via_sweep = true
    ship.save!
    assert_nil ShipScan.find_by(document: doc)
  end

  test "defaults matched_by to human when not set by the sweep" do
    doc = make_document
    ship = WeeklyShip.create!(document: doc, project_tracker: make_tracker, sent_at: Time.zone.now)
    assert ship.human?
  end

  test "rejects duplicate document+tracker pairs" do
    doc = make_document
    tracker = make_tracker
    WeeklyShip.create!(document: doc, project_tracker: tracker, sent_at: Time.zone.now, matched_by: :human)
    assert_raises(ActiveRecord::RecordInvalid) do
      WeeklyShip.create!(document: doc, project_tracker: tracker, sent_at: Time.zone.now, matched_by: :human)
    end
  end
end
```

`test/models/document_permalink_test.rb`:

```ruby
require 'test_helper'

class DocumentPermalinkTest < ActiveSupport::TestCase
  def doc(external_id:, gmail_ids:, source: :google_groups, group: "ships@sanctuary.computer")
    Document.new(source: source, external_id: external_id, occurred_at: Time.zone.now,
                 raw_metadata: { "group_email" => group, "gmail_message_ids" => gmail_ids })
  end

  test "prefers the first gmail message id and escapes + and @" do
    d = doc(external_id: "<root@x.com>", gmail_ids: ["<CAJQ+abc=def@mail.gmail.com>"])
    assert_equal "https://groups.google.com/a/sanctuary.computer/d/msgid/ships/CAJQ%2Babc%3Ddef%40mail.gmail.com",
                 d.google_groups_permalink
  end

  test "falls back to external_id when gmail_message_ids is empty or missing" do
    d = doc(external_id: "<root@mail.gmail.com>", gmail_ids: [])
    assert_equal "https://groups.google.com/a/sanctuary.computer/d/msgid/ships/root%40mail.gmail.com",
                 d.google_groups_permalink
    d2 = doc(external_id: "<root@mail.gmail.com>", gmail_ids: nil)
    assert_equal "https://groups.google.com/a/sanctuary.computer/d/msgid/ships/root%40mail.gmail.com",
                 d2.google_groups_permalink
  end

  test "nil for non-google_groups sources and blank group email" do
    assert_nil doc(external_id: "<x@y>", gmail_ids: ["<x@y>"], source: :meet).google_groups_permalink
    assert_nil doc(external_id: "<x@y>", gmail_ids: ["<x@y>"], group: nil).google_groups_permalink
  end

  test "ships_group scope filters by group email" do
    a = Document.create!(source: :google_groups, external_id: "<a@m>", occurred_at: Time.zone.now,
                         raw_metadata: { "group_email" => "ships@sanctuary.computer" })
    Document.create!(source: :google_groups, external_id: "<b@m>", occurred_at: Time.zone.now,
                     raw_metadata: { "group_email" => "other@sanctuary.computer" })
    assert_equal [a.id], Document.ships_group.pluck(:id)
  end
end
```

- [ ] **Step 3: Run tests to verify they fail** — `bin/rails test test/models/weekly_ship_test.rb test/models/document_permalink_test.rb` → NameError / NoMethodError expected. (If Document.create! demands fields not listed here, mirror what `lib/stacks/etl/connector.rb` sets — adjust the helpers, not the assertions.)

- [ ] **Step 4: Implement**

`app/models/weekly_ship.rb`:

```ruby
# One (ship email × project tracker) link. Created by the nightly
# Stacks::WeeklyShips::Sweep (matched_by: llm, via_sweep set) or by humans in
# ActiveAdmin (matched_by defaults to human). Any human write locks the
# document's ShipScan so the sweep never overrides human judgment.
class WeeklyShip < ApplicationRecord
  belongs_to :document
  belongs_to :project_tracker

  enum matched_by: { llm: 0, human: 1 }

  validates :sent_at, presence: true
  validates :project_tracker_id, uniqueness: { scope: :document_id }

  # Set by the sweep so pipeline writes skip the human-lock callbacks.
  attr_accessor :via_sweep

  before_validation { self.matched_by ||= :human unless via_sweep }

  after_save    :human_lock_scan!, unless: :via_sweep
  after_destroy :human_lock_scan_after_destroy!, unless: :via_sweep

  private

  def human_lock_scan!
    upsert_scan!(outcome: :linked)
  end

  def human_lock_scan_after_destroy!
    outcome = document.weekly_ships.where.not(id: id).exists? ? :linked : :no_match
    upsert_scan!(outcome: outcome)
  end

  def upsert_scan!(outcome:)
    scan = ShipScan.find_or_initialize_by(document: document)
    scan.update!(outcome: outcome, human_locked: true,
                 scanned_at: Time.zone.now,
                 scanned_content_hash: document.content_hash)
  end
end
```

Also add `has_many :weekly_ships, dependent: :destroy` to `app/models/document.rb` and `app/models/project_tracker.rb`.

`app/models/ship_scan.rb`:

```ruby
# Scan bookkeeping for the weekly-ship sweep — one row per examined ships@
# document. Keyed on content_hash so reply-clobbered threads (the ETL rebuilds
# a thread's document when replies arrive) get re-scanned. human_locked scans
# are never touched by the sweep.
class ShipScan < ApplicationRecord
  belongs_to :document

  enum outcome: { linked: 0, no_match: 1, not_a_ship: 2, out_of_scope: 3 }

  validates :outcome, :scanned_at, presence: true
end
```

In `app/models/document.rb` add:

```ruby
  SHIPS_GROUP_EMAIL = "ships@sanctuary.computer".freeze

  scope :ships_group, -> {
    where(source: :google_groups).where("raw_metadata->>'group_email' = ?", SHIPS_GROUP_EMAIL)
  }

  # Google Groups' d/msgid redirector resolves an RFC822 Message-ID to the
  # thread in the Groups UI (click-test verified 2026-08-18). Prefer a
  # message-id known to be IN the group (gmail_message_ids.first) — thread
  # roots (external_id) are sometimes never-posted ancestors (7/242 in dev).
  def google_groups_permalink
    return nil unless google_groups?
    group = raw_metadata&.dig("group_email").presence
    return nil unless group&.include?("@")
    local, domain = group.split("@", 2)
    id = Array(raw_metadata["gmail_message_ids"]).first.presence || external_id
    return nil if id.blank?
    "https://groups.google.com/a/#{domain}/d/msgid/#{local}/#{CGI.escape(id.delete_prefix('<').delete_suffix('>'))}"
  end
```

(Adjust the enum predicate `google_groups?` if Document's enum generates a different name — check the model.)

- [ ] **Step 5: Run tests to verify green** — both files pass.
- [ ] **Step 6: Commit** — `feat: WeeklyShip/ShipScan models + Google Groups msgid permalinks` (add migrations, models, tests, and `db/schema.rb`).

---

### Task 2: `Stacks::AI` facade + Anthropic provider

**Files:**
- Create: `lib/stacks/ai.rb`, `lib/stacks/ai/providers/anthropic.rb`
- Test: `test/lib/stacks/ai_test.rb`, `test/lib/stacks/ai/providers/anthropic_test.rb`

**Interfaces:**
- Produces: `Stacks::AI.extract(system:, prompt:, schema:, tier: :fast)` → `Stacks::AI::Result` (Struct with `data` Hash, `input_tokens`, `output_tokens`); `Stacks::AI.configured?` → Boolean; `Stacks::AI::Error < StandardError`. Provider maps `:fast` → `claude-haiku-4-5`.

- [ ] **Step 1: Write the failing tests**

`test/lib/stacks/ai_test.rb`:

```ruby
require 'test_helper'

class StacksAITest < ActiveSupport::TestCase
  SCHEMA = {
    "type" => "object",
    "properties" => { "answer" => { "type" => "string" } },
    "required" => ["answer"],
    "additionalProperties" => false
  }.freeze

  test "extract delegates to the configured provider and returns its result" do
    result = Stacks::AI::Result.new({ "answer" => "hi" }, 10, 5)
    Stacks::AI::Providers::Anthropic.expects(:extract)
      .with(system: "sys", prompt: "p", schema: SCHEMA, tier: :fast)
      .returns(result)
    out = Stacks::AI.extract(system: "sys", prompt: "p", schema: SCHEMA)
    assert_equal({ "answer" => "hi" }, out.data)
    assert_equal 10, out.input_tokens
  end

  test "configured? reflects the provider's key presence" do
    Stacks::AI::Providers::Anthropic.stubs(:configured?).returns(false)
    refute Stacks::AI.configured?
  end

  test "unknown provider raises" do
    Stacks::Utils.stubs(:config).returns({ ai: { provider: "openai" } })
    assert_raises(Stacks::AI::Error) { Stacks::AI.provider }
  end
end
```

`test/lib/stacks/ai/providers/anthropic_test.rb` — stub HTTParty at the class level (mirror how other lib clients are tested with mocha):

```ruby
require 'test_helper'

class StacksAIProvidersAnthropicTest < ActiveSupport::TestCase
  SCHEMA = {
    "type" => "object",
    "properties" => { "n" => { "type" => "integer" } },
    "required" => ["n"],
    "additionalProperties" => false
  }.freeze

  def setup
    Stacks::Utils.stubs(:config).returns({ anthropic: { api_key: "sk-test" } })
  end

  def fake_response(code: 200, body: {})
    resp = mock
    resp.stubs(:code).returns(code)
    resp.stubs(:parsed_response).returns(body)
    resp.stubs(:headers).returns({})
    resp
  end

  def success_body(text: '{"n": 3}', stop: "end_turn")
    { "content" => [{ "type" => "text", "text" => text }],
      "stop_reason" => stop,
      "usage" => { "input_tokens" => 100, "output_tokens" => 20 } }
  end

  test "posts the structured-output request shape and parses the result" do
    Stacks::AI::Providers::Anthropic.expects(:post).with do |path, opts|
      body = JSON.parse(opts[:body])
      path == "/messages" &&
        body["model"] == "claude-haiku-4-5" &&
        body.dig("output_config", "format", "type") == "json_schema" &&
        body.dig("output_config", "format", "schema") == SCHEMA &&
        opts[:headers]["x-api-key"] == "sk-test" &&
        opts[:headers]["anthropic-version"] == "2023-06-01"
    end.returns(fake_response(body: success_body))

    result = Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    assert_equal({ "n" => 3 }, result.data)
    assert_equal 100, result.input_tokens
    assert_equal 20, result.output_tokens
  end

  test "retries 429 then succeeds" do
    Stacks::AI::Providers::Anthropic.stubs(:sleep)
    Stacks::AI::Providers::Anthropic.expects(:post).twice
      .returns(fake_response(code: 429), fake_response(body: success_body))
    result = Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    assert_equal({ "n" => 3 }, result.data)
  end

  test "raises after exhausting retries on 529" do
    Stacks::AI::Providers::Anthropic.stubs(:sleep)
    Stacks::AI::Providers::Anthropic.stubs(:post).returns(fake_response(code: 529))
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "raises immediately on 400 without retrying" do
    Stacks::AI::Providers::Anthropic.expects(:post).once
      .returns(fake_response(code: 400, body: { "error" => { "message" => "bad" } }))
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "raises on stop_reason max_tokens" do
    Stacks::AI::Providers::Anthropic.stubs(:post)
      .returns(fake_response(body: success_body(stop: "max_tokens")))
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "raises when required schema keys are missing from the parsed payload" do
    Stacks::AI::Providers::Anthropic.stubs(:post)
      .returns(fake_response(body: success_body(text: '{"other": 1}')))
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "configured? false without a key; extract raises" do
    Stacks::Utils.stubs(:config).returns({})
    refute Stacks::AI::Providers::Anthropic.configured?
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "unknown tier raises" do
    assert_raises(ArgumentError) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :galaxy)
    end
  end
end
```

- [ ] **Step 2: Verify RED** — `bin/rails test test/lib/stacks/ai_test.rb test/lib/stacks/ai/providers/anthropic_test.rb`

- [ ] **Step 3: Implement**

`lib/stacks/ai.rb`:

```ruby
# Provider-agnostic facade for direct LLM calls from Stacks. Call sites depend
# ONLY on this module — swapping providers means writing one adapter class
# under Stacks::AI::Providers and flipping config[:ai][:provider].
module Stacks
  module AI
    class Error < StandardError; end

    # data: validated Hash conforming to the requested schema.
    Result = Struct.new(:data, :input_tokens, :output_tokens)

    PROVIDERS = { "anthropic" => "Stacks::AI::Providers::Anthropic" }.freeze

    class << self
      # tier: :fast (cheap classification) — :smart reserved, unmapped for now.
      def extract(system:, prompt:, schema:, tier: :fast)
        provider.extract(system: system, prompt: prompt, schema: schema, tier: tier)
      end

      def configured?
        provider.configured?
      end

      def provider
        name = Stacks::Utils.config.dig(:ai, :provider).presence || "anthropic"
        klass = PROVIDERS[name.to_s] or raise Error, "Unknown AI provider: #{name}"
        klass.constantize
      end
    end
  end
end
```

`lib/stacks/ai/providers/anthropic.rb`:

```ruby
class Stacks::AI::Providers::Anthropic
  include HTTParty
  base_uri "https://api.anthropic.com/v1"

  # Abstract tiers — call sites never name provider models.
  TIER_MODELS = { fast: "claude-haiku-4-5" }.freeze
  MAX_TOKENS = 512
  RETRYABLE_CODES = [429, 500, 529].freeze
  MAX_ATTEMPTS = 3

  class << self
    def configured?
      api_key.present?
    end

    def extract(system:, prompt:, schema:, tier:)
      model = TIER_MODELS.fetch(tier) { raise ArgumentError, "Unknown Stacks::AI tier: #{tier}" }
      raise Stacks::AI::Error, "Anthropic API key not configured" unless configured?

      response = post_with_retries(
        model: model,
        max_tokens: MAX_TOKENS,
        system: system,
        messages: [{ role: "user", content: prompt }],
        # Native structured outputs — the deprecated top-level `output_format`
        # param must not be used.
        output_config: { format: { type: "json_schema", schema: schema } }
      )

      parsed = response.parsed_response
      raise Stacks::AI::Error, "Response truncated (stop_reason=max_tokens)" if parsed["stop_reason"] == "max_tokens"

      text = parsed.dig("content", 0, "text")
      data = begin
        JSON.parse(text.to_s)
      rescue JSON::ParserError => e
        raise Stacks::AI::Error, "Unparseable structured output: #{e.message}"
      end
      validate!(data, schema)

      usage = parsed["usage"] || {}
      Stacks::AI::Result.new(data, usage["input_tokens"].to_i, usage["output_tokens"].to_i)
    end

    private

    def post_with_retries(body)
      attempts = 0
      loop do
        attempts += 1
        response = post("/messages", headers: headers, body: body.to_json)
        code = response.code.to_i
        return response if code == 200

        if RETRYABLE_CODES.include?(code) && attempts < MAX_ATTEMPTS
          sleep((response.headers["retry-after"] || 2**attempts).to_i)
          next
        end
        message = response.parsed_response.is_a?(Hash) ? response.parsed_response.dig("error", "message") : nil
        raise Stacks::AI::Error, "Anthropic API error #{code}: #{message || "unknown"}"
      end
    end

    # Shallow safety net over the API-side schema enforcement.
    def validate!(data, schema)
      raise Stacks::AI::Error, "Structured output is not an object" unless data.is_a?(Hash)
      missing = Array(schema["required"]) - data.keys
      raise Stacks::AI::Error, "Structured output missing keys: #{missing.join(", ")}" if missing.any?
    end

    def headers
      {
        "x-api-key" => api_key,
        "anthropic-version" => "2023-06-01",
        "content-type" => "application/json"
      }
    end

    def api_key
      Stacks::Utils.config.dig(:anthropic, :api_key)
    end
  end
end
```

Note: `lib/` is autoloaded — the nesting `Stacks::AI::Providers::Anthropic` needs `lib/stacks/ai/providers/anthropic.rb` and Zeitwerk will infer the `Providers` namespace module automatically. If Zeitwerk complains about the `AI` acronym, add `"ai" => "AI"` handling via the existing inflection config (check `config/initializers/inflections.rb`; create the acronym entry if absent) — and note it in your report.

- [ ] **Step 4: Verify GREEN** — both test files.
- [ ] **Step 5: Commit** — `feat: Stacks::AI facade with Anthropic structured-output provider`

---

### Task 3: `Stacks::WeeklyShips::Sweep` + rake task

**Files:**
- Create: `lib/stacks/weekly_ships/sweep.rb`
- Modify: `lib/tasks/etl.rake` (new task + chain into `stacks:etl:sync_all`)
- Test: `test/lib/stacks/weekly_ships/sweep_test.rb`

**Interfaces:**
- Consumes: Task 1 models + `Document.ships_group`; Task 2 `Stacks::AI.extract` / `.configured?` (stub in tests); `Chunk` (content, position, speaker_name, speaker_contact_id); `DocumentContact` (role "sender", email, name); `SystemTask` (`mark_as_success` / `mark_as_error`).
- Produces: `Stacks::WeeklyShips::Sweep.run!` → Hash stats `{ scanned:, linked:, no_match:, not_a_ship:, out_of_scope:, errored:, skipped_no_key:, input_tokens:, output_tokens: }`; rake `stacks:etl:match_weekly_ships`.

- [ ] **Step 1: Write the failing tests** — create documents with real Chunk rows (position 0 carries the sender speaker) and DocumentContacts, stub `Stacks::AI.extract`, cover every path:

```ruby
require 'test_helper'

class StacksWeeklyShipsSweepTest < ActiveSupport::TestCase
  def setup
    Stacks::AI.stubs(:configured?).returns(true)
    @tracker = ProjectTracker.create!(name: "Copilot Money Homepage")
  end

  def make_ship_doc(title: "[Copilot Money] Weekly Ship", occurred_at: 1.day.ago,
                    sender_email: "hugh@sanctuary.computer", sender_name: "Hugh Francis",
                    content_hash: SecureRandom.hex(8))
    doc = Document.create!(
      source: :google_groups, external_id: "<#{SecureRandom.hex(6)}@mail.gmail.com>",
      title: title, occurred_at: occurred_at, content_hash: content_hash,
      raw_metadata: { "group_email" => "ships@sanctuary.computer", "gmail_message_ids" => [] }
    )
    doc.chunks.create!(position: 0, content: "This week we shipped things.",
                       speaker_name: sender_name, source: :google_groups, occurred_at: occurred_at)
    doc.document_contacts.create!(role: "sender", email: sender_email, name: sender_name)
    doc
  end

  def ai_result(tracker_ids: [], not_a_ship: false, confidence: 0.9, rationale: "r")
    Stacks::AI::Result.new(
      { "tracker_ids" => tracker_ids, "not_a_ship" => not_a_ship,
        "confidence" => confidence, "rationale" => rationale }, 100, 20)
  end

  test "links a ship to the tracker the LLM names, with sender + provenance" do
    doc = make_ship_doc
    Stacks::AI.stubs(:extract).returns(ai_result(tracker_ids: [@tracker.id]))
    stats = Stacks::WeeklyShips::Sweep.run!
    ship = WeeklyShip.find_by(document: doc, project_tracker: @tracker)
    assert ship.llm?
    assert_equal "hugh@sanctuary.computer", ship.sent_by_email
    assert_equal "Hugh Francis", ship.sent_by_name
    assert_equal doc.occurred_at.to_i, ship.sent_at.to_i
    assert_equal 0.9, ship.confidence
    assert ShipScan.find_by(document: doc).linked?
    assert_equal 1, stats[:linked]
  end

  test "multi-tracker ships create one link per tracker" do
    other = ProjectTracker.create!(name: "XXIX 3.0 Website")
    make_ship_doc
    Stacks::AI.stubs(:extract).returns(ai_result(tracker_ids: [@tracker.id, other.id]))
    Stacks::WeeklyShips::Sweep.run!
    assert_equal 2, WeeklyShip.count
  end

  test "not_a_ship and low-confidence outcomes record scans without links" do
    doc1 = make_ship_doc(title: "Lunch plans")
    doc2 = make_ship_doc(title: "[Mystery] Weekly Ship")
    Stacks::AI.stubs(:extract)
      .returns(ai_result(not_a_ship: true), ai_result(tracker_ids: [@tracker.id], confidence: 0.3))
    Stacks::WeeklyShips::Sweep.run!
    assert ShipScan.find_by(document: doc1).not_a_ship?
    assert ShipScan.find_by(document: doc2).no_match?
    assert_equal 0, WeeklyShip.count
  end

  test "documents older than 90 days are out_of_scope with no LLM call" do
    doc = make_ship_doc(occurred_at: 120.days.ago)
    Stacks::AI.expects(:extract).never
    Stacks::WeeklyShips::Sweep.run!
    assert ShipScan.find_by(document: doc).out_of_scope?
  end

  test "already-scanned documents with unchanged content_hash are skipped" do
    doc = make_ship_doc(content_hash: "abc")
    ShipScan.create!(document: doc, outcome: :no_match, scanned_at: 1.day.ago,
                     scanned_content_hash: "abc")
    Stacks::AI.expects(:extract).never
    Stacks::WeeklyShips::Sweep.run!
  end

  test "changed content_hash re-scans: refreshes sent fields and adds links, never removes" do
    doc = make_ship_doc(content_hash: "v2", occurred_at: Time.zone.now)
    ship = WeeklyShip.new(document: doc, project_tracker: @tracker,
                          sent_at: 8.days.ago, matched_by: :llm)
    ship.via_sweep = true
    ship.save!
    ShipScan.create!(document: doc, outcome: :linked, scanned_at: 8.days.ago,
                     scanned_content_hash: "v1")
    other = ProjectTracker.create!(name: "F2")
    Stacks::AI.stubs(:extract).returns(ai_result(tracker_ids: [other.id]))
    Stacks::WeeklyShips::Sweep.run!
    assert WeeklyShip.exists?(document: doc, project_tracker: @tracker), "existing link must not be removed"
    assert WeeklyShip.exists?(document: doc, project_tracker: other)
    assert_equal doc.occurred_at.to_i, ship.reload.sent_at.to_i, "sent_at must refresh on re-scan"
  end

  test "human_locked scans are never re-processed even when content changes" do
    doc = make_ship_doc(content_hash: "v2")
    ShipScan.create!(document: doc, outcome: :no_match, scanned_at: 1.day.ago,
                     scanned_content_hash: "v1", human_locked: true)
    Stacks::AI.expects(:extract).never
    Stacks::WeeklyShips::Sweep.run!
  end

  test "AI errors leave no scan row (retry next night) and count as errored" do
    make_ship_doc
    Stacks::AI.stubs(:extract).raises(Stacks::AI::Error, "boom")
    stats = Stacks::WeeklyShips::Sweep.run!
    assert_equal 0, ShipScan.count
    assert_equal 1, stats[:errored]
  end

  test "without an API key the LLM pass is skipped entirely" do
    Stacks::AI.stubs(:configured?).returns(false)
    make_ship_doc
    Stacks::AI.expects(:extract).never
    stats = Stacks::WeeklyShips::Sweep.run!
    assert_equal 0, ShipScan.count
    assert_equal 1, stats[:skipped_no_key]
  end

  test "prompt candidates are ranked with subject-matching trackers first" do
    ProjectTracker.create!(name: "Zzz Unrelated")
    make_ship_doc(title: "[Copilot Money] Weekly Ship")
    captured = nil
    Stacks::AI.stubs(:extract).with { |kw| captured = kw[:prompt]; true }
      .returns(ai_result(tracker_ids: [@tracker.id]))
    Stacks::WeeklyShips::Sweep.run!
    assert captured.index("Copilot Money Homepage") < captured.index("Zzz Unrelated")
  end
end
```

(Adjust `make_ship_doc`'s Chunk/DocumentContact creation to the real column set — read the models/migrations first; keep the assertions.)

- [ ] **Step 2: Verify RED**

- [ ] **Step 3: Implement** `lib/stacks/weekly_ships/sweep.rb`:

```ruby
module Stacks
  module WeeklyShips
    # Nightly matcher connecting ships@ documents to ProjectTrackers.
    # Design notes live in docs/superpowers/specs/2026-08-18-weekly-ship-tracking-design.md —
    # notably: content-hash-keyed re-scans (reply-clobbered threads), LLM
    # classifies every candidate (heuristics only pre-rank the prompt), 90-day
    # backfill bound, human_locked scans untouchable.
    class Sweep
      CONFIDENCE_THRESHOLD = 0.6
      BACKFILL_WINDOW = 90.days
      BODY_CHARS = 2_000

      SCHEMA = {
        "type" => "object",
        "properties" => {
          "tracker_ids" => { "type" => "array", "items" => { "type" => "integer" } },
          "not_a_ship" => { "type" => "boolean" },
          "confidence" => { "type" => "number" },
          "rationale" => { "type" => "string" }
        },
        "required" => %w[tracker_ids not_a_ship confidence rationale],
        "additionalProperties" => false
      }.freeze

      OWN_BRANDS = ["sanctuary computer", "sanctuary", "xxix", "manhattan hydraulics",
                    "index", "garden3d"].freeze

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You classify internal "weekly ship" emails sent to ships@sanctuary.computer,
        matching each email to the client project(s) it reports on.

        Rules:
        - Studio brand names (Sanctuary Computer, XXIX, Manhattan Hydraulics, Index,
          Garden3D) appear in subjects as the SENDER's studio, not the project —
          never match on them alone.
        - An email may cover several projects, or none of the candidates.
        - not_a_ship is true for emails that are not weekly ship reports at all.
        - Only include tracker ids you are genuinely confident about; confidence is
          your overall 0-1 confidence in the ids you returned.
      PROMPT

      def self.run!
        new.run!
      end

      def run!
        stats = Hash.new(0)
        unless Stacks::AI.configured?
          stats[:skipped_no_key] = candidates.count
          Rails.logger.warn("[weekly_ships] No AI key configured — skipped #{stats[:skipped_no_key]} documents")
          return stats
        end

        trackers = candidate_trackers
        candidates.find_each do |doc|
          process(doc, trackers, stats)
        end
        Rails.logger.info("[weekly_ships] #{stats.inspect}")
        stats
      end

      private

      def candidates
        Document.ships_group
          .joins("LEFT JOIN ship_scans ON ship_scans.document_id = documents.id")
          .where("ship_scans.id IS NULL OR (ship_scans.human_locked = FALSE AND documents.content_hash IS DISTINCT FROM ship_scans.scanned_content_hash)")
      end

      def candidate_trackers
        ProjectTracker.where(work_completed_at: nil).map do |pt|
          names = ([pt.name] + pt.forecast_projects.map(&:name)).compact.uniq
          { id: pt.id, names: names, normalized: names.map { |n| normalize(n) } }
        end
      end

      def process(doc, trackers, stats)
        stats[:scanned] += 1
        if doc.occurred_at < BACKFILL_WINDOW.ago
          record_scan!(doc, :out_of_scope)
          stats[:out_of_scope] += 1
          return
        end

        result = Stacks::AI.extract(system: SYSTEM_PROMPT, prompt: prompt_for(doc, trackers), schema: SCHEMA)
        stats[:input_tokens] += result.input_tokens
        stats[:output_tokens] += result.output_tokens
        data = result.data

        if data["not_a_ship"]
          record_scan!(doc, :not_a_ship)
          stats[:not_a_ship] += 1
        elsif data["tracker_ids"].any? && data["confidence"].to_f >= CONFIDENCE_THRESHOLD
          link!(doc, data, trackers)
          record_scan!(doc, :linked)
          stats[:linked] += 1
        else
          Rails.logger.info("[weekly_ships] no_match doc=#{doc.id}: #{data["rationale"]}")
          record_scan!(doc, :no_match)
          stats[:no_match] += 1
        end
      rescue Stacks::AI::Error => e
        # No scan row → retried next night.
        Rails.logger.error("[weekly_ships] doc=#{doc.id} failed: #{e.message}")
        stats[:errored] += 1
      end

      def link!(doc, data, trackers)
        valid_ids = trackers.map { |t| t[:id] }
        sender_name, sender_email = sender_for(doc)

        data["tracker_ids"].uniq.each do |tracker_id|
          next unless valid_ids.include?(tracker_id)
          ship = WeeklyShip.find_or_initialize_by(document: doc, project_tracker_id: tracker_id)
          ship.via_sweep = true
          ship.matched_by ||= :llm
          ship.assign_attributes(sent_at: doc.occurred_at, sent_by_email: sender_email,
                                 sent_by_name: sender_name,
                                 confidence: data["confidence"], rationale: data["rationale"])
          ship.save!
        end
        # Reply-clobber refresh: existing links keep pace with the document.
        doc.weekly_ships.where.not(project_tracker_id: data["tracker_ids"]).find_each do |ship|
          ship.via_sweep = true
          ship.update!(sent_at: doc.occurred_at, sent_by_email: sender_email, sent_by_name: sender_name)
        end
      end

      # Sender = speaker of the first chunk (reply re-ingests rebuild
      # document_contacts to the repliers, so position 0 is the reliable
      # signal); email via the matching sender contact.
      def sender_for(doc)
        first_chunk = doc.chunks.order(:position).first
        name = first_chunk&.speaker_name
        contact = doc.document_contacts.where(role: "sender").detect { |c| c.name == name } ||
                  doc.document_contacts.where(role: "sender").first
        [name || contact&.name, contact&.email]
      end

      def prompt_for(doc, trackers)
        subject = doc.title.to_s
        normalized_subject = normalize(subject)
        ranked = trackers.sort_by do |t|
          hit = t[:normalized].any? { |n| n.present? && !OWN_BRANDS.include?(n) && normalized_subject.include?(n) }
          hit ? 0 : 1
        end
        body = doc.chunks.order(:position).limit(5).pluck(:content).join("\n")[0, BODY_CHARS]
        sender_name, sender_email = sender_for(doc)

        <<~PROMPT
          Subject: #{subject}
          Sender: #{sender_name} <#{sender_email}>

          Body (truncated):
          #{body}

          Candidate project trackers (likely matches first):
          #{ranked.map { |t| "- id #{t[:id]}: #{t[:names].join(" / ")}" }.join("\n")}
        PROMPT
      end

      def record_scan!(doc, outcome)
        scan = ShipScan.find_or_initialize_by(document: doc)
        return if scan.human_locked?
        scan.update!(outcome: outcome, scanned_at: Time.zone.now, scanned_content_hash: doc.content_hash)
      end

      def normalize(s)
        s.to_s.downcase.gsub(/[^0-9a-z ]/, " ").squeeze(" ").strip
      end
    end
  end
end
```

In `lib/tasks/etl.rake`, add a task following the existing SystemTask-wrapped pattern in that file, and append it to the `stacks:etl:sync_all` chain the same way existing sources are chained (rescued so a failure never blocks other steps):

```ruby
  desc "Match ships@ emails to project trackers"
  task match_weekly_ships: :environment do
    system_task = SystemTask.create!(name: "stacks:etl:match_weekly_ships")
    begin
      stats = Stacks::WeeklyShips::Sweep.run!
      if stats[:errored].positive?
        system_task.mark_as_error(StandardError.new("#{stats[:errored]} documents failed: #{stats.inspect}"))
      else
        system_task.mark_as_success
      end
    rescue => e
      system_task.mark_as_error(e)
    end
  end
```

(Read `lib/tasks/etl.rake` first and mirror its exact chaining/rescue idiom for `sync_all`; if `mark_as_error` expects an exception, the above fits — verify against `app/models/system_task.rb`.)

- [ ] **Step 4: Verify GREEN** — `bin/rails test test/lib/stacks/weekly_ships/sweep_test.rb` plus re-run Task 1 model tests.
- [ ] **Step 5: Commit** — `feat: nightly weekly-ship sweep matching ships@ emails to trackers`

---

### Task 4: `ProjectTracker` support + index column

**Files:**
- Modify: `app/models/project_tracker.rb` (association exists from Task 1; add `last_weekly_ship` + bulk loader)
- Modify: `app/admin/project_trackers.rb` (controller collection ivar + index column)
- Test: `test/models/project_tracker_weekly_ships_test.rb`

**Interfaces:**
- Consumes: `WeeklyShip` (Task 1), google_groups_permalink (Task 1).
- Produces: `ProjectTracker#last_weekly_ship` → WeeklyShip or nil; `WeeklyShip.latest_by_tracker(tracker_ids)` → `{tracker_id => WeeklyShip}`; index column "Last Ship" on in_progress + dormant scopes.

- [ ] **Step 1: Write the failing tests**

```ruby
require 'test_helper'

class ProjectTrackerWeeklyShipsTest < ActiveSupport::TestCase
  def make_doc
    Document.create!(source: :google_groups, external_id: "<#{SecureRandom.hex(6)}@m>",
                     occurred_at: Time.zone.now,
                     raw_metadata: { "group_email" => "ships@sanctuary.computer",
                                     "gmail_message_ids" => [] })
  end

  def make_ship(tracker, sent_at:)
    ship = WeeklyShip.new(document: make_doc, project_tracker: tracker,
                          sent_at: sent_at, matched_by: :llm)
    ship.via_sweep = true
    ship.save!
    ship
  end

  test "last_weekly_ship returns the most recent by sent_at" do
    pt = ProjectTracker.create!(name: "X")
    make_ship(pt, sent_at: 10.days.ago)
    newest = make_ship(pt, sent_at: 2.days.ago)
    assert_equal newest.id, pt.last_weekly_ship.id
  end

  test "latest_by_tracker bulk-loads one newest ship per tracker" do
    a = ProjectTracker.create!(name: "A")
    b = ProjectTracker.create!(name: "B")
    make_ship(a, sent_at: 5.days.ago)
    newest_a = make_ship(a, sent_at: 1.day.ago)
    newest_b = make_ship(b, sent_at: 3.days.ago)
    c = ProjectTracker.create!(name: "C")

    map = WeeklyShip.latest_by_tracker([a.id, b.id, c.id])
    assert_equal newest_a.id, map[a.id].id
    assert_equal newest_b.id, map[b.id].id
    assert_nil map[c.id]
  end

  test "ship_staleness classifies by 7/14 day boundaries" do
    pt = ProjectTracker.create!(name: "X")
    assert_equal :never, ProjectTracker.ship_staleness(nil)
    assert_equal :fresh, ProjectTracker.ship_staleness(make_ship(pt, sent_at: 3.days.ago))
    assert_equal :stale, ProjectTracker.ship_staleness(make_ship(pt, sent_at: 8.days.ago))
    assert_equal :overdue, ProjectTracker.ship_staleness(make_ship(pt, sent_at: 15.days.ago))
  end
end
```

- [ ] **Step 2: Verify RED**

- [ ] **Step 3: Implement**

`WeeklyShip` class method:

```ruby
  # {tracker_id => newest WeeklyShip} for the given ids, one query.
  def self.latest_by_tracker(tracker_ids)
    where(project_tracker_id: tracker_ids)
      .order(:project_tracker_id, sent_at: :desc)
      .group_by(&:project_tracker_id)
      .transform_values(&:first)
  end
```

`ProjectTracker`:

```ruby
  def last_weekly_ship
    weekly_ships.order(sent_at: :desc).first
  end

  # Staleness for the "Last Ship" index pill. Weekly cadence: fresh ≤7d,
  # stale (orange) >7d, overdue (red) >14d or never shipped.
  def self.ship_staleness(ship)
    return :never if ship.nil?
    days = (Date.today - ship.sent_at.to_date).to_i
    if days > 14 then :overdue
    elsif days > 7 then :stale
    else :fresh
    end
  end
```

`app/admin/project_trackers.rb` — in the ActionController `collection` path (where the tracker list is materialized, ~line 88-110), after the collection is built set:

```ruby
      @last_ships_by_tracker_id = WeeklyShip.includes(:document).latest_by_tracker(collection.map(&:id))
```

(Read the controller block first; place it so it runs for the index action on all scopes, using whatever local holds the materialized tracker array.)

In the `index` block, add a column immediately BEFORE the `:actions` column:

```ruby
    column "Last Ship" do |pt|
      ship = (@last_ships_by_tracker_id || {})[pt.id]
      staleness = ProjectTracker.ship_staleness(ship)
      dormant_scope = params[:scope] == "dormant"
      if ship.nil?
        if dormant_scope
          span "No ships yet", style: "opacity: 0.5;"
        else
          span "No ships yet", class: "pill error"
        end
      else
        pill_class =
          if dormant_scope then "pill"
          elsif staleness == :overdue then "pill error"
          elsif staleness == :stale then "pill at_risk"
          else "pill"
          end
        label = "#{time_ago_in_words(ship.sent_at)} ago by #{(ship.sent_by_name || ship.sent_by_email).to_s.split(" ").first} ↗"
        url = ship.document&.google_groups_permalink
        if url
          link_to(url, target: "_blank", rel: "noopener") { span label, class: pill_class }
        else
          span label, class: pill_class
        end
      end
    end
```

Skip the column entirely on the complete scope if the index block branches per scope; if it doesn't, the column renders harmlessly there — leave it (do not restructure the index for this).

- [ ] **Step 4: Verify GREEN** — `bin/rails test test/models/project_tracker_weekly_ships_test.rb`, plus boot check `bin/rails runner 'Rails.application.eager_load!; puts "ok"'`.
- [ ] **Step 5: Commit** — `feat: Last Ship column on project tracker index`

---

### Task 5: ActiveAdmin WeeklyShips resource + tracker panel

**Files:**
- Create: `app/admin/weekly_ships.rb`
- Modify: `app/admin/project_trackers.rb` (show page panel)
- Test: none beyond boot/eager-load check (no admin-page test precedent in this repo; model behavior already covered)

**Interfaces:** Consumes everything prior. Produces `/admin/weekly_ships` (audit + manual override) and a "Weekly Ships" panel on the tracker show page.

- [ ] **Step 1: Implement** `app/admin/weekly_ships.rb`:

```ruby
ActiveAdmin.register WeeklyShip do
  menu label: "Weekly Ships", parent: "Documents", if: -> { true }

  permit_params :document_id, :project_tracker_id, :sent_at

  filter :project_tracker
  filter :matched_by, as: :select, collection: WeeklyShip.matched_bies.keys
  filter :sent_at

  index do
    selectable_column
    column("Subject") { |ws| ws.document.title }
    column("Sender") { |ws| ws.sent_by_name || ws.sent_by_email }
    column :sent_at
    column :project_tracker
    column("Matched By") { |ws| span ws.matched_by, class: "pill" }
    column :confidence
    column("Google Groups") do |ws|
      url = ws.document.google_groups_permalink
      link_to("Open ↗", url, target: "_blank", rel: "noopener") if url
    end
    actions
  end

  show do
    attributes_table do
      row("Subject") { |ws| ws.document.title }
      row(:project_tracker)
      row("Sender") { |ws| "#{ws.sent_by_name} <#{ws.sent_by_email}>" }
      row(:sent_at)
      row(:matched_by)
      row(:confidence)
      row(:rationale)
      row("Google Groups") do |ws|
        url = ws.document.google_groups_permalink
        link_to("Open in Google Groups ↗", url, target: "_blank", rel: "noopener") if url
      end
    end
  end

  form do |f|
    f.inputs do
      f.input :document, as: :select,
        collection: Document.ships_group.order(occurred_at: :desc).limit(200).map { |d| [d.title, d.id] }
      f.input :project_tracker, as: :select,
        collection: ProjectTracker.where(work_completed_at: nil).order(:name).pluck(:name, :id)
      f.input :sent_at, as: :datetime_picker
    end
    f.actions
  end

  # Human creates via this form get sent_at defaulted from the document and
  # matched_by :human via the model callback chain.
  before_save do |ship|
    ship.sent_at ||= ship.document&.occurred_at
  end
end
```

(Match the menu/`parent` convention used by other admin files — read a couple of existing `app/admin/*.rb` for the house style; if there is no "Documents" menu parent, register without `parent`. If `datetime_picker` isn't available, use the default input. If `matched_bies` isn't the enum plural, use `WeeklyShip.matched_bys` / the generated method.)

- [ ] **Step 2: Tracker show panel** — in `app/admin/project_trackers.rb`'s `show` block (find it; add after existing panels):

```ruby
    panel "Weekly Ships" do
      ships = resource.weekly_ships.includes(:document).order(sent_at: :desc).limit(20)
      if ships.any?
        table_for ships do
          column("Sent") { |ws| "#{time_ago_in_words(ws.sent_at)} ago" }
          column("Subject") { |ws| ws.document.title }
          column("Sender") { |ws| ws.sent_by_name || ws.sent_by_email }
          column("") do |ws|
            url = ws.document.google_groups_permalink
            link_to("Open ↗", url, target: "_blank", rel: "noopener") if url
          end
        end
      else
        para em("No weekly ships linked yet.")
      end
    end
```

- [ ] **Step 3: Verify** — `bin/rails runner 'Rails.application.eager_load!; puts ActiveAdmin.application.namespaces[:admin].resources.keys.grep(/Weekly/)'` prints the resource; re-run Task 1 model tests (human-lock callbacks are the load-bearing behavior for this UI).
- [ ] **Step 4: Commit** — `feat: WeeklyShips admin resource + tracker show panel`

---

### Task 6: Verification (targeted only — CI runs the full suite)

- [ ] Run every test file this branch added, in one command; all green.
- [ ] Boot check: `bin/rails runner 'Rails.application.eager_load!; puts Stacks::AI.provider; puts Stacks::WeeklyShips::Sweep::CONFIDENCE_THRESHOLD'`
- [ ] `git status --short` clean; commit anything outstanding.
