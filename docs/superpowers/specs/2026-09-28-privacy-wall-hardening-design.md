# Privacy wall hardening (G1–G4)

**Goal.** `Document.corpus_eligible` is the only thing between HR, comp and 1:1 content and the agent.
This change makes the wall stricter at ingest, default-deny for new sources, and tested on every read path.
It also re-applies the rules to documents already stored.

## What prod looked like (2026-09-28, counts only)

| source | eligible | walled off |
|---|---|---|
| meet transcripts | 404 | 164 (all as 1:1) |
| gemini notes | 1,004 | 589 (all as 1:1) |
| google groups | 51,754 | **0** |

- No document has ever been walled off by a title rule. The Groups connector never runs the rules, so about 84 threads
  with subjects about salary, HR, PIP, termination, bonus or promotion are eligible today (admin@, jobs@, nyc@, dev@, hello@…).
- 646 eligible notes have no transcript joined, so nobody knows who actually attended.

## Leak paths found in the current code (fixed here)

1. **Groups never classified** (above).
2. **`get_document` on a notes doc returns the linked transcript's segments.** Notes and transcript share one `Meeting`,
   and the tool reads `meeting.segments`. If the transcript is walled off and the notes are not, the transcript text leaks.
3. **The Reindexer does the same.** "Include & index" on a notes doc indexes the transcript's segments into the notes' chunks.
4. **Inherited human locks.** A notes doc copies its transcript's state verbatim, including `manually_included`.
   If a human later excludes the transcript, the notes stay locked to "included" forever.

## Design

**G1 — classifier.** `Meet::Classifier` moves to `Stacks::Etl::Classifier` (shared by all sources) with a broader title lexicon:
raise, bonus, equity, payroll, pay review/band, severance (compensation); promotion, 360 / peer / upward feedback (performance review);
disciplinary, grievance, investigation, harassment, medical/parental leave (HR); layoff, resignation, exit interview (offboarding);
skip-level (1:1). Bare "feedback" and "review" are **not** title rules. Prod has 129 group threads titled "feedback", mostly client
design feedback. The content review below catches the personal kind.
Then a new `Stacks::Etl::ContentReview` runs on every meeting transcript that passes the deterministic rules. By then the meeting
has 3+ people, because anything with 2 or fewer has already been excluded. It sends the transcript in 40k-character windows to
`Stacks::AI.extract` (fast tier) and asks: is there personal discussion of one individual's pay, performance, discipline,
HR matter, departure, health or family, or a candidate evaluation? Any flagged window walls the whole doc off (`sensitive_content`).
The verdict is memoised in `raw_metadata["privacy_review"]` against the content hash, so nightly re-scans don't pay twice.
**Fails closed:** no API key or an API error means the doc is excluded as `unreviewed`. It is retried on the next run.

**G2 — attendance.** A notes doc with no transcript Document is walled off as `attendance_unknown`, or by its title reason if a title rule matched.
When the transcript arrives, the notes inherit its decision. Human states are mapped on inheritance:
included → `not_excluded`, excluded → `auto_excluded/manual`. That way a later human change on the transcript still propagates.
If several transcript rows match, the strictest one wins. The July invite-count rule for **transcripts** is unchanged.
A transcript invited to 3+ where only 2 turned up is now backstopped by the content review.

**G3 — default-deny.** `Connector#exclusion_for` raises `NotImplementedError` in the base class, so a new source ingests nothing
until it states a policy. A test asserts that every `Connector` subclass defines it. Groups gets an explicit policy: title rules,
otherwise eligible.

**G4 — read paths.** (a) `get_document` returns segments only for transcript docs. (b) The Reindexer only indexes transcript docs.
(c) Admin "Exclude" also excludes the other documents of the same meeting. (d) A tripwire test lists every MCP tool file that
touches corpus models; a new tool that touches them fails the test until someone adds it to the reviewed list with how it scopes.
(e) Canary tests seed walled-off content and assert that no corpus MCP tool returns it.

**Backfill.** `Stacks::Etl::Reclassifier` re-derives every non-human-locked document's state from **stored** data
(Meeting, segments, contacts, title), with no Google re-fetch. Ingest and reclassify must not disagree, or a doc would
flip every night. So the Meet connector records the head-counts it classified on in `raw_metadata["privacy_inputs"]`.
Reclassify reads those and falls back to Meeting and contact rows only for legacy docs. It drops chunks for newly excluded docs and re-indexes transcripts that become eligible.
- `rake stacks:etl:reclassify_privacy[dry_run]` prints the transitions and makes no writes or LLM calls.
- It runs nightly inside `stacks:etl:sync_all`, after the syncs and before weekly-ship matching. That makes it the one mechanism for the first
  backfill, for retrying `unreviewed` docs, and for applying future rule changes retroactively.

**Expected first run:** ~646 notes and ~84+ group threads walled off. ~400 transcripts get content-reviewed once, costing roughly $5 of Haiku.
Walled-off notes lose their chunks. To recover one, a human includes it and the next Drive backfill re-indexes it.

**No migration.** The new reasons are integer enum values (9 `sensitive_content`, 10 `unreviewed`, 11 `attendance_unknown`).

## Rejected alternatives
- An LLM review of email bodies across 51k group threads: cost and noise. Title rules only for now, flagged as residual risk.
- A `privacy_reviews` table for the memo: needs a migration, and Heroku deploys without migrations. `raw_metadata` works.
- Base default returning `auto_excluded` instead of raising: this fails silently (rows stored, never searchable). Raising is loud.

## Residual risk (not fixed here)
- jobs@ (782 threads of candidate mail), admin@ and accounting@ bodies are only title-screened.
- Standalone notes could recover real attendance from Meet `conferenceRecords.participants` (exists even without a transcript). Follow-up.
- Prompt injection inside a transcript could talk the reviewer into "not sensitive". The attackers would be staff; accepted.
