# Ghost ↔ Stacks Contact Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two-way sync between stacks `Contact` records and Ghost (garden3d.ghost.io) members, with stacks sources recorded verbatim as Ghost labels for email segmentation, and Ghost signups flowing back as `g3d:ghost:*` sources.

**Architecture:** Full-state reconciliation sweep (`Stacks::GhostSync#sync_all!`) run by a rake task on Heroku Scheduler + an ActiveAdmin "Sync now" button; Ghost webhooks (`POST /webhooks/ghost`) are a latency optimization only. Stacks owns segmentation (labels named exactly after enabled sources), Ghost owns opt-in state (newsletters) and deliverability. See spec: `docs/superpowers/specs/2026-07-20-ghost-contact-sync-design.md`.

**Tech Stack:** Rails 6.1 / Ruby 3.1, PostgreSQL, HTTParty, `jwt` gem, ActiveAdmin, minitest + mocha (NO webmock — stub with mocha).

## Global Constraints

- Ghost Admin API v6: base `#{api_url}/ghost/api/admin`, header `Accept-Version: v6.0`, auth `Authorization: Ghost <jwt>` (HS256, `kid` = key id, secret **hex-decoded**, `exp` ≤ 5 min, `aud: "/admin/"`).
- Credentials already exist: `Stacks::Utils.config[:ghost]` → `:api_url` (`https://garden3d.ghost.io`), `:admin_api_key` (`id:secret`), `:content_api_key`. `:webhook_secret` added in Task 7.
- Labels are exact source names (no prefix): source `newsletter` → Ghost label `newsletter`. The managed label set = the enabled source names (`GhostSyncedSource.pluck(:source)`); never touch member labels outside that set. Unchecking a source stops managing its labels (existing ones remain in Ghost). Never write `newsletters` on member update. Never delete Ghost members. Never mutate `contact.email` from Ghost data.
- Inbound source names: `g3d:ghost:<newsletter-slug>` per active subscription; bare `g3d:ghost` for members with no active newsletters.
- All API bodies are wrapped: `{"members": [{...}]}`. Duplicate-email create returns HTTP 422.
- Run tests with `bin/rails test <path>`. Commit after every green task.

---

### Task 1: Migration, GhostSyncedSource model, and `Contact#record_source_events!` extraction

**Files:**
- Create: `db/migrate/20260720000001_add_ghost_to_contacts.rb`
- Create: `app/models/ghost_synced_source.rb`
- Modify: `app/models/contact.rb` (add scopes + `record_source_events!`)
- Modify: `app/controllers/api/contacts_controller.rb` (delegate to the model method)
- Test: `test/models/ghost_synced_source_test.rb`, `test/models/contact_test.rb` (add cases)

**Interfaces:**
- Produces: `Contact#ghost_id` (string, unique-indexed), `Contact#ghost_data` (Hash, default `{}`), `GhostSyncedSource` (columns: `source` string unique), `Contact#record_source_events!(sources)` (appends `{added_at: now()}` per source via SQL `jsonb_set`), scopes `Contact.synced_to_ghost` / `Contact.not_synced_to_ghost`.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260720000001_add_ghost_to_contacts.rb
class AddGhostToContacts < ActiveRecord::Migration[6.1]
  def change
    add_column :contacts, :ghost_id, :string
    add_index :contacts, :ghost_id, unique: true
    add_column :contacts, :ghost_data, :jsonb, default: {}, null: false

    create_table :ghost_synced_sources do |t|
      t.string :source, null: false
      t.timestamps
    end
    add_index :ghost_synced_sources, :source, unique: true
  end
end
```

Run: `bin/rails db:migrate` — expect it to apply cleanly and update `db/schema.rb`.

- [ ] **Step 2: Write failing model tests**

```ruby
# test/models/ghost_synced_source_test.rb
require 'test_helper'

class GhostSyncedSourceTest < ActiveSupport::TestCase
  test "requires a unique source" do
    GhostSyncedSource.create!(source: "newsletter")
    dupe = GhostSyncedSource.new(source: "newsletter")
    assert_not dupe.valid?
    assert_not GhostSyncedSource.new(source: "").valid?
  end
end
```

Add to `test/models/contact_test.rb` (create the file with the standard `require 'test_helper'` header if it does not exist):

```ruby
  test "record_source_events! appends an event per source, even for repeats" do
    contact = Contact.create!(email: "events@example.com", sources: ["newsletter"])
    contact.record_source_events!(["newsletter"])
    contact.record_source_events!(["newsletter", "g3d:ghost"])
    contact.reload
    assert_equal 2, contact.source_events["newsletter"].length
    assert_equal 1, contact.source_events["g3d:ghost"].length
    assert contact.source_events["newsletter"].first["added_at"].present?
  end

  test "ghost scopes filter on ghost_id presence" do
    linked = Contact.create!(email: "linked@example.com", ghost_id: "abc123")
    unlinked = Contact.create!(email: "unlinked@example.com")
    assert_includes Contact.synced_to_ghost, linked
    assert_includes Contact.not_synced_to_ghost, unlinked
    assert_not_includes Contact.synced_to_ghost, unlinked
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/ghost_synced_source_test.rb test/models/contact_test.rb`
Expected: FAIL — uninitialized constant / undefined method `record_source_events!` / undefined scope.

- [ ] **Step 4: Implement**

```ruby
# app/models/ghost_synced_source.rb
# A row's existence means "contacts with this source are pushed to Ghost".
class GhostSyncedSource < ApplicationRecord
  validates :source, presence: true, uniqueness: true
end
```

In `app/models/contact.rb`, after the apollo scopes (line ~9), add:

```ruby
  scope :synced_to_ghost, -> {
    where.not(ghost_id: nil)
  }
  scope :not_synced_to_ghost, -> {
    where(ghost_id: nil)
  }
```

Also add (near `merge_source_events`), moved verbatim from `Api::ContactsController#record_source_events!` (app/controllers/api/contacts_controller.rb:32-47) and converted to an instance method:

```ruby
  # Appends { added_at: now() } to source_events[source] for every given source,
  # even when the source is already in the deduped sources array — this is the
  # view counter. jsonb_set at the SQL level so concurrent writes cannot lose events.
  def record_source_events!(sources)
    Array(sources).each do |source|
      Contact.where(id: id).update_all([
        <<~SQL.squish,
          source_events = jsonb_set(
            source_events,
            ARRAY[?],
            COALESCE(source_events->?, '[]'::jsonb)
              || jsonb_build_array(jsonb_build_object('added_at', now())),
            true
          )
        SQL
        source.to_s, source.to_s
      ])
    end
  end
```

In `app/controllers/api/contacts_controller.rb`: replace the call `record_source_events!(contact, params["sources"] || [])` with `contact.record_source_events!(params["sources"] || [])` and DELETE the controller's private `record_source_events!` method entirely.

- [ ] **Step 5: Run tests to verify they pass (including the existing controller tests guarding the refactor)**

Run: `bin/rails test test/models/ghost_synced_source_test.rb test/models/contact_test.rb test/controllers/api/contacts_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models app/controllers/api/contacts_controller.rb test
git commit -m "feat(ghost): contact ghost columns, GhostSyncedSource, extract record_source_events!"
```

---

### Task 2: Ghost Admin API client — `Stacks::Ghost`

**Files:**
- Modify: `Gemfile` (add `gem 'jwt'` — already in the bundle transitively; make the direct dependency explicit)
- Create: `lib/stacks/ghost.rb`
- Test: `test/lib/stacks/ghost_test.rb`

**Interfaces:**
- Consumes: `Stacks::Utils.config[:ghost]` → `{api_url:, admin_api_key: "id:secret"}`.
- Produces:
  - `Stacks::Ghost.new(max_retries: 5)`
  - `#all_members` → Array of member hashes (string keys, with `"labels"` and `"newsletters"` included)
  - `#find_member_by_email(email)` → member hash or nil
  - `#create_member(attrs)` → member hash (raises `Stacks::Ghost::RequestError` with `#code == 422` on duplicate email)
  - `#update_member(id, attrs)` → member hash
  - `Stacks::Ghost::RequestError` — `#code`, `#retryable?` (true for 429 and 5xx)
  - `#token` → JWT string (exposed for tests)

- [ ] **Step 1: Add the gem**

In `Gemfile`, near `gem 'httparty'` (or the other API-related gems), add:

```ruby
gem 'jwt' # Ghost Admin API auth
```

Run: `bundle install` — expect no version changes (jwt 2.2.2 already locked).

- [ ] **Step 2: Write failing tests**

```ruby
# test/lib/stacks/ghost_test.rb
require 'test_helper'

class Stacks::GhostTest < ActiveSupport::TestCase
  # Secret must be hex — Ghost hex-decodes it before signing.
  FAKE_CONFIG = {
    ghost: {
      api_url: "https://example.ghost.io",
      admin_api_key: "65abc123def:0123456789abcdef0123456789abcdef",
    },
  }.freeze

  def build_client(max_retries: 0)
    Stacks::Utils.stubs(:config).returns(FAKE_CONFIG)
    Stacks::Ghost.new(max_retries: max_retries)
  end

  def fake_response(code:, body:)
    resp = mock("response")
    resp.stubs(:success?).returns(code < 400)
    resp.stubs(:code).returns(code)
    resp.stubs(:body).returns(JSON.dump(body))
    resp.stubs(:parsed_response).returns(body.deep_stringify_keys)
    resp
  end

  test "token is an HS256 JWT signed with the hex-decoded secret, kid header, /admin/ audience" do
    client = build_client
    secret = ["0123456789abcdef0123456789abcdef"].pack("H*")
    payload, header = JWT.decode(client.token, secret, true, { algorithm: "HS256" })
    assert_equal "65abc123def", header["kid"]
    assert_equal "/admin/", payload["aud"]
    assert_in_delta Time.now.to_i, payload["iat"], 5
    assert_operator payload["exp"] - payload["iat"], :<=, 300
  end

  test "all_members paginates until meta.pagination.next is nil" do
    client = build_client
    page1 = fake_response(code: 200, body: {
      members: [{ id: "m1", email: "a@x.com" }],
      meta: { pagination: { next: 2 } },
    })
    page2 = fake_response(code: 200, body: {
      members: [{ id: "m2", email: "b@x.com" }],
      meta: { pagination: { next: nil } },
    })
    Stacks::Ghost.stubs(:get).returns(page1).then.returns(page2)
    members = client.all_members
    assert_equal %w[m1 m2], members.map { |m| m["id"] }
  end

  test "find_member_by_email returns the first match or nil" do
    client = build_client
    found = fake_response(code: 200, body: { members: [{ id: "m1", email: "a@x.com" }] })
    empty = fake_response(code: 200, body: { members: [] })
    Stacks::Ghost.stubs(:get).returns(found).then.returns(empty)
    assert_equal "m1", client.find_member_by_email("A@x.com")["id"]
    assert_nil client.find_member_by_email("nope@x.com")
  end

  test "non-success raises RequestError with code; 422 is not retryable" do
    client = build_client
    Stacks::Ghost.stubs(:post).returns(
      fake_response(code: 422, body: { errors: [{ message: "Member already exists." }] })
    )
    error = assert_raises(Stacks::Ghost::RequestError) do
      client.create_member(email: "dupe@x.com")
    end
    assert_equal 422, error.code
    assert_not error.retryable?
  end

  test "retryable errors are retried up to max_retries then raised" do
    client = build_client(max_retries: 2)
    client.stubs(:backoff) # don't sleep in tests
    # 1 initial attempt + 2 retries = exactly 3 calls
    Stacks::Ghost.expects(:get).times(3).returns(fake_response(code: 500, body: { errors: [] }))
    error = assert_raises(Stacks::Ghost::RequestError) { client.all_members }
    assert_equal 500, error.code
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/lib/stacks/ghost_test.rb`
Expected: FAIL — `uninitialized constant Stacks::Ghost`.

- [ ] **Step 4: Implement the client**

```ruby
# lib/stacks/ghost.rb
class Stacks::Ghost
  include HTTParty

  class RequestError < StandardError
    attr_reader :code

    def initialize(code, body)
      @code = code
      super("Ghost API #{code}: #{body.to_s.first(500)}")
    end

    def retryable?
      code == 429 || code >= 500
    end
  end

  # max_retries: backoff count for 429/5xx. Request-path callers (webhooks,
  # admin buttons) should keep this small; the cron sweep can afford retries.
  def initialize(max_retries: 5)
    @max_retries = max_retries
    config = Stacks::Utils.config[:ghost]
    @api_url = config[:api_url]
    @key_id, @secret_hex = config[:admin_api_key].to_s.split(":")
  end

  # Ghost admin JWTs are short-lived and signed with the hex-decoded secret.
  def token
    now = Time.now.to_i
    JWT.encode(
      { iat: now, exp: now + 300, aud: "/admin/" },
      [@secret_hex].pack("H*"),
      "HS256",
      { kid: @key_id }
    )
  end

  def all_members
    members = []
    page = 1
    loop do
      response = handle_response {
        self.class.get(url("/members/"), query: {
          limit: 100, page: page, include: "labels,newsletters",
        }, headers: headers)
      }
      members += response.parsed_response["members"] || []
      break if response.parsed_response.dig("meta", "pagination", "next").nil?
      page += 1
    end
    members
  end

  def find_member_by_email(email)
    response = handle_response {
      self.class.get(url("/members/"), query: {
        filter: "email:'#{email.to_s.downcase}'", include: "labels,newsletters",
      }, headers: headers)
    }
    (response.parsed_response["members"] || []).first
  end

  def create_member(attrs)
    response = handle_response {
      self.class.post(url("/members/"), query: { include: "labels,newsletters" },
        body: JSON.dump({ members: [attrs] }), headers: headers)
    }
    response.parsed_response["members"].first
  end

  def update_member(id, attrs)
    response = handle_response {
      self.class.put(url("/members/#{id}/"), query: { include: "labels,newsletters" },
        body: JSON.dump({ members: [attrs] }), headers: headers)
    }
    response.parsed_response["members"].first
  end

  private

  def url(path)
    "#{@api_url}/ghost/api/admin#{path}"
  end

  def headers
    {
      "Authorization" => "Ghost #{token}",
      "Content-Type" => "application/json",
      "Accept-Version" => "v6.0",
    }
  end

  def handle_response(&block)
    retry_count = 0
    begin
      response = block.call
      raise RequestError.new(response.code, response.body) unless response.success?
      response
    rescue RequestError => e
      raise e unless e.retryable? && retry_count < @max_retries
      retry_count += 1
      backoff(retry_count)
      retry
    end
  end

  def backoff(retry_count)
    sleep(2**retry_count)
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/lib/stacks/ghost_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Gemfile Gemfile.lock lib/stacks/ghost.rb test/lib/stacks/ghost_test.rb
git commit -m "feat(ghost): Ghost Admin API client with JWT auth and backoff"
```

---

### Task 3: Outbound sweep — `Stacks::GhostSync` (stacks → Ghost)

**Files:**
- Create: `lib/stacks/ghost_sync.rb`
- Test: `test/lib/stacks/ghost_sync_test.rb`

**Interfaces:**
- Consumes: `Stacks::Ghost` instance (injected), `GhostSyncedSource.pluck(:source)`, `Contact` ghost columns from Task 1.
- Produces:
  - `Stacks::GhostSync.new(ghost = Stacks::Ghost.new)` — `#summary` (Hash of counters), `#errors` (Array of strings)
  - `#sync_all!` — full two-way sweep (inbound leg completed in Task 4; this task builds the outbound legs and a stub pull leg)
  - `#sync_contact!(contact, enabled, members_by_id, members_by_email)` → member hash
  - `SOURCE_PREFIX = "g3d:ghost"` (labels have NO prefix — they are enabled source names verbatim)
- Note: member hashes use string keys throughout (parsed JSON).

- [ ] **Step 1: Write failing tests**

```ruby
# test/lib/stacks/ghost_sync_test.rb
require 'test_helper'

class Stacks::GhostSyncTest < ActiveSupport::TestCase
  def member(id:, email:, labels: [], newsletters: [], name: nil, extra: {})
    {
      "id" => id, "email" => email, "name" => name,
      "labels" => labels.map { |n| { "name" => n, "slug" => n.parameterize } },
      "newsletters" => newsletters.map { |s| { "id" => "nl-#{s}", "slug" => s, "name" => s.titleize } },
    }.merge(extra)
  end

  def sync_with(ghost)
    Stacks::GhostSync.new(ghost)
  end

  test "creates a member with source-name labels for an eligible contact and links ghost_id" do
    GhostSyncedSource.create!(source: "newsletter")
    contact = Contact.create!(email: "new@example.com", sources: ["newsletter"], display_name: "New Person")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    created = member(id: "m1", email: "new@example.com", labels: ["newsletter"], newsletters: ["weekly"])
    ghost.expects(:create_member)
      .with(email: "new@example.com", name: "New Person", labels: ["newsletter"])
      .returns(created)

    sync = sync_with(ghost)
    sync.sync_all!
    contact.reload
    assert_equal "m1", contact.ghost_id
    assert contact.ghost_data["synced_at"].present?
    assert_equal 1, sync.summary[:created]
  end

  test "updates managed labels while preserving unmanaged (hand-added) labels; never writes newsletters" do
    GhostSyncedSource.create!(source: "newsletter")
    GhostSyncedSource.create!(source: "fundraising")
    contact = Contact.create!(
      email: "update@example.com",
      sources: %w[newsletter fundraising],
      ghost_id: "m2"
    )
    existing = member(id: "m2", email: "update@example.com",
      labels: ["VIP", "newsletter"], newsletters: ["weekly"], name: "Kept Name")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).with do |id, attrs|
      id == "m2" &&
        attrs[:labels].sort == ["VIP", "fundraising", "newsletter"] &&
        !attrs.key?(:newsletters) && !attrs.key?(:name)
    end.returns(existing.merge("labels" => [
      { "name" => "VIP" }, { "name" => "fundraising" }, { "name" => "newsletter" },
    ]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:updated]
  end

  test "no-op when labels already match" do
    GhostSyncedSource.create!(source: "newsletter")
    Contact.create!(email: "same@example.com", sources: ["newsletter"], ghost_id: "m3")
    existing = member(id: "m3", email: "same@example.com", labels: ["newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).never
    ghost.expects(:create_member).never

    sync_with(ghost).sync_all!
  end

  test "adopts the existing member on 422 duplicate-email create" do
    GhostSyncedSource.create!(source: "newsletter")
    contact = Contact.create!(email: "dupe@example.com", sources: ["newsletter"])
    existing = member(id: "m4", email: "dupe@example.com", labels: [])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([]) # not in the sweep snapshot (raced in)
    ghost.expects(:create_member).raises(Stacks::Ghost::RequestError.new(422, "Member already exists."))
    ghost.expects(:find_member_by_email).with("dupe@example.com").returns(existing)
    ghost.expects(:update_member).with do |id, attrs|
      id == "m4" && attrs[:labels] == ["newsletter"]
    end.returns(existing.merge("labels" => [{ "name" => "newsletter" }]))

    sync_with(ghost).sync_all!
    assert_equal "m4", contact.reload.ghost_id
  end

  test "delabels a linked contact that is no longer eligible, keeps the member" do
    GhostSyncedSource.create!(source: "newsletter")
    Contact.create!(email: "gone@example.com", sources: ["etl:meet"], ghost_id: "m5")
    existing = member(id: "m5", email: "gone@example.com", labels: ["VIP", "newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).with do |id, attrs|
      id == "m5" && attrs[:labels] == ["VIP"]
    end.returns(existing.merge("labels" => [{ "name" => "VIP" }]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:delabeled]
  end

  test "skips contacts with no enabled source and does nothing outbound when no sources enabled" do
    Contact.create!(email: "ineligible@example.com", sources: ["etl:meet"])
    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).never
    ghost.expects(:update_member).never
    sync_with(ghost).sync_all!
  end

  test "a per-contact failure is counted and does not halt the sweep" do
    GhostSyncedSource.create!(source: "newsletter")
    Contact.create!(email: "fail@example.com", sources: ["newsletter"])
    ok_contact = Contact.create!(email: "ok@example.com", sources: ["newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    created = member(id: "m6", email: "ok@example.com", labels: ["newsletter"])
    ghost.stubs(:create_member).with do |attrs|
      raise Stacks::Ghost::RequestError.new(500, "boom") if attrs[:email] == "fail@example.com"
      true
    end.returns(created)

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:errors]
    assert_equal "m6", ok_contact.reload.ghost_id
    assert_match(/fail@example.com/, sync.errors.first)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/stacks/ghost_sync_test.rb`
Expected: FAIL — `uninitialized constant Stacks::GhostSync`.

- [ ] **Step 3: Implement the outbound sweep**

```ruby
# lib/stacks/ghost_sync.rb
#
# Full-state reconciliation between stacks Contacts and Ghost members.
# Stacks owns segmentation (labels named after enabled sources, verbatim —
# no prefix); Ghost owns opt-in state
# (newsletters) and deliverability. See
# docs/superpowers/specs/2026-07-20-ghost-contact-sync-design.md
class Stacks::GhostSync
  SOURCE_PREFIX = "g3d:ghost".freeze

  attr_reader :summary, :errors

  def initialize(ghost = Stacks::Ghost.new)
    @ghost = ghost
    @summary = Hash.new(0)
    @errors = []
  end

  def sync_all!
    enabled = GhostSyncedSource.pluck(:source)
    members = @ghost.all_members
    members_by_id = members.index_by { |m| m["id"] }
    members_by_email = members.index_by { |m| m["email"].to_s.downcase }

    # Outbound legs only run when at least one source is enabled: an empty
    # checkbox set means "sync off", not "remove every label in Ghost".
    if enabled.any?
      Contact.where("sources && ARRAY[?]::varchar[]", enabled).find_each do |contact|
        capture_errors(contact) do
          next skip_invalid(contact) unless contact.email.match?(Devise.email_regexp)
          updated = sync_contact!(contact, enabled, members_by_id, members_by_email)
          members_by_id[updated["id"]] = updated if updated
        end
      end

      Contact.where.not(ghost_id: nil)
        .where.not("sources && ARRAY[?]::varchar[]", enabled)
        .find_each do |contact|
          capture_errors(contact) do
            member = members_by_id[contact.ghost_id]
            next unless member
            members_by_id[member["id"]] = delabel_member!(contact, member, enabled)
          end
        end
    end

    pull_members!(members_by_id.values)
    summary
  end

  def sync_contact!(contact, enabled, members_by_id, members_by_email)
    desired = desired_labels_for(contact, enabled)
    member = members_by_id[contact.ghost_id] || members_by_email[contact.email.downcase]

    if member.nil?
      begin
        member = @ghost.create_member(
          { email: contact.email, name: contact.display_name.presence, labels: desired }.compact
        )
        @summary[:created] += 1
      rescue Stacks::Ghost::RequestError => e
        raise unless e.code == 422
        # Someone created this email in Ghost since our sweep snapshot — adopt it.
        member = @ghost.find_member_by_email(contact.email)
        raise if member.nil?
        member = update_member_labels(contact, member, desired, enabled) || member
      end
    else
      member = update_member_labels(contact, member, desired, enabled) || member
    end

    link_contact!(contact, member)
    member
  end

  private

  # Labels are source names verbatim; the managed label set is exactly the
  # enabled sources. Labels outside that set (hand-added in Ghost, or from a
  # since-unchecked source) are never touched.
  def desired_labels_for(contact, enabled)
    (contact.sources & enabled).sort
  end

  def label_names(member)
    (member["labels"] || []).map { |l| l["name"] }
  end

  def managed_label_names(member, enabled)
    (label_names(member) & enabled).sort
  end

  # Returns the updated member hash when a write happened, nil for a no-op.
  # Labels are full-replace in Ghost, so always resend the preserved
  # (unmanaged) labels alongside ours. Never includes :newsletters.
  def update_member_labels(contact, member, desired, enabled)
    attrs = {}
    if managed_label_names(member, enabled) != desired
      attrs[:labels] = (label_names(member) - enabled) + desired
    end
    if member["name"].blank? && contact.display_name.present?
      attrs[:name] = contact.display_name
    end
    return nil if attrs.empty?

    updated = @ghost.update_member(member["id"], attrs)
    @summary[:updated] += 1
    updated
  end

  def delabel_member!(contact, member, enabled)
    return member if managed_label_names(member, enabled).empty?
    updated = @ghost.update_member(member["id"], labels: label_names(member) - enabled)
    @summary[:delabeled] += 1
    updated
  end

  def link_contact!(contact, member)
    contact.update!(
      ghost_id: member["id"],
      ghost_data: contact.ghost_data.merge("synced_at" => Time.current.iso8601)
    )
  rescue ActiveRecord::RecordNotUnique
    # Member already linked to another contact (its email was changed in
    # Ghost). Email is stacks-owned: if the member's email now matches THIS
    # contact, steal the link from the stale owner; otherwise leave it.
    owner = Contact.where(ghost_id: member["id"]).where.not(id: contact.id).first
    if owner && member["email"].to_s.downcase == contact.email.downcase
      owner.update!(ghost_id: nil)
      contact.update!(
        ghost_id: member["id"],
        ghost_data: contact.ghost_data.merge("synced_at" => Time.current.iso8601)
      )
    else
      @summary[:link_conflicts] += 1
    end
  end

  def skip_invalid(_contact)
    @summary[:skipped_invalid] += 1
    nil
  end

  def capture_errors(contact)
    yield
  rescue => e
    @summary[:errors] += 1
    @errors << "#{contact.email}: #{e.class}: #{e.message}"
  end

  # Inbound pull leg — implemented in the next task.
  def pull_members!(_members)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/stacks/ghost_sync_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/ghost_sync.rb test/lib/stacks/ghost_sync_test.rb
git commit -m "feat(ghost): outbound sweep — contacts to Ghost members with source-name labels"
```

---

### Task 4: Inbound upsert + pull leg + advisory lock

**Files:**
- Modify: `lib/stacks/ghost_sync.rb`
- Test: `test/lib/stacks/ghost_sync_test.rb` (add cases)

**Interfaces:**
- Produces:
  - `Stacks::GhostSync#upsert_contact_from_member(member)` → Contact (public — the webhook controller in Task 5 calls this)
  - `Stacks::GhostSync#handle_member_deleted(previous_member)` → Contact or nil (public — webhook controller)
  - `Stacks::GhostSync.sync_all_with_lock!(ghost = Stacks::Ghost.new)` → GhostSync instance, or nil when the advisory lock is held
  - `ADVISORY_LOCK_KEY = 728534291`
- Member hash contract consumed here: `"id"`, `"email"`, `"name"`, `"newsletters"` (array of `{"id", "slug", "name"}` — active subscriptions only), `"email_suppression"` (`{"suppressed" => bool}`), `"email_disabled"`.

- [ ] **Step 1: Write failing tests (append to `test/lib/stacks/ghost_sync_test.rb`)**

```ruby
  test "upsert creates a contact from a Ghost member with per-newsletter sources and events" do
    ghost = mock("ghost")
    sync = sync_with(ghost)
    m = member(id: "m10", email: "Signup@Example.com", name: "Signer Upper",
      newsletters: %w[weekly-digest], extra: {
        "email_suppression" => { "suppressed" => false }, "email_disabled" => false,
      })

    contact = sync.upsert_contact_from_member(m)
    contact.reload
    assert_equal "signup@example.com", contact.email
    assert_equal ["g3d:ghost:weekly-digest"], contact.sources
    assert_equal "m10", contact.ghost_id
    assert_equal "Signer Upper", contact.display_name
    assert_equal ["weekly-digest"], contact.ghost_data.dig("snapshot", "newsletters")
    assert_equal 1, contact.source_events["g3d:ghost:weekly-digest"].length
  end

  test "upsert is idempotent — repeat calls add no sources and no events" do
    ghost = mock("ghost")
    sync = sync_with(ghost)
    m = member(id: "m11", email: "twice@example.com", newsletters: %w[weekly-digest])
    sync.upsert_contact_from_member(m)
    contact = sync.upsert_contact_from_member(m).reload
    assert_equal ["g3d:ghost:weekly-digest"], contact.sources
    assert_equal 1, contact.source_events["g3d:ghost:weekly-digest"].length
  end

  test "member with no active newsletters gets the bare g3d:ghost source" do
    sync = sync_with(mock("ghost"))
    contact = sync.upsert_contact_from_member(member(id: "m12", email: "unsub@example.com")).reload
    assert_equal ["g3d:ghost"], contact.sources
  end

  test "upsert matches an existing contact by email, links ghost_id, keeps display_name" do
    existing = Contact.create!(email: "known@example.com", sources: ["newsletter"], display_name: "Original")
    sync = sync_with(mock("ghost"))
    m = member(id: "m13", email: "KNOWN@example.com", name: "Ghost Name", newsletters: %w[weekly-digest])
    sync.upsert_contact_from_member(m)
    existing.reload
    assert_equal "m13", existing.ghost_id
    assert_equal "Original", existing.display_name
    assert_equal %w[newsletter g3d:ghost:weekly-digest], existing.sources
  end

  test "email changed in Ghost records mismatch without mutating contact.email" do
    existing = Contact.create!(email: "old@example.com", ghost_id: "m14")
    sync = sync_with(mock("ghost"))
    sync.upsert_contact_from_member(member(id: "m14", email: "renamed@example.com"))
    existing.reload
    assert_equal "old@example.com", existing.email
    assert_equal "renamed@example.com", existing.ghost_data.dig("snapshot", "email_in_ghost")
  end

  test "suppression is snapshotted" do
    sync = sync_with(mock("ghost"))
    m = member(id: "m15", email: "bounced@example.com", extra: {
      "email_suppression" => { "suppressed" => true }, "email_disabled" => true,
    })
    contact = sync.upsert_contact_from_member(m).reload
    assert_equal true, contact.ghost_data.dig("snapshot", "suppressed")
    assert_equal true, contact.ghost_data.dig("snapshot", "email_disabled")
  end

  test "handle_member_deleted keeps the contact, clears ghost_id, stamps deleted_at" do
    existing = Contact.create!(email: "bye@example.com", ghost_id: "m16", sources: ["g3d:ghost"])
    sync = sync_with(mock("ghost"))
    sync.handle_member_deleted("id" => "m16", "email" => "bye@example.com")
    existing.reload
    assert_nil existing.ghost_id
    assert existing.ghost_data.dig("snapshot", "deleted_at").present?
    assert_equal ["g3d:ghost"], existing.sources
  end

  test "sync_all! pull leg upserts Ghost-only members" do
    ghost = mock("ghost")
    ghost.expects(:all_members).returns([
      member(id: "m17", email: "organic@example.com", newsletters: %w[weekly-digest]),
    ])
    sync = sync_with(ghost)
    sync.sync_all!
    contact = Contact.find_by(email: "organic@example.com")
    assert_equal "m17", contact.ghost_id
    assert_equal ["g3d:ghost:weekly-digest"], contact.sources
    assert_equal 1, sync.summary[:pulled]
  end

  test "sync_all_with_lock! returns nil when the advisory lock is held elsewhere" do
    other = ActiveRecord::Base.connection_pool.checkout
    other.execute("SELECT pg_advisory_lock(#{Stacks::GhostSync::ADVISORY_LOCK_KEY})")
    ghost = mock("ghost")
    assert_nil Stacks::GhostSync.sync_all_with_lock!(ghost)
  ensure
    other.execute("SELECT pg_advisory_unlock(#{Stacks::GhostSync::ADVISORY_LOCK_KEY})")
    ActiveRecord::Base.connection_pool.checkin(other)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/stacks/ghost_sync_test.rb`
Expected: FAIL — undefined `upsert_contact_from_member` / `handle_member_deleted` / `ADVISORY_LOCK_KEY`; pull-leg test fails on missing contact.

- [ ] **Step 3: Implement**

In `lib/stacks/ghost_sync.rb`:

Add below `SOURCE_PREFIX`:

```ruby
  # Fixed app-wide advisory lock key for the sweep (rand of a keyboard mash;
  # any stable int works — must only avoid colliding with other app locks).
  ADVISORY_LOCK_KEY = 728534291
```

Add the class method:

```ruby
  # Wraps the sweep in a pg advisory lock so an overlapping Scheduler run or
  # admin-button click exits cleanly instead of double-writing. Returns the
  # sync (for summary/errors), or nil when another run holds the lock.
  def self.sync_all_with_lock!(ghost = Stacks::Ghost.new)
    conn = ActiveRecord::Base.connection
    got_lock = conn.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    return nil unless got_lock

    begin
      sync = new(ghost)
      sync.sync_all!
      sync
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
    end
  end
```

Replace the empty `pull_members!` stub and add the two public methods (put them above `private`):

```ruby
  # Shared inbound path for the sweep's pull leg and the webhook receiver.
  # Idempotent: only writes when something changed; source_events recorded
  # only for newly added sources — this is also our echo suppression, since
  # the webhook fired by our own outbound label write finds nothing to do.
  def upsert_contact_from_member(member)
    email = member["email"].to_s.downcase
    contact = Contact.find_by(ghost_id: member["id"]) ||
      Contact.where("LOWER(email) = ?", email).first ||
      Contact.create_or_find_by!(email: email)

    slugs = (member["newsletters"] || []).map { |n| n["slug"] }.compact.sort
    ghost_sources = slugs.any? ? slugs.map { |s| "#{SOURCE_PREFIX}:#{s}" } : [SOURCE_PREFIX]
    new_sources = ghost_sources - contact.sources

    contact.sources = (contact.sources + ghost_sources).uniq
    contact.ghost_id ||= member["id"]
    if contact.display_name.blank? && member["name"].present?
      contact.display_name = member["name"]
    end
    contact.ghost_data = contact.ghost_data.merge(
      "snapshot" => {
        "newsletters" => slugs,
        "suppressed" => member.dig("email_suppression", "suppressed") || false,
        "email_disabled" => !!member["email_disabled"],
        "email_in_ghost" => (email == contact.email.downcase ? nil : member["email"]),
      }.compact
    )
    contact.save! if contact.changed?
    contact.record_source_events!(new_sources)
    contact
  end

  # member.deleted: keep the contact (funnel history), sever the link.
  def handle_member_deleted(previous_member)
    contact = Contact.find_by(ghost_id: previous_member["id"])
    return nil unless contact

    contact.update!(
      ghost_id: nil,
      ghost_data: contact.ghost_data.merge(
        "snapshot" => (contact.ghost_data["snapshot"] || {})
          .merge("deleted_at" => Time.current.iso8601)
      )
    )
    contact
  end
```

Replace the private `pull_members!` stub with:

```ruby
  # Reconciliation for missed webhooks: every Ghost member flows through the
  # shared upsert, so organic signups land in the funnel even if their
  # webhook was dropped (Ghost has a 2s timeout and no retries).
  def pull_members!(members)
    members.each do |member|
      contact = Contact.find_by(ghost_id: member["id"])
      begin
        upserted = upsert_contact_from_member(member)
        @summary[:pulled] += 1 if contact.nil? && upserted.ghost_id == member["id"]
      rescue => e
        @summary[:errors] += 1
        @errors << "#{member["email"]}: #{e.class}: #{e.message}"
      end
    end
  end
```

Note: the outbound `create_member` test from Task 3 ("creates a member...") will now ALSO run the pull leg over the created member — the returned member includes newsletter `weekly`, so the contact gains source `g3d:ghost:weekly`. If that Task 3 test asserted exact sources, update it to expect `["newsletter", "g3d:ghost:weekly"]` ordering-insensitively. This is designed behavior: `g3d:ghost:*` sources reflect current subscription state for ALL members, pushed or organic.

- [ ] **Step 4: Run the full sync test file**

Run: `bin/rails test test/lib/stacks/ghost_sync_test.rb`
Expected: PASS (adjust the Task 3 assertions as described above if they assumed no pull leg).

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/ghost_sync.rb test/lib/stacks/ghost_sync_test.rb
git commit -m "feat(ghost): inbound upsert, pull-leg reconciliation, advisory-locked sweep"
```

---

### Task 5: Webhook receiver — `POST /webhooks/ghost`

**Files:**
- Create: `app/controllers/ghost_webhooks_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/controllers/ghost_webhooks_controller_test.rb`

**Interfaces:**
- Consumes: `Stacks::GhostSync#upsert_contact_from_member`, `#handle_member_deleted` (Task 4); `Stacks::Utils.config[:ghost][:webhook_secret]`.
- Produces: route `POST /webhooks/ghost`. Signature: `X-Ghost-Signature: sha256=<hex>, t=<ms>` where `<hex> = HMAC_SHA256(secret, raw_body + t)`. 401 on bad/stale signature; 200 otherwise (including on handler errors — Ghost doesn't retry, and a 410 would delete the webhook).

- [ ] **Step 1: Write failing tests**

```ruby
# test/controllers/ghost_webhooks_controller_test.rb
require 'test_helper'

class GhostWebhooksControllerTest < ActionDispatch::IntegrationTest
  SECRET = "test-webhook-secret".freeze

  setup do
    GhostWebhooksController.any_instance.stubs(:webhook_secret).returns(SECRET)
  end

  def signed_post(payload, secret: SECRET, at: Time.current)
    body = JSON.dump(payload)
    ts = (at.to_f * 1000).to_i.to_s
    hex = OpenSSL::HMAC.hexdigest("SHA256", secret, body + ts)
    post "/webhooks/ghost", params: body, headers: {
      "Content-Type" => "application/json",
      "X-Ghost-Signature" => "sha256=#{hex}, t=#{ts}",
    }
  end

  def member_payload(id:, email:, newsletters: [])
    {
      "id" => id, "email" => email, "name" => nil,
      "labels" => [],
      "newsletters" => newsletters.map { |s| { "id" => "nl-#{s}", "slug" => s } },
    }
  end

  test "rejects a missing signature" do
    post "/webhooks/ghost", params: JSON.dump({}), headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  test "rejects a wrong-secret signature" do
    signed_post({ "member" => {} }, secret: "wrong")
    assert_response :unauthorized
  end

  test "rejects a stale timestamp" do
    signed_post({ "member" => {} }, at: 10.minutes.ago)
    assert_response :unauthorized
  end

  test "member.added upserts a contact into the funnel" do
    payload = {
      "member" => {
        "current" => member_payload(id: "m20", email: "hook@example.com", newsletters: %w[weekly-digest]),
        "previous" => {},
      },
    }
    assert_difference("Contact.count", 1) { signed_post(payload) }
    assert_response :ok
    contact = Contact.find_by(email: "hook@example.com")
    assert_equal "m20", contact.ghost_id
    assert_equal ["g3d:ghost:weekly-digest"], contact.sources
  end

  test "member.deleted clears the link but keeps the contact" do
    contact = Contact.create!(email: "del@example.com", ghost_id: "m21")
    payload = {
      "member" => {
        "current" => {},
        "previous" => member_payload(id: "m21", email: "del@example.com"),
      },
    }
    assert_no_difference("Contact.count") { signed_post(payload) }
    assert_response :ok
    assert_nil contact.reload.ghost_id
  end

  test "handler errors still return 200" do
    Stacks::GhostSync.any_instance.stubs(:upsert_contact_from_member).raises(StandardError.new("boom"))
    payload = {
      "member" => { "current" => member_payload(id: "m22", email: "err@example.com"), "previous" => {} },
    }
    signed_post(payload)
    assert_response :ok
  end

  test "unknown payload shape is a 200 no-op" do
    signed_post({ "post" => { "current" => { "id" => "p1" } } })
    assert_response :ok
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/ghost_webhooks_controller_test.rb`
Expected: FAIL — routing error (no route matches POST /webhooks/ghost).

- [ ] **Step 3: Implement route and controller**

In `config/routes.rb`, after the `namespace :api` block:

```ruby
  post "/webhooks/ghost" => "ghost_webhooks#handle"
```

```ruby
# app/controllers/ghost_webhooks_controller.rb
#
# Receiver for Ghost member webhooks (member.added / member.edited /
# member.deleted). Ghost aborts delivery after 2s and does not retry, so this
# handler must be fast, and errors return 200 — the 10-minute reconciliation
# sweep (Stacks::GhostSync) is the correctness backstop. A non-2xx buys
# nothing, and a 410 would permanently delete the webhook on the Ghost side.
class GhostWebhooksController < ActionController::Base
  skip_before_action :verify_authenticity_token, raise: false

  TIMESTAMP_TOLERANCE_MS = 5.minutes.in_milliseconds

  def handle
    return head :unauthorized unless valid_signature?

    payload = parsed_payload
    member = payload["member"] || {}
    current = member["current"] || {}
    previous = member["previous"] || {}

    sync = Stacks::GhostSync.new(Stacks::Ghost.new(max_retries: 0))
    if current["id"].present?
      # member.added and member.edited are handled identically: the upsert is
      # idempotent, so our own outbound writes echoing back are no-ops.
      sync.upsert_contact_from_member(current)
    elsif previous["id"].present?
      sync.handle_member_deleted(previous)
    end
    head :ok
  rescue => e
    Rails.logger.error("[ghost-webhook] #{e.class}: #{e.message}")
    head :ok
  end

  private

  def parsed_payload
    JSON.parse(request.raw_post)
  rescue JSON::ParserError
    {}
  end

  def webhook_secret
    Stacks::Utils.config.dig(:ghost, :webhook_secret).to_s
  end

  # X-Ghost-Signature: sha256=<hex>, t=<ms> — hex is HMAC_SHA256 over the raw
  # request body with the millisecond timestamp string concatenated (Ghost 6
  # format). Compared constant-time; stale timestamps rejected (replay guard).
  def valid_signature?
    secret = webhook_secret
    return false if secret.blank?

    parts = request.headers["X-Ghost-Signature"].to_s
      .split(",").map(&:strip).map { |p| p.split("=", 2) }.to_h
    hex, ts = parts["sha256"], parts["t"]
    return false if hex.blank? || ts.blank?
    return false if (Time.current.to_f * 1000 - ts.to_i).abs > TIMESTAMP_TOLERANCE_MS

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post + ts)
    ActiveSupport::SecurityUtils.secure_compare(expected, hex)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/controllers/ghost_webhooks_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/ghost_webhooks_controller.rb config/routes.rb test/controllers/ghost_webhooks_controller_test.rb
git commit -m "feat(ghost): webhook receiver with signature verification"
```

---

### Task 6: Admin UI — Ghost Sync page + Contact ghost panel

**Files:**
- Create: `app/admin/ghost_sync.rb`
- Modify: `app/admin/contacts.rb`

**Interfaces:**
- Consumes: `GhostSyncedSource`, `Stacks::GhostSync.sync_all_with_lock!`, `Contact` ghost scopes/columns.
- Produces: ActiveAdmin page at `/admin/ghost_sync` with source checkboxes + Sync-now; Ghost panel on `/admin/contacts/:id`.

- [ ] **Step 1: Implement the Ghost Sync admin page**

```ruby
# app/admin/ghost_sync.rb
ActiveAdmin.register_page "Ghost Sync" do
  menu label: "Ghost Sync"

  content title: "Ghost Sync" do
    sources_with_counts = Contact.connection.select_rows(<<~SQL)
      SELECT s.source, COUNT(*)
      FROM contacts, LATERAL unnest(sources) AS s(source)
      GROUP BY s.source
      ORDER BY COUNT(*) DESC, s.source
    SQL
    enabled = GhostSyncedSource.pluck(:source)

    panel "Synced Sources" do
      para "Contacts with a checked source are pushed to Ghost as members, " \
           "labeled with the source name verbatim. Unchecking a source stops " \
           "label management for it (existing labels stay in Ghost; members " \
           "are never deleted)."
      form action: admin_ghost_sync_update_sources_path, method: :post do
        input type: :hidden, name: :authenticity_token, value: form_authenticity_token
        table_for sources_with_counts do
          column("Sync?") do |(source, _count)|
            input type: :checkbox, name: "sources[]", value: source,
              checked: enabled.include?(source) || nil
          end
          column("Source") { |(source, _count)| source }
          column("Contacts") { |(_source, count)| count }
        end
        div style: "margin-top: 12px" do
          input type: :submit, value: "Save Synced Sources"
        end
      end
    end

    panel "Sync" do
      para "Runs every 10 minutes via Heroku Scheduler (rake ghost:sync)."
      form action: admin_ghost_sync_sync_now_path, method: :post do
        input type: :hidden, name: :authenticity_token, value: form_authenticity_token
        input type: :submit, value: "Sync Now"
      end
    end

    panel "Webhook Setup (one-time, in Ghost Admin)" do
      para "Settings → Integrations → the stacks custom integration → add " \
           "webhooks for member.added, member.edited, member.deleted pointing " \
           "at #{request.base_url}/webhooks/ghost, each with the shared secret " \
           "from credentials (ghost.webhook_secret)."
    end
  end

  page_action :update_sources, method: :post do
    checked = Array(params[:sources]).map(&:to_s).reject(&:blank?)
    GhostSyncedSource.where.not(source: checked).destroy_all
    checked.each { |s| GhostSyncedSource.find_or_create_by!(source: s) }
    redirect_to admin_ghost_sync_path, notice: "Synced sources updated (#{checked.length} enabled)"
  end

  page_action :sync_now, method: :post do
    sync = Stacks::GhostSync.sync_all_with_lock!
    if sync
      notice = "Ghost sync complete: #{sync.summary.to_h.inspect}"
      notice += " — first error: #{sync.errors.first}" if sync.errors.any?
      redirect_to admin_ghost_sync_path, notice: notice
    else
      redirect_to admin_ghost_sync_path, alert: "A Ghost sync is already running — try again shortly."
    end
  end
end
```

- [ ] **Step 2: Add ghost columns to the Contacts admin**

In `app/admin/contacts.rb`:

- Next to the apollo scopes, add:

```ruby
  scope :synced_to_ghost
  scope :not_synced_to_ghost
```

- In the `show` block, alongside the existing apollo/metadata rows, add a Ghost panel (match the file's existing `attributes_table`/panel style):

```ruby
    panel "Ghost" do
      attributes_table_for contact do
        row("Ghost ID") do
          if contact.ghost_id.present?
            link_to contact.ghost_id,
              "#{Stacks::Utils.config[:ghost][:api_url]}/ghost/#/members/#{contact.ghost_id}",
              target: "_blank", rel: "noopener"
          end
        end
        row("Newsletters") { (contact.ghost_data.dig("snapshot", "newsletters") || []).join(", ") }
        row("Suppressed?") { contact.ghost_data.dig("snapshot", "suppressed").inspect }
        row("Email in Ghost") do
          mismatch = contact.ghost_data.dig("snapshot", "email_in_ghost")
          mismatch.present? ? status_tag(mismatch, class: "warning") : "—"
        end
        row("Last Synced") { contact.ghost_data["synced_at"] }
      end
    end
```

(Adapt `contact` to the block variable name the file actually uses in its `show` block — check before editing; ActiveAdmin show blocks commonly use `resource` or a named block param.)

- [ ] **Step 3: Verify manually and run the full test suite**

Run: `bin/rails test`
Expected: PASS (no regressions).

Boot: `bin/rails server`, visit `http://localhost:3000/admin/ghost_sync` — page renders, checkboxes reflect `GhostSyncedSource` rows, saving toggles rows (verify in console: `GhostSyncedSource.pluck(:source)`). Visit a contact show page — Ghost panel renders. ("Sync Now" against production Ghost is exercised in Task 7's verification, not here.)

- [ ] **Step 4: Commit**

```bash
git add app/admin/ghost_sync.rb app/admin/contacts.rb
git commit -m "feat(ghost): admin UI — synced-source checkboxes, sync-now, contact ghost panel"
```

---

### Task 7: Rake task, webhook secret, scheduler + Ghost-side setup

**Files:**
- Create: `lib/tasks/ghost.rake`
- Modify: `config/credentials.yml.enc` (via `bin/rails credentials:edit` — add `ghost.webhook_secret`)

**Interfaces:**
- Consumes: `Stacks::GhostSync.sync_all_with_lock!`.
- Produces: `rake ghost:sync` for Heroku Scheduler.

- [ ] **Step 1: Write the rake task**

```ruby
# lib/tasks/ghost.rake
namespace :ghost do
  desc "Two-way sync contacts with Ghost (members, source-name labels, funnel sources)"
  task sync: :environment do
    sync = Stacks::GhostSync.sync_all_with_lock!
    if sync
      puts "~~~> Ghost sync complete: #{sync.summary.to_h.inspect}"
      sync.errors.each { |err| puts "~~~> Ghost sync error: #{err}" }
    else
      puts "~~~> Ghost sync skipped: another run holds the advisory lock"
    end
  end
end
```

- [ ] **Step 2: Add the webhook secret to credentials**

Generate: `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`

Then `bin/rails credentials:edit` and add `webhook_secret: <generated>` under the existing `ghost:` key **in the same host scope where `ghost:` currently lives** (it sits under a host key — mirror the indentation of `admin_api_key`). Repeat for the production host scope if credentials are host-scoped separately.

Verify: `bin/rails runner 'puts Stacks::Utils.config.dig(:ghost, :webhook_secret).present?'` → `true`.

- [ ] **Step 3: Smoke-test the sweep against real Ghost (read-only first)**

```bash
bin/rails runner 'puts Stacks::Ghost.new.all_members.length'
```

Expected: a member count, no auth errors. Then, with NO `GhostSyncedSource` rows yet (outbound legs no-op), run the pull-only sweep:

```bash
bin/rails runner 's = Stacks::GhostSync.sync_all_with_lock!; puts s.summary.to_h.inspect; puts s.errors'
```

Expected: `{:pulled=>N}` roughly matching the member count; spot-check a pulled contact in `/admin/contacts` (source `g3d:ghost:*`, ghost panel populated).

- [ ] **Step 4: Commit**

```bash
git add lib/tasks/ghost.rake config/credentials.yml.enc
git commit -m "feat(ghost): ghost:sync rake task + webhook secret"
```

- [ ] **Step 5: Manual rollout checklist (requires Hugh / production access — surface this list at the end)**

1. Deploy to Heroku; set the same `ghost.webhook_secret` in production credentials if scoped per-host.
2. Heroku Scheduler: add `rake ghost:sync`, every 10 minutes.
3. Ghost Admin (garden3d.ghost.io) → Settings → Advanced → Integrations → the custom integration whose Admin API key stacks uses → add 3 webhooks, each with the shared secret and target `https://<production-host>/webhooks/ghost`: `member.added`, `member.edited`, `member.deleted`. (Ghost has no webhook-list API — record their existence in the integration UI only.)
4. In `/admin/ghost_sync`, check the first opt-in source (e.g. `newsletter`). Run the initial backfill via `heroku run rake ghost:sync` (NOT the Sync Now button — a large first push can exceed Heroku's 30s router timeout on a web request; the button is fine for steady-state). Verify members + the `newsletter` label appear in Ghost Admin → Members.
5. Test the loop end-to-end: sign up a test address on the Ghost site; confirm the webhook creates the contact (source `g3d:ghost:<slug>`) within seconds, and that the next sweep is a no-op for it.
6. In Ghost, compose a post → Send via email → audience "Specific people" → pick the `newsletter` label to confirm segmentation targeting works.

---

## Self-Review Notes

- **Spec coverage:** §1→Task 1, §2→Task 2, §3→Task 3 (+422-adopt, delabel, invalid-skip, link-steal), §4→Tasks 4–5, §5→Task 6, §6→Tasks 4+7 (lock, rake, scheduler), §7 error handling→Tasks 2/3/5, §8 testing→each task's tests. CSV backfill: explicitly out of scope per spec.
- **Known judgment call encoded in Task 4:** pushed contacts also acquire `g3d:ghost:<slug>` sources once Ghost subscribes them — sources reflect live subscription state for all members. This makes "who is subscribed to X" queryable in stacks and costs one extra source per pushed contact.
- **Type consistency check:** member hashes are string-keyed everywhere; `create_member`/`update_member` take symbol-keyed attrs (JSON.dump normalizes); `summary` uses symbol keys (`:created, :updated, :delabeled, :pulled, :skipped_invalid, :link_conflicts, :errors`).
