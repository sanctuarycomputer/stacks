# Surveys over MCP + Stacks Surveys as an Observed Source — Design

**Date:** 2026-09-09
**Goal:** Let stacksbot pull recent studio-wide and project satisfaction surveys through the
stacks MCP, observe them as a source (per-survey observations in the Notion Observations DB), and
so start noticing the recurring things contributors say about working with us.

Two parts, mirroring the Google Groups precedent
(`docs/superpowers/specs/2026-07-10-google-groups-observations-source-design.md`):

- **Part A — `stacks` (this repo):** two new read-only MCP tools, `list_surveys` and
  `get_survey_results`, backed by one presenter that adapts both survey families into a single
  shape. Shipped as a normal TDD PR.
- **Part B — Notion (stacksbot control plane):** one Sources row (`stacks-surveys`), one
  **disabled** `Observe: Stacks Surveys` Job, one new `Source` select option on the Observations
  DB, and a go-live checklist doc in this repo. **No stacksbot code changes** — the sync
  reconcilers materialize Notion rows into the agent's always-loaded `sources` skill, and the
  source-agnostic `observe` skill reads the contract.

## Decisions already made (with Hugh, 2026-09-09)

1. **Privacy posture: full anonymous results, closed surveys only.** The MCP returns scores,
   score contexts, and free-text answers for **closed** surveys, never tied to a person. Open
   surveys expose metadata and response rate only. The Notion contract forbids verbatim quotes
   and attribution in observations.
2. **Synthesis: observe only; rely on existing rollups.** `Observe: Stacks Surveys` mints
   per-survey observations (close summary, within-survey themes, stalled open surveys). Cross-survey
   clustering is left to the existing `propose-challenges` (30-day theme clustering) and nightly
   `Distill Institutional Memory` passes. No new synthesis job, no in-Rails LLM.
3. **Both survey families are in scope**, exposed under a `kind` of `studio` or `project`.
4. **No new Observations `Type`** — reuse `Risk` / `FYI` / `Question`. The `Source = Stacks/Surveys`
   select value is the filter for "everything from surveys".

## Background (what exists today)

- **Two parallel, non-shared survey families** (no STI, no shared base class):
  `Survey` (studio-wide; `survey_studios` → N studios; `opens_at` date + `closed_at` datetime;
  statuses `:draft` / `:open` / `:closed` derived from dates) and `ProjectSatisfactionSurvey`
  (one `ProjectCapsule` → `ProjectTracker`; `closed_at` only; `:open` / `:closed`; persisted
  `score` synced on close). Each has `*_questions` (5-point Likert, `sentiment` enum
  `strongly_disagree(1)…strongly_agree(5)`, optional free-text `context` per answer),
  `*_free_text_questions` (single `response` string), `*_responses`, and `*_responders`.
- **Responses are structurally anonymous.** A `*Response` row has NO `admin_user_id` (and on the
  studio side no timestamps at all). A separate `*Responder` row (`survey_id`, `admin_user_id`,
  unique) records only *that* a person responded. There is no join path from an answer to a
  person and none is introduced here.
- **Surveys are not in the ETL corpus** (`Document.source` is `meet | gemini_notes | google_groups`),
  so `search` / `list_documents` / `get_document` cannot reach them. Hence new tools.
- **MCP conventions** (`app/services/mcp/`): one `Mcp::<Name>Tool < MCP::Tool` per file; DSL
  `tool_name` / `description` / `input_schema` / `annotations(read_only_hint: true, …)`;
  `self.call(**kwargs, server_context:)`; `Responses.ok(payload)` / `Responses.error(msg)` as a
  single JSON text block; enumerate valid values in validation errors; clamp numeric params; whole-
  tool `rescue StandardError` → log + Sentry + `"<tool> failed; the error was logged"`; register in
  `Mcp::Server::TOOLS`; unit test in `test/services/mcp/` + one `tools/call` round-trip and the
  exact tool-name array in `test/integration/mcp_endpoint_test.rb`.
- **Auth** is the single shared `X-Api-Key`; anyone holding it sees every read tool. Observations
  land in a **team-visible** Notion DB and a Twist digest. Every admin user can already open both
  survey results pages (free text included), so Part A does not widen exposure; it adds guardrails
  on the one new consumer.
- **The `observe` skill's Source Contract** needs exactly three things from a source: a bounded
  **Fetch** producing normalized items, a deterministic **Source Key** per potential observation,
  and a **Source Ref** backlink + `Source` label. Window start comes from
  `observe-window.mjs` (high-water mark since last successful run, 6h overlap, 14-day cap).

## Part A — `stacks` MCP tools

### A1. `Mcp::SurveyPresenter` (`app/services/mcp/survey_presenter.rb`)

One adapter over both families so the tools contain no per-family branching.

```ruby
module Mcp
  class SurveyPresenter
    KINDS = %w[studio project].freeze
    STATUSES = %w[open closed].freeze
    SMALL_SAMPLE_THRESHOLD = 5
    ADMIN_HOST = "https://stacks.garden3d.net"

    # kind: "studio" | "project" | nil (both); status: "open" | "closed" | nil (both);
    # closed_range: Range|nil (applies to closed_at; a closed_range implies status closed).
    # Returns presenters sorted newest-first by (closed_at || opened_at), after offset/limit.
    def self.list(kind: nil, status: nil, closed_range: nil, limit: 50, offset: 0)
    def self.find(kind:, id:)   # → presenter or nil
    def summary                 # list-row hash (see A2)
    def results                 # full hash (see A3)
  end
end
```

Field mapping:

| Field | `studio` (`Survey`) | `project` (`ProjectSatisfactionSurvey`) |
|---|---|---|
| `status` | `survey.status` (`open`/`closed`; **drafts are never listed** and `find` on a draft behaves as open) | `survey.status` |
| `opened_at` | `opens_at` (date, may be nil) | `created_at.to_date` |
| `closed_at` | `closed_at` | `closed_at` |
| `scope` | `{ studios: [{ name:, mini_name: }] }` | `{ project_tracker_id:, project: tracker.name }` |
| `url` | `#{ADMIN_HOST}/admin/surveys/#{id}` | `#{ADMIN_HOST}/admin/project_satisfaction_surveys/#{id}` |
| `response_count` | `survey_responses.count` | `project_satisfaction_survey_responses.count` |
| `expected_response_count` | `expected_responders.size` | `expected_responders.size` (it's a Hash) |
| `overall_score` | mean of per-question averages, skipping questions whose average is `nil` (matches the admin page) | response-weighted mean of all rating answers (matches persisted `score` and the admin page) |

`list` queries each family separately (`Survey.open`/`Survey.closed`, `ProjectSatisfactionSurvey.open`/`.closed`, with `closed_at: closed_range` applied when given), wraps them, sorts in Ruby by `(closed_at || opened_at)` descending, then applies `offset`/`limit`. Ruby-side sorting is acceptable: the population is a few hundred rows at most and the list payload never triggers the expensive `expected_responders` computation. Preload questions/free-text questions for `results`.

`expected_response_count` and `response_rate` are computed **only in `results`** (one survey per call) because `Survey#expected_responders` runs the elevated-service bulk computation; doing it for 50 list rows risks Heroku's 30 s cap.

### A2. `list_surveys`

```
tool_name   'list_surveys'
description 'READ: list studio-wide and project satisfaction surveys (newest first; closed surveys
             by closed_at, open ones by opened_at). Filter by kind (studio|project), status
             (open|closed), and a closed_at range. Responses are anonymous — this tool exposes
             counts only, never responders. Use get_survey_results for scores and free text.'
properties  kind: string, status: string,
            closed_after: string (ISO8601, inclusive), closed_before: string (ISO8601, inclusive),
            limit: integer (default 50, clamped 1..200), offset: integer (default 0, min 0)
```

Row shape:

```json
{ "kind": "project", "id": 42, "title": "Acme Redesign — Project Satisfaction", "status": "closed",
  "opened_at": "2026-07-01", "closed_at": "2026-08-15T14:02:11Z",
  "scope": { "project_tracker_id": 7, "project": "Acme Redesign" },
  "response_count": 6,
  "url": "https://stacks.garden3d.net/admin/project_satisfaction_surveys/42" }
```

Rules: `closed_after`/`closed_before` go through `Mcp::DateRange.parse` (blank/invalid ignored,
one-sided OK) and, when either is present, force `status = "closed"` (an open survey has no
`closed_at`). Unknown `kind` → `Unknown kind 'x'. Valid kinds: studio, project`; unknown `status`
→ `Unknown status 'x'. Valid statuses: open, closed`. Payload is a bare array (like
`list_documents`). Draft studio surveys are excluded.

### A3. `get_survey_results`

```
tool_name   'get_survey_results'
description 'READ: one survey with anonymous aggregate results. For a CLOSED survey: per-question
             averages (0–5), Likert distributions, the optional free-text context behind each
             score, and free-text answers. For an OPEN survey: metadata and response rate only
             (results_withheld). Responses are anonymous and must never be attributed to a person
             or quoted verbatim into team-visible stores; small_sample flags surveys with fewer
             than 5 responses.'
properties  kind: string (required), id: integer (required)
```

Closed-survey payload = the list row plus:

```json
{ "description": "…",
  "expected_response_count": 8, "response_rate": 0.75, "small_sample": false,
  "overall_score": 3.4,
  "questions": [
    { "prompt": "The budget was realistic", "average": 3.1, "response_count": 6,
      "distribution": { "strongly_disagree": 0, "disagree": 2, "neutral": 1, "agree": 2, "strongly_agree": 1 },
      "contexts": ["…"] }
  ],
  "free_text_questions": [
    { "prompt": "What should we stop doing?", "responses": ["…", "…"] }
  ] }
```

- Scores use `SurveyQuestionResponse.sentiment_to_score` (0 / 1.25 / 2.5 / 3.75 / 5), the same
  0–5 scale the admin pages show. `average` is `nil` for a question with no answered responses;
  `overall_score` is `nil` when there are no responses. Rounded to 2 dp.
- `distribution` counts only answers whose `sentiment` is a valid enum key (the column defaults
  to `0`, which is not a key); `response_count` per question = that same count.
- `contexts` / `responses` include only `present?` strings, in DB order.
- `response_rate = (response_count / expected_response_count).round(2)`, `nil` when expected is 0.
- `small_sample = response_count < SMALL_SAMPLE_THRESHOLD`.
- Questions are ordered by id (creation order), which is the order the form shows.
- The presenter computes aggregates itself rather than calling `Survey#results` (raises
  `NoMethodError` on an empty response set or an unanswered question) or
  `ProjectSatisfactionSurvey#results` (one query per question). Those model methods are unchanged.

Open (or draft studio) survey payload = the list row plus `description`,
`expected_response_count`, `response_rate`, and `"results_withheld": "survey is open"`. No
`questions`, no `free_text_questions`, no `overall_score`, no `small_sample`.

Errors: unknown kind as above; missing id → `Survey not found`.

### A4. Privacy rules (Part A)

- The payload **never** contains an `AdminUser`/`Contributor`/`ForecastPerson` name or email,
  a `*Responder` row, or any per-response identifier. Only counts.
- Free text is returned **only for closed surveys**.
- Both tool descriptions state the anonymity contract so any MCP client (not just the observe
  skill) sees it.
- No `SurveyResponder` / `ProjectSatisfactionSurveyResponder` association is ever loaded by the
  presenter.

### A5. Registration and wiring

- Append `Mcp::ListSurveysTool` and `Mcp::GetSurveyResultsTool` to `Mcp::Server::TOOLS`
  (`app/services/mcp/server.rb`). Read server only — never the write server.
- Update the sorted tool-name literal in `test/integration/mcp_endpoint_test.rb` (the
  `tools/list` test) to include `get_survey_results` and `list_surveys`.
- No migrations, no model changes, no ActiveAdmin changes.

### A6. Tests

- `test/services/mcp/survey_presenter_test.rb`
  - studio + project: `summary` fields (scope, url, opened_at, closed_at, response_count).
  - `results` for a closed survey: per-question `average`, `distribution`, `contexts`,
    `free_text_questions`, `overall_score` (studio = mean of question averages; project =
    response-weighted mean equal to the persisted `score`), `response_rate`, `small_sample` at
    4 vs 5 responses.
  - empty-response closed survey: `overall_score: nil`, questions present with `average: nil`,
    no exception.
  - an answer with `sentiment: 0` (invalid default) is excluded from distribution/average.
  - open survey: `results_withheld`, no free text, no questions.
  - draft studio survey: not returned by `list`; `find` → open-shaped payload.
  - **anonymity**: create a responder `AdminUser` with a distinctive email + name; assert the
    JSON of `results` and `summary` contains neither.
  - `list`: kind/status filters, `closed_range`, newest-first ordering across kinds, offset/limit.
- `test/services/mcp/list_surveys_tool_test.rb`: enumerated errors for bad kind/status; limit
  clamp (0 → 1, 999 → 200); `closed_after` forces closed; payload is an array.
- `test/services/mcp/get_survey_results_tool_test.rb`: bad kind error; not-found error; closed
  payload includes free text; open payload withholds it.
- `test/integration/mcp_endpoint_test.rb`: `tools/list` array; one `tools/call` round-trip per
  tool (a closed project survey with one free-text answer).
- Note (per memory): run targeted tests during development; the full suite once before the PR,
  skipping `EtlRakeTest` locally (`bin/rails test $(ls test/**/*_test.rb | grep -v etl_rake)`),
  and never while a subagent may be running tests.

## Part B — Notion authoring (after the PR is up; all Draft / disabled)

### B1. Sources DB row — `Stacks Surveys`

Sources DB `9090b15496114236ba7a641d660c6e8c` (data source
`collection://576eb9a8-8a01-4d1e-a00f-8efd361143b8`). Properties: `Name: Stacks Surveys` ·
`Slug: stacks-surveys` · `Backing Tool: stacks MCP` · `Cite Label: Stacks/Surveys` ·
`Status: Draft` (→ `Active` at go-live). Body:

```markdown
## Fetch
Daily TRANSITION sensing over contributor surveys via the stacks MCP. Surveys are ANONYMOUS —
see Privacy below before writing anything. Window start = the observe-window high-water mark
(`since`); default 48h.
1. Newly closed surveys: `list_surveys(status: "closed", closed_after: <since>)`, paging by
   offset until fewer than `limit` come back. For each row call
   `get_survey_results(kind, id)` → { title, scope, closed_at, response_count,
   expected_response_count, response_rate, small_sample, overall_score, questions[],
   free_text_questions[], url }. Normalize to { id: "<kind>:<id>", timestamp: closed_at,
   author: none (anonymous), text: the results payload, url }.
   Mint, per closed survey:
   a. CLOSE SUMMARY — always exactly one row. Source Key `stacks:survey:<kind>:<id>:closed`.
      Type FYI; Type Risk (Salience Medium) when overall_score < 3.0 or any question's average
      < 2.5; Salience High when overall_score < 2.5. Text: title + scope, overall x/5, response
      rate (n of m), the weakest and strongest questions with their averages, and — when
      `list_surveys(kind: <kind>, status: "closed")` shows a prior closed survey with the same
      scope (same studios, or the same project) — "up/down from y/5 on <date>".
   b. THEMES — at most THREE per survey. Source Key `stacks:survey:<kind>:<id>:theme:<kebab-slug>`
      (slug from the theme's short name; stable wording, e.g. `timeline-pressure`,
      `unclear-ownership`, `strong-design-dev-collab`). Type Risk for pain points and asks the
      team should act on; Type FYI for wins worth repeating; Type Question for an explicit
      unanswered ask. Salience Medium for a pain point, Low otherwise. Text paraphrases the theme
      and states support as a count ("4 of 12 responses raise …"). A theme MUST be supported by
      at least TWO distinct responses (contexts or free-text answers) — a single response is one
      person's comment and is never its own row. Skip themes entirely when response_count < 2.
2. Stalled open surveys: `list_surveys(status: "open")`. For each open survey whose opened_at is
   more than 14 days ago, call `get_survey_results(kind, id)`; if response_rate < 0.5 mint
   Source Key `stacks:survey:<kind>:<id>:stalled` — Type Risk, Salience Low, text = title, days
   open, n of m responses. (A single stateless key: it dedups on every later run.)
Entities: Sanctuary Computer Inc for project surveys (client services) when confident; leave
blank for studio surveys unless the studio clearly maps. Projects relation: for `project` kind,
link the 🎛️ Projects row matching `scope.project` when confident. NEVER set the People relation
from this source.

## Privacy (binding)
Responses are anonymous by design — the stacks tool exposes no responder identity, and you must
not reconstruct one. NEVER quote a context or free-text answer verbatim; paraphrase. NEVER
attribute, guess, or hint who wrote something (no roles, no "the designer on the project"). When
`small_sample` is true, be more conservative: only themes with ≥2 supporters, and keep the
paraphrase general enough that it cannot be matched to one person. Never write survey content to
the Knowledge DB from this source; durable findings are the nightly distiller's job.

## Source Key
`stacks:survey:<kind>:<id>:closed` · `stacks:survey:<kind>:<id>:theme:<slug>` ·
`stacks:survey:<kind>:<id>:stalled`   (kind ∈ studio | project)

## Source Ref
The survey's `url` from the payload (the Stacks admin results page).

## Search
Current-state Q&A about how contributors feel: `list_surveys(kind:, status: "closed")` to find the
relevant closed survey(s) (by scope/date), then `get_survey_results` for scores and themes.
Answer with aggregates and paraphrased themes only — the Privacy rules above apply to Recall
answers too. There is no text search; pick surveys by scope and recency.

## Cite
The survey title, scope and closed date, linking `url`. Label: Stacks/Surveys. When writing an
Observation from this source, set `Source` to EXACTLY `Stacks/Surveys`.
```

### B2. Jobs DB row — `Observe: Stacks Surveys`

Jobs DB `329131fea2c78015ba3eed7476974b9b`. `Name: Observe: Stacks Surveys` ·
`Cron: 0 7 \* \* \*` (daily 07:00; asterisks escaped per the Notion cron convention) ·
`Timezone: America/New_York` · `Deliver To: none` · `Model: anthropic/claude-sonnet-5` ·
**`Enabled: unchecked`**. Body (keep under ~9,000 chars; the cron reconciler elides the middle of
longer bodies):

```markdown
# Observe: Stacks Surveys
## Purpose
Sense newly closed contributor surveys (studio-wide + project satisfaction) and stalled open ones,
writing per-survey observations. Silent sensor; the Observations Digest reports them.
## Procedure
1. Load the `observe` skill.
2. Run it for source `stacks-surveys` (bundled contract: skills/sources/stacks-surveys.md).
## WINDOW CONTRACT
Before fetching, run ONE exec:
`node /app/scripts/observe-window.mjs --job <THIS PAGE'S NOTION ID> --default 48h`
and READ its JSON; use `since` (ISO) as `closed_after` for list_surveys. If the helper is
missing or exits non-zero, fall back to `closed_after = now − 48h` and say so in the final line.
Surveys close rarely: a typical run finds zero or one; do not fan out sub-agents unless the
window holds more than ~5 closed surveys.
## Output
New rows in the Observations DB (data source 390131fe-a2c7-80bf-b9a2-000b91fc630a), Source =
`Stacks/Surveys`, Status = New.
## Deliver To
none
## Guardrails
Read-only on stacks. Anonymity rules in the source contract are binding: paraphrase, never
quote; never attribute; never set People. End with one line of final text
("Observe: Stacks Surveys done — N written").
```

Replace `<THIS PAGE'S NOTION ID>` with the created page's id (the Google Groups incident: prose
without literal ids makes the model guess).

### B3. Observations DB

Add the select option **`Stacks/Surveys`** to the `Source` property of the Observations DB
(`390131fea2c7808bb216c38b46c3ba55`), idempotently (check it doesn't exist first). No new `Type`
option.

### B4. Go-live checklist

`docs/stacks-surveys-observations-golive.md`, following `docs/google-groups-observations-golive.md`:
what's done, how to dry-run (trigger `observe` for `stacks-surveys` over a window that contains a
known closed survey), what to verify (see Testing below), how to enable, and how to seed history
(a human triggers the skill once with an explicit window like "the last 365 days" — the automatic
window is capped at 14 days).

## Testing / validation

- **Part A:** the unit + integration tests in A6. Manual check against a real closed survey via
  the MCP endpoint confirms the payload shape and that no responder identity appears.
- **Part B (dry run, before enabling):**
  1. Run `observe` for `stacks-surveys` over a window containing one known closed survey →
     exactly one `:closed` row plus ≤3 `:theme:` rows, `Source = Stacks/Surveys`, working admin
     backlink, no verbatim quotes, no People relation.
  2. Re-run immediately → **zero** new rows (deterministic-key idempotence).
  3. A closed survey with a single response → the `:closed` row only, no theme rows.
  4. An open survey older than 14 days with < 50% response rate → one `:stalled` row; younger or
     well-responded open surveys → nothing.

## Out of scope (v1)

- Any cross-survey synthesis job or in-Rails LLM theme extraction (decision 2).
- The external client feedback survey (`project_capsules.client_feedback_survey_url` is a link to
  a third-party form; nothing is modeled in Stacks).
- Historical backfill beyond the 14-day window cap — seeded manually (B4).
- Changing `Survey#results` / `ProjectSatisfactionSurvey#results` (the empty-set crash and the
  per-question queries are noted, not fixed).
- Audit logging or per-tool scopes on the MCP (a general gap, unchanged here).
- Draft studio surveys are invisible to the tools.
