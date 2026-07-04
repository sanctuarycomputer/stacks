# Design: MCP tool — `list_open_admin_tasks`

**Date:** 2026-07-04
**Source:** [Stacksbot ROADMAP](https://www.notion.so/garden3d/ROADMAP-md-391131fea2c7801485e0d767177e0da3) Phase 1a + [SPEC — Stacks MCP upgrades](https://www.notion.so/garden3d/SPEC-Stacks-MCP-upgrades-391131fea2c78147a3aff77c7a6a5493) (`list_open_tasks` row)
**Status:** Draft — awaiting Hugh's review. One boundary decision defaulted while he was away, flagged ⚖️ below.

## Naming (decided by Hugh, 2026-07-04)

`list_open_admin_tasks`, not the spec's `list_open_tasks`: these are **Stacks system-administration
tasks** (the TaskBuilder "what needs attention" queue — data hygiene, approvals, sync debt),
distinct from Notion **Tasks** (day-to-day work tasks for the whole company) which will become
their own source in P1a's Datazone work. The name carries the distinction so Recall and future
Sources rows can't confuse them.

## Why this slice

The engineering spec calls the TaskBuilder queue "the single most agent-ready dataset in the
whole company": 12 discovery classes, already owner-routed, cached with a 24h TTL (rebuilt on first read after expiry or a cache bust), with
display names, fix-it URLs, and humanized labels already computed by `StacksTask`
(`app/models/stacks_task.rb`). Feeds the Director-of-Delivery role and the Stewardship sweep.

## Approaches considered

1. **Thin presenter over `Stacks::TaskBuilder` (chosen).** One tool file; call
   `TaskBuilder.new.tasks` (or `#tasks_for(admin_user)` when filtering by owner — it filters
   descriptors *before* hydration, so the per-owner path never loads unrelated subjects); map
   each `StacksTask` through its existing accessors. No new queries beyond TaskBuilder's own
   bounded hydration (one SELECT per unique subject class + one for AdminUsers).
2. **Raw descriptor dump (no hydration).** Cheapest read, but descriptors are
   `{subject_type, subject_id, type, owner_ids}` — no display names, no URLs, no humanized
   labels. The agent would need N follow-up lookups. Rejected.
3. **Group-by-owner payload.** Pre-shapes for the per-PL digest, but the flat list + `owner`
   param serves both that and the whole-queue stewardship view. Rejected (YAGNI).

## Tool contract

- **File:** `app/services/mcp/list_open_admin_tasks_tool.rb`, registered in
  `Mcp::Server::TOOLS` (7th tool).
- **Params:**
  - `owner` (optional string) — AdminUser email, case-insensitive. Uses
    `TaskBuilder#tasks_for`. Unknown email → `Mcp::Responses.error` listing valid owner
    emails (mirrors the enterprise-param pattern; roster is internal-only data behind the
    same key).
- **Payload:**

```json
{
  "count": 42,
  "tasks": [
    {
      "type": "project_capsule_incomplete",
      "task": "Project capsule needs completion",
      "subject_class": "project_trackers",
      "subject": "Acme Website Rebuild",
      "url": "/admin/project_trackers/123",
      "url_external": false,
      "owners": ["someone@sanctuary.computer"]
    }
  ]
}
```

  Field sources: `type` / `humanized_type` (as `task`) / `subject_class_key` /
  `subject_display_name(redact_amounts: true)` / `subject_url` / `subject_url_external?` /
  `owners.map(&:email)`. Internal `url`s are relative paths on the Stacks admin host
  (`url_external: false`); Forecast/Notion links are absolute (`url_external: true`) — the
  tool description says so.
- **Ordering:** grouped stable — sorted by `subject_class`, then `type`, then `subject` —
  so diffs between runs read cleanly.
- **Annotations:** `read_only_hint: true, destructive_hint: false, idempotent_hint: true`
  (idempotent within the 24h cache window).
- **Envelope:** `Mcp::Responses.ok` / `.error`.

## ⚖️ Comp boundary (defaulted — Hugh to confirm)

The queue includes comp-adjacent task types (pay-cycle approvals, reimbursements, contributor
ledger adjustments). Chosen default, consistent with the late-fee "expose data, not policy /
wall out comp content" doctrine: **expose every task type — the nudge is the point — but
redact dollar amounts from MCP display strings.** Mechanism keeps the model the single source
of truth:

- `StacksTask#subject_display_name` gains a keyword: `subject_display_name(redact_amounts: false)`.
  Default `false` → existing behavior, zero change for the admin dashboard.
- With `redact_amounts: true`:
  - `RecurringLedgerAdjustment` renders `"<contributor email> on <enterprise> — <cadence>
    recurring adjustment"` (drops `$<amount>`).
  - `Reimbursement` renders `"Reimbursement #<id>"` (its free-text display_name can embed
    amounts).
  - All other branches unchanged (PayCycle shows enterprise + date range — no amounts;
    verified).
- The MCP tool always passes `redact_amounts: true`.

Alternatives Hugh can pick instead: expose verbatim (drop the keyword), or exclude the
comp-adjacent types entirely (filter by type list in the tool).

## Cache behavior (accepted)

The tool reads through TaskBuilder's 24h descriptor cache. A call landing on a cold cache
triggers the full discovery sweep — the same cost the `/admin/tasks` dashboard pays on first
load today, accepted as-is. No cache changes in this slice.

## Drive-by fix (from the engineering spec §7)

`DISCOVERY_CLASSES` lists 12 classes but `lib/stacks/task_builder.rb` only `require_relative`s
10 — `legacy_ledgers_pending_qbo_migration` and `auto_paused_recurring_ledger_adjustments`
exist on disk but aren't required at the top. Add the two `require_relative` lines (verify
first whether autoloading already covers them; add regardless for consistency with the
file's own convention).

## Error handling

- Unknown `owner` email → error payload listing valid admin emails.
- A `StacksTask` whose payload mapping raises (exotic subject state) → skipped with a
  `Rails.logger.warn`, never fails the whole list (same doctrine as `QboReceivables`).
- Empty queue → `{ count: 0, tasks: [] }`.

## Testing

- Unit (`test/services/mcp/admin_tasks_tool_test.rb`): stub `Stacks::TaskBuilder#tasks` /
  `#tasks_for` (mocha) to return constructed `StacksTask` objects over light fixture-backed
  subjects — asserts field mapping, ordering, owner filter + unknown-owner error, empty
  payload, and the skip-on-raise path.
- Unit (`test/models/stacks_task_test.rb` or existing home): `subject_display_name`
  redaction — `RecurringLedgerAdjustment` with amount renders without `$` under
  `redact_amounts: true`, unchanged without; `Reimbursement` generic form; default arg
  changes nothing.
- Integration: tool-name array in `test/integration/mcp_endpoint_test.rb` gains
  `list_open_admin_tasks`; one `tools/call` round-trip (empty-queue fixture state is fine —
  assert structure).

## Out of scope

Notion Tasks (separate Datazone source), cache tuning, any write path, per-owner digest
formatting (that's the Stacksbot job's concern), remaining P1a tools.
