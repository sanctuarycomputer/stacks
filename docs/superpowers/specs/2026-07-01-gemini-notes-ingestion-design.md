# Gemini Notes Ingestion — Design

**Goal:** Ingest Google Meet "Notes by Gemini" docs into the org vector corpus as a
**progressive enhancement** to the existing Meet-transcript ETL — searchable alongside
transcripts, subject to the same privacy wall — without making anything depend on notes.

## Guiding principle: progressive enhancement, not load-bearing

Transcripts remain the primary, load-bearing artifact. Gemini notes are often **absent**
(users disable "Take notes with Gemini"; meetings predate the feature), so search,
attribution, and the exclusion wall must all work from the transcript alone. Notes only
**add** signal when present: a distilled summary, decisions, next steps, and an extra
source of attendee emails. Nothing in the system may require notes to exist.

## Scope (decided)

- **Search-only.** Each notes doc is ingested as searchable content (chunked + embedded).
  We do **not** parse Next-steps/Decisions into structured commitment/decision records in
  this increment — that belongs to the spec-#2 intelligence layer, which is designed to
  draw from transcripts primarily (so accountability tracking never leans solely on
  Gemini). The Next-steps/Decisions text is still fully searchable as content.
- **Notes-only meetings are ingested standalone.** If a notes doc exists with no
  transcript (transcription off, notes on), the notes become that meeting's document on
  their own, classified independently. We do not drop meetings whose only artifact is notes.

## What a Gemini notes doc looks like (from real prod data)

Drive Google Doc, named `"<Title> - YYYY/MM/DD HH:MM <TZ> - Notes by Gemini"` (same
dash-date stamp as transcripts). Body (markdown-ish) contains:

- `Invited:` — attendee names as `[Name](mailto:email)` links (emails inline).
- `Meeting records [Transcript](https://docs.google.com/document/d/<TRANSCRIPT_DOC_ID>/…)`
  — present when a transcript exists; **the join key**. Absent for notes-only meetings.
- `### Summary`, `### Decisions` (Aligned / Needs Further Discussion), `### Next steps`
  (`[Owner] Action: Description`), `### Details`.

## Architecture (Approach A: notes are "another source")

Notes reuse the existing multi-source pipeline (Document → Chunk → Embedding → MCP) exactly
as another source. Transcripts are untouched.

### Data model
- `Document.source` and `Chunk.source` enums gain `gemini_notes: 1` (alongside `meet: 0`).
- `Meeting has_many :documents, as: :source_record` — a meeting can own a transcript
  Document **and** a notes Document (both `source_record` → the same Meeting). No other
  Meeting change.
- The notes Document is keyed `find_or_initialize_by(source: :gemini_notes,
  external_id: <notes Drive doc id>)` — same idempotency as transcripts.

### `Stacks::Etl::Meet::GeminiNotesSource` (new, parallel to `DriveSource`)
A focused source class that shares Drive `Auth`, `clean_title`, and date-stamp stripping
with `DriveSource`. It:
- Queries Drive: `mimeType='application/vnd.google-apps.document' and name contains 'Notes by Gemini'`
  (plus the same `createdTime` window bounds as `DriveSource`, incl. `until_time`).
- Exports each doc (`text/plain`) and parses:
  - **title** via `clean_title` (strips `- Notes by Gemini` suffix + the date stamp),
  - **transcript doc id** from the `…/document/d/<id>/…` in the Transcript link (nil if absent),
  - **Invited emails** from the `mailto:` links (skip room resources),
  - **body** = the Summary/Decisions/Next-steps/Details text → the searchable segments.
- Yields a normalized hash with `source: :gemini_notes`, the parsed fields, a
  `transcript_doc_id` join hint, and a `build_source_record` that links/creates the Meeting.

### Join + ordering
In the Drive backfill, **transcripts are swept first (`DriveSource`), notes second
(`GeminiNotesSource`)** — so a notes doc's transcript Document already exists when the
notes are processed.
- **Joined:** parse the transcript doc id → find `Document(source: :meet,
  external_id: <transcript_doc_id>)` → attach the notes Document's `source_record` to that
  Document's `Meeting`.
- **Standalone:** no transcript link, or transcript Document not found → create/find a
  notes-only Meeting keyed on the notes Drive doc id (`meet_source: :gemini_notes`),
  classified independently.

### Exclusion inheritance (privacy — non-negotiable)
- **Joined:** the notes Document copies the linked transcript Document's `excluded` /
  `excluded_reason` verbatim (do NOT re-derive) — the wall is provably identical. A 1:1's
  notes are excluded exactly like its transcript.
- **Standalone:** classified via the existing `Classifier(title:, participant_count:)`,
  where `participant_count` = the notes' Invited count.

The connector's exclusion path is extended so a notes `normalized` carries either
`inherit_exclusion: [excluded, reason]` (joined) or the title + Invited count (standalone).

### Attribution
The notes' Invited emails become the notes Document's `document_contacts` (resolved to the
same Contacts via `MentionResolver.resolve_email`). This **supplements** attribution;
transcript-only meetings still use the Calendar match. Contact source tag stays `etl:meet`.

### Chunking / embedding
The notes body flows through the existing `Chunker`/`Embedder`, modeled as segments with
`speaker_name: nil` and `occurred_at` = the meeting time. Notes are short → a handful of
chunks. Corpus-eligible notes get chunked + embedded exactly like transcripts.

### MCP surface
No new tools. Notes appear in `search` / `list_documents` / `get_document`, tagged
`source: gemini_notes` (the existing `source` filter lets the agent request transcripts,
notes, or both). Excluded notes are never returned (`corpus_eligible` filter).

### Sweep windows (important: notes are Drive-only)
The transcript's API-recent / Drive-older time-partition does **not** apply to notes —
notes exist only as Drive Docs, never via the Meet API. So a Gemini-notes sweep is always
Drive-based, deduped simply by the notes Drive doc id (single source, no cross-source merge
risk). Notes are therefore swept in **both** entry points:
- **Nightly `sync_all`:** after `sync_meet_all` (API transcripts, recent window) runs a
  Gemini-notes Drive sweep over the same recent window — otherwise recent notes (< the
  7-day Drive backfill guard) would never be captured, since the API sync can't see notes.
- **`backfill_meet_all[N]`:** after `DriveSource` (historical transcripts) runs
  `GeminiNotesSource` over the historical window.

In both, **transcripts are swept before notes** so the join target exists. Notes have no
`until_time` overlap-guard (no API counterpart to collide with); the notes-doc-id dedup
makes overlapping windows across runs harmless.

## Error handling
- **Best-effort parsing:** a notes doc that fails to export/parse is skipped, never
  breaking the backfill (same philosophy as Calendar enrichment).
- **Unrecognized structure:** a notes doc with no parseable sections falls back to
  ingesting its raw exported text (still searchable) rather than being dropped.
- **Idempotent re-ingest:** keyed on the notes Drive doc id; content-hash gate avoids
  re-chunking unchanged notes.

## Testing
- `GeminiNotesSource` parsing: title cleaning, transcript-doc-id extraction (present +
  absent), Invited email extraction (incl. skipping room resources), body extraction.
- **Join:** a notes doc links to the existing transcript's Meeting (same `source_record`).
- **Exclusion inheritance:** a 1:1 transcript's notes are `excluded` with no
  chunks/embeddings; a standalone 1:1 notes doc is classified excluded on its own.
- **Attribution:** Invited emails resolve to the notes Document's `document_contacts`.
- **MCP:** notes are searchable, filterable by `source`, and walled off when excluded.

## Out of scope (future / spec #2)
- Structured extraction of Next-steps → commitments and Decisions → decision records, with
  owner-name → Contact resolution and cross-meeting accountability queries.
- Any dependence on notes for core search/attribution/exclusion.
