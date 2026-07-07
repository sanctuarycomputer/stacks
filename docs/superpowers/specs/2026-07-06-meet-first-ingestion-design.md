# Meeting-First Meet Ingestion — Design

**Goal:** Make the *daily* Meet ingestion robust by driving it from the **Meet API**
(meeting-first): structured transcripts from the API, and Gemini notes reached via the
transcript's `docsDestination` pointer — so the brittle Drive-filename-scan + markdown
**transcript** parsing is demoted to the historical **backfill** only, behind a canary that
fails loud on a Google format change.

## Why

A live Meet API probe established:
1. `conferenceRecords.list` is meeting-first discovery (~66/month for one admin; ~30-day
   retention).
2. Each `conferenceRecords.transcripts[].docsDestination.document` points **directly** at the
   combined "`… - Notes by Gemini`" Drive doc.
3. Transcript **entries** are structured (`participant` id + `text` + `start_time`) — no
   markdown parsing, cannot silently break.
4. The API does **not** expose the Gemini notes (Summary/Decisions/Next-steps) — those live
   only in the Drive doc's markdown.
5. API retention is ~30 days, so a *year* backfill can only come from Drive.

The prior increment (PR #128) parses the combined doc's markdown for BOTH transcript and notes
in the daily job. The transcript parse is brittle (it already broke once on Google's bold
`**Name:**` speaker format). This design keeps #128's parsers but changes **where the recent
transcript comes from** (the API, structured) and **who discovers notes** (`docsDestination`,
not a filename scan).

## Guiding principles (unchanged)

- **Privacy wall:** a transcript is classified by ACTUAL attendance (API participant count, or
  backfill distinct speakers), never invited count; notes inherit the transcript's
  `excluded`/`excluded_reason` verbatim, else (notes-only) fall back to the invited count.
- **Progressive enhancement:** transcripts stay load-bearing; notes are additive.
- **One transcript per meeting** via the `for_drive_doc` reverse-dedup.
- **Two Documents, one Meeting:** `source: meet` transcript + `source: gemini_notes` notes.

## The three paths

### A. Recent transcripts — Meet API (unchanged)
`MeetApiSource` pulls structured entries per conference record; head-count =
`participants.size` (real attendance). Transcript Document: `source: meet`,
`external_id: cr.name`, `raw_metadata.drive_doc_id = docsDestination`.

### B. Recent notes — follow `docsDestination` (NEW, meeting-first)
For each conference record **that has a transcript**, after emitting the transcript record,
`MeetApiSource` also emits a **notes record**:
- Export the `docsDestination` doc (`text/markdown`) with the source's Drive service.
- `split_transcript` the export and keep the **notes portion only** (everything before the
  transcript heading) — the transcript itself comes structured from the API, so its markdown
  tab is ignored.
- Parse the notes body + invited emails via the shared `NotesDoc` parser.
- Emit `source: gemini_notes`, `external_id: docsDestination`, `transcript_doc_id: docsDestination`,
  same Meeting. It inherits the transcript's exclusion through the existing
  `for_drive_doc(docsDestination)` join (the transcript's `drive_doc_id` matches).
- **Best-effort:** if the export raises (doc not ready, or the impersonated user lacks access
  to the organizer's doc), skip the notes record for this run — never abort the transcript
  ingest. The `LOOKBACK` re-check picks it up on a later sweep.
- **Order:** transcript record yielded first, notes second. If the transcript is *deferred* by
  reverse-dedup (a Drive/older Document already covers it), the notes record is still emitted
  and inherits from that existing Document (emit `[transcript?, notes].compact`).

**No markdown transcript parsing on this path.**

### C. Notes-only meetings + year backfill — `GeminiNotesSource` (Drive scan)
`GeminiNotesSource` gains a `parse_transcript:` flag (default `false`):

- **Daily mode (`parse_transcript: false`, from `sync_gemini_notes_all`):** emit **notes only**,
  and only for docs whose meeting has **no transcript Document** yet. The skip check uses the
  `file.id` from `list_files` **before** exporting (`Document.for_drive_doc(file.id).exists?`),
  so transcript-bearing docs are skipped without a wasted export — the API path (which runs
  first in `sync_all`) already emitted their notes. Only genuinely notes-only docs (transcription
  off) are exported + ingested. **Never** parses a markdown transcript.
- **Backfill mode (`parse_transcript: true`, from `backfill_meet_all`):** the full #128
  combined-doc handling — `split_transcript` → strip bold → speaker parse → a `meet` transcript
  (when no existing transcript) **plus** notes. This is the only place the brittle markdown
  transcript parse survives; the API can't reach these old meetings.

### The canary (backfill path)
When `parse_transcript: true` and a doc's transcript section is **present with substantial
content** (length over a small threshold, e.g. 200 chars after the heading) but
`parse_segments` yields **0 speakers**, log `Rails.logger.error(...)` and mark the sweep's
`SystemTask` errored — a Google format change fails loud instead of silently degrading to
notes-only. A genuinely empty section ("Transcription ended after 00:01:30") is below the
threshold and does not alert.

## Components

- **`Stacks::Etl::Meet::NotesDoc` (new shared module).** Extracts the reusable notes parsing
  from #128's `GeminiNotesSource`: `notes_body_segments(markdown, occurred_at:)` (notes portion
  via `split_transcript`, footer strip, paragraph segments with `speaker_name: nil`),
  `invited_emails_from(markdown)`. Included by both `MeetApiSource` and `GeminiNotesSource`.
  `split_transcript`, `TranscriptSegments` (+ bold-strip), and the ingest-time inheritance
  (`Connector#exclusion_for` resolving `transcript_doc_id`) are **reused as-is** from #128.
- **`MeetApiSource` (modify).** Add a Drive service (`Auth.drive_service(sub: user)`); after
  the transcript record, build+yield the `docsDestination` notes record (best-effort). Yields
  `[transcript?, notes?].compact` per conference record.
- **`GeminiNotesSource` (modify).** Add `parse_transcript:` (default `false`); daily mode emits
  notes-only for no-transcript docs; backfill mode keeps #128 behavior + the canary.
- **`lib/tasks/etl.rake` (modify).** `sync_gemini_notes_all` → notes-only daily (flag `false`);
  `backfill_meet_all`'s notes sweep → `parse_transcript: true`. Thread the flag through
  `Meet::Connector` (a `parse_transcript:` kwarg passed to `GeminiNotesSource`).

## Data flow (daily `sync_all`)
1. `sync_meet_all` (`MeetApiSource`): per conference record → structured transcript + notes via
   `docsDestination`, both on one Meeting; notes inherit the participant-count exclusion.
2. `sync_gemini_notes_all` (`GeminiNotesSource`, `parse_transcript: false`): Drive-scan; ingest
   notes-only for meetings with no transcript Document; skip transcript-bearing (already done).

## Data flow (year `backfill_meet_all[N]`)
1. `DriveSource` (historical transcripts, `name contains 'Transcript'`) — unchanged.
2. `GeminiNotesSource` (`parse_transcript: true`): combined-doc handling — markdown transcript
   (when none exists) + notes, with the canary.

## Privacy / dedup (unchanged from #128)
- Transcript classified by real attendance; notes inherit or fall back to invited count.
- `for_drive_doc(id)` (meet-scoped, matches `external_id` OR `raw_metadata.drive_doc_id`)
  guarantees one transcript Document per meeting and drives notes inheritance.
- Non-eligible docs have their chunks destroyed.

## Error handling
- `docsDestination` export failure → skip notes this run (best-effort), retried via `LOOKBACK`.
- A conference record with no transcript → `MeetApiSource` skips it (as today); its notes (if
  any) are a notes-only meeting handled by the daily Drive scan.
- Idempotent re-ingest via `(source, external_id)` + `content_hash`.

## Testing
- **API notes:** a mocked conference record with a transcript + a mocked Drive export yields a
  `meet` transcript and a `gemini_notes` notes record on one Meeting; the notes inherit the
  participant-count exclusion (1:1 by participants → both walled).
- **Best-effort:** a `docsDestination` export that raises → transcript still ingested, no notes,
  no crash.
- **Deferred transcript:** an existing Drive transcript Document for the same `docsDestination`
  → API transcript defers, notes still emitted and inherit from it.
- **Notes-only daily:** `GeminiNotesSource(parse_transcript: false)` emits notes only for a
  no-transcript doc and skips a doc whose meeting already has a transcript Document; never
  yields a `meet` record.
- **Backfill:** `GeminiNotesSource(parse_transcript: true)` still yields a markdown transcript +
  notes (with the bold-format speaker parse).
- **Canary:** a transcript section with content but 0 parsed speakers → logs an error / marks
  the SystemTask errored; a tiny empty section does not.
- **Privacy wall e2e** through the connector for the API path.

## Out of scope
- Structured extraction of Next-steps/Decisions into commitment records (spec #2).
- Per-meeting Drive title-search for notes-only meetings (rejected: title matching is fragile;
  the single daily Drive scan is used instead).
- Changing the API retention or backfill windows.

## Migration / rollout
This supersedes PR #128 by evolving the same branch. Ships alongside the existing retroactive
runbook: after deploy, the daily job is meeting-first; a one-time `backfill_meet_all[365]`
(with `parse_transcript: true`) recovers historical transcripts + notes.
