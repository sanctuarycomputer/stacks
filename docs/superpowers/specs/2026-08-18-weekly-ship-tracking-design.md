# Weekly Ship Tracking — Design

**Date:** 2026-08-18
**Status:** Approved

## Goal

Emails sent to ships@sanctuary.computer (already ingested nightly as
`Document` records, source `google_groups`) should be connected to the
active `ProjectTracker`s they describe, so the project tracker index shows
each tracker's last weekly ship — who sent it and how long ago — with
overdue trackers flagged. Clicking through opens the thread in Google
Groups' own UI via the `groups.google.com/a/<domain>/d/msgid/<group>/<id>`
redirector, built from the RFC822 Message-ID we already store
(`Document#external_id`). Verified working against the live group
(2026-08-18, Hugh click-tested) — so Stacks builds no email-rendering UI.

Matching is in-app (chosen over an external stacksbot/MCP agent):
deterministic heuristics first, then an LLM call through a new
provider-agnostic `Stacks::AI` facade backed by the Anthropic API. This is
deliberately the first direct LLM integration in Stacks — the facade is the
pattern future features reuse.

## Data model

### `weekly_ships` — one row per (ship email × tracker) link

- `document_id` (fk → documents, indexed)
- `project_tracker_id` (fk → project_trackers, indexed)
- unique index on (document_id, project_tracker_id)
- `sent_at` (datetime — the thread's first-message time, from
  `Document#occurred_at`)
- `sent_by_email` / `sent_by_name` (denormalized from the document's
  `DocumentContact` with role `sender`)
- `matched_by` enum: `heuristic` / `llm` / `human`
- `confidence` (float, nullable — LLM matches only)
- `rationale` (text, nullable — LLM matches only)

One email may link to multiple trackers (multi-project ships).

### `ship_scans` — scan bookkeeping, one row per examined document

- `document_id` (fk, unique)
- `outcome` enum: `linked` / `no_match` / `not_a_ship`
- `scanned_at`
- `human_locked` (boolean, default false)

Purpose: the sweep never re-classifies an already-scanned document, and
`human_locked: true` (set whenever a human creates/edits/deletes a
WeeklyShip for that document) means the sweep never overwrites human
judgment — same spirit as the ETL's human-locked exclusion flags.

## `Stacks::AI` facade

Call sites depend ONLY on `Stacks::AI`; providers are adapters beneath.

- `Stacks::AI.extract(prompt:, schema:, tier: :fast)` → Hash. Sends the
  prompt to the configured provider, requests structured JSON conforming to
  `schema` (a shallow expected-keys/types description), validates the
  response, raises `Stacks::AI::Error` on transport/validation failure.
- `tier:` is abstract — `:fast` (cheap classification; used here) and
  `:smart` (reserved). Call sites never name provider model ids.
- `Stacks::AI::Providers::Anthropic` — the only adapter for now. HTTParty
  client mirroring `Stacks::Notion`'s style; API key from
  `Stacks::Utils.config[:anthropic][:api_key]`; maps `:fast` to the current
  cheapest Haiku-class model. Exact model id, API version headers, and
  request shape are settled at implementation time against the claude-api
  reference skill (not from memory).
- Provider selection: `Stacks::Utils.config[:ai][:provider]`, defaulting to
  `anthropic` when unset. Swapping providers later = one new adapter class.
- Key prerequisite: Hugh supplies the Anthropic API key; it goes into Rails
  credentials before deploy. With no key configured, `extract` raises
  `Stacks::AI::Error` and the sweep's LLM pass is skipped (heuristic links
  still happen; unscanned docs remain unscanned for retry).

## Matching pipeline — `Stacks::WeeklyShips::Sweep`

Runs nightly at the end of the `stacks:etl:sync_all` chain (new rake task
`stacks:etl:match_weekly_ships`), wrapped in a `SystemTask` like its
siblings.

Candidate documents: `source: :google_groups`,
`raw_metadata->>'group_email' = 'ships@sanctuary.computer'`, not
ETL-excluded, with no `ship_scans` row.

Candidate trackers: in-progress (`work_completed_at: nil`) ProjectTrackers,
each presented as {id, tracker name, Forecast project + client names}.

1. **Heuristic pass:** normalize the email subject (downcase, strip
   punctuation) and test containment against each tracker's normalized
   name/client names. Exactly one hit → create WeeklyShip
   (`matched_by: :heuristic`), scan outcome `linked`. Zero or multiple
   hits → fall through.
2. **LLM pass:** one `Stacks::AI.extract` call per document (tier `:fast`).
   Prompt: subject, sender, first ~2,000 chars of thread body (from the
   document's chunks, in position order), and the candidate tracker list.
   Schema: `{tracker_ids: [Integer], not_a_ship: bool, confidence: Float,
   rationale: String}`.
   - `not_a_ship: true` → scan outcome `not_a_ship`.
   - `tracker_ids` present and `confidence >= 0.6` → WeeklyShip per id
     (`matched_by: :llm`, confidence + rationale stored), outcome `linked`.
   - Otherwise → outcome `no_match`, rationale kept in logs; these surface
     in the WeeklyShips admin for manual linking.
3. **Failure handling:** `Stacks::AI::Error` on a document → log, count it,
   write NO scan row (retries next night). The wrapping SystemTask is
   marked error (Sentry notification) if any document errored, success
   otherwise. A hard failure of the whole task never blocks the rest of the
   ETL chain (rescued per-task like existing chain entries).

Historical backfill comes free: on first run, every previously-ingested
ships@ document is unscanned and gets processed (heuristic pass absorbs
most; LLM the rest — a one-time cost).

## Project tracker index column

- New "Last Ship" column on the in-progress and dormant scopes of the
  ActiveAdmin project trackers index (not the complete scope).
- Content: a pill linking DIRECTLY to the ship's Google Groups permalink
  (external, ↗, new tab), reading `<time_ago> ago by <first name or email>`
  — e.g. `4d ago by Hugh ↗`.
- Permalink construction: `Document#google_groups_permalink` — for
  google_groups documents only, returns
  `https://groups.google.com/a/<domain>/d/msgid/<group-local-part>/<CGI-escaped Message-ID without angle brackets>`,
  where domain and group-local-part come from
  `raw_metadata["group_email"]`. Returns nil for other sources.
- Staleness (relative to Date.today, using the latest linked ship's
  `sent_at`): ≤7 days → neutral pill; >7 days → `pill at_risk` (orange);
  >14 days or no ship ever → `pill error` (red, "No ships yet" when none).
- Model support: `ProjectTracker#last_weekly_ship` plus a per-index bulk
  loader (one grouped query for the page's tracker ids — extend the
  existing `preload_for_render`/controller collection path; no N+1).

## Audit trail + manual override (ActiveAdmin `WeeklyShips` resource)

No email-body rendering in Stacks — the Google Groups permalink is the
viewer. The resource is a thin CRUD:

- **Index:** all WeeklyShips, filterable by project tracker, matched_by,
  and sent_at; columns include subject (document title), sender, sent_at,
  tracker, matched_by/confidence, and an "Open in Google Groups ↗" link.
  This is the audit trail.
- **Show page:** the same metadata plus rationale, linked tracker(s), and
  the Groups permalink. No chunk/body rendering.
- **Manual override:** standard create/edit/delete on WeeklyShip (belongs_to
  selects for document + tracker; document select scoped to ships@
  documents). Any human create/update/destroy sets `human_locked: true` on
  the document's ShipScan (creating it if absent) so the sweep leaves the
  document alone thereafter.
- **Tracker show page:** a "Weekly Ships" panel listing that tracker's
  ships (sent_at desc, sender, Groups permalink ↗).

## Error handling summary

- No API key / provider down: heuristic links still land; unscanned docs
  retry nightly; SystemTask error surfaces the outage.
- LLM returns malformed JSON: `Stacks::AI` validation raises; treated as
  document-level failure (retry next night).
- Document deleted/excluded after linking: ETL exclusion doesn't destroy
  documents, so links and permalinks survive.
- Ambiguous/low-confidence: never auto-linked; visible as `no_match` scans
  and via missing "Last Ship" pills, fixable manually.

## Testing

- Heuristic matcher: unit tests over subject/tracker-name normalization,
  single-hit vs ambiguous vs zero-hit.
- `Stacks::AI`: facade tests with a stubbed provider (schema validation,
  error raising, provider selection default); Anthropic adapter tests with
  stubbed HTTP (request shape, response parsing, error mapping).
- Sweep: integration-style tests with real Document/Chunk/DocumentContact
  rows and `Stacks::AI.extract` stubbed — covering heuristic link, llm
  link (incl. multi-tracker), not_a_ship, no_match (low confidence),
  human_locked skip, already-scanned skip, API-error retry semantics.
- Index support: `ProjectTracker#last_weekly_ship` + staleness boundaries
  (7/14 days) + bulk loader returns latest-per-tracker.
- `Document#google_groups_permalink`: correct domain/group parsing,
  CGI-escaping of `+`/`@` in message-ids, angle-bracket stripping, nil for
  non-google_groups sources.
- Admin: model-level tests for the human-lock side effect on
  create/update/destroy.

## Out of scope

- No overdue-ship Stacks tasks (Hugh chose flag-only; the task-system hook
  is an easy follow-up).
- No MCP tool for ship linking (possible later addition; in-app pipeline is
  the system of record).
- No in-Stacks rendering of email bodies (the Groups `d/msgid` permalink is
  the viewer; chunks remain available if a future feature wants them).
- No changes to the ETL ingestion itself (ships@ is already ingested).
- No `:smart` tier implementation in `Stacks::AI` beyond reserving the
  name.
