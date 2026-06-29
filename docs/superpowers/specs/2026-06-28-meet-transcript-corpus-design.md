# Google Meet Transcript Corpus + MCP Access — Design

**Date:** 2026-06-28
**Status:** Approved, ready for implementation plan

## Context

This is the first feature of a broader "MCP & agent features" effort. The long-term
vision is an agent that understands every decision made across the organization,
tracks commitments people make ("I'll do X by Y") and whether they're kept, and
surfaces opportunities. That intelligence layer is **explicitly out of scope here**
— it is only as good as the corpus underneath it, so we build the corpus first.

This spec covers the **foundation**: reliably ingesting Google Meet transcripts
org-wide, storing them permanently, and exposing them to an agent through a
read-only MCP server. The "understand decisions / track commitments / find
opportunities" intelligence becomes its own later spec built on top of this corpus.

Stacks already has Google Workspace integration via a **service account with
domain-wide delegation** (impersonating `hugh@sanctuary.computer`), used in
`lib/stacks/calendar.rb` and `lib/stacks/team.rb` for the Directory and Calendar
APIs. We extend that same mechanism rather than introducing new auth.

## Goals

- Pull Google Meet transcripts from across the `sanctuary.computer` Workspace.
- Store them permanently and queryably so they are "forever accessible" to an agent.
- Bounded historical backfill (default ~90 days) plus continuous ongoing capture.
- Expose the corpus to an agent via a read-only MCP server supporting both keyword
  (full-text) and semantic (embedding) search.
- A sensitivity/exclusion layer: capture everything, but keep sensitive material
  (1:1s, performance reviews, comp, HR, etc.) structurally unreachable by the agent.

## Non-Goals

- The intelligence layer (decision understanding, commitment tracking, opportunity
  detection). Separate later spec.
- Audio/video recordings. Transcripts (text) only.
- Write access of any kind from the MCP server. Read-only.
- Real-time/streaming capture during a live meeting. Capture is post-meeting, batched.

## Key constraints & decisions

These were settled during brainstorming:

| Decision | Choice |
| --- | --- |
| Scope | Foundation only (ingest + store + MCP access); intelligence layer deferred. |
| Which meetings | Capture **all** transcribed meetings, no ingest-time filter. Sensitivity handled by an exclusion layer (below), not by skipping ingest. |
| History | Bounded recent backfill (default 90 days, configurable) + ongoing capture. |
| Search | **Both** full-text and semantic (hybrid). |
| Source | **Hybrid**: Meet REST API for ongoing (rich structure), Drive sweep for backfill. |
| Sensitive access | **Fully walled off** — excluded content is stored for the human record, viewable only in ActiveAdmin, never returned by the MCP server and never embedded/indexed. |

### Hard reality: where transcripts live

Google Meet transcripts only exist when transcription was turned **on** for a
meeting. When they exist:

- The **Meet REST API v2** exposes `conferenceRecords → transcripts →
  transcript.entries` (per-utterance speaker, email, timestamps) and real
  participant lists — but only lists conference records for a **recent window
  (~30 days)**. Best structure, no deep history.
- The transcript **Google Doc persists in Drive** in each organizer's
  "Meet Recordings" folder for as long as Drive retains it — reachable for
  backfill, but flatter data (speaker turns embedded in text, weaker attribution).

Hence the hybrid source: Meet API for ongoing capture, Drive sweep for backfill,
both normalized into one schema.

## Architecture

### Components

```
lib/stacks/meet/
  auth.rb            # service-account DWD, Drive + Meet readonly scopes, per-user impersonation
  meet_api_source.rb # ongoing capture via Meet REST API v2
  drive_source.rb    # backfill via Drive "Meet Recordings" transcript Docs
  classifier.rb      # exclusion rules (1:1 / title patterns)
  ingestor.rb        # idempotent upsert + classify + enqueue embeddings
  embedder.rb        # Voyage AI wrapper (swappable provider)
  search.rb          # keyword + semantic + hybrid query layer (MCP-facing)

app/models/
  meeting.rb
  meeting_participant.rb
  meeting_transcript_segment.rb
  meeting_transcript_chunk.rb

app/services/mcp/        # read-only MCP server
app/admin/meetings.rb    # ActiveAdmin browse/audit/reclassify
lib/tasks/meet.rake      # backfill + ongoing sync tasks (SystemTask-wrapped)
```

### Data flow

1. **Backfill** (one-off): `stacks:backfill_meet_transcripts` impersonates each
   Workspace user, sweeps their Drive "Meet Recordings" folder for transcript Docs
   within the window, normalizes, and hands each to the Ingestor.
2. **Ongoing** (scheduled): `stacks:sync_meet_transcripts` lists recent
   `conferenceRecords` via the Meet API, fetches transcripts + entries +
   participants, normalizes, and hands each to the Ingestor.
3. **Ingestor** upserts idempotently by external ID, runs the **classifier** on new
   records, and for non-excluded meetings chunks the transcript and enqueues
   embeddings.
4. **Embedder** generates a vector per chunk via Voyage AI.
5. **MCP server** answers agent queries through the Search layer, which always
   restricts to corpus-eligible meetings.

## Data model (Postgres + pgvector)

New extension: `enable_extension "vector"` (Heroku Postgres supports pgvector).
ActiveRecord integration via the `neighbor` gem.

### `meetings`

| column | type | notes |
| --- | --- | --- |
| `meet_conference_record_id` | string | unique (nullable for Drive-only) |
| `drive_transcript_doc_id` | string | unique (nullable for API-only) |
| `source` | enum | `meet_api`, `drive` |
| `title` | string | |
| `organizer_email` | string | |
| `started_at` / `ended_at` | datetime | |
| `participant_count` | integer | |
| `excluded` | enum | `not_excluded` (default), `auto_excluded`, `manually_excluded`, `manually_included` |
| `excluded_reason` | enum | `none` (default), `one_on_one`, `performance_review`, `compensation`, `hr`, `offboarding`, `pip`, `title_keyword`, `manual` |
| `excluded_by` | string | admin email when set by a human |
| `raw_metadata` | jsonb | source payload for debugging/reprocessing |

Both external IDs are uniquely indexed so re-runs upsert rather than duplicate. A
meeting present in both sources is reconciled onto one row (API data preferred for
attribution).

### `meeting_participants`

`meeting_id`, `name`, `email`, `join_at`, `leave_at`.

### `meeting_transcript_segments`

`meeting_id`, `speaker_name`, `speaker_email`, `started_at`, `ended_at`,
`position` (ordering), `text`, and a `tsvector` column (GIN-indexed) for full-text
search. This is the structured turn-by-turn record and the human-readable source of
truth.

### `meeting_transcript_chunks`

`meeting_id`, `content`, `embedding vector(1024)`, `started_at`/`ended_at` (time
range covered). Chunks are ~512 tokens with small overlap, the unit semantic search
retrieves. **Created only for corpus-eligible meetings** (see below).

## Sensitivity / exclusion layer

Capture everything; gate by the `excluded` state. The classifier runs on each newly
ingested meeting and sets `excluded`/`excluded_reason`:

**Auto-exclude (`auto_excluded`) when any of:**

- the meeting is a 1:1 — `participant_count <= 2` → reason `one_on_one`; or
- the title matches (case-insensitive) a sensitive pattern → reason from the matched
  family:
  - `1:1`, `1 on 1`, `one-on-one` → `one_on_one`
  - `performance review`, `review` → `performance_review`
  - `salary`, `comp`, `compensation` → `compensation`
  - `hr` → `hr`
  - `offboarding`, `termination` → `offboarding`
  - `pip` → `pip`
  - any other configured keyword → `title_keyword`

Everything else defaults to `not_excluded`.

**Human overrides (ActiveAdmin):**

- Clear a false positive → `manually_included` (sticky: re-ingest/re-classify will
  not re-flag it).
- Flag something the rules missed → `manually_excluded`, reason `manual`.
- A `manually_excluded` or `manually_included` decision is never overwritten by the
  classifier.

**Corpus eligibility = `excluded IN (not_excluded, manually_included)`.**

For excluded meetings: segments are still stored (so a human can read them in
ActiveAdmin), but **no chunks are created and no embeddings generated**, and the MCP
search/get tools never select them. Walled-off content is structurally unreachable
by the agent, not merely hidden behind a flag.

## Ingestion

Following the established Stacks pattern (no background job framework; periodic work
is rake tasks invoked by Heroku Scheduler, each wrapped in a `SystemTask` record for
observability — cf. `stacks:sync_forecast`, `stacks:sync_notion`):

- `lib/stacks/meet/auth.rb` — reuses
  `Stacks::Utils.config[:google_oauth2][:service_account]`, adding Drive-readonly and
  Meet-readonly scopes, impersonating each user via `authorization.sub`.
- `Stacks::Meet::MeetApiSource` and `Stacks::Meet::DriveSource` each return a
  normalized struct: meeting metadata + ordered segments + participants.
- `Stacks::Meet::Ingestor#upsert(normalized)` — finds-or-creates by external ID
  inside a transaction, replaces segments, runs the classifier (unless human-locked),
  and enqueues chunk embedding for corpus-eligible meetings.
- Rake tasks:
  - `stacks:backfill_meet_transcripts[days]` — one-off bounded Drive sweep.
  - `stacks:sync_meet_transcripts` — ongoing Meet API capture, scheduled.

Idempotency: every external record maps to a stable ID; re-ingest updates in place.

## Embeddings

- Provider: **Voyage AI** (Anthropic's recommended embedding provider; there is no
  native Anthropic embeddings API), model `voyage-3` (1024-dim). Wrapped behind
  `Stacks::Meet::Embedder` so the provider/model is swappable and config-driven.
- API key via existing `Stacks::Utils.config` mechanism.
- Embeddings are generated per chunk, only for corpus-eligible meetings, after
  ingest. Re-embedding is idempotent per chunk.

## MCP server (read-only)

- Transport: **remote Streamable-HTTP**, mounted under the existing `api` namespace
  in `config/routes.rb`, so both claude.ai and Claude Code can connect.
- Auth: **bearer token** (admin-issued, stored in config). Read-only; no tool mutates
  data.
- Tools:
  - `search_transcripts(query, mode: keyword|semantic|hybrid, filters)` — `filters`
    covers date range and participant email. `hybrid` combines full-text rank with
    vector similarity.
  - `list_meetings(date range, participant)` — metadata listing.
  - `get_meeting(id)` — metadata + participants.
  - `get_transcript(meeting_id)` — ordered segments with speaker attribution.
- **Every tool restricts to corpus-eligible meetings at the query layer.** Excluded
  content cannot be returned by any tool.

## Governance & consent

Permanently storing every employee's spoken words carries real consent/legal weight
that varies by jurisdiction. This spec records (the org may take or leave these):

- A **one-time notice** to employees that transcribed meetings are retained and
  searchable by internal tooling, with the exclusion categories listed.
- The MCP **bearer token is the access boundary** — it gates who/what can read the
  corpus; treat it as a secret and rotate it.
- The exclusion layer is the privacy control: sensitive material is retained for the
  human record but walled off from the agent.
- ActiveAdmin `Meeting` resource provides the audit/review surface and the only path
  to read excluded transcripts.

## Error handling

- Per-user impersonation failures (no Drive access, revoked grant) are logged and
  skipped; one user failing does not abort the sweep. Failures surface on the
  `SystemTask` record (consistent with existing sync tasks).
- Google API rate limits / `ClientError` handled per the existing `Stacks::Calendar`
  retry/rescue pattern.
- Embedding-provider failures leave the meeting ingested but unembedded and retryable
  on the next run (chunk has no vector yet).
- Meetings without transcripts are simply absent — not an error.

## Testing

- Classifier: unit tests over the exclusion rules (1:1 by count, each title family,
  human-lock precedence over auto-classification).
- Ingestor: idempotent upsert (re-ingest does not duplicate; source reconciliation;
  excluded meetings get no chunks).
- Sources: normalization from fixture Meet-API and Drive-Doc payloads.
- Search: keyword, semantic, and hybrid each exclude walled-off meetings.
- MCP tools: each tool refuses to return excluded content; auth required.

## Open items for the implementation plan

- Confirm Heroku Postgres pgvector availability/version on the target plan.
- Confirm the Drive transcript-Doc identification heuristic (folder + name pattern
  vs. Docs export MIME) against a real "Meet Recordings" folder.
- Choose the Ruby MCP implementation (official MCP Ruby SDK vs. a thin Rack
  controller speaking MCP JSON-RPC over Streamable HTTP).
- Confirm Voyage model/dimensions and budget for the backfill embedding run.
