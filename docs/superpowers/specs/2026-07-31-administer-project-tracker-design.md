# Administer a Project Tracker — Design

**Date:** 2026-07-31
**Status:** Approved (autonomous build; flagged decisions surfaced at PR review)

## Problem

PR #158/#160 can **create** a project tracker and its sub-objects (workstreams, rates,
recurring assignments) but can't **administer** existing ones. Gaps, all of which a true
"administer a project tracker" agent skill needs:

- Update an existing tracker — name, budgets, and **replace the placeholder MSA/SOW links**
  that `provision!` warns about but provides no way to fix.
- **Remove** a rate from a workstream (exists in HTTP, never wrapped for MCP).
- **Mark / unmark work complete** (`work_completed_at`).
- **Set the account-lead / project-lead** for a tracker.
- **Manage a recurring assignment's lifecycle** — pause / resume / destroy.

This closes them as new **MCP tools** (the agent's channel) over new/existing **model
methods**, keeping the #160 seam: model methods do the work, thin tools validate + wrap,
Forecast stays hidden, ids are native.

## Surfaces

- Read tools register on `Mcp::Server` (`/api/mcp`).
- Write tools register on `Mcp::WriteServer` (`/api/mcp/write`).
- **HTTP parity is out of scope for this PR** (the consumer is the MCP agent; the HTTP API
  is a parallel door). Deferred, noted below.
- **Audit-log wiring lives in the skill, not the tools.** Tools execute and return
  `{before, after, ...}`; the "Administer a Project Tracker" skill logs one 📜 Audit Log
  row per write. No tool change for audit.

## New read tools

### `find_admin_user`
- **Input:** `email` (required).
- **Why:** leads are **`AdminUser`s** (garden3d staff), NOT Contributors/ForecastPersons —
  a distinct lookup from `find_contributor`.
- **Behavior:** `AdminUser.where("lower(email) = ?", email.strip.downcase)`.
- **Returns:** `[{ id, name, email }]` (`AdminUser#name`/`display_name` both return email;
  return `email` for both fields).

### `list_project_trackers` — ENRICHED (additive)
Extend `Mcp::ProvisioningSerializers.tracker_json` (used by `list_project_trackers`,
`ensure_project_tracker`, `update_project_tracker`) so the agent can see current state
before administering. Add, alongside the existing `{ id, name, client, workstreams }`:
- `budget_low_end`, `budget_high_end` (numbers or null)
- `work_completed_at` (ISO or null), `work_status` (the model's `work_status` symbol as a string)
- `msa_url`, `sow_url` (from the tracker's `msa`/`sow` `ProjectTrackerLink`s, or null)
- `account_lead` and `project_lead`: `{ name, email }` of the **current open** period's
  admin_user (period with `ended_at` nil), or null.

Additive only — #160's existing assertions (`id`/`name`/`client`/`workstreams`) stay valid.

## New write tools

All follow the house pattern: validate → `WriteGuard.check!` only on the real mutate path →
model method → `Responses.ok({ before:, after:, ... })`; rescue order `ArgumentError,
WriteGuard::CapExceeded` → `ActiveRecord::RecordNotFound` → `ActiveRecord::RecordInvalid`
(surface `e.record.errors.full_messages`) → `StandardError` (log + Sentry + generic).

### `update_project_tracker`
- **Input:** `project_tracker_id` (required); `name?`, `budget_low_end?`, `budget_high_end?`,
  `msa_url?`, `sow_url?` (all optional — only provided fields change).
- **Model method:** `ProjectTracker#update_details!(name: nil, budget_low_end: nil,
  budget_high_end: nil, msa_url: nil, sow_url: nil)`:
  - Assign `name`/budgets when the arg is non-nil.
  - For `msa_url`: find the tracker's `link_type: :msa` `ProjectTrackerLink` and update its
    `url`; if none exists, build one (`name: "MSA", link_type: :msa`). Same for `sow_url`
    (`link_type: :sow`, `name: "SOW"`).
  - `save!` — keeps `has_msa_and_sow_links` and the budget-pair validations
    (`budget_low_end <= budget_high_end`; both-or-neither).
- **Returns:** `{ before: <tracker_json pre>, after: <tracker_json post>, updated: <changed fields> }`.
- Rate limits: `WriteGuard.check!` before the write.

### `remove_workstream_rate`
- **Input:** `workstream_id` (the `ProjectTrackerForecastProject` id), `rate` (string/number).
- **Behavior:** load the workstream; `Stacks::Forecast.new.remove_project_rate!(ws.forecast_project_id, rate)`
  (mirrors `Api::WorkstreamsController#remove_rate`). `remove_project_rate!` is tolerant —
  removing an absent tag is a no-op update.
- **Returns:** `{ before:, after: <workstream_json post reload>, removed: <bool> }` — `removed`
  is whether the rate tag was present beforehand.
- `WriteGuard.check!` only when the tag was actually present (no-op removal burns no slot).

### `set_project_tracker_work_completed_at`
- **Input:** `project_tracker_id`; `completed_at?` — an ISO date/datetime (default: today) to
  mark complete, or explicit `null` to unmark.
- **Model method:** `ProjectTracker#mark_work_completed!(at:)` → `update!(work_completed_at: at)`
  (`at` may be nil to clear). (Admin uses `update_column`; we use `update!` for consistency —
  there are no validations gating this column.)
- **Returns:** `{ before: { work_completed_at:, work_status: }, after: { work_completed_at:, work_status: } }`.
- Distinguish "omitted" from "explicit null": default the tool param to a sentinel so
  `completed_at: null` clears and an omitted arg marks-now. (Implementation: accept the key;
  if the key is absent → today; if present and blank/null → nil.)

### `set_project_tracker_role_assignee`
- **Input:** `project_tracker_id`; `role` (`"account_lead"` | `"project_lead"`);
  `admin_user_email` (required); `starts_on?` (ISO date, default `today.beginning_of_month`).
- **Model method:** `ProjectTracker#set_role_assignee!(role:, admin_user:, starts_on:)`:
  - `role` maps to `account_lead_periods` or `project_lead_periods`. Old Deal variants are
    NOT exposed.
  - `starts_on` must be the **first day of a month** (raise `ArgumentError` otherwise — the
    period model requires it).
  - **Current open period** = the role's period with `ended_at` nil (at most one by convention).
  - If the current open period's `admin_user == target` → **no-op**, return it.
  - Else if a current open period exists and its `started_at` is in an **earlier month** than
    `starts_on` → set its `ended_at = starts_on.prev_day` (= last day of prior month; satisfies
    full-months + non-overlap), `save!`; then create the new period (`admin_user`,
    `started_at: starts_on`, `ended_at: nil`), `save!`.
  - Else (an open period that **started this same month** — a same-month lead swap) → raise a
    clear error: *"a lead already starts this month; resolve same-month lead changes in the
    admin UI"* (financially sensitive — account leads carry an 8% take; avoid silent
    overlap/rewrite). **Flagged.**
- **Returns:** `{ before: { role, assignee: {name,email}|null }, after: { role, assignee: {name,email} } }`.
- `WriteGuard.check!` only when actually changing the assignee (no-op burns no slot).

### `manage_recurring_assignment`
- **Input:** `recurring_assignment_id`; `action` (`"pause"` | `"resume"` | `"destroy"`).
- **Behavior:** load `RecurringAssignment`.
  - `pause` → `update!(paused_at: Time.current)` (no-op if already paused).
  - `resume` → `update!(paused_at: nil)`.
  - `destroy` → `destroy!` — removes the rule + its occurrence rows (`dependent: :destroy`);
    **leaves already-materialized Forecast assignments intact** (per #157's destroy semantics).
- **Returns:** `{ before: { paused_at:, exists: true }, after: { paused_at:, exists: <bool> }, action: }`.
- `WriteGuard.check!` before the mutation.

## Testing (Minitest + Mocha)

Append to `test/services/mcp/provisioning_tools_test.rb` (reuse its helpers; add
`make_admin_user(email:)` and lead-period fixtures). Cover per tool:
- **find_admin_user:** case-insensitive match; empty.
- **list enrichment:** budgets, work_completed_at/work_status, msa/sow urls, account/project
  lead present + null cases.
- **update_project_tracker:** update name/budgets; replace existing MSA link url; build SOW
  link when absent; budget-pair validation surfaced; only-provided-fields change.
- **remove_workstream_rate:** present tag removed (`removed:true`); absent tag no-op
  (`removed:false`, no cap slot); missing workstream → clean error.
- **set_project_tracker_work_completed_at:** default marks today; explicit date; null unmarks;
  work_status reflects it.
- **set_project_tracker_role_assignee:** first-time set (creates period); reassign across
  months (ends prior at end-of-prior-month, creates new); no-op when already the lead (no cap);
  same-month swap raises; non-first-of-month `starts_on` raises; unknown admin email → error;
  account vs project role hits the right period table.
- **manage_recurring_assignment:** pause sets paused_at; resume clears; destroy removes rule +
  occurrences but does NOT call Forecast delete; unknown id → clean error.
- **Integration:** update the pinned `WRITE_TOOLS` (now 13) in `mcp_write_endpoint_test.rb`
  and the read-tool list (add `find_admin_user`) in `mcp_endpoint_test.rb`; one happy-path each.

## Flagged decisions (for PR review)

1. **Lead handoff is monthly.** `set_project_tracker_role_assignee` ends the prior lead at the
   end of the prior month and starts the new one at the first of the target month
   (`starts_on`, default this month). A **same-month lead swap raises** and defers to the admin
   UI — account leads carry an 8% take, so silent overlap/rewrite is unsafe.
2. **Only `account_lead` + `project_lead`** are exposed; Old Deal lead variants are left alone.
3. **HTTP parity deferred** — MCP-only this PR (the agent's channel). `workstreams#remove_rate`
   already exists in HTTP; the rest can follow if a non-agent caller needs them.
4. **`list_project_trackers` enriched additively** (budgets, completion, links, leads).
5. **`manage_recurring_assignment` destroy leaves Forecast assignments intact** (per #157).
6. **Audit-log wiring stays in the skill**, not the tools; tools return `{before, after}`.
