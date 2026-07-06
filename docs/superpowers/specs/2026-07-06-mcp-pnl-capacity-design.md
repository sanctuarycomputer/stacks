# Design: MCP tools — `get_pnl` + `get_capacity`

**Date:** 2026-07-06
**Source:** [Stacksbot ROADMAP](https://www.notion.so/garden3d/ROADMAP-md-391131fea2c7801485e0d767177e0da3) Phase 1a + [SPEC — Stacks MCP upgrades](https://www.notion.so/garden3d/SPEC-Stacks-MCP-upgrades-391131fea2c78147a3aff77c7a6a5493)
**Status:** Draft — awaiting Hugh's review. One boundary decision defaulted while he was away, flagged ⚖️ (capacity per-person identity).

## Why this slice

The last two P1a read tools, completing the read layer (8 → all P1a read tools live). `get_pnl`
unblocks the Financial Reports auto-writer (roadmap automation #9 — per-entity P&L narrative);
`get_capacity` unblocks bench-capacity → outreach (P4) and capacity watch. Both read
data Stacks already computes — no schema changes, no new syncs. Fourth slice in the
established pattern (finance → admin tasks → business → this).

## Tool 1: `get_pnl`

- **File:** `app/services/mcp/get_pnl_tool.rb`
- **CRITICAL — never fetch live.** `QboProfitAndLossReport.find_or_fetch_for_range` fires a
  **live QBO API call** (two, cash + accrual) when no persisted row matches — even with
  `force: false`. Same trap as `QboInvoice#data`'s lazy sync in the finance slice. The tool
  **must query persisted rows directly** (`qbo_account.qbo_profit_and_loss_reports.where(...)`)
  and never call `find_or_fetch_for_range`.
- **Params:**
  - `enterprise` (optional string; name match, Ruby-side case-insensitive like the other
    resolvers; default Sanctuary Computer; unknown → error listing enterprises **that have a
    qbo_account**).
  - `accounting_method` (optional `cash` | `accrual`, default `cash`; invalid → error).
  - `period_type` (optional `month` (default) / `quarter` / `year`; review round 7). QBO
    syncs monthly + quarterly + yearly reports into ONE table with no period-type column, and
    the current year's report is future-dated (Dec 31) — so the default "most recent" MUST be
    scoped by the report's span in days (month ≈27-30d / quarter ≈89-91d / year =364d), else it
    silently returns a whole-year P&L. Ignored when an explicit `start_date`/`end_date` is given.
    The payload echoes the resolved `period_type`.
  - `start_date` / `end_date` (optional ISO dates). Default: the **most recent persisted
    report** for the resolved qbo_account. If a range is given with no matching persisted
    report → error listing the available `(starts_at, ends_at)` ranges (never fetch to fill it).
  - **(vertical param CUT in review round 2 — whole entity only.)** Per-vertical P&L
    (`[SC]`/`[XXIX]` splits of Sanctuary's combined realm) depends on `data_for_enterprise`'s
    vertical bucketing, which only counts vertical rows followed by a `Total` line — so a
    vertical present only in QBO below-the-line sections silently returns an all-zero P&L.
    Shipping that would be silently-incomplete, so v1 reports the **whole entity** (`:All`)
    only; per-vertical is a follow-up that fixes the model bucketing first (same PR as the
    discarded-margin fix below).
- **Reads + computes:** reuse `QboProfitAndLossReport#data_for_enterprise(enterprise, method,
  "", :All)` for the revenue/cogs/expenses/net_revenue bucketing (whole-entity logic is sound).
  **Drive-by:** `data_for_enterprise` computes `profit_margin` but discards the result (the
  `((net/revenue)*100) if revenue > 0` line is never assigned — it returns `profit_margin: 0`
  always, at `qbo_profit_and_loss_report.rb:31,43`). The tool therefore computes margin itself
  (`net_revenue / revenue * 100`, guarded on revenue > 0) rather than emit the model's bogus 0.
  Noted for a separate model fix; not fixed here (it would change admin-dashboard behavior).
- **Payload:** `{ enterprise, accounting_method, period: { starts_at, ends_at },
  revenue, cogs, expenses, net_revenue, profit_margin }` (money rounded 2dp, margin 1dp).
- **No matching report / no reports at all:** error naming the resolved account and listing
  available ranges (or saying none are synced yet) — never a live fetch.

## Tool 2: `get_capacity`

- **File:** `app/services/mcp/get_capacity_tool.rb`
- **Reads:** `ForecastPersonUtilizationReport` (persisted, rebuilt nightly per person per
  gradation: `expected_hours_sold`/`_unsold`, `actual_hours_sold`/`_internal`/`_time_off`,
  `utilization_rate`). Scoped to **active** ForecastPeople (`ForecastPerson.active` — archived
  excluded). Never a live Forecast call. Studio scoping via `Studio#forecast_people`.
- ⚖️ **Per-person identity (defaulted — Hugh to confirm).** This is the most individual-level
  data any Stacks MCP tool exposes. **Chosen: named, resourcing-framed** — each active person's
  email + their hours + `benched` flag. Rationale: the roadmap explicitly names "per-person
  utilization" as a `get_capacity` deliverable, and `get_studio_health` excluded per-person
  utilization *specifically because it is get_capacity's surface*; "who's benched / free to
  staff" is unactionable without names; and booked-hours are operational **resourcing** data,
  not comp/salary/1:1/performance-review content (the wall stays exactly where it's defined).
  The tool emits **no performance-evaluative fields** — raw hours + benched status only, no
  rankings, no "under-utilized" judgments. Alternatives Hugh can pick: name only benched people
  (aggregate the rest), or aggregate-only (no individual identifiers).
- **Params:**
  - `studio` (optional; name/mini_name, comma-split alias aware like `get_studio_health`;
    default all studios; unknown → error listing valid studios).
  - `gradation` (optional; validated against `ForecastPersonUtilizationReport.period_gradations`
    keys — its OWN enum: year/month/quarter/trailing_3_months/…/trailing_12_months; default
    `month`; invalid → error listing the enum keys).
  - `period` — a capacity read is a **now-state**, so default to the single **most recent**
    persisted period for the gradation. (No multi-period param in v1 — YAGNI; add if asked.)
- **Payload (flat — the `studio` param scopes the set, so no nesting):**
  `{ gradation, period: { starts_at, ends_at }, studio: <name or "all">, benched_count,
  people: [{ person, sellable_hours, billable_hours, internal_hours, time_off_hours,
  unsold_hours, utilization_rate, benched }] }`, sorted by `person`. Column mapping:
  `sellable_hours`←`expected_hours_sold`, `billable_hours`←`actual_hours_sold`,
  `internal_hours`←`actual_hours_internal`, `time_off_hours`←`actual_hours_time_off`,
  `unsold_hours`←`expected_hours_unsold`, `utilization_rate`←`utilization_rate`,
  `benched` = `expected_hours_unsold > 0`. (Flat avoids `Studio#forecast_people`'s expensive
  memoized reverse-map for the all-studios case; the `studio` param uses it only when set.)
  No reports for the period → valid empty payload (`benched_count: 0, people: []`).
- **Framing note in the tool description:** explicitly "resourcing / who is free to staff,"
  and that the wall on comp/HR/1:1 content is unaffected.

## Shared conventions (as the prior three slices)

`Mcp::Responses.ok/.error`; `annotations(read_only_hint: true, destructive_hint: false,
idempotent_hint: true)`; registered in `Mcp::Server::TOOLS` (11 tools after this); integration
tool-name array updated; a `tools/call` round-trip per tool; per-row mapping failures →
skip + warn + Sentry, never fail the report; **never a live external API call** (persisted QBO
P&L rows + persisted utilization reports only). `mcp_payload` / `call_tool` test helpers reused.

## Error handling

Unknown `enterprise` (get_pnl) → error listing qbo-account-having enterprises. Unknown
`studio` (get_capacity) → error listing studios. Invalid `accounting_method` / `gradation` →
error listing valid values. get_pnl range with no persisted report → error listing available
ranges (never fetch). Empty results → valid empty payloads.

## Testing

Per tool, created records only (no live calls):
- **get_pnl:** persisted `QboProfitAndLossReport` rows with representative `data` (cash/accrual
  `rows` arrays incl. `Total Income`/`Total Cost of Goods Sold`/`Total Expenses`/`Net Income`);
  assert bucketing + tool-computed margin (not the model's 0), accounting-method selection,
  most-recent default, explicit-range hit + miss-lists-available, unknown-enterprise error, and
  — critically — that a call **never invokes `find_or_fetch_for_range`** (mocha
  `.expects(:find_or_fetch_for_range).never`) so no live fetch can fire.
- **get_capacity:** persisted `ForecastPersonUtilizationReport` rows over created
  `ForecastPerson`s (active + archived); assert column→field mapping, `benched` flag,
  archived-excluded, gradation/period selection (most-recent), benched_count, unknown-studio
  error, and empty-period → empty payload. (Studio-scoping via `Studio#forecast_people` is
  exercised with a created studio + person; keep it minimal.)
- Integration: registry array (11 names) + one round-trip per tool.

## Out of scope

The Financial Reports auto-writer + capacity-watch automations (Stacksbot config); **unfilled
placeholder assignments** for get_capacity (`forecast_assignments.placeholder_id` exists, but
resolving a placeholder → role/studio needs Forecast placeholder metadata that isn't cleanly
persisted — deliberate follow-up, not shipped in v1); the G1–G4 privacy hardening (recommended
next, but wants Hugh's approach-level review); any write path.

**Deferred model-fix follow-up PR** (three related `QboProfitAndLossReport` defects the tool
inherits and works around, all fixed together at the model so the admin dashboard and the tool
stay consistent): (1) `data_for_enterprise` computes `profit_margin` but discards it (returns
0) — get_pnl recomputes in-tool; (2) per-vertical bucketing ignores below-the-line rows — get_pnl
cut the vertical param; (3) `find_rows` matches labels by String `include?` (substring) rather
than equality, so a row whose label is a substring of a target total (e.g. `Income` ⊂ `Total
Income`) with a nonzero value would inflate revenue — get_pnl reuses it as-is for single-source
consistency with the dashboard (fixing only the tool would make the two disagree).
