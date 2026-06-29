# Org-Wide Vector Store & ETL — Design

**Date:** 2026-06-28
**Status:** Approved, ready for implementation plan
**First source:** Google Meet transcripts

## Context

This is the foundation of the broader "MCP & agent features" effort. The goal is a
**durable, org-wide vector database fed by an ETL pipeline**, giving an agent
**cross-cutting** retrieval over everything the organization knows — answering
"what do we know about X" across meetings *and* emails *and* Notion *and* finance
data at once, not siloed per tool.

**Google Meet transcripts are the first source.** Many more will follow (Notion,
Gmail, Calendar, Deel/Runn/Forecast, QBO, Apollo, …). So this spec deliberately
builds two things together: (1) the **source-agnostic core + connector/ETL
framework**, and (2) the **Meet connector** that proves the pattern end-to-end.

The long-term intelligence layer — an agent that understands decisions, tracks
commitments ("X said they'd do Y") against Notion milestones/tasks, and surfaces
opportunities — is **out of scope here**. It is only as good as the corpus
underneath it, so we build the corpus and its pipeline first. It becomes its own
later spec built on this store.

Stacks already has Google Workspace integration via a **service account with
domain-wide delegation** (impersonating `hugh@sanctuary.computer`), used in
`lib/stacks/calendar.rb` and `lib/stacks/team.rb`. The Meet connector extends that
same mechanism. People are modelled as `AdminUser` (canonical, email-keyed across
`@sanctuary.computer` / `@xxix.co`) and `Contributor` (via `forecast_person`).

## Goals

- A **source-agnostic vector store**: unified `documents` + `document_chunks` with
  embeddings, full-text, and common facets (`source`, `occurred_at`, people).
- A **connector / ETL framework**: a common interface (`extract → normalize → chunk
  → embed → load`) with incremental sync watermarks, so adding a source is one
  connector and never touches search.
- A **read-only MCP server** that searches across *all* sources at once (keyword,
  semantic, hybrid), with an optional `source` filter.
- The **Meet connector** as the first real source: org-wide transcript capture,
  bounded backfill + ongoing, full speaker/participant fidelity.
- A generalized **exclusion layer** so sensitive material (e.g. 1:1s, reviews, comp,
  HR) is walled off from the agent across any source.
- **Identity resolution**: people on any document resolve to `AdminUser`/`Contributor`
  so cross-cutting "everything involving person X" works.

## Non-Goals

- The intelligence layer (decision understanding, commitment tracking, opportunity
  detection). Separate later spec.
- Connectors beyond Meet. The framework is built to accept them; they are future
  specs. We will not over-fit the core to Meet, but we also won't build speculative
  connectors now.
- Any write/mutation from the MCP server. Read-only.
- Audio/video. Text content only.

## Key decisions (settled in brainstorming)

| Decision | Choice |
| --- | --- |
| What we're building | Durable org-wide vector DB + ETL framework; Meet is source #1. |
| Storage shape | **Generic core + rich per-source**: unified documents/chunks searched across all sources, plus rich domain tables per source that project into the core. |
| Search | Full-text **and** semantic (hybrid), cross-source. |
| Which meetings (Meet) | Capture **all** transcribed meetings; sensitivity via the exclusion layer, not ingest-time skipping. |
| History (Meet) | Bounded backfill (default 90 days, configurable) + ongoing. |
| Source mechanism (Meet) | **Hybrid**: Meet REST API for ongoing (rich), Drive sweep for backfill. |
| Sensitive access | **Fully walled off** — excluded content stored for the human record (ActiveAdmin only), never embedded, indexed, or returned by MCP. |
| People | Resolve emails to `AdminUser` (→ `Contributor`); unresolved guests kept, never dropped. |

## Architecture

### Layers

```
                ┌─────────────────────────────────────────┐
   MCP server   │ read-only: search / get / list across    │
   (api ns)     │ ALL sources, source-filterable           │
                └───────────────────▲─────────────────────┘
                                    │ queries
                ┌───────────────────┴─────────────────────┐
   Generic core │ documents · document_people · document_  │
                │ chunks(embedding+tsvector) · source_syncs │
                └───────────────────▲─────────────────────┘
                                    │ load (upsert/chunk/embed)
                ┌───────────────────┴─────────────────────┐
   ETL framework│ Stacks::Etl::Connector (extract→normalize │
                │ →chunk→embed→load) · watermark · SystemTask│
                └───────────────────▲─────────────────────┘
                                    │ implements
                ┌───────────────────┴─────────────────────┐
   Connectors   │ Meet (source #1): Meet API + Drive,       │
                │ rich meetings/segments/participants,      │
                │ exclusion classifier                      │
                │ … future: Notion, Gmail, Calendar, …      │
                └──────────────────────────────────────────┘
```

### Code layout

```
lib/stacks/etl/
  connector.rb        # base: orchestrates extract→classify→chunk→embed→load + watermark
  chunker.rb          # source-agnostic text chunking (~512 tokens, overlap)
  embedder.rb         # Voyage AI wrapper (swappable provider)
  search.rb           # cross-source keyword + semantic + hybrid query layer (MCP-facing)
  meet/
    connector.rb      # Stacks::Etl::Meet::Connector (implements extract)
    auth.rb           # service-account DWD, Drive + Meet readonly scopes
    meet_api_source.rb# ongoing capture via Meet REST API v2
    drive_source.rb   # backfill via Drive "Meet Recordings" Docs
    classifier.rb     # Meet exclusion rules (1:1 / title patterns)

app/models/
  document.rb · document_person.rb · document_chunk.rb · source_sync.rb
  meeting.rb · meeting_participant.rb · meeting_transcript_segment.rb

app/services/mcp/     # read-only MCP server (Streamable HTTP)
app/admin/            # documents.rb, meetings.rb — browse/audit/reclassify
lib/tasks/etl.rake    # per-source backfill + ongoing sync tasks (SystemTask-wrapped)
```

## Data model (Postgres + pgvector)

New extension: `enable_extension "vector"` (Heroku Postgres supports pgvector),
ActiveRecord integration via the `neighbor` gem.

### Generic core

**`documents`** — one row per retrievable unit of source content.

| column | type | notes |
| --- | --- | --- |
| `source` | enum | `meet` (first); future sources extend the enum |
| `external_id` | string | stable id within the source; unique per `[source, external_id]` |
| `source_record_type`/`source_record_id` | polymorphic, nullable | link to the rich domain row (e.g. `Meeting`) when one exists |
| `title` | string | |
| `url` | string | link back to the source (Drive Doc, Notion page, …) |
| `occurred_at` | datetime | when the content happened (meeting start, email date) |
| `content_hash` | string | change detection for idempotent re-ingest |
| `excluded` | enum | `not_excluded` (default), `auto_excluded`, `manually_excluded`, `manually_included` |
| `excluded_reason` | enum | `none` (default), `one_on_one`, `performance_review`, `compensation`, `hr`, `offboarding`, `pip`, `title_keyword`, `manual` |
| `excluded_by` | string | admin email when set by a human |
| `raw_metadata` | jsonb | source payload for debugging/reprocessing |

**`document_people`** — the cross-cutting people facet (join).

`document_id`, `admin_user_id` (nullable FK), `email`, `name`, `role`
(e.g. `participant`, `speaker`, `sender`, `recipient`). Lets the store answer
"every document involving person X across all sources." Unresolved external people
keep name/email with a null `admin_user_id`.

**`document_chunks`** — the retrieval unit.

`document_id`, `position`, `content`, `embedding vector(1024)`, a `tsvector` column
(GIN-indexed), and denormalized `source` + `occurred_at` for fast facet filtering
without a join. **Created only for corpus-eligible documents** (see exclusion).

**`source_syncs`** — ETL watermark + run record per source.

`source`, `cursor` (jsonb watermark — e.g. last conference end-time, last Drive
`modifiedTime`), `last_run_at`, `status`, `stats` (counts), `system_task_id`.
Drives incremental extraction.

### Meet connector tables (rich per-source)

- **`meetings`** — `document` back-reference; `meet_conference_record_id` (unique,
  nullable), `drive_transcript_doc_id` (unique, nullable), `meet_source`
  (`meet_api`/`drive`), `title`, `organizer_email`, `started_at`, `ended_at`,
  `participant_count`, `raw_metadata`.
- **`meeting_participants`** — `meeting_id`, `name`, `email`, `admin_user_id`
  (nullable FK), `join_at`, `leave_at`.
- **`meeting_transcript_segments`** — `meeting_id`, `speaker_name`, `speaker_email`,
  `speaker_admin_user_id` (nullable FK), `started_at`, `ended_at`, `position`,
  `text`. The structured turn-by-turn record and human-readable source of truth; the
  connector derives `document_chunks` from these.

A meeting is reconciled onto one row even if seen via both sources (API data
preferred for attribution), keyed by the unique external IDs.

## ETL framework

`Stacks::Etl::Connector` is the base each source subclasses. The framework owns the
generic pipeline; a connector only implements **extraction + its exclusion policy**:

- `#extract(since:)` → yields normalized documents: `{ external_id, title, url,
  occurred_at, people: [{email,name,role}], content_segments, raw_metadata,
  build_source_record: -> { … } }`.
- `#exclusion_for(normalized)` → `[excluded, excluded_reason]` (default
  `not_excluded`); per-source pluggable.

The framework then, per document, inside a transaction:

1. Upsert `documents` by `[source, external_id]`; skip unchanged via `content_hash`.
2. Build/refresh the rich source record (e.g. `Meeting` + segments + participants).
3. **Resolve people** → `document_people` (+ segment/participant `admin_user_id`)
   via the shared `AdminUser` cross-domain uid matcher.
4. Run `exclusion_for` (unless human-locked: `manually_excluded`/`manually_included`
   are never overwritten).
5. For corpus-eligible documents only: chunk content → `document_chunks` → enqueue
   embeddings. Excluded documents get **no chunks and no embeddings**.
6. Advance the `source_syncs` watermark; record stats on the `SystemTask`.

Following the established Stacks pattern (no background-job framework; periodic work
is rake tasks invoked by Heroku Scheduler, each wrapped in a `SystemTask` — cf.
`stacks:sync_forecast`, `stacks:sync_notion`):

- `stacks:etl:backfill_meet[days]` — one-off bounded Drive sweep.
- `stacks:etl:sync_meet` — ongoing Meet API capture, scheduled.
- Future sources add `stacks:etl:sync_<source>` with no change to core or search.

## Exclusion layer (generalized)

Capture everything; gate by the document `excluded` state. Corpus eligibility =
`excluded IN (not_excluded, manually_included)`. Excluded documents keep their rich
records (readable by a human in ActiveAdmin) but are **never chunked, embedded, or
returned by any MCP tool** — structurally unreachable, not merely hidden.

The **Meet classifier** sets the initial state on new meetings:

- 1:1 (`participant_count <= 2`) → `auto_excluded`, reason `one_on_one`.
- Title matches (case-insensitive): `1:1`/`1 on 1`/`one-on-one` → `one_on_one`;
  `performance review`/`review` → `performance_review`; `salary`/`comp`/
  `compensation` → `compensation`; `hr` → `hr`; `offboarding`/`termination` →
  `offboarding`; `pip` → `pip`; other configured keyword → `title_keyword`.
- Otherwise `not_excluded`.

Humans reclassify in ActiveAdmin: clear a false positive → `manually_included`
(sticky); flag a miss → `manually_excluded`/`manual`. Future connectors supply their
own `exclusion_for` policy.

## Identity resolution

People on any document resolve to the existing person model rather than bare strings:

- `email` → `AdminUser` via the established cross-domain uid matching
  (`AdminUser.find_or_create_by_g3d_uid!` logic reconciling `@sanctuary.computer` /
  `@xxix.co`), stored as `admin_user_id` on `document_people` (and on Meet
  participants/segments). `Contributor` is reachable via
  `admin_user.forecast_person.contributor`.
- Unresolved external people keep name/email with a null `admin_user_id` — never
  dropped.

This makes "who said/did this" first-class and is what the later intelligence layer
hangs off.

## Embeddings

- Provider: **Voyage AI** (Anthropic's recommended embedding provider; there is no
  native Anthropic embeddings API), model `voyage-3` (1024-dim), wrapped behind
  `Stacks::Etl::Embedder` so model/provider is swappable and config-driven. API key
  via the existing `Stacks::Utils.config` mechanism.
- Per chunk, corpus-eligible content only, after load. Idempotent per chunk.

## MCP server (read-only, cross-source)

- Transport: remote **Streamable-HTTP**, mounted under the existing `api` namespace,
  so both claude.ai and Claude Code can connect. Auth: **bearer token**
  (admin-issued, config secret). Read-only.
- Tools (operate over the generic core, every one restricted to corpus-eligible
  documents at the query layer):
  - `search(query, mode: keyword|semantic|hybrid, filters)` — `filters`: `source`,
    `person` (email/admin_user), `date_range`. Hybrid combines full-text rank with
    vector similarity. Returns chunks with their document context.
  - `list_documents(filters)` — metadata listing.
  - `get_document(id)` — metadata + people + url; renders source-specific detail
    (for Meet: ordered speaker segments).
  - `list_sources()` — which sources are ingested and their freshness.

Because search is over the generic core, **every future connector is searchable the
moment it loads** — no per-source MCP work.

## Governance & consent

Permanently storing org communications (starting with everyone's transcribed speech)
carries real consent/legal weight that varies by jurisdiction. Recorded here (the
org may take or leave these):

- A **one-time notice** to employees that transcribed meetings (and, as sources are
  added, other communications) are retained and searchable by internal tooling, with
  the exclusion categories listed.
- The MCP **bearer token is the access boundary** — treat as a secret, rotate it.
- The **exclusion layer is the privacy control**: sensitive material is retained for
  the human record but walled off from the agent.
- ActiveAdmin `Document`/`Meeting` resources provide the audit/review surface and the
  only path to read excluded content. As new sources are added, each must declare its
  exclusion policy before it loads.

## Error handling

- Per-user impersonation failures (no Drive access, revoked grant) are logged and
  skipped; one user failing never aborts a sweep. Failures surface on the
  `SystemTask`/`source_syncs` record.
- Google API rate limits / `ClientError` handled per the existing `Stacks::Calendar`
  retry/rescue pattern.
- Embedding-provider failures leave the document loaded but a chunk unembedded and
  retryable next run (no vector yet).
- Source content without a transcript/body is simply absent — not an error.
- A connector raising mid-run advances the watermark only for fully-processed
  documents, so re-runs resume cleanly.

## Testing

- Core: idempotent document upsert (re-ingest no-dupes; `content_hash` skip;
  excluded docs get no chunks); people resolution (cross-domain match; unresolved
  guest retained).
- ETL framework: watermark advance/resume; exclusion-policy hook precedence over
  auto vs human locks.
- Meet connector: source normalization from fixture Meet-API and Drive-Doc payloads;
  classifier rules (1:1 by count, each title family, human-lock precedence); both
  sources reconcile to one meeting.
- Search: keyword, semantic, hybrid each exclude walled-off documents and honour the
  `source`/`person`/`date` filters.
- MCP tools: each refuses excluded content; auth required; `list_sources` freshness.

## Open items for the implementation plan

- Confirm Heroku Postgres pgvector availability/version on the target plan.
- Confirm the Drive transcript-Doc identification heuristic (folder + name pattern
  vs. Docs export MIME) against a real "Meet Recordings" folder.
- Choose the Ruby MCP implementation (official MCP Ruby SDK vs. a thin Rack
  controller speaking MCP JSON-RPC over Streamable HTTP).
- Confirm Voyage model/dimensions and budget for the backfill embedding run.
- Decide chunking parameters (size/overlap) and whether to chunk per-segment or
  across segments for Meet.
