# Human Operating Manual Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit per-admin Stacks tasks when an active admin user has no Human Operating Manual page in Notion, or has one without a "Pigment.is Superpowers PDF" file attached.

**Architecture:** Register the Notion "🤼 Human Operating Manuals" database in `Stacks::Notion::DATABASE_IDS` (the daily rake sync sweeps the whole registry automatically), wrap synced `NotionPage` rows in a `Stacks::Notion::HumanOperatingManual` value object, and add a `Stacks::TaskBuilder` discovery that joins manuals to `AdminUser`s by email and emits `:missing_human_operating_manual` / `:missing_superpowers_pdf` tasks owned by the admin themselves. Display plumbing mirrors the existing `Stacks::Notion::Lead` subject type.

**Tech Stack:** Rails 6.1 / Ruby 3.1.7, minitest + mocha (`Object#stubs`), no new gems.

**Spec:** `docs/superpowers/specs/2026-08-17-human-operator-manual-links-design.md`

## Global Constraints

- Notion database ID (copy verbatim): `5d59dcd95bfb458a9747ce7d6ce9e009`
- Notion property names (copy verbatim, they are fuzzy-matched case-insensitively): `Email`, `Pigment.is Superpowers PDF`
- Humanized labels (copy verbatim): `missing_human_operating_manual` → "Admin user needs a Human Operating Manual"; `missing_superpowers_pdf` → "Human Operating Manual needs a Pigment.is Superpowers PDF"
- Task ownership: both task types are owned by the affected `AdminUser` (never the fallback admin team, unless the owner list is somehow empty — the `Discoveries::Base#task` helper handles that invariant).
- Population: `AdminUser.active.not_ignored.distinct` only.
- Email join: case-insensitive; manuals with a blank `Email` property are ignored entirely.
- Never emit both task types for the same admin user.
- Test runner: `bin/rails test <path>` from the repo root. All tests must pass before each commit.
- `lib/` is autoloaded and eager-loaded (`config/application.rb:30-31`) — do NOT add `require` lines for the wrapper class. The discovery file DOES need a `require_relative` in `lib/stacks/task_builder.rb` because that file explicitly requires all discoveries.

---

### Task 1: Notion registration + `Stacks::Notion::HumanOperatingManual` wrapper

**Files:**
- Modify: `lib/stacks/notion.rb:8-10` (DATABASE_IDS)
- Modify: `app/models/notion_page.rb` (scope + wrap method, after the existing `:lead` scope / `#as_lead`)
- Create: `lib/stacks/notion/human_operating_manual.rb`
- Test: `test/lib/stacks/notion/human_operating_manual_test.rb`

**Interfaces:**
- Consumes: `Stacks::Notion::Base` (`get_prop_value(fuzzy_key)`, delegation to `NotionPage` via method_missing — gives `notion_link`, `page_title`, `notion_page` for free).
- Produces (later tasks rely on these exact names):
  - `Stacks::Notion::HumanOperatingManual.all` → `Array<Stacks::Notion::HumanOperatingManual>`
  - `#email` → downcased String or nil
  - `#superpowers_pdf?` → Boolean
  - `#notion_page` → underlying `NotionPage` (from `Stacks::Notion::Base`'s `attr_accessor`)
  - `NotionPage.human_operating_manual` scope and `NotionPage#as_human_operating_manual`

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/notion/human_operating_manual_test.rb`:

```ruby
require 'test_helper'

class StacksNotionHumanOperatingManualTest < ActiveSupport::TestCase
  def manual_with_props(props)
    NotionPage.new(data: { "properties" => props }).as_human_operating_manual
  end

  def email_prop(value)
    { "type" => "email", "email" => value }
  end

  def files_prop(files)
    { "type" => "files", "files" => files }
  end

  test "#email returns the downcased Email property" do
    manual = manual_with_props("Email" => email_prop("Hugh@Sanctuary.computer"))
    assert_equal "hugh@sanctuary.computer", manual.email
  end

  test "#email returns nil when the property is missing or empty" do
    assert_nil manual_with_props({}).email
    assert_nil manual_with_props("Email" => email_prop(nil)).email
  end

  test "#superpowers_pdf? is true when the PDF property holds at least one file" do
    manual = manual_with_props(
      "Pigment.is Superpowers PDF" => files_prop([{ "name" => "superpowers.pdf" }])
    )
    assert manual.superpowers_pdf?
  end

  test "#superpowers_pdf? is false when the PDF property is empty or missing" do
    refute manual_with_props("Pigment.is Superpowers PDF" => files_prop([])).superpowers_pdf?
    refute manual_with_props({}).superpowers_pdf?
  end

  test ".all wraps every page in the human_operating_manual scope" do
    page = NotionPage.new(data: { "properties" => {} })
    NotionPage.stubs(:human_operating_manual).returns([page])
    all = Stacks::Notion::HumanOperatingManual.all
    assert_equal 1, all.length
    assert_kind_of Stacks::Notion::HumanOperatingManual, all.first
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/notion/human_operating_manual_test.rb`
Expected: FAIL/ERROR with `NoMethodError: undefined method 'as_human_operating_manual'`

- [ ] **Step 3: Write the implementation**

In `lib/stacks/notion.rb`, change the `DATABASE_IDS` hash (lines 8–10) to:

```ruby
  DATABASE_IDS = {
    LEADS: "4d9b46b8bad542509f144347db37964d",
    HUMAN_OPERATING_MANUALS: "5d59dcd95bfb458a9747ce7d6ce9e009"
  }
```

In `app/models/notion_page.rb`, directly below the existing `as_lead` method (line 13), add:

```ruby
  scope :human_operating_manual, -> {
    where(
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:HUMAN_OPERATING_MANUALS])
    )
  }

  def as_human_operating_manual
    Stacks::Notion::HumanOperatingManual.new(self)
  end
```

Create `lib/stacks/notion/human_operating_manual.rb`:

```ruby
# Wraps a NotionPage row from the "🤼 Human Operating Manuals" database.
# Synced daily by the DATABASE_IDS sweep in lib/tasks/stacks.rake; consumed
# by Stacks::TaskBuilder::Discoveries::HumanOperatingManuals to nag active
# admins who are missing a manual or its Superpowers PDF.
class Stacks::Notion::HumanOperatingManual < Stacks::Notion::Base
  class << self
    def all
      NotionPage.human_operating_manual.map(&:as_human_operating_manual)
    end
  end

  # Downcased "Email" property — the join key to AdminUser.email. Nil when unset.
  def email
    value = get_prop_value("Email")
    value.is_a?(String) ? value.downcase : nil
  end

  # True when the "Pigment.is Superpowers PDF" file property holds ≥1 file.
  def superpowers_pdf?
    files = get_prop_value("Pigment.is Superpowers PDF")
    files.is_a?(Array) && files.any?
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/notion/human_operating_manual_test.rb`
Expected: PASS (5 tests, 0 failures)

- [ ] **Step 5: Run the neighboring Notion tests to check for regressions**

Run: `bin/rails test test/lib/stacks/notion/lead_test.rb test/lib/stacks/task_builder/discoveries/notion_leads_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/notion.rb lib/stacks/notion/human_operating_manual.rb app/models/notion_page.rb test/lib/stacks/notion/human_operating_manual_test.rb
git commit -m "feat: sync + wrap the Human Operating Manuals Notion database"
```

---

### Task 2: `Discoveries::HumanOperatingManuals` task discovery

**Files:**
- Create: `lib/stacks/task_builder/discoveries/human_operating_manuals.rb`
- Modify: `lib/stacks/task_builder.rb` (require_relative block at top, `DISCOVERY_CLASSES` list ~line 43)
- Test: `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb`

**Interfaces:**
- Consumes: `Stacks::Notion::HumanOperatingManual.all` / `#email` / `#superpowers_pdf?` / `#notion_page` (Task 1); `Discoveries::Base#task(subject:, type:, owners:)`; `AdminUser.active`, `AdminUser.not_ignored` scopes; test helper `build_admin!` (`test/test_helper.rb:108`).
- Produces: `Stacks::TaskBuilder::Discoveries::HumanOperatingManuals#tasks` → `Array<StacksTask>` with types `:missing_human_operating_manual` (subject: `AdminUser`) and `:missing_superpowers_pdf` (subject: `Stacks::Notion::HumanOperatingManual`). Task 3 relies on exactly these subject classes and type symbols.

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb`:

```ruby
require 'test_helper'

class StacksTaskBuilderDiscoveriesHumanOperatingManualsTest < ActiveSupport::TestCase
  def setup
    # No full-time period → inactive → excluded from the checked population,
    # so the fallback itself never generates tasks in these tests.
    @fallback = AdminUser.create!(email: "fallback@sanctuary.computer", password: "passw0rd")
  end

  def manual_page(props)
    NotionPage.new(data: { "properties" => props })
  end

  def email_prop(value)
    { "type" => "email", "email" => value }
  end

  def files_prop(files)
    { "type" => "files", "files" => files }
  end

  def discover(pages)
    NotionPage.stubs(:human_operating_manual).returns(pages)
    Stacks::TaskBuilder::Discoveries::HumanOperatingManuals.new(admin_fallback: [@fallback]).tasks
  end

  test "an active admin with no matching manual gets a missing_human_operating_manual task they own" do
    admin = build_admin!
    tasks = discover([])

    task = tasks.find { |t| t.type == :missing_human_operating_manual }
    assert task, "expected a missing_human_operating_manual task"
    assert_equal admin, task.subject
    assert_equal [admin], task.owners
  end

  test "an active admin whose manual lacks a PDF gets a missing_superpowers_pdf task subjecting the manual" do
    admin = build_admin!
    page = manual_page("Email" => email_prop(admin.email))
    tasks = discover([page])

    task = tasks.find { |t| t.type == :missing_superpowers_pdf }
    assert task, "expected a missing_superpowers_pdf task"
    assert_kind_of Stacks::Notion::HumanOperatingManual, task.subject
    assert_equal page, task.subject.notion_page
    assert_equal [admin], task.owners
    refute tasks.any? { |t| t.type == :missing_human_operating_manual && t.subject == admin }
  end

  test "an active admin whose manual has a PDF gets no tasks" do
    admin = build_admin!
    tasks = discover([manual_page(
      "Email" => email_prop(admin.email),
      "Pigment.is Superpowers PDF" => files_prop([{ "name" => "superpowers.pdf" }])
    )])

    assert_empty tasks
  end

  test "email matching is case-insensitive" do
    admin = build_admin!
    tasks = discover([manual_page(
      "Email" => email_prop(admin.email.upcase),
      "Pigment.is Superpowers PDF" => files_prop([{ "name" => "superpowers.pdf" }])
    )])

    assert_empty tasks
  end

  test "manuals with a blank Email property are ignored" do
    admin = build_admin!
    tasks = discover([manual_page("Email" => email_prop(nil))])

    task = tasks.find { |t| t.type == :missing_human_operating_manual }
    assert task
    assert_equal admin, task.subject
  end

  test "ignored admins are skipped" do
    admin = build_admin!
    admin.update!(ignore: true)
    assert_empty discover([])
  end

  test "inactive admins are skipped" do
    build_admin!(ended_at: Date.today - 1)
    assert_empty discover([])
  end

  test "with multiple matching manuals, a PDF on any of them satisfies the check" do
    admin = build_admin!
    tasks = discover([
      manual_page("Email" => email_prop(admin.email)),
      manual_page(
        "Email" => email_prop(admin.email),
        "Pigment.is Superpowers PDF" => files_prop([{ "name" => "superpowers.pdf" }])
      )
    ])

    assert_empty tasks
  end
end
```

(The humanized-label and display tests are deliberately NOT in this task — Task 3 adds them alongside the code that makes them pass, so every commit stays green.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb`
Expected: ERROR with `NameError: uninitialized constant Stacks::TaskBuilder::Discoveries::HumanOperatingManuals`

- [ ] **Step 3: Write the implementation**

Create `lib/stacks/task_builder/discoveries/human_operating_manuals.rb`:

```ruby
module Stacks
  class TaskBuilder
    module Discoveries
      # Every active admin should have a Human Operating Manual page in
      # Notion (matched by email) with a Pigment.is Superpowers PDF attached.
      # Both task types are personal — owned by the admin themselves.
      class HumanOperatingManuals < Base
        def tasks
          manuals_by_email = Stacks::Notion::HumanOperatingManual.all
            .select { |m| m.email.present? }
            .group_by(&:email)

          AdminUser.active.not_ignored.distinct.flat_map do |user|
            manuals = manuals_by_email[user.email.downcase] || []
            if manuals.empty?
              [task(subject: user, type: :missing_human_operating_manual, owners: [user])]
            elsif manuals.none?(&:superpowers_pdf?)
              # Deterministic subject across cache rebuilds: lowest NotionPage id.
              manual = manuals.min_by { |m| m.notion_page.id.to_i }
              [task(subject: manual, type: :missing_superpowers_pdf, owners: [user])]
            else
              []
            end
          end
        end
      end
    end
  end
end
```

In `lib/stacks/task_builder.rb`:

1. Add to the `require_relative` block at the top (after the `notion_leads` line):

```ruby
require_relative "task_builder/discoveries/human_operating_manuals"
```

2. Add to `DISCOVERY_CLASSES` (after `Discoveries::NotionLeads,`):

```ruby
      Discoveries::HumanOperatingManuals,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb`
Expected: PASS (8 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/task_builder.rb lib/stacks/task_builder/discoveries/human_operating_manuals.rb test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb
git commit -m "feat: TaskBuilder discovery for missing Human Operating Manuals / Superpowers PDFs"
```

---

### Task 3: Display plumbing + hydration for the new subject type

**Files:**
- Modify: `app/models/stacks_task.rb` (`HUMANIZED_TYPES` ~line 28, `subject_class_key` ~line 81, `subject_display_name` ~line 97, `subject_url` ~line 139, `subject_url_external?` ~line 163)
- Modify: `lib/stacks/task_builder.rb` (`subject_id_for` ~line 110, `batch_load_subjects` ~line 146)
- Test: `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb` (labels + display), Create: `test/lib/stacks/task_builder/human_operating_manual_hydration_test.rb`

**Interfaces:**
- Consumes: `Stacks::Notion::HumanOperatingManual` (`#notion_page`, `#email`, delegated `#page_title` / `#notion_link`), types `:missing_human_operating_manual` / `:missing_superpowers_pdf` from Task 2.
- Produces: `StacksTask#humanized_type`, `#subject_class_key` (`"human_operating_manuals"`), `#subject_display_name`, `#subject_url` (external Notion link) for the new subject; `Stacks::TaskBuilder` descriptor round-trip (`subject_type: "Stacks::Notion::HumanOperatingManual"`, `subject_id: <NotionPage#id>`).

- [ ] **Step 1: Write the failing tests**

Append to `test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb` (inside the class):

```ruby
  test "both task types have explicit humanized labels" do
    assert_equal "Admin user needs a Human Operating Manual",
      StacksTask::HUMANIZED_TYPES[:missing_human_operating_manual]
    assert_equal "Human Operating Manual needs a Pigment.is Superpowers PDF",
      StacksTask::HUMANIZED_TYPES[:missing_superpowers_pdf]
  end

  test "a missing_superpowers_pdf task links externally to the Notion manual" do
    admin = build_admin!
    page = manual_page("Email" => email_prop(admin.email))
    page.notion_id = "abc123def456"
    tasks = discover([page])

    task = tasks.find { |t| t.type == :missing_superpowers_pdf }
    assert_equal "human_operating_manuals", task.subject_class_key
    assert_equal "https://www.notion.so/garden3d/abc123def456", task.subject_url
    assert task.subject_url_external?
  end

  test "a missing_superpowers_pdf task displays the manual's title, falling back to email" do
    admin = build_admin!
    titled = manual_page("Email" => email_prop(admin.email))
    titled.page_title = "Hugh's Manual"
    tasks = discover([titled])
    assert_equal "Hugh's Manual", tasks.find { |t| t.type == :missing_superpowers_pdf }.subject_display_name

    untitled = manual_page("Email" => email_prop(admin.email))
    tasks = discover([untitled])
    assert_equal admin.email.downcase, tasks.find { |t| t.type == :missing_superpowers_pdf }.subject_display_name
  end
```

Create `test/lib/stacks/task_builder/human_operating_manual_hydration_test.rb`:

```ruby
require 'test_helper'

class StacksTaskBuilderHumanOperatingManualHydrationTest < ActiveSupport::TestCase
  test "descriptors for manual subjects round-trip through hydrate as re-wrapped manuals" do
    admin = build_admin!
    page = NotionPage.create!(
      notion_id: "11111111-2222-3333-4444-555555555555",
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:HUMAN_OPERATING_MANUALS]),
      page_title: "Test Manual",
      data: { "properties" => {} }
    )
    builder = Stacks::TaskBuilder.new
    manual = page.as_human_operating_manual
    task = StacksTask.new(type: :missing_superpowers_pdf, subject: manual, owners: [admin])

    descriptor = builder.send(:descriptor_for, task)
    assert_equal "Stacks::Notion::HumanOperatingManual", descriptor[:subject_type]
    assert_equal page.id, descriptor[:subject_id]

    hydrated = builder.send(:hydrate, [descriptor])
    assert_equal 1, hydrated.length
    assert_kind_of Stacks::Notion::HumanOperatingManual, hydrated.first.subject
    assert_equal page, hydrated.first.subject.notion_page
    assert_equal [admin], hydrated.first.owners
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb test/lib/stacks/task_builder/human_operating_manual_hydration_test.rb`
Expected: FAIL — nil humanized labels; `subject_class_key` returns the demodulized default (`"human_operating_manuals"` is actually what demodulize+underscore+pluralize produces for `HumanOperatingManual`, so that one may pass); `subject_url` returns the notion_link via the `else subject.try(:external_link)` fallback (may pass); `subject_url_external?` returns false (FAILS); hydration test FAILS in `batch_load_subjects` (tries `Stacks::Notion::HumanOperatingManual.where`, raising `NoMethodError`).

- [ ] **Step 3: Write the implementation**

In `app/models/stacks_task.rb`:

1. Add to `HUMANIZED_TYPES` after the "AdminUser issues" group (~line 31):

```ruby
    # Human Operating Manual issues
    missing_human_operating_manual: "Admin user needs a Human Operating Manual",
    missing_superpowers_pdf: "Human Operating Manual needs a Pigment.is Superpowers PDF",
```

2. In `subject_class_key` (~line 82), add a branch above the `else`:

```ruby
    when Stacks::Notion::HumanOperatingManual then "human_operating_manuals"
```

3. In `subject_display_name` (~line 98), add a branch above the `else` (next to the `Stacks::Notion::Lead` branch):

```ruby
    when Stacks::Notion::HumanOperatingManual
      subject.try(:page_title).presence || subject.email || "Human Operating Manual"
```

4. In `subject_url` (~line 150), add next to the `Stacks::Notion::Lead` branch:

```ruby
    when Stacks::Notion::HumanOperatingManual then subject.notion_link
```

5. In `subject_url_external?` (~line 165), extend the true-branch:

```ruby
    when ForecastProject, ForecastPerson, ForecastAssignment, Stacks::Notion::Lead, Stacks::Notion::HumanOperatingManual then true
```

In `lib/stacks/task_builder.rb`:

6. In `subject_id_for` (~line 110), extend the Lead branch:

```ruby
    def subject_id_for(subject)
      case subject
      when Stacks::Notion::Lead, Stacks::Notion::HumanOperatingManual then subject.notion_page.id
      else subject.id
      end
    end
```

7. In `batch_load_subjects` (~line 152), change the wrapper branch:

```ruby
        records =
          if klass == Stacks::Notion::Lead
            # Lead is a wrapper around NotionPage; load the underlying pages
            # and re-wrap. Index by NotionPage.id so descriptor lookup matches.
            NotionPage.where(id: ids).index_by(&:id).transform_values(&:as_lead)
          elsif klass == Stacks::Notion::HumanOperatingManual
            NotionPage.where(id: ids).index_by(&:id).transform_values(&:as_human_operating_manual)
          else
```

(the trailing `else` branch and everything after it is unchanged)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb test/lib/stacks/task_builder/human_operating_manual_hydration_test.rb`
Expected: PASS (12 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/models/stacks_task.rb lib/stacks/task_builder.rb test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb test/lib/stacks/task_builder/human_operating_manual_hydration_test.rb
git commit -m "feat: display + hydration plumbing for Human Operating Manual task subjects"
```

---

### Task 4: Full-suite verification

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: a green build ready for PR.

- [ ] **Step 1: Run the full test suite**

Run: `bin/rails test`
Expected: 0 failures, 0 errors. Pre-existing failures unrelated to this branch (if any) must be listed explicitly and compared against a `git stash`-style check or the baseline test run — do NOT silently accept failures in files this branch touched (`stacks_task`, `task_builder`, `notion_page`, `notion`).

- [ ] **Step 2: Sanity-check the task dashboard renders (boot check)**

Run: `bin/rails runner 'puts Stacks::TaskBuilder::DISCOVERY_CLASSES.map(&:name)'`
Expected: output includes `Stacks::TaskBuilder::Discoveries::HumanOperatingManuals` with no boot errors.

- [ ] **Step 3: Commit anything outstanding**

```bash
git status --short
```

Expected: clean tree (all work committed in Tasks 1–3). If not clean, commit the remainder with an appropriate message.
