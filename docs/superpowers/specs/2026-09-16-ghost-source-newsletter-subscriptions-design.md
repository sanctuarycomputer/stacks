# Ghost Sync: Source-Driven Newsletter Subscriptions (Design)

**Date:** 2026-09-16
**Status:** Approved by Hugh for implementation
**Repo:** `stacks`. This spec amends `docs/superpowers/specs/2026-07-20-ghost-contact-sync-design.md`.

## Instructions for the implementing agent

- Work on a feature branch (never `main`). Copy `config/master.key` into your worktree first (see `CLAUDE.md`).
- Read the 2026-07-20 design doc and `lib/stacks/ghost_sync.rb` + `test/lib/stacks/ghost_sync_test.rb` before writing code. This change extends that sweep; it does not replace it.
- TDD with the existing minitest + stubbed-client patterns. Never call the real Ghost API from tests.
- The safety property in "Core invariant" below is the whole point of this feature. Every code path that writes `newsletters` must be covered by a test proving it cannot re-subscribe someone who unsubscribed.
- Open a PR when done. Do not flip the grants flag or check any source on in production yourself (see Rollout).
- **Read "Verified platform facts" before designing anything.** Those rows were established by probing
  the live Ghost API and by running this app's own bundle, specifically because several of them fail
  *silently* rather than raising. Do not re-derive them, and do not assume anything not listed there.
- The highest-risk work in this change is **"Hardening layer 3"**. It is mandatory. The events endpoint
  returns `200 {"events": []}` for a bad member id, and under a naive reading that means "never
  subscribed" and grants. Write those tests first.
- One assumption is **unverified and blocking** (see "Blocking pre-implementation verification"):
  nobody has ever unsubscribed on this Ghost instance, so "an unsubscribe writes a readable event" has
  no evidence behind it. Ask Hugh before doing the live check; it needs a write to production Ghost.

## Problem

Today the sweep creates Ghost members **without** a `newsletters` key, so Ghost applies `subscribe_on_signup` defaults and every synced contact is subscribed to **every** newsletter (XXIX, Index Space, Sanctuary Computer). Existing members are only ever labeled; subscriptions are never managed. That is wrong in both directions:

- **Over-subscription:** an Index Shopify customer gets the XXIX and Sanctuary newsletters.
- **No expansion:** a contact who later gains an `xxix:*` source is never subscribed to XXIX.

Verified live 2026-09-16: a sync-created member's event history shows three `subscribed: true, source: "api"` events at creation, one per newsletter.

This is blocking the sync of the Index contact base (12,367 contacts), which cannot be turned on until subscriptions are source-driven.

## Consent model (Hugh's rules)

1. **A source is consent.** A contact with a source is opted in to correspondence from that source's brand.
2. **Sources are colon-scoped; the first segment is the brand.** `index:shopify_customer`, `index:luma:chinatown`, `xxix:` all belong to their prefix brand. Each brand prefix maps to **one** Ghost newsletter.
3. **Unsubscribing is per brand and permanent.** Unsubscribing from the XXIX newsletter means never being re-subscribed to XXIX, no matter how many new `xxix:*` sources the contact gains or how many times the sync runs. They keep receiving other brands' newsletters.
4. **Expansion subscribes.** When a contact gains a source under a brand whose newsletter they have **never** been subscribed to, the next sweep subscribes them to it.

## Core invariant

> The sync subscribes a member to newsletter N **only if that member has never been subscribed to N** (by anyone, ever). It never removes subscriptions.

"Ever subscribed" is established from three layers, and a grant requires **all** of them to say "never":

1. **Current state:** member is not currently subscribed to N.
2. **Stacks ledger:** the contact has no ledger entry for N (write-once, see Data model).
3. **Ghost event history:** the member's Ghost event history contains **no** `newsletter_event` for N (any subscribe or unsubscribe event disqualifies).

Layer 3 is authoritative and covers everything that happened before this feature shipped. Layer 2 is a cache and defense-in-depth (and avoids re-querying history daily for people who unsubscribed). If layer 3 cannot be read, or cannot be **shown** to have been read correctly, **fail closed**: no grant. See "Hardening layer 3", which is mandatory, not advisory.

**One honest limitation.** Ghost's member edit replaces the whole `newsletters` array and offers no
conditional write (no ETag, no `If-Match`). So between the fresh GET and the PUT there is a window in
which a person can unsubscribe from a newsletter that is **not** a grant candidate, and our PUT --
which resends their current subscriptions verbatim -- re-adds it. The fresh GET shrinks this window;
it cannot close it. This is a property of Ghost's API, not a bug in this design, and it is stated
here so the invariant is not over-sold when someone relies on it. Mitigations: keep the GET and the
PUT as close together as the design allows (see control flow: the layer-3 read, and on an empty
history its existence probe, are the only calls permitted in that window, and they are there
precisely because the fresh GET alone cannot disqualify a candidate), and never write at all when
there are no candidates.

## Current data (dev DB, 2026-09-16)

Distinct contacts per prefix. These are the numbers the design is sized against.

| prefix | contacts | sources |
|---|---|---|
| `index` | 12,367 | `luma:chinatown` 6515, `shopify_customer` 4306, `mailchimp:index_mailchimp` 1681, `luma:greenpoint` 1154, `luma:chinatownjs` 84, `luma:conjurecollectivewildflower` 58, `luma:radicallove` 38, `luma:noticing` 16 |
| `sanctu` | 4,057 | `mailchimp:sanctu_mailchimp` 3853, `request_pricing_info` 211, `luma:family.intelligence` 1 |
| `g3d` (non-`ghost`) | 3,495 | `substack:g3d_substack` 3197, `hey_mamdani` 178, `family_intelligence*` 210 |
| `xxix` | 895 | `mailchimp:xxix_mailchimp` 893, `xxix:` 3 |
| `usb_club` | 814 | `shopify_customer` 814 |
| `etl` | 3,580 | `meet` 3580. **Not consent.** Never enable as a synced source. |
| `team` | 1 | `team` |

Union of the five brand prefixes: **18,980 contacts**. Ghost holds **52 members** today. Hugh has confirmed the Ghost Pro tier change.

## Verified platform facts

Every row below was checked against Ghost core source, the live API, or the installed gems on
2026-09-16. Rows marked **[probe]** were established by hitting the live Ghost instance; rows marked
**[runtime]** by running the app's own bundle. Do not re-litigate these; do not assume anything not
listed here.

### Ghost members API

| Fact | Evidence | Consequence |
|---|---|---|
| Create with **no** `newsletters` key subscribes to all `subscribe_on_signup` newsletters | `member-repository.js`: `if (memberData.subscribed !== false && !memberData.newsletters)` | Create must **always** send an explicit `newsletters` array. |
| Create with `newsletters: []` subscribes to **nothing** | Same check; `[]` is truthy in JS | Safe way to create a member with no subscriptions. |
| `newsletters` on member edit is a **full replace** (`newslettersToRemove = existing - incoming`) | `member-repository.js` edit path | Every write must send current subscriptions union additions, computed from a **fresh** GET. Never send `subscribed`. |
| Member payloads embed newsletters by id/name without slug | Existing comment in `ghost_sync.rb` | Key everything by newsletter **id**, never slug (XXIX's slug is `default-newsletter`). |

### Ghost members/events API **[probe]**

Real captured `newsletter_event` payload:

```json
{ "type": "newsletter_event",
  "data": { "id": "...", "member_id": "6aaa0647345d7200012fc658", "subscribed": true,
            "created_at": "2026-09-16T03:00:23.000Z", "source": "api",
            "newsletter_id": "6aa857adfe2ac60001f3e242",
            "member": { ... }, "newsletter": { ... } } }
```

`data` keys: `id, member_id, subscribed, created_at, source, newsletter_id, member, newsletter`.

| Fact | Consequence |
|---|---|
| **Use `data["newsletter_id"]`** (scalar). The nested `data["newsletter"]["id"]` also exists | An earlier draft of this spec guessed the nested form. Use the scalar. |
| `data.subscribed` is **not** filterable (400 `Cannot filter by data.subscribed`) | Inspect in Ruby. |
| `data.newsletter_id` is **not** filterable (400 `Cannot filter by data.newsletter_id`) | There is no way to ask Ghost "has this member any event for newsletter N". You must fetch the member's newsletter events and inspect them. This was tested specifically to try to avoid the paging scheme; the API refuses. |
| `data.created_at:<'<iso8601>'` **is** filterable and genuinely applied | Verified both ways: a cutoff before all events returns 0, after returns all. This is the paging cursor. |
| Quotes in a filter must be passed **raw** (`'`), never percent-encoded | `%27` yields **422 Invalid value** (HTTParty encodes the query itself, so `%27` becomes `%2527`). |
| `limit` is **capped at 100**; `limit: "all"` is coerced to `100`, not honored | Unlike `/newsletters/`, where `Stacks::Ghost#all_newsletters` relies on `limit: "all"`. Copying that idiom here truncates silently. |
| The `page` param is **silently ignored** (`limit: 2, page: 2` returns page 1's rows; `meta.pagination.page` and `.next` are `nil`) | Unlike `/members/`, where `Stacks::Ghost#all_members` pages by number. Copying *that* idiom here re-reads the same rows forever. |
| The `order` param is **silently ignored too**. `order=created_at desc`, `order=created_at asc` and even `order=garbage nonsense` all return 200 with identical ordering | There is no way to pin or even know the sort. Any cursor scheme that assumes page 1 is the newest (or oldest) 100 is unfounded. **Do not page this endpoint at all** (see below). |
| `meta.pagination.total` and `.pages` are reliable (`limit=1` returned 1, `total` 3, `pages` 3) | Use `total` as a completeness guard. |

**CRITICAL: this endpoint fails silently, not loudly.**

| member id passed | response |
|---|---|
| `deadbeefdeadbeefdeadbeef` (well-formed hex, nonexistent) | **200**, `total: 0`, `events: []` |
| `not-an-id` (malformed, non-hex) | **200**, `total: 0`, `events: []` |

Under layer 3, "no events" means "never subscribed" means **GRANT**. Any bug that corrupts the member
id (nil, a hash interpolated into a string, a truncated id, a stray character breaking filter syntax)
silently reads as "this person never subscribed" and re-subscribes someone who deliberately opted
out. `Stacks::Ghost#handle_response` raises only on `!response.success?`, so a 200 sails through and
the spec's "fail closed on error" rule never fires. See "Hardening layer 3" below, which is mandatory.

**Current state of the live instance [probe]:** 52 members, 148 newsletter events, **all**
`subscribed: true`, **all** `source: "api"`. Zero members have zero newsletter events. **Zero
unsubscribe events exist anywhere.** Two consequences: (a) the coherence guard below is sound, since
every linked member does have events; (b) the claim "an unsubscribe produces a readable
`newsletter_event`" is **unverified** and cannot be verified read-only. See "Blocking pre-implementation
verification".

### App runtime **[runtime]**

Verified by running this app's own bundle. Each of these silently produces wrong behavior rather than
an error, which is why they are listed.

| Fact | Consequence |
|---|---|
| Storext `Boolean`: `"1"` -> `true`, `"0"` -> `false`, but **`""` -> `""`**, which is **truthy in Ruby** | An unchecked HTML checkbox sends nothing. The usual Rails fix is a preceding hidden input; if its value is `""`, the flag reads **truthy** through the plain reader while the UI renders "off". The hidden input's value **must be `"0"`**. |
| Storext generates a reader and a predicate with **different semantics**: the reader returns the raw Virtus value; the predicate (`attr?`) has a `String -> !blank?` branch (`storext/class_methods.rb:16-33`) | For `""` the reader is truthy and the predicate is `false`. All sweep code must use the **predicate** `ghost_newsletter_grants_enabled?`. |
| Storext `Integer`: `"3000"` -> `3000`, but `""` -> `""` and `"abc"` -> `"abc"` (no coercion) | `budget > 0` then raises `ArgumentError: comparison of String with 0 failed`. In `stacks.rake` that exception is swallowed into a log line, so the daily Ghost sync would silently stop running. Clamp on read. |
| Storext's reader re-runs the Virtus writer on every call (`class_methods.rb:16-23`), and Virtus `Hash#coerce` rebuilds the hash | `system.ghost_newsletter_prefix_map[k] = v` mutates a throwaway object and persists nothing, with no error and no dirty flag. Always assign a whole hash. Read the map **once** into a local at sweep start, not per contact. |
| Virtus `default: {}` is **not** shared across instances (`FromClonable#call` clones) | Safe. Noted so nobody re-investigates. |
| Assigning `ActionController::Parameters` to a Storext `Hash` raises `ActionController::UnfilteredParameters` | The page_action must call `.to_unsafe_h` (after explicit filtering) before assignment. |
| ActiveRecord 6.1 has **no** `??` escape for jsonb's `?` operator (`sanitization.rb:153-160` counts `?` then `gsub(/\?/)`) | `where("... ?? ?", id)` raises `PreparedStatementInvalid: wrong number of bind variables`. An earlier draft of this spec recommended `??`; that advice was wrong. Use `where("jsonb_exists(ghost_data->'newsletter_ledger'->'entries', ?)", id)`. |
| `Hash.new(0)` cannot lazily nest: `h[:a]["b"] += 1` raises `TypeError` | `@summary` is a `Hash.new(0)` (`ghost_sync.rb:17`). Any per-newsletter sub-hash must be initialized explicitly in `initialize`. |
| `config/puma.rb`: `workers 2`, `preload_app!`, `worker_timeout 60`; `rack-timeout` 0.7.0 is in the Gemfile (15s default). No background job infrastructure (`app/jobs` has only `application_job.rb`; the production queue adapter is commented out) | The "Sync Now" button runs the whole sweep **inline in the web request** (`app/admin/ghost_sync.rb:58`). A 2,500-write sweep cannot finish in 15-60s. The rollout must be driven by `rake ghost:sync`, not the button. |
| `System.instance` memoizes in a class variable that is never invalidated (`app/models/system.rb:20-22`), across 2 preloaded puma workers | A setting saved in worker A is not seen by worker B, ever. The sweep currently reads fresh (`ghost_sync.rb:39`) and must continue to. The admin page must **not** read new settings via `System.instance`. |
| `stacks:sync_contacts` runs `Contact.all.each(&:dedupe!)` (`lib/tasks/stacks.rake:419`) in a **separate task that does not take the Ghost advisory lock** | `dedupe!` row-locks and then `delete_all`s duplicate contacts. A concurrent ledger write from the sweep lands on a deleted row, affects 0 rows, and raises nothing. Unioning ledgers inside the merge does not fix this. |

### A note on line references

This spec cites `ghost_sync.rb` and `contact.rb` line numbers from BEFORE the branch landed, as
orientation for where a behaviour lived at design time. They no longer resolve against the current
file. The method and behaviour names are the durable references; use those.

### Blocking pre-implementation verification

The design's authoritative layer assumes **an unsubscribe produces a readable `newsletter_event`**.
The live instance has zero unsubscribe events, so this is assumed, not verified. Before relying on
layer 3, unsubscribe a disposable test member from one newsletter via each path and confirm each
writes an event with `data.subscribed: false` and the right `data.newsletter_id`:

1. the unsubscribe link in a sent email,
2. RFC 8058 one-click `List-Unsubscribe-Post` (does not go through Portal or the Admin API),
3. toggling the newsletter off in Ghost Admin by hand.

Record each response as a test fixture. This requires a write to the production Ghost instance, so
**ask Hugh before doing it.**

If any path turns out to be silent, layer 3 is not authoritative for history. Note the residual risk
is bounded: the always-on observation leg writes an `observed` ledger entry for every currently
subscribed newsletter on every sweep, so anyone who unsubscribes **after** this ships is blocked by
layer 2 regardless. The exposure is only people who unsubscribed **before** shipping, and that set is
currently empty.

Live newsletter ids (2026-09-16, for orientation; do not hardcode): XXIX `6a21586e051a3d00085d2b9d`,
Index Space `6a691445819f720001082773`, Sanctuary Computer `6aa857adfe2ac60001f3e242`. The publisher
plan caps Ghost at 3 newsletters, so there is no garden3d newsletter yet.

## Design

### Prefix derivation

- `prefix(source) = source.split(":", 2).first.downcase`. `xxix:` -> `xxix`; `team` -> `team`; `G3D:foo` -> `g3d`.
- **Excluded namespace (critical):** sources equal to `g3d:ghost` or starting with `g3d:ghost:` are **never** used to derive subscriptions. They are Stacks' own record of Ghost opt-in state (written by the pull leg). Without this exclusion, mapping the `g3d` prefix would subscribe everyone who subscribed to any newsletter to the garden3d newsletter, a consent feedback loop. Define this exclusion next to `SOURCE_PREFIX` and test it explicitly.
- Only **enabled** sources participate: `targets(contact) = { map[prefix(s)] : s in contact.sources intersect enabled, s not excluded, map[prefix(s)] present }`. This matches how labels already work: disabling a source on the Ghost Sync page turns off both its label and its consent-driven subscriptions.

### Why the mapping key is the prefix and not the full source path

Considered and **deferred**: mapping any colon-path prefix of a source (`index:luma:chinatownjs`) to a *set* of newsletters, unioned across a contact's sources. The motivating case is Chinatown JS: Sanctuary Computer hosts it, but its source is `index:luma:chinatownjs`, so under prefix mapping those 84 people are Index Space subscribers and SC cannot own the send.

Rejected for now because the sync engine is nearly identical either way (everything downstream operates on a set of newsletter ids), while the admin UI roughly doubles: a 7-row single-select table becomes a ~25-row multi-select table needing an "inherited from `index`" display state, and "why was this person granted SC?" stops being answerable from one column.

Two escape hatches cover the need without code:

1. **Ghost label segments.** Publish the post, send it out of the Index Space newsletter, filter recipients to "Specific people" on the `index:luma:chinatownjs` label. The label is already in Ghost today. Cost: the email carries Index sender identity, and its unsubscribe link unsubscribes from Index Space.
2. **Write a second source.** A source *is* the consent record, so for a list SC genuinely co-owns, have whatever posts to `/api/contacts` emit `sanctu:luma:chinatownjs` alongside the index one. `sanctu:luma:family.intelligence` already exists, proving the caller can do this. The existing prefix map then does the rest and the consent story stays literally true. Backfilling the 84 existing rows is one statement.

If path mapping is ever needed, it is additive and non-breaking: a prefix key is the one-segment case of a path key, so `{"index" => "id"}` becomes `{"index" => ["id"]}` with no data migration.

### Configuration (System settings, Storext)

```ruby
ghost_newsletter_prefix_map     Hash,    default: {}      # lowercase prefix => Ghost newsletter id
ghost_newsletter_grants_enabled Boolean, default: false   # gates grants to EXISTING members only
ghost_sweep_write_budget        Integer, default: 2500    # Ghost member mutations per sweep
ghost_last_sync_summary         Hash,    default: {}      # last sweep counters + finished_at
```

Ships with an empty map. Hugh configures it in the admin UI. Given the **[runtime]** facts above, all
four of these are booby-trapped in the same way, so the rules are mandatory:

- **Read the flag through the predicate**, `ghost_newsletter_grants_enabled?`, never the bare reader.
  The bare reader returns `""` (truthy) for a blank stored value.
- **Clamp the budget on read**: `[ghost_sweep_write_budget.to_i, 1].max`. Storext will happily hand
  back `""` or `"abc"`, and `> 0` on those raises.
- **Never mutate the map in place.** Assign a whole hash. Read it **once** into a local at sweep start.
- **Read all four from a fresh `System.first_or_create!`** at the top of `sync_all!` (as the sweep
  already does at `ghost_sync.rb:39`), and in the admin page too. Never `System.instance`, which
  memoizes per puma worker forever.
- The sweep must also `reject { |_, v| v.blank? }` the map defensively, so a stored `""` can never be
  treated as a newsletter id.

### Data model: the ledger

`contacts.ghost_data["newsletter_ledger"]`:

```ruby
{ "member_id" => "<ghost member id this ledger describes>",
  "entries"   => { "<newsletter_id>" => { "state" => "granted"|"observed"|"history", "at" => iso8601 } } }
```

- **Write-once per newsletter id.** Entries are never removed or overwritten by the sweep.
- **Any entry blocks future grants** for that newsletter.
- `observed`: member was seen currently subscribed. `history`: Ghost events showed prior subscription
  activity while not currently subscribed. `granted`: this sync subscribed them.

**Why `member_id` is part of the ledger.** Consent lives on a Ghost *member*; the ledger lives on a
Stacks *Contact*, and the two are not one-to-one. `link_contact!` deliberately leaves case-fold
duplicate Contacts unlinked (`ghost_sync.rb:249-252`, an explicitly tested steady state at
`ghost_sync_test.rb:393-422`), so Contact B can resolve to Contact A's member via `members_by_email`
while carrying a permanently empty ledger -- layer 2 structurally disabled for B. `dedupe!` can also
leave a survivor accumulating `observed` entries describing a member it is not linked to. Therefore:

- A grant decision **must ignore layer 2 entirely** when `ledger["member_id"]` is present and does not
  equal the member the decision resolved, falling through to layer 3 alone.
- A contact whose `link_contact!` outcome was `link_conflicts` **must not drive grants at all** this
  sweep. An unlinked duplicate has no business changing subscriptions for a member another Contact owns.

**Ledger writes are in-memory only.** Every ledger write mutates the same in-memory
`contact.ghost_data` and is persisted by the single `update!` at the end of `sync_contact!`. **Never**
write the ledger with `update_column`, `update_all`, or raw jsonb SQL (the `record_source_events!`
pattern at `contact.rb:39-54` is the tempting model and is wrong here): `link_contact!` reconstructs
the whole `ghost_data` column from the in-memory hash (`ghost_sync.rb:238-239`) and would clobber any
out-of-band write microseconds later. `link_contact!` must be changed to merge onto the same
in-memory hash rather than an older copy, including in its steal branch (`:254`).

- **Merges must union ledgers.** Extend `Contact#dedupe!` and the `fresh_existing` path in
  `contact.rb` to union `newsletter_ledger["entries"]` across all merged contacts (earliest `at` wins),
  mirroring the existing `deleted_at` handling. Build a **new** hash rather than `merge!`-ing a
  loser's nested hash in place (`merged_ghost_data` is only a shallow `dup`, `contact.rb:185`).
  The merged `member_id` must be the **`ghost_id` owner's**, not the survivor's own. After a dedupe the
  survivor is linked to the merged `ghost_id`, so a ledger carrying any other member's id describes
  someone the contact is not linked to, and the grant decision then ignores the whole ledger.
- **`stacks:sync_contacts` must take the Ghost advisory lock** around its `Contact.all.each(&:dedupe!)`
  loop (`lib/tasks/stacks.rake:419`). Without it, `dedupe!` deletes a contact row mid-sweep and the
  sweep's ledger `update!` silently affects zero rows. Union-on-merge does not fix a lost update.
- `upsert_contact_from_member` merges only `snapshot`; keep it that way.

### Client additions (`Stacks::Ghost`)

- `find_member(id)`: `GET /members/:id/?include=labels,newsletters`.
- `newsletter_events_for(member_id)`: see below. It must implement the hardening rules, not just fetch.

### Hardening layer 3 (mandatory)

The events endpoint returns **200 with an empty list** for a nonexistent or malformed member id, so
"no events" is not evidence of "never subscribed" unless all of the following hold. Any failure means
**fail closed**: no grants for this member this sweep, `grant_errors += 1`, no ledger entries.

1. **Id format.** `member_id` must match `/\A[0-9a-f]{24}\z/` before the request is issued.
2. **Provenance.** Every returned event must have `data["member_id"] == member_id`. A mismatch means
   the filter did not bind as intended.
3. **Completeness.** Compare the number of collected events against `meta.pagination.total` for the
   query. Fewer collected than `total` means the history is truncated.
4. **Coherence (positive control).** A member currently subscribed to at least one newsletter **must**
   have at least one newsletter event. Verified live: all 52 members have events, none has zero. If
   the member has current subscriptions and the query returns zero events, the result is incoherent.
5. **`total` must be present.** `meta.pagination.total` is documented reliable, so its absence is
   itself evidence the response is not what we think it is. A missing `total` would otherwise skip
   guard 3 entirely and let an empty body read as "never subscribed".
6. **Existence probe on an empty history.** Guard 4 is **anticorrelated with the risk**: someone who
   deliberately unsubscribed from everything has zero current newsletters, so the coherence check is
   inert for precisely the people this feature protects, and their empty history is indistinguishable
   from a nonexistent or mistyped member id (which returns the same `200 {"events": []}`). So when the
   history comes back empty, positively confirm the member exists with `find_member`, and raise if it
   does not. This costs one extra GET only on an empty history, and only for contacts that have a
   mapped target at all.
7. **Type.** Every returned event must be `type == "newsletter_event"`. The type is filtered server
   side, but the same defence-in-depth that applies to `member_id` applies here.
8. **Shape.** A non-Hash body, a non-Hash event, or a non-Hash `data` raises `UntrustworthyHistory`,
   not `NoMethodError`, so one malformed member cannot take down the sweep.

Coerce `member_id` to a String immediately after the format check and use that value everywhere: the
guard validates `member_id.to_s` while the provenance check compares the raw object, so a Symbol would
otherwise pass validation and then fail provenance with a misleading message.

**Do not page. Issue exactly one request and fail closed above 100.**

Both `page` and `order` are silently ignored, so there is no way to walk this endpoint reliably: a
cursor scheme would have to assume an ordering the API will not honour or even report. Rather than
build a loop on an unfounded assumption, fetch one page of `limit: 100` and require
`collected.length == total`. If a member has more than 100 newsletter events, raise and let them fail
closed.

This is a deliberate, bounded trade: such a member can never be granted until handled by hand. It
takes more than 100 subscribe/unsubscribe toggles to reach, the live maximum today is **3**, and the
failure is counted in `grant_errors` so it is visible rather than silent. Guessing at an order would
risk collecting the wrong 100 events, reading "no event for N", and re-subscribing someone who opted
out. That is the failure this whole design exists to prevent.

Remaining rules:

- Pass quotes **raw**, never percent-encoded.
- Quote the member id the way `find_member_by_email` already does (`ghost.rb:55`). It is safe from
  injection because the format guard restricts it to hex, which is what the comment should say.
- `current_newsletter_ids:` is a **required** keyword argument. It must not default to `[]`: the
  coherence check is inert for an empty list, and that is exactly the population at risk (see below).

### Per-sweep write budget

At 18,980 contacts the sweep is one serial API call per contact with no batching. An unbounded first
sweep is ~19,000 `create_member` calls, which invites 429 storms (`Stacks::Ghost#backoff` sleeps
`2**n` up to 5 retries, so throttling compounds).

`ghost_sweep_write_budget` caps **Ghost member mutations per sweep**: every `create_member` and every
`update_member`, counted in `@summary[:writes_used]`. It lives as an instance variable
(`@writes_remaining`) set up in `sync_all!`, so the delabel loop (a *different* loop, `ghost_sync.rb:64-72`)
shares the same counter.

**The unit is one mutation, not one newsletter.** A contact with two candidate newsletters is a single
PUT and consumes a single unit. The budget check inside the per-newsletter grant loop is a
*reservation* check ("is at least one unit left?"); the decrement happens once, when the mutation is
issued. In dry-run mode the decrement happens once per member that ends the loop with at least one
candidate, so dry run and real run consume BUDGET identically. Their API costs differ and that is
fine: the real run additionally issues a `find_member` per granting contact, and a dry run can spend
a unit without issuing any call at all. It is budget consumption, not call count, that has to match,
because budget is what decides who gets deferred to the next sweep.
`creates_deferred`, `grants_deferred` and `updates_deferred` count **contacts**, not newsletters.

**Linked contacts are processed first, with their own reserved allowance.** The eligible-contact loop
is a single `find_each` in id order, so a naive shared budget would spend all 2,500 units on creates
for eight-plus sweeps and defer every grant decision on the 52 pre-existing members -- the only
population with real subscription history, and the only one the grants flag exists to protect. Rollout
step 5 asks Hugh to review exactly those numbers before flipping the toggle, and he would be reviewing
an empty report and reasonably reading it as "nothing to worry about". So: run
`Contact.synced_to_ghost` eligible contacts first against a reserved allowance, then creates against
the remainder.

Deferral is otherwise safe: it never grants and never writes a ledger entry, and the next sweep resumes
where this one stopped. Reword step 4 as writing no **new** ledger entry for the remaining targets --
a target that already hit step 1 earlier in the loop has legitimately written an `observed` entry.

**Reads are deliberately unbudgeted**, and the implementer should know the cost: a grant candidate
costs a `find_member` GET plus a single `newsletter_events_for` call. At a 2,500 unit
budget that is up to ~7,500 serial HTTP calls in a sweep. The pull leg is also unbudgeted and O(members):
after backfill, `all_members` is ~190 serial GETs holding ~19,000 member hashes in memory at once,
then ~19,000 `find_by` + `save!` + `record_source_events!` round trips. This is accepted, not solved.
Expect a full sweep to run in tens of minutes and to grow with member count.

### Sweep changes (`Stacks::GhostSync`)

**Per sweep, once:** read the four settings fresh, build the local prefix map, set `@writes_remaining`,
and resolve newsletter validity. **Load newsletters conditionally** -- `return {} if prefix_map.empty?`
-- and reuse the existing `@newsletter_slug_map` memo (`ghost_sync.rb:159-163`) rather than adding a
second fetch. An eager unconditional `all_newsletters` call would (a) add a Ghost API call to every
sweep even in the empty-map state this ships in, and (b) break roughly fifteen existing tests, which
use strict mocha `mock("ghost")` and would raise `unexpected invocation` -- one test asserts
`all_newsletters` is called `.never` (`ghost_sync_test.rb:40-42`). Drop map entries whose id is unknown
or whose newsletter is not active (count `grant_mapping_invalid`). **Verify the newsletter status field
name against a live payload before filtering on it**, and update the test fixture helper, which
currently emits no `status` key -- naive `n["status"] == "active"` filtering would drop every
newsletter in tests.

**Observation (always on, regardless of the grants flag):** in the pull leg, add an `observed` ledger
entry for each currently subscribed newsletter id not already in the ledger. Cheap, unbudgeted (it
writes to Stacks, not Ghost), and it is what makes layer 2 a real backstop for everyone who
unsubscribes after this ships.

**Control flow in `sync_contact!`.** The existing flow issues the label PUT first and unconditionally,
computing the label diff from the **stale snapshot** member. A combined write is impossible without
restructuring, and "one PUT per contact" and "label writes stay exactly as they are today" cannot both
hold literally. Resolve it as:

1. Extract a pure `label_attrs_for(contact, member, desired, enabled)` from `update_member_labels`,
   returning `attrs` or `nil` and issuing no request. Both paths below call it.
2. Compute `desired` labels and the grant candidates (steps 1-6 below).
3. **If there are candidates:** `find_member` for a fresh member, then re-run the layer-3 read against
   that fresh member, then recompute the label diff from the fresh member, then issue **one**
   `update_member` carrying `newsletters` (and `labels` when they differ). One budget unit.
4. **If there are no candidates:** fall through to today's `update_member_labels` unchanged.

`sync_contact!`'s public signature is unchanged; the map, flag, budget, newsletter validity and event
memo all live on the instance.

**The layer-3 read happens in the apply phase, immediately before the PUT -- not in the decision
phase, and it is never memoized across a write.** This matters: the spec's fresh GET was re-checking
only layer 1 ("is the member currently subscribed"), which does not disqualify a grant candidate,
since a candidate is by definition not currently subscribed. So a person who subscribed and then
unsubscribed during a multi-hour sweep would have been re-subscribed by a decision made hours
earlier. **No candidate may be carried across an API call boundary.** A per-member memo is allowed
only within one uninterrupted decision-plus-apply block.

**Grant decision for an existing member**, for each target newsletter N in `targets(contact)`:

1. Member currently subscribed to N -> ensure `observed` entry. No write.
2. Ledger has N (and the ledger's `member_id` matches this member) -> skip; count `already_handled`
   when the entry is `granted`/`observed`, `unsubscribe_respected` when it is `history`.
3. Member `email_suppression.suppressed` or `email_disabled` -> skip, no ledger entry; count
   `grant_skipped_undeliverable`, counted once per CONTACT (every other deferral counter counts
   contacts, so mixing units in one panel would misread).
4. **Budget reservation check.** Exhausted -> `grants_deferred += 1` for this contact, skip its
   remaining targets, no layer-3 read, no new ledger entry.
5. Layer-3 read, hardened as above. Any event for N -> add `history` entry; skip; count
   `unsubscribe_respected`. Any hardening failure or error -> skip all grants for this member this
   sweep; count `grant_errors`; no ledger writes.
6. Otherwise N is a grant candidate.

Implementation note: the undeliverable check runs before the ledger check rather than after.
Behaviourally identical (both skip without producing a candidate), but it means a suppressed member's
already-ledgered targets count as `grant_skipped_undeliverable` rather than `already_handled` or
`unsubscribe_respected`, very slightly deflating the numbers rollout step 6 reviews.

**Applying grants (only if `ghost_newsletter_grants_enabled?`):**

- PUT `newsletters: (fresh current ids union candidate ids).map { {id:} }`, plus labels if they differ.
  Never send `subscribed`.
- Confirm the response contains each candidate id; only then write `granted` entries. A failed write
  writes no ledger entries.
- Count `granted`, and per newsletter id in `@summary[:granted_by_newsletter]`. The create path counts
  separately, in `granted_on_create` and `@summary[:granted_on_create_by_newsletter]`: creates are not
  flag-gated and run up to the full budget per sweep, so folding them in would swamp the per-newsletter
  comparison rollout step 6 asks a human to make against `grants_planned_by_newsletter`. Both **must be
  initialized to `Hash.new(0)` in `initialize`** -- `@summary` is itself a `Hash.new(0)`, so lazy
  nesting raises `TypeError`.

When the flag is off, run steps 1-6 fully (ledger and history writes are safe) and count
`grants_planned` / `grants_planned_by_newsletter` without writing to Ghost. This is the dry run.

**Creating a new member** (no member matched, not suppressed by `snapshot.deleted_at`, budget available):

- **Always** send an explicit `newsletters` array: target newsletters minus anything already in the
  contact's ledger. Never omit the key.
- **Creates are NOT gated by `ghost_newsletter_grants_enabled?`.** A create only happens when no Ghost
  member matched by `ghost_id` or email, so there is no member history and the invariant cannot be
  violated. The one hole -- a member we failed to match -- lands in the 422 adopt path, which is gated
  and does run layer 3.
- **Write `granted` entries only for ids present in the create response's `newsletters`**, not for what
  was sent. `create_member` already requests `include=labels,newsletters` (`ghost.rb:73`), so this is
  free. A ledger entry is write-once and blocks grants forever; if Ghost silently drops a newsletter
  (archived mid-sweep, plan cap), writing `granted` from the request would permanently block the
  legitimate grant with no repair path.
- **Insert the created or adopted member into `members_by_email`** (keyed by
  `member["email"].to_s.downcase`) as well as `members_by_id`. Today only the id index is updated
  (`ghost_sync.rb:59-60`). `contacts` does have a unique index on `email`, but it is **case
  sensitive**, so `Foo@x.com` and `foo@x.com` coexist -- which is exactly why `dedupe!` matches on
  `LOWER(email)` and why `link_contact!` has a case-fold branch. Both rows key to the same
  `members_by_email` entry, so in one sweep the first creates and the second 422s into the adopt path,
  burning an extra POST, a `find_member_by_email`, a layer-3 read, and a second budget unit for the
  same human. "Creates are idempotent by email" is true across sweeps, not within one.
- The 422 adopt path routes through the existing-member decision above, including layer 3 and the flag.

**Never, in any path:** remove a subscription; write `newsletters` without a fresh GET immediately
prior in the same code path; write `newsletters` from the no-candidate label path or `delabel_member!`.

**Summary persistence:** write counters plus `finished_at` to `System#ghost_last_sync_summary`,
including the per-newsletter breakdowns, **incrementally** (every N contacts and in an `ensure`), not
only at the end of `sync_all!`. A sweep killed by rack-timeout or a dyno restart must still leave
reviewable counters, because the rollout's review gate reads this panel. Stringify keys on the way in
(the column is jsonb, `@summary` has symbol keys) and note that `summary.to_h` carries a default proc
into logs and the flash.

### Admin UI (Ghost Sync page)

UI copy must not use em dashes. Arbre registers `select`/`option` as builder tags, so a dropdown table
works in the existing `ActiveAdmin.register_page` idiom.

- **One form**, posting to a single new `page_action :update_newsletter_settings, method: :post`,
  carrying `prefix_map[<prefix>]`, `grants_enabled`, and `write_budget`, with the manual
  `authenticity_token` hidden input the existing form already uses.
- **Param normalization, exactly:**
  - map: `params.fetch(:prefix_map, {}).to_unsafe_h.transform_values(&:to_s).reject { |_, v| v.blank? }`
    (assigning `ActionController::Parameters` directly raises). "Not mapped" means the key is **absent**.
  - flag: `ActiveModel::Type::Boolean.new.cast(params[:grants_enabled])`, with the checkbox's hidden
    companion input set to `value: "0"` -- **never** `""`.
  - budget: `params[:write_budget].presence&.to_i`, clamped to `>= 1`.
  - selected option: `selected: (current == id) || nil`, matching the existing checkbox idiom.
- **Synced Sources panel (existing, extended):** add a Newsletter column per row showing what that
  source's prefix resolves to, or "No newsletter (members created with no subscription)". This
  surfaces an ordering footgun: because the map ships empty, checking `index:*` before mapping `index`
  creates 12k members subscribed to nothing, which then become *existing* members whose subscriptions
  are flag-gated, turning a one-pass rollout into two by accident.
- **Newsletter Mapping panel:** one row per distinct prefix from `Contact.sources`, **excluding the
  `g3d:ghost` namespace** (so the `g3d` row's count does not include contacts whose only `g3d` source
  is `g3d:ghost:*`), with contact counts and a dropdown of active newsletters plus "Not mapped".
- **Grants toggle** and **write budget** number field, with plain copy.
- **Impact preview** per mapped row: "Next sync may subscribe up to N contacts", where N counts
  contacts with an enabled source under that prefix (same `g3d:ghost` exclusion) and no ledger entry
  for the target newsletter id. Write the SQL once so the panel and `targets` cannot drift:
  `where("NOT jsonb_exists(ghost_data->'newsletter_ledger'->'entries', ?)", newsletter_id)`.
  **Do not use `??`** -- ActiveRecord 6.1 has no such escape and it raises with a bind.
- **Last sweep summary panel** reads `System#ghost_last_sync_summary` from a fresh read, not
  `System.instance`, which would serve a value cached at worker boot essentially forever.
- **Contact show page, Ghost panel:** add a row listing ledger entries (newsletter name, state, date).

### Out of scope

- **Cleaning up existing over-subscriptions.** The 52 current members were subscribed to all three newsletters by `subscribe_on_signup`. This feature never unsubscribes, so it does not fix that. See "Decision for Hugh" below; implement only if approved, as a separate task.
- **Path-level newsletter mapping** (see "Why the mapping key is the prefix"). Deferred, additive later.
- Changing Ghost's `subscribe_on_signup` setting (it will no longer affect synced members; it still affects Portal signups).
- A garden3d newsletter (blocked on the Ghost plan's 3-newsletter cap). When one exists, mapping `g3d` to it is a config change. Note the higher Ghost Pro tier may lift the cap.
- Per-list unsubscribe. Ghost's unsubscribe link operates on a newsletter, and there are only 3.
- Webhooks (the sync remains sweep-only).
- Batching or parallelising the sweep's per-contact API calls. The write budget bounds the blast radius instead.

## Tests (minitest, stubbed client)

The suite uses strict mocha `mock("ghost")`, so any un-stubbed client call raises `unexpected
invocation`. **Update every existing `sync_all!` test to stub the new calls** it now reaches, and keep
`ghost_sync_test.rb:40-42`'s `all_newsletters` -> `.never` assertion meaningful by making the load
conditional. Extend the `member(...)` fixture helper with a `status` key for newsletters, and add an
`events(...)` helper producing the real `newsletter_event` shape from the captured payload above.

Prefix + targets:
- `index:luma:chinatown` -> `index`; `xxix:` -> `xxix`; `team` -> `team`; uppercase normalized.
- `g3d:ghost` and `g3d:ghost:index` never produce targets even when `g3d` is mapped.
- Disabled sources produce no targets; unmapped prefixes produce no targets.
- A map value of `""` produces no target (blank-reject).

Grant decisions (each asserts whether `update_member`/`create_member` was called with `newsletters`):
- Never-subscribed member with a mapped source -> granted after fresh GET; `granted` ledger entry.
- Currently subscribed -> no write; `observed` entry.
- Ledger entry present -> no write, no events call.
- Ghost history has an unsubscribe event for N -> no write; `history` entry written.
- History has an event for a **different** newsletter only -> grant proceeds for N.
- Events API raises -> no grants, no ledger entries, `grant_errors` incremented, sweep continues.
- Write sends current union new ids (existing subscriptions preserved).
- Contact gains a second `xxix:*` source after unsubscribing from XXIX -> still no grant.
- Contact with `index:*` (subscribed) gains `xxix:foo` -> XXIX granted, Index untouched.
- Suppressed / email_disabled member -> skipped, no ledger entry.
- Mapping to archived or unknown newsletter -> ignored, counted.
- Flag off -> identical decisions, ledger/history writes happen, zero `newsletters` writes,
  `grants_planned` counted.
- Contact with two candidate newsletters -> one `update_member` carrying both ids, one budget unit.

Layer-3 hardening (each must assert **no** `newsletters` write):
- Events call returns **200 with an empty list** for a member that currently has subscriptions
  (incoherent) -> fail closed, `grant_errors`.
- Events returned carry a different `data["member_id"]` -> fail closed.
- Collected events fewer than `meta.pagination.total` -> fail closed.
- Member id not matching `/\A[0-9a-f]{24}\z/` -> no request issued, fail closed.
- Events read returns no XXIX event on the decision-phase call and an XXIX unsubscribe on the
  pre-PUT call -> **no write** (proves the read is not memoized across the write).

Create path:
- New member created with explicit `newsletters` = targets; key always present.
- Created with mapped newsletters **even when the grants flag is off**.
- Contact whose ledger already has a target -> that newsletter is subtracted from the create.
- Contact with only unmapped-prefix sources -> created with `newsletters: []`.
- Create response omits a requested newsletter -> **no** `granted` entry for it.
- Two Contact rows differing only in email case, both eligible and unlinked -> exactly one
  `create_member` call (proves `members_by_email` is updated after a create).
- 422 adopt path runs layer 3 and respects the grants flag.

Ledger integrity:
- Case-fold duplicate contact resolving to another contact's member issues no `newsletters` write.
- Ledger whose `member_id` does not match the resolved member -> layer 2 ignored, layer 3 consulted.
- A contact that receives a `history` entry **and** needs a label update retains the `history` entry
  after `sync_all!` (guards the `link_contact!` clobber).
- `dedupe!` unions ledger entries from all dupes regardless of which owns `ghost_id`.
- `fresh_existing` merge path unions entries in both directions; earliest `at` wins on conflict.

Write budget:
- Budget of 1 with 3 creatable contacts -> one create, two `creates_deferred`, no links or ledger
  entries for the deferred pair.
- Deferred contact is created on the next sweep. **Instantiate a second `Stacks::GhostSync`** against
  the same stubbed client (use `stubs(:all_members)`, not `expects`, so it answers twice) -- the budget
  lives on the instance, so re-calling `sync_all!` on the same object reuses the exhausted counter.
- Budget exhausted before a grant candidate -> no layer-3 read issued, `grants_deferred` incremented.
- Budget binds identically with the grants flag off.
- Budget exhausted -> label-only updates deferred, `updates_deferred` incremented.
- Linked contacts get their reserved allowance even when creates would otherwise exhaust the budget.

Settings coercion (these are the silent-failure cases):
- Grants flag saved from a form with the checkbox absent stores `false`, and the sweep writes no
  newsletters (guards the `""`-is-truthy trap).
- A blank or zero budget falls back to `>= 1` rather than raising.
- Prefix map saved from form params (an `ActionController::Parameters`) persists correctly.
- The sweep honours a setting changed in the DB behind a memoized `System.instance`.

Unchanged-behavior guards:
- The no-candidate label path and delabeling never include `newsletters`.
- Pull leg writes `observed` entries without touching `snapshot` semantics.
- An empty prefix map issues no `all_newsletters` call.

Summary persistence:
- Counters and `finished_at` are written to `System#ghost_last_sync_summary`, and are present even
  when the sweep aborts partway (the `ensure` path).

## Rollout

Order matters. Map first, then enable sources. **Drive the rollout with `rake ghost:sync` from a
one-off dyno, not the "Sync Now" button** -- that button runs the whole sweep inline in a web request
(`app/admin/ghost_sync.rb:58`) against `rack-timeout` (15s) and puma's `worker_timeout 60`, so a
2,500-write sweep is killed long before it finishes. The button stays useful for small incremental
sweeps once the backfill is done.

1. Merge with grants disabled, an empty prefix map, and a 2,500 write budget. Nothing changes yet,
   because no new source is enabled.
2. Complete the **blocking pre-implementation verification** (does an unsubscribe write a readable
   event?) before trusting layer 3 for historical consent.
3. Hugh sets the prefix map: expected `index` -> Index Space, `sanctu` -> Sanctuary Computer,
   `xxix` -> XXIX, and a decision on `team`. Leave `g3d` and `usb_club` unmapped for now.
   **Never map or enable `etl`.**
4. Hugh checks the sources to sync. The Newsletter column confirms each will land in the right place.
   All five brand prefixes is 18,980 contacts against 52 members today.
5. Run `rake ghost:sync` repeatedly (or let the daily task ramp). Each sweep creates up to 2,500
   members, correctly subscribed on creation because creates are not flag-gated. Watch
   `creates_deferred` fall to zero across sweeps.
6. Review the Last Sweep Summary panel for the 52 pre-existing members: `grants_planned` per
   newsletter, `unsubscribe_respected`, `grant_errors`. Because linked contacts get a reserved
   allowance, these numbers are meaningful from the very first sweep rather than after the ramp.
   Spot-check a few contacts' ledgers on the contact show page.
7. Hugh flips the grants toggle and runs `rake ghost:sync`. Confirm `granted` matches the prior
   `grants_planned`.
8. Update the 2026-07-20 design doc's ownership table: the opt-in row becomes "Stacks grants a
   newsletter once per member, derived from sources; Ghost is authoritative for revocation; stacks
   never unsubscribes or re-subscribes." **Also correct that doc's claim** that "the sweep is the only
   Ghost writer and always runs in fresh rake dynos" -- the admin button runs it in a web dyno.

`g3d` (3,495) and `usb_club` (814) sync as labeled members with `newsletters: []`. When a newsletter
exists for them, mapping the prefix subscribes them on following sweeps under rule 4, bounded by the
budget. Expect the pull leg to then add a `g3d:ghost:<slug>` source and a `source_events` row for each
newly subscribed member -- a sync-granted subscription recorded as a funnel event. That is existing
behavior, called out here so it is not mistaken for a bug.

## Decision for Hugh (not part of this implementation)

The 52 existing members are subscribed to all three newsletters regardless of source. Under the consent model, most of those subscriptions have no backing source. Options:

- **A. Leave them.** Simplest; people unsubscribe per brand as they choose.
- **B. One-time cleanup task** (dry run first, Hugh reviews the report, then apply): remove subscription to N only when **all** of these hold: the contact has no enabled source mapping to N, and every `subscribed: true` event for N in the member's history has `source: "api"` (i.e. the sync or an API opt-in did it, never the person via Portal or an admin by hand). Removal would be a one-off, logged action and never part of the recurring sweep.

At 52 members, B is small and reviewable. Recommendation: B, with the dry-run report reviewed before applying.
