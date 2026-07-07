# Observations Backfill — Meet/Gemini (Phase 1 source) — Design Spec

- **Date:** 2026-07-07
- **Status:** Approved (design); implementation via writing-plans → subagent-driven development
- **Owner:** Hugh / Sanctuary Computer
- **Worktree / branch:** `mcp-agent-features` / `worktree-mcp-agent-features`
- **Related:** Stacksbot observation layer (`../stacksbot/docs/superpowers/specs/2026-06-30-stacksbot-observation-layer-design.md`), sense-making Recall (`../stacksbot/docs/superpowers/specs/2026-06-30-sense-making-recall-design.md`), the Stacks Meet/Gemini corpus + read-only MCP (this repo).

## Background

Stacksbot has a source-agnostic **Observation layer** (`sense → triage → act`, sense only so
far). An `observe` skill reads a source's `## Fetch` contract from an always-loaded `sources`
skill (materialized from a Notion **Sources** DB), applies a salience rubric, dedups by a stable
`Source Key`, and writes `Status: New` rows to a team-visible Notion **Observations** DB. A
daily digest reports new rows to Twist.

Separately, this repo (`stacks`) now hosts a durable org-wide corpus: a full year of Google Meet
transcripts + Gemini "Notes by Gemini", embedded in pgvector, exposed by a read-only **stacks
MCP** server (`search`, `list_documents`, `get_document`, `list_sources`). As of the 365-day
backfill: **315 transcripts, 675 notes, ~730 meetings**.

The observe layer has already partially run against these sources, producing (in the Observations
DB today):

- **Google Meet: 122** observations, all `Status: New` — from an earlier, sparser partial pass
  that predates the full corpus.
- **Twist: 60** (56 `New`, 4 `Acted`).
- **Notion: 2** (`New`).
- **14 rows with no `Source`** — junk/test leftovers.
- **Gemini notes: 0** — notes were deliberately *not observed* (see below).

We want to run a **comprehensive, per-meeting historical backfill** over the full year of the
corpus — faithfully **simulating what Stacksbot's `observe` skill would do**, but executed from
this Claude Code session so the one-time load does not tie up the live Stacksbot agent. We also
make **Gemini notes a first-class observed source** going forward. Twist gets the same treatment
in a later phase.

## Goals

1. **Backfill meeting observations comprehensively.** For every corpus-eligible meeting in the
   past year (oldest → youngest), record all salient observations that clear the rubric
   (including `Low`, no per-meeting cap) into the Observations DB, deduplicated against what is
   already there.
2. **Make Gemini notes an observed source.** Flip the `gemini-notes` Sources row from
   *"Not observed"* to observed, and teach `observe` to treat a meeting's transcript and note as
   **one meeting** (dedup across artifacts), so the ~360 meetings that have a note but no
   transcript are covered without double-counting the ~315 that have both.
3. **Do it through the live stacks MCP**, exactly as Stacksbot reaches it — not a database dump —
   so the run is a faithful simulation of the agent's own behavior.
4. **Leave a durable improvement behind.** The MCP change and the Notion authoring make ongoing
   Observe/Recall better, not just this one run.

## Non-goals (YAGNI)

- **Twist backfill** — deferred to Phase 3 (own spec/plan); creds are available in this repo's
  credentials, so it is unblocked but out of scope here.
- **Triage / act / digest tuning** — we only write `New` rows; humans triage from the DB.
- **Enabling anything in Notion** — all authored Notion changes are drafts / inert body edits;
  a human flips the trust boundary. This run does not enable an "Observe: Gemini notes" Job.
- **Re-embedding or changing the corpus/ETL** — read-only against the existing corpus.
- **Deleting the existing 122 Meet rows** — decision was to keep and dedup against them.

## Decisions locked in brainstorming

| # | Decision | Choice |
|---|---|---|
| 1 | Meeting model | Notes become a **separate observed source**; process **per-meeting, oldest→youngest**; `observe`/`recall` get **dedup instructions** so a meeting's transcript + note collapse to one observation. |
| 2 | Selectivity | **Comprehensive** — all salience incl. `Low`, no per-meeting cap. |
| 3 | Execution | **Multi-agent Workflow**, run in this session. |
| 4 | Twist | **Meet/Gemini now; Twist fast-follow** (own spec). |
| 5 | Existing 122 Meet rows | **Keep, dedup against them** (skip already-observed meetings). |
| 6 | Data access | **Live stacks MCP** (`https://stacks.garden3d.net/api/mcp`), like Stacksbot — not a dump. |
| 7 | Note reading | **Small MCP enhancement first** — `get_document` returns the doc's own text + a meeting group key. |

## Architecture

Four phases. Phase 0 is code + a deploy; Phase 1 is Notion authoring (can run in parallel with 0);
Phase 2 is the run and depends on both; Phase 3 is a later spec.

### Phase 0 — MCP enhancement (code in `stacks`, requires deploy)

`get_document` (`app/services/mcp/get_document_tool.rb`) today returns
`{id, title, url, occurred_at, segments}`, where `segments` is the **transcript** (from
`meeting.segments`). A `Document` has **no body column** — a Gemini note's prose lives only in its
`chunks` (`chunks.content`, ordered by `position`). So a note is currently **unreadable** through
the MCP except as `search` snippets, and the tools expose no `meeting_id` to pair a transcript
with its note.

Change `get_document` to additionally return:

- **`body`** — the document's own text: its `chunks` ordered by `position`, joined. This is the
  note's prose for a `gemini_notes` doc (and, for a transcript doc, the chunked transcript text —
  harmless/redundant next to `segments`).
- **`meeting_key`** — a stable per-meeting grouping id, `source_record_id` (the `Meeting` id) when
  `source_record` is a `Meeting`, else `null`. Lets a caller group a transcript and its note into
  one meeting without heuristics.

Constraints:
- Stays within the existing `corpus_eligible` scope (privacy wall holds — excluded docs still 404).
- Additive only; existing fields unchanged. TDD, mirrors the existing tool tests
  (`test/.../mcp/` + `skip_without_pgvector` guards where embeddings are touched).
- Ship as a normal PR. **A human merges + deploys** (I cannot); Phase 2 waits until it is live on
  `stacks.garden3d.net` (verified by a live `get_document` call returning `body`).

Optional (only if grouping proves expensive): add `meeting_key` to `list_documents` rows too. Not
required — Phase 2 fetches every doc anyway and can group on the `get_document` result.

### Phase 1 — Gemini notes become an observed source (Notion, drafted)

Authoring only; no repo code. Uses the Notion MCP. Follows the repo's trust-boundary rule: the
agent never enables; a human does.

1. **`gemini-notes` Sources row** (`https://app.notion.com/390131fea2c78168b3eaf1dc0bdaf85b`):
   replace the *"Not observed"* framing with an observed `## Fetch` contract:
   - Fetch: via the stacks MCP, `list_documents(source: "gemini_notes", occurred_after/before)`
     over the window; for each, `get_document(id)` and read `body` (the note prose). Normalize to
     `{id, timestamp: occurred_at, author: participants, text: body, url}`.
   - Source Key: **meeting-scoped** — `stacks:meeting:<meeting_key>:<n>` (see "Source Key & dedup").
   - Dedup: a note and a transcript that share a `meeting_key` are the **same meeting** — observe
     the meeting once. If the meeting already has observations (any artifact), skip.
   - Source label (the `Source` select value): **`Gemini Notes`** (exact existing option name).
2. **`google-meet` Sources row** (`https://app.notion.com/390131fea2c7814890bbfea77b36ebec`):
   update its Source Key to the meeting-scoped scheme and add the same cross-artifact dedup note
   (transcript preferred when present). Source label stays **`Google Meet`**.
3. **`observe` skill** (Skills DB `38e131fe-a2c7-806b-8a4a-000b79b5b49c`, `Slug: observe`): add a
   cross-artifact **dedup instruction** to the source-agnostic Steps — "when a source exposes the
   same underlying meeting through more than one artifact (e.g. a transcript and a Gemini note),
   treat them as one meeting: observe it once, key on the meeting, and do not emit a second
   observation set for the other artifact."
4. **`recall` skill / `gemini-notes` Search contract**: already Search-enabled; make the dedup
   language consistent (a note and transcript of one meeting are one meeting) so Recall does not
   double-report. Minor edit.

All four are drafts / inert body edits. Editing an `Active` Sources row's body goes live on the
next reconcile but stays **inert** until an "Observe: Gemini notes" Job is enabled — which this
project does **not** do.

### Phase 2 — The backfill Workflow (run here, simulating Stacksbot)

Executed via the `Workflow` tool in this session. Depends on Phase 0 being live.

**Setup (in the session, before the Workflow):**

1. **Connect the live stacks MCP** to this session:
   `https://stacks.garden3d.net/api/mcp`, transport streamable-HTTP, header `X-Api-Key: <key>`.
   The key is read from this repo — `Rails.application.credentials[:"localhost:3000"][:stacks]
   [:private_api_key]` (prod reads the same `localhost:3000` credentials block; verified by one
   authenticated `list_sources` call returning 200, not 401). **Never printed.**
2. **Build the "already-observed" set:** query the Observations DB (Notion MCP) for all existing
   `Source Key`s. For each legacy Meet key `stacks:meet:<doc_id>`, resolve `doc_id → meeting_key`
   via `get_document` so the 122 map onto meetings. The result is a set of `meeting_key`s to skip.
3. **Enumerate meetings oldest→youngest:** page `list_documents(source: "meet")` and
   `list_documents(source: "gemini_notes")` across the full year (newest-first + `offset`; reverse
   client-side). Group docs into meetings by `meeting_key` (via `get_document`), producing one
   work-item per meeting `{meeting_key, occurred_at, transcript_doc?, note_doc?}`, sorted ascending
   by `occurred_at`. Drop meetings already in the skip set.

**The Workflow:**

- `pipeline()` over meeting work-items, one subagent per meeting (the orchestrator may batch only
  very small meetings). Each subagent:
  1. Reads its meeting via the live MCP — `get_document` for the transcript (prefer `segments`)
     and/or the note (`body`).
  2. Applies the real observe **salience rubric comprehensively** — every lead / risk / decision /
     question / durable fact that clears the bar, incl. `Low`, no cap.
  3. **Dedups within the meeting** (transcript + note → one observation set).
  4. Emits structured observations (schema-validated) with fields:
     `Name` (≤~10 words), `Observation` (self-contained, PII-summarized), `Source`
     (`Google Meet` if a transcript backed it, else `Gemini Notes`), `Source Ref` (the doc `url`),
     `Source Key` (`stacks:meeting:<meeting_key>:<n>`), `Observed At` (the meeting's `occurred_at`,
     not run time), `Salience` (`High`/`Medium`/`Low`), `Type`
     (`Lead`/`Risk`/`Decision`/`Question`/`FYI`), `Status` = `New`. Leave `Related Observations`,
     `Domain`, `Functions` empty (triage's job).
  5. **Writes** the rows to the Observations DB via the Notion MCP, with a **concurrency cap +
     429 backoff** (Notion rate-limits aggressively — observed during design).
- **Resumable / idempotent:** re-reading the existing `Source Key`s at the start and skipping
  already-observed meetings means an interrupted run simply continues; a re-run writes nothing new.
  The Workflow's own `resumeFromRunId` gives an additional resume path.

**First-batch quality gate:** run the first ~10 meetings, present the produced observations to the
user for a quality read on the rubric, then proceed to the full fan-out. (Even under
"comprehensive," this confirms the rubric behaves before writing hundreds of rows.)

### Phase 3 — Twist (later, own spec)

Sketch only. Twist creds are in this repo (`credentials[:"localhost:3000"][:twist]` — token /
workspace id / bot user id), so it is unblocked. Export a year of threads/messages via Twist REST
v3 (`threads/get` per channel over 365d with `newer_than_ts`/`older_than_ts`, `comments/get` per
thread — broader than the current client's unread-only reads), normalize per the Twist `## Fetch`
contract, run the same Workflow shape, dedup `twist:msg:<id>` / `twist:thread:<id>:<state>` against
the existing 60. Twist over a year is chattier than meetings; its own spec will set Twist-specific
selectivity.

## Source Key & dedup

- **Dedup unit = the meeting** (`meeting_key = get_document.meeting_key = Meeting id`). A meeting is
  observed at most once across its transcript and note(s).
- **New observation keys:** `stacks:meeting:<meeting_key>:<n>`, where `<n>` is a stable index/slug
  within the meeting (a meeting can yield several observations under "comprehensive").
- **Legacy keys:** the existing 122 use `stacks:meet:<doc_id>`. They are honored by resolving
  `doc_id → meeting_key` and adding that meeting to the skip set (Decision #5: keep + dedup, do not
  delete or migrate them).
- **Cross-source:** notes and transcripts of one meeting share `meeting_key`, so a note never
  double-counts a transcript-observed meeting. Distinct meetings stay distinct.

## Data / control flow

```
Phase 0 (deployed):  get_document → { …, body, meeting_key }
                                   │
Setup:  credentials[:"localhost:3000"][:stacks][:private_api_key]
            └─ connect session → https://stacks.garden3d.net/api/mcp (X-Api-Key)
        Notion: existing Source Keys ──resolve──▶ skip-set (meeting_keys, incl. the 122)
        MCP: list_documents(meet) + list_documents(gemini_notes) ──group by meeting_key──▶
             meetings sorted oldest→youngest, minus skip-set
                                   │
Phase 2 Workflow (pipeline, 1 subagent / meeting):
        get_document(transcript?/note?) → rubric (comprehensive) → dedup-in-meeting →
        observations{…, Source Key = stacks:meeting:<key>:<n>, Status:New} →
        Notion create (throttled, 429 backoff)
                                   │
        First-batch gate (~10) ──▶ full fan-out ──▶ post-run verification
```

## Guardrails

- **Read-only** on the corpus and (Phase 3) Twist. The only writes are Observations rows.
- **Privacy wall holds:** only `corpus_eligible` docs are reachable (1:1 / HR / perf / comp meetings
  are already excluded from the corpus and 404 from `get_document`). The backfill never sees them.
- **No secrets / raw PII** in an `Observation` — the DB and digest are team-visible. Summarize;
  reference, do not paste. (Mirrors the observe skill + apollo skill PII guardrails.)
- **The API key is never printed** or written to any file, log, or Notion row.
- **`Status` is always `New`** — no triage transitions.
- **Canonical option values only** on write: `Source ∈ {Google Meet, Gemini Notes}`,
  `Salience ∈ {High, Medium, Low}`, `Type ∈ {Lead, Risk, Decision, Question, FYI}`. Do not create
  new select options. (The DB currently has option-bleed — `Salience` carries stray
  `Decision`/`Lead`, `Type` carries stray `High`/`Medium`, `Source` has both `Meet` and
  `Google Meet` — see Follow-ups; the backfill must not add to it.)

## Verification / success criteria

- **Phase 0:** a live `get_document` on a `gemini_notes` doc against `stacks.garden3d.net` returns a
  non-empty `body` and a `meeting_key`; a transcript doc returns both `segments` and `body`; an
  excluded doc still 404s. Existing tool tests stay green.
- **Auth:** an authenticated `list_sources` against the live endpoint returns 200 with the
  repo-sourced key (proves prod accepts the `localhost:3000` key).
- **Dedup:** none of the existing 122 meetings are re-observed; no meeting appears with both a
  `Google Meet` and a `Gemini Notes` observation set for the same `meeting_key`.
- **Coverage:** meetings that have only a note (no transcript) receive observations (proves the
  Phase 0 `body` path works end-to-end).
- **Comprehensiveness:** observations exist across `High`/`Medium`/`Low`; no per-meeting cap applied.
- **Provenance:** every row has a working `Source Ref` backlink, an `Observed At` equal to the
  meeting time (not run time), `Status = New`, and a `stacks:meeting:…` key.
- **Idempotency:** a second run (or a resume) writes zero new rows.
- **Silence:** no Twist/Slack/email is sent; the run only writes Observations rows.

## Risks & mitigations

- **Volume (comprehensive, team-visible):** accepted by decision; humans triage from the DB with
  filters. The first-batch gate calibrates rubric behavior before the full write.
- **Notion rate limits (429s seen in design):** concurrency cap + exponential backoff on writes;
  resumable so a throttle stall is not fatal.
- **Prod key mismatch:** if the `localhost:3000` key is *not* the prod key, the first `list_sources`
  call 401s — then fetch the prod key from Heroku config / stacksbot secrets before proceeding.
- **Meeting grouping gaps:** `meeting_key` is exact (the `Meeting` id) for docs whose
  `source_record` is a `Meeting`; any doc with a `null` meeting_key is treated as its own meeting
  (keyed on its `doc_id`) — no silent merge.
- **Token cost / long run:** hundreds of subagent runs. Mitigated by resumability, the batch gate,
  and running as a single background Workflow.
- **Double-count from the durable Phase 1 change:** the cross-artifact dedup instruction + the
  meeting-scoped key are the mitigation; the verification explicitly checks for it.

## Follow-ups (out of scope, noted)

- **Observations schema hygiene:** `Salience`/`Type` option-bleed and the duplicate
  `Meet`/`Google Meet` Source options predate this work. Optional one-time cleanup via
  `notion-update-data-source`; not required for the backfill (which writes canonical values only).
- **14 null-`Source` junk rows:** harmless; leave (Decision #5 kept scope to the 122). Optional
  delete later.
- **`list_documents` meeting_key:** add only if grouping cost becomes a problem.
