# Runn Mirror Implementation Plan (Part 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror Runn assignments, people, and roles into local tables nightly, alongside the existing `runn_projects` mirror, following the Forecast sync's changed-rows-only upsert, prune-by-absence, and advisory-lock patterns.

**Architecture:** Three new tables keyed on `runn_id` (like `runn_projects`), three thin AR models, and three new `sync_*!` methods on `Stacks::Runn` called from a rewritten `sync_all!`. A `System` storext attribute `runn_synced_at` records the last full success.

**Tech Stack:** Rails 6.1, PostgreSQL (btree_gist already enabled), HTTParty, storext, minitest + mocha.

**Spec:** `docs/superpowers/specs/2026-09-08-contributor-payment-projections-design.md` (Part 2).

## Global Constraints

- Work ONLY in the worktree `/Users/hhff/Documents/Code/stacks/.claude/worktrees/feat+contributor-payment-projections`. Never `cd` to `/Users/hhff/Documents/Code/stacks`. Before every commit run `git rev-parse --abbrev-ref HEAD`; if it does not print `worktree-feat+contributor-payment-projections`, STOP and report BLOCKED.
- Assignments are pruned by absence. People and roles are NEVER deleted locally (Runn's `isArchived` is mirrored instead).
- Only rows whose Runn `updatedAt` changed are rewritten (`upsert_changed!`).
- `sync_all!` uses advisory lock key `84_217_296` (Forecast uses `84_217_295`).
- `runn_synced_at` is written through `System.first`, never `System.instance` (which is process-memoized).
- `created_at` / `updated_at` on the mirror tables hold Runn's own timestamps; no Rails `t.timestamps`.
- Migration filenames use 14-digit timestamps: `20260909000002`, `20260909000003`, `20260909000004`.
- `stacks_development` and `stacks_test` are SHARED with the main checkout and every other worktree (`config/database.yml` has no per-worktree naming). Do not run the main checkout's dev server or tests until this branch merges. If this worktree's tests start failing with `PendingMigrationError` or an unknown table, another checkout reloaded the test DB — re-run the Schema procedure's two `RAILS_ENV=test` commands.
- After adding migrations, follow the **Schema procedure** below exactly. `db/schema.rb` is hand-curated in this repo (pgvector and a generated column are deliberately omitted so `schema:load` works without pgvector); a raw dump must not be committed.

## Schema procedure (used by every migration task)

```bash
bin/rails db:migrate
git diff db/schema.rb
```
Keep ONLY: the `ActiveRecord::Schema.define(version: ...)` bump and the new `create_table` blocks / columns / indexes this task adds. Revert everything else the dumper re-emitted: restore the pgvector comment block under `enable_extension`, remove any re-added `enable_extension "vector"`, `t.vector "embedding"`, `hnsw` index, and the `content_tsv` column / GIN index on `chunks` (restore that comment block too). Compare against the last schema commit (`git log -1 -- db/schema.rb`) — the diff must otherwise be byte-identical to HEAD. Then:
```bash
RAILS_ENV=test bin/rails db:environment:set   # test DB lacks ar_internal_metadata.environment; schema:load aborts without this
RAILS_ENV=test bin/rails db:schema:load
```
Expected: schema loads with no error. If `schema:load` fails, the leftover is almost always a re-dumped `content_tsv` DEFAULT or `vector` column — re-check the diff.
- Run targeted test files only.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8
  ```

---

## File map

| File | Responsibility |
|---|---|
| `db/migrate/20260909000002_create_runn_people.rb` (create) | `runn_people` table |
| `db/migrate/20260909000003_create_runn_roles.rb` (create) | `runn_roles` table |
| `db/migrate/20260909000004_create_runn_assignments.rb` (create) | `runn_assignments` table + indexes |
| `app/models/runn_person.rb` (create) | `RunnPerson` |
| `app/models/runn_role.rb` (create) | `RunnRole` |
| `app/models/runn_assignment.rb` (create) | `RunnAssignment`, `working_days_between`, `hours_between`, scopes |
| `app/models/runn_project.rb` (modify) | `has_many :runn_assignments` |
| `app/models/system.rb` (modify) | `runn_synced_at` storext attribute |
| `lib/stacks/runn.rb` (modify) | `sync_all!`, `sync_people!`, `sync_roles!`, `sync_assignments!`, `upsert_changed!`, `prune_assignments_not_in!`, `sync_projects!` fix |
| `test/models/runn_assignment_test.rb` (create) | day counting |
| `test/lib/stacks/runn_sync_test.rb` (create) | sync behavior with stubbed reads |

---

### Task 1: Mirror tables and models

**Files:**
- Create: `db/migrate/20260909000002_create_runn_people.rb`, `db/migrate/20260909000003_create_runn_roles.rb`, `db/migrate/20260909000004_create_runn_assignments.rb`
- Create: `app/models/runn_person.rb`, `app/models/runn_role.rb`, `app/models/runn_assignment.rb`
- Modify: `app/models/runn_project.rb`, `app/models/system.rb`
- Test: `test/models/runn_assignment_test.rb`

**Interfaces:**
- Produces:
  - `RunnPerson` (`primary_key = "runn_id"`; columns `runn_id`, `first_name`, `last_name`, `email`, `is_archived`, `created_at`, `updated_at`, `data`; `has_many :runn_assignments`; `scope :active`; `#contributor`).
  - `RunnRole` (`primary_key = "runn_id"`; `runn_id`, `name`, `standard_rate` (decimal), `default_hour_cost` (decimal), `is_archived`, `created_at`, `updated_at`, `data`; `has_many :runn_assignments`).
  - `RunnAssignment` (`primary_key = "runn_id"`; `runn_id`, `person_id`, `project_id`, `role_id`, `start_date`, `end_date`, `minutes_per_day`, `is_active`, `is_billable`, `is_placeholder`, `is_template`, `is_non_working_day`, `note`, `created_at`, `updated_at`, `data`; `belongs_to :runn_person / :runn_project / :runn_role` (optional); `scope :overlapping(from, to)`, `scope :plannable`; `#working_days_between(from, to)` → Integer; `#hours_between(from, to)` → Float).
  - `RunnProject#runn_assignments`.
  - `System#runn_synced_at` (DateTime or nil, stored in the `settings` jsonb).

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/runn_assignment_test.rb
require "test_helper"

class RunnAssignmentTest < ActiveSupport::TestCase
  def build(start_date:, end_date:, minutes_per_day: 480, is_non_working_day: false)
    RunnAssignment.new(runn_id: 1, person_id: 1, project_id: 1, role_id: 1,
                       start_date: start_date, end_date: end_date,
                       minutes_per_day: minutes_per_day, is_non_working_day: is_non_working_day)
  end

  # 2026-09-07 is a Monday; 2026-09-13 a Sunday.
  test "working_days_between counts Monday to Friday inside the overlap" do
    a = build(start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 13))
    assert_equal 5, a.working_days_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30))
  end

  test "working_days_between clips to the window on both sides" do
    a = build(start_date: Date.new(2026, 8, 24), end_date: Date.new(2026, 10, 9))
    # Sep 2026: 22 weekdays (Sep 1 is a Tuesday, Sep 30 a Wednesday)
    assert_equal 22, a.working_days_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30))
  end

  test "working_days_between is zero when there is no overlap" do
    a = build(start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 5))
    assert_equal 0, a.working_days_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30))
  end

  test "non-working-day assignments count every calendar day" do
    a = build(start_date: Date.new(2026, 9, 12), end_date: Date.new(2026, 9, 13), is_non_working_day: true)
    assert_equal 2, a.working_days_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30))
  end

  test "hours_between multiplies working days by minutes_per_day" do
    a = build(start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 11), minutes_per_day: 120)
    assert_in_delta 10.0, a.hours_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30)), 0.001
  end

  test "overlapping scope finds rows touching the range and plannable excludes templates and inactive rows" do
    RunnAssignment.create!(runn_id: 9001, person_id: 1, project_id: 1, role_id: 1, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 5), minutes_per_day: 60)
    RunnAssignment.create!(runn_id: 9002, person_id: 1, project_id: 1, role_id: 1, start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 5), minutes_per_day: 60)
    RunnAssignment.create!(runn_id: 9003, person_id: 1, project_id: 1, role_id: 1, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 5), minutes_per_day: 60, is_template: true)
    RunnAssignment.create!(runn_id: 9004, person_id: 1, project_id: 1, role_id: 1, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 5), minutes_per_day: 60, is_active: false)

    ids = RunnAssignment.plannable.overlapping(Date.new(2026, 9, 1), Date.new(2026, 9, 30)).pluck(:runn_id)
    assert_equal [9001], ids
  end

  test "associations resolve through runn_id" do
    RunnPerson.create!(runn_id: 501, first_name: "A", last_name: "B", email: "AB@Example.com")
    RunnRole.create!(runn_id: 601, name: "$195.00 p/h", standard_rate: 195, default_hour_cost: 0)
    RunnProject.create!(runn_id: 701, name: "P")
    a = RunnAssignment.create!(runn_id: 9005, person_id: 501, project_id: 701, role_id: 601, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 5), minutes_per_day: 60)
    assert_equal "A", a.runn_person.first_name
    assert_equal 195, a.runn_role.standard_rate
    assert_equal "P", a.runn_project.name
    assert_equal [a], RunnProject.find(701).runn_assignments.to_a
  end

  test "RunnPerson#contributor matches a forecast person by lowercased email" do
    fp = ForecastPerson.create!(forecast_id: 880_001, email: "match-me@example.com", data: {})
    person = RunnPerson.create!(runn_id: 502, first_name: "M", last_name: "E", email: "Match-Me@Example.com")
    assert_equal fp.contributor, person.contributor
    assert_nil RunnPerson.new(runn_id: 503, email: "").contributor
  end

  test "System#runn_synced_at round-trips through settings" do
    s = System.first || System.create!(settings: {})
    assert_nil s.runn_synced_at
    t = Time.current.change(usec: 0)
    s.update!(runn_synced_at: t)
    assert_equal t.to_i, System.first.runn_synced_at.to_i
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/runn_assignment_test.rb`
Expected: FAIL with `NameError: uninitialized constant RunnAssignment`.

- [ ] **Step 3: Write the migrations**

```ruby
# db/migrate/20260909000002_create_runn_people.rb
class CreateRunnPeople < ActiveRecord::Migration[6.1]
  def change
    create_table :runn_people do |t|
      t.bigint :runn_id, null: false
      t.string :first_name
      t.string :last_name
      t.string :email
      t.boolean :is_archived, null: false, default: false
      t.datetime :created_at
      t.datetime :updated_at
      t.jsonb :data
    end
    add_index :runn_people, :runn_id, unique: true
    add_index :runn_people, "lower(email)", name: "index_runn_people_on_lower_email"
  end
end
```

```ruby
# db/migrate/20260909000003_create_runn_roles.rb
class CreateRunnRoles < ActiveRecord::Migration[6.1]
  def change
    create_table :runn_roles do |t|
      t.bigint :runn_id, null: false
      t.string :name
      t.decimal :standard_rate
      t.decimal :default_hour_cost
      t.boolean :is_archived, null: false, default: false
      t.datetime :created_at
      t.datetime :updated_at
      t.jsonb :data
    end
    add_index :runn_roles, :runn_id, unique: true
  end
end
```

```ruby
# db/migrate/20260909000004_create_runn_assignments.rb
class CreateRunnAssignments < ActiveRecord::Migration[6.1]
  def change
    create_table :runn_assignments do |t|
      t.bigint :runn_id, null: false
      t.bigint :person_id
      t.bigint :project_id
      t.bigint :role_id
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :minutes_per_day, null: false, default: 0
      t.boolean :is_active, null: false, default: true
      t.boolean :is_billable, null: false, default: true
      t.boolean :is_placeholder, null: false, default: false
      t.boolean :is_template, null: false, default: false
      t.boolean :is_non_working_day, null: false, default: false
      t.text :note
      t.datetime :created_at
      t.datetime :updated_at
      t.jsonb :data
    end
    add_index :runn_assignments, :runn_id, unique: true
    add_index :runn_assignments, :person_id
    add_index :runn_assignments, :project_id
    add_index :runn_assignments, [:start_date, :end_date], using: :gist, name: "idx_runn_assignments_on_daterange"
  end
end
```

- [ ] **Step 4: Write the models**

```ruby
# app/models/runn_person.rb
# Nightly mirror of Runn people (Stacks::Runn#sync_people!). Never pruned;
# Runn's isArchived is mirrored instead.
class RunnPerson < ApplicationRecord
  self.primary_key = "runn_id"
  has_many :runn_assignments, foreign_key: :person_id, primary_key: :runn_id

  scope :active, -> { where(is_archived: false) }

  # Ad-hoc lookup. The projection engine builds one email index instead of
  # calling this per row.
  def contributor
    return @contributor if defined?(@contributor)
    e = email.to_s.strip.downcase
    @contributor = e.present? ? Contributor.joins(:forecast_person).find_by("lower(forecast_people.email) = ?", e) : nil
  end
end
```

```ruby
# app/models/runn_role.rb
# Nightly mirror of Runn roles. standard_rate is the client BILL rate the
# Forecast->Runn actuals sync writes ("$195.00 p/h" roles); default_hour_cost
# is 0 on those roles. Never pruned.
class RunnRole < ApplicationRecord
  self.primary_key = "runn_id"
  has_many :runn_assignments, foreign_key: :role_id, primary_key: :runn_id
end
```

```ruby
# app/models/runn_assignment.rb
# Nightly mirror of Runn's forward plan (Stacks::Runn#sync_assignments!).
# minutes_per_day applies to each working day in [start_date, end_date]
# (Runn's semantic), except assignments flagged is_non_working_day, which
# cover every calendar day. Pruned by absence on each sync.
class RunnAssignment < ApplicationRecord
  self.primary_key = "runn_id"

  belongs_to :runn_person, foreign_key: :person_id, primary_key: :runn_id, optional: true
  belongs_to :runn_project, foreign_key: :project_id, primary_key: :runn_id, optional: true
  belongs_to :runn_role, foreign_key: :role_id, primary_key: :runn_id, optional: true

  scope :overlapping, ->(from, to) { where("end_date >= ? AND start_date <= ?", from, to) }
  scope :plannable, -> { where(is_template: false, is_active: true) }

  def working_days_between(from, to)
    a = [start_date, from].max
    b = [end_date, to].min
    return 0 if a > b
    return (b - a).to_i + 1 if is_non_working_day
    (a..b).count { |d| (1..5).cover?(d.wday) }
  end

  def hours_between(from, to)
    working_days_between(from, to) * minutes_per_day / 60.0
  end
end
```

In `app/models/runn_project.rb`, after `has_one :project_tracker` add:

```ruby
  has_many :runn_assignments, foreign_key: :project_id, primary_key: :runn_id
```

In `app/models/system.rb`, inside the `store_attributes :settings do ... end` block, after `ghost_synced_sources Array, default: []` add:

```ruby
    # Last time Stacks::Runn#sync_all! completed every table. Read via
    # System.first, not System.instance (process-memoized).
    runn_synced_at DateTime, default: nil
```

- [ ] **Step 5: Migrate, curate the schema dump, reload the test schema, run the test**

Follow the **Schema procedure** in Global Constraints. The curated `db/schema.rb` diff must contain only the version bump to `2026_09_09_000004` and the three new `create_table` blocks (`runn_assignments`, `runn_people`, `runn_roles`), including `t.index ["start_date", "end_date"], name: "idx_runn_assignments_on_daterange", using: :gist` and `t.index "lower((email)::text)", name: "index_runn_people_on_lower_email"` (that is the dumper's form for an expression index — see `idx_optix_users_on_lower_email` already in the file; do not "fix" it).

Then run: `bin/rails test test/models/runn_assignment_test.rb`
Expected: `9 runs, 0 failures, 0 errors`.

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add db/migrate/20260909000002_create_runn_people.rb db/migrate/20260909000003_create_runn_roles.rb db/migrate/20260909000004_create_runn_assignments.rb db/schema.rb app/models/runn_person.rb app/models/runn_role.rb app/models/runn_assignment.rb app/models/runn_project.rb app/models/system.rb test/models/runn_assignment_test.rb
git commit -m "feat: runn_people, runn_roles, runn_assignments mirror tables and models

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 2: `Stacks::Runn` sync methods

**Files:**
- Modify: `lib/stacks/runn.rb` — replace `sync_all!` (:43-49) and `sync_projects!` (:210-233); add `sync_people!`, `sync_roles!`, `sync_assignments!`, `upsert_changed!`, `prune_assignments_not_in!`, `SYNC_ALL_ADVISORY_LOCK_KEY`
- Test: `test/lib/stacks/runn_sync_test.rb`

**Interfaces:**
- Consumes: `RunnPerson`, `RunnRole`, `RunnAssignment`, `RunnProject`, `System#runn_synced_at` (Task 1); existing `get_people`, `get_roles`, `get_assignments`, `get_projects`, `handle_response`.
- Produces: `Stacks::Runn#sync_all!` (lock, four syncs, prune, stamp), `#sync_people!` / `#sync_roles!` / `#sync_assignments!` / `#sync_projects!` (each returns the Array of seen `runn_id`s), `#upsert_changed!(model, rows)` (returns seen ids), `#prune_assignments_not_in!(seen_ids)`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/lib/stacks/runn_sync_test.rb
require "test_helper"

# Covers the local mirror of Runn people / roles / assignments. Reads are
# stubbed on the instance; nothing here touches HTTP.
class Stacks::RunnSyncTest < ActiveSupport::TestCase
  def runn
    r = Stacks::Runn.allocate # skip initialize (needs Runn API config)
    r.instance_variable_set(:@max_retries, 0)
    r.instance_variable_set(:@headers, {})
    r
  end

  def person(id, updated_at: "2026-09-01T00:00:00.000Z", email: "p#{id}@example.com", archived: false)
    { "id" => id, "firstName" => "F#{id}", "lastName" => "L#{id}", "email" => email, "isArchived" => archived,
      "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => updated_at }
  end

  def role(id, updated_at: "2026-09-01T00:00:00.000Z", rate: 195)
    { "id" => id, "name" => "$#{rate}.00 p/h", "standardRate" => rate, "defaultHourCost" => 0, "isArchived" => false,
      "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => updated_at }
  end

  def assignment(id, updated_at: "2026-09-01T00:00:00.000Z", minutes: 480)
    { "id" => id, "personId" => 1, "projectId" => 10, "roleId" => 100, "startDate" => "2026-09-07", "endDate" => "2026-09-11",
      "minutesPerDay" => minutes, "isActive" => true, "note" => "", "isBillable" => true, "phaseId" => nil,
      "isNonWorkingDay" => false, "isTemplate" => false, "isPlaceholder" => false, "workstreamId" => nil,
      "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => updated_at }
  end

  def project(id, updated_at: "2026-09-01T00:00:00.000Z")
    { "id" => id, "name" => "Proj #{id}", "isTemplate" => false, "isArchived" => false, "isConfirmed" => true,
      "pricingModel" => "tm", "rateType" => "role", "budget" => 0, "expensesBudget" => 0,
      "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => updated_at }
  end

  def stub_reads(r, people: [], roles: [], assignments: [], projects: [])
    r.stubs(:get_people).returns(people)
    r.stubs(:get_roles).returns(roles)
    r.stubs(:get_assignments).returns(assignments)
    r.stubs(:get_projects).returns(projects)
    r
  end

  test "sync_people! maps columns, keeps the raw payload, and returns seen ids" do
    ids = runn.sync_people!([person(1, email: "One@Example.com"), person(2, archived: true)])
    assert_equal [1, 2], ids
    p1 = RunnPerson.find(1)
    assert_equal "F1", p1.first_name
    assert_equal "One@Example.com", p1.email
    assert_equal false, p1.is_archived
    assert_equal "One@Example.com", p1.data["email"]
    assert RunnPerson.find(2).is_archived
  end

  test "sync_roles! maps standard_rate and default_hour_cost" do
    runn.sync_roles!([role(100, rate: 225)])
    r = RunnRole.find(100)
    assert_equal 225, r.standard_rate
    assert_equal 0, r.default_hour_cost
    assert_equal "$225.00 p/h", r.name
  end

  test "sync_assignments! maps every column" do
    runn.sync_assignments!([assignment(5000)])
    a = RunnAssignment.find(5000)
    assert_equal 1, a.person_id
    assert_equal 10, a.project_id
    assert_equal 100, a.role_id
    assert_equal Date.new(2026, 9, 7), a.start_date
    assert_equal Date.new(2026, 9, 11), a.end_date
    assert_equal 480, a.minutes_per_day
    assert a.is_active && a.is_billable
    assert_not a.is_placeholder
    assert_not a.is_template
    assert_not a.is_non_working_day
    assert_equal Time.parse("2026-09-01T00:00:00.000Z").to_i, a.updated_at.to_i
  end

  test "sync_projects! reads updatedAt (not UpdatedAt) so the column is populated" do
    runn.sync_projects!([project(10, updated_at: "2026-09-02T00:00:00.000Z")])
    assert_equal Time.parse("2026-09-02T00:00:00.000Z").to_i, RunnProject.find(10).updated_at.to_i
  end

  test "upsert_changed! skips rows whose updated_at did not move but still reports them seen" do
    r = runn
    r.sync_assignments!([assignment(5001), assignment(5002)])
    RunnAssignment.expects(:upsert_all).never
    ids = r.sync_assignments!([assignment(5001), assignment(5002)])
    assert_equal [5001, 5002], ids
  end

  test "upsert_changed! rewrites only rows whose updated_at advanced, plus new rows" do
    r = runn
    r.sync_assignments!([assignment(5003, minutes: 480), assignment(5004, minutes: 480)])
    captured = nil
    RunnAssignment.stubs(:upsert_all).with { |rows, **| captured = rows.map { |x| x[:runn_id] }; true }
    ids = r.sync_assignments!([
      assignment(5003, minutes: 480),
      assignment(5004, updated_at: "2026-09-05T00:00:00.000Z", minutes: 240),
      assignment(5005),
    ])
    assert_equal [5004, 5005], captured
    assert_equal [5003, 5004, 5005], ids
  end

  test "a changed assignment's new values land" do
    r = runn
    r.sync_assignments!([assignment(5006, minutes: 480)])
    r.sync_assignments!([assignment(5006, updated_at: "2026-09-05T00:00:00.000Z", minutes: 60)])
    assert_equal 60, RunnAssignment.find(5006).minutes_per_day
  end

  test "prune_assignments_not_in! deletes unseen assignments and is a no-op on blank input" do
    r = runn
    r.sync_assignments!([assignment(5007), assignment(5008)])
    r.prune_assignments_not_in!([])
    assert_equal 2, RunnAssignment.where(runn_id: [5007, 5008]).count
    r.prune_assignments_not_in!([5007])
    assert_equal [5007], RunnAssignment.where(runn_id: [5007, 5008]).pluck(:runn_id)
  end

  test "sync_all! runs every sync, prunes, and stamps runn_synced_at only on full success" do
    System.first || System.create!(settings: {})
    System.first.update!(runn_synced_at: nil)
    r = stub_reads(runn, people: [person(1)], roles: [role(100)], assignments: [assignment(5009)], projects: [project(10)])
    RunnAssignment.create!(runn_id: 5010, person_id: 1, project_id: 10, role_id: 100, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 2), minutes_per_day: 60)

    r.sync_all!

    assert RunnPerson.exists?(1)
    assert RunnRole.exists?(100)
    assert RunnProject.exists?(10)
    assert RunnAssignment.exists?(5009)
    assert_not RunnAssignment.exists?(5010), "unseen assignment pruned"
    assert_not_nil System.first.runn_synced_at
  end

  test "sync_all! leaves runn_synced_at untouched and earlier tables written when a later sync raises" do
    System.first || System.create!(settings: {})
    System.first.update!(runn_synced_at: nil)
    r = stub_reads(runn, people: [person(3)], roles: [role(101)], projects: [project(11)])
    r.stubs(:get_assignments).raises(RuntimeError, "boom")

    assert_raises(RuntimeError) { r.sync_all! }
    assert RunnProject.exists?(11)
    assert RunnPerson.exists?(3)
    assert RunnRole.exists?(101)
    assert_nil System.first.runn_synced_at
  end

  test "sync_all! never deletes people or roles" do
    r = stub_reads(runn, people: [person(4)], roles: [role(102)], assignments: [], projects: [])
    r.sync_all!
    r2 = stub_reads(runn, people: [], roles: [], assignments: [], projects: [])
    r2.sync_all!
    assert RunnPerson.exists?(4)
    assert RunnRole.exists?(102)
  end

  test "sync_all! skips when the advisory lock is held" do
    r = stub_reads(runn)
    ActiveRecord::Base.connection.stubs(:select_value).with("SELECT pg_try_advisory_lock(#{Stacks::Runn::SYNC_ALL_ADVISORY_LOCK_KEY})").returns(false)
    r.expects(:sync_projects!).never
    r.sync_all!
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/stacks/runn_sync_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'sync_people!'` and friends; the `sync_projects!` updatedAt test fails with nil `updated_at`.

- [ ] **Step 3: Rewrite `sync_all!` and `sync_projects!`, add the new methods**

In `lib/stacks/runn.rb`, replace the existing `sync_all!` method (`:43-49`, from `def sync_all!` through its `end`) with:

```ruby
  # Arbitrary 32-bit int identifying this lock. Forecast uses 84_217_295.
  SYNC_ALL_ADVISORY_LOCK_KEY = 84_217_296

  # Full mirror refresh: projects, people, roles, assignments. Mirrors the
  # Forecast sync: changed-rows-only upserts, assignments pruned by absence,
  # people/roles never pruned (isArchived is mirrored instead), and a
  # non-blocking advisory lock so the scheduler and daily_tasks can't run
  # two syncs at once. runn_synced_at is stamped only when every table
  # succeeded; a failure part-way leaves the earlier tables refreshed.
  def sync_all!
    acquired = ActiveRecord::Base.connection.select_value(
      "SELECT pg_try_advisory_lock(#{SYNC_ALL_ADVISORY_LOCK_KEY})"
    )
    unless acquired
      Rails.logger.warn("Stacks::Runn#sync_all! skipped — another sync is already running")
      return
    end

    begin
      sync_projects!
      sync_people!
      sync_roles!
      seen = sync_assignments!
      prune_assignments_not_in!(seen)
      # System.first, not System.instance: instance is memoized per process and
      # the web workers must see a fresh stamp for the stale-sync pill.
      (System.first || System.create!(settings: {})).update!(runn_synced_at: Time.current)
    ensure
      ActiveRecord::Base.connection.select_value(
        "SELECT pg_advisory_unlock(#{SYNC_ALL_ADVISORY_LOCK_KEY})"
      )
    end
  end

  # Only write rows that are NEW or whose Runn updatedAt moved (same fix the
  # Forecast sync needed — unconditional upsert_all rewrote every row nightly
  # and bloated the table). Returns EVERY seen runn_id so prune-by-absence
  # still treats unchanged rows as present.
  def upsert_changed!(model, rows)
    return [] if rows.empty?

    seen_ids = rows.map { |row| row[:runn_id] }
    stored_updated_at = model.where(runn_id: seen_ids).pluck(:runn_id, :updated_at).to_h
    changed = rows.select do |row|
      prev = stored_updated_at[row[:runn_id]]
      incoming = row[:updated_at]
      prev.nil? || incoming.blank? || prev.to_i != Time.parse(incoming.to_s).to_i
    end
    model.upsert_all(changed, unique_by: :runn_id) if changed.any?
    seen_ids
  end

  # Chunked so each delete holds locks for milliseconds. Blank input is a
  # no-op so an empty fetch can never wipe the mirror.
  def prune_assignments_not_in!(seen_ids)
    return if seen_ids.blank?

    RunnAssignment.where.not(runn_id: seen_ids).in_batches(of: 1000) do |batch|
      batch.delete_all
    end
  end

  def sync_people!(all_people = get_people())
    rows = all_people.map do |c|
      {
        runn_id: c["id"],
        first_name: c["firstName"],
        last_name: c["lastName"],
        email: c["email"],
        is_archived: c["isArchived"] == true,
        created_at: c["createdAt"],
        updated_at: c["updatedAt"],
        data: c,
      }
    end
    upsert_changed!(RunnPerson, rows)
  end

  def sync_roles!(all_roles = get_roles())
    rows = all_roles.map do |c|
      {
        runn_id: c["id"],
        name: c["name"],
        standard_rate: c["standardRate"],
        default_hour_cost: c["defaultHourCost"],
        is_archived: c["isArchived"] == true,
        created_at: c["createdAt"],
        updated_at: c["updatedAt"],
        data: c,
      }
    end
    upsert_changed!(RunnRole, rows)
  end

  def sync_assignments!(all_assignments = get_assignments())
    rows = all_assignments.map do |c|
      {
        runn_id: c["id"],
        person_id: c["personId"],
        project_id: c["projectId"],
        role_id: c["roleId"],
        start_date: c["startDate"],
        end_date: c["endDate"],
        minutes_per_day: c["minutesPerDay"].to_i,
        is_active: c["isActive"] != false,
        is_billable: c["isBillable"] != false,
        is_placeholder: c["isPlaceholder"] == true,
        is_template: c["isTemplate"] == true,
        is_non_working_day: c["isNonWorkingDay"] == true,
        note: c["note"],
        created_at: c["createdAt"],
        updated_at: c["updatedAt"],
        data: c,
      }
    end
    upsert_changed!(RunnAssignment, rows)
  end
```

Then in the existing `sync_projects!` (~:210-233):
- change `updated_at: c["UpdatedAt"],` to `updated_at: c["updatedAt"],`
- change the final line `RunnProject.upsert_all(data, unique_by: :runn_id)` to `upsert_changed!(RunnProject, data)`

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/stacks/runn_sync_test.rb test/lib/stacks/runn_test.rb test/models/runn_assignment_test.rb test/models/project_tracker_forecast_to_runn_sync_task_test.rb`
Expected: all pass.

- [ ] **Step 5: Live smoke against the dev database**

Run: `bin/rails runner 'Stacks::Runn.new(max_retries: 0).sync_all!; puts [RunnPerson.count, RunnRole.count, RunnAssignment.count, RunnProject.where(updated_at: nil).count, System.first.runn_synced_at].inspect'`
Expected: non-zero people/roles/assignments counts (live today: about 43 roles and 1600 assignments); `RunnProject.where(updated_at: nil).count` drops from 205 to roughly 66 (projects that no longer exist in Runn are never pruned, so they keep a nil `updated_at`); and a fresh timestamp. This is a read-only call against Runn; it writes only to the local dev database.

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add lib/stacks/runn.rb test/lib/stacks/runn_sync_test.rb
git commit -m "feat: Stacks::Runn#sync_all! mirrors people, roles, and assignments with changed-only upserts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 3: Part 2 regression check

- [ ] **Step 1: Confirm the rake wiring needs no change**

Run: `grep -n "Stacks::Runn.new.sync_all!" lib/tasks/stacks.rake`
Expected: two hits (`daily_tasks` and `sync_runn`). Both call the rewritten method with default `max_retries: 5`; nothing to edit.

- [ ] **Step 2: Run the adjacent suites**

Run: `bin/rails test test/lib/stacks/runn_sync_test.rb test/lib/stacks/runn_test.rb test/models/runn_assignment_test.rb test/models/runn_project_test.rb test/services/resourcing test/services/mcp/tools_test.rb`
Expected: `0 failures, 0 errors`.

No commit for this task.
