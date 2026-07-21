# Ghost ↔ Stacks Contact Sync — Design

**Date:** 2026-07-20
**Status:** Approved (approach + sections 1–2 reviewed with Hugh; remainder self-reviewed per his delegation)

## Goal

Keep stacks contacts in sync with Ghost (garden3d.ghost.io, Ghost(Pro) Publisher tier) so that:

1. Opt-in contacts in stacks appear as Ghost members, segmented by **labels**, so email campaigns can be targeted per segment from Ghost.
2. People who sign up directly on Ghost flow back into the stacks contacts funnel with proper `sources` + `source_events`.

## Architecture: full-state reconciliation (Approach A)

A scheduled sweep (`rake ghost:sync`, Heroku Scheduler every 10 min, plus an admin "Sync now" button) pulls **all** Ghost members and all sync-eligible contacts, computes desired state per person, and applies the diff in both directions. **The sweep is the only transport** — no webhooks. (Ghost webhooks were originally in scope as a latency optimization, but their 2s delivery timeout and lack of retries meant the sweep had to be fully correct on its own anyway; per Hugh 2026-07-21 they were removed entirely. Signup latency is at most one sweep interval, ~10 minutes.) Any Ghost-side change is picked up by the next sweep.

Scale assumption: newsletter-sized lists (thousands, not millions). A paginated full sweep is seconds of work. If that ever changes, `filter=updated_at:>cursor` delta-sync can be layered on without changing semantics.

## Ownership rules (the core invariants)

| Fact | Authority | Consequence |
|---|---|---|
| Segmentation (labels named after enabled sources) | **stacks** | Label names are the source names **verbatim** (no prefix). The managed label set = the enabled sources (`System.settings.ghost_synced_sources`); the sweep enforces that a synced member carries exactly the enabled sources its contact has. Labels outside the enabled set — hand-added in Ghost, or belonging to a since-unchecked source — are never touched. Caveat: a hand-added Ghost label that happens to equal an enabled source name is adopted as managed. |
| Opt-in state (newsletter subscriptions) | **Ghost** | We set newsletters only implicitly at member **creation** (Ghost's `subscribe_on_signup` default). We never write `newsletters` on update and never re-subscribe anyone. |
| Deliverability (`email_suppression`, `email_disabled`) | **Ghost** (read-only) | Snapshotted into `ghost_data` for visibility; never written. |
| Contact email | **stacks** | Email changes made in Ghost do NOT mutate `contact.email` (unique key + dedupe machinery). Mismatch recorded in `ghost_data.email_in_ghost` and surfaced in admin. |
| Member existence | shared | Stacks creates members for eligible contacts; stacks **never deletes** Ghost members (a contact losing eligibility only loses its managed labels). Ghost deleting a member keeps the stacks contact (clears `ghost_id`, stamps `snapshot.deleted_at`) — detected by the sweep (any linked contact whose member is absent from the full fetch). **Deletion sticks**: a contact with `snapshot.deleted_at` is never re-created in Ghost (deletion is the strongest opt-out); if the person signs up on Ghost again, the fresh member match clears `deleted_at` automatically and sync resumes. |

## 1. Data model & configuration

**Migration — contacts:**
- `ghost_id` string, unique index. Stable join key (Ghost emails are mutable). Set on first push or first inbound event.
- `ghost_data` jsonb, default `{}`, null: false. Contents:
  - `snapshot`: Ghost-owned state for admin visibility — `{newsletters: [slugs], suppressed: bool, email_disabled: bool, email_in_ghost: "...", deleted_at: ts}`.
  - `synced_at`: last successful outbound write.

  (No pushed-state "fingerprint" is stored: outbound needs-update checks compare desired labels against the freshly fetched member, and inbound echo suppression falls out of upsert idempotence — see §4.)

**Enabled sources** live on the `System` singleton's Storext settings store as `ghost_synced_sources` (array of source strings, default `[]`) — matching where this app keeps other app-wide config (no dedicated table). Written by the admin checkbox UI. Note: `System.instance` memoizes per-process; only the checkbox *display* can go stale across web processes — the sweep (the only Ghost writer) runs in fresh rake dynos and always reads current state.

**Credentials** (already present under `Stacks::Utils.config[:ghost]`): `api_url` (`https://garden3d.ghost.io`), `admin_api_key` (`id:secret`), `content_api_key` (unused by this feature). A `webhook_secret` key exists from the earlier webhook design; it is unused and harmless.

**Gemfile:** add `jwt` explicitly (already in bundle transitively).

## 2. Ghost API client — `lib/stacks/ghost.rb`

HTTParty class following `Stacks::Apollo` / `Stacks::Runn` patterns.

- **Auth:** per-request JWT — header `{alg: HS256, typ: JWT, kid: <key id>}`, payload `{iat: now, exp: now+300, aud: "/admin/"}`, signed with the **hex-decoded** secret. Sent as `Authorization: Ghost <token>`. Pin `Accept-Version: v6.0`.
- **Methods:** `all_members` (browse, `?limit=100&include=labels,newsletters`, follow `meta.pagination.next`), `find_member_by_email(email)` (`?filter=email:'<email>'`), `create_member(attrs)`, `update_member(id, attrs)`. (No newsletters endpoint needed — member payloads embed newsletter slugs.)
- **Resilience:** shared request wrapper with Runn-style exponential backoff on 429/5xx. (No proactive req/s throttle is implemented — rate control is reactive via 429 backoff; Ghost publishes no rate limits. The admin "Sync Now" path uses `max_retries: 1` so backoff sleeps can't park a web dyno.)
- No webhook management — the sync is sweep-only.

## 3. Outbound sweep (stacks → Ghost) — `lib/stacks/ghost_sync.rb`

`Stacks::GhostSync#sync_all!`:

1. Load `enabled` from the System setting; the **outbound legs** no-op if empty (an empty checkbox set means "push off", never "mass-delabel"). The inbound pull leg (§4) always runs.
1a. **Deletion reconciliation** (before the outbound leg): any linked contact whose `ghost_id` is absent from the fetched member set was deleted in Ghost — clear `ghost_id`, stamp `snapshot.deleted_at`, count `member_deleted`. Eligible contacts with `snapshot.deleted_at` and no matching member are NOT re-created (counted `suppressed_deleted`).
2. Fetch all Ghost members into a map by lowercased email and by id. Fetch newsletters (id → slug map).
3. Eligible contacts: `Contact.where("sources && ARRAY[?]::varchar[]", enabled)` with a validly-formatted email (reuse the `resolve_email` regex; skip + count invalid).
4. Per eligible contact, desired labels = `enabled ∩ contact.sources`, used verbatim as label names (source `newsletter` → label `newsletter`; Ghost slugifies for NQL targeting, e.g. `etl:meet` → `etl-meet`).
5. **Create** if no member matches (by `ghost_id`, else email): `POST /members/` with `{email, name: display_name, labels: desired}`. No `newsletters` key → Ghost subscribes them to `subscribe_on_signup` newsletters. No `send_email` param (defaults off — no welcome email). On 422 "Member already exists": re-fetch by email, adopt, fall through to update.
6. **Update** if the member's actual managed label set (member labels ∩ enabled) ≠ desired, or name is blank in Ghost while contact has `display_name`: PUT with `labels = (member's labels outside the enabled set) + desired`, GET-then-PUT semantics (we have the fresh member from the sweep fetch). Never include `newsletters`. Never overwrite a non-blank Ghost name.
7. **De-labeling:** contacts linked to a member (`ghost_id` set) but no longer eligible get their managed (enabled-set) labels removed (member kept, subscriptions untouched). Fully unchecking a source shrinks the managed set instead, so that source's existing labels remain in Ghost unmanaged.
8. After any successful write: update `ghost_data.synced_at`; store `ghost_id` on create. The sweep's pull leg (§4) then refreshes `ghost_data.snapshot` for every member. `RecordNotUnique` on `ghost_id` (member already linked to another contact — e.g. its email was changed in Ghost and now matches a different contact): if the member's current email matches this contact's email, steal the link (clear the stale owner's `ghost_id`, retry once); otherwise skip and count as a conflict.
9. Sweep summary (created/updated/delabeled/skipped-invalid/inbound-upserted/errors) returned for the admin flash and logged for Scheduler runs. Per-contact errors are rescued, counted, and don't halt the sweep.

**Initial backfill note:** first real run just uses this same loop. If the eligible set were ever huge (>~5k creates), Ghost's CSV import endpoint (`POST /members/upload/`, fires no webhooks) is the escape hatch — not built now (YAGNI).

## 4. Inbound (Ghost → stacks)

One upsert path, `Stacks::GhostSync#upsert_contact_from_member(member)`, driven by the sweep's pull leg:

- Match contact by `ghost_id`, else by lowercased email; else `Contact.create_or_find_by!(email:)`.
- Sources to ensure: `g3d:ghost:<newsletter-slug>` for each **active** newsletter the member subscribes to; plain `g3d:ghost` if they have none (signed up but unsubscribed). Add only missing sources; record a `source_events` entry **only for newly added sources** (so repeat sweeps don't inflate funnel counts) — reusing the atomic `jsonb_set` pattern from `Api::ContactsController`.
- Set `ghost_id` if unset; refresh `ghost_data.snapshot` (newsletter slugs, `suppressed`, `email_disabled`, `email_in_ghost` when it differs from `contact.email`). Fill blank `display_name` from member name.
- The upsert is **idempotent** — it only writes when something actually changed — so sweeping the same member every 10 minutes is free, and since the inbound path never writes to Ghost, no loop is possible.
- Member deletion (detected via §3.1a reconciliation): keep the contact; clear `ghost_id`, stamp `ghost_data.snapshot.deleted_at`.

## 5. Admin UI (ActiveAdmin)

- **"Ghost Sync" page:** table of all distinct `Contact.sources` values (unioned with already-enabled sources) with contact counts and a checkbox per source (checked ⇔ present in `System.settings.ghost_synced_sources`); save replaces the setting. "Sync now" button runs `sync_all!` inline and flashes the summary (steady-state only — initial backfill goes through `rake ghost:sync`).
- **Contact show page:** "Ghost" panel — `ghost_id` linked to the Ghost Admin member page (`https://garden3d.ghost.io/ghost/#/members/<id>`), newsletter subscriptions, suppression + email-disabled flags, email-mismatch warning, `synced_at`. (Pushed labels are not snapshotted locally — they're derivable as `sources ∩ enabled` and visible in Ghost Admin via the link.)
- **Scopes on Contacts:** `:synced_to_ghost` / `:not_synced_to_ghost` (by `ghost_id` presence), alongside the Apollo scopes.

## 6. Scheduling & concurrency

- `lib/tasks/ghost.rake` → `ghost:sync` invoking `Stacks::GhostSync.new.sync_all!`; Heroku Scheduler every 10 minutes.
- Postgres advisory lock (`pg_try_advisory_lock` on a fixed key) wraps the sweep so an overlapping Scheduler run / admin button click exits cleanly instead of double-writing.

## 7. Error handling summary

- 429/5xx from Ghost → backoff+retry in client; persistent failure raises, sweep rescues per-contact and reports.
- 422 duplicate-email on create → adopt existing member (fetch by email), update path.
- `RecordNotUnique` on `ghost_id` → steal the link only when the member's email matches this contact (case-fold duplicates skip and wait for `dedupe!`, which carries ghost link + deletion opt-out through merges).
- Invalid contact emails → skipped, counted.

## 8. Testing (minitest, existing patterns)

- **Client:** JWT construction (kid/aud/exp, hex-decoded secret), pagination, backoff — WebMock-style stubs.
- **Sweep:** create/update/delabel decisions; unmanaged labels preserved; `newsletters` never written on update; unsubscribed member not re-subscribed; 422-adopt path; invalid email skip; advisory-lock no-overlap.
- **Inbound upsert:** new contact from member; source added only once; `source_events` only on newly added source; `display_name` backfill; email-mismatch snapshot; repeat upsert issues no write.

## Out of scope (explicit)

- Pushing metadata-derived labels (only `sources` map to labels, per Hugh).
- Two-way label sync (Ghost labels never become stacks sources; only newsletter subscriptions do, as `g3d:ghost:*`).
- Syncing paid-tier/Stripe state.
- Job queue infrastructure; CSV bulk-import path.
- Webhooks in any form (removed 2026-07-21 per Hugh — sweep-only; the `POST /webhooks/ghost` receiver existed briefly during development).
