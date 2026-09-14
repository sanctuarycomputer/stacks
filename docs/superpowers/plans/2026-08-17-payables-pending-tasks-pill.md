# Payables Pending-Tasks Pill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show an orange "N pending tasks" pill (linking to the person's admin page) in each payables group header on `/admin/money/payable_qbo_bills`, left of the amount pill.

**Architecture:** A hydration-free `TaskBuilder#task_count_for(admin_user)` counts cached descriptors per user; the `payable_qbo_bills` page_action precomputes a per-contributor hash with one builder instance; the view renders the pill only when count > 0.

**Tech Stack:** Rails 6.1 / Ruby 3.1.7, minitest + mocha. No new gems.

**Spec:** `docs/superpowers/specs/2026-08-17-payables-pending-tasks-pill-design.md`

## Global Constraints

- Pill class (verbatim): `pill at_risk` (orange — NOT `error`/red).
- Pill text: `1 pending task` / `N pending tasks` (proper pluralization).
- Render nothing at count 0 or when the contributor has no linked AdminUser.
- Position: inside each group's `titlebar_right`, immediately BEFORE the existing `<span class="pill complete">` amount pill; link wraps the pill and points to `admin_admin_user_path(admin_user)`.
- `task_count_for` must NOT hydrate subjects (descriptor filtering only) and must return 0 for `nil` / unpersisted users.
- One `Stacks::TaskBuilder` instance per page render.
- Test command: `bin/rails test <path>`.

---

### Task 1: `task_count_for` + controller hash + view pill

**Files:**
- Modify: `lib/stacks/task_builder.rb` (add `task_count_for` next to `task_count`, ~line 75)
- Modify: `app/admin/money.rb` (`page_action :payable_qbo_bills`, after `@unsettled_count` ~line 44)
- Modify: `app/views/admin/money/payable_qbo_bills.html.erb` (`titlebar_right` block ~line 142)
- Test: Create `test/lib/stacks/task_builder/task_count_for_test.rb`

**Interfaces:**
- Consumes: `Stacks::TaskBuilder#tasks_for` / `#task_count` (existing, for placement + style), `StacksTask.new(type:, subject:, owners:)`, `Contributor#forecast_person` → `ForecastPerson#admin_user`, test helper `build_admin!` (`test/test_helper.rb:108`).
- Produces: `Stacks::TaskBuilder#task_count_for(admin_user)` → Integer; `@pending_task_counts_by_contributor` → `{ Contributor => { admin_user: AdminUser, count: Integer } }`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/task_builder/task_count_for_test.rb`:

```ruby
require 'test_helper'

class StacksTaskBuilderTaskCountForTest < ActiveSupport::TestCase
  test "counts only the given admin's tasks, without hydration, matching tasks_for" do
    admin_a = build_admin!
    admin_b = build_admin!
    builder = Stacks::TaskBuilder.new
    builder.stubs(:build_tasks).returns([
      StacksTask.new(type: :missing_skill_tree, subject: admin_a, owners: [admin_a]),
      StacksTask.new(type: :missing_skill_tree, subject: admin_b, owners: [admin_b]),
      StacksTask.new(type: :no_full_time_periods_set, subject: admin_b, owners: [admin_b]),
    ])

    assert_equal 1, builder.task_count_for(admin_a)
    assert_equal 2, builder.task_count_for(admin_b)
    assert_equal builder.tasks_for(admin_a).length, builder.task_count_for(admin_a)
  end

  test "returns 0 for nil and for an admin with no tasks" do
    admin = build_admin!
    builder = Stacks::TaskBuilder.new
    builder.stubs(:build_tasks).returns([])

    assert_equal 0, builder.task_count_for(nil)
    assert_equal 0, builder.task_count_for(admin)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/task_builder/task_count_for_test.rb`
Expected: ERROR — `NoMethodError: undefined method 'task_count_for'`

- [ ] **Step 3: Implement**

In `lib/stacks/task_builder.rb`, directly below the existing `task_count` method:

```ruby
    # Pending-task count for one AdminUser. Descriptor filtering only — no
    # subject hydration — so callers can annotate lists of people cheaply
    # (e.g. the payable-bills page header pills).
    def task_count_for(admin_user)
      return 0 unless admin_user&.id
      cached_descriptors.count { |d| d[:owner_ids].include?(admin_user.id) }
    end
```

In `app/admin/money.rb`, inside `page_action :payable_qbo_bills` after the `@unsettled_count` assignment:

```ruby
    # Pending-task pill per payables group — one TaskBuilder instance so the
    # cached descriptors are shared across every contributor's count.
    task_builder = Stacks::TaskBuilder.new
    @pending_task_counts_by_contributor =
      @rows.map(&:contributor).uniq.each_with_object({}) do |contributor, acc|
        admin_user = contributor.forecast_person&.admin_user
        next unless admin_user
        acc[contributor] = { admin_user: admin_user, count: task_builder.task_count_for(admin_user) }
      end
```

In `app/views/admin/money/payable_qbo_bills.html.erb`, inside `<div id="titlebar_right">` immediately BEFORE `<span class="pill complete">`:

```erb
          <% pending = @pending_task_counts_by_contributor[contributor] %>
          <% if pending && pending[:count] > 0 %>
            <%= link_to admin_admin_user_path(pending[:admin_user]) %>
          <% end %>
```

Note: the link must wrap the pill — use this exact form:

```erb
          <% pending = @pending_task_counts_by_contributor[contributor] %>
          <% if pending && pending[:count] > 0 %>
            <%= link_to admin_admin_user_path(pending[:admin_user]), style: "margin-right: 4px;" do %>
              <span class="pill at_risk"><%= pluralize(pending[:count], "pending task") %></span>
            <% end %>
          <% end %>
```

(Use only the second form; the first is shown to clarify the guard.)

- [ ] **Step 4: Run tests to verify green + regressions**

Run: `bin/rails test test/lib/stacks/task_builder/`
Expected: all pass (new file 2 runs; discovery + hydration files unchanged and green).

- [ ] **Step 5: Render smoke check**

Run: `bin/rails runner 'ApplicationController.render(template: "admin/money/payable_qbo_bills", assigns: {qbo_accounts: [], summary_by_account: {}, rows: [], active_qa: nil, unsettled_total: 0, unsettled_count: 0, pending_task_counts_by_contributor: {}}) rescue puts $!.message'`
Expected: renders (or fails only on something unrelated to the new code — the empty-accounts branch skips the group loop; the check is that the template compiles). If ActiveAdmin layout constraints make this impractical, run `bin/rails runner 'ERB.new(File.read("app/views/admin/money/payable_qbo_bills.html.erb"), trim_mode: "-").src'` to prove the template parses, and note it in the report.

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/task_builder.rb app/admin/money.rb app/views/admin/money/payable_qbo_bills.html.erb test/lib/stacks/task_builder/task_count_for_test.rb
git commit -m "feat: pending-tasks pill on payable QBO bills groups"
```
