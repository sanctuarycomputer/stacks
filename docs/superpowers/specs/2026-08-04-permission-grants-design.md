# Permission Grants: Lead-in-Training Access — Design

**Date:** 2026-08-04
**Branch:** `worktree-per-project-stacks-permissions`

## Problem

Access to the financial/BI surface of ActiveAdmin (Invoice Trackers, Project Trackers,
Studios, explorers, etc.) is gated by a single check in
`AdminAuthorization#authorized?`:

```ruby
return true if (user.is_admin? || user.has_led_projects?)
```

`AdminUser#has_led_projects?` returns true only if the person has **ever** held an
`AccountLeadPeriod` or `ProjectLeadPeriod`. People training to become team leads or
account leads have never held one, so there is no way to give them that visibility
without making them full admins or fabricating a lead period (which would corrupt
compensation data — `AccountLeadPeriod#taking_percent` drives real payouts).

We need admins to be able to grant a person lead-equivalent access explicitly, and the
mechanism must be extensible to **scoped** grants: a person may be limited to seeing
only the Project Trackers and Invoice Trackers pertaining to specific projects, or be
given all projects.

## Approaches considered

1. **Add a `"lead_in_training"` value to the existing `admin_users.roles` text[]
   column.** Lowest friction (no migration), but stringly-typed, has no room for
   per-project scoping, no audit trail of who granted it, and the exact-array-equality
   `AdminUser.admin` scope (`where(roles: ["admin"])`) breaks the moment a user holds
   two roles.
2. **Reuse the lead-period tables with a "training" flag.** Rejected outright:
   `AccountLeadPeriod` drives compensation (`taking_percent`), and
   `has_led_projects?` semantics ("ever led") would become untrustworthy.
3. **A `permission_grants` table — one row per grant, with an optional polymorphic
   subject for scoping.** (Recommended.) This generalizes the existing
   `enterprise_admins` precedent (a join table read by a predicate with a super-admin
   bypass) into a reusable shape: `{admin_user, permission, subject?, granted_by,
   notes}`. A grant with no subject is global; a grant with a subject is scoped to
   that record. New permission kinds and new subject types are added by extending two
   allow-lists — no new tables.

## Design

### Data model

New table `permission_grants`:

| column | type | notes |
|---|---|---|
| `admin_user_id` | bigint, null: false, FK | who holds the permission |
| `permission` | string, null: false | initially only `"lead"` |
| `subject_type` / `subject_id` | string / bigint, nullable | polymorphic scope; both nil ⇒ global |
| `granted_by_id` | bigint, nullable, FK → admin_users | audit: who granted it |
| `notes` | text | why (e.g. "AL training, Q3 cohort") |
| timestamps | | |

Indexes: unique on `[admin_user_id, permission, subject_type, subject_id]`; plain on
`[subject_type, subject_id]`.

`PermissionGrant` model:

- `belongs_to :admin_user`, `belongs_to :granted_by, class_name: "AdminUser",
  optional: true`, `belongs_to :subject, polymorphic: true, optional: true`
- `PERMISSIONS = %w[lead]`, `SUBJECT_TYPES = %w[ProjectTracker]` — validated
  inclusion (subject_type only when present). Extending the system later = adding a
  string to one of these arrays plus the enforcement for it.
- Scopes: `global` (`subject_type: nil`), `for_permission(p)`.

### Predicates on `AdminUser`

- `has_many :permission_grants, dependent: :destroy` (+ `accepts_nested_attributes_for`)
- `can_act_as_lead?` → `has_led_projects? || permission_grants.global.for_permission("lead").any?`
- `lead_scoped_project_tracker_ids` → subject ids of `"lead"` grants scoped to
  `ProjectTracker` (memoized per request-ish usage is fine; keep it a simple query).

`has_led_projects?` keeps its exact current meaning ("has actually held a lead
period") — compensation and reporting code can keep relying on it. Authorization
call sites move to `can_act_as_lead?`:

- `admin_authorization.rb:35` → `return true if user.is_admin? || user.can_act_as_lead?`
- `app/views/admin/contributor_payouts/_show.html.erb:9` → `can_act_as_lead?`

So a **global** `"lead"` grant is exactly equivalent to having led before — same
blanket ActiveAdmin access a real lead gets today. A **scoped** grant deliberately
does *not* pass that line; it gets only the narrow rules below.

### Scoped access enforcement (`AdminAuthorization`)

For a user whose only standing is project-scoped `"lead"` grants, after the global
gate falls through:

1. **Class-level reads** (menus + index actions): allow `:read`/`:index` on
   `ProjectTracker` and `InvoiceTracker` classes when
   `lead_scoped_project_tracker_ids.any?`. Also allow `:read` on `InvoicePass`
   (invoice trackers are only reachable through their pass's show page).
2. **Record-level reads**: allow `:read` on a `ProjectTracker` instance iff its id is
   in the granted set; allow `:read` on an `InvoiceTracker` instance iff
   `invoice_tracker.project_trackers` intersects the granted set. Scoped access is
   **read-only** — no create/update/destroy, no member actions.
3. **Index scoping**: re-enable `scope_collection` in the adapter. For scoped-only
   users, filter `ProjectTracker` to granted ids and `InvoiceTracker` via a SQL
   filter that resolves granted projects → `ProjectTrackerForecastProject` →
   forecast_project ids → `EXISTS (SELECT 1 FROM jsonb_each(blueprint->'lines') l
   WHERE (l.value->>'forecast_project')::bigint IN (...))`. `InvoicePass` is not
   row-filtered (it's just a monthly container). Its show partial renders only
   error tables — trackers are listed on the nested InvoiceTracker index
   (`admin_invoice_pass_invoice_trackers_path`), which `scope_collection`
   filters, so no view changes are needed there.
4. Keep the existing `Dashboard` page allowance (already present for everyone).

### Admin UI (`app/admin/admin_users.rb`)

- Show page: a "Permission Grants" panel (visible to admins) listing each grant —
  permission, scope ("All projects" / project name), granted by, notes, granted at.
- Edit form (inside the existing `if current_admin_user.is_admin?` block):
  `f.has_many :permission_grants, allow_destroy: true` with permission select
  (`PermissionGrant::PERMISSIONS`), an optional `subject_id` select over
  `ProjectTracker` (labelled "Scope to project — leave blank for all projects", with
  hidden/derived `subject_type: "ProjectTracker"` when a project is chosen), and
  notes. `granted_by` is set automatically to `current_admin_user`, never from
  params.
- `permit_params` gains `permission_grants_attributes`; the controller strips
  `permission_grants_attributes` from params unless `current_admin_user.is_admin?`
  (the form gate alone is UI-only — leads pass the adapter and could otherwise POST
  grants to themselves).

### Hardening (in scope because this widens who passes the adapter)

`member_action :promote_admin_user`, `:demote_admin_user` in
`app/admin/admin_users.rb` currently have **no controller-side guard** — only the
`action_item` link is hidden. Any lead (and now any global grantee) could POST to
them directly and self-promote to admin. Add explicit
`current_admin_user.is_admin?` guards to both (impersonate already has one).

### Testing

New `test/models/admin_authorization_test.rb` (first authorization tests in the app)
plus `test/models/permission_grant_test.rb`:

- Global grant ⇒ `can_act_as_lead?` true, adapter authorizes ProjectTracker /
  InvoiceTracker reads and writes exactly as a period-holding lead.
- No grant, no periods ⇒ unchanged fallback behavior (contributor ledger rules).
- Scoped grant ⇒ read allowed on in-scope ProjectTracker/InvoiceTracker instances,
  denied on out-of-scope instances, denied for `:update`/`:destroy` everywhere;
  `scope_collection` filters both indexes correctly (jsonb filter verified against a
  real blueprint fixture).
- Promote/demote member actions reject non-admins (controller test).
- `PermissionGrant` validations: permission/subject_type inclusion, uniqueness.

### Error handling

- Deleting a `ProjectTracker` with grants pointing at it: `dependent: :destroy` via a
  `has_many :permission_grants, as: :subject` on `ProjectTracker` so grants can't
  dangle.
- A scoped user with zero surviving grants degrades gracefully to the existing
  non-lead fallback ladder (no crash, just no access).

## Defaulted decisions (flagged for PR review)

1. **Scoped grants are read-only** (index/show only). "Only see invoice trackers and
   project trackers" was read literally; write access within a project scope can be a
   follow-up permission (e.g. `"lead_write"`) without schema changes.
2. **Global grants are full lead-equivalents** — they pass the same line-35 gate, so
   they see everything a real lead sees (not just trackers). That is what "similar to
   the current permission" was taken to mean.
3. **Scoped grants also allow `:read` on `InvoicePass`** so scoped users can navigate
   to their invoice trackers. The final review found the InvoicePass index rendered
   company-wide monthly aggregates (value / outstanding / surplus / status counts) and
   the show page a company-wide missing-hours report; both are now gated behind
   `is_admin? || can_act_as_lead?`, leaving only month navigation for scoped users.
4. **Polymorphic subject** rather than a bare `project_tracker_id` FK, so future
   scopes (Studio, Enterprise) need no migration.
5. **No expiry column.** Training grants are revoked manually; add `expires_at` later
   if needed.
