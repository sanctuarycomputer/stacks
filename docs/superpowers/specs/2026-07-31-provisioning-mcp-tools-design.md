# Provisioning MCP Tools — Design

**Date:** 2026-07-31
**Status:** Approved (autonomous build; flagged decisions surfaced at PR review)

## Problem

PR #158 shipped a generic provisioning HTTP API (contributors, project trackers,
workstreams, rates, recurring assignments) that hides Forecast entirely. The goal
all along was for an agent to satisfy a prompt like:

> "Ensure the Qualitate project has a $450p/h workstream, and set up a weekly
> recurring assignment for hugh@sanctuary.computer on it."

Phase 2 exposes that same provisioning surface as **MCP tools** so the agent can
actually invoke it. This is a thin wrapper layer: no new business logic — the MCP
tools call the already-tested #158 service methods and add only (a) input
validation, (b) the idempotent "find-or-create" glue that makes *Ensure...* prompts
re-runnable.

## Boundary decision (the crux)

`Mcp::WriteServer` today carries the comment: *"Only projection-plane tools exist
here — actuals, rates, and money have no tools, so no composition can reach them."*
Provisioning requires setting a `$450p/h` rate, which crosses that stated line.

**Resolution (approved):** the "no rates/money" rule is really about **actuals and
billing money** — what a contributor is *paid* or a client is *invoiced*. A Forecast
project's `p/h` rate-card *tag* is projection-plane provisioning, not a money-actual.
Provisioning tools (including rate-setting) therefore join the **existing write
surface** (`/api/mcp/write` → `Mcp::WriteServer`), and the comment is tightened to
scope the exclusion to *actuals & billing money*.

## Surfaces

- **Read tools** register on `Mcp::Server` (`/api/mcp`, read-only).
- **Write tools** register on `Mcp::WriteServer` (`/api/mcp/write`).

Forecast stays fully hidden: every id crossing the tool boundary is native
(`Contributor#id`, `ProjectTracker#id`, `ProjectTrackerForecastProject#id` = the
"workstream" id). No `forecast_*` in any tool name, param, or response field.

## Read tools (→ `Mcp::Server`)

### `find_contributor`
- **Input:** `email` (string, required).
- **Wraps:** `Api::ContributorsController#index` logic — `ForecastPerson` by
  case-insensitive email → `Contributor`.
- **Returns:** `[{ id, name, email }]` (array; empty if none).

### `list_project_trackers`
- **Input:** `name` (string, optional), `client` (string, optional) — both
  case-insensitive exact-match, mirroring the HTTP index.
- **Wraps:** `Api::ProjectTrackersController#index` + its `tracker_json`.
- **Returns:** trackers **with nested workstreams**:
  `[{ id, name, client, workstreams: [{ id, name, code, rates }] }]`.
- **YAGNI:** no separate `list_workstreams` tool — trackers already nest their
  workstreams, which covers "what workstreams / rates exist" for disambiguation.

## Write tools (→ `Mcp::WriteServer`)

All three follow the house pattern from `CreateAssignmentTool`:
validate EVERYTHING first → `WriteGuard.check!` **only on the mutate path** →
call the service → `Responses.ok(...)`. Two-tier rescue: `ArgumentError` /
`WriteGuard::CapExceeded` → surfaced message; any other `StandardError` →
`Rails.logger.warn` + `Sentry.capture_exception` + generic
`"<tool> failed; the error was logged"` (no upstream-body leak).

Response envelope: `Responses.ok({ before:, after:, created: })` — `created` is a
boolean so the agent can distinguish "found existing" from "made new".

### `ensure_project_tracker`
- **Input:** `name` (required); `msa_url`, `sow_url`, `budget_low_end`,
  `budget_high_end` (all optional).
- **Behavior:** find `ProjectTracker` by case-insensitive exact `name`.
  - **0 matches** → `ProjectTracker.provision!(name:, msa_url:, sow_url:,
    budget_low_end:, budget_high_end:)` (creates the bare tracker + MSA/SOW
    `ProjectTrackerLink`s with placeholder fallback). `provision!` returns
    `[tracker, warnings]`; the tool returns `{ after: tracker_json, created: true,
    warnings: [...] }`.
  - **1 match** → return `{ after: tracker_json, created: false }`. No mutation, no
    cap slot consumed.
  - **>1 matches** → `ArgumentError` (surfaced): *"multiple trackers named '<name>';
    disambiguate with list_project_trackers and pass the specific id."* We never
    guess which one.
- **Annotations:** `read_only_hint: false, destructive_hint: false,
  idempotent_hint: true`.

### `ensure_workstream`
- **Input:** `project_tracker_id` (integer, required), `name` (required),
  `code` (required), `rate` (required — number or `"Np/h"` string),
  `client_name` (optional).
- **Behavior:** load the tracker; find its workstream
  (`project_tracker_forecast_projects`) whose `forecast_project.code == code`.
  - **Exists** → ensure the rate tag is present: if `Stacks::Forecast.rate_tag(rate)`
    is not already among the project's `p/h` tags, call
    `Stacks::Forecast.new.add_project_rate!(ws.forecast_project_id, rate)` (additive,
    multi-rate-safe). Return `{ after: workstream_json, created: false,
    rate_added: <bool> }`.
  - **Absent** → `tracker.add_workstream!(name:, code:, rate:, client_name:)`.
    Return `{ after: workstream_json, created: true }`.
- **Client rule:** a tracker's **first** workstream needs a client. `add_workstream!`
  find-or-creates the client from `client_name` (and errors "A client is required
  for the first workstream." if the tracker has no client and none is given). The
  tool passes `client_name` straight through; the description tells the agent to
  supply it for a brand-new tracker.
- **Code-collision guard:** inherited from `add_workstream!` (raises
  `ActiveRecord::RecordInvalid` when `code` is already used by *another* tracker) —
  surfaced to the agent as a validation message.
- **Cap:** `WriteGuard.check!` only when actually creating or adding a rate (the
  rate-already-present no-op burns no slot).
- **Annotations:** `idempotent_hint: true`.

### `create_recurring_assignment`
- **Input:** `contributor_id` (integer, required), `workstream_id` (integer,
  required), `allocation_hours` (number, default 8), `weekdays` (int[], default
  `[1,2,3,4,5]`, 0=Sun..6=Sat), `starts_on` (YYYY-MM-DD, default today),
  `ends_on` (YYYY-MM-DD, optional — blank ⇒ never ends), `notes` (string, optional),
  `active_on_days_off` (bool, default false).
- **Wraps:** `Api::RecurringAssignmentsController#create` — resolves
  `contributor.forecast_person_id` and `workstream.forecast_project_id`, builds a
  `RecurringAssignment`, `allocation_in_hours=`, `save!`.
- **Idempotency guard (approved):** if an **active** `RecurringAssignment` already
  exists for the same `(forecast_person_id, forecast_project_id)`, return it with
  `created: false` instead of creating a duplicate. This is what makes the *whole*
  target prompt re-runnable. (Looser than a literal "create"; flagged below.)
- **Returns:** `{ after: { id, contributor_id, workstream_id, allocation_hours,
  weekdays, starts_on, ends_on }, created: <bool> }`.
- **Annotations:** `idempotent_hint: true` (given the guard).

## Validation

Reuse `Mcp::WriteValidation` helpers: `integer!`, `short_string!`, `date_range!`
(for starts/ends when both present). Rate: accept a positive number or a string
ending `p/h`; normalize via `Stacks::Forecast.rate_tag`. `weekdays`: array of ints
⊆ 0..6, non-empty (mirrors the model validation). `allocation_hours` > 0.

## Registration

- `Mcp::Server::TOOLS` gains `FindContributorTool`, `ListProjectTrackersTool`.
- `Mcp::WriteServer::TOOLS` gains `EnsureProjectTrackerTool`, `EnsureWorkstreamTool`,
  `CreateRecurringAssignmentTool`; the file's header comment is tightened to
  "actuals & billing money have no tools".

## Agent flow for the target prompt

1. `find_contributor(email: "hugh@sanctuary.computer")` → `contributor_id`.
2. `ensure_project_tracker(name: "Qualitate")` → `tracker_id` (created or found).
3. `ensure_workstream(project_tracker_id: tracker_id, name: "Qualitate",
   code: "QUAL", rate: "450p/h", client_name: "Qualitate")` → `workstream_id`.
4. `create_recurring_assignment(contributor_id:, workstream_id:, weekdays: [1])`.

Fully re-runnable: a second pass finds the tracker, finds the workstream (rate
already present → no-op), finds the active rule → no duplicates, no wasted cap.

## Testing (Minitest + Mocha; no WebMock/VCR)

Mirror `test/services/mcp/*` — stub `Stacks::Forecast` / service methods at the
class-method level.

- **find_contributor / list_project_trackers:** return shape; email/name/client
  case-insensitive; nested workstreams + rates; empty results.
- **ensure_project_tracker:** 0→provision! (created:true + warnings passed through);
  1→found (created:false, no provision! call, no cap); >1→ArgumentError.
- **ensure_workstream:** absent→add_workstream! (created:true); present + rate
  missing→add_project_rate! (rate_added:true); present + rate already there→no-op
  (rate_added:false, no cap slot); first-workstream-without-client→surfaced error;
  code collision→surfaced validation message.
- **create_recurring_assignment:** creates with defaults (8h/Mon–Fri/today);
  honors overrides; **duplicate active rule → returns existing, created:false, no
  second save**; validation (bad weekdays, allocation ≤ 0).
- **cap discipline:** an ensure no-op does NOT increment `WriteGuard`.
- **Integration:** add cases to `mcp_write_endpoint_test` and `mcp_endpoint_test`
  (tool discovery + one happy-path call each).

## Flagged decisions (for PR review)

1. **Rate-setting lives on the MCP write surface.** The "no rates/money" comment is
   reframed to *actuals & billing money*; provisioning rate-card tags are treated as
   projection-plane setup.
2. **`create_recurring_assignment` returns an existing active rule** for the same
   (person, project) rather than erroring — full-prompt idempotency over strict
   create semantics.
3. **`ensure_*` no-ops don't burn a `WriteGuard` cap slot** (cap fires only on real
   mutation). Deliberate: the breaker counts mutations, and a find-hit isn't one.
4. **`ensure_project_tracker` refuses on an ambiguous name** (>1 match) rather than
   guessing — the agent must disambiguate via `list_project_trackers`.
5. **No standalone `list_workstreams`** — folded into `list_project_trackers`'
   nested output (YAGNI).
6. **People only** for recurring assignments (inherited from #157 — no placeholder
   assignees).
