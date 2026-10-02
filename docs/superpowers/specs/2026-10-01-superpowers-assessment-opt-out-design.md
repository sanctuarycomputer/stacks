# Human Operating Manual & Superpowers assessment opt-out

**Date:** 2026-10-01
**Status:** Approved, ready for planning

## Problem

Every active, non-ignored admin is nagged to have a Human Operating Manual page
in Notion with a Pigment.is Superpowers assessment PDF attached. Some people
legitimately shouldn't be on the hook for one or both — but there is no way to
say so. The nag is unconditional, so the only way to silence it today is to
mark the account `ignore: true`, which removes the person from far more than
this one check.

We want to selectively exempt individuals. The requirement stays the default:
everyone is required unless someone deliberately says otherwise.

### How the nag works today

`Stacks::TaskBuilder::Discoveries::HumanOperatingManuals`
(`lib/stacks/task_builder/discoveries/human_operating_manuals.rb:20-31`) loops
over `AdminUser.active.not_ignored.distinct`, matches Notion manuals to people
by downcased email, and emits one of two task types — both **owned by the
person themselves**:

| Condition | Task type | Subject |
|---|---|---|
| No manual matches their email | `missing_human_operating_manual` | the `AdminUser` |
| A manual exists, but no manual of theirs has a PDF | `missing_superpowers_pdf` | the `Stacks::Notion::HumanOperatingManual` |

This discovery is the **only** producer of either task type — verified by
grepping the repo for `superpowers`, `HumanOperatingManual`,
`human_operating_manual`, `missing_superpowers_pdf` and
`missing_human_operating_manual`; outside `docs/` the only hits are
`human_operating_manuals.rb:23,27`. Every consumer hydrates the same cached
descriptor list from `Stacks::TaskBuilder`, so a task suppressed at the
discovery disappears from all eight surfaces at once:

1. `config/initializers/active_admin.rb:406` — `build_pending_tasks_nag if
   current_admin_user.pending_tasks.any?`, the nag banner on **every** admin
   page. The most prominent surface, and the "it won't bug them" one.
2. `app/admin/tasks.rb` — the `/admin/tasks` dashboard, the system-wide list
   admins work from to chase people.
3. `app/views/admin/admin_users/_show.html.erb:81` — the person's own
   `/admin/admin_users/:id` page, via `AdminUser#pending_tasks`.
4. `app/views/admin/contributors/_show.html.erb:7` — the "View N Tasks" pill.
5. `app/admin/money.rb:52` — the pending-tasks pill on payable QBO bills, via
   `TaskBuilder#task_count_for`.
6. `app/views/admin/studios/_show.html.erb:30` — the OKR-page open-task warning
   banner, via `TaskBuilder#task_count`.
7. `lib/stacks/notifications.rb:111` — the daily `SystemNotification` task
   count.
8. `app/services/mcp/list_open_admin_tasks_tool.rb` — the
   `list_open_admin_tasks` MCP tool.

This is why the whole behavioural change is two early-outs in one discovery.
There is no second place that re-derives these tasks.

## Scope decisions

- **Two independent flags**, not one. Needing a manual and needing a Pigment.is
  assessment are separate obligations and are exempted separately.
- **Default is required.** Both columns are `null: false, default: true`, so
  every existing row and every future row is on the hook until someone un-ticks
  a box. No backfill, no grandfathering.
- **Stored on `admin_users`**, not `contributors` and not Notion.
- **Admin-only, enforced server-side** — hiding the inputs is not sufficient in
  this app. See §3.
- **No audit trail, no visible exemption marker.** Deliberate scope cuts — see
  Non-goals.

### Why `admin_users`

`AdminUser` is the identity this discovery iterates over, the subject of one
task type and the owner of both. `Contributor` is the payments/ledger identity
(keyed off `ForecastPerson`, holder of QBO vendors) and has no relationship to
Human Operating Manuals.

Storing the flags as checkbox properties on the Notion manual page was
considered and rejected:

1. It cannot express "exempt from needing a manual at all" — there is no page to
   hold the flag precisely when the flag is needed.
2. Changes would only land after the next daily `stacks:sync_notion` run.

Real boolean columns rather than the existing `info` jsonb also sidesteps the
Storext trap where a `Boolean` stored as `""` reads as truthy.

### Cache staleness (pre-existing, but it shapes expectations)

`AdminUser` already includes `BustsTaskCache` (`app/models/admin_user.rb:2`), so
saving the form calls `Stacks::TaskBuilder.clear_cache!`. But production uses
`:memory_store` (`config/environments/production.rb:57`), so the bust only
reaches the web process that handled the save. Other processes keep serving the
stale descriptor list until `CACHE_TTL` (24h, `lib/stacks/task_builder.rb:44`)
expires or `stacks:daily_tasks` calls `refresh!` (`lib/tasks/stacks.rake:628`).

This is existing behaviour for every task-affecting edit, not something this
change introduces, but it means **"I un-ticked the box and they still see the
task" is expected for up to 24h.** Worth saying out loud to whoever uses the
feature.

## Design

### 1. Data model

One migration on `admin_users`:

```ruby
class AddHumanOperatingManualRequirementFlagsToAdminUsers < ActiveRecord::Migration[6.1]
  def change
    add_column :admin_users, :requires_human_operating_manual, :boolean, null: false, default: true
    add_column :admin_users, :requires_superpowers_assessment, :boolean, null: false, default: true
  end
end
```

Rails is `6.1.7.10` (`Gemfile.lock:370`), and `[6.1]` matches every recent
migration in `db/migrate/`. `add_column ... :boolean, null: false, default:
true` emits `ADD COLUMN ... boolean DEFAULT TRUE NOT NULL`, which Postgres
applies to existing rows as part of the same statement — no separate backfill,
and no window in which anyone reads as exempt. There is no `strong_migrations`
gem to object to the `NOT NULL`.

Note the deliberate divergence from the neighbouring `ignore` column, which is
`default: false` with **no** `null: false` (`db/schema.rb:87`). Do not
pattern-match on `ignore` here: these columns are `null: false` so that
`requires_x?` can never be `nil`, which would read as "exempt" at the call site.

#### schema.rb

`db/schema.rb` is hand-curated in this repo — there is direct evidence at
`db/schema.rb:19-23` (pgvector columns "intentionally omitted here so
`db:schema:load` works on a Postgres without pgvector… Keep them out of this
dumped schema") plus the idempotent re-establishment blocks in
`test/test_helper.rb:8-50`. So edit it by hand:

- Add both columns to the `admin_users` block **after** `t.boolean "ignore",
  default: false` (`db/schema.rb:87`) and **before** the two `t.index` lines at
  `:88-89`. Rails dumps columns in physical order, so this placement is what a
  real dump would produce; anywhere else creates a noisy diff next time someone
  dumps.
- Bump `version:` (`db/schema.rb:13`) to the new migration's timestamp.

Forgetting the schema.rb edit fails loudly, not subtly: `maintain_test_schema`
is not disabled in `config/environments/test.rb`, so the first test run after
this migration purges and reloads the test DB from `db/schema.rb`. That reload
is also what triggers the `ActiveRecord::EnvironmentMismatchError` that
`db:environment:set` fixes.

#### Naming

`requires_human_operating_manual` and `requires_superpowers_assessment`.

Positive polarity (`requires_*`, default `true`) rather than the `ignore`-style
negative (`skip_*`, default `false`) because the question at the call site is
"is this person required to have one?", and a `requires_x?` predicate reads
correctly in that position. `assessment` rather than `pdf` names the obligation
the person actually has (matching
`HumanOperatingManual::ASSESSMENT_GUIDE_URL`) instead of the artifact that
proves it.

#### Deploy ordering — migrate BEFORE deploying

Migrations in this repo are manual: the `Procfile` contains only `web:` and
`app.json` has no release script, so the default sequence is deploy-then-migrate.
**Do not use that sequence here.** Run the migration *first*, then deploy.

Both columns are purely additive with a `default: true`, and no code on `main`
reads them, so migrating ahead of the deploy is safe and gives a zero-length
exposure window. Deploying first does not, and the damage does not end when the
migration finishes:

- **The admin edit form 500s, and keeps 500ing after the migration.**
  Production runs `cache_classes = true` / `eager_load = true`
  (`config/environments/production.rb:5,11`), and ActiveRecord memoizes a
  model's column set per process behind a `schema_loaded?` guard. `admin_users`
  is queried on essentially every request (Devise), so every web dyno caches
  `AdminUser`'s columns *without* the new ones as soon as it boots.
  `heroku run rails db:migrate` does not restart web dynos, so Formtastic keeps
  raising `undefined method 'requires_human_operating_manual'` on
  `/admin/admin_users/:id/edit` for **every** admin until the dynos restart.
  There is no `db/schema_cache.yml` to make this deterministic either way.
- **The nag job degrades silently, and `stacks:daily_tasks` cannot fix it.**
  `TaskBuilder#build_tasks` wraps every discovery in a blanket rescue
  (`lib/stacks/task_builder.rb:192-201`) that logs, reports to Sentry and
  substitutes `[]`, so a missing column makes HOM tasks vanish rather than
  raise — and that HOM-less list is cached. On a stale dyno this repeats on
  every rebuild, so it is permanent rather than 24h-bounded. `stacks:daily_tasks`
  calls `refresh!` (`lib/tasks/stacks.rake:628`) in a *separate* dyno and writes
  to that dyno's `:memory_store`, so it can never restore the web dynos' nags.

If the deploy has already gone out ahead of the migration, the recovery is
`heroku restart` after migrating — not `stacks:daily_tasks`. A restart fixes the
per-process column cache and clears the per-process task cache in one step.

Decision: **no defensive `column_exists?` guard.** With migrate-first ordering
the window is zero, so a guard would be permanent complexity for no benefit, and
the repo has no precedent for one.

This section has been wrong twice, which is worth recording. An early draft
claimed the discovery would raise on a missing column; it does not, because of
the blanket rescue. The correction then claimed the window was "a few minutes of
deploy skew" fixable with `stacks:daily_tasks`; that was also wrong, because the
column cache is per-process and the task cache is per-dyno. Both errors pointed
the same way — treating a process-local cache as if it were shared.

### 2. Discovery changes

`lib/stacks/task_builder/discoveries/human_operating_manuals.rb` — two
early-outs inside the existing per-user branch:

```ruby
AdminUser.active.not_ignored.distinct.flat_map do |user|
  manuals = manuals_by_email[user.email.downcase]
  if manuals.empty?
    # Exempt from the manual entirely: nothing to nag about, and there is no
    # manual on which a Superpowers assessment could live.
    next [] unless user.requires_human_operating_manual?
    [task(subject: user, type: :missing_human_operating_manual, owners: [user])]
  elsif manuals.none?(&:superpowers_pdf?)
    next [] unless user.requires_superpowers_assessment?
    # Deterministic subject across cache rebuilds: lowest NotionPage id.
    manual = manuals.min_by { |m| m.notion_page.id.to_i }
    [task(subject: manual, type: :missing_superpowers_pdf, owners: [user])]
  else
    []
  end
end
```

The flags are read as plain attributes on the already-loaded `AdminUser`, so
this adds no queries and no N+1.

`next []` — **not** a bare `next`, which would inject `nil` into the returned
array and break `assert_empty` assertions.

#### Flag interaction

The two flags are independent, which yields four behaviours. The table is the
specification — the implementation must match it exactly:

| `requires_human_operating_manual` | `requires_superpowers_assessment` | No manual exists | Manual exists, no PDF | Manual exists with PDF |
|---|---|---|---|---|
| true | true | `missing_human_operating_manual` | `missing_superpowers_pdf` | no task |
| true | false | `missing_human_operating_manual` | no task | no task |
| false | true | **no task** | `missing_superpowers_pdf` | no task |
| false | false | no task | no task | no task |

The one non-obvious cell is row 3 / "no manual exists": someone exempt from the
manual but still required to do the assessment gets **no** task, because the
assessment is a file property on a manual page and there is nowhere to attach
it. The existing `manuals.empty?` branch already swallows both cases, so this
falls out of the structure rather than needing a special case — but it is
intentional, and a test pins it so a later refactor can't quietly change it.

### 3. UI and authorization

#### The trap

Hiding the inputs is **not** sufficient in this app. `AdminAuthorization`
returns `true` for every action on every not-explicitly-carved-out subject when
`user.is_admin? || user.can_act_as_lead?` (`app/models/admin_authorization.rb:84`),
and `can_act_as_lead?` is `has_led_projects? || <global "lead" grant>`
(`app/models/admin_user.rb:566-568`) — i.e. **anyone who has ever led a
project**. That check is not record-scoped, and `actions :index, :show, :edit,
:update` (`app/admin/admin_users.rb:43`) means such a user can `PUT
/admin/admin_users/:id` for *any* person. `permit_params` is global, not
admin-conditional.

The repo already knows this. There is a comment and a controller override
documenting exactly this trap for permission grants
(`app/admin/admin_users.rb:117-133`):

> Permission grants are admin-managed only. The form hides them from
> non-admins, but leads pass the authorization adapter for AdminUser
> updates, so strip the params server-side too.

and a passing test showing a non-admin lead successfully PUTting a permitted
attribute to a record (`test/integration/admin_permission_grants_test.rb:56-68`).

So adding the two flags to `permit_params` alone would let any past project lead
silently exempt themselves — or anyone else — from the nag, with no audit trail
(which this spec also declines to add). That is the thing to prevent.

#### Changes to `app/admin/admin_users.rb`

1. Add `:requires_human_operating_manual` and `:requires_superpowers_assessment`
   to `permit_params` (`:2-5`, alongside `:ignore`).

2. **Extend the existing `def update` override** (`:121-133`) to strip both keys
   for non-admins, following the shape already there for
   `permission_grants_attributes`:

```ruby
HUMAN_OPERATING_MANUAL_FLAGS = %i[
  requires_human_operating_manual
  requires_superpowers_assessment
].freeze

def update
  # ... existing permission_grants_attributes handling ...

  # Nag exemptions are admin-managed only. The form hides them from
  # non-admins, but leads pass the authorization adapter for AdminUser
  # updates, so strip them server-side too — otherwise anyone who has ever
  # led a project could exempt themselves from their own nag tasks.
  unless current_admin_user.is_admin?
    HUMAN_OPERATING_MANUAL_FLAGS.each { |f| params[:admin_user]&.delete(f) }
  end

  super
end
```

3. Add two checkbox inputs to the `f.inputs(class: "admin_inputs")` block
   (`:184`), immediately after `f.input :ignore` (`:185`). That block is already
   wrapped in `if current_admin_user.is_admin?` (`:183`), so the inputs are
   hidden from non-admins — the strip in (2) is what actually enforces it.

```ruby
f.input :requires_human_operating_manual,
  label: "Requires a Human Operating Manual",
  hint: "Leave checked for everyone normally. Uncheck to exempt this person — they won't be asked to create a Human Operating Manual, and the task won't appear for them or for admins following up. If they have no manual at all, this also silences the Superpowers assessment nag, since there would be no page to attach the PDF to. Can take up to 24h to clear everywhere."
f.input :requires_superpowers_assessment,
  label: "Requires a Pigment.is Superpowers assessment",
  hint: "Leave checked for everyone normally. Uncheck to exempt this person from attaching a Pigment.is Superpowers PDF to their Human Operating Manual. Can take up to 24h to clear everywhere."
```

Formtastic renders `:boolean` columns as checkboxes automatically, so no `as:`
is needed.

Nothing else changes: no exemption pill on the show page, no index scope, no
change to the task list partials or the MCP tool.

## Testing

### Discovery — `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb`

All **15 existing tests must pass unchanged** — that is itself the regression
check that the `true` defaults preserve today's behaviour.

Set the flags with `admin.update!(...)` after `build_admin!`, matching the
existing idiom at `:105` (`admin.update!(ignore: true)`). Do **not** add
keyword arguments to `build_admin!` (`test/test_helper.rb:109`) — it has a fixed
four-keyword signature and is shared by many tests. `update!` is safe here:
`bust_task_cache` is rescued (`app/models/concerns/busts_task_cache.rb:26-29`)
and the test cache is `:null_store` (`config/environments/test.rb:26`).

New cases, one per interesting cell of the table:

1. `requires_superpowers_assessment: false` + matching manual with no PDF → no
   tasks at all.
2. `requires_superpowers_assessment: false` + no matching manual → still gets
   `missing_human_operating_manual` (the flags don't bleed into each other).
3. `requires_human_operating_manual: false` (assessment flag left at its `true`
   default) + no matching manual → no tasks. Pins row 3 of the table, the
   non-obvious cell.
4. `requires_human_operating_manual: false` + matching manual with no PDF →
   still gets `missing_superpowers_pdf` (manual exemption doesn't imply
   assessment exemption).
5. Both flags `false` + no matching manual → no tasks.
6. Both flags `false` + matching manual with no PDF → no tasks.

### Defaults — `test/models/admin_user_test.rb`

7. A freshly created `AdminUser` has both flags `true`. This is a model-level
   assertion, so it belongs here rather than in the discovery test.

### Authorization — `test/integration/admin_permission_grants_test.rb`

8. A non-admin lead PUTting `requires_superpowers_assessment: false` (and the
   manual flag) to their own record does **not** change either flag. Add
   alongside the existing "a non-admin (even a global grantee) cannot create
   grants" test (`:56`), which already establishes the `sign_in @trainee` +
   `put admin_admin_user_path` harness.
9. An admin PUTting the same params **does** change them — otherwise test 8
   would pass even if the feature were never wired up.

### Running

- `db:environment:set` must be set for the test DB (see the schema.rb note
  above for why this bites on the first run after the migration).
- Skip `test/lib/tasks/etl_rake_test.rb` locally — its `sync_meet` test makes a
  live Google call and can hang the run for ~73 minutes.
- `AdminUserTest`'s salary-window test fails between 20:00 and 24:00 ET for
  reasons unrelated to this change; check the clock before investigating.
- Baseline on this branch before any changes: **1765 runs, 5650 assertions, 0
  failures, 0 errors, 2 skips** (excluding `etl_rake_test.rb`).

## Non-goals

- **No visible exemption marker.** No pill on the AdminUser show page, no
  `/admin/admin_users` scope listing the exempt. The checkbox state on the edit
  form is the single source of truth. Accepted cost: an admin wondering why
  someone isn't being nagged has to open the edit form.
- **No audit trail.** No `exempted_by` / `exempted_at`, no exemption notes.
  This is a nag opt-out, not a financial control; the project-capsule sign-off
  pattern would be overkill. (Note this is *why* the server-side strip in §3
  matters: without an audit trail there would be no way to detect a
  self-exemption after the fact.)
- **No `column_exists?` guard** for the merge→migrate window. See §1.
- **No bulk editing.** Exemptions are expected to be rare and set one at a
  time.
- **No change to `ignore`.** `ignore: true` continues to remove a person from
  these checks (and everything else) as a side effect; the new flags are the
  targeted instrument.
- **Nothing touches the Notion side.** No new properties in the Human
  Operating Manuals database, no sync changes.
- **No fix for the cross-process cache staleness.** Pre-existing and out of
  scope; documented above so expectations are right.
