# Optix: Automated Deactivation of Inactive Members — Design

Date: 2026-07-10
Status: approved (design validated against live API via read-only dry run;
member list OK'd by the Index Space team — see
`docs/optix-member-deactivation-dry-run.md`, revision 2)

## Purpose

Every day, automatically remove ("deactivate") Optix members of Index Space who
no longer hold any membership. Today, lapsed members accumulate forever as
active users in Optix (541 active users; only ~470 hold a current plan).

## Background: API facts validated during the dry run

These were confirmed against the live Optix GraphQL API and drive the design:

- `memberRemove(member_id: ID!, collect_payment: Boolean)` is the deactivation
  mutation. It is available under the **organization token**. It creates an
  invoice for any pending charges; `collect_payment: true` makes it due
  immediately. Removal is reversible (re-adding by email reactivates).
- `memberRemovePreview(member_id: ID!)` returns the `ChangeInvoice` that
  removal would generate (`{ total, subtotal, invoice_due_timestamp }`).
  **It 500s when given a wrong/unknown ID** — Optix returns
  "Internal server error", not a semantic error.
- **`member_id` ≠ `user_id`.** The only org-token path to the mapping is
  `invoices(...) { data { member { member_id user { user_id } } } }`.
  Members with no invoices on record cannot be mapped (7 of the current 68).
- `AccountPlanStatus` enum: `ACTIVE, CANCELED, ENDED, IN_TRIAL, UPCOMING,
  UNKNOWN`.
- `User.has_plans` is Optix's own membership flag, documented as "whether the
  user has active o[r] upcoming plans". It also covers **team-held plans**,
  which do not appear under `accountPlans.access_usage_user` for the member.
- A plan can be **canceled before it ever starts** (`canceled_timestamp` <
  `start_timestamp`); its `canceled_timestamp` is when the cancel was clicked,
  not when a membership ended.

## Selection rules (validated in dry run rev 2)

A user is deactivated when ALL of the following hold:

1. `is_active` is true (they are a current Optix user).
2. They have at least one account plan on record (leads/contacts untouched).
3. No plan with status `ACTIVE`, `IN_TRIAL`, or `UPCOMING`.
4. `has_plans` is false (Optix's own flag agrees; catches team-held plans).
5. Among plans that actually started (`start_timestamp <= now`), the latest
   effective end (`end_timestamp`, else `canceled_timestamp`) is more than
   **7 days** ago (grace period). If no plan ever started or no end data
   exists, skip (conservative).
6. `is_admin` is false.
7. A `member_id` mapping exists AND `memberRemovePreview` succeeds. Members
   who can't be mapped or previewed are **skipped and reported**, never
   removed blind.

Removal uses `collect_payment: true`. No per-run cap (team decision; the
backlog of 68 was reviewed and approved via the dry-run document).

## Architecture

Live-API-only: the service reads from the Optix API directly rather than the
synced `optix_*` tables, so it never acts on stale sync data. It runs inside
`stacks:daily_enterprise_tasks`.

### Component 1 — `Stacks::Optix` client additions (`lib/stacks/optix.rb`)

- `list_users` gains fields: `is_admin`, `is_lead`, `has_plans`.
  (`OptixSync#sync_users!` maps a slim subset keyed by column presence; adding
  fields to the query must not break the sync — sync mapping stays unchanged.)
- `user_id_to_member_id_map` — paginates `invoices` (include_paid, include_void,
  include_upcoming all true) and returns `{ user_id => member_id }`.
- `member_remove_preview(member_id)` — wraps `memberRemovePreview`, returns the
  `ChangeInvoice` hash.
- `member_remove!(member_id, collect_payment:)` — wraps the `memberRemove`
  mutation, returns the removed `Member` payload (`member_id`, `is_active`).
- `self.deactivate_inactive_members!(...)` — class-level convenience that
  delegates to the service object below (matches the call-site shape agreed
  with the team).

### Component 2 — service `Stacks::Optix::DeactivateInactiveMembers`
(new file `lib/stacks/optix/deactivate_inactive_members.rb`)

Interface:

```ruby
result = Stacks::Optix::DeactivateInactiveMembers.call(
  client: Stacks::Optix.new(optix_organization), # injectable for tests
  grace_days: 7,
  collect_payment: true,
)
result.deactivated # [{user_id:, member_id:, email:, name:, invoice_total:}, ...]
result.skipped     # [{user_id:, email:, reason:}, ...]  (unmappable / preview failed)
result.errors      # [{user_id:, email:, error:}, ...]   (removal raised)
```

Flow:

1. Fetch users (with `is_admin`/`has_plans`) and all account plans; apply
   selection rules 1–6.
2. Build the user→member map from invoices once per run.
3. For each candidate: map → preview → remove. Per-member failures are
   caught, recorded in `errors`, and never abort the run.
4. Log one summary line + one line per action
   (`[Stacks::Optix::DeactivateInactiveMembers] ...`); report per-member
   errors to Sentry.

Idempotency: removed members come back from Optix with `is_active: false`, so
they fail rule 1 on subsequent runs. Same-day reruns are safe.

### Component 3 — `Enterprise#daily_tasks` (`app/models/enterprise.rb`)

```ruby
def is_index?
  name == INDEX_SPACE_NAME
end

def daily_tasks
  Stacks::Optix.deactivate_inactive_members! if is_index?
end
```

`Stacks::Optix.deactivate_inactive_members!` uses `OptixOrganization.first` —
consistent with the documented single-tenant assumption in that model and in
`stacks.rake` (the existing sync does the same).

### Component 4 — rake hook (`lib/tasks/stacks.rake`, `daily_enterprise_tasks`)

Appended as a new step, following the task's existing per-item isolation
pattern:

```ruby
Enterprise.find_each do |e|
  e.daily_tasks
rescue => err
  Rails.logger.error("[stacks:daily_enterprise_tasks] Enterprise##{e.id} (#{e.name}) daily_tasks failed: ...")
  Sentry.capture_exception(err) if defined?(Sentry)
end
```

### Component 5 — targeted analytics fix

`OptixOrganization#inactive_members` and `#active_members` currently treat only
`ACTIVE`/`IN_TRIAL` as membership. Add `UPCOMING` to both status lists so churn
analytics stop counting scheduled-return members (e.g. B Milder) as churned.
(`has_plans` is not synced to the DB; the deeper team-held-plan blind spot is
out of scope for these DB-backed analytics and is documented in the method
comments.)

## Error handling

- Optix API errors during candidate selection abort the run (raise) — better
  no action than action on partial data. The rake wrapper isolates the failure
  to this step and reports via Sentry + logs; the SystemTask records the error.
- Per-member preview/removal errors: isolate, record, continue.
- Members who can't be mapped to a `member_id`: skip + report (never remove
  without a successful preview).

## Testing

Minitest, with the client injected as a stub/fake (no live API in tests).
Cases:

1. Removes a qualifying member (happy path) — preview then remove called with
   the mapped member_id and `collect_payment: true`.
2. Excludes: user with ACTIVE plan; IN_TRIAL; **UPCOMING**; `has_plans: true`
   despite no attributed plans (team-held); admin; lead with no plans;
   `is_active: false` users.
3. Grace period: plan ended 6 days ago → skipped; 8 days ago → removed;
   plan canceled before it started → its cancel date is NOT a membership end.
4. Unmappable member (absent from invoice map) → skipped with reason, not
   removed.
5. Preview raises ApiError → skipped with reason, not removed.
6. Removal raises for one member → recorded in errors, remaining members still
   processed.
7. `Enterprise#daily_tasks` — calls the service for Index, no-ops otherwise.
8. `OptixOrganization#active_members`/`#inactive_members` include UPCOMING as
   membership (DB-backed test).

## Out of scope

- Per-enterprise Optix credentials / multi-tenancy (documented future work).
- Notifying members that they've been removed (Optix handles its own emails,
  if configured).
- Syncing `has_plans`/`is_admin` into `optix_users` columns (live API is the
  source of truth for this automation).
- Webhooks / MCP.
