# Org-Wide Vector Store & ETL — Design

**Date:** 2026-06-28
**Status:** Approved, ready for implementation plan
**First source:** Google Meet transcripts

## Context

This is the foundation of the broader "MCP & agent features" effort: a **durable,
org-wide vector database fed by an ETL pipeline**, giving an agent **cross-cutting**
retrieval over what the organization knows — answering "what do we know about X"
across meetings *and* emails *and* Notion *and* finance data at once, not siloed.

It is built in the existing **Stacks Rails app on Heroku Postgres**, which already
holds org data and the hard-won Google Workspace auth. The ETL target and the durable
store are the same database; Heroku's automated backups + PITR cover "durable."

### The index is a synthesis layer, not a mirror

A guiding principle (from prior architecture work): the pgvector index is **not a
copy of every tool**. It holds the distilled, decision-bearing, historical slice that
lives *at the seams between tools* — the cross-source brain. Sources that already have
their own MCP and decent native search (Notion, GitHub, Figma, Gmail, Twist) are
queried **live** for current state; we only **promote** their high-signal fraction
into the index when it needs cross-source semantic search or durable history.

**Google Meet transcripts are the exception that proves the rule, and so are
source #1:** they have *no* MCP, they are the richest source of decisions and
commitments, and they are the messiest input (speaker display-names, no stable IDs).
They get **fully ingested**. Later, chatty/ephemeral sources will contribute only a
promoted slice, not a full mirror.

### Phasing

The long-term target is a 16-table institutional-memory schema (see *Target schema*
below). It splits cleanly into two layers, and **this spec builds only the first**:

- **Foundation (this spec):** raw substrate + retrieval + the Meet connector —
  `documents`, `chunks`, `mentions`, contact resolution,
  `embeddings`, plus the read-only MCP server. Designed to be forward-compatible.
- **Intelligence layer (later spec):** the extracted semantic objects
  (`decisions`, `commitments`, `tasks`, `opportunities`), the provenance/bitemporal
  spine (`evidence`, `events`, `links`), `projects`/`milestones` synced from Notion,
  and the five read-layer views. Tracks "who said they'd do what, by when, and whether
  it happened." Out of scope here; it is only as good as the corpus underneath it.

People are anchored by the **existing `contacts` table** — its stated vision is
"everyone we know," it is unique on `email`, and it already carries Apollo enrichment
(`apollo_data`) and a `sources` provenance array. **`Contact` is the identity, full
stop.** Every person on any document resolves to a `Contact` purely by email
(`create_or_find_by`, lowercased, tagged with a `meet` source) — including
`@sanctuary.computer` / `@xxix.co` workspace people. If we don't have a `Contact` for
someone yet (workspace or external), we just make one; we deliberately do **not**
reconcile against `AdminUser` or `Contributor`. So `contact_id` is the FK target
everywhere, and ingesting transcript people broadens `contacts` toward truly everyone.

A consequence we accept: with no cross-domain reconciliation, a workspace person seen
under both `@sanctuary.computer` and `@xxix.co` is two `contacts` rows; the existing
`Contact#dedupe!` handles merges, and it can be revisited later. Internal org info from
`Contributor` (ledgers, assignments, skill trees) is joinable later by email if the
intelligence layer wants it — not part of resolution now. Google auth reuses the
service-account domain-wide delegation in `lib/stacks/calendar.rb` / `team.rb`.

## Goals

- A **source-agnostic vector store**: `documents` → `chunks`,
  with a versioned `embeddings` side-table, full-text, and facets (`source`,
  `occurred_at`, contacts).
- A **connector / ETL framework**: a common interface (`extract → normalize → chunk
  → embed → load`) with incremental sync watermarks, so adding a source is one
  connector and never touches search. Each connector decides what to *promote*
  (full ingest vs. distilled slice).
- A **read-only MCP server** searching across *all* sources at once
  (keyword/semantic/hybrid), `source`-filterable, authenticated by the existing private API key and
  audit logging.
- The **Meet connector** as source #1: org-wide transcript capture, bounded backfill
  + ongoing, full speaker/participant fidelity, display-name → contact resolution.
- A generalized **exclusion layer** walling sensitive material (1:1s, reviews, comp,
  HR) off from the agent across any source.
- **Identity resolution** so everyone on any document resolves to a `Contact` (by
  email, created if missing) and cross-cutting "everything involving this contact"
  works.
- **Provenance-ready chunks**: stable chunk spans so the later `evidence` layer can
  cite exact quotes.

## Non-Goals

- The intelligence layer (decisions/commitments/tasks/opportunities, evidence/events/
  links, Notion projects/milestones, the views). Separate later spec.
- Connectors beyond Meet. The framework accepts them; they are future specs. No
  speculative connectors now.
- **Multi-tenant / productization.** Internal single-tenant only (one org, our
  credentials). Productizing (per-tenant OAuth, tenant isolation, never holding a
  cross-org index) is a separate future effort, deliberately not designed in now.
- Any write/mutation from the MCP server. Read-only.
- Audio/video. Text only.
- A new background-job framework. We use the existing rake + Heroku Scheduler pattern.

## Key decisions (settled in brainstorming)

| Decision | Choice |
| --- | --- |
| What we're building | Durable org-wide vector DB + ETL framework; Meet is source #1. |
| Scope | Foundation only (raw substrate + retrieval + Meet); intelligence layer later. |
| Index philosophy | Synthesis layer, not a mirror. Full-ingest Meet (no MCP); promote distilled slices from MCP-having sources later. |
| Storage shape | Generic core + rich per-source tables that project into the core. |
| Embeddings | Versioned, polymorphic **side-table** keyed by `(owner_type, owner_id, model)` — not a vector column on chunks. |
| Search | Full-text **and** semantic (hybrid), cross-source. |
| Which meetings (Meet) | Capture **all** transcribed meetings; sensitivity via the exclusion layer. |
| History (Meet) | Bounded backfill (default 90 days, configurable) + ongoing. |
| Source mechanism (Meet) | **Hybrid**: Meet REST API for ongoing (rich), Drive sweep for backfill. |
| Sensitive access | **Fully walled off** — stored for humans (ActiveAdmin only), never chunked, embedded, or returned by MCP. |
| People | Canonical FK is the existing `contacts` table ("everyone we know", email-unique, Apollo-enriched). Resolve email → `Contact` (`create_or_find_by`, make one if missing — workspace or external); **no** AdminUser/Contributor reconciliation. Display-name fuzziness + leftovers go to the `mentions` queue; nobody dropped. |
| Job infra | Existing SystemTask-wrapped rake tasks via Heroku Scheduler; embed inline, retry next run. |
| Tenancy | Internal single-tenant. |
| MCP impl | Official `mcp` Ruby gem, Streamable HTTP at `/mcp`, run stateless if >1 web dyno. |

## Architecture

```
                ┌─────────────────────────────────────────┐
   MCP server   │ read-only: search / get / list across    │
   (api ns)     │ ALL sources · X-Api-Key auth · audit log │
                └───────────────────▲─────────────────────┘
                                    │ queries (hybrid: vector ⋈ tsvector ⋈ SQL)
                ┌───────────────────┴─────────────────────┐
   Generic core │ documents · chunks · mentions ·          │
                │ document_contacts · embeddings ·          │
                │ source_syncs                              │
                └───────────────────▲─────────────────────┘
                                    │ load (upsert/chunk/embed/resolve)
                ┌───────────────────┴─────────────────────┐
   ETL framework│ Stacks::Etl::Connector (extract→normalize │
                │ →chunk→embed→load) · watermark · SystemTask│
                └───────────────────▲─────────────────────┘
                                    │ implements
                ┌───────────────────┴─────────────────────┐
   Connectors   │ Meet (source #1): Meet API + Drive,       │
                │ rich meetings/segments/participants,      │
                │ exclusion classifier, mention resolver    │
                │ … future: promoted slices from Notion/… │
                └──────────────────────────────────────────┘
```

### Code layout

```
lib/stacks/etl/
  connector.rb        # base: extract→classify→chunk→embed→resolve + watermark
  chunker.rb          # source-agnostic chunking (~512 tokens, overlap, stable spans)
  embedder.rb         # local embeddings via informers/ONNX (mxbai, swappable) → embeddings
  mention_resolver.rb # raw display-name/handle/email → Contact (+ confidence/queue)
  search.rb           # cross-source hybrid query layer (MCP-facing)
  meet/
    connector.rb · auth.rb · meet_api_source.rb · drive_source.rb · classifier.rb

app/models/
  document.rb · chunk.rb · mention.rb · document_contact.rb
  embedding.rb · source_sync.rb
  meeting.rb · meeting_participant.rb · meeting_transcript_segment.rb

app/services/mcp/     # read-only MCP server (mcp gem, Streamable HTTP)
app/admin/            # MCP menu → ETL subpages: meetings, documents, chunks,
                      #   mentions (resolve queue), source_syncs — browse/audit/debug
lib/tasks/etl.rake    # per-source backfill + ongoing sync (SystemTask-wrapped)
```

## Data model (Postgres + pgvector)

New extension: `enable_extension "vector"` (Heroku Postgres supports pgvector),
ActiveRecord integration via the `neighbor` gem.

### Generic core

**`documents`** — a logical unit from a source (transcript, thread, page, PR, file).
`source` (enum), `external_id` (unique per `[source, external_id]`),
`source_record_type`/`source_record_id` (polymorphic link to the rich row, e.g.
`Meeting`), `title`, `url`, `occurred_at`, `excluded` enum
(`not_excluded`/`auto_excluded`/`manually_excluded`/`manually_included`),
`excluded_reason` enum (`none`/`one_on_one`/`performance_review`/`compensation`/`hr`/
`offboarding`/`pip`/`title_keyword`/`manual`), `excluded_by`, `content_hash`
(idempotent skip when an unchanged document is re-fetched), `raw_metadata` jsonb.

(No `document_versions` table: Meet transcripts are immutable, so a document has one
content state. A re-fetch with a changed `content_hash` simply replaces the document's
chunks. Per-fetch version history is added when the first *mutable* source — e.g.
Notion — lands; the chunk spans below already make that a clean addition.)

**`chunks`** — the retrieval/provenance unit. `document_id`, `position`,
`content`, `start_offset`/`end_offset` (stable span within the document for later
`evidence` citation), `speaker_name` + `speaker_contact_id` (Meet), `occurred_at` and
`source` (denormalized for fast facet filtering), `tsvector` (GIN-indexed). **No
embedding column** — embeddings live in the side-table. Created only for
corpus-eligible documents.

**`embeddings`** — versioned, polymorphic vector store. `owner_type`/`owner_id`
(currently `Chunk`; later also extracted objects), `model` (e.g. `mxbai-embed-large-v1`),
`dimensions`, `embedding vector`, `created_at`. Unique on
`(owner_type, owner_id, model)`, HNSW index. Re-embed / swap models with no migration
and run two models side by side. (mxbai-embed-large-v1 = 1024 dims, under HNSW's
2000-dim cap; a >2000-dim model would use `halfvec` — noted, not needed now.)

**`contacts`** (existing — extended) — the canonical identity and FK target for
everyone. Already: `email` (unique), `sources` array, `apollo_id`/`apollo_data`,
`metadata` jsonb. **Added by this spec:** `display_name` (Meet gives names, not IDs).
Everyone — workspace or external — is just a `Contact`, created on first sighting; no
links to `AdminUser`/`Contributor`.

**`mentions`** — raw mention → canonical contact (resolution record + queue).
`chunk_id`, `raw_text` (display name / handle / email as it appeared),
`contact_id` (nullable),
`confidence`, `status` (`resolved`/`unresolved`/`ambiguous`). The **unresolved-mention
queue** is how "Drew said he'd do it" stops silently dropping when a transcript only
gives a display name. Reviewed/corrected in ActiveAdmin.

**`document_contacts`** — clean document↔contact facet for search filters.
`document_id`, `contact_id` (nullable), `email`, `name`, `role`
(`participant`/`speaker`/…). Populated from resolved mentions + connector participants.

**`source_syncs`** — ETL watermark + run record. `source`, `cursor` (jsonb — e.g. last
conference end-time, last Drive `modifiedTime`), `last_run_at`, `status`, `stats`,
`system_task_id`.

### Meet connector tables (rich per-source)

- **`meetings`** — `document` back-reference; `meet_conference_record_id` (unique,
  nullable), `drive_transcript_doc_id` (unique, nullable), `meet_source`
  (`meet_api`/`drive`), `title`, `organizer_email`, `started_at`, `ended_at`,
  `participant_count`, `raw_metadata`.
- **`meeting_participants`** — `meeting_id`, `name`, `email`, `contact_id`
  (nullable), `join_at`, `leave_at`.
- **`meeting_transcript_segments`** — `meeting_id`, `speaker_name`, `speaker_email`
  (when the API provides it), `speaker_contact_id` (nullable, via mention
  resolution), `started_at`, `ended_at`, `position`, `text`. Human-readable source of
  truth; the connector derives `chunks` from these (chunked per/across speaker turns).

A meeting is reconciled onto one row even if seen via both sources (API preferred for
attribution), keyed by the unique external IDs.

## ETL framework

`Stacks::Etl::Connector` is the base each source subclasses. The framework owns the
generic pipeline; a connector implements **extraction, its exclusion policy, and what
it promotes**:

- `#extract(since:)` → yields normalized documents: `{ external_id, title, url,
  occurred_at, content_hash, contacts:[{email,name,role}], content_segments,
  raw_metadata, build_source_record: -> { … } }`.
- `#exclusion_for(normalized)` → `[excluded, excluded_reason]` (default `not_excluded`).

Per document, inside a transaction:

1. Upsert `documents` by `[source, external_id]`; if `content_hash` is unchanged,
   skip; if changed, replace the document's chunks.
2. Build/refresh the rich source record (e.g. `Meeting` + segments + participants).
3. **Resolve contacts** → `mentions` (+ `document_contacts`, segment/participant
   `contact_id`) via `MentionResolver`: email → `Contact` (`create_or_find_by`,
   tagging the `meet` source, created if missing); display-name-only speakers resolved
   fuzzily against the meeting's participants; unresolved names land in the queue.
4. Run `exclusion_for` (unless human-locked: `manually_excluded`/`manually_included`
   are never overwritten).
5. For corpus-eligible documents only: chunk the document → `chunks`, then **embed
   inline** → `embeddings`. A failed embedding leaves the chunk unembedded and
   retryable next run.
6. Advance the `source_syncs` watermark; record stats on the `SystemTask`.

Following the established Stacks pattern (no job framework; periodic work is rake
tasks invoked by Heroku Scheduler, each wrapped in a `SystemTask` — cf.
`stacks:sync_forecast`, `stacks:sync_notion`). The serial run is the single writer:

- `stacks:etl:backfill_meet[days]` — one-off bounded Drive sweep.
- `stacks:etl:sync_meet` — ongoing Meet API capture, scheduled.
- Future sources add `stacks:etl:sync_<source>` with no change to core or search.

## Exclusion layer (generalized)

Capture everything; gate by the document `excluded` state. Corpus eligibility =
`excluded IN (not_excluded, manually_included)`. Excluded documents keep their rich
records (readable by a human in ActiveAdmin) but are **never chunked, embedded, or
returned by any MCP tool** — structurally unreachable.

The **Meet classifier** sets initial state on new meetings: 1:1
(`participant_count <= 2`) → `one_on_one`; title matches (case-insensitive):
`1:1`/`1 on 1`/`one-on-one` → `one_on_one`; `performance review`/`review` →
`performance_review`; `salary`/`comp`/`compensation` → `compensation`; `hr` → `hr`;
`offboarding`/`termination` → `offboarding`; `pip` → `pip`; other configured keyword →
`title_keyword`; otherwise `not_excluded`. Humans reclassify in ActiveAdmin
(`manually_included` is sticky). Future connectors supply their own policy.

## Embeddings

- **Local, no API key** — `mixedbread-ai/mxbai-embed-large-v1` (1024 dims, a top-tier
  open English embedding model) run via the `informers` gem (ONNX Runtime), wrapped
  behind `Stacks::Etl::Embedder` so the model is swappable. Embeddings are computed
  **on our own infrastructure** — no chunk text is sent to a third party, a privacy win
  for internal-meeting content. Per the model's convention, search *queries* get the
  prefix `"Represent this sentence for searching relevant passages: "`; stored chunks
  do not.
- Written to the `embeddings` side-table per chunk, corpus-eligible content only,
  inline during the sync run. Idempotent per `(owner, model)`.
- Deploy note: we run the **quantized** ONNX variant (~340 MB, int8) — fits a standard dyno; `sync_meet` /
  `backfill_meet` load the memoized model once per run. The model downloads and caches
  on first run.

## MCP server (read-only, cross-source)

- Official **`mcp` Ruby gem**, **Streamable-HTTP** Rack app mounted under the existing
  `api` namespace at `/mcp`, so claude.ai and Claude Code can both connect. Tools are
  classes carrying `read_only_hint`. Run **stateless** if more than one web dyno
  (the transport otherwise keeps session/SSE state in memory).
- **Security:** reuse the existing **private API key** (`X-Api-Key` header, `config[:stacks][:private_api_key]`, same as `ApiController#check_private_api_key!`), **audit-log every call**, and
  **treat all retrieved content as untrusted** — indexed text was written by people
  who are not the agent's operator, so tool results are tagged as data, not
  instructions (prompt-injection surface in both directions).
- Tools (over the generic core, every one restricted to corpus-eligible documents):
  - `search(query, mode: keyword|semantic|hybrid, filters)` — `filters`: `source`,
    `contact`, `date_range`. Hybrid = full-text rank ⋈ vector similarity over
    `embeddings`. Returns chunks with document context.
  - `list_documents(filters)` · `get_document(id)` (renders source-specific detail —
    for Meet, ordered speaker segments) · `list_sources()` (ingested sources +
    freshness).

Because search is over the generic core, **every future connector is searchable the
moment it loads** — no per-source MCP work.

## Identity resolution

Everyone resolves to a `Contact` (the spine):

1. **Has an email** (Meet API participants): `email` → `Contact` via the unique-email
   index (`create_or_find_by`, lowercased, `meet` source tag). Created if missing —
   workspace or external alike, with no `AdminUser`/`Contributor` reconciliation.
2. **Display name only** (common in transcript entries): `MentionResolver` does fuzzy
   display-name → `Contact` matching, scoped first to the meeting's known participants,
   with a confidence score; low/no confidence routes to the unresolved-mention queue
   for human resolution in ActiveAdmin.

Nobody is dropped. (The target schema's `person_identities` — GitHub/Figma/Twist
handles — arrives with those sources; email is the only key the current sources need.)

## Admin UI (ActiveAdmin)

A new **top-level `MCP` menu** in ActiveAdmin, with an **`ETL` subpage**, so the whole
pipeline is inspectable visually for debugging:

- **Meetings** — every ingested meeting: title, organizer, time, participant count,
  `meet_source`, `excluded`/`excluded_reason`, and drill-down to its transcript
  segments (speaker-attributed) and derived chunks. The place to eyeball "did this
  meeting come in correctly."
- **Documents** — the generic `documents` rows with `source`, `occurred_at`,
  `excluded` state, chunk/embedding counts; filterable by source and exclusion.
- **Chunks** — content + span + which `embeddings` (model) exist, to verify
  chunking/embedding.
- **Mentions** — the **unresolved-mention queue**: raw display-names awaiting a
  `Contact`, with a one-click resolve/assign action.
- **Source syncs** — per-source watermark, last run, status, stats (the run log).

Reclassification (exclude / `manually_included`) happens here too; it is also the only
surface that can read **excluded** transcripts (never exposed via MCP).

## Governance & consent

Permanently storing org communications (starting with everyone's transcribed speech)
carries real consent/legal weight that varies by jurisdiction. Recorded here (the org
may take or leave these):

- A **one-time notice** to employees that transcribed meetings (and, as sources are
  added, other communications) are retained and searchable by internal tooling, with
  the exclusion categories listed.
- **The private API key + audit logging** are the access boundary; treat the key
  as secrets, rotate them.
- The **exclusion layer is the privacy control**: sensitive material is retained for
  the human record but walled off from the agent.
- ActiveAdmin (`Document`/`Meeting`/`Mention`) is the audit/review surface and the
  only path to read excluded content. Each new source must declare its exclusion
  policy before it loads.

## Error handling

- Per-user impersonation failures (no Drive access, revoked grant) are logged and
  skipped; one user never aborts a sweep. Failures surface on the
  `SystemTask`/`source_syncs` record.
- Google API rate limits / `ClientError` follow the existing `Stacks::Calendar`
  retry/rescue pattern.
- Embedding failures leave the chunk unembedded and retryable next run.
- A connector raising mid-run advances the watermark only for fully-processed
  documents, so re-runs resume cleanly.
- Content without a transcript/body is simply absent — not an error.

## Testing

- Core: idempotent upsert (re-ingest no-dupes; unchanged `content_hash` skips;
  changed content replaces chunks; excluded docs get no chunks/embeddings);
  embeddings side-table uniqueness per `(owner, model)`; model swap leaves old vectors.
- Contacts/mentions: email → `Contact` create/find (made if missing); display-name
  fuzzy resolution; low-confidence routes to the unresolved queue; nobody dropped.
- ETL framework: watermark advance/resume; exclusion-policy precedence (auto vs human
  locks).
- Meet connector: normalization from fixture Meet-API and Drive-Doc payloads;
  classifier rules (1:1 by count, each title family); both sources reconcile to one
  meeting.
- Search: keyword, semantic, hybrid each exclude walled-off documents and honour
  `source`/`contact`/`date` filters.
- MCP: each tool refuses excluded content; auth required; calls audit-logged;
  `list_sources` freshness.

## Target schema (north star — for forward-compatibility only)

The full institutional-memory design is 16 tables in five layers; **bold = built in
this foundation spec**, the rest belong to the later intelligence spec:

- **Identity:** **`contacts`** (= existing "everyone we know" table, the spine, the FK
  target for everyone), `person_identities` (later, for non-email handles).
- Org structure: `projects`, `milestones` (synced from Notion).
- **Raw substrate:** **`documents`**, **`chunks`**,
  **`mentions`** (+ **`document_contacts`**, **`source_syncs`** as our additions).
- Extracted objects: `decisions`, `commitments`, `tasks`, `opportunities`.
- Cross-cutting spine: `evidence`, `events` (append-only bitemporal), `links` (typed
  edges / knowledge graph), **`embeddings`** (built now, polymorphic so objects embed
  later). Plus views: `v_open_commitments`, `v_overdue_commitments`,
  `v_project_health`, `v_recent_decisions`, `v_live_opportunities`.

The foundation's chunk spans, polymorphic embeddings, and mention
resolution exist specifically so the intelligence layer slots on top without rework.

## Open items for the implementation plan

- Confirm Heroku Postgres pgvector availability/version on the target plan.
- Confirm the Drive transcript-Doc identification heuristic (folder + name pattern vs.
  Docs export MIME) against a real "Meet Recordings" folder.
- Scope the `MentionResolver` effort — fuzzy display-name matching is the riskiest
  Meet-specific piece (transcripts give names, not IDs).
- Confirm `informers` + `onnxruntime` native lib builds in the Heroku slug, and that the quantized mxbai model downloads/caches on the dyno on first run (consider baking it into the slug or a persistent cache).
- Decide chunking parameters (size/overlap) and per-segment vs across-segment chunking
  for Meet.
- Confirm `mcp` gem Streamable-HTTP statelessness given the prod dyno count.
