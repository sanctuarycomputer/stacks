# Ghost ↔ Stacks Contact Sync — Design

**Date:** 2026-07-20
**Status:** Approved (approach + sections 1–2 reviewed with Hugh; remainder self-reviewed per his delegation)

## Goal

Keep stacks contacts in sync with Ghost (garden3d.ghost.io, Ghost(Pro) Publisher tier) so that:

1. Opt-in contacts in stacks appear as Ghost members, segmented by **labels**, so email campaigns can be targeted per segment from Ghost.
2. People who sign up directly on Ghost flow back into the stacks contacts funnel with proper `sources` + `source_events`.

## Architecture: full-state reconciliation (Approach A)

A scheduled sweep (`rake ghost:sync`, Heroku Scheduler every 10 min, plus an admin "Sync now" button) pulls **all** Ghost members and all sync-eligible contacts, computes desired state per person, and applies the diff in both directions. Ghost webhooks (`member.added` / `member.edited` / `member.deleted`) are a latency optimization only — correctness never depends on them, because Ghost webhook delivery has a 2s timeout and effectively no retries. Any missed event is corrected by the next sweep.

Scale assumption: newsletter-sized lists (thousands, not millions). A paginated full sweep is seconds of work. If that ever changes, `filter=updated_at:>cursor` delta-sync can be layered on without changing semantics.

## Ownership rules (the core invariants)

| Fact | Authority | Consequence |
|---|---|---|
| Segmentation (`stacks:*` labels) | **stacks** | Sweep enforces exactly the `stacks:*` labels a contact should have; hand-added non-`stacks:` labels in Ghost are never touched. |
| Opt-in state (newsletter subscriptions) | **Ghost** | We set newsletters only implicitly at member **creation** (Ghost's `subscribe_on_signup` default). We never write `newsletters` on update and never re-subscribe anyone. |
| Deliverability (`email_suppression`, `email_disabled`) | **Ghost** (read-only) | Snapshotted into `ghost_data` for visibility; never written. |
| Contact email | **stacks** | Email changes made in Ghost do NOT mutate `contact.email` (unique key + dedupe machinery). Mismatch recorded in `ghost_data.email_in_ghost` and surfaced in admin. |
| Member existence | shared | Stacks creates members for eligible contacts; stacks **never deletes** Ghost members (un-checking a source only removes `stacks:*` labels). Ghost deleting a member keeps the stacks contact (clears `ghost_id`, stamps `ghost_data.deleted_at`). |

## 1. Data model & configuration

**Migration — contacts:**
- `ghost_id` string, unique index. Stable join key (Ghost emails are mutable). Set on first push or first inbound event.
- `ghost_data` jsonb, default `{}`, null: false. Contents:
  - `fingerprint`: what we last pushed — `{labels: [sorted stacks:* label names], name: "..."}`. Used for echo suppression and needs-update checks.
  - `snapshot`: Ghost-owned state for admin visibility — `{newsletters: [slugs], suppressed: bool, email_disabled: bool, email_in_ghost: "...", deleted_at: ts}`.
  - `synced_at`: last successful outbound write.

**New model `GhostSyncedSource`** — single `source` string column, unique index. Row exists ⇔ contacts with that source are pushed to Ghost. Written by the admin checkbox UI.

**Credentials** (already present under `Stacks::Utils.config[:ghost]`): `api_url` (`https://garden3d.ghost.io`), `admin_api_key` (`id:secret`), `content_api_key` (unused by this feature). **To add:** `webhook_secret` (we generate it; configured on each webhook in Ghost Admin).

**Gemfile:** add `jwt` explicitly (already in bundle transitively).

## 2. Ghost API client — `lib/stacks/ghost.rb`

HTTParty class following `Stacks::Apollo` / `Stacks::Runn` patterns.

- **Auth:** per-request JWT — header `{alg: HS256, typ: JWT, kid: <key id>}`, payload `{iat: now, exp: now+300, aud: "/admin/"}`, signed with the **hex-decoded** secret. Sent as `Authorization: Ghost <token>`. Pin `Accept-Version: v6.0`.
- **Methods:** `all_members` (browse, `?limit=100&include=labels,newsletters`, follow `meta.pagination.next`), `find_member_by_email(email)` (`?filter=email:'<email>'`), `create_member(attrs)`, `update_member(id, attrs)`, `all_newsletters`.
- **Resilience:** shared request wrapper with Runn-style exponential backoff on 429/5xx; ~5 req/s self-throttle on write loops.
- Webhook registration is manual, one-time, in Ghost Admin (Settings → Integrations → custom integration): three webhooks (member.added/edited/deleted) → `POST https://<stacks-host>/webhooks/ghost`, each with the shared secret. (Ghost has no webhook browse endpoint; API-managed webhooks aren't worth it.)

## 3. Outbound sweep (stacks → Ghost) — `lib/stacks/ghost_sync.rb`

`Stacks::GhostSync#sync_all!`:

1. Load `enabled = GhostSyncedSource.pluck(:source)`; abort (no-op) if empty.
2. Fetch all Ghost members into a map by lowercased email and by id. Fetch newsletters (id → slug map).
3. Eligible contacts: `Contact.where("sources && ARRAY[?]::varchar[]", enabled)` with a validly-formatted email (reuse the `resolve_email` regex; skip + count invalid).
4. Per eligible contact, desired `stacks:*` labels = `enabled ∩ contact.sources`, each mapped to label name `stacks:<source>` (e.g. `stacks:newsletter`; Ghost slugifies to `stacks-newsletter` for NQL targeting).
5. **Create** if no member matches (by `ghost_id`, else email): `POST /members/` with `{email, name: display_name, labels: desired}`. No `newsletters` key → Ghost subscribes them to `subscribe_on_signup` newsletters. No `send_email` param (defaults off — no welcome email). On 422 "Member already exists": re-fetch by email, adopt, fall through to update.
6. **Update** if the member's actual `stacks:*` label set ≠ desired, or name is blank in Ghost while contact has `display_name`: PUT with `labels = (member's non-stacks labels) + desired`, GET-then-PUT semantics (we have the fresh member from the sweep fetch). Never include `newsletters`. Never overwrite a non-blank Ghost name.
7. **De-labeling:** contacts linked to a member (`ghost_id` set) but no longer eligible get their `stacks:*` labels removed (member kept, subscriptions untouched).
8. After any successful write: update `ghost_data.fingerprint` + `synced_at`; store `ghost_id` on create. The sweep also refreshes `ghost_data.snapshot` for every matched member (not just pull-leg upserts), so the webhook echo check always compares against current state. `RecordNotUnique` on `ghost_id` → reuse the `sync_to_apollo!` lock-merge-retry pattern (`dedupe!`).
9. Sweep summary (created/updated/delabeled/skipped-invalid/inbound-upserted/errors) returned for the admin flash and logged for Scheduler runs. Per-contact errors are rescued, counted, and don't halt the sweep.

**Initial backfill note:** first real run just uses this same loop. If the eligible set were ever huge (>~5k creates), Ghost's CSV import endpoint (`POST /members/upload/`, fires no webhooks) is the escape hatch — not built now (YAGNI).

## 4. Inbound (Ghost → stacks)

One shared upsert path, `Stacks::GhostSync#upsert_contact_from_member(member)`, used by both the sweep's pull leg and the webhook receiver:

- Match contact by `ghost_id`, else by lowercased email; else `Contact.create_or_find_by!(email:)`.
- Sources to ensure: `g3d:ghost:<newsletter-slug>` for each **active** newsletter the member subscribes to; plain `g3d:ghost` if they have none (signed up but unsubscribed). Add only missing sources; record a `source_events` entry **only for newly added sources** (so repeated `member.edited` events don't inflate funnel counts) — reusing the atomic `jsonb_set` pattern from `Api::ContactsController`.
- Set `ghost_id` if unset; refresh `ghost_data.snapshot` (newsletter slugs, `suppressed`, `email_disabled`, `email_in_ghost` when it differs from `contact.email`). Fill blank `display_name` from member name.
- Sweep pull leg: every Ghost member not matched to an eligible contact runs through this upsert (reconciliation for missed webhooks).

**Webhook receiver** — `POST /webhooks/ghost` (new controller, outside `/api`; no session/CSRF):

- **Signature:** verify `X-Ghost-Signature: sha256=<hex>, t=<ms>` where hex = HMAC-SHA256(secret, raw_body + t) — computed against raw request bytes. Constant-time compare; reject with 401 on mismatch or if `t` is >5 min stale. (Ghost 6 format; we're on Ghost(Pro) current, so no legacy body-only fallback.)
- `member.added` / `member.edited` → **echo check first**: if the payload's `stacks:*` labels + name match `ghost_data.fingerprint` and its newsletters match `ghost_data.snapshot`, it's the echo of our own write — 200, skip. Otherwise run the shared upsert.
- `member.deleted` → keep the contact; clear `ghost_id`, stamp `ghost_data.snapshot.deleted_at`. (Payload's `previous` holds the member.)
- Always respond inside Ghost's 2s window — the upsert is single-row writes, done inline; no queue needed. Unknown events → 200 no-op. Handler errors → 200 anyway (sweep is the safety net; a 5xx buys nothing since Ghost won't retry, and a 410 would delete the webhook).

## 5. Admin UI (ActiveAdmin)

- **"Ghost Sync" page:** table of all distinct `Contact.sources` values with contact counts and a checkbox per source (checked ⇔ `GhostSyncedSource` row exists); save updates rows. "Sync now" button runs `sync_all!` inline and flashes the summary. Shows webhook URL + setup instructions for the one-time Ghost Admin configuration.
- **Contact show page:** "Ghost" panel — `ghost_id` linked to the Ghost Admin member page (`https://garden3d.ghost.io/ghost/#/members/<id>`), pushed labels, newsletter subscriptions, suppression/disabled flags, email-mismatch warning, `synced_at`.
- **Scopes on Contacts:** `:synced_to_ghost` / `:not_synced_to_ghost` (by `ghost_id` presence), alongside the Apollo scopes.

## 6. Scheduling & concurrency

- `lib/tasks/ghost.rake` → `ghost:sync` invoking `Stacks::GhostSync.new.sync_all!`; Heroku Scheduler every 10 minutes.
- Postgres advisory lock (`pg_try_advisory_lock` on a fixed key) wraps the sweep so an overlapping Scheduler run / admin button click exits cleanly instead of double-writing.

## 7. Error handling summary

- 429/5xx from Ghost → backoff+retry in client; persistent failure raises, sweep rescues per-contact and reports.
- 422 duplicate-email on create → adopt existing member (fetch by email), update path.
- `RecordNotUnique` on `ghost_id` → lock, `dedupe!`, retry (Apollo pattern).
- Invalid contact emails → skipped, counted.
- Webhook bad signature → 401; stale timestamp → 401; processing error → 200 + log (sweep reconciles).

## 8. Testing (minitest, existing patterns)

- **Client:** JWT construction (kid/aud/exp, hex-decoded secret), pagination, backoff — WebMock-style stubs.
- **Sweep:** create/update/delabel decisions; non-stacks labels preserved; `newsletters` never written on update; unsubscribed member not re-subscribed; 422-adopt path; fingerprint updates; invalid email skip; advisory-lock no-overlap.
- **Inbound upsert:** new contact from member; source added only once; `source_events` only on newly added source; `display_name` backfill; email-mismatch snapshot.
- **Webhook controller:** signature valid/invalid/stale; echo suppression; added/edited/deleted flows; unknown event 200.

## Out of scope (explicit)

- Pushing metadata-derived labels (only `sources` map to labels, per Hugh).
- Two-way label sync (non-`stacks:` Ghost labels never become stacks sources).
- Syncing paid-tier/Stripe state.
- Job queue infrastructure; CSV bulk-import path.
- Managing Ghost webhooks via API.
