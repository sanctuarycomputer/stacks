# Weekly Ship Tracking — Design

**Date:** 2026-08-18 (rev 2 — post adversarial review against live dev data)
**Status:** Approved

## Goal

Emails sent to ships@sanctuary.computer (already ingested nightly as
`Document` records, source `google_groups`) should be connected to the
`ProjectTracker`s they describe, so the project tracker index shows each
tracker's last weekly ship — who sent it and how long ago — with overdue
trackers flagged. Clicking through opens the thread in Google Groups' own
UI via the `groups.google.com/a/<domain>/d/msgid/<group>/<id>` redirector
(verified working 2026-08-18, Hugh click-tested) — Stacks builds no
email-rendering UI.

Matching is in-app via a new provider-agnostic `Stacks::AI` facade backed
by the Anthropic API — deliberately the first direct LLM integration in
Stacks and the pattern future features reuse. Adversarial review against
the live corpus (242 ships@ documents, 49 open trackers) refuted
heuristic-first matching: 42% of real ship subjects don't contain their
tracker's name, and brand-token collisions produce wrong auto-links
(`[XXIX x F2]` → "XXIX 3.0 Website"). So: **the LLM classifies every
candidate document**; heuristics only pre-rank the candidate tracker list
inside the prompt. Cost is trivial (~$0.25 one-time backfill, cents/week —
Haiku-class pricing).

## Key ETL reality this design must survive

The ETL is one-Document-per-thread-root, and the nightly sync re-ingests
from a ~2-day window. When a team sends this week's ship as a REPLY to last
week's thread, the document is **clobbered**: `occurred_at`, `title`,
`content_hash`, chunks, and document_contacts are rebuilt from the window's
messages only (178 google_groups documents in dev show
`occurred_at > created_at`; one is a real Aug 3 ships@ ship living under a
Jul 28 root). A scan-once model would never see that Aug 3 ship and would
flag the tracker red while it actively ships. The scan model below is
therefore **content-hash keyed, not scan-once**.

## Data model

### `weekly_ships` — one row per (ship email × tracker) link

- `document_id` (fk → documents, indexed)
- `project_tracker_id` (fk → project_trackers, indexed)
- unique index on (document_id, project_tracker_id)
- `sent_at` (datetime — the document's `occurred_at` at scan time;
  REFRESHED on every re-scan so reply-ships advance it)
- `sent_by_email` / `sent_by_name` — the speaker of the document's FIRST
  chunk (position 0): `speaker_name` from the chunk, email resolved via the
  chunk's `speaker_contact` or the matching sender-role DocumentContact.
  (NOT "the DocumentContact with role sender" — reply re-ingests rebuild
  contacts to the repliers.) Refreshed on re-scan.
- `matched_by` enum: `llm` / `human` (no heuristic auto-linking — see Goal)
- `confidence` (float, nullable) / `rationale` (text, nullable) — llm only

One email may link to multiple trackers (multi-project ships).

### `ship_scans` — scan bookkeeping, one row per examined document

- `document_id` (fk, unique)
- `outcome` enum: `linked` / `no_match` / `not_a_ship` / `out_of_scope`
- `scanned_content_hash` (string — the document's `content_hash` at scan
  time; the re-scan trigger)
- `scanned_at`
- `human_locked` (boolean, default false)

Sweep candidate rule: document has NO scan row, OR
`documents.content_hash != ship_scans.scanned_content_hash` — except
`human_locked: true`, which the sweep never touches. Re-scan of a
previously-linked document refreshes `sent_at`/`sent_by_*` on its existing
WeeklyShips and may ADD new tracker links; it never removes links (removal
is human-only).

Human scan semantics: a human creating a WeeklyShip sets the document's
scan to `linked` + `human_locked` (creating the scan row if absent);
deleting the document's last WeeklyShip sets `no_match` + `human_locked`.

## `Stacks::AI` facade

Call sites depend ONLY on `Stacks::AI`; providers are adapters beneath.

- `Stacks::AI.extract(system:, prompt:, schema:, tier: :fast)` → Hash.
  Structured output via the provider's NATIVE structured-output mechanism —
  for Anthropic, `output_config.format` with a `json_schema`
  (`additionalProperties: false`); the deprecated `output_format` param
  must not be used. This eliminates the malformed-JSON failure class by
  construction; validation of the parsed Hash against the schema is a
  safety net that raises `Stacks::AI::Error`.
- `tier:` abstract — `:fast` (cheap classification; used here), `:smart`
  (reserved). Call sites never name provider models.
- `Stacks::AI::Providers::Anthropic`: HTTParty client mirroring
  `Stacks::Notion` style; key from
  `Stacks::Utils.config[:anthropic][:api_key]` (per-BASE_HOST credentials —
  the key must exist in every deployed host namespace); maps `:fast` to the
  current cheapest Haiku-class model. `max_tokens` a few hundred, and a
  `stop_reason: "max_tokens"` response is an error, not a result. Retries
  with backoff on 429/529 (2 attempts) before raising. Exact model id,
  headers, and request shape settled at implementation time against the
  claude-api reference skill.
- Token accounting: `extract` returns usage internally; the sweep logs
  total input/output tokens per run (visible in SystemTask/log output).
- Provider selection: `Stacks::Utils.config[:ai][:provider]`, default
  `anthropic`.
- **Key absent:** `Stacks::AI.configured?` returns false; the sweep then
  SKIPS the LLM pass and finishes as success-with-warning (logged count of
  skipped docs). SystemTask error is reserved for real failures when a key
  exists. The key is a LAUNCH PREREQUISITE — without it nothing links
  (there is no heuristic fallback by design); Hugh has added it to
  credentials (verify both host namespaces before deploy).

## Matching pipeline — `Stacks::WeeklyShips::Sweep`

Runs nightly at the end of the `stacks:etl:sync_all` chain (new rake task
`stacks:etl:match_weekly_ships`), wrapped in a `SystemTask`, rescued so it
never blocks the rest of the chain.

**Candidate documents:** `source: :google_groups`,
`raw_metadata->>'group_email' = 'ships@sanctuary.computer'`, not
ETL-excluded, matching the scan candidate rule above.

**Backfill bound:** documents with `occurred_at` older than 90 days at
scan time get outcome `out_of_scope` with NO LLM call (their trackers are
mostly long-completed; classifying them against today's tracker list only
manufactures noise). `out_of_scope` scans are excluded from all
manual-review surfaces.

**Candidate trackers:** `work_completed_at: nil` (= the in_progress ∪
dormant population, 49 today). This is the authoritative set for BOTH
matching and the index column, so the two can never disagree.

**Per document (within the 90-day window):**
1. Build the prompt: subject (title), sender, first ~2,000 chars of body
   (chunks in position order), and the candidate tracker list ({id, tracker
   name, Forecast project/client names}) — pre-RANKED by a normalized
   name-containment heuristic so likely matches appear first, but ranking
   is the heuristic's ONLY role.
2. One `Stacks::AI.extract` call (tier `:fast`). Schema:
   `{tracker_ids: [Integer], not_a_ship: bool, confidence: Float,
   rationale: String}`. System prompt explains weekly-ship semantics, the
   own-brand-token trap (Sanctuary Computer / XXIX / studio names appear in
   subjects as the SENDER's brand, not the project), and that an email may
   cover several projects or none.
3. Outcomes: `not_a_ship` → scan `not_a_ship`. `tracker_ids` present with
   `confidence >= threshold` (default 0.6, admin-tunable via an env-style
   constant; an uncalibrated knob, not a guarantee) → WeeklyShip per id
   (`matched_by: :llm`), scan `linked`. Otherwise scan `no_match`
   (rationale logged; surfaces in the WeeklyShips admin for manual
   linking).
4. `Stacks::AI::Error` on a document → log, count, write NO scan row
   (retries next night). Any errored docs → SystemTask error (Sentry);
   zero errors → success.

## Project tracker index column

- "Last Ship" column on the in-progress and dormant scopes (not complete).
- Content: external link (↗, new tab) to the ship's Google Groups
  permalink, reading `<time_ago> ago by <first name or email>`.
- Staleness, from the tracker's latest `weekly_ships.sent_at`:
  - **in_progress scope:** ≤7 days neutral; >7 days `pill at_risk`
    (orange); >14 days or never `pill error` (red, "No ships yet").
  - **dormant scope:** always neutral/muted — a dormant tracker red
    forever is noise, not signal.
- Model support: `ProjectTracker#last_weekly_ship` plus a bulk
  latest-per-tracker loader invoked from the project_trackers admin
  controller path (NOT inside `preload_for_render` — its other three
  callers shouldn't pay for ships).

## Permalink — `Document#google_groups_permalink`

For google_groups documents:
`https://groups.google.com/a/<domain>/d/msgid/<group-local-part>/<CGI-escaped id, angle brackets stripped>`
where domain/local-part come from `raw_metadata["group_email"]`, and the
id is **`raw_metadata["gmail_message_ids"].first`, falling back to
`external_id`** — 7/242 real documents have a thread-root `external_id`
that was never posted to the group (reply-to-compose ancestors,
post-clobber roots), so a message-id known to be in the group is
preferred. Returns nil for other sources. (`gmail_message_ids` holds
RFC822 Message-IDs, same id-space as `external_id`.)

## Audit trail + manual override (ActiveAdmin `WeeklyShips` resource)

- **Index:** filterable by project tracker, matched_by, sent_at; columns:
  subject, sender, sent_at, tracker, matched_by/confidence, "Open in
  Google Groups ↗". Doubles as the manual-review surface via a `no_match`
  scans filter (excluding `out_of_scope`).
- **Show:** metadata + rationale + linked tracker(s) + Groups permalink.
  No body rendering.
- **Manual override:** create/edit/delete WeeklyShip (document select
  scoped to ships@ documents); human writes set the scan's `human_locked`
  per the semantics in the data model section.
- **Tracker show page:** "Weekly Ships" panel (sent_at desc, sender,
  Groups permalink ↗).

## Error handling summary

- No API key: LLM pass skipped, success-with-warning, nothing links (by
  design; key is a launch prerequisite).
- Provider outage / malformed response: per-document error, no scan row,
  nightly retry; SystemTask error surfaces it once per run.
- Reply-clobbered documents: re-scanned via content-hash change; links
  refreshed/added, never auto-removed.
- Ambiguous/low-confidence: `no_match`, visible in admin, fixable by hand;
  human fixes are locked against the sweep forever.

## Testing

- Sweep (with `Stacks::AI.extract` stubbed): llm link (incl.
  multi-tracker), not_a_ship, no_match low-confidence, out_of_scope
  90-day bound, human_locked skip, unchanged-hash skip, CHANGED-hash
  re-scan (sent_at/sender refresh + link addition, no removal), AI-error
  retry semantics, no-key skip path.
- `Stacks::AI`: facade schema-validation + configured? + provider default;
  Anthropic adapter with stubbed HTTP — request shape (structured output
  config), usage extraction, 429 retry, stop_reason max_tokens error.
- Prompt ranking heuristic: own-brand tokens don't outrank real clients;
  normalization.
- `Document#google_groups_permalink`: gmail_message_ids.first preference,
  external_id fallback, `+`/`@` escaping, bracket stripping, nil for other
  sources.
- `ProjectTracker#last_weekly_ship` + staleness boundaries (7/14 days) +
  bulk loader latest-per-tracker + dormant muting.
- WeeklyShip human-lock side effects on create/update/destroy.

## Out of scope

- No overdue-ship Stacks tasks (easy follow-up).
- No MCP tool for ship linking (possible later).
- No in-Stacks rendering of email bodies.
- No `:smart` tier implementation beyond reserving the name.
- No ETL ingestion changes — the reply-clobber behavior is survived, not
  fixed (fixing the ETL's window semantics is its own project).
