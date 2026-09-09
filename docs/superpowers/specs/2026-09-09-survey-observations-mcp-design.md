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
| `status` | `survey.status` (`open`/`closed`; **drafts are invisible**: never listed, and `find` on a draft returns nil → `Survey not found`) | `survey.status` |
| `opened_at` | `opens_at` (a date; non-nil for any non-draft survey) | `created_at.to_date` (project surveys are created open) |
| `closed_at` | `closed_at` | `closed_at` |
| `scope` | `{ studios: [{ name:, mini_name: }] }` | `{ project_tracker_id:, project: tracker.name }` |
| `url` | `#{ADMIN_HOST}/admin/surveys/#{id}` | `#{ADMIN_HOST}/admin/project_satisfaction_surveys/#{id}` |
| `response_count` | count of `survey_responses` | count of `project_satisfaction_survey_responses` |
| `expected_response_count` | `expected_responder_ids.size` (new, see below) | `expected_responders.size` (it's a Hash; reads `all_contributors_with_roles` + `AdminUser.active`, never responder rows) |
| `overall_score` | mean of per-question averages, skipping questions whose average is `nil`; `nil` when no question has an answer (matches the admin page) | the persisted `score` column (synced on close; what the admin page and the OKR snapshot show) |

`list` queries each family separately (`Survey.open`/`Survey.closed`, `ProjectSatisfactionSurvey.open`/`.closed`, with `closed_at: closed_range` applied when given), wraps them, sorts in Ruby by `sort_time = closed_at || opened_at.in_time_zone` descending (normalize to `Time` — never compare a `Date` with a `TimeWithZone`), then applies `offset`/`limit`. Ruby-side sorting is acceptable: the population is a few hundred rows at most.

`list` must not be N+1: preload `includes(:studios)` for studio surveys and `includes(project_capsule: :project_tracker)` for project surveys; compute `response_count` with one grouped query per family (`SurveyResponse.where(survey_id: ids).group(:survey_id).count`, likewise for `ProjectSatisfactionSurveyResponse`). Studio `overall_score` for list rows is computed from `includes(survey_responses: :survey_question_responses)` (a few hundred rows in total across all studio surveys); project rows read the `score` column. `overall_score` is `nil` for open surveys in list rows too.

`expected_response_count` and `response_rate` are computed **only in `results`** (one survey per call) because the studio expected set runs the elevated-service bulk computation; doing it for 50 list rows risks Heroku's 30 s cap.

**One small model addition** (the only model change): `Survey#expected_responder_ids` — a memoized `Set` of admin_user ids equal to the keys of `expected_responder_status`, computed the same way (core members ∪ elevated-service members across the survey's studios) but stopping **before** the per-member `SurveyResponder.find_by`. `expected_responder_status` is refactored to build from it (behaviour unchanged, existing tests must still pass). The presenter uses `expected_responder_ids.size` so `get_survey_results` never queries `survey_responders`.

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
  "response_count": 6, "overall_score": 3.4,
  "url": "https://stacks.garden3d.net/admin/project_satisfaction_surveys/42" }
```

Rules: `closed_after`/`closed_before` go through `Mcp::DateRange.parse` (blank/invalid ignored,
one-sided OK). When a closed range is present and `status` is nil, the list is implicitly
`closed` (an open survey has no `closed_at`); when a closed range is present and
`status: "open"` is also passed, return the error
`closed_after/closed_before cannot be combined with status 'open'` rather than silently
flipping. Unknown `kind` → `Unknown kind 'x'. Valid kinds: studio, project`; unknown `status`
→ `Unknown status 'x'. Valid statuses: open, closed`. `offset` is a plain row skip after
sorting (`offset: 50` with `limit: 50` = the second page). Payload is a bare array (like
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
  0–5 scale the admin pages show. `average` is `nil` for a question with no answered responses.
  Studio `overall_score` is the mean of the non-nil question averages (`nil` when none); project
  `overall_score` is the persisted `score` column. Rounded to 2 dp.
- `distribution` and `average` count only answers whose `sentiment` is a valid enum key (the
  column defaults to `0`, which is not a key and reads back as `nil`); `response_count` per
  question = that same count. (The persisted project `score` scores such rows as 0, so a project
  survey containing an invalid row can show a `score` that differs from the mean of its question
  averages — accepted; such rows cannot be created through the form. In tests, create one with
  `update_column(:sentiment, 0)` — the enum setter raises on `0` and validation rejects `nil`.)
- `contexts` / `responses` include only `present?` strings, **sorted alphabetically within each
  array**. DB order would align index *i* of every array to the same respondent (one full
  questionnaire per index), which is a re-identification aid; sorting breaks that alignment
  deterministically.
- **Free text is withheld below three responses:** when `response_count <
  MIN_RESPONSES_FOR_TEXT` (3), `contexts` are `[]`, `free_text_questions` carry `responses: []`,
  and the payload adds `"free_text_withheld": "fewer than 3 responses"`. Scores and
  distributions are still returned. This is a tool-level guardrail for every MCP consumer, not
  just the observe skill.
- `response_rate = response_count.fdiv(expected_response_count).round(2)` (float division),
  `nil` when expected is 0. It can exceed 1.0 (non-expected users may "Respond anyway"); do not
  clamp.
- `small_sample = response_count < SMALL_SAMPLE_THRESHOLD` (5).
- Questions are ordered by id (creation order) by the presenter.
- The presenter computes aggregates itself rather than calling `Survey#results` (which omits
  unanswered questions and returns no `:overall` for an empty set, leaving the view to raise) or
  `ProjectSatisfactionSurvey#results` (one query per question). Those model methods are
  unchanged. Preload `survey_questions`, `survey_free_text_questions`,
  `survey_responses: [:survey_question_responses, :survey_free_text_question_responses]` (and
  the project equivalents) so `results` is a bounded number of queries.

Open survey payload = the list row plus `description`, `expected_response_count`,
`response_rate`, and `"results_withheld": "survey is open"`. No `questions`, no
`free_text_questions`, no `small_sample`; `overall_score` is `nil`.

Errors: unknown kind as above; missing id, an id of the other kind, or a draft studio survey →
`Survey not found`.

### A4. Privacy rules (Part A)

- The payload **never** contains an `AdminUser`/`Contributor`/`ForecastPerson` name or email,
  a `*Responder` row, or any per-response identifier. Only counts.
- Free text is returned **only for closed surveys with at least 3 responses**, and each array is
  sorted so arrays cannot be aligned by respondent.
- Both tool descriptions state the anonymity contract so any MCP client (not just the observe
  skill) sees it.
- The presenter never issues SQL against `survey_responders` or
  `project_satisfaction_survey_responders` (tested by subscribing to `sql.active_record`).
- **Known residual risk, mitigated in the contract not the code:** the same API key can call
  `get_project_contributors(project_tracker_id)` / `find_contributor` / `get_person_metrics`,
  which enumerate exactly the people a survey went to. That is the pre-existing admin-page
  exposure (any admin can open both pages), not a new one, but the Part B contract explicitly
  forbids the observe and Recall flows from calling those tools for a survey's project or studio.

### A5. Registration and wiring

- Append `Mcp::ListSurveysTool` and `Mcp::GetSurveyResultsTool` to `Mcp::Server::TOOLS`
  (`app/services/mcp/server.rb`). Read server only — never the write server.
- Update the sorted tool-name literal in `test/integration/mcp_endpoint_test.rb` (the
  `tools/list` test) to include `get_survey_results` and `list_surveys`.
- No migrations, no ActiveAdmin changes. The only model change is `Survey#expected_responder_ids`
  (A1).

### A6. Tests

- `test/models/survey_test.rb`: `expected_responder_ids` equals the key ids of
  `expected_responder_status` (core + elevated members), and computing it issues no SQL against
  `survey_responders`.
- `test/services/mcp/survey_presenter_test.rb` (use `travel_to` — `Survey.open`/`#status` use
  `Date.today`, the same midnight-ET hazard the memory notes for `AdminUserTest`):
  - studio + project: `summary` fields (scope, url, opened_at, closed_at, response_count,
    overall_score; `overall_score: nil` for open rows).
  - `results` for a closed survey: per-question `average`, `distribution`, `contexts`,
    `free_text_questions`, `overall_score` (studio = mean of question averages; project = the
    persisted `score`), `response_rate` pinned to a non-integer value such as `0.75`,
    `small_sample` at 4 vs 5 responses.
  - `response_rate: nil` when `expected_response_count` is 0; studio `expected_response_count`
    with a real core member (`make_admin_user!` + `StudioMembership` + `FullTimePeriod`, see
    `test/test_helper.rb`).
  - free text withheld at 2 responses (`free_text_withheld`, empty arrays, scores still present);
    present at 3.
  - arrays are sorted: two responses whose contexts/answers would align by index come back
    alphabetically, not in insertion order.
  - empty-response closed survey: `overall_score: nil`, questions present with `average: nil`,
    no exception.
  - a row forced to `sentiment` `0` via `update_column` is excluded from distribution/average.
  - open survey: `results_withheld`, no free text, no questions.
  - draft studio survey: not returned by `list`; `find` → nil.
  - **anonymity**: create a responder `AdminUser` with a distinctive email + name; assert the
    JSON of `results` and `summary` contains neither. Subscribe to `sql.active_record` around
    `results` and assert no statement references `survey_responders` /
    `project_satisfaction_survey_responders`.
  - `list`: kind/status filters, `closed_range` (both bounds), newest-first ordering across
    kinds, offset/limit; query count for a 10-survey list stays bounded (no N+1).
- `test/services/mcp/list_surveys_tool_test.rb`: enumerated errors for bad kind/status; the
  closed-range + `status: "open"` conflict error; limit clamp (0 → 1, 999 → 200);
  `closed_after` alone implies closed; payload is an array.
- `test/services/mcp/get_survey_results_tool_test.rb`: bad kind error; not-found error (missing
  id, and `kind: studio` with a project survey's id); closed payload includes free text; open
  payload withholds it.
- `test/integration/mcp_endpoint_test.rb`: `tools/list` array; one `tools/call` round-trip per
  tool (a closed project survey with three responses and one free-text answer each).
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
   offset until fewer than `limit` come back. **IDEMPOTENCE GATE (do this first, per survey):**
   query the Observations DB for Source Key `stacks:survey:<kind>:<id>:closed`; if it exists,
   SKIP THIS SURVEY ENTIRELY — do not fetch its results and do not mint any theme rows. The
   window's 6h overlap re-lists recently closed surveys and theme slugs are chosen by you, so
   only the close key is stable; the gate is what makes re-runs write zero rows.
   For each un-observed survey call `get_survey_results(kind, id)` → { title, scope,
   closed_at, response_count, expected_response_count, response_rate, small_sample,
   overall_score, questions[], free_text_questions[], free_text_withheld?, url }. Normalize to
   { id: "<kind>:<id>", timestamp: closed_at, author: none (anonymous), text: the results
   payload, url }.
   Mint, per closed survey (Observed At = closed_at for all rows):
   a. CLOSE SUMMARY — always exactly one row. Source Key `stacks:survey:<kind>:<id>:closed`.
      Type FYI; Type Risk (Salience Medium) when overall_score < 3.0 or any question's average
      < 2.5; Salience High when overall_score < 2.5. Text: title + scope, overall x/5, response
      rate (n of m), the weakest and strongest questions with their averages, and — when
      `list_surveys(kind: <kind>, status: "closed")` shows a prior closed survey with the same
      scope (same studios, or the same project; its `overall_score` is in the list row) —
      "up/down from y/5 on <date>".
   b. THEMES — at most THREE per survey, written in the SAME run as the close summary. Source
      Key `stacks:survey:<kind>:<id>:theme:<kebab-slug>` (slug from the theme's short name, e.g.
      `timeline-pressure`, `unclear-ownership`, `strong-design-dev-collab`; uniqueness within
      the survey is all that matters — the gate above handles re-runs). Type Risk for pain
      points and asks the team should act on; Type FYI for wins worth repeating; Type Question
      for an explicit unanswered ask. Salience Medium for a pain point, Low otherwise. Text
      paraphrases the theme and states support as a count ("4 of 12 responses raise …"). A theme
      MUST be supported by at least TWO distinct responses (contexts or free-text answers) — a
      single response is one person's comment and is never its own row. Skip themes entirely
      when `free_text_withheld` is present (fewer than 3 responses).
2. Stalled open surveys: `list_surveys(status: "open")`. Consider only surveys whose
   `opened_at` is between 14 and 90 days ago (older open surveys are abandoned capsules, not
   signal). For each, call `get_survey_results(kind, id)`; if `response_rate` is non-null and
   < 0.5, mint Source Key `stacks:survey:<kind>:<id>:stalled` — Type Risk, Salience Low,
   Observed At = opened_at + 14 days, text = title, days open, n of m responses. (A single
   stateless key: it dedups on every later run.) Skip when `response_rate` is null.
Reopened surveys: a survey that is reopened and re-closed keeps its `:closed` key and is NOT
re-observed (accepted for v1); while reopened it may appear in the open list — the 14–90 day
bound and the stalled key's dedup make that harmless.
Entities: leave BLANK for every row from this source (the Projects relation carries the link;
a survey about our own team is not "about" a legal entity). Projects relation: for `project`
kind, link the 🎛️ Projects row matching `scope.project` when confident. NEVER set the People
relation from this source.

## Privacy (binding)
Responses are anonymous by design — the stacks tool exposes no responder identity, and you must
not reconstruct one. NEVER call `get_project_contributors`, `find_contributor`,
`get_person_metrics`, or any people-listing tool for a survey's project or studio while
observing or recalling surveys — knowing who was surveyed defeats the anonymity. NEVER quote a
context or free-text answer verbatim; paraphrase. NEVER attribute, guess, or hint who wrote
something (no roles, no "the designer on the project"). When `small_sample` is true, be more
conservative: only themes with ≥2 supporters, and keep the paraphrase general enough that it
cannot be matched to one person. Never write survey content to the Knowledge DB from this
source; durable findings are the nightly distiller's job.

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
     backlink, no verbatim quotes, no People relation, Entities blank.
  2. Re-run immediately → **zero** new rows (the `:closed` gate skips the survey before any
     theme is generated).
  3. A closed survey with fewer than three responses → the `:closed` row only, no theme rows.
  4. An open survey 14–90 days old with < 50% response rate → one `:stalled` row; younger,
     older, or well-responded open surveys → nothing.

## Out of scope (v1)

- Any cross-survey synthesis job or in-Rails LLM theme extraction (decision 2).
- The external client feedback survey (`project_capsules.client_feedback_survey_url` is a link to
  a third-party form; nothing is modeled in Stacks).
- Historical backfill beyond the 14-day window cap — seeded manually (B4).
- Changing `Survey#results` / `ProjectSatisfactionSurvey#results` (the empty-set crash and the
  per-question queries are noted, not fixed).
- Audit logging or per-tool scopes on the MCP (a general gap, unchanged here).
- Draft studio surveys are invisible to the tools.
- Re-observing a survey that is reopened and re-closed (keyed once on `:closed`).
