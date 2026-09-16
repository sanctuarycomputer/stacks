# Project Capsule Opt-Out Sign-Off Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Project Capsule that opts out of any close-out obligation stay incomplete until an admin signs off, without changing any existing metric.

**Architecture:** `ProjectCapsule#complete?` is purely derived today. We keep it derived and add two conditions — a survey-URL proof and an admin signature whose validity is computed from a persisted list of the selections the admin approved. Because the gate changes `complete?`, and `complete?` currently feeds compensation math, we first extract `substantively_complete?` (today's exact `complete?` bar) and repoint the metrics at it, so the gate can never move a number.

**Tech Stack:** Rails 6.1.7.10, Ruby 3.1.7, PostgreSQL, ActiveAdmin, Minitest + Mocha.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-09-16-project-capsule-opt-out-sign-off-design.md`. Read it before Task 1.
- **Work in this worktree only:** `/Users/hhff/Documents/Code/stacks/.worktrees/capsule-opt-out-sign-off`, branch `feat/capsule-opt-out-sign-off`. Run `git branch --show-current` before your first commit and confirm it prints `feat/capsule-opt-out-sign-off`. Never `cd` to `/Users/hhff/Documents/Code/stacks`.
- **`db/schema.rb` is hand-curated** in this repo. Never run `db:migrate` expecting a correct dump — edit `schema.rb` by hand to match, including the `version:` and any index/foreign-key lines.
- **Run tests with:** `bin/rails test <path>`. The test DB is `stacks_test` and is shared with the main checkout — never run two suites at once.
- **Never run the full suite without excluding** `test/lib/tasks/etl_rake_test.rb` — its `sync_meet` test makes a live Google call and can hang the run for ~73 minutes.
- **Enum key typo is intentional:** `opt_out_out_of_publishing_a_case_study` has a doubled "out". Copy it exactly; do not "fix" it.
- **Grace period:** `NO_RESPONSE_GRACE_PERIOD = 4.weeks`.
- **Selection keys** are exactly: `client_feedback_survey`, `client_feedback_no_response`, `internal_marketing`, `capsule_sharing`, `satisfaction_survey`.
- **Do not** add `admin_signed_off_at`, `admin_signed_off_by_id`, `admin_signed_off_selections`, or `sign_off_exempt` to `permit_params`.
- Commit after every task. Use `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` as the last line of each commit message.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `db/migrate/20260916000001_add_admin_sign_off_to_project_capsules.rb` | New columns + backfill | 1 |
| `db/schema.rb` | Hand-curated schema mirror | 1 |
| `app/models/project_capsule.rb` | Scope rename, `substantively_complete?`, all gating logic | 2, 4 |
| `app/models/project_tracker.rb` | Delegate status check; decouple `considered_successful?`; `inverse_of` | 2, 3, 7 |
| `app/models/studio.rb` | Decouple satisfaction score | 3 |
| `app/models/admin_authorization.rb` | Admin-only sign-off actions | 5 |
| `app/admin/project_capsules.rb` | Sign-off member actions, action items, warning panel | 6 |
| `app/admin/project_trackers.rb` | "Needs sign-off" scope | 8 |
| `app/views/admin/project_trackers/_show.html.erb` | Pill + per-row sign-off notes | 8 |
| `app/models/stacks_task.rb` | New humanized task type | 7 |
| `lib/stacks/task_builder/discoveries/project_trackers.rb` | Emit + route the sign-off task | 7 |
| `test/models/project_capsule_test.rb` | **New.** Gating logic | 2, 4 |
| `test/models/project_tracker_test.rb` | Metric decoupling regressions | 3 |
| `test/models/studio_test.rb` | Satisfaction score regression (Task 3 Step 5) | 3 |
| `test/models/admin_authorization_test.rb` | Sign-off authorization | 5 |
| `test/integration/admin_project_capsule_sign_off_test.rb` | **New.** Page renders; sign-off / revoke; lead is refused | 6 |
| `test/lib/stacks/task_builder/discoveries/project_trackers_test.rb` | **New.** Nag routing | 7 |

---

### Task 1: Migration and schema

**Files:**
- Create: `db/migrate/20260916000001_add_admin_sign_off_to_project_capsules.rb`
- Modify: `db/schema.rb` (version line 13; `project_capsules` table at line 917; foreign-key block near line 1423)

**Interfaces:**
- Consumes: nothing.
- Produces: columns `admin_signed_off_at` (datetime, nullable), `admin_signed_off_by_id` (bigint, nullable, FK to `admin_users`), `admin_signed_off_selections` (string array, `null: false, default: []`), `sign_off_exempt` (boolean, `null: false, default: false`).

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260916000001_add_admin_sign_off_to_project_capsules.rb`:

```ruby
class AddAdminSignOffToProjectCapsules < ActiveRecord::Migration[6.1]
  def up
    add_column :project_capsules, :admin_signed_off_at, :datetime
    add_reference :project_capsules, :admin_signed_off_by,
      foreign_key: { to_table: :admin_users }, null: true
    add_column :project_capsules, :admin_signed_off_selections, :string,
      array: true, null: false, default: []
    add_column :project_capsules, :sign_off_exempt, :boolean,
      null: false, default: false

    # Grandfather capsules whose close-out decisions are already made — the exact
    # set that would otherwise flip from Complete back to Pending. Capsules with
    # statuses still blank are already Pending, so gating them reopens nothing.
    # Raw SQL, not the model, so this can't break if ProjectCapsule's callbacks
    # change later.
    execute <<~SQL
      UPDATE project_capsules SET sign_off_exempt = true
      WHERE client_feedback_survey_status       IS NOT NULL
        AND internal_marketing_status           IS NOT NULL
        AND capsule_status                      IS NOT NULL
        AND project_satisfaction_survey_status  IS NOT NULL;
    SQL
  end

  def down
    remove_column :project_capsules, :sign_off_exempt
    remove_column :project_capsules, :admin_signed_off_selections
    remove_reference :project_capsules, :admin_signed_off_by
    remove_column :project_capsules, :admin_signed_off_at
  end
end
```

- [ ] **Step 2: Hand-edit `db/schema.rb`**

Change line 13 from `ActiveRecord::Schema.define(version: 2026_08_04_000001) do` to:

```ruby
ActiveRecord::Schema.define(version: 2026_09_16_000001) do
```

In the `create_table "project_capsules"` block (line 917), add the four columns after `t.integer "project_satisfaction_survey_status"` and add the new index line after the existing index:

```ruby
    t.integer "project_satisfaction_survey_status"
    t.datetime "admin_signed_off_at"
    t.bigint "admin_signed_off_by_id"
    t.string "admin_signed_off_selections", default: [], null: false, array: true
    t.boolean "sign_off_exempt", default: false, null: false
    t.index ["admin_signed_off_by_id"], name: "index_project_capsules_on_admin_signed_off_by_id"
    t.index ["project_tracker_id"], name: "index_project_capsules_on_project_tracker_id"
  end
```

Insert this as **line 1500**, immediately *before* the existing `add_foreign_key "project_capsules", "project_trackers"`:

```ruby
  add_foreign_key "project_capsules", "admin_users", column: "admin_signed_off_by_id"
```

- [ ] **Step 3: Apply the migration to the development database**

Run: `bin/rails db:migrate`

Rails will rewrite `db/schema.rb` from the database. That dump is **not** authoritative here — this repo's `schema.rb` is hand-curated and deliberately omits things the dumper can't represent (pgvector, generated columns). Immediately after migrating:

```bash
git diff db/schema.rb
```

Keep only your Step 2 edits. Revert anything else the dumper added or removed (`git checkout -p db/schema.rb`, or restore and re-apply Step 2 by hand). Confirm with `git diff db/schema.rb` that the final diff is exactly: the `version:` bump, four new `t.` lines, one new `t.index` line, one new `add_foreign_key` line.

- [ ] **Step 4: Apply the schema to the test database**

Run:
```bash
bin/rails db:environment:set RAILS_ENV=test
bin/rails db:test:prepare
```
Expected: no output, exit 0.

- [ ] **Step 5: Verify the columns and defaults landed**

Run:
```bash
bin/rails runner -e test 'c = ProjectCapsule.new; puts c.sign_off_exempt.inspect; puts c.admin_signed_off_selections.inspect; puts ProjectCapsule.column_names.grep(/sign/).sort.inspect'
```
Expected output:
```
false
[]
["admin_signed_off_at", "admin_signed_off_by_id", "admin_signed_off_selections", "sign_off_exempt"]
```

- [ ] **Step 6: Verify the backfill predicate against the dev database**

This is a read-only sanity check that the `WHERE` clause selects the intended population. Run:
```bash
bin/rails runner -e development 'exempted = ProjectCapsule.where.not(client_feedback_survey_status: nil).where.not(internal_marketing_status: nil).where.not(capsule_status: nil).where.not(project_satisfaction_survey_status: nil).count; puts "would exempt: #{exempted}"; puts "total: #{ProjectCapsule.count}"'
```
Expected: two integers, the first ≤ the second. Record both numbers in the commit message. If the first is `0` and the second is large, stop and report — the predicate is likely wrong.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260916000001_add_admin_sign_off_to_project_capsules.rb db/schema.rb
git commit -m "feat: add admin sign-off columns to project capsules

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Rename the status scope and extract `substantively_complete?`

Pure refactor. No behaviour changes anywhere — this task exists so Task 3 has something to point at.

**Files:**
- Modify: `app/models/project_capsule.rb:8` (scope), `:42` (`complete?`)
- Modify: `app/models/project_tracker.rb:67` (scope body), `:282` (`capsule_complete_by_statuses?`)
- Create: `test/models/project_capsule_test.rb`

**Interfaces:**
- Consumes: Task 1's columns (not used yet).
- Produces: `ProjectCapsule.all_statuses_set` (scope), `ProjectCapsule#all_statuses_set?` → Boolean, `ProjectCapsule#substantively_complete?` → Boolean. `substantively_complete?` is byte-identical to the pre-change `complete?` and is what Task 3 consumes.

- [ ] **Step 1: Write the failing test**

Create `test/models/project_capsule_test.rb`:

```ruby
require "test_helper"

class ProjectCapsuleTest < ActiveSupport::TestCase
  def make_tracker!(work_completed_at: 2.months.ago)
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:work_completed_at, work_completed_at)
    pt
  end

  # A capsule with every close-out obligation genuinely satisfied.
  def make_honest_capsule!(tracker: nil)
    tracker ||= make_tracker!
    capsule = ProjectCapsule.create!(
      project_tracker: tracker,
      client_feedback_survey_status: :client_feedback_survey_received_and_shared_with_project_team,
      client_feedback_survey_url: "https://www.notion.so/garden3d/response-abc123",
      internal_marketing_status: :case_study_scheduled_with_communications_team,
      capsule_status: :project_capsule_shared_with_garden3d_on_twist,
      project_satisfaction_survey_status: :internal_project_team_satisfaction_survey_created,
      client_satisfaction_status: :satisfied,
    )
    survey = ProjectSatisfactionSurvey.create!(
      project_capsule: capsule,
      title: "Survey",
      description: "Description",
    )
    survey.update!(closed_at: DateTime.now)
    capsule.reload
  end

  test "all_statuses_set? is true only when all four close-out enums are set" do
    capsule = ProjectCapsule.create!(project_tracker: make_tracker!)
    assert_not capsule.all_statuses_set?

    capsule.update!(
      client_feedback_survey_status: :no_response_from_client,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
    )
    assert_not capsule.all_statuses_set?

    capsule.update!(project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey)
    assert capsule.all_statuses_set?
  end

  test "the all_statuses_set scope agrees with all_statuses_set? on the same records" do
    partial = ProjectCapsule.create!(
      project_tracker: make_tracker!,
      client_feedback_survey_status: :no_response_from_client,
    )
    full = make_honest_capsule!

    scoped_ids = ProjectCapsule.all_statuses_set.pluck(:id)
    assert_includes scoped_ids, full.id
    assert_not_includes scoped_ids, partial.id
    assert_equal full.all_statuses_set?, scoped_ids.include?(full.id)
    assert_equal partial.all_statuses_set?, scoped_ids.include?(partial.id)
  end

  test "substantively_complete? is true for a fully honest capsule" do
    assert make_honest_capsule!.substantively_complete?
  end

  test "substantively_complete? is false when client satisfaction is unset" do
    capsule = make_honest_capsule!
    capsule.update!(client_satisfaction_status: nil)
    assert_not capsule.substantively_complete?
  end

  test "substantively_complete? is false when the satisfaction survey is still open" do
    capsule = make_honest_capsule!
    capsule.project_satisfaction_survey.update!(closed_at: nil)
    assert_not capsule.reload.substantively_complete?
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/project_capsule_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'all_statuses_set?'`.

- [ ] **Step 3: Rename the scope and add the two methods**

In `app/models/project_capsule.rb`, replace the `scope :complete` block:

```ruby
  # The four close-out enums being filled in at all. NOT the same as #complete?,
  # which additionally requires client satisfaction, a closed satisfaction survey,
  # survey-URL proof, and admin sign-off on any opt-outs.
  scope :all_statuses_set, -> {
    self
      .where.not(client_feedback_survey_status: nil)
      .where.not(internal_marketing_status: nil)
      .where.not(capsule_status: nil)
      .where.not(project_satisfaction_survey_status: nil)
  }
```

Replace the body of `complete?` and add the two new methods above it:

```ruby
  def all_statuses_set?
    client_feedback_survey_status.present? &&
    internal_marketing_status.present? &&
    capsule_status.present? &&
    project_satisfaction_survey_status.present?
  end

  # The close-out bar as it stood before bypass protections existed. Metrics that
  # feed compensation and OKRs read THIS, not #complete?, so that gating a capsule
  # can never move a number. See the spec, §6.
  def substantively_complete?
    all_statuses_set? &&
    client_satisfaction_status.present? &&
    project_satisfaction_survey_status_valid?
  end

  def complete?
    substantively_complete?
  end
```

- [ ] **Step 4: Update the two callers**

In `app/models/project_tracker.rb:67`, change `ProjectCapsule.complete` to `ProjectCapsule.all_statuses_set`:

```ruby
  scope :complete, -> {
    where.not(work_completed_at: nil)
      .includes(:project_capsule).where(
        project_capsules: { id: ProjectCapsule.all_statuses_set }
      )
  }
```

Replace `capsule_complete_by_statuses?` (`:282`) with a delegation. Keep it `private def`, and keep the `!!` so it returns `false` rather than `nil` when there's no capsule:

```ruby
  private def capsule_complete_by_statuses?
    !!project_capsule&.all_statuses_set?
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/project_capsule_test.rb test/models/project_tracker_test.rb test/models/project_satisfaction_survey_test.rb`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 6: Confirm no stale references to the old scope name remain**

Run: `grep -rn "ProjectCapsule\.complete\b" app lib test`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add app/models/project_capsule.rb app/models/project_tracker.rb test/models/project_capsule_test.rb
git commit -m "refactor: rename ProjectCapsule.complete to .all_statuses_set, extract substantively_complete?

The scope checked only the four close-out enums while #complete? checked far
more, so they shared a name and meant different things. ProjectTracker had a
hand-copied Ruby twin of the scope; it now delegates. substantively_complete?
captures today's completion bar so metrics can be decoupled from the incoming
sign-off gate. No behaviour change.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Decouple metrics from `complete?`

**This task must land before Task 4.** Once Task 4 gates `complete?`, any metric still reading it would silently change. This task moves those metrics onto `substantively_complete?` first, while `complete?` and `substantively_complete?` are still identical — so these tests pass both before and after Task 4, which is exactly what makes them a regression net.

**Files:**
- Modify: `app/models/project_tracker.rb:328-334` (`considered_successful?`)
- Modify: `app/models/studio.rb:489-491` (`project_satisfaction_score` filter)
- Modify: `test/models/project_tracker_test.rb` (insert before the final `end`)

**Interfaces:**
- Consumes: `ProjectCapsule#substantively_complete?` from Task 2.
- Produces: no new public API. `ProjectTracker#considered_successful?` keeps its signature and its current return values.

- [ ] **Step 1: Write the failing test**

Insert the following **before the final `end`** of `test/models/project_tracker_test.rb` (the file closes the class on its last line — a literal append produces a SyntaxError):

```ruby
  # --- metric decoupling (spec §6) ---------------------------------------
  # considered_successful? feeds PSU allocation (profit_share_pass.rb:216) and
  # Studio OKR metrics. It must depend on the substantive close-out bar, never on
  # whether an admin has signed off a bypass — otherwise opting out of the client
  # survey would DROP the client_satisfied? requirement and pay better than
  # doing the work.
  def make_capsule_for!(tracker, client_satisfaction_status:)
    capsule = ProjectCapsule.create!(
      project_tracker: tracker,
      client_feedback_survey_status: :opt_out_of_sending_client_feedback_survey,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
      client_satisfaction_status: client_satisfaction_status,
    )
    capsule
  end

  test "considered_successful? is false for a dissatisfied client even when the capsule opts out of everything" do
    # after_initialize :set_targets rewrites a 0 target to the 30%/0% defaults
    # (project_tracker.rb:322), so the targets must be forced AFTER save.
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_columns(work_completed_at: 2.months.ago, target_profit_margin: 0, target_free_hours_percent: 100)
    make_capsule_for!(pt, client_satisfaction_status: :dissatisfied)

    assert_not pt.reload.considered_successful?,
      "a dissatisfied client must not read as successful, gated or not"
  end

  test "considered_successful? is true for a satisfied client with a substantively complete capsule" do
    # after_initialize :set_targets rewrites a 0 target to the 30%/0% defaults
    # (project_tracker.rb:322), so the targets must be forced AFTER save.
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_columns(work_completed_at: 2.months.ago, target_profit_margin: 0, target_free_hours_percent: 100)
    make_capsule_for!(pt, client_satisfaction_status: :satisfied)

    assert pt.reload.considered_successful?
  end

  test "considered_successful? ignores client satisfaction when the capsule is not substantively complete" do
    # after_initialize :set_targets rewrites a 0 target to the 30%/0% defaults
    # (project_tracker.rb:322), so the targets must be forced AFTER save.
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_columns(work_completed_at: 2.months.ago, target_profit_margin: 0, target_free_hours_percent: 100)
    ProjectCapsule.create!(project_tracker: pt, client_satisfaction_status: :dissatisfied)

    # Half-filled capsule: the pre-existing "in flight" branch, which deliberately
    # scores only on margin + free hours.
    assert pt.reload.considered_successful?
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/project_tracker_test.rb`

**Expected: PASS, 0 failures.** This is deliberate and is NOT a broken TDD cycle — do not "fix" anything. At this point `complete?` and `substantively_complete?` are still identical, so these tests describe behaviour that already holds. Their job is to be the regression net that catches Task 4 if the gate leaks into the metrics. Record the green and continue.

- [ ] **Step 3: Repoint `considered_successful?`**

In `app/models/project_tracker.rb`, replace:

```ruby
  def considered_successful?
    if work_status == :complete
```

with:

```ruby
  def considered_successful?
    # Deliberately NOT `work_status == :complete`: work_status folds in the admin
    # sign-off gate, and a gated capsule would fall to the else branch and lose the
    # client_satisfied? requirement — making a bypass score better than compliance.
    # This is the substantive close-out bar only. See the spec, §6.
    if work_completed_at.present? && !!project_capsule&.substantively_complete?
```

Leave the two branch bodies and the `end` exactly as they are.

- [ ] **Step 4: Repoint the studio satisfaction score**

In `app/models/studio.rb`, in `project_satisfaction_score`, change the `select` block from `pt.capsule_complete?` to `pt.project_capsule&.substantively_complete?`:

```ruby
    completed_projects_in_period = ProjectTracker
      .includes(project_capsule: {project_satisfaction_survey: :project_satisfaction_survey_responses})
      .where(work_completed_at: period.starts_at..period.ends_at)
      .select{|pt| pt.project_capsule&.substantively_complete? && pt.project_capsule.project_satisfaction_survey.present? && pt.project_capsule.project_satisfaction_survey.closed?}
```

- [ ] **Step 5: Write the Studio satisfaction-score regression test**

`project_satisfaction_score` is a **local variable** inside `key_datapoints_for_period` (`app/models/studio.rb:454`, assigned at `:493`), not a method — reach it through that call. It is exposed in the returned hash under the key **`:project_satisfaction`** (`studio.rb:563`), not `:project_satisfaction_score`. Follow the existing shape at `test/models/studio_test.rb:134`.

Insert before the final `end` of `test/models/studio_test.rb`:

```ruby
  # A capsule awaiting opt-out sign-off must still count toward the period's
  # satisfaction score: the survey is closed and answered, and whether an admin
  # has signed a bypass says nothing about how the team rated the project.
  test "project satisfaction score still counts a project whose capsule awaits sign-off" do
    studio = Studio.create!(name: "garden3d", mini_name: "g3d", accounting_prefix: "")
    studio.stubs(:profit_and_loss_for_period).returns(
      { income: 0.0, cost_of_goods_sold: 0.0, expenses: 0.0, net_operating_income: 0.0 }
    )
    period = Stacks::Period.new("Jan 2025", Date.new(2025, 1, 1), Date.new(2025, 1, 31))

    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:work_completed_at, Date.new(2025, 1, 15))

    capsule = ProjectCapsule.create!(
      project_tracker: pt,
      client_feedback_survey_status: :opt_out_of_sending_client_feedback_survey,
      internal_marketing_status: :case_study_scheduled_with_communications_team,
      capsule_status: :project_capsule_shared_with_garden3d_on_twist,
      project_satisfaction_survey_status: :internal_project_team_satisfaction_survey_created,
      client_satisfaction_status: :satisfied,
    )
    survey = ProjectSatisfactionSurvey.create!(
      project_capsule: capsule, title: "Survey", description: "Description"
    )
    # A response is REQUIRED, not incidental: studio.rb:495 calls
    # `survey.results[:overall]`, and #results returns nil when there are no
    # responses (project_satisfaction_survey.rb:113) - so a response-less survey
    # raises NoMethodError precisely when the project IS included, which would
    # invert what this test proves.
    ProjectSatisfactionSurveyResponse.create!(project_satisfaction_survey: survey)
    survey.update!(closed_at: DateTime.new(2025, 1, 20))

    assert capsule.reload.substantively_complete?,
      "fixture must be substantively complete for this test to mean anything"
    # NOTE: this fixture is not yet GATED - complete? is still an alias for
    # substantively_complete? until Task 4 lands. Task 4 adds the assertion that
    # it is gated, at which point this test becomes a real regression net: the
    # opt_out_of_sending_client_feedback_survey status above will then require
    # sign-off, so the capsule will be incomplete but must STILL be counted here.

    data = studio.key_datapoints_for_period(
      period, nil, "cash", [studio], [], {}, {}, {}, {},
      Stacks::ClientRevenue.new(studio, [studio], [])
    )

    # If the filter regressed to complete?, completed_projects_in_period would be
    # empty and the score would stay nil.
    assert_not_nil data[:project_satisfaction_score][:value],
      "a gated capsule with a closed, answered survey must still count"
  end
```

If `key_datapoints_for_period`'s positional arity differs from the call above, copy the argument list from `test/models/studio_test.rb:143-155` verbatim — that test is known-passing.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/project_tracker_test.rb test/models/studio_test.rb test/models/profit_share_test.rb`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add app/models/project_tracker.rb app/models/studio.rb test/models/project_tracker_test.rb test/models/studio_test.rb
git commit -m "refactor: decouple success and satisfaction metrics from capsule complete?

considered_successful? branched on work_status == :complete. Once the sign-off
gate lands, a gated capsule falls to the else branch, which DROPS the
client_satisfied? requirement - so bypassing the client survey on an unhappy
project would have scored better than doing the work, and that value feeds PSU
allocation. Both it and Studio#project_satisfaction_score now read
substantively_complete?, which is identical to today's bar. No behaviour change;
the new tests are the regression net for the next commit.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The gate

**Files:**
- Modify: `app/models/project_capsule.rb`
- Modify: `test/models/project_capsule_test.rb` (insert before the final `end`)

**Interfaces:**
- Consumes: Task 1 columns; `substantively_complete?` and `all_statuses_set?` from Task 2.
- Produces:
  - `ProjectCapsule::NO_RESPONSE_GRACE_PERIOD` → `4.weeks`
  - `ProjectCapsule::GATED_SELECTION_LABELS` → `Hash{String => String}`, frozen
  - `#gated_selections` → `Array<String>` (stable keys)
  - `#gated_selection_labels` → `Array<String>` (prose, for the UI)
  - `#requires_admin_sign_off?` → Boolean
  - `#admin_sign_off_satisfied?` → Boolean
  - `#client_feedback_survey_url_valid?` → Boolean
  - `#complete_but_for_admin_sign_off?` → Boolean (Task 7 consumes this)
  - `#complete?` → Boolean (now gated)

- [ ] **Step 1: Write the failing test**

Insert the following **before the final `end`** of `test/models/project_capsule_test.rb` (a literal append produces a SyntaxError):

```ruby
  # --- the gate (spec §4, §5) --------------------------------------------

  # An otherwise-complete capsule that opts out of exactly one obligation.
  def make_gated_capsule!(field, value, tracker: nil)
    capsule = make_honest_capsule!(tracker: tracker)
    capsule.update!(field => value)
    capsule.reload
  end

  test "each of the four opt-outs blocks completion until an admin signs off" do
    {
      client_feedback_survey_status: :opt_out_of_sending_client_feedback_survey,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
    }.each do |field, value|
      capsule = make_gated_capsule!(field, value)
      assert capsule.requires_admin_sign_off?, "#{field} should require sign-off"
      assert_not capsule.complete?, "#{field} should block completion"
      assert capsule.complete_but_for_admin_sign_off?, "#{field} should be complete but for sign-off"

      capsule.update!(
        admin_signed_off_at: DateTime.now,
        admin_signed_off_selections: capsule.gated_selections,
      )
      assert capsule.complete?, "#{field} should complete once signed off"
      assert_not capsule.complete_but_for_admin_sign_off?
    end
  end

  test "an honest capsule completes with no sign-off at all" do
    capsule = make_honest_capsule!
    assert_not capsule.requires_admin_sign_off?
    assert capsule.complete?
    assert_nil capsule.admin_signed_off_at
  end

  test "sign-off survives the lead REMOVING an approved opt-out" do
    capsule = make_honest_capsule!
    capsule.update!(
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
    )
    assert_equal %w[internal_marketing capsule_sharing].sort, capsule.gated_selections.sort
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_selections: capsule.gated_selections,
    )
    assert capsule.complete?

    # Lead goes and does the real thing for one of them.
    capsule.update!(capsule_status: :project_capsule_shared_with_garden3d_on_twist)
    assert capsule.reload.complete?, "removing an approved opt-out must not void the signature"
  end

  test "sign-off is void when the lead SWAPS in an unapproved opt-out" do
    capsule = make_gated_capsule!(:internal_marketing_status, :opt_out_out_of_publishing_a_case_study)
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_selections: capsule.gated_selections,
    )
    assert capsule.complete?

    capsule.update!(
      internal_marketing_status: :case_study_scheduled_with_communications_team,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
    )
    assert_not capsule.reload.complete?, "an unapproved selection must re-block the capsule"
  end

  test "update_column cannot preserve a stale signature" do
    capsule = make_gated_capsule!(:project_satisfaction_survey_status, :opt_out_of_internal_project_team_satisfaction_survey)
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_selections: capsule.gated_selections,
    )
    assert capsule.complete?

    # Callback-free write, as ProjectSatisfactionSurvey#reset_project_capsule_survey_flow does.
    capsule.update_column(:capsule_status, ProjectCapsule.capsule_statuses[:opt_out_of_sharing_project_capsule_with_garden3d])
    assert_not capsule.reload.complete?, "a derived gate must not be bypassable via update_column"
  end

  test "creating the internal satisfaction survey does not void an unrelated approval" do
    # Gated on TWO things; the admin approves both. Then the lead does the honest
    # thing for one of them, which is the exact update! at
    # app/admin/project_satisfaction_surveys.rb:161. A naive callback-based
    # invalidation would revoke the signature here and force a re-signature.
    capsule = make_honest_capsule!
    capsule.update!(
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
    )
    assert_equal %w[internal_marketing satisfaction_survey].sort, capsule.gated_selections.sort
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_selections: capsule.gated_selections,
    )
    assert capsule.complete?

    capsule.update!(project_satisfaction_survey_status: :internal_project_team_satisfaction_survey_created)
    assert capsule.reload.complete?, "honest work must not force a re-signature"
  end

  test "no_response_from_client is free inside the grace period and gated after it" do
    inside = make_gated_capsule!(
      :client_feedback_survey_status, :no_response_from_client,
      tracker: make_tracker!(work_completed_at: 3.weeks.ago),
    )
    assert_not inside.requires_admin_sign_off?
    assert inside.complete?

    outside = make_gated_capsule!(
      :client_feedback_survey_status, :no_response_from_client,
      tracker: make_tracker!(work_completed_at: 5.weeks.ago),
    )
    assert_equal ["client_feedback_no_response"], outside.gated_selections
    assert_not outside.complete?
  end

  test "the grace clock cannot be reset by uncompleting and recompleting the work" do
    tracker = make_tracker!(work_completed_at: 5.weeks.ago)
    capsule = make_gated_capsule!(:client_feedback_survey_status, :no_response_from_client, tracker: tracker)
    capsule.update_column(:created_at, 5.weeks.ago)
    assert_not capsule.reload.complete?

    # What app/admin/project_trackers.rb:303-312 does on two clicks.
    tracker.update_column(:work_completed_at, nil)
    tracker.update_column(:work_completed_at, DateTime.now)

    assert_not capsule.reload.complete?,
      "re-wrapping must not buy another grace period"
  end

  test "the grace clock falls back to the capsule created_at when work_completed_at is nil" do
    tracker = make_tracker!(work_completed_at: nil)
    capsule = make_gated_capsule!(:client_feedback_survey_status, :no_response_from_client, tracker: tracker)
    capsule.update_column(:created_at, 5.weeks.ago)
    assert_not capsule.reload.complete?
  end

  test "claiming the client responded requires a well-formed survey url" do
    capsule = make_honest_capsule!
    assert capsule.complete?

    capsule.update!(client_feedback_survey_url: nil)
    assert_not capsule.reload.complete?, "a blank url is not proof"

    capsule.update!(client_feedback_survey_url: "n/a")
    assert_not capsule.reload.complete?, "'n/a' is not proof"

    capsule.update!(client_feedback_survey_url: "https://www.notion.so/garden3d/resp")
    assert capsule.reload.complete?
  end

  test "sign_off_exempt bypasses both the sign-off gate and the url proof" do
    capsule = make_gated_capsule!(:internal_marketing_status, :opt_out_out_of_publishing_a_case_study)
    capsule.update!(sign_off_exempt: true, client_feedback_survey_url: nil)

    assert_empty capsule.gated_selections
    assert_not capsule.requires_admin_sign_off?
    assert capsule.complete?
  end

  test "complete_but_for_admin_sign_off? is false while other requirements are unmet" do
    capsule = make_gated_capsule!(:internal_marketing_status, :opt_out_out_of_publishing_a_case_study)
    capsule.update!(client_satisfaction_status: nil)

    assert capsule.requires_admin_sign_off?
    assert_not capsule.complete?
    assert_not capsule.complete_but_for_admin_sign_off?,
      "don't nag admins about a capsule the lead hasn't finished"
  end

  test "gated_selection_labels renders prose for every key" do
    capsule = make_gated_capsule!(:capsule_status, :opt_out_of_sharing_project_capsule_with_garden3d)
    assert_equal ["Sharing the capsule with garden3d"], capsule.gated_selection_labels
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/project_capsule_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'requires_admin_sign_off?'`.

- [ ] **Step 3: Implement the gate**

In `app/models/project_capsule.rb`, add the association under the existing `belongs_to :project_tracker`:

```ruby
  belongs_to :admin_signed_off_by, class_name: "AdminUser", optional: true
```

Add the constants below the `has_one`:

```ruby
  NO_RESPONSE_GRACE_PERIOD = 4.weeks

  # Stable keys, not prose — these are persisted in admin_signed_off_selections,
  # so the wording can change without invalidating existing signatures.
  GATED_SELECTION_LABELS = {
    "client_feedback_survey"      => "Sending a client feedback survey",
    "client_feedback_no_response" => "Chasing an unresponsive client",
    "internal_marketing"          => "Publishing a case study",
    "capsule_sharing"             => "Sharing the capsule with garden3d",
    "satisfaction_survey"         => "The internal team satisfaction survey",
  }.freeze
```

Replace `complete?` (currently `substantively_complete?` alone, from Task 2) and add the rest. Put these public methods after `substantively_complete?`:

```ruby
  def complete?
    completeness_checks_pass? && admin_sign_off_satisfied?
  end

  # True when the lead has done everything they can and only an admin's signature
  # is outstanding. Drives the admin nag — we don't pester admins about a capsule
  # that is still half-filled.
  def complete_but_for_admin_sign_off?
    completeness_checks_pass? && !admin_sign_off_satisfied?
  end

  def gated_selections
    return [] if sign_off_exempt?
    [
      ("client_feedback_survey"      if opt_out_of_sending_client_feedback_survey?),
      ("client_feedback_no_response" if no_response_from_client? && no_response_grace_expired?),
      ("internal_marketing"          if opt_out_out_of_publishing_a_case_study?),
      ("capsule_sharing"             if opt_out_of_sharing_project_capsule_with_garden3d?),
      ("satisfaction_survey"         if opt_out_of_internal_project_team_satisfaction_survey?),
    ].compact
  end

  def gated_selection_labels
    gated_selections.map { |key| GATED_SELECTION_LABELS.fetch(key) }
  end

  def requires_admin_sign_off?
    gated_selections.any?
  end

  # Derived rather than invalidated by a callback, so update_column can't slip a
  # new opt-out under an old signature. Sign-off covers the selections an admin
  # actually saw: still valid if the lead has since REMOVED some (doing the honest
  # thing shouldn't force a re-signature), void the moment a selection appears
  # that nobody approved.
  def admin_sign_off_satisfied?
    return true unless requires_admin_sign_off?
    return false if admin_signed_off_at.blank?
    (gated_selections - admin_signed_off_selections.to_a).empty?
  end

  # Mirrors project_satisfaction_survey_status_valid?: claiming the client
  # responded requires linking their response.
  def client_feedback_survey_url_valid?
    return true if sign_off_exempt?
    return true unless client_feedback_survey_received_and_shared_with_project_team?
    client_feedback_survey_url.to_s.match?(%r{\Ahttps?://\S+\z})
  end

  private

  def completeness_checks_pass?
    substantively_complete? && client_feedback_survey_url_valid?
  end

  # Anchored on the EARLIEST wrap signal we have. work_completed_at alone is
  # resettable: uncomplete_work then complete_work rewrites it to DateTime.now
  # (app/admin/project_trackers.rb:303-312), buying another 4 weeks, repeatably.
  # project_capsules.created_at is immutable and is stamped at the first
  # complete_work, so the earlier of the two can't be pushed forward.
  def no_response_grace_anchor
    [project_tracker&.work_completed_at, created_at].compact.min
  end

  def no_response_grace_expired?
    anchor = no_response_grace_anchor
    anchor.present? && anchor < NO_RESPONSE_GRACE_PERIOD.ago
  end
```

**Placement matters.** `project_satisfaction_survey_status_valid?` is currently public and must stay public. Put the four private methods (`completeness_checks_pass?`, `no_response_grace_anchor`, `no_response_grace_expired?`) and the `private` keyword at the **very bottom of the class**, below `project_satisfaction_survey_status_valid?` — not inline where `complete?` lives. Pasting the block verbatim in the middle of the class would silently privatize it.

Verify afterwards:

```bash
bin/rails runner -e test 'c = ProjectCapsule.new; puts c.respond_to?(:project_satisfaction_survey_status_valid?); puts c.respond_to?(:completeness_checks_pass?)'
```
Expected:
```
true
false
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/project_capsule_test.rb`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 5: Strengthen the Studio regression test now that the gate exists**

Task 3 left a NOTE comment in `test/models/studio_test.rb` saying this assertion belongs here. The gate now exists, so the fixture (which opts out of sending the client feedback survey) is genuinely gated. Replace that NOTE comment block with a real assertion, so the test proves a *gated* capsule still counts rather than merely a complete one:

```ruby
    assert_not capsule.complete?,
      "fixture must be GATED - otherwise this test passes even if the filter regresses"
```

- [ ] **Step 6: Prove the Studio regression test is no longer vacuous**

At Task 3 this test was structurally vacuous — `complete?` and `substantively_complete?` were identical, so no fixture could make the two filters disagree. The gate you just added is what makes it real. Verify that, don't assume it:

1. Temporarily change `app/models/studio.rb`'s filter back from `pt.project_capsule&.substantively_complete?` to `pt.capsule_complete?`.
2. Run: `bin/rails test test/models/studio_test.rb`
3. **Expected: the "project satisfaction score still counts a project whose capsule awaits sign-off" test now FAILS.** If it still passes, the test is not exercising the regression it claims to and you must report that — do not proceed.
4. Restore the `substantively_complete?` version and confirm green again.

Record both outcomes in your report.

- [ ] **Step 7: Verify Task 3's regression net still holds**

Run: `bin/rails test test/models/project_tracker_test.rb test/models/studio_test.rb test/models/project_satisfaction_survey_test.rb test/models/profit_share_test.rb`
Expected: PASS, 0 failures, 0 errors. **If `considered_successful?` tests now fail, Task 3 was done wrong — stop and fix Task 3 rather than weakening these tests.**

- [ ] **Step 8: Commit**

```bash
git add app/models/project_capsule.rb test/models/project_capsule_test.rb test/models/studio_test.rb
git commit -m "feat: require admin sign-off on project capsule opt-outs

All four opt-outs now block completion until an admin signs off, and
'no response from client' does the same once 4 weeks have passed since the
earliest wrap signal. Claiming the client responded requires a well-formed
survey URL. Sign-off validity is derived from a persisted list of the
selections the admin approved, so update_column can't slip an unapproved
opt-out under an old signature, and a lead who REMOVES an opt-out keeps the
approval instead of needing a new one.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Authorization

**Files:**
- Modify: `app/models/admin_authorization.rb` (the `authorized?` method, before the `can_act_as_lead?` line)
- Modify: `test/models/admin_authorization_test.rb` (insert before the final `end`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `AdminAuthorization#authorized?(:sign_off | :revoke_sign_off, ProjectCapsule | instance)` returns `user.is_admin?`. Task 6's member actions rely on this.

- [ ] **Step 1: Write the failing test**

Insert the following **before the final `end`** of `test/models/admin_authorization_test.rb` (a literal append produces a SyntaxError):

```ruby
  # Sign-off exists to police project leads, so it must not inherit the blanket
  # lead access granted a few lines below in authorized?.
  test "a lead cannot sign off or revoke sign-off on a project capsule" do
    user = make_user("lead@sanctuary.computer")
    pt = make_project_tracker("Gated")
    ProjectLeadPeriod.create!(admin_user: user, project_tracker: pt, started_at: Date.today.beginning_of_month)
    capsule = ProjectCapsule.create!(project_tracker: pt)

    auth = auth_for(user)
    assert auth.authorized?(:update, capsule), "leads still edit capsules normally"
    refute auth.authorized?(:sign_off, capsule)
    refute auth.authorized?(:revoke_sign_off, capsule)
    refute auth.authorized?(:sign_off, ProjectCapsule)
  end

  test "an admin can sign off and revoke sign-off on a project capsule" do
    user = AdminUser.create!(email: "boss@sanctuary.computer", password: "password12345", roles: ["admin"])
    capsule = ProjectCapsule.create!(project_tracker: make_project_tracker("Gated"))

    auth = auth_for(user)
    assert auth.authorized?(:sign_off, capsule)
    assert auth.authorized?(:revoke_sign_off, capsule)
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/admin_authorization_test.rb`
Expected: FAIL on `refute auth.authorized?(:sign_off, capsule)` — currently returns `true` via the `can_act_as_lead?` branch.

- [ ] **Step 3: Add the authorization branch**

In `app/models/admin_authorization.rb`, inside `authorized?`, add this **above** the `return true if (user.is_admin? || user.can_act_as_lead?)` line, next to the existing `ContributorAdjustment` and `ProjectSatisfactionSurvey` branches:

```ruby
    # Opt-out sign-off polices project leads, so it must sit above the blanket
    # lead grant below — otherwise every lead could approve their own bypass.
    if subject.is_a?(ProjectCapsule) || subject == ProjectCapsule
      return user.is_admin? if [:sign_off, :revoke_sign_off].include?(action)
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/admin_authorization_test.rb`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/models/admin_authorization.rb test/models/admin_authorization_test.rb
git commit -m "feat: restrict capsule sign-off actions to admins

authorized? returns true for any can_act_as_lead? user, which is exactly the
population opt-out sign-off is meant to police. Guarding only the ActiveAdmin
action_item would have hidden a link while leaving the POST open.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: ActiveAdmin sign-off actions and warning panel

**Files:**
- Modify: `app/admin/project_capsules.rb`

**Interfaces:**
- Consumes: Task 4's `gated_selections`, `gated_selection_labels`, `requires_admin_sign_off?`, `admin_sign_off_satisfied?`; Task 5's authorization branch.
- Produces: routes `sign_off_admin_project_capsule_path` and `revoke_sign_off_admin_project_capsule_path` (POST).

- [ ] **Step 1: Add the member actions and action items**

In `app/admin/project_capsules.rb`, after the existing `member_action :create_project_satisfaction_survey` block, add:

```ruby
  action_item :sign_off, only: [:edit],
    if: proc { current_admin_user.is_admin? && resource.requires_admin_sign_off? && !resource.admin_sign_off_satisfied? } do
    link_to "✅ Approve Opt-Outs", sign_off_admin_project_capsule_path(resource), method: :post
  end

  action_item :revoke_sign_off, only: [:edit],
    if: proc { current_admin_user.is_admin? && resource.admin_signed_off_at.present? } do
    link_to "Revoke Sign-Off", revoke_sign_off_admin_project_capsule_path(resource), method: :post
  end

  # Defence in depth: AdminAuthorization already restricts :sign_off to admins,
  # but member actions are easy to add without an authorize call, so check here too.
  member_action :sign_off, method: :post do
    unless current_admin_user.is_admin?
      raise ActiveAdmin::AccessDenied.new(current_admin_user, :sign_off, resource)
    end
    resource.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_by: current_admin_user,
      admin_signed_off_selections: resource.gated_selections,
    )
    redirect_to admin_project_tracker_path(resource.project_tracker_id),
      notice: "Opt-outs approved."
  end

  member_action :revoke_sign_off, method: :post do
    unless current_admin_user.is_admin?
      raise ActiveAdmin::AccessDenied.new(current_admin_user, :revoke_sign_off, resource)
    end
    resource.update!(
      admin_signed_off_at: nil,
      admin_signed_off_by: nil,
      admin_signed_off_selections: [],
    )
    redirect_to admin_project_tracker_path(resource.project_tracker_id),
      notice: "Sign-off revoked."
  end
```

- [ ] **Step 2: Add the warning panel to the form**

In the same file, inside `form do |f|`, as the **first** thing inside `f.inputs(class: "admin_inputs") do`, before `f.input :client_feedback_survey_status`:

Use Arbre builders — this repo's idiom for custom markup in an admin DSL (`app/admin/finalizations.rb:97`, `app/admin/contacts.rb:88,104`). **Do not use `f.form_buffers`**: it was removed in ActiveAdmin 2.9.0 (pinned in `Gemfile.lock:59`) and now raises unconditionally at *render* time. Note Arbre has no `p` builder — `p` is `Kernel#p` — so use `para`.

```ruby
      if f.object.requires_admin_sign_off?
        signed_off = f.object.admin_sign_off_satisfied?
        div class: "dashboard-module", style: "pointer-events: auto; margin: 20px 0px;" do
          div class: "module-header", style: "pointer-events: auto;" do
            para(signed_off ? "✅ Opt-outs approved" : "⚠️ This capsule needs admin sign-off")
          end
          div class: "module-body" do
            para "This capsule opts out of:", style: "margin-bottom: 6px;"
            ul do
              f.object.gated_selection_labels.each { |label| li { para label } }
            end
            if signed_off
              approver = f.object.admin_signed_off_by&.email || "an admin"
              para "Approved by #{approver} on #{f.object.admin_signed_off_at.to_date.to_s(:long)}."
            else
              para "An admin must approve these before this capsule counts as complete. If you'd rather not wait, doing the real thing clears it immediately — no approval needed."
            end
          end
        end
      end
```

(`Date#to_s(:long)` is fine on Rails 6.1.7.10 — it's only deprecated from Rails 7.)

- [ ] **Step 3: Verify the admin screen renders**

Run:
```bash
bin/rails runner -e development 'puts Rails.application.routes.url_helpers.sign_off_admin_project_capsule_path(1); puts Rails.application.routes.url_helpers.revoke_sign_off_admin_project_capsule_path(1)'
```
Expected:
```
/admin/project_capsules/1/sign_off
/admin/project_capsules/1/revoke_sign_off
```

- [ ] **Step 4: Write a test that actually RENDERS the page**

A DSL-load check is not enough: `form do |f| … end` is stored as a proc and `instance_eval`'d at render time, so a broken form block still lets the file load and every load-only check goes green while the page 500s. The panel must be exercised by a real request.

Create `test/integration/admin_project_capsule_sign_off_test.rb`:

```ruby
require 'test_helper'

class AdminProjectCapsuleSignOffTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def make_admin!
    AdminUser.create!(email: "boss#{SecureRandom.hex(4)}@sanctuary.computer",
                      password: 'password12345', password_confirmation: 'password12345',
                      roles: ['admin'])
  end

  def make_lead!(tracker)
    user = AdminUser.create!(email: "lead#{SecureRandom.hex(4)}@sanctuary.computer",
                             password: 'password12345', password_confirmation: 'password12345')
    ProjectLeadPeriod.create!(admin_user: user, project_tracker: tracker,
                              started_at: Date.today.beginning_of_month)
    user
  end

  def make_gated_capsule!
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:work_completed_at, 2.months.ago)
    ProjectCapsule.create!(
      project_tracker: pt,
      client_feedback_survey_status: :opt_out_of_sending_client_feedback_survey,
      internal_marketing_status: :case_study_scheduled_with_communications_team,
      capsule_status: :project_capsule_shared_with_garden3d_on_twist,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
      client_satisfaction_status: :satisfied,
    )
  end

  test "the edit page renders the sign-off warning panel for a gated capsule" do
    capsule = make_gated_capsule!
    sign_in make_admin!

    get edit_admin_project_capsule_path(capsule)
    assert_response :success
    assert_includes response.body, "needs admin sign-off"
    assert_includes response.body, "Sending a client feedback survey"
    assert_includes response.body, "The internal team satisfaction survey"
  end

  test "an admin can sign off, and the capsule completes" do
    capsule = make_gated_capsule!
    sign_in make_admin!

    assert_not capsule.complete?
    post sign_off_admin_project_capsule_path(capsule)
    assert_response :redirect

    capsule.reload
    assert capsule.complete?
    assert capsule.admin_signed_off_at.present?
    assert_equal capsule.gated_selections.sort, capsule.admin_signed_off_selections.sort
  end

  test "a project lead cannot sign off their own capsule" do
    capsule = make_gated_capsule!
    sign_in make_lead!(capsule.project_tracker)

    post sign_off_admin_project_capsule_path(capsule)
    assert_not capsule.reload.complete?, "a lead must not be able to approve their own bypass"
    assert_nil capsule.admin_signed_off_at
  end

  test "an admin can revoke a sign-off" do
    capsule = make_gated_capsule!
    sign_in make_admin!
    post sign_off_admin_project_capsule_path(capsule)
    assert capsule.reload.complete?

    post revoke_sign_off_admin_project_capsule_path(capsule)
    capsule.reload
    assert_not capsule.complete?
    assert_nil capsule.admin_signed_off_at
    assert_empty capsule.admin_signed_off_selections
  end
end
```

- [ ] **Step 5: Run the rendering test**

Run: `bin/rails test test/integration/admin_project_capsule_sign_off_test.rb`
Expected: PASS, 0 failures, 0 errors.

If "the edit page renders…" fails with `RuntimeError: 'form_buffers' has been removed`, the Step 2 panel was pasted from an older draft — re-apply the Arbre version above.

For "a project lead cannot sign off": ActiveAdmin turns `AccessDenied` into a redirect with a flash, not a raised error, so assert on the *effect* (capsule unchanged) as written rather than on `assert_raises`. If the response is a redirect and the capsule is unchanged, the test passes.

- [ ] **Step 6: Commit**

```bash
git add app/admin/project_capsules.rb test/integration/admin_project_capsule_sign_off_test.rb
git commit -m "feat: admin sign-off actions and warning panel on project capsules

Covered by an integration test that actually renders the edit page - a
DSL-load check would go green even with a broken form block, since the
form proc is only instance_eval'd at render time.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: The nag

**Files:**
- Modify: `app/models/stacks_task.rb:9` area (`HUMANIZED_TYPES`)
- Modify: `lib/stacks/task_builder/discoveries/project_trackers.rb`
- Modify: `app/models/project_tracker.rb:22` and `app/models/project_capsule.rb` (`inverse_of`)
- Create: `test/lib/stacks/task_builder/discoveries/project_trackers_test.rb`

**Interfaces:**
- Consumes: `ProjectCapsule#complete_but_for_admin_sign_off?` from Task 4.
- Produces: `StacksTask` of type `:project_capsule_needs_admin_sign_off`, owners = `AdminUser.admin` via `Base#task`'s fallback.

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/task_builder/discoveries/project_trackers_test.rb`:

```ruby
require 'test_helper'

class StacksTaskBuilderDiscoveriesProjectTrackersTest < ActiveSupport::TestCase
  def setup
    @admin = AdminUser.create!(email: "admin@sanctuary.computer", password: "passw0rd", roles: ["admin"])
    @lead = AdminUser.create!(email: "lead@sanctuary.computer", password: "passw0rd")
  end

  def discover
    Stacks::TaskBuilder::Discoveries::ProjectTrackers.new(admin_fallback: [@admin]).tasks
  end

  def make_wrapped_tracker!
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:work_completed_at, 2.months.ago)
    ProjectLeadPeriod.create!(admin_user: @lead, project_tracker: pt, started_at: Date.today.beginning_of_month)
    AccountLeadPeriod.create!(admin_user: @lead, project_tracker: pt, started_at: Date.today.beginning_of_month)
    pt
  end

  # Otherwise complete, but opts out of the case study.
  def make_gated_capsule!(tracker)
    capsule = ProjectCapsule.create!(
      project_tracker: tracker,
      client_feedback_survey_status: :client_feedback_survey_received_and_shared_with_project_team,
      client_feedback_survey_url: "https://www.notion.so/garden3d/resp",
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :project_capsule_shared_with_garden3d_on_twist,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
      client_satisfaction_status: :satisfied,
    )
    capsule.reload
  end

  test "a gated capsule nags the admins for sign-off and the lead for completion" do
    pt = make_wrapped_tracker!
    capsule = make_gated_capsule!(pt)
    assert capsule.complete_but_for_admin_sign_off?, "fixture should be complete but for sign-off"

    tasks = discover.select { |t| t.subject.is_a?(ProjectTracker) && t.subject.id == pt.id }

    sign_off = tasks.find { |t| t.type == :project_capsule_needs_admin_sign_off }
    assert sign_off, "expected a project_capsule_needs_admin_sign_off task"
    assert_equal [@admin], sign_off.owners

    incomplete = tasks.find { |t| t.type == :project_capsule_incomplete }
    assert incomplete, "the lead should still be nagged to go do the real thing"
    assert_equal [@lead], incomplete.owners
  end

  test "a signed-off capsule yields neither task" do
    pt = make_wrapped_tracker!
    capsule = make_gated_capsule!(pt)
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_by: @admin,
      admin_signed_off_selections: capsule.gated_selections,
    )

    tasks = discover.select { |t| t.subject.is_a?(ProjectTracker) && t.subject.id == pt.id }
    refute tasks.any? { |t| t.type == :project_capsule_needs_admin_sign_off }
    refute tasks.any? { |t| t.type == :project_capsule_incomplete }
  end

  test "a half-filled capsule nags the lead but not the admins" do
    pt = make_wrapped_tracker!
    ProjectCapsule.create!(
      project_tracker: pt,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
    )

    tasks = discover.select { |t| t.subject.is_a?(ProjectTracker) && t.subject.id == pt.id }
    assert tasks.any? { |t| t.type == :project_capsule_incomplete }
    refute tasks.any? { |t| t.type == :project_capsule_needs_admin_sign_off },
      "don't nag admins about a capsule the lead hasn't finished"
  end

  # Must use a capsule on the no_response path: gated_selections short-circuits
  # (`no_response_from_client? && no_response_grace_expired?`), so a capsule on any
  # other status never dereferences project_tracker and the assertion would be
  # vacuous.
  def make_no_response_capsule!(tracker)
    capsule = make_gated_capsule!(tracker)
    capsule.update!(client_feedback_survey_status: :no_response_from_client)
    tracker.update_column(:work_completed_at, 8.weeks.ago)
    capsule.update_column(:created_at, 8.weeks.ago)
    capsule.reload
  end

  test "the discovery does not fire a query per capsule for its project_tracker" do
    3.times { make_no_response_capsule!(make_wrapped_tracker!) }

    queries = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { discover }
    assert queries < 15, "expected a bounded query count, got #{queries} - check inverse_of / preloading"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/stacks/task_builder/discoveries/project_trackers_test.rb`
Expected: FAIL — `expected a project_capsule_needs_admin_sign_off task`.

- [ ] **Step 3: Register the task type**

In `app/models/stacks_task.rb`, in the `# ProjectTracker issues` group of `HUMANIZED_TYPES`, add after the `project_capsule_incomplete:` line:

```ruby
    project_capsule_needs_admin_sign_off: "Project capsule opt-outs need admin sign-off",
```

- [ ] **Step 4: Emit and route the task**

In `lib/stacks/task_builder/discoveries/project_trackers.rb`, change the `else` branch of `issues_for`:

```ruby
          else
            out << :project_capsule_incomplete if pt.work_status == :capsule_pending
            out << :project_capsule_needs_admin_sign_off if pt.project_capsule&.complete_but_for_admin_sign_off?
          end
```

In `owners_for`, add a branch. Returning an empty array makes `Base#task` substitute `@admin_fallback` (`AdminUser.admin`):

```ruby
          when :project_capsule_needs_admin_sign_off
            # Empty → Base#task falls back to AdminUser.admin. Admins own the call.
            []
```

- [ ] **Step 5: Make the association inverse explicit**

Rails 6.1 already infers this inverse automatically (conventional names, and `dependent:` is not in `INVALID_AUTOMATIC_INVERSE_OPTIONS`), so this is documentation rather than a fix — the query-count test in Step 1 passes either way. Add it so the guarantee the discovery relies on is stated rather than assumed.

In `app/models/project_tracker.rb:22`:

```ruby
  has_one :project_capsule, dependent: :delete, inverse_of: :project_tracker
```

In `app/models/project_capsule.rb`:

```ruby
  belongs_to :project_tracker, inverse_of: :project_capsule
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/lib/stacks/task_builder/discoveries/project_trackers_test.rb test/models/project_capsule_test.rb test/models/project_tracker_test.rb`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add app/models/stacks_task.rb lib/stacks/task_builder/discoveries/project_trackers.rb app/models/project_tracker.rb app/models/project_capsule.rb test/lib/stacks/task_builder/discoveries/project_trackers_test.rb
git commit -m "feat: nag admins when a capsule is complete but for opt-out sign-off

The project lead keeps their existing project_capsule_incomplete task, so both
parties stay on the hook. Adds the first test coverage for this discovery.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Make gated capsules visible

Without this, a gated tracker is filed under the **Complete** tab (the SQL scope sees all four statuses set) while its own page reads Pending — so the lead can't find it. See spec §3.

**Files:**
- Modify: `app/admin/project_trackers.rb` (scope list near line 9-11, plus a scope definition)
- Modify: `app/views/admin/project_trackers/_show.html.erb:32-34`, and the Client Feedback row at `:66-70`

**Interfaces:**
- Consumes: Task 4's `complete_but_for_admin_sign_off?`, `requires_admin_sign_off?`, `client_feedback_survey_url_valid?`.
- Produces: no new API.

- [ ] **Step 1: Add the ActiveAdmin scope**

In `app/admin/project_trackers.rb`, after `scope :complete` (line 11), add:

```ruby
  # Gated capsules have all four statuses set, so the SQL `complete` scope files
  # them under Complete while their own page reads Pending. Give them a home.
  # show_count: false is deliberate. ActiveAdmin computes every scope's count on
  # every index render, and this resource sets config.paginate = false, so a
  # counted Ruby-filtered scope would scan all completed trackers on each load of
  # the default In Progress tab.
  scope :needs_capsule_sign_off, show_count: false do |scope|
    ids = ProjectTracker.complete.select { |pt| pt.project_capsule&.complete_but_for_admin_sign_off? }.map(&:id)
    scope.where(id: ids)
  end
```

- [ ] **Step 2: Show the sign-off state on the pill**

In `app/views/admin/project_trackers/_show.html.erb`, replace lines 32-34:

```erb
  <p class="pill nag <%= project_capsule.complete? ? 'complete' : 'pending' %>" style="margin-bottom: 20px;margin-right: 6px;">
    <%= project_capsule.complete? ? "Complete" : "Pending" %>
  </p>
```

with:

```erb
  <p class="pill nag <%= project_capsule.complete? ? 'complete' : 'pending' %>" style="margin-bottom: 20px;margin-right: 6px;">
    <% if project_capsule.complete? %>
      Complete
    <% elsif project_capsule.complete_but_for_admin_sign_off? %>
      Pending — needs admin sign-off
    <% else %>
      Pending
    <% end %>
  </p>
```

- [ ] **Step 3: Explain a missing survey URL on the Client Feedback row**

In the same file, replace the Client Feedback row body (the `<td class="col text-right">` containing `project_capsule.client_feedback_survey_status.try(:humanize)`):

```erb
              <td class="col text-right">
                <%= project_capsule.client_feedback_survey_status.try(:humanize) %>
                <% unless project_capsule.client_feedback_survey_url_valid? %>
                  <span class="pill error">survey URL missing</span>
                <% end %>
              </td>
```

- [ ] **Step 4: Verify the view and scope load**

Run:
```bash
bin/rails runner -e test 'puts ActiveAdmin.application.namespaces[:admin].resources["ProjectTracker"].scopes.map(&:name).inspect'
```
Expected: an array including `"Needs Capsule Sign Off"` — ActiveAdmin titleizes the symbol (`scope.rb:57`, `@name.to_s.titleize`), so every word is capitalized.

Run: `bin/rails test test/integration 2>&1 | tail -5`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/admin/project_trackers.rb app/views/admin/project_trackers/_show.html.erb
git commit -m "feat: surface capsules awaiting sign-off in the tracker UI

A gated capsule has all four statuses set, so the SQL complete scope files it
under the Complete tab while its page reads Pending - invisible to the lead who
has to act on it. Adds a Needs capsule sign off scope, says why the pill is
pending, and flags a missing client survey URL inline.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Full verification

**Files:** none modified.

- [ ] **Step 1: Run the whole suite, excluding the live-network test**

Run:
```bash
bin/rails test $(find test -name '*_test.rb' ! -path 'test/lib/tasks/etl_rake_test.rb' | sort | tr '\n' ' ') 2>&1 | tail -30
```
Expected: 0 failures, 0 errors. Takes roughly 100 minutes.

- [ ] **Step 2: Triage any failures**

Known environmental failures that are **not** caused by this work:
- `AdminUserTest` salary-window test fails between 20:00 and 24:00 ET.
- Anything requiring pgvector skips rather than fails.

Any other failure must be fixed before the PR. Do not weaken a test to make it pass.

- [ ] **Step 3: Confirm the diff contains nothing unintended**

Run: `git diff main --stat`
Expected: only the files listed in the File Structure table above, plus the two spec/plan documents.

---

## Self-Review Notes

Spec coverage check, section by section:

| Spec section | Task |
|---|---|
| §1 Data model | 1 |
| §2 Backfill predicate | 1 |
| §3 Rename + consumer inventory | 2, 8 |
| §4 Gating logic | 4 |
| §5 Derived (not callback) invalidation | 4 |
| §6 Metric decoupling | 3 |
| §7 Authorization | 5 |
| §8 UI + AA scope | 6, 8 |
| §9 Nagging + `inverse_of` | 7 |
| Testing | every task, plus 9 |
| Non-goals | not implemented, by design |
