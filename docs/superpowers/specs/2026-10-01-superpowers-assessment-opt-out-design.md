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
(`lib/stacks/task_builder/discoveries/human_operating_manuals.rb`) loops over
`AdminUser.active.not_ignored.distinct`, matches Notion manuals to people by
downcased email, and emits one of two task types — both **owned by the person
themselves**:

| Condition | Task type | Subject |
|---|---|---|
| No manual matches their email | `missing_human_operating_manual` | the `AdminUser` |
| A manual exists, but no manual of theirs has a PDF | `missing_superpowers_pdf` | the `Stacks::Notion::HumanOperatingManual` |

Every consumer hydrates the same cached descriptor list from
`Stacks::TaskBuilder`, so a task suppressed at the discovery disappears
everywhere at once:

- the `/admin/tasks` dashboard — the system-wide list admins work from to chase
  people (`app/admin/tasks.rb`)
- the person's own `/admin/admin_users/:id` page, via `AdminUser#pending_tasks`
  (`app/views/admin/admin_users/_show.html.erb:81`)
- the "View N Tasks" pill on the contributor page
  (`app/views/admin/contributors/_show.html.erb:7`)
- the pending-tasks pill on payable QBO bills
  (`app/admin/money.rb:48`, via `TaskBuilder#task_count_for`)
- the `list_open_admin_tasks` MCP tool
  (`app/services/mcp/list_open_admin_tasks_tool.rb`)

This is why the whole feature is two early-outs in one discovery and nothing
else. There is no second place that re-derives these tasks.

## Scope decisions

- **Two independent flags**, not one. Needing a manual and needing a Pigment.is
  assessment are separate obligations and are exempted separately.
- **Default is required.** Both columns are `null: false, default: true`, so
  every existing row and every future row is on the hook until someone un-ticks
  a box. No backfill, no grandfathering.
- **Stored on `admin_users`**, not `contributors` and not Notion. See below.
- **Admin-only, no audit trail, no visible exemption marker.** Deliberate
  scope cuts — see Non-goals.

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

`AdminUser` already includes `BustsTaskCache`, so saving the form clears the
task cache immediately.

**Known limitation, pre-existing:** production uses a `memory_store` cache, so
the bust only reaches the web process that handled the save. Other processes
can keep serving the stale task list until the `CACHE_TTL` (24h) expires or the
next `stacks:daily_tasks` run rebuilds it. This is existing behaviour for every
task-affecting edit, not something this change introduces, but it does mean
"I un-ticked the box and they still see the task" is expected for up to 24h.

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

`null: false, default: true` means existing rows are backfilled to `true` by
Postgres as part of `ADD COLUMN`, so no separate backfill statement is needed
and there is no window in which anyone reads as exempt.

`db/schema.rb` is hand-curated in this repo — add both columns to the
`admin_users` block and bump the `version:` to the new migration's timestamp by
hand rather than relying on a dump.

Migrations in this repo are run manually after deploy (there is no release
phase), so the code must tolerate the columns being absent for the window
between merge and migration. Both call sites are plain attribute reads on
`AdminUser`; if the column is missing the discovery raises rather than silently
mis-behaving, which is the correct failure mode for a nag job. No defensive
`column_exists?` guard — it would hide a real deploy error.

#### Naming

`requires_human_operating_manual` and `requires_superpowers_assessment`.

Positive polarity (`requires_*`, default `true`) rather than the `ignore`-style
negative (`skip_*`, default `false`) because the question being asked at the
call site is "is this person required to have one?", and a `requires_x?`
predicate reads correctly in that position. `assessment` rather than `pdf`
names the obligation the person actually has (matching
`HumanOperatingManual::ASSESSMENT_GUIDE_URL`) instead of the artifact that
proves it.

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

### 3. UI

`app/admin/admin_users.rb`:

- Add `:requires_human_operating_manual` and `:requires_superpowers_assessment`
  to `permit_params` (top of the file, alongside `:ignore`).
- Add two checkbox inputs to the `f.inputs(class: "admin_inputs")` block at
  `:184`, immediately after `f.input :ignore`. That block is already wrapped in
  `if current_admin_user.is_admin?` (`:183`), so the inputs are admin-only with
  no new gating, and non-admins cannot submit them because the fields are never
  rendered for them.

```ruby
f.input :requires_human_operating_manual,
  label: "Requires a Human Operating Manual",
  hint: "Leave checked for everyone normally. Uncheck to exempt this person — they won't be asked to create a Human Operating Manual, and the task won't appear for them or for admins following up."
f.input :requires_superpowers_assessment,
  label: "Requires a Pigment.is Superpowers assessment",
  hint: "Leave checked for everyone normally. Uncheck to exempt this person from attaching a Pigment.is Superpowers PDF to their Human Operating Manual."
```

Formtastic renders `:boolean` columns as checkboxes automatically, so no `as:`
is needed.

Nothing else changes: no exemption pill on the show page, no index scope, no
change to the task list partials or the MCP tool.

## Testing

Extend `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb`.
Its existing `build_admin!` helper creates an active admin; new rows pick up the
`true` defaults, so **all 15 existing tests must pass unchanged** — that is
itself the regression check that the default preserves today's behaviour.

New cases, one per interesting cell of the table above:

1. `requires_superpowers_assessment: false` + a matching manual with no PDF →
   no tasks at all.
2. `requires_superpowers_assessment: false` + no matching manual → still gets
   `missing_human_operating_manual` (the flags don't bleed into each other).
3. `requires_human_operating_manual: false` + no matching manual → no tasks.
4. `requires_human_operating_manual: false`, `requires_superpowers_assessment:
   true` + no matching manual → no tasks (pins row 3 of the table, the
   non-obvious cell).
5. `requires_human_operating_manual: false` + a matching manual with no PDF →
   still gets `missing_superpowers_pdf` (manual exemption doesn't imply
   assessment exemption).
6. Both `false` → no tasks.
7. A freshly created `AdminUser` has both flags `true` (guards the migration
   defaults).

Run the full suite. Per prior art in this repo:

- `db:environment:set` must be set for the test DB.
- Skip `EtlRakeTest`'s `sync_meet` test locally — it makes a live Google call
  and can hang the run for ~73 minutes.
- `AdminUserTest`'s salary-window test fails between 20:00 and 24:00 ET for
  reasons unrelated to this change; if it fails, confirm the clock before
  investigating.

## Non-goals

- **No visible exemption marker.** No pill on the AdminUser show page, no
  `/admin/admin_users` scope listing the exempt. The checkbox state on the edit
  form is the single source of truth. Accepted cost: an admin wondering why
  someone isn't being nagged has to open the edit form.
- **No audit trail.** No `exempted_by` / `exempted_at`, no exemption notes.
  This is a nag opt-out, not a financial control; the project-capsule sign-off
  pattern would be overkill.
- **No self-service.** The person being exempted cannot exempt themselves — the
  inputs live in the admin-only block.
- **No bulk editing.** Exemptions are expected to be rare and set one at a
  time.
- **No change to `ignore`.** `ignore: true` continues to remove a person from
  these checks (and everything else) as a side effect; the new flags are the
  targeted instrument.
- **Nothing touches the Notion side.** No new properties in the Human
  Operating Manuals database, no sync changes.
