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

Layer 3 is authoritative and covers everything that happened before this feature shipped. Layer 2 is a cache and defense-in-depth (and avoids re-querying history daily for people who unsubscribed). If layer 3 cannot be read for any reason, **fail closed**: no grant.

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

Checked against Ghost core source, the live API, and the installed gems on 2026-09-16.

| Fact | Evidence | Consequence |
|---|---|---|
| Create with **no** `newsletters` key subscribes to all `subscribe_on_signup` newsletters | `member-repository.js`: `if (memberData.subscribed !== false && !memberData.newsletters)` | Create must **always** send an explicit `newsletters` array. |
| Create with `newsletters: []` subscribes to **nothing** | Same check; `[]` is truthy in JS | Safe way to create a member with no subscriptions. |
| `newsletters` on member edit is a **full replace** (`newslettersToRemove = existing - incoming`) | `member-repository.js` edit path | Every write must send current subscriptions union additions, computed from a **fresh** GET. Never send `subscribed`. |
| Member event history is readable by the integration token | `GET /ghost/api/admin/members/events/?filter=type:newsletter_event+data.member_id:<id>` returned 200 | Usable as the authoritative "ever subscribed" check. |
| Events **cannot** be filtered by `data.subscribed` | Returns 400 "Cannot filter by data.subscribed" | Fetch a member's newsletter events and inspect them in Ruby. |
| Member payloads embed newsletters by id/name without slug | Existing comment in `ghost_sync.rb` | Key everything by newsletter **id**, never slug (XXIX's slug is `default-newsletter`). |
| Ghost can send one post to a newsletter filtered to "Specific people" by label | ghost.org/help/email-newsletters, ghost.org/changelog/member-labels | Sub-brand lists are reachable today with zero code, because the sync already writes every enabled source as a verbatim label. |
| Storext 3.3.0 (Virtus-backed) supports `Hash`, `Boolean`, `Integer` with defaults; `Boolean` coerces `"1"` to `true` | Verified by running Virtus directly against the app bundle | Config below can use these types as written. `"1"` coercion matters for checkbox params. |

Verify the exact shape of `event.data` (expect `data.newsletter.id`, `data.subscribed`, `data.created_at`) against a real response before relying on it, and record the shape in a test fixture.

Live newsletter ids (2026-09-16, for orientation; do not hardcode): XXIX `6a21586e051a3d00085d2b9d`, Index Space `6a691445819f720001082773`, Sanctuary Computer `6aa857adfe2ac60001f3e242`. The publisher plan caps Ghost at 3 newsletters, so there is no garden3d newsletter yet.

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
ghost_last_sync_summary         Hash,    default: {}      # last sweep's counters + finished_at
```

Ships with an empty map. Hugh configures it in the admin UI.

### Data model: the ledger

`contacts.ghost_data["newsletter_ledger"]`: `{ "<newsletter_id>" => { "state" => "granted" | "observed" | "history", "at" => iso8601 } }`

- **Write-once per newsletter id.** Entries are never removed or overwritten by the sweep.
- **Any entry blocks future grants** for that newsletter.
- `observed`: member was seen currently subscribed. `history`: Ghost events showed prior subscription activity while not currently subscribed. `granted`: this sync subscribed them.
- **Merges must union ledgers.** `Contact#dedupe!` and the `fresh_existing` merge path in `contact.rb` currently carry `ghost_data` from a single owner, with special handling to preserve `snapshot.deleted_at` in any merge direction. Extend both paths to union `newsletter_ledger` across all merged contacts (earliest `at` wins on conflict). A lost ledger entry could re-subscribe someone who unsubscribed; add tests for both merge directions mirroring the existing `deleted_at` tests.
- `upsert_contact_from_member` merges only `snapshot`; make sure no writer replaces `ghost_data` wholesale and drops the ledger.

### Client additions (`Stacks::Ghost`)

- `find_member(id)`: `GET /members/:id/?include=labels,newsletters`.
- `newsletter_events_for(member_id)`: `GET /members/events/?filter=type:newsletter_event+data.member_id:<id>&limit=100`. If exactly 100 are returned, page back in time (e.g. add `+data.created_at:<'<oldest>'` to the filter) until fewer come back. Returns raw events.

### Per-sweep write budget

At 18,980 contacts the sweep is one serial API call per contact with no batching. An unbounded first sweep is roughly 19,000 `create_member` calls inside `stacks:daily_enterprise_tasks`, which invites 429 storms (`Stacks::Ghost#backoff` sleeps `2**n` up to 5 retries, so throttling compounds).

`ghost_sweep_write_budget` caps **Ghost member mutations per sweep**: every `create_member` and every `update_member` the sweep would make, counted in `@summary[:writes_used]`.

**The unit is one mutation, not one newsletter.** A contact with two candidate newsletters is a single PUT and consumes a single unit. So the budget check inside the per-newsletter grant loop is a *reservation* check ("is at least one unit left?"), and the decrement happens once, when the mutation is actually issued. In dry-run mode the decrement happens once per member that ends the loop with at least one candidate, so dry run and real run consume budget identically. `creates_deferred` and `grants_deferred` are likewise counted per contact, not per newsletter.

When the budget is exhausted:

- Create path: defer the contact entirely. `creates_deferred += 1`, return nil, **no** `link_contact!`, no ledger write.
- Grant path: skip grants for this contact. `grants_deferred += 1`, no history read, no ledger write.
- Label-only update or delabel: skip. `updates_deferred += 1`.

Deferral is always safe: it never grants and never writes a ledger entry, and the next sweep picks up exactly where this one stopped (creates are idempotent by email, links and ledgers persist). At the default 2,500 the initial backfill ramps over roughly eight daily sweeps, or as many "Sync Now" clicks as Hugh cares to make.

**The budget binds in dry-run mode too.** When `ghost_newsletter_grants_enabled` is off, a *planned* grant consumes budget exactly as a real one does, and the budget is checked **before** the history read. This keeps the dry run's shape and API cost identical to the real run, and it bounds the expensive future case: mapping `g3d` to a garden3d newsletter would otherwise make 3,495 members grant candidates in a single sweep, each needing a history fetch.

The budget must be at least 1. To effectively disable it, set it very high.

### Sweep changes (`Stacks::GhostSync`)

**Per sweep, once:** load `enabled`, the prefix map, the write budget, and `all_newsletters`. Drop map entries whose id is unknown or whose newsletter is not `active` (count `grant_mapping_invalid`, log it). Grants to archived newsletters are impossible and must not be attempted.

**Observation (always on, regardless of the grants flag):** in the pull leg, for every member, add an `observed` ledger entry for each currently subscribed newsletter id not already in the ledger. This is cheap, unbudgeted (it writes to Stacks, not Ghost), and keeps layer 2 current for every linked contact.

**Grant decision for an existing member** (inside `sync_contact!`, for eligible contacts), for each target newsletter N in `targets(contact)`:

1. Member currently subscribed to N -> ensure `observed` entry. No write.
2. Ledger has N -> skip; count `unsubscribe_respected`.
3. Member `email_suppression.suppressed` or `email_disabled` -> skip, no ledger entry (retried naturally if that changes); count `grant_skipped_undeliverable`.
4. **Budget reservation check** (at least one mutation unit left). Exhausted -> `grants_deferred += 1` for this contact, skip all of its targets, no history read, no ledger entry.
5. Fetch `newsletter_events_for(member)` (at most once per member per sweep, memoized). Any event for N -> add `history` entry; skip; count `unsubscribe_respected`. On any error -> skip all grants for this member this sweep; count `grant_errors`; **no** ledger writes.
6. Otherwise N is a grant candidate.

**Applying grants (only if `ghost_newsletter_grants_enabled`):**

- Re-fetch the member with `find_member` **immediately before writing** (the sweep's `all_members` snapshot can be minutes old; someone may have unsubscribed since). Re-evaluate step 1 against the fresh member.
- PUT `newsletters: (fresh current ids union candidate ids).map { {id:} }`. If labels also need updating, include them in the same PUT computed from the fresh member. Never send `subscribed`.
- Confirm the response contains each candidate id; only then write `granted` entries. A failed write writes no ledger entries.
- Count `granted`, and per newsletter id in a `grants_by_newsletter` reader.

When the flag is **off**, run steps 1 to 6 fully (including history reads and ledger writes, which are safe) and count `grants_planned` (plus `grants_planned_by_newsletter`) without writing to Ghost. This is the dry run.

**Creating a new member** (no member matched, not suppressed by `snapshot.deleted_at`, budget available):

- **Always** send an explicit `newsletters` array: the contact's target newsletters minus any already in its ledger. Never omit the key (omitting it re-triggers `subscribe_on_signup`).
- **Creates are NOT gated by `ghost_newsletter_grants_enabled`.** The flag exists to protect people who may have opted out, and a create only happens when no Ghost member matched by `ghost_id` **or** email, so there is no member history and the core invariant cannot be violated. The one hole, a member we failed to match, lands in the 422 path below, which is gated and does run the history check. Subtracting the ledger is free defense in depth.
- A brand-new member has no Ghost history, so no events call is needed; on success write `granted` entries for what was sent.
- The existing 422 "already exists" path adopts an existing member: route it through the existing-member grant decision above, including the history check and the flag. Do not treat an adopted member as new.

**Never, in any path:** remove a subscription; write `newsletters` without a fresh GET in the same code path; write `newsletters` from `update_member_labels` or `delabel_member!` (label-only writes stay exactly as they are today).

**Summary persistence:** at the end of `sync_all!`, write the counters plus `finished_at` to `System#ghost_last_sync_summary`. Include `grants_by_newsletter` and `grants_planned_by_newsletter`. The summary is a `Hash.new(0)` with symbol keys and the column is jsonb, so stringify keys on the way in and read them as strings in the admin panel. Without this, the daily cron's numbers are invisible; today they only reach a flash notice on the manual button.

### Admin UI (Ghost Sync page)

UI copy must not use em dashes.

- **Synced Sources panel (existing, extended):** add a "Newsletter" column per row showing the newsletter that source's prefix resolves to, or "No newsletter (members created with no subscription)". This surfaces an ordering footgun: because the map ships empty, checking `index:*` before mapping `index` would create 12k members subscribed to nothing, which then become *existing* members whose subscriptions are flag-gated, turning a one-pass rollout into two by accident.
- **Newsletter Mapping panel (new):** one row per distinct prefix derived from `Contact.sources` (excluding the `g3d:ghost` namespace), with contact counts and a dropdown of active Ghost newsletters (by name) plus "Not mapped". Save writes `ghost_newsletter_prefix_map`.
- **Grants toggle** for `ghost_newsletter_grants_enabled`, with plain copy explaining that turning it on subscribes existing contacts to mapped newsletters they have never been subscribed to.
- **Write budget** number field for `ghost_sweep_write_budget`, with copy explaining that work past the budget is deferred to the next sweep.
- **Impact preview:** each mapped prefix row shows "Next sync may subscribe up to N contacts", where N counts contacts with an enabled source under that prefix and no ledger entry for the target newsletter id (`NOT (ghost_data->'newsletter_ledger' ? '<id>')`). Gotcha: jsonb's `?` operator collides with ActiveRecord's bind placeholder, so write it as `??` in any string passed to `where`, or use `jsonb_exists(...)` instead. Adding or changing a mapping means the next sweep may subscribe everyone with that prefix who has never had that newsletter. That is intended (rule 4), but show it.
- **Last sweep summary panel** reads `System#ghost_last_sync_summary`, so a dry run shows `grants_planned` per newsletter, `unsubscribe_respected`, `grant_errors`, and the deferred counters before Hugh flips the toggle.
- **Contact show page, Ghost panel:** add a row listing ledger entries (newsletter name, state, date) alongside the existing Newsletters / Suppressed / Email Disabled rows.

### Out of scope

- **Cleaning up existing over-subscriptions.** The 52 current members were subscribed to all three newsletters by `subscribe_on_signup`. This feature never unsubscribes, so it does not fix that. See "Decision for Hugh" below; implement only if approved, as a separate task.
- **Path-level newsletter mapping** (see "Why the mapping key is the prefix"). Deferred, additive later.
- Changing Ghost's `subscribe_on_signup` setting (it will no longer affect synced members; it still affects Portal signups).
- A garden3d newsletter (blocked on the Ghost plan's 3-newsletter cap). When one exists, mapping `g3d` to it is a config change. Note the higher Ghost Pro tier may lift the cap.
- Per-list unsubscribe. Ghost's unsubscribe link operates on a newsletter, and there are only 3.
- Webhooks (the sync remains sweep-only).
- Batching or parallelising the sweep's per-contact API calls. The write budget bounds the blast radius instead.

## Tests (minitest, stubbed client)

Prefix + targets:
- `index:luma:chinatown` -> `index`; `xxix:` -> `xxix`; `team` -> `team`; uppercase normalized.
- `g3d:ghost` and `g3d:ghost:index` never produce targets even when `g3d` is mapped.
- Disabled sources produce no targets; unmapped prefixes produce no targets.

Grant decisions (each asserts whether `update_member`/`create_member` was called with `newsletters`):
- Never-subscribed member with a mapped source -> granted after fresh GET; `granted` ledger entry.
- Currently subscribed -> no write; `observed` entry.
- Ledger entry present (member unsubscribed) -> no write, no events call.
- No ledger entry, but Ghost history has an unsubscribe event for N -> no write; `history` entry written.
- History has an event for a **different** newsletter only -> grant proceeds for N.
- Events API raises -> no grants, no ledger entries, `grant_errors` incremented, sweep continues.
- Member unsubscribed between sweep snapshot and fresh GET -> no write.
- Write sends current union new ids (existing subscriptions preserved).
- Contact gains a second `xxix:*` source after unsubscribing from XXIX -> still no grant.
- Contact with `index:*` (subscribed) gains `xxix:foo` (never had XXIX) -> XXIX granted, Index untouched.
- Suppressed / email_disabled member -> skipped, no ledger entry.
- Mapping to archived or unknown newsletter -> ignored, counted.
- Flag off -> identical decisions, ledger/history writes happen, zero `newsletters` writes, `grants_planned` counted.

Create path:
- New member created with explicit `newsletters` = targets; key always present.
- **New member created with mapped newsletters even when the grants flag is off.**
- New member whose contact already has a ledger entry for a target -> that newsletter is subtracted from the create.
- Contact with only unmapped-prefix sources -> created with `newsletters: []`.
- 422 adopt path runs the history check and respects the grants flag.

Write budget:
- Budget of 1 with 3 creatable contacts -> one create, two `creates_deferred`, no links or ledger entries for the deferred pair.
- Deferred contact is created on the next sweep (run the sync twice against the same stub).
- Budget exhausted before a grant candidate -> no history read is issued, `grants_deferred` incremented.
- Budget binds identically with the grants flag off (a planned grant consumes budget).
- Budget exhausted -> label-only updates are deferred too, `updates_deferred` incremented.
- Contact with two candidate newsletters -> one `update_member` call carrying both ids, one budget unit consumed.

Unchanged-behavior guards:
- Label-only updates and delabeling never include `newsletters` (update the existing "never writes newsletters" test so it still covers the label path).
- Pull leg writes `observed` entries without touching `snapshot` semantics.

Merges:
- `dedupe!` unions ledgers from all dupes regardless of which dupe owns `ghost_id`.
- `fresh_existing` merge path unions ledgers in both directions.
- Earliest `at` wins when both sides hold an entry for the same newsletter.

Summary persistence:
- `sync_all!` writes counters and `finished_at` to `System#ghost_last_sync_summary`.

## Rollout

Order matters. Map first, then enable sources.

1. Merge with `ghost_newsletter_grants_enabled = false`, an empty prefix map, and a 2,500 write budget. Nothing changes yet, because no new source is enabled.
2. Hugh sets the prefix map on the Ghost Sync page: expected `index` -> Index Space, `sanctu` -> Sanctuary Computer, `xxix` -> XXIX, and a decision on `team`. Leave `g3d` and `usb_club` unmapped for now. **Never map or enable `etl`.**
3. Hugh checks the sources to sync. The Newsletter column confirms each will land in the right place. Enabling all five brand prefixes is 18,980 contacts against 52 members today.
4. Run "Sync now" repeatedly, or let the daily task ramp. Each sweep creates up to 2,500 members, correctly subscribed on creation because creates are not flag-gated. Watch `creates_deferred` fall to zero across sweeps.
5. Review the summary for the 52 pre-existing members: `grants_planned` per newsletter, `unsubscribe_respected`, `grant_errors`. Spot-check a few contacts' ledgers on the contact show page.
6. Hugh flips the grants toggle and runs "Sync now". Confirm `granted` matches the prior `grants_planned`.
7. Update the 2026-07-20 design doc's ownership table: the opt-in row becomes "Stacks grants a newsletter once per member, derived from sources; Ghost is authoritative for revocation; stacks never unsubscribes or re-subscribes."

`g3d` (3,495) and `usb_club` (814) sync as labeled members with `newsletters: []`. When a newsletter exists for them, mapping the prefix subscribes them on the following sweeps under rule 4, bounded by the write budget.

## Decision for Hugh (not part of this implementation)

The 52 existing members are subscribed to all three newsletters regardless of source. Under the consent model, most of those subscriptions have no backing source. Options:

- **A. Leave them.** Simplest; people unsubscribe per brand as they choose.
- **B. One-time cleanup task** (dry run first, Hugh reviews the report, then apply): remove subscription to N only when **all** of these hold: the contact has no enabled source mapping to N, and every `subscribed: true` event for N in the member's history has `source: "api"` (i.e. the sync or an API opt-in did it, never the person via Portal or an admin by hand). Removal would be a one-off, logged action and never part of the recurring sweep.

At 52 members, B is small and reviewable. Recommendation: B, with the dry-run report reviewed before applying.
