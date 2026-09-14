# MCP Business-Intelligence Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eleven read-only MCP tools that mirror how admins actually use Stacks (dashboard, enterprise health, OKR grid + explorer, project burn-up/cost/contributors, AP bills, person metrics, quarterly report, capacity), plus two model defect fixes — per `docs/superpowers/specs/2026-08-05-stacks-bi-mcp-assessment.md` (the spec of record; read it first).

**Architecture:** One file per tool at `app/services/mcp/<name>_tool.rb` (`Mcp::XTool < MCP::Tool`), appended to `TOOLS` in `app/services/mcp/server.rb`. Tools read the nightly jsonb caches (`Studio#snapshot`, `Enterprise#snapshot`, `ProjectTracker#snapshot`) and synced QBO mirrors — never live QBO except the explicitly-flagged dashboard money block. Reuse model methods; never re-derive.

**Tech Stack:** Rails, `mcp` gem v0.22.0, minitest. Test env check is Task 0 Step 0.

## Global Constraints (violating any of these is a review-blocker)

- **H1 — cache-only reads:** never call `QboProfitAndLossReport.find_or_fetch_for_range` (live QBO + `delete_all` on force) — use `find_by(qbo_account:, starts_at:, ends_at:)` and report "no cached report". Never bulk-read `QboInvoice#data` outside a scope (lazy per-row live fetch at `qbo_invoice.rb:90-94`); same caution for `QboBill#data` presence.
- **H2 — entity axis:** every finance tool takes an explicit `entity` param (enum: `Sanctuary Computer Inc`, `garden3d, LLC`, `Index Space, LLC`, `USB Club, LLC`), resolves its `qbo_account` explicitly, and **echoes the entity in the payload**. Never let `Stacks::Period#report`'s nil default (silently Sanctuary, `qbo_profit_and_loss_report.rb:75`) decide.
- **H3 — bills are read-only:** `QboBill#destroy` deletes the remote bill in QBO (`qbo_bill.rb:12`). No write path anywhere near bills.
- **H4 — two schemas, never conflated:** Enterprise snapshot (`verticals.<v>.<method>.datapoints.revenue`, "Net Income") vs Studio snapshot (`<method>.datapoints.income`, "Net Operating Income"). Label payloads accordingly; never present them as the same number.
- House conventions (copy from any existing tool, e.g. `list_projects_at_risk_tool.rb`): `Responses.ok/error`; per-row `rescue → log + skip`; invalid enum inputs → `Responses.error` listing valid values; BigDecimal → `.to_f`; clamp numeric params; `annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)`; `server_context:` required kwarg; never echo exception internals (log + Sentry + generic message).
- **Every task updates the sorted tool-name array in `test/integration/mcp_endpoint_test.rb:48`** — the suite hard-fails otherwise — and adds a unit test in `test/services/mcp/`.
- Fixture style: build snapshot hashes directly on models (`Studio.create!(snapshot: {...})`), per `test/services/mcp/studio_health_tool_test.rb:4-27`. Salvageable fixtures exist on the superseded `worktree-mcp-capacity-pnl` branch (`test/services/mcp/pnl_tool_test.rb` there) — copy patterns, not architecture.
- Commit per task: `git add <files> && git commit -m "feat(mcp): <tool_name>"`.

---

### Task 0: Environment check + model defect fixes (D1, D2)

**Files:** Modify `app/models/qbo_profit_and_loss_report.rb`; Test `test/models/qbo_profit_and_loss_report_test.rb`.

- [ ] **Step 0:** Verify the suite runs: `bin/rails test test/services/mcp/tools_test.rb`. If the env can't run tests, STOP and report — every later task depends on it.
- [ ] **Step 1: Failing tests** — in the existing model test (fixture rows already there at `:18-33`): (a) `data_for_enterprise(..., :All)[:profit_margin]` should equal `net_revenue/revenue*100` (currently 0 — D1, both branches `:33` and `:64`); (b) a row labeled exactly `"Income"` must NOT be summed into revenue (D2: `find_rows(method, "Total Income")` passes a String, making `labels_array.include?` a substring test — call sites `:27-30`).
- [ ] **Step 2: Fix** — assign the computed margin in both branches (`dataset[:profit_margin] = ...`); wrap the three `find_rows` call-site arguments in arrays (`["Total Income"]` etc.).
- [ ] **Step 3:** `bin/rails test test/models/qbo_profit_and_loss_report_test.rb` → green. Note in the commit body: Enterprise snapshots regenerate nightly, so persisted margins stay 0 until the next `generate_snapshot!` — tools must still compute margin defensively (Task 2 does).
- [ ] **Step 4:** Commit `fix(pnl): assign profit_margin (was always 0); find_rows exact-match arrays`.

### Task 1: `get_enterprise_health` (the exemplar — copy this shape for all later tools)

**Files:** Create `app/services/mcp/get_enterprise_health_tool.rb`; Test `test/services/mcp/enterprise_health_tool_test.rb`; Modify `app/services/mcp/server.rb` (+ endpoint test array).

**Interfaces — Produces:** `{entity, gradation, vertical, accounting_method, periods: [{label, period_starts_at, period_ends_at, revenue, revenue_growth, cogs, expenses, net_revenue, profit_margin}], raw_rows?, available_verticals}`.

- [ ] **Step 1: Failing test** — `Enterprise.create!(name: "Index Space, LLC", snapshot: {"generated_at" => ..., "month" => [{"label" => "June, 2026", "period_starts_at" => "06/01/2026", "period_ends_at" => "06/30/2026", "verticals" => {"All" => {"cash" => {"datapoints" => {"revenue" => {"value" => 1000.0, "unit" => "usd", "growth" => 10.0}, "cogs" => {"value" => 200.0}, "expenses" => {"value" => 100.0}, "profit_margin" => {"value" => 0}}}}}}]})`. Assert: entity echoed; margin returned as `70.0` (computed in-tool from `(revenue-cogs-expenses)/revenue`, NOT the snapshot's 0); unknown entity → error listing the four valid names; unknown vertical → error listing `available_verticals`.
- [ ] **Step 2: Implement:**

```ruby
module Mcp
  class GetEnterpriseHealthTool < MCP::Tool
    tool_name 'get_enterprise_health'
    description 'Per-legal-entity financial health from the nightly Enterprise snapshot ' \
                '(QBO P&L cache): revenue/cogs/expenses/net revenue/margin per period, ' \
                'per business vertical. Figures are as of the nightly sync.'
    input_schema(properties: {
      entity: { type: 'string', description: 'One of the four Enterprise names. Required.' },
      gradation: { type: 'string', description: 'month (default) | quarter | year | trailing_3_months | trailing_4_months | trailing_6_months | trailing_12_months' },
      vertical: { type: 'string', description: 'A vertical tag (see available_verticals in output); default All' },
      accounting_method: { type: 'string', description: 'cash (default) | accrual' },
      periods: { type: 'integer', description: 'How many trailing periods, default 6, max 24' },
      raw_rows: { type: 'boolean', description: 'Include the raw cached P&L rows for the most recent period (label/value pairs). Default false.' }
    }, required: ['entity'])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(entity:, gradation: 'month', vertical: 'All', accounting_method: 'cash', periods: 6, raw_rows: false, server_context:)
      ent = Enterprise.find_by(name: entity)
      return Responses.error("unknown entity '#{entity}'; valid: #{Enterprise.pluck(:name).join(', ')}") unless ent
      return Responses.error("unknown gradation; valid: #{Studio::SNAPSHOT_GRADATIONS.join(', ')}") unless Studio::SNAPSHOT_GRADATIONS.map(&:to_s).include?(gradation)
      entries = Array(ent.snapshot[gradation]).last(periods.to_i.clamp(1, 24))
      rows = entries.filter_map do |e|
        dp = e.dig('verticals', vertical, accounting_method, 'datapoints')
        next nil unless dp
        revenue = dp.dig('revenue', 'value').to_f
        cogs = dp.dig('cogs', 'value').to_f
        expenses = dp.dig('expenses', 'value').to_f
        net = revenue - cogs - expenses
        { label: e['label'], period_starts_at: e['period_starts_at'], period_ends_at: e['period_ends_at'],
          revenue: revenue, revenue_growth: dp.dig('revenue', 'growth')&.to_f,
          cogs: cogs, expenses: expenses, net_revenue: net,
          profit_margin: revenue.positive? ? ((net / revenue) * 100).round(2) : nil }
      rescue StandardError => e2
        Rails.logger.warn("[Mcp::GetEnterpriseHealthTool] skipping period: #{e2.message}"); nil
      end
      payload = { entity: ent.name, gradation:, vertical:, accounting_method:,
                  available_verticals: (['All'] + ent.discover_verticals), periods: rows }
      payload[:raw_rows] = latest_raw_rows(ent, accounting_method) if raw_rows
      Responses.ok(payload)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetEnterpriseHealthTool] #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_enterprise_health failed; the error was logged')
    end

    def self.latest_raw_rows(ent, accounting_method)
      report = QboProfitAndLossReport.where(qbo_account: ent.qbo_account).order(ends_at: :desc).first
      return nil unless report
      { starts_at: report.starts_at, ends_at: report.ends_at,
        rows: Array(report.data.dig(accounting_method, 'rows')) }
    end
  end
end
```

- [ ] **Step 3:** Register in `server.rb` TOOLS + update the endpoint-test name array; run both test files → green.
- [ ] **Step 4:** Commit.

### Task 2: `get_executive_dashboard`

**Files:** Create tool + test; modify registry + endpoint array (same for all subsequent tasks — not repeated).
**Reads:** the 8 tile definitions verbatim from `app/admin/dashboard.rb:12-63` (`Studio#ytd_snapshot` for g3d/xxix/sanctu, `dig("accrual","okrs",<name>)`) + `Okr.make_annual_growth_progress_data` for the two growth tiles (`okr.rb:53-88`). Money block (param `include_money`, **default false** — spec §7 Q2 open): replicate `dashboard.rb:66-152` — same `Rails.cache` key family (24h), `net_cash` from `Enterprise.sanctuary.qbo_account.fetch_all_accounts` (Bank+CC, Liabilities negated), `average_burn_rate` = 3-month mean of cached-P&L COGS+Expenses, `runway_months = net_cash / burn`, per-account rows, `Contributor.aggregated_new_deal_balance`; on any QBO failure → zeros + `degraded: true` (admin-page precedent `dashboard.rb:126-141`).
**Produces:** `{as_of, okr_tiles: [{name, studio, value, target, tolerance, health, unit, surplus, hint, growth_progress?}], money?: {net_cash, avg_burn_3mo, runway_months, accounts: [{name, classification, balance}], new_deal: {balance, unsettled}, degraded}}`.

- [ ] Failing test (tiles from fixture snapshots; money path tested with `include_money: false` default + a stubbed-failure `degraded` case) → implement → green → commit.

### Task 3: `get_okr_grid`

**Reads:** `Studio#snapshot[gradation]` `okrs` hashes across periods (`studio.rb:198-254` semantics): every OKR name incl. synthetic `Profit`/`Surplus Profit`; `target` is OPTIONAL (absent when value was nil — `okr_period.rb:42-46`); `tolerance` absent on synthetic rows. Params: `studio`, `gradation`, `accounting_method`, `periods` (reuse `get_studio_health_tool.rb:34-60`'s studio resolution).
**Produces:** `{studio, gradation, accounting_method, okr_names: [...], periods: [{label, okrs: {<name>: {value, unit, target?, tolerance?, health, surplus, hint}}}]}` — the grid transposition left to the consumer.

- [ ] Failing test (fixture with one full OKR + one bare-datapoint OKR + a synthetic row) → implement → green → commit.

### Task 4: `explore_okr`

**Reads (live model calls, mirroring `app/admin/okr_explorer.rb` + its view):** param `okr` ∈ the 7 explorer datapoints + `average_hourly_rate`'s per-person view: `successful_projects` → `Studio#project_trackers_with_recorded_time_by_periods` (`studio.rb:311`) then per tracker `profit_margin`, `spend`, `estimated_cost`, `total_hours`, `total_free_hours`, `free_hours_ratio`, `client_satisfied?`, `considered_successful?`; `successful_proposals` → `Studio#sent_proposals_settled_in_period` (`studio.rb:369`) → lead title/url, `proposal_sent_at`, `settled_at`, `considered_successful?`; `average_hourly_rate` → the snapshot period's `utilization` map (per person: rate→hours) — **deliberately exposed here** (the one place; `get_studio_health` keeps stripping it); the 4 client KPIs → the datapoint + its `extras` verbatim. Limit `periods` default 3, max 6 (live queries are heavy).
**Produces:** `{studio, okr, gradation, periods: [{label, value, unit, evidence: [...per-datapoint shape above...]}]}`.

- [ ] Failing test per datapoint branch (fixtures: one tracker, one lead, one utilization map) → implement → green → commit.

### Task 5: `get_project_burnup`

**Reads:** `ProjectTracker` by id or name; snapshot series verbatim (`spend`, `cost`, `hours` — `[{x,y}]` cumulative); income series assembled exactly as `app/admin/project_trackers.rb:323-358` (invoice_trackers + adhoc, sorted by `qbo_invoice.data["due_date"]` fallback `created_at`, tracker-attributable lines only — extract that block into `ProjectTracker#income_series` so admin + tool share one source of truth); money: `income` (`:919`), `spend` (`:732`), `estimated_cost` (`:790`), `profit`, `profit_margin` (`:794`), `lifetime_commissions_paid`; overage: `max(spend-low,0)` / `max(spend-high,0)`; completion: `trailing_7_days_value` / `trailing_30_days_value` (`:689-701`) + weeks/months-left math from `_show.html.erb:360-378`; plus `status`, `work_status`, `considered_successful?`, `generated_at`.
**Produces:** the spec §4 payload sketch, verbatim keys.

- [ ] Failing test (fixture snapshot with 3-point series + budgets; assert overage + weeks-left math and that the admin page still renders via the extracted `#income_series`) → implement (model extraction + tool) → green → commit `feat(mcp): get_project_burnup + extract ProjectTracker#income_series`.

### Task 6: `get_project_cost_breakdown` — reads `ProjectTracker#monthly_cosr` (`project_tracker.rb:740-788`), person-level per Hugh's transparency call (spec §7.1). **Produces:** `{tracker, months: [{month, people: [{name, type, amount}], total}], total}`. Failing test → implement → commit.

### Task 7: `get_project_contributors` — reads `all_contributors_with_roles` (`:531-597`; serialize role symbols + dates) and the per-workstream table (per `forecast_project`: `hourly_rate`, hours trailing 7/30d via `total_hours_during_range`, `total_hours`, spend). **Produces:** `{tracker, contributors: [{name, email, roles: [{role, started_at, ended_at}]}], workstreams: [{name, rate, hours_7d, hours_30d, hours_total, spend_total}]}`. Failing test → implement → commit.

### Task 8: `list_payable_bills` — reads `QboBill` mirrors per entity (**guard `data` presence**; never destroy — H3): vendor `display_name` via realm-scoped `#vendor`, `doc_number`, `total_amount`, `remaining_balance` (nil-able), `paid?`, due date if present in `data`, `qbo_account.enterprise.name`. Param: `entity` (default all four, each labeled). **Produces:** `{as_of, entities: [{entity, bills: [{vendor, doc_number, total, remaining_balance, paid, due_date?}], total_outstanding}]}`. Failing test → implement → commit.

### Task 9: `get_person_metrics` — reads `AdminUser#key_metrics_for_period(period, gradation)` per period (shape `{skill_points, sellable, billable, non_billable, non_sellable, time_off}` each `{value:}`); derive `utilization_rate` (`billable/sellable*100`) and `sellable_ratio` with zero-guards, mirroring `admin_user_key_metrics.rb:40-115`. Params: `email`, `gradation`, `periods` (default 6). Failing test → implement → commit.

### Task 10: `get_quarterly_report` — reads `PeriodicReport` (by `period_label` or latest): `collective_okrs_for_studio_tab` (`periodic_report.rb:121-142`), `quarter_slice_for_studio`, and the full blueprint (gross_surplus, net_profit_share_pool, total_shares, generated_at, per-contributor `{name, tenure_multiplier, effective_cost_of_living_index, elevated_service_months, shares, amount, accepted}`) — person-level per spec §7.1. Param: `studio` tab (g3d default). Failing test → implement → commit.

### Task 11: `get_capacity` — fresh implementation (the superseded worktree's version is reference-only): reads `ForecastPersonUtilizationReport` rows for the current + next period (per person: `expected_hours_sold`, `expected_hours_unsold` = benched, `actual_hours_sold_by_rate`, `actual_hours_internal`, `actual_hours_time_off`) + unfilled placeholder `ForecastAssignment`s. **Produces:** `{gradation, period, people: [{name, email, sellable, benched, billable_by_rate, internal, time_off}], benched_total, unfilled_placeholders: [{project, role?, hours}]}`. Failing test → implement → commit.

### Task 12: Wrap

- [ ] Full suite green (`bin/rails test`); endpoint test's tool array = 23 names sorted.
- [ ] Update `docs/superpowers/specs/2026-08-05-stacks-bi-mcp-assessment.md` status line → implemented; note D3/D4/D5 (latent arity bug, producer-less OKR datapoints, dead admin assignment) as follow-ups NOT fixed here unless trivially adjacent.
- [ ] Push, open PR referencing the assessment; flag in the PR body that `worktree-mcp-capacity-pnl` is superseded and can be archived after merge.

## Self-review notes (done at write time)

- Spec coverage: 11 tools ✓ (Tasks 1–11), defects D1/D2 ✓ (Task 0), D3–D5 explicitly deferred (Task 12), hazards in Global Constraints ✓, Hugh's three §7 calls honored (person-level cost/profit-share; `include_money` default-off; worktree superseded, fixtures salvage noted) ✓. Tier 2 (balance-sheet sync) is deliberately NOT in this plan — separate plan once Hugh settles the cash question.
- Type consistency: payload keys match the assessment's §4 sketches; entity enum matches `Enterprise` constants; gradations validate against `Studio::SNAPSHOT_GRADATIONS` everywhere.
- No placeholders: every task names its exact reader methods with file:line grounding from the 2026-08-05 research sweeps.
