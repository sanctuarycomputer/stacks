# Studio OKR: Client & Pipeline KPIs — Design

**Date:** 2026-07-29
**Status:** Approved (brainstorming session with Hugh)

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

## KPI Definitions

### 1. `average_client_lifetime_value` — unit `:usd`, typical operator `greater_than`

As of the period's end date: every `ForecastClient` that has ever had an
`InvoiceTracker`, averaged over each client's total invoiced value up to that
date. All-time population, lifetime-to-date value — a slow-growing number that
rises as bigger, longer-lived clients land.

### 2. `average_client_tenure` — unit months (`:count`), typical operator `greater_than`

As of the period's end date: per client, months elapsed between their first
and most recent invoice pass (up to that date), averaged across all clients
ever. Single-invoice clients count as 0 months.

### 3. `client_revenue_concentration` — unit `:percentage`, typical operator `less_than`

Within the period itself: the largest client's share of the studio's invoiced
revenue. `extras` names the top client and its dollar amount.

### 4. `forecasted_sales_revenue` — unit `:usd`, typical operator `greater_than`

Open pipeline as of the period's end, from Notion leads via the existing
`Studio#new_biz_leads` (already per-studio; garden3d sees all leads).

- **Open lead:** `✨ Lead Received` ≤ period end AND no terminal date
  (`✨ Status: Won`, `✨ Status: Lost`, `✨ Status: Ghosted`,
  `✨ Status: We Passed`, or `Settled Date`) on or before period end. This
  date-based rule captures the Active / Not started / On hold (re-engage)
  statuses and treats Settled as no longer active (per Hugh).
- **Lead value:** midpoint of `Est. Budget Low` / `Est. Budget High`
  (Notion number properties); if only one is filled, use it; if neither,
  the lead contributes $0 and triggers a hygiene task (below).

### Known caveats (accepted)

- **History horizon:** invoice passes start June 2021 (~1,100 trackers,
  113 clients). Pre-2021 clients look younger and smaller than reality in
  LTV and tenure.
- **Budget fill rate:** only ~10% of currently-open leads have Est. Budget
  filled, so forecasted sales revenue starts as an undercount and becomes
  accurate as hygiene tasks are worked.
- **No budget versioning:** historical periods' pipeline values use each
  lead's *current* budget numbers (Notion doesn't version them), so past
  values can drift on re-snapshot.

## Computation & Studio Attribution

### `Stacks::ClientRevenue` (new PORO, `lib/stacks/client_revenue.rb`)

`Studio#key_datapoints_for_period` is already ~190 lines of inline metric
math; the client-revenue logic lives in a new PORO that answers one question:
**per-client invoiced revenue for a studio within a date range.** The three
client KPIs become short calls into it.

- **Value:** an InvoiceTracker's dollar value is its existing `total`
  (manual `value` override, else `blueprint_total`), dated by its
  InvoicePass month, grouped by `forecast_client_id`.
- **Studio attribution:**
  - garden3d: every tracker counts, no splitting.
  - Sub-studios: split each tracker's value by blueprint lines — each line
    encodes a forecast person and `quantity × unit_price`; person → studio is
    the same attribution the cost explorer uses. Malformed blueprint entries
    are skipped and logged (matching the recent cost-explorer fix).
  - Fallback (no blueprint): split by the linked ProjectTracker's
    hours-by-studio for that invoice month
    (`ProjectTracker#total_hours_during_range_by_studio`).
  - If neither exists: the value counts for garden3d but is omitted from
    sub-studio numbers rather than guessed.
- **Internal clients excluded:** clients marked internal via
  `enterprise_forecast_clients` don't count — inter-studio billing would
  inflate LTV and distort concentration.

### Pipeline computation

Stays a small inline computation in `key_datapoints_for_period`, since
`Studio#new_biz_leads` already loads and scopes leads. `Stacks::Notion::Lead`
gains readers for the terminal-status dates and budget fields it doesn't
expose yet. `extras` reports lead count and budget coverage
(e.g. "31 open leads, 12 budgeted").

### Performance

All four KPIs compute inside the existing nightly `Studio#generate_snapshot!`
run. The dataset is small; InvoiceTracker + blueprint data loads once per
snapshot run and is memoized, following existing preload patterns — no
per-period query storms.

## Budget Hygiene Task

`Stacks::TaskBuilder` gains a `needs_budget_estimate` task type: any lead
whose *current* `Lead Status` is Active, Not started, or On hold (re-engage)
with neither `Est. Budget Low` nor `Est. Budget High` filled gets a task
routed to its Account Lead admin users, falling back to the Stacks admin team
when unset (same routing as `needs_settling`).

## Error Handling

- Empty denominators return 0 with explanatory `extras`, not nil — a studio
  with no invoiced revenue in a period reports 0% concentration.
- Leads with missing/unparseable dates are skipped.
- Malformed blueprint entries are skipped and logged.
- Enum integers are appended at the next free values, never renumbered;
  existing datapoints are untouched.

## Testing

RSpec at three levels:

1. **Unit — `Stacks::ClientRevenue`:** grouping by client, studio splits via
   blueprint persons, fallback chain (blueprint → project-tracker hours →
   g3d-only), internal-client exclusion, period-end truncation for LTV/tenure.
2. **Unit — pipeline:** open-lead date logic (each terminal status), budget
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
- Revenue basis for client metrics: **InvoiceTracker** (option C), accepting
  the June 2021 history horizon.
