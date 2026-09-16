# Ghost Source-Driven Newsletter Subscriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Derive each Ghost member's newsletter subscriptions from the first colon-segment of their enabled Stacks sources, granting a newsletter at most once per member and never removing one.

**Architecture:** Extends the existing full-state sweep in `Stacks::GhostSync`. A write-once per-contact ledger in `contacts.ghost_data` plus a hardened read of Ghost's member event history establishes "has this member ever been subscribed to N". A per-sweep write budget bounds API volume across an 18,980-contact backfill.

**Tech Stack:** Rails 6.1.7.10, Ruby 3.1.7, Postgres/jsonb, Storext 3.3.0 (Virtus-backed), ActiveAdmin + Arbre, minitest + mocha, HTTParty.

**Spec:** `docs/superpowers/specs/2026-09-16-ghost-source-newsletter-subscriptions-design.md`. Read "Verified platform facts" in full before starting. Those rows were established by probing the live API and running this app's bundle, specifically because several fail *silently* rather than raising.

## Global Constraints

- Ruby 3.1.7 / Rails 6.1.7.10. No new gems.
- Tests: minitest + mocha. `mock("ghost")` is **strict** - any un-stubbed call raises `unexpected invocation`. Never call the real Ghost API from a test.
- Run tests with `RAILS_ENV=test bundle exec rails test <path>`.
- Work in this worktree on branch `feat/ghost-source-newsletter-subscriptions`. Verify with `git branch --show-current` before every commit. Never commit to `main` or to the main checkout.
- **UI copy must not use em dashes.**
- Key everything by Ghost newsletter **id**, never slug.
- Never send `subscribed` in a member write. Never remove a subscription. Never write `newsletters` without a fresh GET immediately prior in the same code path.
- Read Storext booleans via the **predicate** (`foo?`), never the bare reader. Clamp Storext integers with `.to_i`. Never mutate a Storext Hash in place.
- Ledger writes are **in-memory on `contact.ghost_data`** only, persisted by the single `update!` at the end of `sync_contact!`. Never `update_column`, `update_all`, or raw jsonb SQL for the ledger.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/models/system.rb` | The four new Storext settings plus safe accessors that absorb the coercion traps. |
| `test/models/system_test.rb` | **New.** Coercion edge cases for those settings. |
| `lib/stacks/ghost.rb` | `find_member`, and `newsletter_events_for` with all layer-3 hardening. |
| `test/lib/stacks/ghost_test.rb` | Client tests, stubbing `Stacks::Ghost.stubs(:get)`. |
| `app/models/contact.rb` | Ledger read/write helpers; ledger unioning in `dedupe!` and the `fresh_existing` merge. |
| `test/models/contact_test.rb` | Ledger helper + merge tests. |
| `lib/stacks/ghost_sync.rb` | Prefix/targets, per-sweep config, observation, grant decision, apply, budget, summary. |
| `test/lib/stacks/ghost_sync_test.rb` | Sweep tests. |
| `app/admin/ghost_sync.rb` | Mapping table, grants toggle, budget field, impact preview, last-sweep summary. |
| `app/admin/contacts.rb` | Ledger rows on the contact show page. |
| `lib/tasks/stacks.rake` | Advisory lock around the `dedupe!` loop. |

---

### Task 1: System settings with trap-absorbing accessors

**Files:**
- Modify: `app/models/system.rb:7-12`
- Test: `test/models/system_test.rb` (create)

**Interfaces:**
- Produces: `System#ghost_newsletter_prefix_map` (Hash), `System#ghost_newsletter_grants_enabled?` (Boolean predicate), `System#ghost_sweep_write_budget` (Integer), `System#ghost_last_sync_summary` (Hash), and class helper `System.ghost_settings` returning a fresh, normalized struct.

**Why this task exists:** every one of these settings has a silent-failure mode verified in the spec. `""` reads back truthy through a Storext Boolean reader; `""` and `"abc"` stay Strings through an Integer reader and raise on `> 0`.

- [ ] **Step 1: Write the failing tests**

Create `test/models/system_test.rb`:

```ruby
require "test_helper"

class SystemModelTest < ActiveSupport::TestCase
  def sys
    @sys ||= System.first_or_create!(settings: {})
  end

  test "grants flag: blank stored value reads false through the predicate, not truthy" do
    sys.update!(ghost_newsletter_grants_enabled: "")
    # The bare Storext reader returns "" here, which is truthy in Ruby. The predicate
    # is the only safe accessor, and it is what the sweep must use.
    refute sys.ghost_newsletter_grants_enabled?
  end

  test "grants flag coerces the values an HTML form can actually send" do
    { "0" => false, "1" => true, "" => false }.each do |stored, expected|
      sys.update!(ghost_newsletter_grants_enabled: stored)
      assert_equal expected, sys.ghost_newsletter_grants_enabled?, "stored #{stored.inspect}"
    end
  end

  test "write budget never returns a value that raises on comparison" do
    ["", "abc", nil, "0", "-5"].each do |stored|
      sys.update!(ghost_sweep_write_budget: stored)
      budget = sys.ghost_sweep_write_budget_clamped
      assert_kind_of Integer, budget, "stored #{stored.inspect}"
      assert_operator budget, :>=, 1, "stored #{stored.inspect}"
    end
    sys.update!(ghost_sweep_write_budget: "3000")
    assert_equal 3000, sys.ghost_sweep_write_budget_clamped
  end

  test "prefix map rejects blank values so a blank can never be treated as a newsletter id" do
    sys.update!(ghost_newsletter_prefix_map: { "index" => "nl-1", "xxix" => "" })
    assert_equal({ "index" => "nl-1" }, sys.ghost_newsletter_prefix_map_clean)
  end

  test "prefix map must be assigned wholesale; in-place mutation does not persist" do
    sys.update!(ghost_newsletter_prefix_map: { "index" => "nl-1" })
    sys.ghost_newsletter_prefix_map["xxix"] = "nl-2"
    sys.save!
    assert_equal({ "index" => "nl-1" }, sys.reload.ghost_newsletter_prefix_map)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/models/system_test.rb`
Expected: FAIL, `NoMethodError: undefined method 'ghost_newsletter_grants_enabled='`

- [ ] **Step 3: Implement**

In `app/models/system.rb`, inside the existing `store_attributes :settings do` block, after `ghost_synced_sources`:

```ruby
    ghost_newsletter_prefix_map Hash, default: {}
    ghost_newsletter_grants_enabled Boolean, default: false
    ghost_sweep_write_budget Integer, default: 2500
    ghost_last_sync_summary Hash, default: {}
```

Then add these public instance methods to `System` (above the `private` keyword):

```ruby
  # Storext/Virtus stores "" and "abc" verbatim for an Integer attribute, so the
  # raw reader can hand back a String and `budget > 0` raises ArgumentError. In
  # stacks.rake that exception is swallowed into a log line, which would silently
  # stop the daily Ghost sync. Always read the budget through here.
  def ghost_sweep_write_budget_clamped
    [ghost_sweep_write_budget.to_i, 1].max
  end

  # A blank map value would otherwise be a truthy "newsletter id".
  def ghost_newsletter_prefix_map_clean
    ghost_newsletter_prefix_map.to_h.reject { |_, v| v.to_s.blank? }
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/models/system_test.rb`
Expected: 5 runs, 0 failures

- [ ] **Step 5: Commit**

```bash
git branch --show-current   # must print feat/ghost-source-newsletter-subscriptions
git add app/models/system.rb test/models/system_test.rb
git commit -m "feat: Ghost newsletter settings with coercion-safe accessors"
```

---

### Task 2: Ghost client - find_member and hardened newsletter_events_for

**Files:**
- Modify: `lib/stacks/ghost.rb`
- Test: `test/lib/stacks/ghost_test.rb`

**Interfaces:**
- Produces: `Stacks::Ghost#find_member(id)` returning a member Hash. `Stacks::Ghost#newsletter_events_for(member_id, current_newsletter_ids: [])` returning an Array of raw event Hashes, or **raising** `Stacks::Ghost::UntrustworthyHistory` when the result cannot be trusted.
- Consumes: nothing from earlier tasks.

**This is the highest-risk task in the plan.** The endpoint returns `200 {"events": []}` for a nonexistent *and* for a malformed member id. A naive reading of that is "never subscribed", which grants. Write the hardening tests first.

Verified constraints you must honour (do not re-derive, do not assume otherwise):
- `data.subscribed` and `data.newsletter_id` are **not** filterable (400). Filter by `type` and `data.member_id` only, inspect the rest in Ruby.
- `data.created_at:<'<iso>'` **is** filterable and applied. Quotes must be **raw**, never percent-encoded (`%27` yields 422).
- `limit` caps at **100**; `limit: "all"` is coerced to 100, unlike `/newsletters/`.
- The `page` param is **silently ignored**, unlike `/members/`. Page with a `created_at` cursor.
- `meta.pagination.total` is reliable.
- Use `data["newsletter_id"]` (scalar), not `data["newsletter"]["id"]`.

- [ ] **Step 1: Write the failing tests**

Append to `test/lib/stacks/ghost_test.rb`:

```ruby
  MEMBER_ID = "6aaa0647345d7200012fc658".freeze

  def nl_event(member_id: MEMBER_ID, newsletter_id: "nl-1", subscribed: true, created_at: "2026-09-16T03:00:23.000Z")
    { "type" => "newsletter_event",
      "data" => { "id" => "ev-#{rand(1_000_000)}", "member_id" => member_id,
                  "subscribed" => subscribed, "created_at" => created_at,
                  "source" => "api", "newsletter_id" => newsletter_id } }
  end

  def events_response(events, total: nil)
    fake_response(code: 200, body: {
      events: events,
      meta: { pagination: { limit: 100, total: total || events.length, pages: 1, page: nil, next: nil } },
    })
  end

  test "newsletter_events_for returns events and filters by type and member only" do
    client = build_client
    Stacks::Ghost.expects(:get).with { |url, opts|
      url.include?("/members/events/") &&
        opts[:query][:filter].include?("type:newsletter_event") &&
        opts[:query][:filter].include?(MEMBER_ID) &&
        # verified 400s if present
        !opts[:query][:filter].include?("data.subscribed") &&
        !opts[:query][:filter].include?("data.newsletter_id") &&
        # verified silently ignored on this endpoint
        !opts[:query].key?(:page) &&
        opts[:query][:limit] == 100
    }.returns(events_response([nl_event]))

    events = client.newsletter_events_for(MEMBER_ID)
    assert_equal 1, events.length
    assert_equal "nl-1", events.first["data"]["newsletter_id"]
  end

  test "newsletter_events_for rejects a malformed member id without issuing a request" do
    client = build_client
    Stacks::Ghost.expects(:get).never
    ["not-an-id", "", nil, "6AAA0647345D7200012FC658", "6aaa0647345d7200012fc65"].each do |bad|
      assert_raises(Stacks::Ghost::UntrustworthyHistory) { client.newsletter_events_for(bad) }
    end
  end

  test "newsletter_events_for raises when an event belongs to a different member" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event(member_id: "someone-else")]))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) { client.newsletter_events_for(MEMBER_ID) }
  end

  test "newsletter_events_for raises when fewer events are collected than meta.pagination.total" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event], total: 7))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) { client.newsletter_events_for(MEMBER_ID) }
  end

  test "newsletter_events_for raises on an empty history for a member that has live subscriptions" do
    # A 200 with an empty list is what a nonexistent or malformed member id returns.
    # A member currently subscribed to something MUST have at least one event, so an
    # empty result here is incoherent and must never read as "never subscribed".
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
  end

  test "newsletter_events_for allows a genuinely empty history for a member with no subscriptions" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    assert_equal [], client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
  end

  test "newsletter_events_for pages with a raw-quoted created_at cursor, never the page param" do
    client = build_client
    page1 = Array.new(100) { |i| nl_event(created_at: "2026-09-#{format('%02d', 16 - (i / 20))}T03:00:23.000Z") }
    page2 = [nl_event(created_at: "2026-08-01T00:00:00.000Z")]
    seen_filters = []
    Stacks::Ghost.stubs(:get).with { |_url, opts| seen_filters << opts[:query][:filter]; true }
      .returns(events_response(page1, total: 101)).then.returns(events_response(page2, total: 101))

    events = client.newsletter_events_for(MEMBER_ID)
    assert_equal 101, events.length
    assert_equal 2, seen_filters.length
    assert seen_filters[1].include?("data.created_at:<'"), "cursor must use raw single quotes"
    refute seen_filters[1].include?("%27"), "percent-encoded quotes yield 422"
  end

  test "newsletter_events_for raises rather than looping when a page does not advance the cursor" do
    client = build_client
    stuck = Array.new(100) { nl_event(created_at: "2026-09-16T03:00:23.000Z") }
    Stacks::Ghost.stubs(:get).returns(events_response(stuck, total: 500))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) { client.newsletter_events_for(MEMBER_ID) }
  end

  test "find_member requests one member with labels and newsletters" do
    client = build_client
    Stacks::Ghost.expects(:get).with { |url, opts|
      url.include?("/members/m1/") && opts[:query][:include] == "labels,newsletters"
    }.returns(fake_response(code: 200, body: { members: [{ id: "m1", email: "a@x.com" }] }))
    assert_equal "m1", client.find_member("m1")["id"]
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_test.rb`
Expected: FAIL, `NameError: uninitialized constant Stacks::Ghost::UntrustworthyHistory`

- [ ] **Step 3: Implement**

In `lib/stacks/ghost.rb`, add the error class next to `RequestError`:

```ruby
  # Raised when a member's event history cannot be trusted to be complete and
  # correct. The events endpoint returns 200 with an empty list for a nonexistent
  # OR malformed member id, so "no events" is not evidence of "never subscribed".
  # Callers MUST treat this as fail-closed: no grants.
  class UntrustworthyHistory < StandardError; end

  MEMBER_ID_FORMAT = /\A[0-9a-f]{24}\z/.freeze
  EVENTS_PAGE_LIMIT = 100
  EVENTS_MAX_PAGES = 20
```

Add the public methods:

```ruby
  def find_member(id)
    response = handle_response {
      self.class.get(url("/members/#{id}/"), query: { include: "labels,newsletters" }, headers: headers)
    }
    (response.parsed_response["members"] || []).first
  end

  # Returns every newsletter_event for a member, or raises UntrustworthyHistory.
  # current_newsletter_ids enables the coherence check: a member currently
  # subscribed to something must have at least one event.
  def newsletter_events_for(member_id, current_newsletter_ids: [])
    unless member_id.to_s.match?(MEMBER_ID_FORMAT)
      raise UntrustworthyHistory, "refusing to query events for malformed member id #{member_id.inspect}"
    end

    collected = []
    cursor = nil
    total = nil
    pages = 0

    loop do
      pages += 1
      if pages > EVENTS_MAX_PAGES
        raise UntrustworthyHistory, "member #{member_id} exceeded #{EVENTS_MAX_PAGES} event pages"
      end

      # NQL quoting mirrors find_member_by_email. Quotes must be RAW: HTTParty
      # encodes the query itself, so a pre-encoded %27 arrives as %2527 and 422s.
      filter = "type:newsletter_event+data.member_id:'#{member_id}'"
      filter += "+data.created_at:<'#{cursor}'" if cursor

      response = handle_response {
        self.class.get(url("/members/events/"), query: {
          filter: filter, limit: EVENTS_PAGE_LIMIT, order: "created_at desc",
        }, headers: headers)
      }
      body = response.parsed_response
      page = body["events"] || []
      total ||= body.dig("meta", "pagination", "total")

      page.each do |event|
        actual = event.dig("data", "member_id")
        next if actual == member_id
        raise UntrustworthyHistory, "event for member #{actual.inspect} returned when querying #{member_id}"
      end

      collected += page
      break if page.length < EVENTS_PAGE_LIMIT

      oldest = page.map { |e| e.dig("data", "created_at") }.compact.min
      if oldest.nil? || (cursor && oldest >= cursor)
        raise UntrustworthyHistory, "member #{member_id} event cursor did not advance past #{cursor.inspect}"
      end
      cursor = oldest
    end

    if total && collected.length < total
      raise UntrustworthyHistory, "collected #{collected.length} of #{total} events for member #{member_id}"
    end

    if collected.empty? && current_newsletter_ids.any?
      raise UntrustworthyHistory,
        "member #{member_id} is subscribed to #{current_newsletter_ids.length} newsletter(s) but has no events"
    end

    collected
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_test.rb`
Expected: all green, including the pre-existing client tests

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add lib/stacks/ghost.rb test/lib/stacks/ghost_test.rb
git commit -m "feat: hardened Ghost member event history reads"
```

---

### Task 3: Contact ledger helpers and merge unioning

**Files:**
- Modify: `app/models/contact.rb` (add helpers; extend `dedupe!` around `:181-191` and the `fresh_existing` merge around `:90-104`)
- Test: `test/models/contact_test.rb`

**Interfaces:**
- Produces: `Contact#newsletter_ledger` -> Hash, `Contact#newsletter_ledger_entries` -> Hash, `Contact#ledger_member_id` -> String or nil, `Contact#ledger_has?(newsletter_id)` -> Boolean, `Contact#ledger_state(newsletter_id)` -> String or nil, `Contact#record_ledger_entry!(newsletter_id, state, member_id:)` (in-memory only, does NOT save), and `Contact.merge_newsletter_ledgers(ledgers)` -> Hash.
- Consumes: nothing.

Ledger shape: `ghost_data["newsletter_ledger"] = { "member_id" => "<id>", "entries" => { "<nl id>" => { "state" => ..., "at" => iso8601 } } }`.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/contact_test.rb`:

```ruby
  test "record_ledger_entry! is write-once and mutates in memory without saving" do
    c = Contact.create!(email: "ledger@example.com")
    c.record_ledger_entry!("nl-1", "granted", member_id: "m1")
    first_at = c.ledger_entry("nl-1")["at"]
    c.record_ledger_entry!("nl-1", "observed", member_id: "m1")

    assert_equal "granted", c.ledger_state("nl-1"), "an existing entry is never overwritten"
    assert_equal first_at, c.ledger_entry("nl-1")["at"]
    assert_equal({}, c.reload.ghost_data, "record_ledger_entry! must not persist on its own")
  end

  test "ledger records the member id it describes" do
    c = Contact.create!(email: "ledger2@example.com")
    c.record_ledger_entry!("nl-1", "observed", member_id: "m1")
    assert_equal "m1", c.ledger_member_id
    assert c.ledger_has?("nl-1")
    refute c.ledger_has?("nl-2")
  end

  test "merge_newsletter_ledgers unions entries and keeps the earliest at" do
    early = { "member_id" => "m1", "entries" => { "nl-1" => { "state" => "history", "at" => "2026-01-01T00:00:00Z" } } }
    late  = { "member_id" => "m1", "entries" => {
      "nl-1" => { "state" => "granted", "at" => "2026-06-01T00:00:00Z" },
      "nl-2" => { "state" => "observed", "at" => "2026-06-01T00:00:00Z" } } }

    merged = Contact.merge_newsletter_ledgers([late, early])
    assert_equal "history", merged["entries"]["nl-1"]["state"], "earliest entry wins"
    assert_equal "2026-01-01T00:00:00Z", merged["entries"]["nl-1"]["at"]
    assert_equal "observed", merged["entries"]["nl-2"]["state"]
  end

  test "dedupe! unions ledgers regardless of which dupe owns ghost_id" do
    keeper = Contact.create!(email: "dupe@example.com", ghost_data: {
      "newsletter_ledger" => { "member_id" => "m1", "entries" => {
        "nl-1" => { "state" => "history", "at" => "2026-01-01T00:00:00Z" } } } })
    Contact.create!(email: "DUPE@example.com", ghost_id: "m1", ghost_data: {
      "newsletter_ledger" => { "member_id" => "m1", "entries" => {
        "nl-2" => { "state" => "granted", "at" => "2026-02-01T00:00:00Z" } } } })

    survivor = keeper.dedupe!
    entries = survivor.ghost_data.dig("newsletter_ledger", "entries")
    assert_equal %w[nl-1 nl-2], entries.keys.sort, "a lost ledger entry is a consent violation"
    assert_equal "m1", survivor.ghost_id
  end

  test "dedupe! preserves deleted_at alongside a unioned ledger" do
    keeper = Contact.create!(email: "dupe2@example.com", ghost_data: {
      "newsletter_ledger" => { "member_id" => "m2", "entries" => {
        "nl-1" => { "state" => "history", "at" => "2026-01-01T00:00:00Z" } } } })
    Contact.create!(email: "DUPE2@example.com", ghost_id: "m2",
      ghost_data: { "snapshot" => { "deleted_at" => "2026-03-01T00:00:00Z" } })

    survivor = keeper.dedupe!
    assert_equal "2026-03-01T00:00:00Z", survivor.ghost_data.dig("snapshot", "deleted_at")
    assert survivor.ghost_data.dig("newsletter_ledger", "entries").key?("nl-1")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/models/contact_test.rb`
Expected: FAIL, `NoMethodError: undefined method 'record_ledger_entry!'`

- [ ] **Step 3: Implement**

Add to `Contact` (public, near `merge_source_events`):

```ruby
  # Unions write-once newsletter ledgers across merging duplicates. A lost entry
  # could re-subscribe someone who deliberately unsubscribed, so the earliest
  # entry for a newsletter always wins. Builds a NEW hash rather than mutating a
  # loser's nested hash, matching the deleted_at handling in dedupe!.
  def self.merge_newsletter_ledgers(ledgers)
    present = Array(ledgers).compact.reject(&:blank?)
    return {} if present.empty?

    entries = {}
    present.each do |ledger|
      (ledger["entries"] || {}).each do |newsletter_id, entry|
        existing = entries[newsletter_id]
        next if existing && existing["at"].to_s <= entry["at"].to_s
        entries[newsletter_id] = entry.dup
      end
    end
    { "member_id" => present.map { |l| l["member_id"] }.compact.first, "entries" => entries }.compact
  end

  def newsletter_ledger
    ghost_data["newsletter_ledger"] || {}
  end

  def newsletter_ledger_entries
    newsletter_ledger["entries"] || {}
  end

  def ledger_member_id
    newsletter_ledger["member_id"]
  end

  def ledger_entry(newsletter_id)
    newsletter_ledger_entries[newsletter_id.to_s]
  end

  def ledger_has?(newsletter_id)
    newsletter_ledger_entries.key?(newsletter_id.to_s)
  end

  def ledger_state(newsletter_id)
    ledger_entry(newsletter_id)&.dig("state")
  end

  # Write-once, in memory only. The caller persists via the single update! at the
  # end of sync_contact!. Never write the ledger with update_column/update_all/raw
  # jsonb: link_contact! rebuilds ghost_data from this same in-memory hash and
  # would clobber an out-of-band write.
  def record_ledger_entry!(newsletter_id, state, member_id:)
    ledger = newsletter_ledger.deep_dup
    ledger["member_id"] ||= member_id
    ledger["entries"] ||= {}
    return self if ledger["entries"].key?(newsletter_id.to_s)

    ledger["entries"][newsletter_id.to_s] = { "state" => state.to_s, "at" => Time.current.iso8601 }
    self.ghost_data = ghost_data.merge("newsletter_ledger" => ledger)
    self
  end
```

In `dedupe!`, after the existing `any_deleted_at` block and before `losers.each`, add:

```ruby
        merged_ledger = Contact.merge_newsletter_ledgers(dupes.map { |d| d.ghost_data["newsletter_ledger"] })
        merged_ghost_data["newsletter_ledger"] = merged_ledger if merged_ledger.present?
```

In the `fresh_existing` merge in `sync_to_apollo!`, inside `if fresh_existing`, after the existing `deleted_at` preservation block, add:

```ruby
                merged_ledger = Contact.merge_newsletter_ledgers(
                  [self.ghost_data["newsletter_ledger"], fresh_existing.ghost_data["newsletter_ledger"]]
                )
                if merged_ledger.present?
                  self.ghost_data = self.ghost_data.merge("newsletter_ledger" => merged_ledger)
                end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/models/contact_test.rb`
Expected: all green

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add app/models/contact.rb test/models/contact_test.rb
git commit -m "feat: write-once newsletter ledger on contacts with merge unioning"
```

---

### Task 4: Prefix derivation, targets, and per-sweep config load

**Files:**
- Modify: `lib/stacks/ghost_sync.rb`
- Test: `test/lib/stacks/ghost_sync_test.rb`

**Interfaces:**
- Produces: `Stacks::GhostSync::EXCLUDED_SOURCE_PREFIX = "g3d:ghost"`, `.source_prefix(source)` -> String, `#target_newsletter_ids(contact, enabled)` -> Array of ids. Instance state set up in `sync_all!`: `@prefix_map`, `@grants_enabled`, `@writes_remaining`, `@active_newsletter_ids`.
- Consumes: Task 1's `System#ghost_newsletter_prefix_map_clean`, `#ghost_newsletter_grants_enabled?`, `#ghost_sweep_write_budget_clamped`.

- [ ] **Step 1: Write the failing tests**

Append to `test/lib/stacks/ghost_sync_test.rb`:

```ruby
  test "source_prefix takes the first colon segment, downcased" do
    { "index:luma:chinatown" => "index", "xxix:" => "xxix", "team" => "team",
      "G3D:foo" => "g3d", "sanctu:luma:family.intelligence" => "sanctu" }.each do |source, expected|
      assert_equal expected, Stacks::GhostSync.source_prefix(source), source
    end
  end

  test "the g3d:ghost namespace never produces a target even when g3d is mapped" do
    enable_sources("g3d:ghost", "g3d:ghost:index", "g3d:substack:g3d_substack")
    System.instance.update!(ghost_newsletter_prefix_map: { "g3d" => "nl-g3d" })
    contact = Contact.create!(email: "loop@example.com", sources: ["g3d:ghost", "g3d:ghost:index"])
    sync = sync_with(mock("ghost"))
    sync.send(:load_newsletter_config!)
    assert_equal [], sync.target_newsletter_ids(contact, System.instance.ghost_synced_sources)
  end

  test "targets come only from enabled, mapped, non-blank prefixes" do
    enable_sources("index:shopify_customer", "xxix:mailchimp:xxix_mailchimp")
    System.instance.update!(ghost_newsletter_prefix_map: {
      "index" => "nl-index", "xxix" => "", "usb_club" => "nl-usb" })
    contact = Contact.create!(email: "t@example.com", sources: [
      "index:shopify_customer",              # enabled + mapped
      "xxix:mailchimp:xxix_mailchimp",       # enabled but mapped to blank
      "usb_club:shopify_customer",           # mapped but NOT enabled
      "etl:meet",                            # neither
    ])
    sync = sync_with(mock("ghost"))
    sync.send(:load_newsletter_config!)
    assert_equal ["nl-index"], sync.target_newsletter_ids(contact, System.instance.ghost_synced_sources)
  end

  test "an empty prefix map issues no all_newsletters call" do
    enable_sources("newsletter")
    Contact.create!(email: "nomap@example.com", sources: ["newsletter"])
    ghost = mock("ghost")
    ghost.expects(:all_newsletters).never
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).returns(member(id: "m1", email: "nomap@example.com"))
    sync_with(ghost).sync_all!
  end

  test "the sweep reads settings fresh, not through the memoized System.instance" do
    enable_sources("index:shopify_customer")
    System.instance   # prime the class-variable memo
    # Change the row behind the memo, the way another puma worker or a rake dyno would.
    System.first.update_columns(settings: System.first.settings.merge(
      "ghost_newsletter_prefix_map" => { "index" => "nl-index" }))

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    sync = sync_with(ghost)
    sync.send(:load_newsletter_config!)
    assert_equal({ "index" => "nl-index" }, sync.instance_variable_get(:@prefix_map),
      "System.instance memoizes per process and is never invalidated")
  end

  test "a mapping to an unknown or archived newsletter is dropped and counted" do
    enable_sources("index:shopify_customer")
    System.instance.update!(ghost_newsletter_prefix_map: {
      "index" => "nl-index", "sanctu" => "nl-archived", "team" => "nl-missing" })
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns([
      { "id" => "nl-index", "name" => "Index Space", "slug" => "index", "status" => "active" },
      { "id" => "nl-archived", "name" => "Old", "slug" => "old", "status" => "archived" },
    ])
    sync = sync_with(ghost)
    sync.send(:load_newsletter_config!)
    assert_equal({ "index" => "nl-index" }, sync.instance_variable_get(:@prefix_map))
    assert_equal 2, sync.summary[:grant_mapping_invalid]
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: FAIL, `NoMethodError: undefined method 'source_prefix'`

- [ ] **Step 3: Implement**

Add near `SOURCE_PREFIX` in `lib/stacks/ghost_sync.rb`:

```ruby
  # Sources under this namespace are stacks' own record of Ghost opt-in state,
  # written by the pull leg. Deriving subscriptions from them would subscribe
  # everyone who subscribed to anything to the g3d newsletter: a consent feedback
  # loop. They are excluded from prefix derivation, always.
  EXCLUDED_SOURCE_PREFIX = "g3d:ghost".freeze

  def self.source_prefix(source)
    source.to_s.split(":", 2).first.to_s.downcase
  end

  def self.excluded_source?(source)
    s = source.to_s.downcase
    s == EXCLUDED_SOURCE_PREFIX || s.start_with?("#{EXCLUDED_SOURCE_PREFIX}:")
  end
```

Add the public target resolver:

```ruby
  def target_newsletter_ids(contact, enabled)
    (contact.sources & enabled)
      .reject { |s| self.class.excluded_source?(s) }
      .map { |s| @prefix_map[self.class.source_prefix(s)] }
      .compact.uniq
  end
```

Add the private per-sweep config loader:

```ruby
  # Read settings fresh every sweep. System.instance memoizes in a class variable
  # that is never invalidated, so a setting saved in one puma worker is invisible
  # to another forever, and the admin "Sync Now" button runs this in a web dyno.
  def load_newsletter_config!
    system = System.first_or_create!(settings: {})
    @grants_enabled = system.ghost_newsletter_grants_enabled?
    @writes_remaining = system.ghost_sweep_write_budget_clamped
    requested = system.ghost_newsletter_prefix_map_clean

    if requested.empty?
      @prefix_map = {}
      return @prefix_map
    end

    # Reuses the lazily-built slug map's fetch rather than adding a second one.
    active = @ghost.all_newsletters.select { |n| n["status"].nil? || n["status"] == "active" }
    active_ids = active.map { |n| n["id"] }.to_set
    @prefix_map = requested.select { |_, id| active_ids.include?(id) }
    @summary[:grant_mapping_invalid] += (requested.length - @prefix_map.length)
    @prefix_map
  end
```

Call `load_newsletter_config!` as the first line of `sync_all!`, before `enabled = ...`.

Note the `n["status"].nil?` allowance: the existing test fixture helper emits no `status` key, and treating a missing status as inactive would drop every newsletter in tests.

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: all green, including the 34 pre-existing sweep tests

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add lib/stacks/ghost_sync.rb test/lib/stacks/ghost_sync_test.rb
git commit -m "feat: prefix-to-newsletter mapping and per-sweep Ghost config"
```

---

### Task 5: Observation leg writes `observed` entries in the pull

**Files:**
- Modify: `lib/stacks/ghost_sync.rb` (`upsert_contact_from_member`)
- Test: `test/lib/stacks/ghost_sync_test.rb`

**Interfaces:**
- Consumes: Task 3's `Contact#record_ledger_entry!`.
- Produces: every linked contact gains an `observed` entry per currently subscribed newsletter id.

This runs regardless of the grants flag. It is what makes layer 2 a real backstop for anyone who unsubscribes after this ships.

- [ ] **Step 1: Write the failing tests**

```ruby
  test "the pull leg records observed ledger entries for current subscriptions" do
    ghost = mock("ghost")
    sync = sync_with(ghost)
    m = member(id: "m90", email: "obs@example.com", newsletters: %w[weekly])
    contact = sync.upsert_contact_from_member(m).reload

    assert_equal "observed", contact.ledger_state("nl-weekly")
    assert_equal "m90", contact.ledger_member_id
    assert_equal ["weekly"], contact.ghost_data.dig("snapshot", "newsletters"),
      "snapshot semantics must be untouched"
  end

  test "observation never overwrites an existing ledger entry" do
    ghost = mock("ghost")
    sync = sync_with(ghost)
    contact = Contact.create!(email: "obs2@example.com", ghost_id: "m91", ghost_data: {
      "newsletter_ledger" => { "member_id" => "m91", "entries" => {
        "nl-weekly" => { "state" => "history", "at" => "2026-01-01T00:00:00Z" } } } })

    sync.upsert_contact_from_member(member(id: "m91", email: "obs2@example.com", newsletters: %w[weekly]))
    assert_equal "history", contact.reload.ledger_state("nl-weekly")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb -n "/observed|observation/"`
Expected: FAIL, ledger_state returns nil

- [ ] **Step 3: Implement**

In `upsert_contact_from_member`, after the `new_ghost_data` assignment and before `contact.save! if contact.changed?`:

```ruby
    (member["newsletters"] || []).map { |n| n["id"] }.compact.each do |newsletter_id|
      contact.record_ledger_entry!(newsletter_id, "observed", member_id: member["id"])
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: all green

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add lib/stacks/ghost_sync.rb test/lib/stacks/ghost_sync_test.rb
git commit -m "feat: record observed newsletter subscriptions in the pull leg"
```

---

### Task 6: Extract `label_attrs_for` (pure refactor, no behaviour change)

**Files:**
- Modify: `lib/stacks/ghost_sync.rb:197-219`
- Test: `test/lib/stacks/ghost_sync_test.rb` (existing tests must keep passing unchanged)

**Interfaces:**
- Produces: `label_attrs_for(contact, member, desired, enabled)` -> Hash of attrs or `nil`, issuing **no** HTTP request. `update_member_labels` keeps its signature and behaviour, now delegating.
- Consumes: nothing.

The grant path needs the label diff computed against a *fresh* member without issuing its own PUT. This task changes no behaviour; it only separates the computation from the request so Task 8 can combine them into one write.

- [ ] **Step 1: Write the failing test**

```ruby
  test "label_attrs_for computes the label diff without issuing a request" do
    enable_sources("newsletter", "fundraising")
    contact = Contact.create!(email: "attrs@example.com", sources: %w[newsletter fundraising])
    existing = member(id: "m70", email: "attrs@example.com", labels: ["VIP", "newsletter"])

    ghost = mock("ghost")
    ghost.expects(:update_member).never
    sync = sync_with(ghost)
    attrs = sync.send(:label_attrs_for, contact, existing, %w[fundraising newsletter], %w[newsletter fundraising])

    assert_equal ["VIP", "fundraising", "newsletter"], attrs[:labels].sort
    refute attrs.key?(:newsletters)
  end

  test "label_attrs_for returns nil when nothing needs changing" do
    enable_sources("newsletter")
    contact = Contact.create!(email: "attrs2@example.com", sources: %w[newsletter], display_name: nil)
    existing = member(id: "m71", email: "attrs2@example.com", labels: ["newsletter"], name: "Has Name")
    sync = sync_with(mock("ghost"))
    assert_nil sync.send(:label_attrs_for, contact, existing, %w[newsletter], %w[newsletter])
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb -n "/label_attrs_for/"`
Expected: FAIL, `NoMethodError: undefined method 'label_attrs_for'`

- [ ] **Step 3: Implement**

Replace the body of `update_member_labels` with a delegation, keeping all of its existing comments on the new pure method:

```ruby
  # Pure: computes the attrs a label-only write would send, or nil for a no-op.
  # Issues no request, so the grant path can recompute the diff against a fresh
  # member and fold it into a single PUT.
  def label_attrs_for(contact, member, desired, enabled)
    attrs = {}
    if managed_label_names(member, enabled).map(&:downcase).uniq.sort != desired.map(&:downcase).uniq.sort
      enabled_downcased = enabled.map(&:downcase)
      preserved = label_names(member).reject { |n| enabled_downcased.include?(n.downcase) }
      attrs[:labels] = preserved + desired
    end
    if member["name"].blank? && contact.display_name.present?
      attrs[:name] = contact.display_name
    end
    attrs.presence
  end

  def update_member_labels(contact, member, desired, enabled)
    attrs = label_attrs_for(contact, member, desired, enabled)
    return nil if attrs.nil?

    updated = @ghost.update_member(member["id"], attrs)
    @summary[:updated] += 1
    updated
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: all green, no existing test modified

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add lib/stacks/ghost_sync.rb test/lib/stacks/ghost_sync_test.rb
git commit -m "refactor: extract pure label_attrs_for from update_member_labels"
```

---

### Task 7: Grant decision for existing members (dry run only, no Ghost writes)

**Files:**
- Modify: `lib/stacks/ghost_sync.rb`
- Test: `test/lib/stacks/ghost_sync_test.rb`

**Interfaces:**
- Produces: `grant_candidates_for(contact, member, enabled)` -> Array of newsletter ids, writing `observed`/`history` ledger entries in memory as it goes and incrementing `already_handled`, `unsubscribe_respected`, `grant_skipped_undeliverable`, `grant_errors`.
- Consumes: Task 2's `newsletter_events_for`, Task 3's ledger helpers, Task 4's `target_newsletter_ids`.

This task implements decision steps 1, 2, 3, 5 and 6. Step 4 (budget) arrives in Task 9. No Ghost write happens yet; Task 8 adds the apply.

- [ ] **Step 1: Write the failing tests**

```ruby
  def grant_setup(sources:, map:, newsletters: [])
    enable_sources(*sources)
    System.instance.update!(ghost_newsletter_prefix_map: map)
    Contact.create!(email: "g@example.com", sources: sources, ghost_id: "m50")
  end

  def active_nl(*ids)
    ids.map { |i| { "id" => i, "name" => i, "slug" => i, "status" => "active" } }
  end

  test "a never-subscribed member with a mapped source becomes a grant candidate" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).with("m50", current_newsletter_ids: []).returns([])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal ["nl-xxix"], sync.send(:grant_candidates_for, contact, m, System.instance.ghost_synced_sources)
  end

  test "a currently subscribed newsletter is observed, never a candidate" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com", extra: {
      "newsletters" => [{ "id" => "nl-xxix", "name" => "XXIX", "status" => "active" }] })
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).never
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, System.instance.ghost_synced_sources)
    assert_equal "observed", contact.ledger_state("nl-xxix")
  end

  test "an existing ledger entry blocks the grant without any events call" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    contact.record_ledger_entry!("nl-xxix", "history", member_id: "m50")
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).never
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, System.instance.ghost_synced_sources)
    assert_equal 1, sync.summary[:unsubscribe_respected]
  end

  test "history showing any event for N blocks the grant and caches a history entry" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m50", "newsletter_id" => "nl-xxix", "subscribed" => false,
        "created_at" => "2026-01-01T00:00:00.000Z" } }])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, System.instance.ghost_synced_sources)
    assert_equal "history", contact.ledger_state("nl-xxix")
    assert_equal 1, sync.summary[:unsubscribe_respected]
  end

  test "history for a different newsletter does not block the grant" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m50", "newsletter_id" => "nl-other", "subscribed" => false,
        "created_at" => "2026-01-01T00:00:00.000Z" } }])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal ["nl-xxix"], sync.send(:grant_candidates_for, contact, m, System.instance.ghost_synced_sources)
  end

  test "an untrustworthy history fails closed for the whole member" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).raises(Stacks::Ghost::UntrustworthyHistory, "200 with empty list")
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, System.instance.ghost_synced_sources)
    assert_equal 1, sync.summary[:grant_errors]
    assert_equal({}, contact.newsletter_ledger_entries, "a failed history read writes no ledger entry")
  end

  test "a suppressed or email-disabled member is skipped before any events call" do
    [{ "email_suppression" => { "suppressed" => true } }, { "email_disabled" => true }].each_with_index do |extra, i|
      contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
      contact.update!(email: "g#{i}@example.com")
      m = member(id: "m50", email: contact.email, extra: extra)
      ghost = mock("ghost")
      ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
      ghost.expects(:newsletter_events_for).never
      sync = sync_with(ghost); sync.send(:load_newsletter_config!)

      assert_equal [], sync.send(:grant_candidates_for, contact, m, System.instance.ghost_synced_sources)
      assert_equal 1, sync.summary[:grant_skipped_undeliverable]
      assert_equal({}, contact.newsletter_ledger_entries)
    end
  end

  test "a ledger describing a different member is ignored, falling through to history" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    contact.record_ledger_entry!("nl-xxix", "granted", member_id: "SOMEONE-ELSE")
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).returns([])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal ["nl-xxix"], sync.send(:grant_candidates_for, contact, m, System.instance.ghost_synced_sources)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb -n "/grant|candidate|history|suppressed/"`
Expected: FAIL, `NoMethodError: undefined method 'grant_candidates_for'`

- [ ] **Step 3: Implement**

```ruby
  # Decision steps 1, 2, 3, 5, 6. Returns the newsletter ids this member has
  # provably never been subscribed to. Writes observed/history ledger entries in
  # memory; the caller persists them.
  #
  # The layer-3 read is deliberately NOT memoized across an API call. A candidate
  # is by definition not currently subscribed, so re-checking "is subscribed" in
  # the apply phase cannot disqualify one: only a fresh history read can.
  def grant_candidates_for(contact, member, enabled)
    targets = target_newsletter_ids(contact, enabled)
    return [] if targets.empty?

    current_ids = (member["newsletters"] || []).map { |n| n["id"] }.compact
    ledger_applies = contact.ledger_member_id.nil? || contact.ledger_member_id == member["id"]

    if member.dig("email_suppression", "suppressed") || member["email_disabled"]
      @summary[:grant_skipped_undeliverable] += 1
      return []
    end

    candidates = []
    events = nil

    targets.each do |newsletter_id|
      if current_ids.include?(newsletter_id)
        contact.record_ledger_entry!(newsletter_id, "observed", member_id: member["id"])
        next
      end

      if ledger_applies && contact.ledger_has?(newsletter_id)
        if contact.ledger_state(newsletter_id) == "history"
          @summary[:unsubscribe_respected] += 1
        else
          @summary[:already_handled] += 1
        end
        next
      end

      begin
        events ||= @ghost.newsletter_events_for(member["id"], current_newsletter_ids: current_ids)
      rescue Stacks::Ghost::UntrustworthyHistory, Stacks::Ghost::RequestError => e
        # Fail closed: no grants for this member this sweep, no ledger writes.
        @summary[:grant_errors] += 1
        @errors << "#{contact.email}: history unreadable: #{e.class}: #{e.message}"
        return []
      end

      if events.any? { |ev| ev.dig("data", "newsletter_id") == newsletter_id }
        contact.record_ledger_entry!(newsletter_id, "history", member_id: member["id"])
        @summary[:unsubscribe_respected] += 1
        next
      end

      candidates << newsletter_id
    end

    candidates
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: all green

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add lib/stacks/ghost_sync.rb test/lib/stacks/ghost_sync_test.rb
git commit -m "feat: three-layer grant decision for existing Ghost members"
```

---

### Task 8: Apply grants and set newsletters on create

**Files:**
- Modify: `lib/stacks/ghost_sync.rb` (`sync_contact!`)
- Test: `test/lib/stacks/ghost_sync_test.rb`

**Interfaces:**
- Consumes: Tasks 2, 3, 6, 7.
- Produces: `sync_contact!` issues at most one `update_member` per contact carrying `newsletters` (plus `labels` when they differ); the create path always sends an explicit `newsletters` array.

- [ ] **Step 1: Write the failing tests**

```ruby
  test "a grant re-reads the member and its history immediately before the PUT" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    System.instance.update!(ghost_newsletter_grants_enabled: "1")
    snapshot = member(id: "m50", email: "g@example.com")
    fresh = member(id: "m50", email: "g@example.com", extra: {
      "newsletters" => [{ "id" => "nl-index", "name" => "Index", "status" => "active" }] })

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix", "nl-index"))
    ghost.expects(:all_members).returns([snapshot])
    ghost.expects(:newsletter_events_for).twice.returns([])
    ghost.expects(:find_member).with("m50").returns(fresh)
    ghost.expects(:update_member).with { |id, attrs|
      id == "m50" &&
        attrs[:newsletters].map { |n| n[:id] }.sort == %w[nl-index nl-xxix] &&
        !attrs.key?(:subscribed)
    }.returns(fresh.merge("newsletters" => [
      { "id" => "nl-index" }, { "id" => "nl-xxix" }]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal "granted", contact.reload.ledger_state("nl-xxix")
    assert_equal 1, sync.summary[:granted]
  end

  test "an unsubscribe landing between the decision and the PUT blocks the write" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    System.instance.update!(ghost_newsletter_grants_enabled: "1")
    m = member(id: "m50", email: "g@example.com")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([m])
    ghost.expects(:find_member).with("m50").returns(m)
    # Decision-phase read sees nothing; the pre-PUT read sees the unsubscribe.
    ghost.expects(:newsletter_events_for).twice.returns([]).then.returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m50", "newsletter_id" => "nl-xxix", "subscribed" => false,
        "created_at" => "2026-09-16T04:00:00.000Z" } }])
    ghost.expects(:update_member).never

    sync_with(ghost).sync_all!
    assert_equal "history", contact.reload.ledger_state("nl-xxix")
  end

  test "with the grants flag off the decision runs but nothing is written to Ghost" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    System.instance.update!(ghost_newsletter_grants_enabled: "0")
    m = member(id: "m50", email: "g@example.com")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([m])
    ghost.expects(:newsletter_events_for).returns([])
    ghost.expects(:find_member).never
    ghost.expects(:update_member).never

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_planned]
    assert_equal 0, sync.summary[:granted]
    assert_nil contact.reload.ledger_state("nl-xxix"), "a planned grant writes no granted entry"
  end

  test "a new member is created with its mapped newsletters even when grants are off" do
    enable_sources("index:shopify_customer")
    System.instance.update!(ghost_newsletter_prefix_map: { "index" => "nl-index" },
                            ghost_newsletter_grants_enabled: "0")
    contact = Contact.create!(email: "fresh@example.com", sources: ["index:shopify_customer"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).with { |attrs| attrs[:newsletters] == [{ id: "nl-index" }] }
      .returns(member(id: "m60", email: "fresh@example.com").merge(
        "newsletters" => [{ "id" => "nl-index" }]))

    sync_with(ghost).sync_all!
    assert_equal "granted", contact.reload.ledger_state("nl-index")
  end

  test "a contact with no mapped prefix is created with an explicit empty newsletters array" do
    enable_sources("usb_club:shopify_customer")
    System.instance.update!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "unmapped@example.com", sources: ["usb_club:shopify_customer"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).with { |attrs| attrs.key?(:newsletters) && attrs[:newsletters] == [] }
      .returns(member(id: "m61", email: "unmapped@example.com"))

    sync_with(ghost).sync_all!
  end

  test "granted is written only for newsletters the create response confirms" do
    enable_sources("index:shopify_customer")
    System.instance.update!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    contact = Contact.create!(email: "dropped@example.com", sources: ["index:shopify_customer"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    # Ghost silently drops the newsletter. A granted entry is write-once and would
    # block the legitimate grant forever, with no repair path.
    ghost.expects(:create_member).returns(member(id: "m62", email: "dropped@example.com"))

    sync_with(ghost).sync_all!
    assert_nil contact.reload.ledger_state("nl-index")
  end

  test "two case-fold duplicate contacts produce exactly one create" do
    enable_sources("index:shopify_customer")
    System.instance.update!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "dup@example.com", sources: ["index:shopify_customer"])
    Contact.create!(email: "DUP@example.com", sources: ["index:shopify_customer"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).once.returns(
      member(id: "m63", email: "dup@example.com").merge("newsletters" => [{ "id" => "nl-index" }]))
    ghost.stubs(:newsletter_events_for).returns([])

    sync_with(ghost).sync_all!
  end

  test "a contact left unlinked by a case-fold link conflict never drives a newsletters write" do
    enable_sources("index:shopify_customer")
    System.instance.update!(ghost_newsletter_prefix_map: { "index" => "nl-index" },
                            ghost_newsletter_grants_enabled: "1")
    Contact.create!(email: "owner@example.com", sources: ["index:shopify_customer"], ghost_id: "m64")
    Contact.create!(email: "OWNER@example.com", sources: ["index:shopify_customer"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([
      member(id: "m64", email: "owner@example.com", labels: ["index:shopify_customer"])])
    ghost.stubs(:newsletter_events_for).returns([])
    ghost.stubs(:find_member).returns(
      member(id: "m64", email: "owner@example.com", labels: ["index:shopify_customer"]))
    ghost.expects(:update_member).at_most_once.with { |_id, attrs|
      attrs[:newsletters].nil? || attrs[:newsletters] == [{ id: "nl-index" }] }
      .returns(member(id: "m64", email: "owner@example.com").merge("newsletters" => [{ "id" => "nl-index" }]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_operator sync.summary[:granted], :<=, 1, "the unlinked duplicate must not grant again"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: FAIL on the new grant tests

- [ ] **Step 3: Implement**

Rewrite `sync_contact!`'s member branches. The create branch:

```ruby
      begin
        member = @ghost.create_member(
          { email: contact.email, name: contact.display_name.presence, labels: desired,
            newsletters: create_newsletter_ids(contact, enabled).map { |id| { id: id } } }.compact
        )
        @summary[:created] += 1
        wrote = true
        confirm_granted!(contact, member)
      rescue Stacks::Ghost::RequestError => e
        raise unless e.code == 422
        member = @ghost.find_member_by_email(contact.email)
        raise if member.nil?
        updated = apply_grants_or_labels!(contact, member, desired, enabled)
        if updated
          member = updated
          wrote = true
        end
      end
```

The existing-member branch calls `apply_grants_or_labels!` in place of `update_member_labels`.

At the end of `sync_contact!`, after `link_contact!`, register the member in **both** indexes. In `sync_all!`, replace `members_by_id[updated["id"]] = updated if updated` with:

```ruby
            if updated
              members_by_id[updated["id"]] = updated
              members_by_email[updated["email"].to_s.downcase] = updated
            end
```

Add the private helpers:

```ruby
  # Targets minus anything already in the ledger. A create cannot violate the
  # invariant (no member means no history), so it is NOT gated by the flag: that
  # is what makes the index backfill a single pass.
  def create_newsletter_ids(contact, enabled)
    target_newsletter_ids(contact, enabled) - contact.newsletter_ledger_entries.keys
  end

  # Write granted only for what the response confirms, never for what was sent.
  def confirm_granted!(contact, member)
    (member["newsletters"] || []).map { |n| n["id"] }.compact.each do |id|
      contact.record_ledger_entry!(id, "granted", member_id: member["id"])
      @summary[:granted] += 1
      @summary[:granted_by_newsletter][id] += 1
    end
  end

  # One PUT per contact. When there are candidates we must re-read the member and
  # its history immediately before writing, then recompute the label diff against
  # that fresh member so both ride in a single write.
  def apply_grants_or_labels!(contact, member, desired, enabled)
    candidates = grant_candidates_for(contact, member, enabled)

    if candidates.empty?
      return update_member_labels(contact, member, desired, enabled)
    end

    unless @grants_enabled
      @summary[:grants_planned] += candidates.length
      candidates.each { |id| @summary[:grants_planned_by_newsletter][id] += 1 }
      return update_member_labels(contact, member, desired, enabled)
    end

    fresh = @ghost.find_member(member["id"])
    return update_member_labels(contact, member, desired, enabled) if fresh.nil?

    candidates = grant_candidates_for(contact, fresh, enabled)
    return update_member_labels(contact, fresh, desired, enabled) if candidates.empty?

    current_ids = (fresh["newsletters"] || []).map { |n| n["id"] }.compact
    attrs = label_attrs_for(contact, fresh, desired, enabled) || {}
    attrs[:newsletters] = (current_ids | candidates).map { |id| { id: id } }

    updated = @ghost.update_member(fresh["id"], attrs)
    @summary[:updated] += 1

    confirmed = (updated["newsletters"] || []).map { |n| n["id"] }.compact
    candidates.each do |id|
      next unless confirmed.include?(id)
      contact.record_ledger_entry!(id, "granted", member_id: fresh["id"])
      @summary[:granted] += 1
      @summary[:granted_by_newsletter][id] += 1
    end
    updated
  end
```

In `initialize`, add the nested counters (a bare `Hash.new(0)` cannot lazily nest, it raises `TypeError`):

```ruby
    @summary[:granted_by_newsletter] = Hash.new(0)
    @summary[:grants_planned_by_newsletter] = Hash.new(0)
```

In `link_contact!`, change both `contact.ghost_data` reads so ledger entries written during this sweep survive. Replace `new_data = wrote ? contact.ghost_data.merge(...) : contact.ghost_data` with a merge onto the same in-memory hash the ledger was written to (it already is `contact.ghost_data`), and make the no-op early return also persist a dirty ledger:

```ruby
  def link_contact!(contact, member, wrote = false)
    already_linked = contact.ghost_id == member["id"]
    ledger_dirty = contact.changed.include?("ghost_data")
    return if already_linked && !wrote && !ledger_dirty
```

Finally, skip grants entirely for a contact the sweep could not link: in the `link_conflicts` branch of `link_contact!`, nothing more is needed, but `sync_contact!` must not have granted for it. Guard at the top of `apply_grants_or_labels!`:

```ruby
    if contact.ghost_id.present? && contact.ghost_id != member["id"]
      # This contact resolved to a member another Contact owns (case-fold duplicate).
      # An unlinked duplicate must never change subscriptions for someone else's member.
      @summary[:grants_skipped_unlinked] += 1
      return update_member_labels(contact, member, desired, enabled)
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: all green

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add lib/stacks/ghost_sync.rb test/lib/stacks/ghost_sync_test.rb
git commit -m "feat: apply source-derived newsletter grants and set them on create"
```

---

### Task 9: Per-sweep write budget with a reserved allowance for linked contacts

**Files:**
- Modify: `lib/stacks/ghost_sync.rb`
- Test: `test/lib/stacks/ghost_sync_test.rb`

**Interfaces:**
- Consumes: Task 4's `@writes_remaining`.
- Produces: `reserve_write!` -> Boolean (true when a unit was consumed), counters `writes_used`, `creates_deferred`, `grants_deferred`, `updates_deferred`.

The unit is **one mutation, not one newsletter**. Linked contacts are swept first against a reserved share so the rollout's review gate is not empty for eight sweeps while 19k creates burn the budget.

- [ ] **Step 1: Write the failing tests**

```ruby
  test "the budget caps creates and defers the rest without linking them" do
    enable_sources("index:x")
    System.instance.update!(ghost_newsletter_prefix_map: {}, ghost_sweep_write_budget: 1)
    3.times { |i| Contact.create!(email: "b#{i}@example.com", sources: ["index:x"]) }

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).once.returns(member(id: "mb1", email: "b0@example.com"))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:created]
    assert_equal 2, sync.summary[:creates_deferred]
    assert_equal 2, Contact.where(ghost_id: nil).where("email LIKE 'b%'").count
  end

  test "a deferred contact is created by the next sweep" do
    enable_sources("index:x")
    System.instance.update!(ghost_newsletter_prefix_map: {}, ghost_sweep_write_budget: 1)
    2.times { |i| Contact.create!(email: "c#{i}@example.com", sources: ["index:x"]) }

    ghost = mock("ghost")
    ghost.stubs(:all_members).returns([])   # stubs, not expects: answers twice
    ghost.stubs(:create_member).returns(
      member(id: "mc1", email: "c0@example.com")).then.returns(
      member(id: "mc2", email: "c1@example.com"))

    Stacks::GhostSync.new(ghost).sync_all!
    # The budget lives on the instance, so the second sweep needs a second object.
    second = Stacks::GhostSync.new(ghost)
    second.sync_all!
    assert_equal 1, second.summary[:created]
  end

  test "an exhausted budget skips the history read entirely" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    System.instance.update!(ghost_sweep_write_budget: 0)   # clamps to 1
    Contact.create!(email: "filler@example.com", sources: ["xxix:"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([member(id: "m50", email: "g@example.com")])
    ghost.stubs(:newsletter_events_for).returns([])
    ghost.stubs(:create_member).returns(member(id: "mf", email: "filler@example.com"))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_operator sync.summary[:writes_used], :<=, 1
  end

  test "linked contacts get their reserved allowance even when creates would exhaust it" do
    enable_sources("xxix:")
    System.instance.update!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" },
                            ghost_newsletter_grants_enabled: "0",
                            ghost_sweep_write_budget: 2)
    linked = Contact.create!(email: "linked@example.com", sources: ["xxix:"], ghost_id: "m80")
    5.times { |i| Contact.create!(email: "z#{i}@example.com", sources: ["xxix:"]) }

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([member(id: "m80", email: "linked@example.com")])
    ghost.expects(:newsletter_events_for).with("m80", anything).returns([])
    ghost.stubs(:create_member).returns(member(id: "mz", email: "z0@example.com"))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_planned],
      "the linked contact's decision must run on the first sweep, not after the ramp"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb -n "/budget|deferred|allowance/"`
Expected: FAIL

- [ ] **Step 3: Implement**

Add the reservation helpers:

```ruby
  # One unit per Ghost member mutation, not per newsletter: a contact with two
  # candidates is a single PUT. Deferral is always safe, because it never grants
  # and never writes a ledger entry.
  def writes_available?
    @writes_remaining > 0
  end

  def reserve_write!
    return false unless writes_available?
    @writes_remaining -= 1
    @summary[:writes_used] += 1
    true
  end
```

In `sync_all!`, split the eligible loop so linked contacts run first against a reserved share:

```ruby
      eligible = Contact.where("sources && ARRAY[?]::varchar[]", enabled)
      linked_budget = [@writes_remaining / 2, 1].max

      [[eligible.synced_to_ghost, linked_budget], [eligible.not_synced_to_ghost, nil]].each do |scope, cap|
        spent_before = @summary[:writes_used]
        scope.find_each do |contact|
          break if cap && (@summary[:writes_used] - spent_before) >= cap
          capture_errors(contact) do
            next skip_invalid(contact) unless contact.email.match?(Devise.email_regexp)
            updated = sync_contact!(contact, enabled, members_by_id, members_by_email)
            if updated
              members_by_id[updated["id"]] = updated
              members_by_email[updated["email"].to_s.downcase] = updated
            end
          end
        end
      end
```

Gate the create in `sync_contact!`:

```ruby
      unless reserve_write!
        @summary[:creates_deferred] += 1
        return nil
      end
```

Gate the budget reservation in `grant_candidates_for`, as decision step 4, placed **before** the history read (so a deferred member costs no API calls):

```ruby
      unless writes_available?
        @summary[:grants_deferred] += 1
        return candidates
      end
```

Gate the label-only write in `update_member_labels`:

```ruby
    return nil if attrs.nil?
    unless reserve_write!
      @summary[:updates_deferred] += 1
      return nil
    end
```

and in `delabel_member!` likewise, returning `member` when deferred.

In `apply_grants_or_labels!`, consume the unit immediately before the grant PUT:

```ruby
    return update_member_labels(contact, fresh, desired, enabled) unless reserve_write!
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: all green

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add lib/stacks/ghost_sync.rb test/lib/stacks/ghost_sync_test.rb
git commit -m "feat: per-sweep Ghost write budget with reserved allowance for linked contacts"
```

---

### Task 10: Incremental summary persistence

**Files:**
- Modify: `lib/stacks/ghost_sync.rb`
- Test: `test/lib/stacks/ghost_sync_test.rb`

**Interfaces:**
- Produces: `System#ghost_last_sync_summary` populated with stringified counters plus `finished_at`, written periodically and in an `ensure`.

The admin button runs the sweep inline against `rack-timeout` (15s) and puma's `worker_timeout 60`. A killed sweep must still leave the counters the rollout's review gate reads.

- [ ] **Step 1: Write the failing tests**

```ruby
  test "the sweep persists its summary with a finished_at" do
    enable_sources("newsletter")
    Contact.create!(email: "sum@example.com", sources: ["newsletter"])
    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).returns(member(id: "ms1", email: "sum@example.com"))

    sync_with(ghost).sync_all!
    stored = System.first.reload.ghost_last_sync_summary
    assert_equal 1, stored["created"]
    assert stored["finished_at"].present?
  end

  test "an aborted sweep still persists its counters" do
    enable_sources("newsletter")
    Contact.create!(email: "boom@example.com", sources: ["newsletter"])
    ghost = mock("ghost")
    ghost.expects(:all_members).raises(RuntimeError, "ghost is down")

    assert_raises(RuntimeError) { sync_with(ghost).sync_all! }
    assert System.first.reload.ghost_last_sync_summary["finished_at"].present?,
      "the rollout's review gate reads this panel; a killed sweep must not leave it empty"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb -n "/summary/"`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
  # @summary has symbol keys and a default proc; the column is jsonb.
  def persist_summary!
    payload = @summary.to_h.each_with_object({}) do |(k, v), acc|
      acc[k.to_s] = v.is_a?(Hash) ? v.to_h.transform_keys(&:to_s) : v
    end
    payload["finished_at"] = Time.current.iso8601
    System.first_or_create!(settings: {}).update!(ghost_last_sync_summary: payload)
  rescue => e
    Rails.logger.error("[GhostSync] could not persist summary: #{e.class}: #{e.message}")
  end
```

Wrap the body of `sync_all!` in `begin ... ensure persist_summary! end`, and call `persist_summary!` every 250 contacts inside the eligible loop.

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: all green

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add lib/stacks/ghost_sync.rb test/lib/stacks/ghost_sync_test.rb
git commit -m "feat: persist Ghost sweep summary incrementally"
```

---

### Task 11: Advisory lock around the dedupe! loop

**Files:**
- Modify: `lib/tasks/stacks.rake:416-419`

**Interfaces:**
- Consumes: `Stacks::GhostSync::ADVISORY_LOCK_KEY`.

`dedupe!` row-locks duplicates and then `delete_all`s them. A concurrent ledger write from a multi-hour Ghost sweep lands on a deleted row, affects zero rows, and raises nothing. Unioning ledgers on merge does not fix a lost update.

- [ ] **Step 1: Implement**

Replace `Contact.all.each(&:dedupe!)` with:

```ruby
      # Serialise against the Ghost sweep: dedupe! deletes contact rows, and a
      # concurrent ledger write from the sweep would silently affect zero rows.
      # A lost ledger entry can re-subscribe someone who unsubscribed.
      conn = ActiveRecord::Base.connection
      conn.select_value("SELECT pg_advisory_lock(#{Stacks::GhostSync::ADVISORY_LOCK_KEY})")
      begin
        Contact.all.each(&:dedupe!)
      ensure
        conn.execute("SELECT pg_advisory_unlock(#{Stacks::GhostSync::ADVISORY_LOCK_KEY})")
      end
```

- [ ] **Step 2: Verify the task still loads**

Run: `RAILS_ENV=test bundle exec rails -T 2>/dev/null | grep sync_contacts`
Expected: the task is listed, no load error

- [ ] **Step 3: Commit**

```bash
git branch --show-current
git add lib/tasks/stacks.rake
git commit -m "fix: serialise contact dedupe against the Ghost sweep"
```

---

### Task 12: Admin UI

**Files:**
- Modify: `app/admin/ghost_sync.rb`, `app/admin/contacts.rb:74-81`

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces: one new `page_action :update_newsletter_settings, method: :post`.

Copy must not use em dashes.

- [ ] **Step 1: Implement the mapping panel and page_action**

In `app/admin/ghost_sync.rb`, read settings from a fresh `System.first_or_create!(settings: {})`, **never** `System.instance` (it memoizes per puma worker and never invalidates). Add, after the Synced Sources panel:

```ruby
    system = System.first_or_create!(settings: {})
    newsletters = begin
      Stacks::Ghost.new(max_retries: 1).all_newsletters.select { |n| n["status"] != "archived" }
    rescue => e
      []
    end
    map = system.ghost_newsletter_prefix_map_clean

    prefixes = Contact.connection.select_rows(<<~SQL).to_h
      SELECT src_prefix, COUNT(*) FROM (
        SELECT DISTINCT contacts.id, split_part(lower(s.source), ':', 1) AS src_prefix
        FROM contacts, LATERAL unnest(sources) AS s(source)
        WHERE lower(s.source) <> 'g3d:ghost' AND lower(s.source) NOT LIKE 'g3d:ghost:%'
      ) t GROUP BY src_prefix ORDER BY COUNT(*) DESC
    SQL

    panel "Newsletter Mapping" do
      para "Each source prefix maps to one Ghost newsletter. Contacts with a source " \
           "under that prefix are subscribed to it once, and never re-subscribed if " \
           "they later unsubscribe. Do not map etl: it records Google Meet attendance, " \
           "not consent."
      form action: admin_ghost_sync_update_newsletter_settings_path, method: :post do
        input type: :hidden, name: :authenticity_token, value: form_authenticity_token
        table_for prefixes.to_a do
          column("Prefix") { |(prefix, _)| prefix }
          column("Contacts") { |(_, count)| count }
          column("Newsletter") do |(prefix, _)|
            select name: "prefix_map[#{prefix}]" do
              option "Not mapped", value: ""
              newsletters.map do |n|
                option n["name"], value: n["id"], selected: (map[prefix] == n["id"]) || nil
              end
            end
          end
          column("May subscribe") do |(prefix, _)|
            id = map[prefix]
            next "" if id.blank?
            Contact
              .where("sources && ARRAY[?]::varchar[]", system.ghost_synced_sources)
              .where("EXISTS (SELECT 1 FROM unnest(sources) s WHERE lower(s) LIKE ? AND lower(s) <> 'g3d:ghost' AND lower(s) NOT LIKE 'g3d:ghost:%')", "#{prefix}:%")
              .where("NOT jsonb_exists(COALESCE(ghost_data->'newsletter_ledger'->'entries', '{}'::jsonb), ?)", id)
              .count
          end
        end

        div style: "margin-top: 12px" do
          input type: :hidden, name: "grants_enabled", value: "0"
          input type: :checkbox, name: "grants_enabled", value: "1",
            checked: system.ghost_newsletter_grants_enabled? || nil
          span "Apply grants to existing members. Leave off for a dry run."
        end
        div style: "margin-top: 8px" do
          span "Writes per sweep: "
          input type: :number, name: "write_budget", min: 1,
            value: system.ghost_sweep_write_budget_clamped
        end
        div style: "margin-top: 12px" do
          input type: :submit, value: "Save Newsletter Settings"
        end
      end
    end

    panel "Last Sweep Summary" do
      summary = system.ghost_last_sync_summary
      if summary.blank?
        para "No sweep has recorded a summary yet."
      else
        table_for summary.to_a do
          column("Counter") { |(k, _)| k }
          column("Value") { |(_, v)| v.is_a?(Hash) ? v.inspect : v }
        end
      end
    end
```

The hidden `grants_enabled` input **must** be `value: "0"`. A blank value stores `""`, which reads truthy through the plain Storext reader.

Add the page_action:

```ruby
  page_action :update_newsletter_settings, method: :post do
    map = params.fetch(:prefix_map, {}).permit!.to_h
      .transform_keys { |k| k.to_s.downcase }
      .transform_values(&:to_s)
      .reject { |_, v| v.blank? }

    System.first_or_create!(settings: {}).update!(
      ghost_newsletter_prefix_map: map,
      ghost_newsletter_grants_enabled: ActiveModel::Type::Boolean.new.cast(params[:grants_enabled]) || false,
      ghost_sweep_write_budget: [params[:write_budget].presence.to_i, 1].max,
    )
    redirect_to admin_ghost_sync_path, notice: "Newsletter settings updated (#{map.length} prefixes mapped)"
  end
```

Assigning `ActionController::Parameters` straight to a Storext Hash raises `UnfilteredParameters`, hence `.permit!.to_h`.

Also add a Newsletter column to the existing Synced Sources table:

```ruby
          column("Newsletter") do |(source, _count)|
            id = map[source.to_s.split(":", 2).first.to_s.downcase]
            id.present? ? (newsletters.find { |n| n["id"] == id }&.dig("name") || id)
                        : "No newsletter (members created with no subscription)"
          end
```

- [ ] **Step 2: Add ledger rows to the contact show page**

In `app/admin/contacts.rb`, after the "Last Synced" row:

```ruby
        row("Newsletter Ledger") do
          entries = resource.newsletter_ledger_entries
          if entries.blank?
            "None"
          else
            entries.map { |id, e| "#{id}: #{e["state"]} (#{e["at"]})" }.join(", ")
          end
        end
```

- [ ] **Step 3: Verify the pages render**

Run: `RAILS_ENV=test bundle exec rails test test/models test/lib/stacks 2>&1 | tail -5`
Expected: green. Then confirm the admin files parse: `bundle exec ruby -c app/admin/ghost_sync.rb && bundle exec ruby -c app/admin/contacts.rb`

- [ ] **Step 4: Commit**

```bash
git branch --show-current
git add app/admin/ghost_sync.rb app/admin/contacts.rb
git commit -m "feat: newsletter mapping, grants toggle and sweep summary in admin"
```

---

### Task 13: Update the 2026-07-20 design doc

**Files:**
- Modify: `docs/superpowers/specs/2026-07-20-ghost-contact-sync-design.md`

- [ ] **Step 1: Correct the ownership table and the stale dyno claim**

Change the opt-in ownership row to: "Stacks grants a newsletter once per member, derived from sources; Ghost is authoritative for revocation; stacks never unsubscribes or re-subscribes."

Correct the claim that the sweep "always runs in fresh rake dynos and always reads current state": the admin Sync Now button runs it inline in a web dyno (`app/admin/ghost_sync.rb`), which is why the new settings must be read from a fresh `System.first_or_create!` rather than the memoized `System.instance`.

Add a pointer to `docs/superpowers/specs/2026-09-16-ghost-source-newsletter-subscriptions-design.md`.

- [ ] **Step 2: Commit**

```bash
git branch --show-current
git add docs/superpowers/specs/2026-07-20-ghost-contact-sync-design.md
git commit -m "docs: point the Ghost sync design at the subscriptions amendment"
```

---

## Final verification

- [ ] Run the full touched-area suite:

```bash
RAILS_ENV=test bundle exec rails test test/models/contact_test.rb test/models/system_test.rb \
  test/lib/stacks/ghost_test.rb test/lib/stacks/ghost_sync_test.rb
```

Expected: 0 failures, 0 errors.

- [ ] Run the broader suite, excluding the two known-flaky files (`EtlRakeTest`'s `sync_meet` test makes a live Google call and can hang for ~73 minutes; `AdminUserTest`'s salary-window test fails between 20:00 and 24:00 ET):

```bash
RAILS_ENV=test bundle exec rails test test/models test/lib 2>&1 | tail -20
```

- [ ] Confirm no `newsletters` key is ever sent by a label-only path: `grep -n "newsletters" lib/stacks/ghost_sync.rb` and check each hit against the spec's "Never, in any path" list.
- [ ] Confirm the branch: `git branch --show-current` prints `feat/ghost-source-newsletter-subscriptions`.
