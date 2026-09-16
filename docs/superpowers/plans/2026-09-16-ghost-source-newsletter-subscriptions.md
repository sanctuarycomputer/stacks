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

## Test harness preamble (read before writing any test)

Three facts about this suite will silently break tests that look correct. Verified in this worktree.

**1. Never use `System.instance` in a test.** It memoizes in a class variable that is never
invalidated and therefore **survives the per-test transaction rollback**. The first test in the
process to touch it caches a `System` whose row is then rolled back; every later test gets that dead
object back, and `System.instance.update!(...)` issues an `UPDATE ... WHERE id = <dead id>` that
affects **zero rows and raises nothing**. Measured: `instance.id=18`, real row `id=19`, and the
update persisted nothing. Meanwhile `enable_sources` and the sweep both read the real row, so the
test silently exercises the wrong configuration. Tests are order-randomized, so this fails
nondeterministically.

Add these helpers to `test/lib/stacks/ghost_sync_test.rb` next to `enable_sources`, and use them in
**every** new test in this plan:

```ruby
  # Always hit the real row. System.instance memoizes across the test transaction.
  def sys!(attrs)
    System.first_or_create!(settings: {}).tap { |s| s.update!(attrs) }
  end

  def enabled_sources
    System.first_or_create!(settings: {}).ghost_synced_sources
  end

  def active_nl(*ids)
    ids.map { |i| { "id" => i, "name" => i, "slug" => i, "status" => "active" } }
  end
```

The only permitted use of `System.instance` is the Task 4 test that deliberately probes the memo,
which must reset it in an `ensure`: `System.class_variable_set(:@@instance, nil)`.

**2. `Mocha::ExpectationError` descends from `Exception`, not `StandardError`.** Verified:
`Mocha::ExpectationError.superclass == Exception`. So `capture_errors`'s `rescue => e`
(`ghost_sync.rb:266-270`) does **not** swallow it. An unexpected or unstubbed call does not become a
counted per-contact error: it aborts `sync_all!` entirely, which means `link_contact!` never runs and
no ledger entry is persisted. A test that fails this way often fails on a *later* assertion about
ledger state, which misdirects debugging. When you add a call to a code path, stub it in every
existing test that reaches that path.

**3. The label path fires more often than you expect.** `desired` is the contact's enabled sources
verbatim, and the `member(...)` fixture helper defaults to `labels: []`. So any test whose contact has
an enabled source and whose fixture member has no labels **will** issue a label `update_member`, even
when the test is about newsletters. If a test asserts `expects(:update_member).never`, give the
fixture member the matching label (e.g. `labels: ["xxix:"]`) so the label path is genuinely a no-op.

Existing test counts for reference: `ghost_sync_test.rb` has **28** tests, `ghost_test.rb` has **6**.

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

### Task 0: Raise the blocking layer-3 verification with Hugh

**Files:** none (a gate, not code).

The spec marks one assumption **blocking**: that unsubscribing writes a readable `newsletter_event`.
Probing the live instance found 52 members, 148 events, **all** `subscribed: true` - nobody has ever
unsubscribed, so there is no evidence either way, and it cannot be obtained read-only.

- [ ] **Step 1: Surface it, do not silently proceed**

Report to Hugh, before Task 7 merges: confirming this needs a disposable test member unsubscribed via
(a) an emailed unsubscribe link, (b) RFC 8058 one-click, and (c) the Ghost Admin UI, checking each
writes `data.subscribed: false` with the right `data.newsletter_id`. That is a **write to production
Ghost**, so it is Hugh's call, not the implementer's.

Do **not** block the other tasks on this. The residual risk is bounded: the always-on observation leg
(Task 5) writes an `observed` entry for every currently subscribed newsletter every sweep, so anyone
unsubscribing after this ships is blocked by layer 2 even if layer 3 were blind. The exposure is only
people who unsubscribed *before* shipping, and that set is currently empty.

- [ ] **Step 2: Record the answer**

If the check is run, save each response as a fixture under `test/fixtures/files/` and note the outcome
in the spec's "Blocking pre-implementation verification" section.

---

### Task 1: System settings with trap-absorbing accessors

**Files:**
- Modify: `app/models/system.rb:7-12`
- Test: `test/models/system_test.rb` (create)

**Interfaces:**
- Produces: `System#ghost_newsletter_prefix_map` (Hash), `System#ghost_newsletter_grants_enabled?` (Boolean predicate), `System#ghost_sweep_write_budget` (Integer), `System#ghost_last_sync_summary` (Hash), plus `System#ghost_sweep_write_budget_clamped` and `System#ghost_newsletter_prefix_map_clean`.

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

  test "prefix map rejects blank values and downcases keys" do
    # source_prefix always yields a lowercase key, so a map key saved as "Index" by
    # any path other than the admin form would silently never match.
    sys.update!(ghost_newsletter_prefix_map: { "Index" => "nl-1", "xxix" => "" })
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
    ghost_newsletter_prefix_map.to_h
      .transform_keys { |k| k.to_s.downcase }
      .reject { |_, v| v.to_s.blank? }
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

> **This task was implemented once and sent back by review.** Commit `5ae3789a` is on the branch and
> contains a version with a paging loop. This revision REPLACES that implementation. The paging loop
> must be deleted, not extended: a later probe found `order` is silently ignored, so it was built on an
> assumption the API does not honour.

**Files:**
- Modify: `lib/stacks/ghost.rb`
- Test: `test/lib/stacks/ghost_test.rb`

**Interfaces:**
- Produces: `Stacks::Ghost#find_member(id)` -> member Hash or nil. `Stacks::Ghost#newsletter_events_for(member_id, current_newsletter_ids:)` -> Array of raw event Hashes, or **raises** `Stacks::Ghost::UntrustworthyHistory`. The keyword argument is **required**.

**Why this is the highest-risk task.** The endpoint returns `200 {"events": []}` for a nonexistent
*and* for a malformed member id. A naive reading is "never subscribed", which grants, which mails
someone who deliberately opted out.

Verified endpoint facts (live, 2026-09-16 - do not re-derive, do not assume otherwise):
- `data.subscribed` and `data.newsletter_id` are NOT filterable (400 each). Fetch and inspect in Ruby.
- Quotes in a filter must be RAW `'`. A pre-encoded `%27` yields 422.
- `limit` caps at 100. `limit: "all"` is coerced to 100, unlike `/newsletters/`.
- **`page` is silently ignored**, unlike `/members/`.
- **`order` is silently ignored too** - `created_at desc`, `created_at asc`, and `garbage nonsense` all
  return 200 with identical ordering.
- `meta.pagination.total` is reliable.
- Use the scalar `data["newsletter_id"]`, not `data["newsletter"]["id"]`.

**Because both `page` and `order` are ignored, this endpoint cannot be walked.** Issue exactly one
request and fail closed when there is more than one page's worth. A member with >100 newsletter events
becomes unprocessable until handled by hand; that takes 100+ subscribe/unsubscribe toggles, today's
live maximum is 3, and it is counted in `grant_errors`. Guessing an order risks collecting the wrong
100 events and reading "no event for N" for someone who unsubscribed.

- [ ] **Step 1: Rewrite the tests**

Replace the `newsletter_events_for` tests added in `5ae3789a`. Keep `find_member`'s test and the
`nl_event` / `events_response` helpers, moving the helpers up next to `build_client` and
`fake_response` (around line 24) rather than leaving them mid-class.

```ruby
  MEMBER_ID = "6aaa0647345d7200012fc658".freeze

  def nl_event(member_id: MEMBER_ID, newsletter_id: "nl-1", subscribed: true,
               created_at: "2026-09-16T03:00:23.000Z", type: "newsletter_event")
    { "type" => type,
      "data" => { "id" => "ev-1", "member_id" => member_id, "subscribed" => subscribed,
                  "created_at" => created_at, "source" => "api", "newsletter_id" => newsletter_id } }
  end

  def events_response(events, total: nil, meta: :default)
    body = { events: events }
    unless meta == :omit
      body[:meta] = { pagination: { limit: 100, total: total || events.length, pages: 1 } }
    end
    fake_response(code: 200, body: body)
  end

  test "newsletter_events_for issues ONE request, filtered by type and member only" do
    client = build_client
    Stacks::Ghost.expects(:get).once.with { |url, opts|
      url.include?("/members/events/") &&
        opts[:query][:filter].include?("type:newsletter_event") &&
        opts[:query][:filter].include?(MEMBER_ID) &&
        !opts[:query][:filter].include?("data.subscribed") &&   # verified 400
        !opts[:query][:filter].include?("data.newsletter_id") && # verified 400
        !opts[:query][:filter].include?("%27") &&                # verified 422
        !opts[:query].key?(:page) &&                             # verified ignored
        !opts[:query].key?(:order) &&                            # verified ignored
        opts[:query][:limit] == 100
    }.returns(events_response([nl_event]))

    events = client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    assert_equal 1, events.length
    assert_equal "nl-1", events.first["data"]["newsletter_id"]
  end

  test "newsletter_events_for rejects a malformed member id without issuing a request" do
    client = build_client
    Stacks::Ghost.expects(:get).never
    ["not-an-id", "", nil, :"6aaa0647345d7200012fc658",
     "6AAA0647345D7200012FC658", "6aaa0647345d7200012fc65"].each do |bad|
      assert_raises(Stacks::Ghost::UntrustworthyHistory, "accepted #{bad.inspect}") do
        client.newsletter_events_for(bad, current_newsletter_ids: [])
      end
    end
  end

  test "newsletter_events_for rejects a non-Array current_newsletter_ids" do
    # nil would otherwise reach `.empty?` and NoMethodError, aborting the sweep rather
    # than skipping one member.
    client = build_client
    Stacks::Ghost.expects(:get).never
    [nil, "nl-1", { "nl-1" => true }].each do |bad|
      assert_raises(Stacks::Ghost::UntrustworthyHistory, "accepted #{bad.inspect}") do
        client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: bad)
      end
    end
  end

  test "newsletter_events_for raises when an event has no newsletter_id" do
    # Every other guard passes here. Without this one the consumer reads "no event for
    # newsletter N" and grants someone who actually unsubscribed.
    client = build_client
    [nil, "", 12345].each do |bad_id|
      ev = nl_event
      ev["data"]["newsletter_id"] = bad_id
      Stacks::Ghost.stubs(:get).returns(events_response([ev], total: 1))
      err = assert_raises(Stacks::Ghost::UntrustworthyHistory, "accepted #{bad_id.inspect}") do
        client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
      end
      assert_match(/no newsletter_id/, err.message)
    end
  end

  test "newsletter_events_for returns a complete history at the 100 event boundary" do
    # limit caps at 100, so 100-of-100 is complete and must be ACCEPTED. Pins the
    # boundary so a future tightening to >= cannot silently change behaviour.
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response(Array.new(100) { nl_event }, total: 100))
    assert_equal 100, client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"]).length
  end

  test "newsletter_events_for raises when an event belongs to a different member" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event(member_id: "someone-else")]))
    err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
    assert_match(/someone-else/, err.message)
  end

  test "newsletter_events_for raises on an event of the wrong type" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event(type: "email_delivered_event")]))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
  end

  test "newsletter_events_for raises when the member has more events than one page can carry" do
    # page and order are both silently ignored, so a second page cannot be fetched
    # reliably. Fail closed rather than return a truncated history.
    client = build_client
    Stacks::Ghost.expects(:get).once.returns(events_response(Array.new(100) { nl_event }, total: 150))
    err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
    assert_match(/100 of 150/, err.message)
  end

  test "newsletter_events_for raises when the collected count exceeds total" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event, nl_event], total: 1))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
  end

  test "newsletter_events_for raises when meta.pagination.total is absent or not an Integer" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([], meta: :omit))
    err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
    assert_match(/meta\.pagination\.total/, err.message)

    # A Float total is what makes the Integer check load-bearing: 1 == 1.0 in Ruby, so
    # without it this response passes the completeness check and is accepted.
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event], total: 1.0))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
  end

  test "newsletter_events_for raises when meta itself is a scalar" do
    # body.dig would raise TypeError here, escaping the fail-closed error class.
    client = build_client
    [{ events: [], meta: "nope" }, { events: [], meta: [] }].each do |body|
      Stacks::Ghost.stubs(:get).returns(fake_response(code: 200, body: body))
      assert_raises(Stacks::Ghost::UntrustworthyHistory) do
        client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
      end
    end
  end

  test "newsletter_events_for raises when the response body is not an object at all" do
    client = build_client
    resp = mock("response")
    resp.stubs(:success?).returns(true)
    resp.stubs(:code).returns(200)
    resp.stubs(:body).returns("<html>gateway error</html>")
    # An Array body is the case that matters: without the is_a?(Hash) guard, []["events"]
    # raises TypeError and escapes the fail-closed error class. A String body would be
    # caught by the events-Array guard anyway, so assert the message to tell them apart.
    [["<html>gateway error</html>", /non-object events response/],
     [[{ "events" => [] }], /non-object events response/]].each do |parsed, pattern|
      resp.stubs(:parsed_response).returns(parsed)
      Stacks::Ghost.stubs(:get).returns(resp)
      err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
        client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
      end
      assert_match(pattern, err.message)
    end
  end

  test "newsletter_events_for raises on an empty history for a member with live subscriptions" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    # never: the coherence guard must fire on its own, not fall through to the probe.
    client.expects(:find_member).never
    err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
    assert_match(/subscribed to 1 newsletter/, err.message)
  end

  test "coherence is tested by emptiness, not truthiness" do
    # [nil].any? is false but [nil].empty? is false too. Using .any? here would skip the
    # coherence guard and fall through to the weaker existence probe.
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    client.expects(:find_member).never
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [nil])
    end
  end

  test "an empty history fails closed when the existence probe 404s" do
    # Verified live: GET /members/<unknown>/ answers 404, so find_member RAISES rather
    # than returning nil. This is the realistic shape of the case the probe exists for.
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    client.expects(:find_member).with(MEMBER_ID)
      .raises(Stacks::Ghost::RequestError.new(404, "not found"))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
  end

  test "an empty history fails closed when the probe returns a different member" do
    # This is the ONLY exit that lets a caller conclude "never subscribed" and grant,
    # so bare truthiness is not enough.
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    [{}, { "id" => "someotheridsomeotherid00" }].each do |probed|
      client.stubs(:find_member).with(MEMBER_ID).returns(probed)
      assert_raises(Stacks::Ghost::UntrustworthyHistory) do
        client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
      end
    end
  end

  test "an empty history is confirmed against the member actually existing" do
    # The coherence guard above is inert when current_newsletter_ids is empty, which is
    # exactly the case for someone who unsubscribed from everything: the population this
    # feature exists to protect. Their empty history is indistinguishable from a
    # nonexistent or mistyped id, which returns the same 200 {"events": []}.
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    client.expects(:find_member).with(MEMBER_ID).returns(nil)
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
  end

  test "a genuinely empty history for a confirmed member is allowed" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    client.expects(:find_member).with(MEMBER_ID).returns({ "id" => MEMBER_ID, "newsletters" => [] })
    assert_equal [], client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
  end

  test "newsletter_events_for raises rather than NoMethodError on malformed events" do
    # One malformed member must not take down the whole sweep. Each case carries a VALID
    # meta.pagination.total so it reaches the per-event shape guards instead of being
    # short-circuited by the total check.
    client = build_client
    Stacks::Ghost.stubs(:get).returns(fake_response(code: 200, body: { events: "not-an-array",
      meta: { pagination: { limit: 100, total: 0, pages: 1 } } }))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end

    # Assert the MESSAGE, not just the class. Without it these cases fall through to the
    # type and provenance guards below (a String's ["type"] is a substring miss, so nil),
    # which raise the same class and leave the shape guard deletable with the suite green.
    # The Integer and Array-data shapes are the ones only the shape guard catches: they
    # TypeError otherwise.
    [events_response(["not-a-hash"], total: 1),
     events_response([5], total: 1),
     events_response([{ "type" => "newsletter_event", "data" => "scalar" }], total: 1),
     events_response([{ "type" => "newsletter_event", "data" => [] }], total: 1)].each do |resp|
      Stacks::Ghost.stubs(:get).returns(resp)
      err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
        client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
      end
      assert_match(/malformed event entry/, err.message)
    end
  end

  test "find_member requests one member with labels and newsletters" do
    client = build_client
    Stacks::Ghost.expects(:get).with { |url, opts|
      url.include?("/members/m1/") && opts[:query][:include] == "labels,newsletters"
    }.returns(fake_response(code: 200, body: { members: [{ id: "m1", email: "a@x.com" }] }))
    assert_equal "m1", client.find_member("m1")["id"]
  end
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_test.rb`
Expected: failures on the new guards (total-absent, wrong-type, existence probe, malformed body,
required kwarg), since `5ae3789a`'s implementation does not have them.

- [ ] **Step 3: Replace the implementation**

Delete `EVENTS_MAX_PAGES` and the whole paging loop. Keep `UntrustworthyHistory`,
`MEMBER_ID_FORMAT`, `EVENTS_PAGE_LIMIT` and `find_member` as they are.

```ruby
  # Returns every newsletter_event for a member, or raises UntrustworthyHistory.
  #
  # This endpoint returns 200 with an empty list for a nonexistent OR malformed member
  # id, so "no events" is not evidence of "never subscribed" unless every guard below
  # passes. Callers MUST treat the raise as fail-closed: no grants for this member.
  #
  # Deliberately does not page. Both `page` and `order` are silently ignored here
  # (verified live), so there is no reliable way to walk past the first 100 events and
  # no way to know which 100 we got. A member with more than 100 newsletter events fails
  # closed instead, which takes 100+ subscribe/unsubscribe toggles to reach.
  #
  # current_newsletter_ids has no default on purpose: the coherence guard is inert for
  # an empty list, and that is exactly the population at risk.
  def newsletter_events_for(member_id, current_newsletter_ids:)
    # is_a?(String), not to_s: a Symbol whose to_s is valid hex would otherwise pass the
    # format check and then fail provenance with a misleading message. This guard's whole
    # job is refusing ambiguous input, so reject non-Strings outright.
    unless member_id.is_a?(String) && member_id.match?(MEMBER_ID_FORMAT)
      raise UntrustworthyHistory, "refusing to query events for malformed member id #{member_id.inspect}"
    end
    unless current_newsletter_ids.is_a?(Array)
      raise UntrustworthyHistory, "current_newsletter_ids must be an Array, got #{current_newsletter_ids.class}"
    end

    # Quotes must be RAW: HTTParty encodes the query itself, so a pre-encoded %27
    # arrives as %2527 and 422s. Safe from injection because the guard above restricts
    # member_id to hex.
    response = handle_response {
      self.class.get(url("/members/events/"), query: {
        filter: "type:newsletter_event+data.member_id:'#{member_id}'",
        limit: EVENTS_PAGE_LIMIT,
      }, headers: headers)
    }

    body = response.parsed_response
    raise UntrustworthyHistory, "non-object events response for member #{member_id}" unless body.is_a?(Hash)

    events = body["events"]
    raise UntrustworthyHistory, "events was #{events.class} for member #{member_id}" unless events.is_a?(Array)

    # Not body.dig: a scalar or Array "meta" makes dig raise TypeError, which escapes the
    # error class this whole design rests on and would abort the sweep instead of
    # skipping one member.
    meta = body["meta"]
    pagination = meta.is_a?(Hash) ? meta["pagination"] : nil
    total = pagination.is_a?(Hash) ? pagination["total"] : nil
    # Must be an Integer specifically: 1 == 1.0 in Ruby, so a Float total would sail
    # through the completeness check below.
    unless total.is_a?(Integer)
      raise UntrustworthyHistory, "missing or non-integer meta.pagination.total for member #{member_id}"
    end

    events.each do |event|
      unless event.is_a?(Hash) && event["data"].is_a?(Hash)
        raise UntrustworthyHistory, "malformed event entry for member #{member_id}"
      end
      unless event["type"] == "newsletter_event"
        raise UntrustworthyHistory, "unexpected event type #{event["type"].inspect} for member #{member_id}"
      end
      actual = event["data"]["member_id"]
      unless actual == member_id
        raise UntrustworthyHistory, "event for member #{actual.inspect} returned when querying #{member_id}"
      end
      # An event with no newsletter_id is worse than useless: the consumer asks
      # `events.any? { |e| e.dig("data","newsletter_id") == n }`, so a dropped or renamed
      # field turns a real unsubscribe into "never subscribed" and grants. That is the
      # exact failure this method exists to prevent, so refuse the whole history.
      unless event["data"]["newsletter_id"].is_a?(String) && !event["data"]["newsletter_id"].empty?
        raise UntrustworthyHistory, "event #{event["data"]["id"].inspect} has no newsletter_id for member #{member_id}"
      end
    end

    unless events.length == total
      raise UntrustworthyHistory, "collected #{events.length} of #{total} events for member #{member_id}"
    end

    if events.empty?
      unless current_newsletter_ids.empty?
        raise UntrustworthyHistory,
          "member #{member_id} is subscribed to #{current_newsletter_ids.length} newsletter(s) but has no events"
      end
      # Nothing above distinguishes "genuinely never subscribed" from "this id does not
      # exist": both return 200 with an empty list. Confirm positively. Verified live:
      # GET /members/<unknown>/ answers 404, so this RAISES rather than returning nil,
      # and the probe must convert that into the fail-closed error class.
      probed = begin
        find_member(member_id)
      rescue RequestError => e
        raise UntrustworthyHistory, "could not confirm member #{member_id} exists (Ghost #{e.code})"
      end
      # Bare truthiness is not enough: this is the ONLY exit that lets a caller conclude
      # "never subscribed" and grant, so it gets the same provenance check as everything
      # else. An {} or a member with a different id must not satisfy it.
      unless probed.is_a?(Hash) && probed["id"] == member_id
        raise UntrustworthyHistory, "no events and no confirmed member #{member_id}"
      end
    end

    events
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_test.rb`
Expected: all green, including the 6 pre-existing client tests.

- [ ] **Step 5: Commit**

```bash
git branch --show-current
git add lib/stacks/ghost.rb test/lib/stacks/ghost_test.rb
git commit -m "fix: do not page Ghost member events; order and page are both ignored"
```

---

### Task 3: Contact ledger helpers and merge unioning

**Files:**
- Modify: `app/models/contact.rb` (add helpers; extend `dedupe!` around `:181-191` and the `fresh_existing` merge around `:90-104`)
- Test: `test/models/contact_test.rb`

**Interfaces:**
- Produces: `Contact#newsletter_ledger` -> Hash, `Contact#newsletter_ledger_entries` -> Hash, `Contact#ledger_member_id` -> String or nil, `Contact#ledger_entry(newsletter_id)` -> Hash or nil, `Contact#ledger_has?(newsletter_id)` -> Boolean, `Contact#ledger_state(newsletter_id)` -> String or nil, `Contact#record_ledger_entry!(newsletter_id, state, member_id:)` (in-memory only, does NOT save), and `Contact.merge_newsletter_ledgers(ledgers)` -> Hash.
- Consumes: nothing.

Ledger shape: `ghost_data["newsletter_ledger"] = { "member_id" => "<id>", "entries" => { "<nl id>" => { "state" => ..., "at" => iso8601 } } }`.

- [ ] **Step 1: Write the failing tests**

`test/models/contact_test.rb` holds seven separate test classes, so appending past the final `end` would define tests at top level (`NoMethodError: undefined method 'test' for main`). Put the three ledger-helper tests in a **new** `class ContactNewsletterLedgerTest < ActiveSupport::TestCase` at the end of the file, and the two `dedupe!` tests **inside the existing `ContactDedupeGhostTest`** (line 135):

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

    # Both orders, otherwise a naive "last one processed wins" implementation produces
    # exactly these values for [late, early] and the test proves nothing.
    reversed = Contact.merge_newsletter_ledgers([early, late])
    assert_equal "history", reversed["entries"]["nl-1"]["state"], "earliest wins in either input order"
    assert_equal "2026-01-01T00:00:00Z", reversed["entries"]["nl-1"]["at"]
  end

  test "record_ledger_entry! with a nil member_id does not create the key" do
    # ||= would set member_id to nil, which makes the ledger differ from the stored one
    # and writes a nil member_id on the next save.
    c = Contact.create!(email: "nilmem@example.com")
    c.record_ledger_entry!("nl-1", "observed", member_id: nil)
    refute c.newsletter_ledger.key?("member_id")
    assert c.ledger_has?("nl-1")
  end

  test "an entry with a blank at does not displace a well-formed one" do
    good = { "entries" => { "nl-1" => { "state" => "history", "at" => "2026-01-01T00:00:00Z" } } }
    blank = { "entries" => { "nl-1" => { "state" => "granted" } } }
    # "" stringifies as earliest in both directions, so without the guard the malformed
    # entry wins whichever order it arrives in.
    [[good, blank], [blank, good]].each do |ledgers|
      merged = Contact.merge_newsletter_ledgers(ledgers)
      assert_equal "history", merged["entries"]["nl-1"]["state"], "order #{ledgers.first.equal?(good)}"
      assert_equal "2026-01-01T00:00:00Z", merged["entries"]["nl-1"]["at"]
    end
  end

  test "a merged ledger takes its member_id from the ghost_id owner, not input order" do
    # A ledger whose member_id does not match the contact's linked member is ignored by
    # the grant decision, so mis-attributing it silently disables layer 2 even though
    # every entry survived.
    first = Contact.create!(email: "attrib@example.com", ghost_data: {
      "newsletter_ledger" => { "member_id" => "m9", "entries" => {
        "nl-1" => { "state" => "history", "at" => "2026-01-01T00:00:00Z" } } } })
    Contact.create!(email: "ATTRIB@example.com", ghost_id: "m5", ghost_data: {
      "newsletter_ledger" => { "member_id" => "m5", "entries" => {
        "nl-2" => { "state" => "granted", "at" => "2026-02-01T00:00:00Z" } } } })

    survivor = first.dedupe!
    assert_equal "m5", survivor.ghost_id
    assert_equal "m5", survivor.ghost_data.dig("newsletter_ledger", "member_id"),
      "the ledger must describe the member the survivor is actually linked to"
    assert_equal %w[nl-1 nl-2], survivor.ghost_data.dig("newsletter_ledger", "entries").keys.sort
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

  test "the fresh_existing merge reads the locked row, not a stale in-memory copy" do
    # The surrounding code merges from locked reads so a concurrent write is not lost.
    # A ledger entry written to our row after this object was loaded must survive the
    # save!, which rewrites the whole ghost_data column.
    a = Contact.create!(email: "stale@example.com")
    Contact.create!(email: "stale2@example.com", apollo_id: "apollo-stale")
    # Write behind a's back, exactly as another process would.
    Contact.where(id: a.id).first.tap do |fresh|
      fresh.record_ledger_entry!("nl-concurrent", "history", member_id: "m7")
      fresh.save!
    end
    refute a.ledger_has?("nl-concurrent"), "the in-memory copy must still be stale"

    apollo = mock("apollo")
    apollo.stubs(:search_by_email).returns([{ "id" => "apollo-stale", "email" => a.email }])
    a.sync_to_apollo!(apollo)

    assert a.reload.ledger_has?("nl-concurrent"),
      "a ledger entry written between load and lock must not be clobbered"
  end

  test "the fresh_existing merge path unions ledgers in both directions" do
    # sync_to_apollo!'s RecordNotUnique handler is the other merge path, and a ledger
    # entry lost there is a consent violation exactly as in dedupe!.
    a = Contact.create!(email: "fx@example.com", ghost_data: {
      "newsletter_ledger" => { "member_id" => "m3", "entries" => {
        "nl-1" => { "state" => "history", "at" => "2026-01-01T00:00:00Z" } } } })
    Contact.create!(email: "fx2@example.com", apollo_id: "apollo-1", ghost_data: {
      "newsletter_ledger" => { "member_id" => "m3", "entries" => {
        "nl-2" => { "state" => "granted", "at" => "2026-02-01T00:00:00Z" } } } })

    apollo = mock("apollo")
    apollo.stubs(:search_by_email).returns([{ "id" => "apollo-1", "email" => a.email }])
    a.sync_to_apollo!(apollo)

    entries = a.reload.ghost_data.dig("newsletter_ledger", "entries")
    assert_equal %w[nl-1 nl-2], entries.keys.sort
    assert_equal "history", entries["nl-1"]["state"]
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
        if existing
          existing_at = existing["at"].to_s
          incoming_at = entry["at"].to_s
          # A blank timestamp is UNKNOWN, not "earliest". Comparing it as a string makes
          # "" sort earliest in both directions, so a malformed entry would win whichever
          # order it arrived in. Resolve it explicitly instead:
          #   incoming blank        -> never displaces
          #   existing blank, incoming good -> fall through and replace
          #   both well-formed      -> earliest wins
          next if incoming_at.empty?
          next if !existing_at.empty? && existing_at <= incoming_at
        end
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

  # Write-once, in memory only: this method never saves. Never write the ledger with
  # update_column/update_all/raw jsonb either, because link_contact! rebuilds ghost_data
  # from this same in-memory hash and would clobber an out-of-band write.
  #
  # NOTE for callers: link_contact! early-returns when the contact is already linked and
  # nothing was written, which is the steady state for most contacts. A caller that
  # records a ledger entry MUST ensure a save actually happens, or the entry evaporates.
  def record_ledger_entry!(newsletter_id, state, member_id:)
    ledger = newsletter_ledger.deep_dup
    # Guard against nil: ||= would create the key with a nil value, which makes the
    # ledger "changed" and writes a nil member_id on the next save.
    ledger["member_id"] = member_id if ledger["member_id"].blank? && member_id.present?
    ledger["entries"] ||= {}
    if ledger["entries"].key?(newsletter_id.to_s)
      # Write-once on the entry, but still persist a newly-learned member_id: a ledger
      # carried through a merge can have entries and no member_id, and without this it
      # could never acquire one, leaving the identity check permanently disabled.
      self.ghost_data = ghost_data.merge("newsletter_ledger" => ledger) if ledger != newsletter_ledger
      return self
    end

    ledger["entries"][newsletter_id.to_s] = { "state" => state.to_s, "at" => Time.current.iso8601 }
    self.ghost_data = ghost_data.merge("newsletter_ledger" => ledger)
    self
  end
```

In `dedupe!`, after the existing `any_deleted_at` block and before `losers.each`, add:

```ruby
        # Order matters for member_id only: merge_newsletter_ledgers takes the first
        # non-nil one, and it must be the ghost_id owner's, because that is the member
        # the survivor ends up linked to. A ledger whose member_id does
        # not match the contact's linked member is IGNORED by the grant decision, so
        # picking the wrong one silently disables layer 2 for the whole merged ledger
        # even though every entry survived. Entry unioning itself is order-independent.
        ledger_sources = [ghost_id_owner, survivor, *dupes].compact.uniq
        merged_ledger = Contact.merge_newsletter_ledgers(
          ledger_sources.map { |d| d.ghost_data["newsletter_ledger"] }
        )
        merged_ghost_data["newsletter_ledger"] = merged_ledger if merged_ledger.present?
```

In the `fresh_existing` merge in `sync_to_apollo!`, inside `if fresh_existing`, after the existing `deleted_at` preservation block, add:

```ruby
                # Include fresh_self: the surrounding code deliberately merges from the
                # LOCKED reads so a concurrent write is not lost, and a ledger entry
                # written to our row between load and lock would otherwise be clobbered
                # by the save! below, which rewrites the whole ghost_data column.
                # self first so its member_id wins.
                merged_ledger = Contact.merge_newsletter_ledgers([
                  self.ghost_data["newsletter_ledger"],
                  fresh_self.ghost_data["newsletter_ledger"],
                  fresh_existing.ghost_data["newsletter_ledger"],
                ])
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
- Produces: `Stacks::GhostSync::EXCLUDED_SOURCE_PREFIX = "g3d:ghost"`, `.source_prefix(source)` -> String, `#target_newsletter_ids(contact, enabled)` -> Array of ids. Instance state set up by `load_newsletter_config!`: `@prefix_map`, `@grants_enabled`, `@writes_remaining`.
- Consumes: Task 1's `System#ghost_newsletter_prefix_map_clean`, `#ghost_newsletter_grants_enabled?`, `#ghost_sweep_write_budget_clamped`.

- [ ] **Step 1: Write the failing tests**

Insert before the closing `end` of `class Stacks::GhostSyncTest`, alongside the helpers from the Test harness preamble:

```ruby
  test "source_prefix takes the first colon segment, downcased" do
    { "index:luma:chinatown" => "index", "xxix:" => "xxix", "team" => "team",
      "G3D:foo" => "g3d", "sanctu:luma:family.intelligence" => "sanctu" }.each do |source, expected|
      assert_equal expected, Stacks::GhostSync.source_prefix(source), source
    end
  end

  test "the g3d:ghost namespace never produces a target even when g3d is mapped" do
    enable_sources("g3d:ghost", "g3d:ghost:index", "g3d:substack:g3d_substack")
    sys!(ghost_newsletter_prefix_map: { "g3d" => "nl-g3d" })
    contact = Contact.create!(email: "loop@example.com",
      sources: ["g3d:ghost", "g3d:ghost:index", "g3d:substack:g3d_substack"])
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-g3d"))
    sync = sync_with(ghost)
    sync.send(:load_newsletter_config!)
    # Both directions. Without the third source an over-broad exclusion such as
    # start_with?("g3d") would pass this test while silently dropping every
    # g3d:substack:* contact (3,197 of them) out of the g3d newsletter.
    assert_equal ["nl-g3d"], sync.target_newsletter_ids(contact, enabled_sources),
      "g3d:ghost* is excluded; other g3d:* sources still map to the g3d newsletter"
  end

  test "excluded_source? draws the boundary at the colon, not the prefix string" do
    { "g3d:ghost" => true, "g3d:ghost:index" => true, "G3D:Ghost" => true,
      "g3d:ghostwriter" => false, "g3d:substack:g3d_substack" => false,
      "g3d" => false }.each do |source, expected|
      assert_equal expected, Stacks::GhostSync.excluded_source?(source), source
    end
  end

  test "targets come only from enabled, mapped, non-blank prefixes" do
    enable_sources("index:shopify_customer", "index:luma:chinatown", "xxix:mailchimp:xxix_mailchimp")
    sys!(ghost_newsletter_prefix_map: {
      "index" => "nl-index", "xxix" => "", "usb_club" => "nl-usb" })
    contact = Contact.create!(email: "t@example.com", sources: [
      "index:shopify_customer",              # enabled + mapped
      "index:luma:chinatown",                # same prefix again: must not duplicate
      "xxix:mailchimp:xxix_mailchimp",       # enabled but mapped to blank
      "usb_club:shopify_customer",           # mapped but NOT enabled
      "etl:meet",                            # neither
    ])
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index", "nl-usb"))
    sync = sync_with(ghost)
    sync.send(:load_newsletter_config!)
    assert_equal ["nl-index"], sync.target_newsletter_ids(contact, enabled_sources)
  end

  test "sync_all! loads the newsletter config" do
    # Pins the call site itself: remove it and @prefix_map stays empty.
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "cfg@example.com", sources: ["index:shopify_customer"])
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    ghost.stubs(:create_member).returns(member(id: "mcfg", email: "cfg@example.com"))
    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal({ "index" => "nl-index" }, sync.instance_variable_get(:@prefix_map))
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
  ensure
    System.class_variable_set(:@@instance, nil)
  end

  test "a mapping to an unknown or archived newsletter is dropped and counted" do
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: {
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
  # Must equal SOURCE_PREFIX: the exclusion exists precisely because the pull leg writes
  # SOURCE_PREFIX-namespaced sources. Aliased rather than repeating the literal so the two
  # cannot drift apart and silently disable the feedback-loop guard.
  EXCLUDED_SOURCE_PREFIX = SOURCE_PREFIX

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

    # Degrade rather than abort. Before this, /newsletters/ was only touched from inside
    # upsert_contact_from_member, which runs under capture_errors, so an outage became
    # per-contact error lines and the deletion and label legs still completed. As the
    # first statement in sync_all! an exception would kill all of them. Fail closed on
    # GRANTS only: an empty prefix map means no grants, which is the safe posture, while
    # labels and deletion reconciliation carry on.
    fetched = begin
      all_newsletters
    rescue => e
      @errors << "newsletter config: #{e.class}: #{e.message}"
      @summary[:grant_config_unavailable] += 1
      @prefix_map = {}
      return @prefix_map
    end

    active_ids = fetched.select { |n| n["status"] == "active" }.map { |n| n["id"] }.to_set
    @prefix_map = requested.select { |_, id| active_ids.include?(id) }
    @summary[:grant_mapping_invalid] += (requested.length - @prefix_map.length)
    @prefix_map
  end
```

Share one fetch between this and the pull leg's slug map, so a sweep never hits `/newsletters/` twice.
Replace the existing `newsletter_slug_map` (`ghost_sync.rb:159-163`) with:

```ruby
  # One /newsletters/ fetch per sweep, shared by the push leg's prefix-map validation
  # (load_newsletter_config!) and the pull leg's slug resolution. Keep the RAW list here:
  # the slug map needs archived newsletters too, the prefix map does not.
  def all_newsletters
    @all_newsletters ||= @ghost.all_newsletters
  end

  def newsletter_slug_map
    @newsletter_slug_map ||= all_newsletters.each_with_object({}) { |n, map| map[n["id"]] = n["slug"] }
  end
```

Call `load_newsletter_config!` as the first line of `sync_all!`, before `enabled = ...`.

Insert `target_newsletter_ids` immediately after `upsert_contact_from_member` (`ghost_sync.rb:151`),
**above** the `private` keyword at `:153`. The Task 4 tests call it publicly; if it lands under
`private` they fail with `NoMethodError: private method called`.

Note the `n["status"].nil?` allowance: the existing test fixture helper emits no `status` key, and treating a missing status as inactive would drop every newsletter in tests.

- [ ] **Step 4: Run tests to verify they pass**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: all green, including the 28 pre-existing sweep tests

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
    sys!(ghost_newsletter_prefix_map: map)
    Contact.create!(email: "g@example.com", sources: sources, ghost_id: "m50")
  end

  test "a never-subscribed member with a mapped source becomes a grant candidate" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).with("m50", current_newsletter_ids: []).returns([])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal ["nl-xxix"], sync.send(:grant_candidates_for, contact, m, enabled_sources)
  end

  test "a currently subscribed newsletter is observed, never a candidate" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com", extra: {
      "newsletters" => [{ "id" => "nl-xxix", "name" => "XXIX", "status" => "active" }] })
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).never
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
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

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
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

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal "history", contact.ledger_state("nl-xxix")
    assert_equal 1, sync.summary[:unsubscribe_respected]
  end

  test "a prior SUBSCRIBE event disqualifies just as an unsubscribe does" do
    # "Never been subscribed" means never, in either direction. Narrowing this to
    # subscribed == false would re-grant anyone who subscribed and later unsubscribed,
    # which is the entire population this feature protects.
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m50", "newsletter_id" => "nl-xxix", "subscribed" => true,
        "created_at" => "2026-01-01T00:00:00.000Z" } }])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal "history", contact.ledger_state("nl-xxix")
  end

  test "a granted or observed ledger entry counts as already_handled, not unsubscribe_respected" do
    # These are different numbers in the rollout review: unsubscribe_respected is meant to
    # mean "we correctly did not re-subscribe someone", so entries this sync created must
    # not inflate it.
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    contact.record_ledger_entry!("nl-xxix", "granted", member_id: "m50")
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).never
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal 1, sync.summary[:already_handled]
    assert_equal 0, sync.summary[:unsubscribe_respected]
  end

  test "the history is read at most once per member across several targets" do
    # Pins both the memoization and the per-MEMBER (not per-target) scope of the read.
    enable_sources("xxix:", "index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix", "index" => "nl-index" })
    contact = Contact.create!(email: "multi@example.com",
      sources: ["xxix:", "index:shopify_customer"], ghost_id: "m57")
    # BOTH targets must reach the fetch line, so the member is subscribed to NEITHER.
    # With one target currently subscribed it short-circuits first, and then `events =`
    # and `events ||=` are indistinguishable: only one target ever fetches.
    m = member(id: "m57", email: "multi@example.com")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix", "nl-index"))
    ghost.expects(:newsletter_events_for).once.returns([])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal %w[nl-index nl-xxix],
      sync.send(:grant_candidates_for, contact, m, enabled_sources).sort
  end

  test "a target the member is already subscribed to costs no API call" do
    enable_sources("xxix:", "index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix", "index" => "nl-index" })
    contact = Contact.create!(email: "mixed@example.com",
      sources: ["xxix:", "index:shopify_customer"], ghost_id: "m58")
    m = member(id: "m58", email: "mixed@example.com", extra: {
      "newsletters" => [{ "id" => "nl-index", "name" => "Index", "status" => "active" }] })

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix", "nl-index"))
    ghost.expects(:newsletter_events_for).once.returns([])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal ["nl-xxix"], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal "observed", contact.ledger_state("nl-index")
  end

  test "a RequestError from the history read also fails closed" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).raises(Stacks::Ghost::RequestError.new(500, "boom"))
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal 1, sync.summary[:grant_errors]
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

    candidates = sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal ["nl-xxix"], candidates
    assert_equal({}, contact.newsletter_ledger_entries),
      "a candidate is not a grant: the decision writes no ledger entry for it"
  end

  test "an untrustworthy history fails closed for the whole member" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).raises(Stacks::Ghost::UntrustworthyHistory, "200 with empty list")
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
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

      assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
      assert_equal 1, sync.summary[:grant_skipped_undeliverable]
      assert_nil contact.ledger_state("nl-xxix")
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

    assert_equal ["nl-xxix"], sync.send(:grant_candidates_for, contact, m, enabled_sources)
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
  def grant_candidates_for(contact, member, enabled, count: true)
    targets = target_newsletter_ids(contact, enabled)
    return [] if targets.empty?

    current_ids = (member["newsletters"] || []).map { |n| n["id"] }.compact
    ledger_applies = contact.ledger_member_id.nil? || contact.ledger_member_id == member["id"]

    undeliverable = member.dig("email_suppression", "suppressed") || member["email_disabled"]
    candidates = []
    events = nil

    targets.each do |newsletter_id|
      # Step 1 runs before step 3 on purpose: a suppressed member still gets observed
      # entries for what they ARE subscribed to, which is the population most likely to
      # unsubscribe next.
      if current_ids.include?(newsletter_id)
        contact.record_ledger_entry!(newsletter_id, "observed", member_id: member["id"])
        next
      end

      if undeliverable
        @summary[:grant_skipped_undeliverable] += 1
        next
      end

      if ledger_applies && contact.ledger_has?(newsletter_id)
        if count
          if contact.ledger_state(newsletter_id) == "history"
            @summary[:unsubscribe_respected] += 1
          else
            @summary[:already_handled] += 1
          end
        end
        next
      end

      begin
        events ||= @ghost.newsletter_events_for(member["id"], current_newsletter_ids: current_ids)
      rescue Stacks::Ghost::UntrustworthyHistory, Stacks::Ghost::RequestError => e
        # Fail closed: no grants for this member this sweep. Any "observed" entry already
        # recorded for an earlier target stands, which is fine: observed only ever blocks
        # a future grant, it never permits one.
        @summary[:grant_errors] += 1
        @errors << "#{contact.email}: history unreadable: #{e.class}: #{e.message}"
        return []
      end

      if events.any? { |ev| ev.dig("data", "newsletter_id") == newsletter_id }
        contact.record_ledger_entry!(newsletter_id, "history", member_id: member["id"])
        @summary[:unsubscribe_respected] += 1 if count
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
- **Modify (existing test, will otherwise break): `test/lib/stacks/ghost_sync_test.rb:50-67`** - the create
  test asserts exact hash equality on `create_member`'s attrs. This task adds a `newsletters:` key
  unconditionally, so that equality fails, and because `Mocha::ExpectationError` descends from
  `Exception` the failure aborts `sync_all!` rather than being counted. Change the expectation to:
  ```ruby
      .with { |attrs|
        attrs[:email] == "new@example.com" && attrs[:name] == "New Person" &&
          attrs[:labels] == ["newsletter"] && attrs[:newsletters] == []
      }
  ```

**Interfaces:**
- Consumes: Tasks 2, 3, 6, 7.
- Produces: `sync_contact!` issues at most one `update_member` per contact carrying `newsletters` (plus `labels` when they differ); the create path always sends an explicit `newsletters` array.

- [ ] **Step 1: Write the failing tests**

```ruby
  test "a grant re-reads the member and its history immediately before the PUT" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    sys!(ghost_newsletter_grants_enabled: "1")
    # labels match the enabled source, so the label path is a genuine no-op and any
    # update_member call we see is the grant.
    snapshot = member(id: "m50", email: "g@example.com", labels: ["xxix:"])
    fresh = member(id: "m50", email: "g@example.com", labels: ["xxix:"], extra: {
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
    sys!(ghost_newsletter_grants_enabled: "1")
    m = member(id: "m50", email: "g@example.com", labels: ["xxix:"])

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
    sys!(ghost_newsletter_grants_enabled: "0")
    m = member(id: "m50", email: "g@example.com", labels: ["xxix:"])

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
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" },
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
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
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
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
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

  test "a history ledger entry survives a sweep that also writes a label update" do
    # link_contact! rebuilds the whole ghost_data column from the in-memory hash. If a
    # ledger entry were written out of band (update_column / raw jsonb), this would
    # clobber it, turning a durable "no" back into a fresh layer-3 roll every sweep.
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" }, ghost_newsletter_grants_enabled: "1")
    contact = Contact.create!(email: "clob@example.com", sources: ["xxix:"], ghost_id: "m85")
    m = member(id: "m85", email: "clob@example.com", labels: [])   # label diff WILL fire

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([m])
    ghost.stubs(:newsletter_events_for).returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m85", "newsletter_id" => "nl-xxix", "subscribed" => false,
        "created_at" => "2026-01-01T00:00:00.000Z" } }])
    ghost.stubs(:update_member).returns(member(id: "m85", email: "clob@example.com", labels: ["xxix:"]))

    sync_with(ghost).sync_all!
    assert_equal "history", contact.reload.ledger_state("nl-xxix"),
      "the ledger entry must survive link_contact! rebuilding ghost_data"
  end

  test "the 422 adopt path runs layer 3 and respects the grants flag" do
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" }, ghost_newsletter_grants_enabled: "0")
    contact = Contact.create!(email: "adopt@example.com", sources: ["xxix:"])
    existing = member(id: "m86", email: "adopt@example.com", labels: ["xxix:"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).raises(Stacks::Ghost::RequestError.new(422, "already exists"))
    ghost.expects(:find_member_by_email).with("adopt@example.com").returns(existing)
    # An adopted member is NOT new: it must run the history check, not skip it.
    ghost.expects(:newsletter_events_for).returns([])
    ghost.expects(:update_member).never   # grants flag is off

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_planned]
    assert_equal "m86", contact.reload.ghost_id
  end

  test "two case-fold duplicate contacts produce exactly one create" do
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
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
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" },
         ghost_newsletter_grants_enabled: "1")
    Contact.create!(email: "owner@example.com", sources: ["index:shopify_customer"], ghost_id: "m64")
    Contact.create!(email: "OWNER@example.com", sources: ["index:shopify_customer"])

    linked = member(id: "m64", email: "owner@example.com", labels: ["index:shopify_customer"])
    seen = []
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([linked])
    ghost.stubs(:newsletter_events_for).returns([])
    ghost.stubs(:find_member).returns(linked)
    ghost.stubs(:update_member).with { |_id, attrs| seen << attrs; true }
      .returns(linked.merge("newsletters" => [{ "id" => "nl-index" }]))

    sync = sync_with(ghost)
    sync.sync_all!

    assert_equal 1, seen.count { |a| a.key?(:newsletters) },
      "exactly one contact may write newsletters for member m64"
    assert_equal 1, sync.summary[:grants_skipped_unlinked]
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb`
Expected: FAIL on the new grant tests

- [ ] **Step 3: Implement**

Rewrite `sync_contact!`'s member branches. The create branch:

```ruby
      begin
        requested_newsletter_ids = create_newsletter_ids(contact, enabled)
        member = @ghost.create_member(
          { email: contact.email, name: contact.display_name.presence, labels: desired,
            newsletters: requested_newsletter_ids.map { |id| { id: id } } }.compact
        )
        @summary[:created] += 1
        wrote = true
        confirm_granted!(contact, member, requested_newsletter_ids)
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

  # Write granted only for what the response confirms AND what we actually asked for.
  # Ghost's subscribe_on_signup can attach newsletters we never requested; recording
  # those as "granted" would both inflate the number rollout step 7 compares against
  # grants_planned and permanently block a future legitimate grant, since ledger
  # entries are write-once with no repair path.
  def confirm_granted!(contact, member, requested)
    confirmed = (member["newsletters"] || []).map { |n| n["id"] }.compact
    (confirmed & requested).each do |id|
      contact.record_ledger_entry!(id, "granted", member_id: member["id"])
      @summary[:granted_on_create] += 1
      @summary[:granted_by_newsletter][id] += 1
    end
    (confirmed - requested).each do |id|
      contact.record_ledger_entry!(id, "observed", member_id: member["id"])
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

    # count: false - the decision-phase call already counted these; recounting would
    # double every unsubscribe_respected / already_handled that rollout step 6 reviews.
    candidates = grant_candidates_for(contact, fresh, enabled, count: false)
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
    @writes_remaining = 0   # fail closed until load_newsletter_config! sets the budget
    @prefix_map = {}        # so target_newsletter_ids cannot NoMethodError on nil
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
    # A case-fold duplicate resolves to another Contact's member via members_by_email
    # while carrying ghost_id: nil and an empty ledger, which structurally disables
    # layer 2 for it. Guard on who OWNS the member, not on this contact's ghost_id:
    # checking `contact.ghost_id.present?` would never fire, because the case we are
    # defending against is precisely the one where it is nil.
    if contact.ghost_id.nil? &&
       Contact.where(ghost_id: member["id"]).where.not(id: contact.id).exists?
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
    sys!(ghost_newsletter_prefix_map: {}, ghost_sweep_write_budget: 1)
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
    sys!(ghost_newsletter_prefix_map: {}, ghost_sweep_write_budget: 1)
    2.times { |i| Contact.create!(email: "c#{i}@example.com", sources: ["index:x"]) }

    ghost = mock("ghost")
    # The second sweep must see the member created by the first. Otherwise the
    # deletion-reconciliation leg (ghost_sync.rb:47-51) clears c0's ghost_id and stamps
    # deleted_at, and the test would pass by recycling c0 rather than resuming c1.
    ghost.stubs(:all_members).returns([]).then.returns([member(id: "mc1", email: "c0@example.com")])
    ghost.stubs(:create_member).returns(
      member(id: "mc1", email: "c0@example.com")).then.returns(
      member(id: "mc2", email: "c1@example.com"))

    Stacks::GhostSync.new(ghost).sync_all!
    # The budget lives on the instance, so the second sweep needs a second object.
    second = Stacks::GhostSync.new(ghost)
    second.sync_all!
    assert_equal 1, second.summary[:created]
    assert_equal "mc2", Contact.find_by(email: "c1@example.com").ghost_id,
      "the deferred contact is the one that resumed"
  end

  test "an exhausted budget skips the history read entirely" do
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" }, ghost_sweep_write_budget: 1)
    # Two linked contacts, budget 1. The second must be deferred BEFORE its history read.
    Contact.create!(email: "g1@example.com", sources: ["xxix:"], ghost_id: "m51")
    Contact.create!(email: "g2@example.com", sources: ["xxix:"], ghost_id: "m52")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([
      member(id: "m51", email: "g1@example.com", labels: ["xxix:"]),
      member(id: "m52", email: "g2@example.com", labels: ["xxix:"])])
    # Exactly one history read: the deferred contact must cost no API calls at all.
    ghost.expects(:newsletter_events_for).once.returns([])

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_deferred]
  end

  test "linked contacts get their reserved allowance even when creates would exhaust it" do
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" },
         ghost_newsletter_grants_enabled: "0",
         ghost_sweep_write_budget: 2)
    # Create the unlinked contacts FIRST so they sort ahead of the linked one by id.
    # Without the scope split, find_each's id order would exhaust the budget on these
    # five creates and never reach `linked`, so this ordering is what makes the test
    # actually exercise the reservation.
    5.times { |i| Contact.create!(email: "z#{i}@example.com", sources: ["xxix:"]) }
    Contact.create!(email: "linked@example.com", sources: ["xxix:"], ghost_id: "m80")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([
      member(id: "m80", email: "linked@example.com", labels: ["xxix:"])])
    ghost.expects(:newsletter_events_for).with("m80", anything).returns([])
    ghost.stubs(:create_member).returns(member(id: "mz", email: "z0@example.com"))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_planned],
      "the linked contact's decision must run on the first sweep, not after the ramp"
    assert_operator sync.summary[:creates_deferred], :>=, 4
  end

  test "the budget binds identically when the grants flag is off" do
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" },
         ghost_newsletter_grants_enabled: "0", ghost_sweep_write_budget: 1)
    Contact.create!(email: "d1@example.com", sources: ["xxix:"], ghost_id: "m53")
    Contact.create!(email: "d2@example.com", sources: ["xxix:"], ghost_id: "m54")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([
      member(id: "m53", email: "d1@example.com", labels: ["xxix:"]),
      member(id: "m54", email: "d2@example.com", labels: ["xxix:"])])
    ghost.expects(:newsletter_events_for).once.returns([])

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_deferred],
      "a planned grant consumes budget exactly as a real one does"
  end

  test "an exhausted budget defers label-only updates" do
    enable_sources("newsletter", "fundraising")
    sys!(ghost_sweep_write_budget: 1)
    Contact.create!(email: "l1@example.com", sources: %w[newsletter fundraising], ghost_id: "m55")
    Contact.create!(email: "l2@example.com", sources: %w[newsletter fundraising], ghost_id: "m56")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([
      member(id: "m55", email: "l1@example.com", labels: ["newsletter"]),
      member(id: "m56", email: "l2@example.com", labels: ["newsletter"])])
    ghost.expects(:update_member).once.returns(
      member(id: "m55", email: "l1@example.com", labels: %w[newsletter fundraising]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:updates_deferred]
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `RAILS_ENV=test bundle exec rails test test/lib/stacks/ghost_sync_test.rb -n "/budget|deferred|allowance/"`
Expected: FAIL

- [ ] **Step 3: Implement**

Add the constant next to `ADVISORY_LOCK_KEY` (`ghost_sync.rb:10`):

```ruby
  # Ceiling on the per-sweep allowance reserved for already-linked contacts, so a large
  # linked population can never starve the create backfill.
  LINKED_RESERVE_CAP = 500
```

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
      # Size the reservation to the linked population, not to a fraction of the budget.
      # A flat 50% would halve create throughput and double the 19k backfill from ~8
      # sweeps to ~16, contradicting "each sweep creates up to 2,500 members".
      linked_budget = [[eligible.synced_to_ghost.count, LINKED_RESERVE_CAP].min, 1].max

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
      # try_advisory_lock, not advisory_lock: a full sweep runs tens of minutes, and
      # blocking would stall the whole daily task chain behind it with no timeout.
      # Mirrors sync_all_with_lock!'s "another run holds the lock" behaviour.
      conn = ActiveRecord::Base.connection
      got_lock = false
      12.times do
        got_lock = conn.select_value(
          "SELECT pg_try_advisory_lock(#{Stacks::GhostSync::ADVISORY_LOCK_KEY})")
        break if got_lock
        sleep 5
      end

      if got_lock
        begin
          Contact.all.each(&:dedupe!)
        ensure
          conn.execute("SELECT pg_advisory_unlock(#{Stacks::GhostSync::ADVISORY_LOCK_KEY})")
        end
      else
        Rails.logger.warn("[stacks:sync_contacts] skipped dedupe: Ghost sweep holds the advisory lock")
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

Two ordering rules, both load-bearing:

1. **Put `system`, `map`, `newsletters` and `prefixes` at the very top of the `content` block, BEFORE
   `panel "Synced Sources"`.** Ruby resolves locals lexically at parse time, so a block appearing above
   the assignment cannot see the local and parses `map[...]` as a method call, raising on every render.
   `ruby -c` cannot catch this.
2. **Replace BOTH existing `System.instance` uses** in this file (lines 11 and 53) with the same fresh
   `System.first_or_create!(settings: {})`. Storext writes the whole `settings` jsonb column, so leaving
   `update_sources` on the memoized instance means the next "Save Synced Sources" click writes a stale
   hash back and **silently deletes the prefix map, the grants flag and the budget** - exactly the
   rollout order the spec prescribes (map first, then sources).

Add:

```ruby
    system = System.first_or_create!(settings: {})
    map = system.ghost_newsletter_prefix_map_clean
    newsletters_ok = true
    newsletters = begin
      Stacks::Ghost.new(max_retries: 1).all_newsletters.select { |n| n["status"] != "archived" }
    rescue => e
      newsletters_ok = false
      []
    end

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
      # If Ghost is unreachable every dropdown renders with only "Not mapped", nothing
      # matches `selected:`, and submitting would post a blank for every prefix, deleting
      # the entire consent mapping. Refuse to render a submittable form in that state.
      if !newsletters_ok && map.any?
        para "Could not reach Ghost, so the newsletter list is unavailable. Saving is " \
             "disabled to avoid clearing the existing mapping. Reload once Ghost is reachable."
      end

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
            # split_part matches Stacks::GhostSync.source_prefix exactly. A LIKE
            # '<prefix>:%' would miss a bare single-segment source such as `team`, which
            # the sweep WOULD subscribe, so the preview would understate the number
            # rollout step 3 asks Hugh to decide on.
            Contact
              .where("sources && ARRAY[?]::varchar[]", system.ghost_synced_sources)
              .where("EXISTS (SELECT 1 FROM unnest(sources) s WHERE split_part(lower(s), ':', 1) = ? AND lower(s) <> 'g3d:ghost' AND lower(s) NOT LIKE 'g3d:ghost:%')", prefix)
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
          input type: :submit, value: "Save Newsletter Settings",
            disabled: (!newsletters_ok && map.any?) || nil
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
    # The default must be Parameters, not Hash: a plain {} has no #permit! and would
    # raise when no prefix rows are submitted.
    submitted = params[:prefix_map] || ActionController::Parameters.new
    map = submitted.permit!.to_h
      .transform_keys { |k| k.to_s.downcase }
      .transform_values(&:to_s)
      .reject { |_, v| v.blank? }

    system = System.first_or_create!(settings: {})
    if map.empty? && system.ghost_newsletter_prefix_map_clean.any?
      redirect_to admin_ghost_sync_path,
        alert: "Refusing to clear every newsletter mapping at once. Unmap prefixes one at a time."
      return
    end

    system.update!(
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

`ruby -c` is NOT sufficient: the lexical-local bug described above parses fine and raises only at
render time. Create `test/controllers/admin_ghost_sync_page_test.rb` that actually renders the page:

```ruby
require "test_helper"

class AdminGhostSyncPageTest < ActionDispatch::IntegrationTest
  test "the Ghost Sync page renders with a mapping configured" do
    System.first_or_create!(settings: {}).update!(
      ghost_synced_sources: ["index:shopify_customer"],
      ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "render@example.com", sources: ["index:shopify_customer"])
    Stacks::Ghost.any_instance.stubs(:all_newsletters).returns(
      [{ "id" => "nl-index", "name" => "Index Space", "slug" => "index", "status" => "active" }])

    get admin_ghost_sync_path
    assert_response :success
    assert_match "Index Space", response.body
  end

  test "saving synced sources preserves the newsletter mapping" do
    System.first_or_create!(settings: {}).update!(
      ghost_newsletter_prefix_map: { "index" => "nl-index" })
    post admin_ghost_sync_update_sources_path, params: { sources: ["index:shopify_customer"] }
    assert_equal({ "index" => "nl-index" },
      System.first.reload.ghost_newsletter_prefix_map_clean,
      "update_sources must not write back a stale settings hash")
  end
end
```

Look in `test/controllers/` for how this suite authenticates an admin (ActiveAdmin routes require a
signed-in `AdminUser`) and add that setup; `test/models/admin_authorization_test.rb` shows how admin
users are built here. If no integration-test sign-in helper exists, add one in `setup`.

Run: `RAILS_ENV=test bundle exec rails test test/controllers/admin_ghost_sync_page_test.rb`
Expected: 2 runs, 0 failures

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
