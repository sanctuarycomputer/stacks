# Payables Page: Pending-Tasks Pill — Design

**Date:** 2026-08-17
**Status:** Approved

## Goal

On `/admin/money/payable_qbo_bills`, each payables group (one per
contributor) should show whether that person has pending Stacks tasks. The
indicator renders in the group's `titlebar_right`, to the LEFT of the
amount/ledger-item pill (which sits left of the "Open in QBO ↗" link).

## Behavior

- Contributor → person mapping: `contributor.forecast_person&.admin_user`
  (the established linkage).
- When the mapped AdminUser has ≥1 pending task: render an ORANGE pill
  (`class="pill at_risk"`) reading `N pending task` / `N pending tasks`,
  wrapped in a link to `admin_admin_user_path(admin_user)` (that page lists
  the user's tasks).
- When the count is 0, or the contributor has no linked AdminUser: render
  nothing. (Chosen over a green zero-state.)

## Architecture

### 1. `Stacks::TaskBuilder#task_count_for(admin_user)`

New public method in `lib/stacks/task_builder.rb`, alongside `task_count`:
counts cached descriptors whose `owner_ids` include the user — NO subject
hydration (counting must not load subject records). Returns 0 for nil /
unpersisted users (mirror `tasks_for`'s `return [] unless admin_user&.id`
guard).

### 2. Controller (`app/admin/money.rb`, `payable_qbo_bills` page_action)

After `@rows` is computed: build
`@pending_task_counts_by_contributor` — for each distinct contributor in
`@rows`, resolve the admin user; where one exists, store
`[contributor, { admin_user: au, count: builder.task_count_for(au) }]`.
ONE `Stacks::TaskBuilder` instance for the whole action (its memoized
descriptor cache makes per-user counts cheap). Contributors with no linked
AdminUser are absent from the hash.

### 3. View (`app/views/admin/money/payable_qbo_bills.html.erb`)

In each group's `titlebar_right`, immediately BEFORE the existing
`<span class="pill complete">` amount pill: if the hash has an entry with
`count > 0`, render the linked orange pill. Pluralize "task" properly.

## Error handling

- TaskBuilder cache rebuild failures already degrade per-discovery inside
  `build_tasks`; `task_count_for` only reads descriptors, so the page never
  breaks — worst case the count is stale (24h TTL) or 0.

## Testing

Extend `test/lib/stacks/task_builder/` with a `task_count_for` unit test
(new file `test/lib/stacks/task_builder/task_count_for_test.rb`):

- Stub the builder instance's `build_tasks` (mocha) with real `StacksTask`
  objects owned by two different admins; assert `task_count_for` counts only
  the given admin's tasks and equals `tasks_for(user).length`.
- Returns 0 for nil and for an admin with no tasks.
- Instance memoization means the stubbed build happens once per instance
  even under the test env's cache store.

No controller/view test: the repo has no admin-page test precedent (only
`test/controllers/api`), and the view logic is a guard + literal, consistent
with this page's other header pills.

## Out of scope

- No tooltip/task-list preview on the pill.
- No zero-state or unmapped-contributor indicator.
- No changes to the tasks dashboard or TaskBuilder caching.
