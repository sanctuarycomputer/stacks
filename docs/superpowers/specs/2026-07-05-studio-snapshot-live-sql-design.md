# Studio Snapshot → Live SQL (no derived cache)

**Date:** 2026-07-05
**Status:** Draft — pending review
**Scope:** `Studio` only. `Enterprise#generate_snapshot!` and `ProjectTracker#generate_snapshot!` have the same disease but get their own specs later; this design's primitives (P&L line items, month-folding) are built to be reusable by them.

## Problem

`Studio#generate_snapshot!` walks 7 gradations × ~150 periods since 2020 × 2 accounting methods nightly, computes ~25 datapoints + OKR health per period per studio, and writes it all into the `studios.snapshot` jsonb blob. Costs:

- A long nightly job with fragile ordering (internal → reinvestment → client_services) and connection-pool tuning (`Parallel in_threads: 5`).
- Data is up to 24h stale; a bad run leaves a stale/partial blob with no cheap fix.
- The blob is opaque: consumers `dig` string paths; nothing is queryable.

## Key insight

Every period `Stacks::Period.for_gradation` ever builds is **month-aligned** (unions of calendar months). Nearly every datapoint is **additive over months** (dollars, hours, lead counts) or a **ratio of additive quantities** (profit margin = ΣNOI/Σincome; avg hourly rate = Σ(rate×hrs)/Σhrs). So a monthly fact grain + `SUM ... WHERE month BETWEEN` reproduces every window exactly — no precomputed windows needed. P&L line items are flows, so monthly reports sum to range reports for both cash and accrual basis (verified during rollout, see Oracle).

Non-additive stragglers, each already cheap live:
- distinct project counts / success rates → existing batched `project_trackers_with_recorded_time_by_periods`
- project satisfaction → completed-projects query per span
- workplace satisfaction → one survey lookup
- OKR health/hints → Ruby arithmetic over computed datapoints

What stays cached (unavoidable): the raw synced copies of external APIs (`qbo_profit_and_loss_reports`, `forecast_person_utilization_reports`, `notion_pages`). What gets deleted: the derived layer — the blob, `generate_snapshot!`, and the rake ordering.

## Architecture

Three layers. All new code is service objects (repo convention: `Domain::Verb.call`, e.g. `DeelInvoiceAdjustments::SyncFromDeel`).

### Layer 1 — sync-time normalization (new derived tables, written by sync services)

These are *projections of already-synced data into queryable shape*, rebuilt idempotently at sync time — not caches of computation.

**`qbo_profit_and_loss_line_items`**
| column | type | notes |
|---|---|---|
| qbo_account_id | fk, null: false | |
| qbo_profit_and_loss_report_id | fk, null: false, `on_delete: :cascade` | cascade because `find_or_fetch_for_range(force:)` uses `delete_all` (no callbacks) |
| starts_at | date, null: false | first of month; **monthly reports only** |
| accounting_method | string, null: false | `cash` / `accrual` |
| position | integer, null: false | row order in the source report — preserves the section inference Enterprise needs later |
| label | text, null: false | |
| amount | decimal, null: false | |

Indexes: unique `(qbo_profit_and_loss_report_id, accounting_method, position)`; query index `(qbo_account_id, accounting_method, starts_at)`.
Volume: ~75 months × ~200 rows × 2 methods ≈ 30k rows/account — trivial.

- `Qbo::SyncProfitAndLossLineItems.call(report)` — deletes + reinserts the report's line items in a transaction. No-op unless the report's range is exactly one calendar month.
- Hooked into `QboProfitAndLossReport.find_or_fetch_for_range` on the `create!` path, so the existing nightly `QboAccount#sync_all!` (which force-refreshes every monthly report from `started_at` = 2023-01) keeps line items fresh with zero new scheduling.

**`studio_forecast_people`**
`(studio_id, forecast_person_id)`, unique on the pair.

- `Studios::SyncForecastPeople.call` — rebuilds the table **by calling the existing `Studio#forecast_people`** (single source of truth; no logic duplication of the admin-user/roles heuristics). Runs in the daily rake after Forecast sync. The Ruby method stays for live callers; the table exists only so utilization aggregation can happen in SQL.

**`notion_leads`** (+ `notion_lead_studios` join)
| column | type |
|---|---|
| notion_page_id | fk, unique, null: false |
| received_at | date |
| settled_at | date |
| proposal_sent_at | date |
| won_at | date |

- `Leads::SyncFromNotionPages.call` — iterates `NotionPage.lead`, extracts via the existing `Stacks::Notion::Lead` accessors (source of truth), parses dates defensively (`settled_at` is a free-string Notion prop — warn + null on parse failure, per the `Mcp::QboReceivables` warn-don't-silently-drop pattern). Runs after Notion sync in the daily rake. Studio tagging via the join table; `is_garden3d?` reads all leads (matches today's semantics).

### Layer 2 — read-time query services (no cache)

**`Studios::Snapshots::GradationRows.call(studio:, gradation:)`** → array shape-identical to today's `snapshot[gradation]` (label, period_starts_at/ends_at strings, `cash`/`accrual` → `{datapoints, okrs}`, per-person `utilization`). This is the workhorse; per-period reads delegate to it or to:

**`Studios::Snapshots::PeriodDatapoints.call(studio:, period:, prev_period:, accounting_method:)`** → shape-identical to `key_datapoints_for_period`.

Query strategy (the ≤50ms budget): per gradation, a handful of **span-wide grouped queries**, folded into periods in Ruby — never per-period queries:

1. **P&L:** one query per accounting method: `SELECT starts_at, SUM(amount) ... WHERE qbo_account_id = ? AND starts_at BETWEEN ? AND ? AND <label predicate> GROUP BY starts_at` — label predicates replicate `profit_and_loss_for_period` exactly (garden3d: exact `Total Income` / `Total Cost of Goods Sold` / `Total Expenses` / `Net Operating Income` labels; other studios: `LIKE` on `Revenue - <accounting_prefix>` / `COS - <prefix>` `Total…` rows / `Tools and Subscriptions - <prefix>`).
2. **Utilization:** monthly-grain `forecast_person_utilization_reports` joined through `studio_forecast_people`, grouped by `(forecast_person_id, starts_at)`, with a `LATERAL jsonb_each_text(actual_hours_sold_by_rate)` aggregation for the rate→hours map. Per-person monthly rows are additive, so quarter/trailing/year rows fold from months — including the per-person `utilization` breakdown and the g3d comparison set. (Per-gradation utilization row *generation* keeps running for now; retiring it is a follow-up.)
3. **Leads:** counts grouped by month bucket from `notion_leads` (+ join for studio scoping); proposal success from `won_at` presence among settled-in-period rows.
4. **Projects:** reuse `project_trackers_with_recorded_time_by_periods` (already batched); success/satisfaction predicates stay in Ruby over the small per-period sets.
5. **OKR health:** reuse the existing `okrs_for_period` / `hint_for_okr` logic, extracted to `Studios::Snapshots::OkrRows` so both old and new paths share it during rollout.
6. **Growth:** computed between adjacent folded periods in Ruby (no second query).

Rules:
- **The read path never calls QBO/Forecast/Notion** (same hard rule as `Mcp::QboReceivables`). Missing months → compute from what's present, `Rails.logger.warn` with the gap (a cheap `COUNT(DISTINCT starts_at)` vs expected-month-count guard), mirroring today's `find_row` 0-defaults rather than raising.
- Pre-`UTILIZATION_START_AT` periods return nil utilization datapoints, exactly as today.

Compatibility: `Studio#ytd_snapshot`, `#last_year_snapshot`, `#net_revenue` re-implemented over the services. External consumers (`app/admin/studios.rb`, `app/admin/okr_explorer.rb`, `app/models/admin_user.rb:596`, `app/models/profit_share_pass.rb:330`, `app/models/periodic_report.rb#quarter_slice_for_studio`) swap to service calls in Stage 3 — the identical row shape makes each swap mechanical.

### Layer 3 — backfill & verification

**`Qbo::BackfillMonthlyProfitAndLossReports.call(qbo_account:, from: Date.new(2020, 1, 1))`**
- For each calendar month from `from` through last month missing a `QboProfitAndLossReport` row: fetch via `find_or_fetch_for_range` (non-force). Pre-2023 months likely already exist (lazily cached by historical snapshot runs) — the service reports found/fetched counts. Idempotent, resumable, throttle-aware (sleep between QBO calls).
- Then `Qbo::SyncProfitAndLossLineItems.call` over every monthly report for the account.
- Runs once per account at rollout; the nightly `sync_all!` hook maintains it thereafter.

**Oracle — `Studios::Snapshots::DiffAgainstStored.call(studio)`** (rake task)
- Walks the stored blob and diffs every gradation/period/method/datapoint against service output with float tolerance; prints discrepancies. Run immediately after a nightly blob regeneration so both sides see the same underlying data.
- Includes the **additivity check**: for sampled quarters/years, stored range-report totals vs Σ monthly line items, both methods. This empirically validates the month-summing assumption before any consumer swaps.

## Rollout stages

1. **Normalize:** migrations, `Qbo::SyncProfitAndLossLineItems` (+ hook), `Studios::SyncForecastPeople`, `Leads::SyncFromNotionPages`, backfill service + run. No consumer changes.
2. **Query + verify:** read services + oracle rake; iterate until diffs are clean (or every diff is an explained blob-staleness artifact).
3. **Swap consumers:** migrate the six consumer sites; keep blob writes running as fallback for one release.
4. **Delete:** `generate_snapshot!`, `snapshot_data_for_period`, `utilization_by_period_gradation` (snapshot-only callers), the rake snapshot block + ordering comments, and drop `studios.snapshot`. Follow-ups (separate): retire per-gradation utilization report generation (monthly suffices); retire `sync_quarterly/yearly_profit_and_loss_reports!` (blocked on the Enterprise migration, which still reads range reports).

## Error handling

- Sync services: per-row rescue + `Rails.logger.warn`, never abort the whole rebuild for one bad row (receivables pattern).
- Read services: warn-and-continue on gaps; never network; never raise for missing data (return nil-valued datapoints as today).
- Backfill: per-month rescue, resumable, reports a summary.

## Testing

- Unit specs per service (fixtures for line items, membership, leads; shape assertions against a recorded `key_datapoints_for_period` output).
- The oracle diff is the acceptance test for Stage 2 — run against production data before Stage 3.
- Additivity spot-check is part of the oracle.

## Performance

Budget: ≤50ms per (studio, gradation) read. Expected: ~6 grouped queries over tens-of-thousands-row tables with covering indexes — single-digit ms each. OKR explorer (all-studio views) can later batch with `GROUP BY studio_id`; not needed for Stage 3.

## Out of scope

- Enterprise & ProjectTracker snapshot migrations (separate specs; `position` on line items is the one field carried specifically so Enterprise's section-inference can reuse the table).
- Retiring per-gradation utilization generation and quarterly/yearly P&L syncs (follow-ups noted in Stage 4).
