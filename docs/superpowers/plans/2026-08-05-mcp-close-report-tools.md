# MCP Monthly-Close Report Tools Implementation Plan (Tier 1.5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three read-only MCP tools closing the signal gaps found by auditing the controller's actual monthly-close reports (📈 Financial Reports, Datazone): `get_membership_stats` (Optix), `get_invoice_passes`, `get_client_revenue`. Spec context: `docs/superpowers/specs/2026-08-05-stacks-bi-mcp-assessment.md` (Global Constraints + hazards H1–H5 bind unchanged) — this plan is its Tier-1.5 addendum.

**Why these three (grounded in the reports):** the Apr-26 Coworking report links `/admin/optix_organizations/1` for weekly paying-member counts and frames profitability as "11+ Patron / 35 Non-Patron members"; the May-26 Client Services report narrates revenue client-by-client (Reactor $154K = 33%, Replit −$26K MoM, top-clients list) — `Stacks::ClientRevenue` computes exactly those rows; Hugh explicitly asked for total-invoiced / invoice-pass volume per entity — `InvoicePass` has a 388-line admin surface and no tool.

## Global Constraints (additions to the assessment's)

- **No member PII:** `get_membership_stats` returns COUNTS and plan-mix aggregates only — never member names/emails (the reports need counts of *paying members*; individual identity is irrelevant and stays out).
- Client names in `get_client_revenue` are fine (business data; the reports name clients).
- All the established house conventions (Responses.ok/error, per-row rescue-skip, enum errors listing valid values, clamps, read_only annotations, sorted endpoint-array updates, `mcp_payload` test helper, jsonb key-order caution, `travel_to` pins).
- Cache/synced-data only (H1). If any Optix read path lazily fetches, guard it the way `IncomeSeries` guards `QboInvoice` (stored attributes only, skip + count).

### Task 0: Research + payload finalization + env gate
- [x] `bin/rails test test/services/mcp/tools_test.rb` runs green (env gate; `db:test:prepare` if needed).
- [x] Read and note (file:line): the Optix models (`app/models/optix_*.rb`) + admin surfaces (`app/admin/optix_*.rb`) — how paying-member counts per location are derived (the `/admin/optix_organizations/:id` weekly-count report the controller references), how "paying" is distinguished, how plans map Patron/Non-Patron, how/when the Optix sync runs; `app/models/invoice_pass.rb` + `app/admin/invoice_passes.rb` — pass→trackers→qbo totals, month semantics, per-entity attribution; `lib/stacks/client_revenue.rb` — the Row(client, month, amount) construction, studio-share, external-client scoping, the skipped-tracker counting.
- [x] Finalize the three payload shapes within the sketches below, adjusting to model reality (document deviations in commit bodies).

### Task 1: `get_membership_stats`
Sketch: `{as_of, locations: [{location, paying_members, weekly_counts: [{week, count}] (trailing N weeks, clamp 4..26, default 13), plan_mix: [{plan_type, count}], growth_4w_pct}], total_paying_members}`. Mirror the admin org report's counting logic exactly (it is the controller's reference surface — "paying members only"). Counts only, no PII. TDD; registry + sorted endpoint-array; commit.

### Task 2: `get_invoice_passes`
Sketch: `{months_back (clamp 1..24, default 6), passes: [{month, completed_at?, entities: [{entity, invoiced_total, invoice_count, status_mix: {paid, unpaid, overdue, ...}}], total_invoiced}], mom: [{month, total_invoiced}]}`. Read synced QboInvoice STORED data only (IncomeSeries-style guard, skip+count blank rows). Entity attribution via each invoice's qbo_account → enterprise, echoed per the entity axis. TDD; commit.

### Task 3: `get_client_revenue`
Sketch: `{months_back (clamp 1..24, default 6), scope note (external clients, countable revenue per Stacks::ClientRevenue), clients: [{client, monthly: [{month, amount}], total, share_of_total_pct}] sorted by total desc, top param (clamp 1..50, default 15), skipped_tracker_count, mom_totals: [{month, total}]}` + optional `studio` param using the studio-share path. Reuse `Stacks::ClientRevenue` (one instance per call — heed its un-memoized/thread-safety comment); never rebuild the math. TDD; commit.

### Task 4: Wrap
- [ ] Endpoint array = 26 sorted names + one `tools/call` round-trip per new tool.
- [ ] Full `test/services/mcp` + endpoint + touched model tests green; run `bin/rails test` full suite once, report pre-existing failures without fixing.
- [ ] Commit; do NOT push.

## Self-review notes
Scope covers exactly the three audited gaps; budgets/projections (Google Sheets) deliberately out of scope — noted in the stacksbot-side report. The stacksbot wiring (stacks-bi contract extension + monthly transition keys) happens after merge+deploy, not in this repo.
