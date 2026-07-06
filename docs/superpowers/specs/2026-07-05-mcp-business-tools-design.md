# Design: MCP tools — `list_projects_at_risk` + `get_studio_health`

**Date:** 2026-07-05
**Source:** [Stacksbot ROADMAP](https://www.notion.so/garden3d/ROADMAP-md-391131fea2c7801485e0d767177e0da3) Phase 1a + [SPEC — Stacks MCP upgrades](https://www.notion.so/garden3d/SPEC-Stacks-MCP-upgrades-391131fea2c78147a3aff77c7a6a5493)
**Status:** Approved direction (Hugh, 2026-07-05): `list_pipeline` dropped in favor of Notion MCP for lead rows; OKR/win-rate rollups via `get_studio_health` blessed. Remaining defaulted decision flagged ⚖️ below (risk semantics).

## Why this slice

The roadmap's ranked delivery order puts **Business pre-read v1 (automation #2)** next. Its
named dependencies were `list_pipeline` + `list_projects_at_risk` — but **`list_pipeline` is
dropped by decision (Hugh, 2026-07-05)**: lead rows live canonically in the Notion Leads DB,
which Stacksbot reads directly via the Notion MCP (fresher than the Stacks mirror, with all
properties; 🎯 Leads becomes its own Datazone Sources row). Duplicating those rows on Stacks
MCP would create two sources for one dataset. What Stacks uniquely owns is the *rollup* —
`Studio#snapshot`'s per-period lead counts, win rates, financials, utilization, and OKR
health — which is `get_studio_health` (also P1a). This slice therefore ships
`list_projects_at_risk` + `get_studio_health`: the pre-read gets at-risk projects and
pipeline/OKR aggregates from Stacks, and lead rows from Notion.

## Approaches considered

1. **Two thin presenter tools over existing model methods (chosen).** Mirrors the finance/admin
   slices: one file per tool, `Mcp::Responses` envelope, read-only annotations, params with
   sane defaults. `list_projects_at_risk` uses `ProjectTracker.preload_for_render` for batch
   loading; `get_studio_health` is a pure read of the persisted `Studio#snapshot` rollup.
2. **One combined `get_business_preread` tool.** Couples two different consumers (pipeline
   review vs delivery oversight) and diverges from the spec's named tool contract. Rejected.
3. **Server-side pre-read composition (render the whole meeting doc).** That's the Stacksbot
   job's concern, not Stacks'. Rejected.

## Tool 1: `list_projects_at_risk`

- **File:** `app/services/mcp/list_projects_at_risk_tool.rb`
- **Params:**
  - `only_at_risk` (optional boolean, default `true`) — when `false`, returns every non-complete
    project with its metrics + targets so the agent can judge for itself.
  - `include_complete` (optional boolean, default `false`) — include projects whose
    `work_status` is complete/capsule-pending.
- ⚖️ **Risk semantics (defaulted — Hugh to confirm).** At risk = any of, judged against **the
  tracker's own configured targets** (no invented policy — this is what `considered_successful?`
  already means in Stacks). Single source of truth: reuse the model's existing predicates,
  never re-derive the comparisons in the tool:
  - `margin_below_target`: `!target_profit_margin_satisfied?`
  - `free_hours_above_target`: `!target_free_hours_ratio_satisfied?`
  - `over_budget`: `budget_high_end` present and `spend > budget_high_end` (no existing
    predicate — this one comparison lives in the tool)
  Each row carries `at_risk: true/false` and `risk_reasons: [...]` naming the tripped criteria.
  Alternatives Hugh can pick: fixed global thresholds as params, or no server-side judgment.
- **Base scope:** all `ProjectTracker`s whose `work_status` is `:in_progress` or
  `:likely_complete`; `include_complete: true` widens to every tracker. Historical completed
  work stays out of the pre-read by default.
- **Row fields:** `name`, `work_status`, `spend`, `budget_low_end`, `budget_high_end`,
  `profit_margin` (rounded 1dp), `target_profit_margin`, `free_hours_percent` (ratio × 100,
  rounded 1dp), `target_free_hours_percent`, `likely_complete`, `considered_successful`,
  `at_risk`, `risk_reasons`, `url` (`#external_link` — absolute Stacks admin URL).
- **Batch loading:** `ProjectTracker.preload_for_render(scope)` before mapping; rows sorted
  most-at-risk first (by number of tripped criteria, then name) so the pre-read reads top-down.
- **Snapshot dependence:** metrics come from the nightly snapshot jsonb. Trackers with an
  empty/missing snapshot are skipped with a logged warning (same never-raise doctrine as the
  prior tools; a Rails.logger.warn + Sentry, matching the admin-tasks skip path).

## Tool 2: `get_studio_health`

- **File:** `app/services/mcp/get_studio_health_tool.rb`
- **Params:**
  - `studio` (optional string; matched against Studio name or mini_name, case-insensitive,
    Ruby-side like the enterprise/owner resolvers; unknown → error listing valid studios;
    default: all studios with a snapshot).
  - `gradation` (optional enum: `month` / `quarter` / `year` / `trailing_3_months` /
    `trailing_4_months` / `trailing_6_months` / `trailing_12_months`; default `month`;
    invalid → error listing valid gradations).
  - `accounting_method` (optional: `cash` | `accrual`, default `cash`; invalid → error).
  - `periods` (optional integer, default 6, clamped 1..24) — most recent N periods, bounding
    payload size.
- **Reads:** `Studio#snapshot` jsonb (built nightly by `Studio#generate_snapshot!`) — the tool
  NEVER regenerates; it is a pure read of the persisted rollup, so figures always match what
  Stacks reports elsewhere. Structure per period: the chosen accounting method's subtree
  (`datapoints` — income, cogs, expenses, net operating income, profit margin, utilization
  hours (sellable/billable/free), lead_count, satisfaction scores, etc. — plus `okrs` with
  targets/actuals/health). **Pass the subtree through verbatim** (period label/dates +
  `datapoints` + `okrs`): re-mapping invites drift from the canonical computed shape; the
  `periods` clamp keeps payloads bounded.
- **Pipeline aggregates + OKR/win-rate surface** (per Hugh: "cool to surface OKR/win rate
  stuff") come through these snapshot datapoints/okrs — this is the blessed replacement for
  the dropped `list_pipeline` rollups.
- **Studios with a blank/missing snapshot:** skipped with a logged warning when listing all;
  an explicitly requested studio with no snapshot → error saying the snapshot hasn't been
  generated yet.

## Shared conventions (as the prior two slices)

`Mcp::Responses.ok/.error`; `annotations(read_only_hint: true, destructive_hint: false,
idempotent_hint: true)`; registered in `Mcp::Server::TOOLS` (8 tools after this); integration
test tool-name array updated; a `tools/call` round-trip per tool; never a live external API
call (persisted tracker + studio snapshots only).

## Error handling

Unknown `studio` → error listing valid studios. Invalid `gradation` / `accounting_method` →
error listing valid values; `periods` clamped, never errors. Per-row mapping failures →
skip + warn + Sentry, never fail the report. Empty results → valid empty payloads with zero
counts.

## Testing

Unit tests per tool. Trackers: created records with snapshot jsonb covering at-risk on each
criterion separately, not-at-risk, no-budget trackers, missing-snapshot skip, only_at_risk
and include_complete params. Studio health: created Studio records with a representative
snapshot jsonb covering gradation/accounting_method/periods params, param validation errors,
all-studios vs single-studio, blank-snapshot skip vs explicit-request error, and verbatim
subtree pass-through. Integration: registry array + one round-trip per tool. Full suite
green.

## Out of scope

The Business pre-read automation itself (Stacksbot config), the 🎯 Leads Notion Sources row
(follows with automation #2 wiring), `get_capacity`, `get_pnl`, privacy hardening G1–G4, any
write path. `list_pipeline` is not deferred — it is dropped (decision above); the roadmap's
P1a tool list should be amended accordingly.
