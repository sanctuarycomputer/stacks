# HOM & Superpowers Assessment Opt-Out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin selectively exempt an individual from the Human Operating Manual nag task and/or the Pigment.is Superpowers assessment nag task, with both requirements on by default.

**Architecture:** Two `null: false, default: true` boolean columns on `admin_users`, read by two early-outs in `Stacks::TaskBuilder::Discoveries::HumanOperatingManuals` — the single producer of both task types, so suppressing there removes the task from all eight consuming surfaces at once. The ActiveAdmin edit form gets two admin-only checkboxes, plus a server-side param strip, because this app's authorization adapter lets anyone who has ever led a project `PUT` any `AdminUser`.

**Tech Stack:** Rails 6.1.7.10, Ruby 3.1.7, Postgres, ActiveAdmin + Formtastic, Minitest + Mocha.

**Spec:** `docs/superpowers/specs/2026-10-01-superpowers-assessment-opt-out-design.md`

## Global Constraints

- Work in the worktree `/Users/hhff/Documents/Code/stacks/.worktrees/superpowers-opt-out` on branch `feat/superpowers-assessment-opt-out`. Verify with `git branch --show-current` before any commit. Never `cd` to `/Users/hhff/Documents/Code/stacks` (the main checkout) or any other `.worktrees/` subdirectory.
- Column names exactly: `requires_human_operating_manual`, `requires_superpowers_assessment`. Both `:boolean, null: false, default: true`.
- Run all tests with `RAILS_ENV=test bundle exec rails test …` from the worktree root.
- **Never run `bundle exec rails db:migrate` against the development database.** `config.active_record.dump_schema_after_migration = false` is set only in `config/environments/production.rb:90`, so a development migrate auto-dumps `db/schema.rb` and clobbers its deliberately hand-curated omissions (the pgvector extension, `embeddings.embedding`, its HNSW index, the `chunks.content_tsv` generated column — see `db/schema.rb:19-23`). Edit `db/schema.rb` by hand instead; the test DB reloads from it automatically.
- If a test run fails with `ActiveRecord::PendingMigrationError`, scroll up in the output: Rails shells out to `bin/rails db:test:prepare` and ignores its exit status, so the real cause (commonly `ActiveRecord::EnvironmentMismatchError`) is printed by that subprocess earlier in the run. For the environment mismatch, run `RAILS_ENV=test bundle exec rails db:environment:set` once and retry.
- Never run `test/lib/tasks/etl_rake_test.rb` — its `sync_meet` test makes a live Google API call and can hang for ~73 minutes.
- `AdminUserTest`'s salary-window test fails between 20:00 and 24:00 ET for reasons unrelated to this work. If it fails, check the clock before investigating.
- Baseline before any change (excluding `etl_rake_test.rb`): **1765 runs, 5650 assertions, 0 failures, 0 errors, 2 skips.**
- End every commit message with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `db/migrate/20261001120000_add_human_operating_manual_requirement_flags_to_admin_users.rb` | Create | Adds the two boolean columns |
| `db/schema.rb` | Modify (`:87-89`, `:13`) | Hand-curated schema: add both columns, bump version |
| `test/models/admin_user_test.rb` | Modify (append) | Pins the `true` defaults |
| `lib/stacks/task_builder/discoveries/human_operating_manuals.rb` | Modify (`:20-31`) | Two early-outs that suppress the tasks |
| `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb` | Modify (append) | Pins all four flag combinations |
| `app/admin/admin_users.rb` | Modify (`:2-5`, `:121-133`, `:185`) | permit_params, server-side strip, two checkboxes |
| `test/integration/admin_permission_grants_test.rb` | Modify (append) | Pins that non-admin leads cannot set the flags, that admins can, and that the form renders |

---

### Task 1: Columns and defaults

**Files:**
- Create: `db/migrate/20261001120000_add_human_operating_manual_requirement_flags_to_admin_users.rb`
- Modify: `db/schema.rb:13`, `db/schema.rb:87-89`
- Test: `test/models/admin_user_test.rb` (append a new test before the final `end`)

**Interfaces:**
- Consumes: nothing.
- Produces: `AdminUser#requires_human_operating_manual` / `#requires_human_operating_manual?` and `AdminUser#requires_superpowers_assessment` / `#requires_superpowers_assessment?` — both boolean, both `true` for any newly created or pre-existing row. Tasks 2 and 3 depend on these.

- [ ] **Step 1: Write the failing test**

Append to `test/models/admin_user_test.rb`, immediately before the file's final `end`:

```ruby
  test "a new AdminUser is required to have a Human Operating Manual and a Superpowers assessment by default" do
    admin_user = AdminUser.create!({
      email: "defaults@sanctuary.computer",
      password: "passw0rd",
    })

    assert admin_user.requires_human_operating_manual?,
      "expected requires_human_operating_manual to default to true"
    assert admin_user.requires_superpowers_assessment?,
      "expected requires_superpowers_assessment to default to true"
  end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
RAILS_ENV=test bundle exec rails test test/models/admin_user_test.rb -n "/required_to_have_a_Human_Operating_Manual/"
```

Expected: `1 runs, 0 assertions, 0 failures, 1 errors` — a Minitest **error** (not a failure): `NoMethodError: undefined method 'requires_human_operating_manual?' for #<AdminUser…>`.

Note the underscores: Minitest derives method names from `test "…"` strings by replacing spaces, so a filter containing literal spaces matches nothing. Use this exact filter, and do **not** filter on `/default/` — that also matches the pre-existing `test "#default_skill_level returns the expected value"` (`test/models/admin_user_test.rb:313`), which would make every count below wrong.

- [ ] **Step 3: Create the migration**

Create `db/migrate/20261001120000_add_human_operating_manual_requirement_flags_to_admin_users.rb`:

```ruby
class AddHumanOperatingManualRequirementFlagsToAdminUsers < ActiveRecord::Migration[6.1]
  def change
    add_column :admin_users, :requires_human_operating_manual, :boolean, null: false, default: true
    add_column :admin_users, :requires_superpowers_assessment, :boolean, null: false, default: true
  end
end
```

`null: false, default: true` makes Postgres backfill every existing row within the same `ADD COLUMN` statement, so no separate backfill is needed and no row ever reads as exempt.

- [ ] **Step 4: Hand-edit `db/schema.rb`**

Do NOT run `db:migrate` (see Global Constraints). Make exactly two edits.

First, bump the version on line 13:

```ruby
ActiveRecord::Schema.define(version: 2026_10_01_120000) do
```

Second, in the `create_table "admin_users"` block, insert both columns after `t.boolean "ignore", default: false` and before the first `t.index` line, so the block reads:

```ruby
    t.jsonb "info", default: {}
    t.boolean "ignore", default: false
    t.boolean "requires_human_operating_manual", default: true, null: false
    t.boolean "requires_superpowers_assessment", default: true, null: false
    t.index ["email"], name: "index_admin_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_admin_users_on_reset_password_token", unique: true
```

Rails dumps columns in physical order, so this is the placement a real dump would produce. Anywhere else creates a spurious diff the next time someone dumps the schema.

- [ ] **Step 5: Run the test to verify it passes**

```bash
RAILS_ENV=test bundle exec rails test test/models/admin_user_test.rb -n "/required_to_have_a_Human_Operating_Manual/"
```

Expected: PASS, `1 runs, 2 assertions, 0 failures, 0 errors, 0 skips`.

The first run reloads the test DB from `db/schema.rb`, so it takes longer than usual. If it fails with `ActiveRecord::EnvironmentMismatchError`, run `RAILS_ENV=test bundle exec rails db:environment:set` and retry.

- [ ] **Step 6: Verify the whole AdminUser model test file still passes**

```bash
RAILS_ENV=test bundle exec rails test test/models/admin_user_test.rb
```

Expected: PASS. (If only the salary-window test fails, check whether the local clock is between 20:00 and 24:00 ET — that failure is pre-existing and unrelated.)

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20261001120000_add_human_operating_manual_requirement_flags_to_admin_users.rb db/schema.rb test/models/admin_user_test.rb
git commit -m "$(cat <<'EOF'
feat: add HOM and Superpowers assessment requirement flags to admin_users

Two booleans, both null: false default: true, so every existing and future
person is required until an admin deliberately exempts them. schema.rb is
hand-curated in this repo, so it is edited by hand rather than dumped.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Suppress the nag tasks in the discovery

**Files:**
- Modify: `lib/stacks/task_builder/discoveries/human_operating_manuals.rb:20-31`
- Test: `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb` (append six tests before the final `end`)

**Interfaces:**
- Consumes: `AdminUser#requires_human_operating_manual?` and `AdminUser#requires_superpowers_assessment?` from Task 1.
- Produces: no new public interface. Behaviour only.

The target behaviour, which the six tests below pin cell by cell:

| `requires_human_operating_manual` | `requires_superpowers_assessment` | No manual exists | Manual exists, no PDF | Manual exists with PDF |
|---|---|---|---|---|
| true | true | `missing_human_operating_manual` | `missing_superpowers_pdf` | no task |
| true | false | `missing_human_operating_manual` | no task | no task |
| false | true | **no task** | `missing_superpowers_pdf` | no task |
| false | false | no task | no task | no task |

- [ ] **Step 1: Write the six failing tests**

Append to `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb`, immediately before the file's final `end`.

Set the flags with `admin.update!(...)` after `build_admin!`. Do NOT add keyword arguments to `build_admin!` (`test/test_helper.rb:109`) — it has a fixed four-keyword signature shared by many other tests. `update!` is safe here: the `BustsTaskCache` `after_commit` hook rescues its own failures (`app/models/concerns/busts_task_cache.rb:26-29`) and the test cache is `:null_store` (`config/environments/test.rb:26`).

```ruby
  test "an admin exempt from the assessment whose manual lacks a PDF gets no tasks" do
    admin = build_admin!
    admin.update!(requires_superpowers_assessment: false)

    assert_empty discover([manual_page("Email" => email_prop(admin.email))])
  end

  test "an admin exempt from the assessment with no manual still gets missing_human_operating_manual" do
    admin = build_admin!
    admin.update!(requires_superpowers_assessment: false)

    tasks = discover([manual_page("Email" => email_prop("someone.else@sanctuary.computer"))])

    task = tasks.find { |t| t.type == :missing_human_operating_manual }
    assert task, "expected the manual requirement to survive an assessment exemption"
    assert_equal admin, task.subject
    assert_equal [admin], task.owners
  end

  test "an admin exempt from the manual with no manual gets no tasks, even though the assessment is still required" do
    admin = build_admin!
    admin.update!(requires_human_operating_manual: false)
    assert admin.requires_superpowers_assessment?,
      "this test is only meaningful while the assessment is still required"

    assert_empty discover([manual_page("Email" => email_prop("someone.else@sanctuary.computer"))])
  end

  test "an admin exempt from the manual who has one anyway is still nagged for the assessment" do
    admin = build_admin!
    admin.update!(requires_human_operating_manual: false)

    tasks = discover([manual_page("Email" => email_prop(admin.email))])

    task = tasks.find { |t| t.type == :missing_superpowers_pdf }
    assert task, "a manual exemption must not imply an assessment exemption"
    assert_equal [admin], task.owners
  end

  test "an admin exempt from both with no manual gets no tasks" do
    admin = build_admin!
    admin.update!(requires_human_operating_manual: false, requires_superpowers_assessment: false)

    assert_empty discover([manual_page("Email" => email_prop("someone.else@sanctuary.computer"))])
  end

  test "an admin exempt from both whose manual lacks a PDF gets no tasks" do
    admin = build_admin!
    admin.update!(requires_human_operating_manual: false, requires_superpowers_assessment: false)

    assert_empty discover([manual_page("Email" => email_prop(admin.email))])
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
RAILS_ENV=test bundle exec rails test test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb
```

Expected: 21 runs with **4 failures** — the four `assert_empty` tests fail because the discovery still emits tasks. The two tests asserting a task *is* present already pass, since they describe behaviour the current code happens to have. That is fine and expected; do not "fix" them.

- [ ] **Step 3: Add the two early-outs**

In `lib/stacks/task_builder/discoveries/human_operating_manuals.rb`, replace the `AdminUser.active…` block (currently `:20-31`) with:

```ruby
          AdminUser.active.not_ignored.distinct.flat_map do |user|
            manuals = manuals_by_email[user.email.downcase]
            if manuals.empty?
              # Exempt from the manual entirely: nothing to nag about, and there
              # is no manual on which a Superpowers assessment could live, so an
              # outstanding assessment requirement is unactionable here too.
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

`next []`, not a bare `next` — a bare `next` yields `nil` into the flattened array and breaks `assert_empty`.

Also update the class comment at the top of the file so it no longer claims the requirement is universal. Replace:

```ruby
      # Every active admin should have a Human Operating Manual page in
      # Notion (matched by email) with a Pigment.is Superpowers PDF attached.
      # Both task types are personal — owned by the admin themselves.
```

with:

```ruby
      # Every active admin should have a Human Operating Manual page in
      # Notion (matched by email) with a Pigment.is Superpowers PDF attached,
      # unless an admin has exempted them via AdminUser's
      # requires_human_operating_manual / requires_superpowers_assessment
      # flags (both default true).
      # Both task types are personal — owned by the admin themselves.
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
RAILS_ENV=test bundle exec rails test test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb
```

Expected: PASS, `21 runs, … 0 failures, 0 errors, 0 skips`. All 15 pre-existing tests must still pass untouched — that is the regression check proving the defaults preserve current behaviour.

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/task_builder/discoveries/human_operating_manuals.rb test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb
git commit -m "$(cat <<'EOF'
feat: honour HOM and Superpowers assessment exemptions in the nag discovery

This discovery is the only producer of missing_human_operating_manual and
missing_superpowers_pdf, and every surface hydrates the same TaskBuilder
cache, so suppressing here clears the task from the admin-page nag banner,
the /admin/tasks dashboard, the person's own page, the contributor and
payables pills, the studio OKR warning, the daily SystemNotification and
the MCP tool at once.

A manual exemption also suppresses the assessment nag when no manual
exists, since the assessment is a file property on a manual page and there
would be nowhere to attach it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Admin UI and server-side enforcement

**Files:**
- Modify: `app/admin/admin_users.rb:2-5` (permit_params), `:121-133` (the `update` override), `:185` (the form block)
- Test: `test/integration/admin_permission_grants_test.rb` (append three tests before the final `end`)

**Interfaces:**
- Consumes: `AdminUser#requires_human_operating_manual` and `#requires_superpowers_assessment` from Task 1.
- Produces: no new public interface.

**Why a server-side strip is mandatory.** Hiding the inputs enforces nothing in this app. `AdminAuthorization` returns `true` for every action on every not-explicitly-carved-out subject when `user.is_admin? || user.can_act_as_lead?` (`app/models/admin_authorization.rb:84`), and `can_act_as_lead?` is `has_led_projects? || <global "lead" grant>` (`app/models/admin_user.rb:566-568`) — anyone who has ever led a project. That check is not record-scoped, and `actions :index, :show, :edit, :update` (`app/admin/admin_users.rb:43`) means such a user can `PUT /admin/admin_users/:id` for *any* person, with `permit_params` applying globally. Without the strip, every past project lead could silently exempt themselves — or anyone — from their nag tasks, and the spec deliberately includes no audit trail that would reveal it. The repo already solved this exact problem for permission grants in the `update` override you are about to extend.

- [ ] **Step 1: Write the three failing tests**

Append to `test/integration/admin_permission_grants_test.rb`, immediately before the file's final `end`. The `setup` block already provides `@admin` (an admin) and `@trainee` (no roles); `Devise::Test::IntegrationHelpers` provides `sign_in`.

Note the `PermissionGrant.create!` in the first test is load-bearing: a bare `@trainee` has no lead periods and no grants, so `can_act_as_lead?` is `false` and they would be rejected by authorization before reaching `update`. The grant is what makes them a lead and therefore makes the test actually exercise the strip.

```ruby
  test "a non-admin lead cannot exempt themselves from the Human Operating Manual nag" do
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", granted_by: @admin)
    sign_in @trainee

    put admin_admin_user_path(@trainee), params: {
      admin_user: {
        profit_share_notes: "hi",
        requires_human_operating_manual: "0",
        requires_superpowers_assessment: "0"
      }
    }

    @trainee.reload
    assert @trainee.requires_human_operating_manual?,
      "a non-admin lead must not be able to drop their own manual requirement"
    assert @trainee.requires_superpowers_assessment?,
      "a non-admin lead must not be able to drop their own assessment requirement"
  end

  test "an admin can exempt someone from the Human Operating Manual nag" do
    sign_in @admin

    put admin_admin_user_path(@trainee), params: {
      admin_user: {
        requires_human_operating_manual: "0",
        requires_superpowers_assessment: "0"
      }
    }

    @trainee.reload
    refute @trainee.requires_human_operating_manual?
    refute @trainee.requires_superpowers_assessment?
  end

  test "the exemption checkboxes render on the edit form for admins" do
    sign_in @admin

    get edit_admin_admin_user_path(@trainee)

    assert_response :success
    assert_includes response.body, "admin_user_requires_human_operating_manual"
    assert_includes response.body, "admin_user_requires_superpowers_assessment"
  end
```

The second test is what stops the first from passing vacuously — without it, never wiring the params up at all would look like success.

The third test exists because **no test in the entire suite currently renders the AdminUser edit form.** `grep -rn "edit_admin_admin_user" test/` returns nothing, and the neighbouring test named "…from the edit form" only issues a `put` — `test/integration/admin_permission_grants_test.rb:95` GETs the *show* page, not edit. So without this test the two `f.input` lines added in Step 6 would be completely unexercised, which is exactly the Formtastic render path the spec identifies as the change's largest blast radius (§1, Deploy ordering). A render assertion is cheap and closes that gap.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
RAILS_ENV=test bundle exec rails test test/integration/admin_permission_grants_test.rb
```

Expected: `13 runs` with **2 failures**:

- the **admin** test fails — the flags are not in `permit_params` yet, so they are silently ignored and stay `true`. (`action_on_unpermitted_parameters` is unset in this repo, so the default `:log` applies in test: unpermitted params are logged, never raised.)
- the **form-render** test fails on `assert_includes` — the inputs don't exist yet.
- the **non-admin** test passes, but for the wrong reason: the params aren't permitted yet, so nothing was going to change anyway. It only becomes meaningful after Step 3.

All three must pass for the right reasons by Step 7.

- [ ] **Step 3: Add the two params to `permit_params`**

In `app/admin/admin_users.rb`, extend the `permit_params` list at the top of the file (currently `:2-5`) so it reads:

```ruby
  permit_params :show_skill_tree_data,
    :ignore,
    :requires_human_operating_manual,
    :requires_superpowers_assessment,
    :old_skill_tree_level,
    :profit_share_notes,
```

- [ ] **Step 4: Strip the params for non-admins in the existing `update` override**

In `app/admin/admin_users.rb`, the `controller do … end` block already contains an `update` override (`:121-133`). Add the strip inside `update`, just before `super`, so the whole region reads:

```ruby
    # Permission grants are admin-managed only. The form hides them from
    # non-admins, but leads pass the authorization adapter for AdminUser
    # updates, so strip the params server-side too. New grants get
    # granted_by stamped from the acting admin, never from the client.
    def update
      attrs = params.dig(:admin_user, :permission_grants_attributes)
      if attrs.present?
        if current_admin_user.is_admin?
          attrs.each do |_key, grant_attrs|
            grant_attrs[:granted_by_id] = current_admin_user.id if grant_attrs[:id].blank?
          end
        else
          params[:admin_user].delete(:permission_grants_attributes)
        end
      end

      # Nag exemptions are admin-managed only, for the same reason as above:
      # hiding the checkboxes in the form is not enforcement, because
      # AdminAuthorization grants every action to anyone who can act as a lead
      # and that check is not record-scoped. Without this strip any past
      # project lead could exempt themselves from their own nag tasks, and
      # there is deliberately no audit trail that would show it.
      unless current_admin_user.is_admin?
        %i[requires_human_operating_manual requires_superpowers_assessment].each do |flag|
          params[:admin_user]&.delete(flag)
        end
      end

      super
    end
```

Inline the array rather than extracting a constant. A constant assigned inside an ActiveAdmin DSL block lands on `Object` (the lexical cref for a top-level-`load`ed file), not on the controller class, and since `cache_classes` is false in dev/test ActiveAdmin reloads `app/admin`, so each reload re-assigns it and Ruby warns `already initialized constant`. Two symbols inline avoid the whole question.

- [ ] **Step 5: Run the tests to verify the two param tests now pass**

```bash
RAILS_ENV=test bundle exec rails test test/integration/admin_permission_grants_test.rb
```

Expected: `13 runs` with **1 failure** — the form-render test, which still fails because Step 6 hasn't added the inputs yet. The admin and non-admin tests must both pass now, and both are meaningful: the admin one proves the params are wired up, the non-admin one proves the strip blocks them. Every pre-existing test in the file must still pass.

- [ ] **Step 6: Add the two checkboxes to the form**

In `app/admin/admin_users.rb`, inside the `f.inputs(class: "admin_inputs")` block (`:184`) which is already wrapped in `if current_admin_user.is_admin?` (`:183`), add both inputs immediately after the existing `f.input :ignore` line (`:185`):

```ruby
        f.input :ignore, hint: "Check this box if this account is a dummy email address, bot or duplicate."
        f.input :requires_human_operating_manual,
          label: "Requires a Human Operating Manual",
          hint: "Leave checked for everyone normally. Uncheck to exempt this person — they won't be asked to create a Human Operating Manual, and the task won't appear for them or for admins following up. If they have no manual at all, this also silences the Superpowers assessment nag, since there would be no page to attach the PDF to. Can take up to 24h to clear everywhere."
        f.input :requires_superpowers_assessment,
          label: "Requires a Pigment.is Superpowers assessment",
          hint: "Leave checked for everyone normally. Uncheck to exempt this person from attaching a Pigment.is Superpowers PDF to their Human Operating Manual. Can take up to 24h to clear everywhere."
```

Formtastic renders `:boolean` columns as checkboxes automatically, so no `as:` option is needed.

- [ ] **Step 7: Verify all three tests pass**

```bash
RAILS_ENV=test bundle exec rails test test/integration/admin_permission_grants_test.rb
```

Expected: PASS, `13 runs, … 0 failures, 0 errors, 0 skips`. The form-render test added in Step 1 now finds both checkbox ids, which also proves Formtastic renders the new `:boolean` inputs without raising.

- [ ] **Step 8: Commit**

```bash
git add app/admin/admin_users.rb test/integration/admin_permission_grants_test.rb
git commit -m "$(cat <<'EOF'
feat: admin-only checkboxes for HOM and Superpowers assessment exemptions

Two checkboxes on the AdminUser edit form, in the block already gated on
current_admin_user.is_admin?.

The server-side strip is the actual enforcement: AdminAuthorization grants
every action to anyone who can act as a lead and the check is not
record-scoped, so a past project lead can PUT any AdminUser. Hiding the
inputs would leave a silent self-exemption path, which matters more than
usual because the feature deliberately carries no audit trail. This extends
the existing update override that already does the same for permission
grants.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Full-suite verification

**Files:** none modified. This task only runs tests.

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces: the evidence needed before opening a PR.

- [ ] **Step 1: Run the full suite**

```bash
RAILS_ENV=test bundle exec rails test $(find test -name '*_test.rb' -not -path 'test/lib/tasks/etl_rake_test.rb' | tr '\n' ' ')
```

Expected: `1775 runs, …, 0 failures, 0 errors, 2 skips` — the 1765 baseline plus the 10 new tests (1 defaults + 6 discovery + 3 integration). The hard requirements are `0 failures, 0 errors` and a run count of exactly 1775.

- [ ] **Step 2: Confirm no stray changes**

```bash
git status --porcelain
```

Expected: empty output. `config/master.key` must not appear (it is gitignored); nothing under `.worktrees/` should be staged.

- [ ] **Step 3: Confirm the diff is the expected seven files**

```bash
git diff --stat origin/main...HEAD
```

Expected: the migration, `db/schema.rb`, the discovery, its test, `app/admin/admin_users.rb`, the integration test, `test/models/admin_user_test.rb`, plus the two `docs/superpowers/` files committed before implementation began.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 Data model — migration | Task 1 Step 3 |
| §1 schema.rb hand-edit + version bump | Task 1 Step 4 |
| §1 Naming | Task 1 (column names in the migration) |
| §1 Deploy ordering / no `column_exists?` guard | No task — deliberate non-goal; recorded in the PR description instead |
| §2 Discovery early-outs, `next []` not bare `next` | Task 2 Step 3 |
| §2 Flag-interaction table (all four rows) | Task 2 Step 1, six tests |
| §3 permit_params | Task 3 Step 3 |
| §3 Server-side strip in `update` | Task 3 Step 4 |
| §3 Two checkboxes in the admin-only block | Task 3 Step 6 |
| Testing — 15 existing discovery tests unchanged | Task 2 Step 4 |
| Testing — defaults | Task 1 Step 1 |
| Testing — authorization (both directions) | Task 3 Step 1 |
| Testing — the edit form actually renders the checkboxes | Task 3 Step 1 (third test) |
| Testing — full suite, etl_rake excluded, db:environment:set | Task 4, Global Constraints |

No gaps. The only spec content without a task is the deploy-ordering discussion, which is operational guidance rather than code — it belongs in the PR description so whoever merges runs the migration promptly.

**Placeholder scan:** none. Every code step contains the literal code; every command step contains the literal command and its expected output.

**Type consistency:** `requires_human_operating_manual` and `requires_superpowers_assessment` are spelled identically in the migration, schema, discovery, form, permit_params, the strip constant, and all nine tests. The predicate form (`?`) is used only where a boolean is read.
