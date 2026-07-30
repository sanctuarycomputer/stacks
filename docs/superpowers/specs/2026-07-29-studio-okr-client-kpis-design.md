# Studio OKR: Client & Pipeline KPIs — Design

**Date:** 2026-07-29
**Status:** Approved; revised after correctness/simplicity review (see Review Revisions)

## Goal

Add four new Studio-level OKR datapoints to the existing OKR system:

1. **Average Client Lifetime Value** (evolved from "average deal size")
2. **Average Client Tenure** (evolved from "average client retention")
3. **Client Revenue Concentration** (per-client revenue concentration)
4. **Forecasted Sales Revenue** (open pipeline value)

All four become new `datapoint` enum entries on `Okr` (`app/models/okr.rb`),
computed per studio per period in `Studio#key_datapoints_for_period`
(`app/models/studio.rb`), so they inherit targets, tolerance, health tags,
nightly snapshot generation, the OKR Explorer, dashboard chips, and the
`get_studio_health` MCP tool with no extra plumbing.

Scope note: invoice-pass history starts June 2021 (~1,100 trackers, 113
clients). Per Hugh, only the last few years of data matter, so this is the
metric horizon — no backfilling or pre-2021 adjustment.

## KPI Definitions

### 1. `average_client_lifetime_value` — unit `:usd`, typical operator `greater_than`

As of the period's end date: every external `ForecastClient` with countable
invoiced revenue (see Countable revenue), averaged over each client's total
invoiced value up to that date. All-known-history population, lifetime-to-date
value — a slow-growing number that rises as bigger, longer-lived clients land.

### 2. `average_client_tenure` — unit months (`:count`), typical operator `greater_than`

As of the period's end date: per client, months elapsed between their first
and most recent invoice pass (up to that date), averaged across the same
client population as LTV. Single-invoice clients count as 0 months.

### 3. `client_revenue_concentration` — unit `:percentage`, typical operator `less_than`

Within the period itself: the largest client's share of the studio's invoiced
revenue. `extras` names the top client and its dollar amount.

### 4. `forecasted_sales_revenue` — unit `:usd`, typical operator `greater_than`

Current open pipeline, from Notion leads via the existing
`Studio#new_biz_leads` (already per-studio; garden3d sees all leads).

- **Open lead:** current `Lead Status` is `Active`, `Not started`, or
  `On hold (re-engage)`. Status is the source of truth — the terminal date
  stamps (`✨ Status: Won/Lost/Ghosted`, etc.) are missing on most dead leads
  (e.g. 198 of 326 Lost leads have no date stamp), so date-based
  reconstruction is not viable.
- **Lead value:** midpoint of `Est. Budget Low` / `Est. Budget High`
  (Notion number properties); if only one is filled, use it; if neither,
  the lead contributes $0 and triggers a hygiene task (below).
- **Point-in-time metric:** this KPI always reflects the pipeline as of the
  nightly snapshot run, regardless of which period is being viewed. It is a
  "now" metric for steering against current-period targets; it does not
  reconstruct what the pipeline looked like in past periods.

### Known caveat (accepted)

Only ~10% of currently-open leads have Est. Budget filled, so forecasted
sales revenue starts as an undercount and becomes accurate as hygiene tasks
are worked.

## Computation & Studio Attribution

### Countable revenue

An InvoiceTracker counts toward client revenue iff:

- it has a linked, non-voided `QboInvoice` (excludes `:not_made`, `:deleted`,
  and voided trackers — real invoiced dollars only), and
- its `ForecastClient` is external (`!is_internal?` — internal clients are
  mapped to an enterprise via `enterprise_forecast_clients`; 62 trackers are
  inter-studio billing and would inflate LTV and distort concentration).

Its dollar value is the QBO invoice `total`, dated by its InvoicePass month,
grouped by `forecast_client_id`.

### `Stacks::ClientRevenue` (new PORO, `lib/stacks/client_revenue.rb`)

`Studio#key_datapoints_for_period` is already ~190 lines of inline metric
math; the client-revenue logic lives in a new PORO that answers one question:
**per-client invoiced revenue for a studio within a date range.** The three
client KPIs become short calls into it.

**Studio attribution:**

- garden3d: every countable tracker counts, no splitting.
- Sub-studios: split each tracker's value by its blueprint lines — each line
  encodes a forecast person and `quantity × unit_price`; person → studio is
  the same attribution the cost explorer uses. Malformed blueprint entries
  are skipped and logged (matching the recent cost-explorer fix).
- No further fallback: 1,092 of 1,093 trackers have blueprint lines, so a
  secondary attribution path is not worth its complexity. A tracker without
  lines is simply omitted from sub-studio numbers (it still counts for
  garden3d).

### Pipeline computation

Stays a small inline computation in `key_datapoints_for_period`, since
`Studio#new_biz_leads` already loads and scopes leads. `Stacks::Notion::Lead`
gains two readers: `lead_status` (the Notion status property) and
`estimated_budget` (the Low/High midpoint logic). The same "open lead"
definition (status-based) is shared by the KPI and the hygiene task.
`extras` reports lead count and budget coverage
(e.g. "31 open leads, 12 budgeted").

### Performance

All four KPIs compute inside the existing nightly `Studio#generate_snapshot!`
run. The dataset is small; InvoiceTracker + blueprint data loads once per
snapshot run and is memoized, following existing preload patterns — no
per-period query storms.

## Budget Hygiene Task

`Stacks::TaskBuilder` gains a `needs_budget_estimate` task type: any open
lead (same status-based definition as the KPI) with neither `Est. Budget Low`
nor `Est. Budget High` filled gets a task routed to its Account Lead admin
users, falling back to the Stacks admin team when unset (same routing as
`needs_settling`).

## Error Handling

- Empty denominators return 0 with explanatory `extras`, not nil — a studio
  with no invoiced revenue in a period reports 0% concentration.
- Malformed blueprint entries are skipped and logged.
- Enum integers are appended at the next free values, never renumbered;
  existing datapoints are untouched.

## Testing

RSpec at three levels:

1. **Unit — `Stacks::ClientRevenue`:** countable-revenue rules (voided /
   unlinked / internal-client trackers excluded), grouping by client, studio
   splits via blueprint persons (including malformed-entry skip), period-end
   truncation for LTV/tenure.
2. **Unit — pipeline:** status-based open-lead logic, budget
   midpoint/single-value/missing cases, coverage extras.
3. **Integration — `Studio#key_datapoints_for_period`:** all four keys
   present with correct units and sane values.
4. **`TaskBuilder`:** `needs_budget_estimate` fires for open unbudgeted
   leads, routes to Account Lead, falls back to admin team.

## Rollout

1. Ship code (enum entries, `Stacks::ClientRevenue`, computations, lead
   readers, task type).
2. Create the four Okr records manually in ActiveAdmin (name, description,
   operator, OkrPeriods with target/tolerance/date range, studio
   assignments) — the existing workflow.
3. Optional: add the four to OKR Explorer's `all_okrs` list
   (`app/admin/okr_explorer.rb`) so they chart over time.

## Decisions Log (from brainstorming)

- "Average deal size" → reframed as **Average Client Lifetime Value** (Hugh).
- LTV cohort: **all clients ever, all-time revenue** (not period-billed or
  new-client cohort).
- Retention → **average client tenure** (first→last invoice span, months).
- Concentration → **largest client's % of period revenue** (not top-3 or HHI).
- Forecasted sales revenue → **pipeline only** (no booked Forecast.app work).
- Missing budgets → **sum what exists + hygiene tasks** (no synthetic
  fallback values).
- Pipeline scope: **Active, Not started, On hold (re-engage)**; Settled is
  not active.
- Revenue basis for client metrics: **InvoiceTracker** (option C).
- Data horizon: **last few years is sufficient** (Hugh) — June 2021
  invoice-pass start is the metric horizon, no caveat needed.

## Review Revisions (2026-07-29 correctness & simplicity pass)

1. **Open-lead rule rewritten (correctness).** Terminal date stamps are
   unreliable (198/326 Lost, 115/189 Passed, 44/143 Won leads lack them);
   date-based reconstruction would count hundreds of dead leads as pipeline.
   Now: current `Lead Status` only, and the pipeline KPI is explicitly
   point-in-time. This also removed the "unversioned budgets drift on
   re-snapshot" caveat.
2. **InvoiceTracker value semantics corrected.** `value` is the linked QBO
   invoice's total, not a manual override. Countable revenue is now
   "linked, non-voided QBO invoice only" — real invoiced dollars, and the
   48 not-made/deleted trackers drop out naturally.
3. **Attribution fallback chain deleted (simplicity).** 1,092/1,093 trackers
   have blueprint lines; the ProjectTracker-hours fallback served ~1 record
   and is gone. One attribution mechanism remains.
4. **`Settled Date` terminal logic deleted** — obsolete under the
   status-based rule.
5. **History-horizon caveat reframed** as an accepted scope decision per
   Hugh's "last few years" guidance.
