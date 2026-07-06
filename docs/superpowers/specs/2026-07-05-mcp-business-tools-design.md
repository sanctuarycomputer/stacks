# Design: MCP tools — `list_pipeline` + `list_projects_at_risk`

**Date:** 2026-07-05
**Source:** [Stacksbot ROADMAP](https://www.notion.so/garden3d/ROADMAP-md-391131fea2c7801485e0d767177e0da3) Phase 1a + [SPEC — Stacks MCP upgrades](https://www.notion.so/garden3d/SPEC-Stacks-MCP-upgrades-391131fea2c78147a3aff77c7a6a5493)
**Status:** Draft — awaiting Hugh's review. One decision defaulted while he was away, flagged ⚖️ below.

## Why this slice

The roadmap's ranked delivery order puts **Business pre-read v1 (automation #2)** next, and it
depends on exactly these two P1a tools: new/aging Leads (`list_pipeline`) + at-risk projects
(`list_projects_at_risk`). Both read data Stacks already computes — ProjectTracker nightly
snapshots and the Notion Leads mirror — no schema changes, no new syncs. Third slice in the
established pattern (finance pair → admin tasks → business pair).

## Approaches considered

1. **Two thin presenter tools over existing model methods (chosen).** Mirrors the finance/admin
   slices: one file per tool, `Mcp::Responses` envelope, read-only annotations, params with
   sane defaults. `list_projects_at_risk` uses `ProjectTracker.preload_for_render` for batch
   loading; `list_pipeline` uses `Stacks::Notion::Lead.all` + `Studio` period helpers.
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

## Tool 2: `list_pipeline`

- **File:** `app/services/mcp/list_pipeline_tool.rb`
- **Params:**
  - `period_start` / `period_end` (optional ISO dates; default: trailing 30 days ending today).
    Invalid dates → error payload naming the expected format.
  - `studio` (optional string; matched against Studio name or mini_name, case-insensitive,
    Ruby-side like the enterprise/owner resolvers; unknown → error listing valid studios).
- **Reads:** `Stacks::Notion::Lead.all` once (the synced Notion mirror — never live Notion),
  partitioned per studio. **N+1 hazard:** `Lead#studios` calls `Studio.all_studios` internally
  per lead — the tool must hoist: load studios once and resolve each lead's studio names
  against that in-memory list (extend `Lead#studios` with an optional preloaded-studios
  argument, mirroring the existing `account_lead_admin_users_cache` pattern in that class,
  rather than re-implementing the matching in the tool). Period semantics follow
  `Studio#leads_recieved_in_period` / `#sent_proposals_settled_in_period` (received / settled
  date within period).
- **Params (additional):** `aging_min_days` (optional integer, default 30, clamped ≥ 1).
- **Payload:** per studio: `leads_received` (count + rows), `proposals_settled` (count + rows),
  `won` (count of leads with `won_at` within the period), plus `aging_unsettled` — unsettled
  leads (`settled_at` absent) with `age_days >= aging_min_days`, **excluding leads whose
  `reactivate_at` is in the future** (deliberately parked, not aging — the roadmap treats
  Reactivate Date as scheduled re-engagement), sorted oldest first. Independent of the period
  params: aging is a now-state, not a period bucket.
- **Lead row fields:** `title` (Notion page title), `studios`, `received_at`, `age_days`,
  `proposal_sent_at`, `settled_at`, `won_at`, `reactivate_at`, `account_leads` (emails),
  `notion_url`. Lead titles/emails are operational business data — in-bounds per the
  established comp-boundary scope (same rationale as the admin-tasks slice).
- **Leads with malformed/missing dates:** skipped from period buckets they can't be evaluated
  for, never raise; a lead with no `received_at` appears only in a `undated` count so the
  data-hygiene signal isn't silently lost.

## Shared conventions (as the prior two slices)

`Mcp::Responses.ok/.error`; `annotations(read_only_hint: true, destructive_hint: false,
idempotent_hint: true)`; registered in `Mcp::Server::TOOLS` (8 tools after this); integration
test tool-name array updated; a `tools/call` round-trip per tool; never a live external API
call (snapshots + synced NotionPage rows only).

## Error handling

Unknown `studio` → error listing valid studios. Invalid `period_start`/`period_end` → error
naming expected ISO format. Per-row mapping failures → skip + warn + Sentry, never fail the
report. Empty results → valid empty payloads with zero counts.

## Testing

Unit tests per tool (fixtures/created records for trackers with snapshot jsonb covering:
at-risk on each criterion separately, not-at-risk, no-budget trackers, missing snapshot skip;
leads via NotionPage rows covering: received-in-period, settled-in-period, won, aging
unsettled, undated, studio partitioning, period-param validation). Integration: registry
array + one round-trip per tool. Full suite green.

## Out of scope

The Business pre-read automation itself (Stacksbot config), `get_studio_health`,
`get_capacity`, `get_pnl`, privacy hardening G1–G4, any write path.
