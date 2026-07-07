# Observations Backfill — Meet/Gemini — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Comprehensively backfill the Stacksbot Observations DB with per-meeting observations over the full year of the Meet/Gemini corpus, by simulating the `observe` skill against the live stacks MCP — after a small `get_document` enhancement and making Gemini notes an observed source.

**Architecture:** One small repo code change (Task 1: `get_document` returns the document's `body` + `meeting_key`), then an **operational runbook** (Part B) the controller executes: author the Notion durable changes (notes → observed + dedup), connect this session to the live stacks MCP, enumerate meetings oldest→youngest, and run a multi-agent Workflow that applies the observe rubric per meeting and writes `New` rows. Only Task 1 is subagent-driven TDD code; Part B is controller-run and gated on Task 1 being merged + deployed.

**Tech Stack:** Rails 6.1 / Ruby 3.1, Minitest + mocha, PostgreSQL + pgvector, the `mcp` gem (`MCP::Tool`), the read-only stacks MCP (`https://stacks.garden3d.net/api/mcp`), the Notion MCP, and the `Workflow` tool.

## Global Constraints

- **Only Task 1 is repo code (TDD).** Part B (Notion authoring + the backfill run) is operational — verification is tool-based (fetch-back / live MCP calls), not unit tests. Do not invent unit tests for Notion/Workflow steps.
- **Privacy wall is absolute:** the backfill only ever reaches `corpus_eligible` documents; excluded (1:1/HR/perf/comp) docs 404 from `get_document` and never appear. Never widen that scope.
- **No secrets ever printed or written** to a file, log, or Notion row — including the MCP `X-Api-Key` and any Twist token.
- **No raw PII in an `Observation`** — the Observations DB and digest are team-visible. Summarize; reference, do not paste.
- **`Status` is always `New`.** Never write `Triaged`/`Acted`/`Dismissed`.
- **Canonical Notion select values only:** `Source ∈ {Google Meet, Gemini Notes}`, `Salience ∈ {High, Medium, Low}`, `Type ∈ {Lead, Risk, Decision, Question, FYI}`. Never create new select options.
- **Dedup unit is the meeting** (`meeting_key`). New keys: `stacks:meeting:<meeting_key>:<n>`. Legacy 122 keys `stacks:meet:<doc_id>` are honored by resolving `doc_id → meeting_key` into the skip-set (keep them; do not delete or migrate).
- **The agent never flips a Notion trust boundary** (`Enabled`, Job activation). All Notion changes are drafts / inert body edits; a human enables.
- **Exact ids:** Observations DB `390131fea2c7808bb216c38b46c3ba55` (DS `390131fe-a2c7-80bf-b9a2-000b91fc630a`) · Sources DS `576eb9a8-8a01-4d1e-a00f-8efd361143b8` (rows: `gemini-notes` `https://app.notion.com/390131fea2c78168b3eaf1dc0bdaf85b`, `google-meet` `https://app.notion.com/390131fea2c7814890bbfea77b36ebec`) · Skills DS `38e131fe-a2c7-806b-8a4a-000b79b5b49c` (`Slug: observe`, `Slug: recall`). MCP endpoint `https://stacks.garden3d.net/api/mcp`; key at `Rails.application.credentials[:"localhost:3000"][:stacks][:private_api_key]`.

---

## File / artifact map

| Artifact | Where | Responsibility |
|---|---|---|
| `get_document` `body` + `meeting_key` | `app/services/mcp/get_document_tool.rb` | Make a note readable and pair transcript↔note (Task 1) |
| Tool tests | `test/services/mcp/tools_test.rb` | Prove body join + meeting_key (Task 1) |
| `gemini-notes` / `google-meet` Sources rows | Notion DS `576eb9a8-…` | Durable: notes become observed + meeting dedup (Part B1) |
| `observe` / `recall` skills | Notion Skills DS `38e131fe-…b49c` | Durable: cross-artifact dedup instruction (Part B1) |
| Backfill Workflow | `Workflow` tool (this session) | The comprehensive per-meeting run (Part B2–B5) |

---

## Task 1: `get_document` returns the document `body` and `meeting_key`

**Files:**
- Modify: `app/services/mcp/get_document_tool.rb`
- Test: `test/services/mcp/tools_test.rb`

**Interfaces:**
- Consumes: `Document.corpus_eligible`, `Document#chunks` (has `content`, `position`), `Document#source_record` (a `Meeting` or nil), `Mcp::Responses.ok/.error`.
- Produces: `get_document` response gains two keys — `body` (String: the doc's own `chunks` ordered by `position`, joined with `"\n"`; `""` when the doc has no chunks) and `meeting_key` (Integer meeting id when `source_record` is a `Meeting`, else `null`). Existing keys (`id`, `title`, `url`, `occurred_at`, `segments`) are unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `test/services/mcp/tools_test.rb` (inside `Mcp::ToolsTest`, before the `ids_for` helper). The `setup` block already creates `@doc` (a `:meet` doc) with one chunk at position 0: `'we decided to ship the gateway'`.

```ruby
  test 'get_document returns body joined from the doc chunks in position order' do
    # @doc already has a position-0 chunk from setup; add a later one out of insertion order.
    Chunk.create!(document: @doc, position: 2, content: 'and we set the launch date', source: :meet)
    Chunk.create!(document: @doc, position: 1, content: 'then we picked the rollout plan', source: :meet)

    payload = JSON.parse(Mcp::GetDocumentTool.call(id: @doc.id, server_context: {}).content.first[:text])
    assert_equal(
      "we decided to ship the gateway\nthen we picked the rollout plan\nand we set the launch date",
      payload['body']
    )
  end

  test 'get_document returns meeting_key for a meeting-backed doc and nil for a standalone doc' do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: 'cr/gd-1')
    note = Document.create!(source: :gemini_notes, external_id: 'gd-note', title: 'Roadmap notes',
                            excluded: :not_excluded, source_record: m)
    Chunk.create!(document: note, position: 0, content: 'summary: shipped the gateway', source: :meet)

    linked = JSON.parse(Mcp::GetDocumentTool.call(id: note.id, server_context: {}).content.first[:text])
    assert_equal m.id, linked['meeting_key']
    assert_equal 'summary: shipped the gateway', linked['body']

    standalone = JSON.parse(Mcp::GetDocumentTool.call(id: @doc.id, server_context: {}).content.first[:text])
    assert_nil standalone['meeting_key']
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/services/mcp/tools_test.rb -n '/get_document returns/'`
Expected: 2 failures — `payload['body']` is `nil` (key absent) and `linked['meeting_key']` is `nil` for the note (key absent), so the `assert_equal` lines fail.

- [ ] **Step 3: Implement the enhancement**

Replace the body of `self.call` in `app/services/mcp/get_document_tool.rb` so it also computes `body` and `meeting_key`, and update the class `description`:

```ruby
module Mcp
  class GetDocumentTool < MCP::Tool
    tool_name 'get_document'
    description 'Fetch one corpus-eligible document with its transcript segments, full text, and meeting key.'
    input_schema(properties: { id: { type: 'integer' } }, required: ['id'])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(id:, server_context:)
      doc = Document.corpus_eligible.find_by(id: id)
      return Responses.error('Document not found') unless doc

      meeting = doc.source_record
      segments = meeting.is_a?(Meeting) ? meeting.segments.order(:position).map { |s| { speaker: s.speaker_name, text: s.text } } : []
      body = doc.chunks.order(:position).pluck(:content).join("\n")
      meeting_key = meeting.is_a?(Meeting) ? meeting.id : nil
      Responses.ok({ id: doc.id, title: doc.title, url: doc.url, occurred_at: doc.occurred_at,
                     meeting_key: meeting_key, segments: segments, body: body })
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/mcp/tools_test.rb`
Expected: all tests pass (the two new ones plus the four pre-existing tool tests), 0 failures. (These tests don't touch embeddings, so no `skip_without_pgvector`.)

- [ ] **Step 5: Commit**

```bash
git add app/services/mcp/get_document_tool.rb test/services/mcp/tools_test.rb
git commit -m "MCP get_document: return document body and meeting_key"
```

---

## Part B — Backfill runbook (controller-executed; **gated on Task 1 merged + deployed**)

These are **not** subagent TDD tasks. The controller runs them after a human merges Task 1's PR and it deploys to `stacks.garden3d.net`. Each has a concrete verification.

### B0. Deploy gate

- Task 1 ships as a PR (see finishing-a-development-branch). **A human merges + deploys** (the agent cannot). Confirm live before continuing:
  - `KEY=$(bin/rails runner 'print Rails.application.credentials[:"localhost:3000"][:stacks][:private_api_key]')` (never echo `$KEY`).
  - `curl -s -X POST https://stacks.garden3d.net/api/mcp -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_document","arguments":{"id":<a known gemini_notes doc id>}}}'`
  - Expected: a 200 whose result JSON contains non-empty `body` and a numeric `meeting_key`. A 401 means the `localhost:3000` key is not the prod key → fetch the prod key from Heroku config / stacksbot secrets before proceeding. If `body` is absent, the deploy has not rolled out yet — wait and retry.

### B1. Durable Notion changes (notes → observed + dedup) — drafts

Author via the Notion MCP. No `Enabled` flips.

- **`gemini-notes` Sources row** (`390131fea2c78168b3eaf1dc0bdaf85b`): replace the "Not observed" body with an observed contract:
  - `## Fetch`: via the stacks MCP, `list_documents(source: "gemini_notes", occurred_after/before)`; for each, `get_document(id)` and read `body` (the note prose). Normalize `{id, timestamp: occurred_at, author: participants, text: body, url}`. Source Key `stacks:meeting:<meeting_key>:<n>`. **Dedup:** a note sharing a `meeting_key` with a transcript is the *same meeting* — observe once. Source label `Gemini Notes`.
  - Keep the existing `## Search` / `## Cite` sections.
- **`google-meet` Sources row** (`390131fea2c7814890bbfea77b36ebec`): change its Source Key to `stacks:meeting:<meeting_key>:<n>` and add the same cross-artifact dedup note (transcript preferred when present).
- **`observe` skill** (`Slug: observe`): add to the source-agnostic Steps: "When a source exposes one underlying meeting through more than one artifact (e.g. a transcript and a Gemini note), treat them as one meeting — observe it once, key on the meeting, and do not emit a second observation set for the other artifact."
- **`recall` skill** (`Slug: recall`): make the same dedup language consistent so Recall does not double-report a meeting.
- **Verify:** `notion-fetch` each edited row/skill; confirm the new `## Fetch`/dedup text is present and no `Enabled`/Status was flipped (Sources rows stay `Active`, skills stay as they were).

### B2. Connect the live MCP + build the enumeration

- **Connect this session** to `https://stacks.garden3d.net/api/mcp` (streamable-HTTP, header `X-Api-Key: $KEY`) via `claude mcp add` (or session MCP config). Verify with a `list_sources` call returning 200.
- **Skip-set (dedup vs the 122):** query the Observations DB (`390131fe-…630a`) for every `Source Key`. For legacy `stacks:meet:<doc_id>` keys, `get_document(<doc_id>)` → collect `meeting_key`. For `stacks:meeting:<key>:*` keys, take `<key>` directly. Result: a set `OBSERVED_MEETING_KEYS`.
- **Enumerate meetings oldest→youngest:** page `list_documents(source:"meet")` and `list_documents(source:"gemini_notes")` across the year (newest-first + `offset`; reverse client-side). `get_document` each to read its `meeting_key`; group docs by `meeting_key` (a `null` meeting_key → its own meeting keyed on `doc_id`) into work-items `{meeting_key, occurred_at, transcript_doc?, note_doc?}`, sorted ascending by `occurred_at`, minus `OBSERVED_MEETING_KEYS`.
- **Verify:** print the count of work-items and the oldest/newest `occurred_at`; sanity-check against the corpus (~730 meetings minus the ~122 already observed).

### B3. First-batch quality gate

- Run the Workflow (B4 shape) on **only the first ~10 work-items**. Present the produced observations (Name / Observation / Salience / Type / Source Key) to the user for a rubric-quality read. Adjust the rubric prompt if needed, then proceed. Do not write the remaining meetings until the sample is reviewed.

### B4. The comprehensive Workflow run

- `Workflow` script: `pipeline()` over the work-items (oldest→youngest), one subagent per meeting (batch only tiny ones). Each subagent:
  1. Reads its meeting via the live MCP — `get_document` for the transcript (prefer `segments`) and/or the note (`body`).
  2. Applies the observe **salience rubric comprehensively** — every lead/risk/decision/question/durable-fact that clears the bar, incl. `Low`, no per-meeting cap.
  3. Dedups within the meeting (transcript+note → one set).
  4. Emits schema-validated observations: `Name`, `Observation` (PII-summarized), `Source` (`Google Meet` if transcript-backed else `Gemini Notes`), `Source Ref` (doc `url`), `Source Key` `stacks:meeting:<meeting_key>:<n>`, `Observed At` (meeting `occurred_at`), `Salience`, `Type`, `Status:New`; leaves `Related Observations`/`Domain`/`Functions` empty.
  5. Writes rows via the Notion MCP `notion-create-pages` with a **concurrency cap + 429 backoff** (Notion rate-limits hard).
- **Resumable/idempotent:** rebuild `OBSERVED_MEETING_KEYS` at start so a re-run/resume skips written meetings; the Workflow's `resumeFromRunId` is the secondary resume path.

### B5. Post-run verification

- Query the Observations DB grouped by `Source`, `Salience`, `Type`; confirm coverage across `High/Medium/Low` and both `Google Meet` + `Gemini Notes`.
- Confirm **no meeting double-counted**: no `meeting_key` carries both a `Google Meet` and a `Gemini Notes` observation set.
- Confirm the **122 legacy meetings were not re-observed** (their `meeting_key`s absent from the new writes).
- Spot-check ~5 rows: `Source Ref` backlink resolves, `Observed At` equals the meeting time (not run time), `Status = New`.
- Re-run once → **zero** new rows (idempotency).

---

## Part C — Phase 3: Twist (future, separate spec)

Out of scope here. Twist creds live in this repo (`credentials[:"localhost:3000"][:twist]`), so it is unblocked. A later spec/plan exports a year of Twist threads/messages via REST v3, runs the same Workflow shape, and dedups `twist:msg:<id>` against the existing 60 rows.

---

## Self-Review

**Spec coverage:** Phase 0 `get_document` body + meeting_key → Task 1 ✓ · notes-become-observed + cross-artifact dedup (durable) → B1 ✓ · live-MCP access (not a dump) → B0/B2 ✓ · skip-set dedup vs the 122 → B2 ✓ · oldest→youngest per-meeting enumeration → B2 ✓ · comprehensive rubric, no cap → B4 ✓ · meeting-scoped Source Keys → B4 + Global Constraints ✓ · first-batch gate → B3 ✓ · post-run + idempotency verification → B5 ✓ · Twist deferred → Part C ✓ · privacy/PII/secrets/Status/canonical-options guardrails → Global Constraints ✓.

**Placeholder scan:** Task 1 carries complete test + implementation code and exact commands. Part B is intentionally operational (no unit tests, per the first Global Constraint) with concrete verifications; the one `<a known gemini_notes doc id>` / `<doc_id>` placeholders are runtime ids resolved from the live corpus at execution, not authoring gaps.

**Type/name consistency:** `body` (String) and `meeting_key` (Integer|nil) names identical across Task 1's Interfaces, tests, implementation, and B0/B2. Source Key format `stacks:meeting:<meeting_key>:<n>` identical in Global Constraints, B1, B2, B4. Source labels `Google Meet` / `Gemini Notes` match the DB select options and are used consistently. Notion ids match the spec's Global Constraints.
