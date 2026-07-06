# Meet Combined Notes+Transcript Format — Design

**Goal:** Correctly ingest Google Meet's newer "Notes by Gemini" docs, which embed the
transcript as a tab in the same file (instead of a separate "`… - Transcript`" doc), so the
transcript lands as a proper `source: meet` Document classified by real speakers — not
buried inside a `gemini_notes` doc and mis-classified on invited count.

## Background

Google changed the Meet output format. A newer meeting no longer produces a separate
"`<Title> - <date> - Transcript`" Google Doc. It produces a **single**
"`<Title> - <date> - Notes by Gemini`" doc whose markdown export contains BOTH a `# 📝 Notes`
section AND a `# 📖 Transcript` section (tabs, flattened by the `text/markdown` export). Its
"Meeting records [Transcript](…/document/d/<ID>…?tab=t.xxx)" link is a `#tab=` deep-link whose
`<ID>` is **the notes doc's own file id** (self-referencing).

Current behavior (bug): `DriveSource` matches `name contains 'Transcript'`, so it only finds
OLD-format standalone transcript docs. Newer transcripts live inside the notes docs.
`GeminiNotesSource` ingests those as `source: gemini_notes`, chunking the whole markdown
(notes + transcript together), and `transcript_doc_id_from` extracts the doc's OWN id (a
self-link) that never resolves — so every combined doc falls to the standalone path and is
classified on **invited count**, not actual speakers. Two problems:

1. **Mis-tagging** — full transcript content is tagged `gemini_notes`, so a source-filtered
   "transcripts only" query misses it, and notes + transcript are conflated in one Document.
2. **Weakened privacy head-count** — these docs now carry FULL transcripts but are excluded
   on invited count. A benign-titled private meeting with >2 invited (e.g. a no-show, or an
   HR/comp meeting) could be classified eligible and expose its embedded transcript. The
   transcript path deliberately uses ACTUAL attendance (distinct speakers) to avoid exactly
   this.

Measured on prod (2026-07-06): 677 `gemini_notes` docs, 263 with a transcript link, and
**263/263 self-referencing** — the combined format is universal for recent meetings. The
earlier "197 missing transcripts" figure was entirely an artifact of this self-link, NOT a
crash and NOT related to PR #122 (whose `Contact#dedupe!` fix lives only in
`stacks:sync_contacts`, not the ETL path).

## Guiding principles

- **Progressive enhancement, transcripts load-bearing.** This is additive. `MeetApiSource`,
  `DriveSource` (old-format), and the base `Connector` are unchanged except for extracting a
  shared speaker parser. Nothing depends on the combined format existing.
- **Privacy wall is non-negotiable.** Excluded meetings are never chunked/embedded/returned.
  The split transcript is classified by actual speakers; the notes inherit its decision
  verbatim.
- **Reuse the existing machinery.** The fix deliberately turns the self-referencing link from
  a bug into the correct join key, so exclusion inheritance flows through the join path that
  already exists — no new inherit mechanism.

## Detection & splitting

A combined doc is a "Notes by Gemini" file whose exported markdown's transcript link points
to its own id: `transcript_doc_id_from(markdown) == file.id`.

When detected, split the markdown at the **transcript heading** — the first markdown heading
(`#`/`##`) whose text contains "Transcript" (e.g. `# 📖 Transcript`, tolerant of the emoji so
a future Google change doesn't break it; the inline "Meeting records [Transcript](…)" link is
not a heading and is not matched):
- **notes body** = everything before the transcript heading (Summary / Decisions / Next steps
  / Details),
- **transcript** = everything from the transcript heading onward.

If detection says combined but **no transcript heading is found** (unexpected markup), do not
split — fall back to notes-only rather than emitting a broken transcript.

Parse the transcript with the shared speaker parser (`SPEAKER_LINE` / `parse_segments`).
- If the transcript section yields **≥1 speaker segment**, it is a real transcript → emit it.
- If it yields **0 speaker segments** (short/aborted meeting: "Transcription ended after
  00:01:30", "A summary wasn't produced…"), there is no transcript to ingest → the doc stays
  a notes-only record with today's behavior (standalone, classified on invited count). No
  empty `meet` Document is created.

## Data model — two records from one file

For a combined doc with a real transcript, `GeminiNotesSource#each_meeting` yields **two**
normalized records from the one file, **transcript first**:

1. **Transcript** — `source: meet`, `external_id: file.id`, speaker `segments` (each stamped
   `started_at = file.created_time`, since the embedded transcript has no per-line
   timestamps), `participant_count: distinct_speaker_count(segments)`,
   `raw_metadata: { 'drive_doc_id' => file.id }`, `build_source_record` → Meeting keyed
   `find_or_initialize_by(drive_transcript_doc_id: file.id)` (exactly like `DriveSource`),
   `meet_source: :drive`.
2. **Notes** — `source: gemini_notes`, `external_id: file.id`, `transcript_doc_id: file.id`
   (self), notes-body-only segments, invited-email contacts, `build_source_record` → the same
   Meeting.

Because `Document` is keyed on `(source, external_id)`, `(meet, file.id)` and
`(gemini_notes, file.id)` are two distinct rows that share one Meeting.

**Attribution:** the split transcript reuses the **Invited emails already parsed from the same
doc** as its `document_contacts` (same source tag `etl:meet`), so no separate Calendar-match
call is needed — the emails are right there in the notes portion. (Head-count still comes from
distinct speakers, never the invited count — attribution and head-count are separate concerns,
as in `DriveSource`.)

### The self-link becomes the join key
Once a `meet` Document exists keyed on `file.id`, the notes' existing join
(`Document.for_drive_doc(file.id)` — the fix from PR #121) resolves to it. So the notes
**inherit the transcript's `excluded`/`excluded_reason` verbatim** through the join+inherit
path that already exists. Emitting transcript-first guarantees the transcript Document (and
its Meeting) exist when the notes record is ingested in the same sweep.

## Exclusion / privacy

- The **transcript** is classified by the connector's normal `exclusion_for` using
  `participant_count = distinct_speaker_count` — the actual-attendance head-count, identical
  to `DriveSource`. (0 speakers only occurs on the no-transcript fallback, which is not
  emitted as a transcript.)
- The **notes** inherit the transcript's decision via the join (no re-classification on
  invited count when a real transcript is present).
- **Reverse-dedup unchanged:** the split transcript emission carries `drive_doc_id = file.id`
  and applies the same reverse-dedup as `DriveSource` — if the Meet API already ingested this
  meeting's transcript (`raw_metadata->>'drive_doc_id' = file.id` under a conference-record
  `external_id`), the split transcript defers to it, and the notes inherit from that existing
  Document. One transcript Document per meeting regardless of which source saw it first.

## Retroactive re-processing

The 263 combined docs already ingested are single `gemini_notes` Documents on standalone
`gemini_notes` Meetings, classified on invited count. After deploy:

1. **Wipe** the combined-format rows: delete `Document`s where `source: gemini_notes` AND the
   doc is combined-format (its stored `raw_metadata->>'transcript_doc_id'` equals its own
   `external_id`). Then delete `Meeting`s with `meet_source: :gemini_notes` that are **left
   with no Documents** after that delete — this precisely targets the orphaned combined-format
   meetings while **preserving legitimate notes-only meetings** (transcription genuinely off;
   their notes doc has a `NULL` transcript_doc_id, so it is not deleted and its meeting keeps a
   Document). Mirrors the self-heal cleanup used twice before, avoiding orphans / the re-link
   gap.
2. **Re-run** `backfill_meet_all[365]` (+ the nightly `sync_all` keeps recent current). The
   combined docs re-ingest split: a `meet` transcript Document (real-speaker classification) +
   a `gemini_notes` notes Document inheriting it, both on one Meeting.

Idempotent everywhere else — genuinely new combined docs flow through the fixed path on the
next sweep with no wipe needed.

## Code structure

- **Shared speaker parser.** Extract `SPEAKER_LINE`, `NAME_HEAD`/`NAME_TAIL`/`ANON_LABEL`,
  `parse_segments`, and `distinct_speaker_count` from `DriveSource` into a shared module
  (e.g. `Stacks::Etl::Meet::TranscriptSegments`) that both `DriveSource` and
  `GeminiNotesSource` include. `DriveSource` behavior is unchanged — this is a pure move.
- **`GeminiNotesSource`.** Add combined-format detection, markdown splitting on the
  `# 📖 Transcript` heading, the two-record yield, and the no-transcript fallback. The
  existing notes parsing (invited emails, body segments, footer strip) applies to the
  notes-body portion only.
- **`Connector` (Meet).** No change — it already ingests one normalized record at a time and
  honors `source` per record; two yields from one file are ingested as two Documents.

## Error handling

- A doc that fails to export/parse is skipped, never breaking the sweep (existing philosophy).
- A combined doc whose transcript section is unparseable/empty falls back to notes-only
  (above) rather than emitting a broken transcript.
- Idempotent re-ingest via `(source, external_id)` + `content_hash`.

## Testing

- **Detection:** self-referencing link → combined; external transcript link (old format) →
  not combined; no link → not combined.
- **Split:** markdown with `# 📖 Transcript` cut into notes-body vs transcript; notes body no
  longer contains transcript dialogue.
- **Two-record yield:** a combined doc yields a `meet` record (speaker segments) then a
  `gemini_notes` record (self `transcript_doc_id`), both building the same Meeting.
- **Privacy head-count:** a 1:1 combined doc (2 distinct speakers) → transcript
  `auto_excluded`/`one_on_one`, and the notes inherit it → neither chunked. A combined doc
  with >2 invited but ≤2 actual speakers is still excluded (speakers, not invited, drive the
  head-count).
- **Empty transcript:** "Transcription ended after…" with no speaker lines → no `meet`
  Document; notes-only standalone (current behavior).
- **Reverse-dedup:** an API-ingested transcript (`drive_doc_id = file.id`) already present →
  the split transcript defers; the notes inherit from the API Document.
- **Shared parser move:** existing `DriveSource` speaker tests still pass unchanged.

## Out of scope

- Structured extraction of Next-steps/Decisions into commitment/decision records (spec #2).
- Backfilling transcripts for meetings whose ONLY artifact is a notes doc with an empty
  transcript section (there is no transcript to ingest).
- Changing `MeetApiSource` or old-format `DriveSource` behavior.
