# MSO Roster and Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record who holds an MSO role and at what tier, and compute the monthly Top-N Sanctuary contributor benchmark their compensation is based on.

**Architecture:** `MsoRolePeriod` is a windowed role assignment on a `Contributor` (same shape as `ProjectLeadPeriod`). `Ledger::QualifyingIncome` sums one ledger's compensation for one month from live rows only. `Mso::Benchmark` averages the top N Sanctuary earners for a month, leaving out anyone who holds or has held an MSO role. Nothing here pays anyone or talks to QuickBooks.

**Tech Stack:** Rails 6.1, Postgres, Minitest, Mocha, ActiveAdmin, Storext.

This is subsystem **S2** of `docs/superpowers/specs/2026-10-09-garden3d-mso-compensation-design.md` (§7, §10, §12).

## Global Constraints

- `db/schema.rb` is **hand-curated**. Edit it by hand. **Never run `bin/rails db:migrate`** — in development it re-dumps the file (reintroducing `enable_extension "vector"` and dropping deliberate omissions). Loading the *test* schema (`RAILS_ENV=test bin/rails db:environment:set db:schema:load`) is safe and required after a schema edit.
- `check_pending!` aborts every test run if a migration file is newer than `db/schema.rb`'s version line. This plan adds one migration, `20261012100000`; the version line must become `2026_10_12_100000` in the same task.
- Run tests with `--exclude "sync_meet runs the connector inside a SystemTask"` (that test makes a live Google call and hangs for over an hour). Never run two test processes at once — they share one test database and deadlock.
- `Enterprise.sanctuary` / `.garden3d` memoize in `Thread.current`. Any test that touches them clears both keys in `teardown`:
  ```ruby
  Thread.current[:sanctuary_enterprise] = nil
  Thread.current[:garden3d_enterprise] = nil
  ```
- Money is `BigDecimal`, built from strings (`BigDecimal(amount.to_s)`). Never `to_f`.
- `Contributor` has a `default_scope` that joins `forecast_people`. A `Contributor` only exists alongside a `ForecastPerson`; tests create both.
- Tier multipliers, verbatim: head `0.70`, svp `0.85`, chief `1.00`, principal `1.15`.
- Baseline before this plan: **1835 runs, 0 failures, 0 errors, 2 skips**.
- Commit after every task.

## File Structure

| File | Responsibility |
| --- | --- |
| `db/migrate/20261012100000_create_mso_role_periods.rb` | The table |
| `app/models/mso_role_period.rb` | Role window, tier, multiplier, `active_during` |
| `app/models/contributor.rb` | `has_many :mso_role_periods` (one line) |
| `app/admin/mso_role_periods.rb` | Admin-only CRUD for the roster |
| `app/models/admin_authorization.rb` | One guard line: roster is admin-only |
| `app/models/system.rb` | `mso_top_n` setting and its safe reader |
| `app/models/ledger/qualifying_income.rb` | One ledger's qualifying income for one month |
| `app/services/mso/benchmark.rb` | Top-N average |

---

### Task 1: `MsoRolePeriod` model and table

**Files:**
- Create: `db/migrate/20261012100000_create_mso_role_periods.rb`
- Modify: `db/schema.rb`
- Create: `app/models/mso_role_period.rb`
- Modify: `app/models/contributor.rb` (next to `has_many :ledgers`, line 68)
- Create: `test/models/mso_role_period_test.rb`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `MsoRolePeriod` with `contributor`, `tier` (enum, prefixed: `tier_head?` … `tier_principal?`), `title`, `started_at`, `ended_at`
  - `MsoRolePeriod#tier_multiplier -> BigDecimal`
  - `MsoRolePeriod.active_during(date) -> ActiveRecord::Relation` — periods overlapping the calendar month containing `date`
  - `Contributor#mso_role_periods`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20261012100000_create_mso_role_periods.rb`:

```ruby
class CreateMsoRolePeriods < ActiveRecord::Migration[6.1]
  def change
    create_table :mso_role_periods do |t|
      t.references :contributor, null: false, foreign_key: true
      t.integer :tier, null: false
      t.string :title, null: false
      t.date :started_at, null: false
      t.date :ended_at
      t.timestamps
    end
  end
end
```

- [ ] **Step 2: Hand-edit `db/schema.rb`**

Change the version line to:

```ruby
ActiveRecord::Schema.define(version: 2026_10_12_100000) do
```

Add the table block between `create_table "misc_payments"` and `create_table "notifications"` (tables are alphabetical):

```ruby
  create_table "mso_role_periods", force: :cascade do |t|
    t.bigint "contributor_id", null: false
    t.integer "tier", null: false
    t.string "title", null: false
    t.date "started_at", null: false
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["contributor_id"], name: "index_mso_role_periods_on_contributor_id"
  end
```

Add the foreign key immediately after `add_foreign_key "misc_payments", "contributors"` (the list is alphabetical by table):

```ruby
  add_foreign_key "mso_role_periods", "contributors"
```

Confirm nothing else changed: `grep -c 'enable_extension "vector"' db/schema.rb` must print `0`.

- [ ] **Step 3: Load the schema into the test database**

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
RAILS_ENV=test bin/rails db:environment:set db:schema:load
```

Expected: no error.

- [ ] **Step 4: Write the failing test**

Create `test/models/mso_role_period_test.rb`:

```ruby
require "test_helper"

class MsoRolePeriodTest < ActiveSupport::TestCase
  def make_contributor(tag)
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                email: "mso-#{tag}-#{SecureRandom.hex(3)}@example.com", data: {})
    Contributor.create!(forecast_person: fp)
  end

  def build_period(contributor, attrs = {})
    MsoRolePeriod.new({
      contributor: contributor,
      tier: :chief,
      title: "Operations",
      started_at: Date.new(2026, 1, 1),
    }.merge(attrs))
  end

  test "a valid period saves" do
    period = build_period(make_contributor("valid"))
    assert period.save, period.errors.full_messages.to_sentence
  end

  test "tier multipliers are exact decimals" do
    contributor = make_contributor("mult")
    assert_equal BigDecimal("0.70"), build_period(contributor, tier: :head).tier_multiplier
    assert_equal BigDecimal("0.85"), build_period(contributor, tier: :svp).tier_multiplier
    assert_equal BigDecimal("1.00"), build_period(contributor, tier: :chief).tier_multiplier
    assert_equal BigDecimal("1.15"), build_period(contributor, tier: :principal).tier_multiplier
    assert_kind_of BigDecimal, build_period(contributor, tier: :head).tier_multiplier
  end

  test "started_at is required" do
    period = build_period(make_contributor("nostart"), started_at: nil)
    assert_not period.valid?
    assert_includes period.errors[:started_at], "can't be blank"
  end

  test "a missing started_at does not blow up when a sibling exists" do
    contributor = make_contributor("nostart-sibling")
    build_period(contributor).save!
    period = build_period(contributor, started_at: nil)
    assert_not period.valid?
  end

  test "title is required" do
    period = build_period(make_contributor("notitle"), title: "")
    assert_not period.valid?
    assert_includes period.errors[:title], "can't be blank"
  end

  test "started_at must be the first day of a month" do
    period = build_period(make_contributor("midstart"), started_at: Date.new(2026, 1, 15))
    assert_not period.valid?
    assert_includes period.errors[:started_at], "must be the first day of the month"
  end

  test "ended_at must be the last day of a month" do
    period = build_period(make_contributor("midend"), ended_at: Date.new(2026, 3, 15))
    assert_not period.valid?
    assert_includes period.errors[:ended_at], "must be the last day of the month"
  end

  test "ended_at on the last day of a month is accepted" do
    period = build_period(make_contributor("goodend"), ended_at: Date.new(2026, 2, 28))
    assert period.valid?, period.errors.full_messages.to_sentence
  end

  test "two overlapping periods for one contributor are rejected" do
    contributor = make_contributor("overlap")
    build_period(contributor, ended_at: Date.new(2026, 6, 30)).save!
    overlapping = build_period(contributor, tier: :svp, started_at: Date.new(2026, 6, 1))
    assert_not overlapping.valid?
    assert_includes overlapping.errors[:base], "This period overlaps with another."
  end

  test "two open-ended periods are rejected even when the second starts in the future" do
    # ActsAsPeriod's default period_ended_at is `ended_at || Date.today`, which
    # makes a future-dated open-ended period look non-overlapping. A promotion
    # entered ahead of time would then leave the person holding two tiers.
    contributor = make_contributor("future")
    build_period(contributor).save!
    promotion = build_period(contributor, tier: :principal,
                             started_at: Date.today.next_year.beginning_of_year)
    assert_not promotion.valid?
    assert_includes promotion.errors[:base], "This period overlaps with another."
  end

  test "a closed period followed by a later open one is accepted" do
    contributor = make_contributor("handoff")
    build_period(contributor, ended_at: Date.new(2026, 6, 30)).save!
    successor = build_period(contributor, tier: :principal, started_at: Date.new(2026, 7, 1))
    assert successor.valid?, successor.errors.full_messages.to_sentence
  end

  test "two contributors may hold periods over the same months" do
    build_period(make_contributor("a")).save!
    assert build_period(make_contributor("b")).valid?
  end

  test "active_during returns periods overlapping the month" do
    closed = build_period(make_contributor("closed"),
                          started_at: Date.new(2026, 1, 1), ended_at: Date.new(2026, 3, 31))
    open = build_period(make_contributor("open"), started_at: Date.new(2026, 3, 1))
    later = build_period(make_contributor("later"), started_at: Date.new(2026, 5, 1))
    [closed, open, later].each(&:save!)

    assert_equal [closed.id, open.id].sort, MsoRolePeriod.active_during(Date.new(2026, 3, 15)).pluck(:id).sort
    assert_equal [open.id], MsoRolePeriod.active_during(Date.new(2026, 4, 1)).pluck(:id)
    assert_equal [closed.id], MsoRolePeriod.active_during(Date.new(2026, 2, 10)).pluck(:id)
    assert_equal [open.id, later.id].sort, MsoRolePeriod.active_during(Date.new(2026, 5, 31)).pluck(:id).sort
  end

  test "a contributor lists its role periods" do
    contributor = make_contributor("assoc")
    period = build_period(contributor)
    period.save!
    assert_equal [period], contributor.mso_role_periods.to_a
  end
end
```

- [ ] **Step 5: Run it to verify it fails**

```bash
bin/rails test test/models/mso_role_period_test.rb
```

Expected: every test errors with `NameError: uninitialized constant MsoRolePeriod`.

- [ ] **Step 6: Write the model**

Create `app/models/mso_role_period.rb`:

```ruby
# A window during which a contributor holds an MSO executive role at a tier.
# Their monthly MSO compensation is the Top-N Sanctuary benchmark multiplied
# by the tier's multiplier (see Mso::Benchmark and Mso::Compensation).
class MsoRolePeriod < ApplicationRecord
  include ActsAsPeriod

  MULTIPLIERS = {
    "head" => BigDecimal("0.70"),
    "svp" => BigDecimal("0.85"),
    "chief" => BigDecimal("1.00"),
    "principal" => BigDecimal("1.15"),
  }.freeze

  # Sentinel for an open-ended period. ActsAsPeriod's default is Date.today,
  # under which two open-ended periods never overlap if the second starts in
  # the future.
  OPEN_ENDED = Date.new(9999, 12, 31)

  belongs_to :contributor

  enum tier: { head: 0, svp: 1, chief: 2, principal: 3 }, _prefix: :tier

  validates :started_at, presence: true
  validates :title, presence: true
  validate :full_months_only

  # Periods that overlap the calendar month containing `date`. Written in SQL
  # rather than on top of period_ended_at, which is a Ruby-side sentinel.
  scope :active_during, ->(date) {
    where("mso_role_periods.started_at <= ?", date.end_of_month)
      .where("mso_role_periods.ended_at IS NULL OR mso_role_periods.ended_at >= ?", date.beginning_of_month)
  }

  def tier_multiplier
    MULTIPLIERS.fetch(tier)
  end

  def period_ended_at
    ended_at || OPEN_ENDED
  end

  # ActsAsPeriod compares against these in its overlap validation. With no
  # contributor or no start date there is nothing meaningful to compare, and
  # the presence validations already fail the record.
  def sibling_periods
    return MsoRolePeriod.none if contributor.nil? || started_at.nil?
    contributor.mso_role_periods
  end

  def full_months_only
    if started_at && started_at.day != started_at.beginning_of_month.day
      errors.add(:started_at, "must be the first day of the month")
    end
    if ended_at && ended_at.day != ended_at.end_of_month.day
      errors.add(:ended_at, "must be the last day of the month")
    end
  end
end
```

In `app/models/contributor.rb`, directly below `has_many :ledgers` (line 68), add:

```ruby
  has_many :mso_role_periods, dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
bin/rails test test/models/mso_role_period_test.rb
```

Expected: PASS, 14 runs, 0 failures.

- [ ] **Step 8: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1849 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 9: Commit**

```bash
git add db/migrate/20261012100000_create_mso_role_periods.rb db/schema.rb \
  app/models/mso_role_period.rb app/models/contributor.rb test/models/mso_role_period_test.rb
git commit -m "feat(mso): MsoRolePeriod — who holds an MSO role, at what tier, and when"
```

---

### Task 2: Admin-only roster page

The roster decides who is paid executive compensation, so it is admin-only for **every** action, including read. `AdminAuthorization#authorized?` has a blanket `return true if (user.is_admin? || user.can_act_as_lead?)`; the new guard must sit **above** that line (next to the `ApiToken` guard) or every project lead can read and edit the roster.

**Files:**
- Modify: `app/models/admin_authorization.rb` (directly below the `ApiToken` line, currently line 77)
- Create: `app/admin/mso_role_periods.rb`
- Modify: `test/models/admin_authorization_test.rb`
- Create: `test/integration/admin_mso_role_periods_test.rb`

**Interfaces:**
- Consumes: `MsoRolePeriod` (Task 1)
- Produces: `/admin/mso_role_periods` for admins

- [ ] **Step 1: Write the failing authorization tests**

Append inside the existing `AdminAuthorizationTest` class in `test/models/admin_authorization_test.rb` (it already defines `auth_for` and `make_user`):

```ruby
  test "only admins may touch the MSO roster, including reading it" do
    admin = AdminUser.create!(email: "mso-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    lead = make_user("mso-lead@sanctuary.computer")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    nobody = make_user("mso-nobody@sanctuary.computer")

    %i[read create update destroy].each do |action|
      assert auth_for(admin).authorized?(action, MsoRolePeriod), "admin should #{action}"
      assert auth_for(admin).authorized?(action, MsoRolePeriod.new), "admin should #{action} a record"
      refute auth_for(lead).authorized?(action, MsoRolePeriod), "lead must not #{action}"
      refute auth_for(lead).authorized?(action, MsoRolePeriod.new), "lead must not #{action} a record"
      refute auth_for(nobody).authorized?(action, MsoRolePeriod), "non-lead must not #{action}"
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/admin_authorization_test.rb
```

Expected: the new test FAILS on "lead must not read" — the blanket lead grant currently allows it.

- [ ] **Step 3: Add the guard**

In `app/models/admin_authorization.rb`, directly below the line

```ruby
    return user.is_admin? if subject.is_a?(ApiToken) || subject == ApiToken
```

add:

```ruby
    # The MSO roster decides who is paid executive compensation: admins only,
    # for every action including read. Must stay above the blanket lead grant.
    return user.is_admin? if subject.is_a?(MsoRolePeriod) || subject == MsoRolePeriod
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rails test test/models/admin_authorization_test.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 5: Write the failing integration test**

Create `test/integration/admin_mso_role_periods_test.rb`. Open `test/integration/admin_permission_grants_test.rb` first and mirror how it builds and signs in its admin and non-admin users (it uses `Devise::Test::IntegrationHelpers` and `sign_in`).

```ruby
require "test_helper"

class AdminMsoRolePeriodsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(email: "roster-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "roster-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "roster-exec@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
  end

  test "an admin can list and create role periods" do
    sign_in @admin

    get admin_mso_role_periods_path
    assert_response :success

    assert_difference -> { MsoRolePeriod.count }, 1 do
      post admin_mso_role_periods_path, params: { mso_role_period: {
        contributor_id: @contributor.id, tier: "chief", title: "Operations",
        started_at: "2026-01-01",
      } }
    end
    period = MsoRolePeriod.last
    assert_equal "chief", period.tier
    assert_equal Date.new(2026, 1, 1), period.started_at
  end

  test "a lead cannot see the roster" do
    sign_in @lead

    get admin_mso_role_periods_path

    assert_not_equal 200, response.status
  end

  test "a lead cannot create a role period by posting directly" do
    sign_in @lead

    assert_no_difference -> { MsoRolePeriod.count } do
      post admin_mso_role_periods_path, params: { mso_role_period: {
        contributor_id: @contributor.id, tier: "principal", title: "Self-appointed",
        started_at: "2026-01-01",
      } }
    end
  end
end
```

- [ ] **Step 6: Run it to verify it fails**

```bash
bin/rails test test/integration/admin_mso_role_periods_test.rb
```

Expected: errors with `NameError: undefined local variable or method 'admin_mso_role_periods_path'` — the resource is not registered.

- [ ] **Step 7: Register the admin resource**

Create `app/admin/mso_role_periods.rb`:

```ruby
ActiveAdmin.register MsoRolePeriod do
  menu label: "MSO Roles", parent: "Money"
  config.filters = false
  config.sort_order = "started_at_desc"
  actions :index, :new, :create, :edit, :update, :destroy
  permit_params :contributor_id, :tier, :title, :started_at, :ended_at

  controller do
    def scoped_collection
      super.includes(contributor: :forecast_person)
    end
  end

  index download_links: false, title: "MSO Roles" do
    column :contributor
    column(:tier) { |period| period.tier.titleize }
    column :title
    column(:multiplier) { |period| "#{period.tier_multiplier.to_s('F')}x" }
    column :started_at
    column :ended_at
    actions
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :contributor,
        collection: Contributor.includes(:forecast_person).map { |c| [c.display_name, c.id] }
      f.input :tier, as: :select, collection: MsoRolePeriod.tiers.keys.map { |t| [t.titleize, t] },
        include_blank: false
      f.input :title, hint: "e.g. Operations — shown as \"Chief (Operations)\""
      f.input :started_at, as: :date_select, hint: "Must be the first day of a month"
      f.input :ended_at, as: :date_select, include_blank: true,
        hint: "Leave blank while the role is held. Otherwise the last day of a month."
    end
    f.actions
  end
end
```

- [ ] **Step 8: Run the integration test to verify it passes**

```bash
bin/rails test test/integration/admin_mso_role_periods_test.rb
```

Expected: PASS, 3 runs, 0 failures. If the index test fails on `column :contributor` rendering, check `Contributor#display_name` exists (`app/models/contributor.rb:287`) — ActiveAdmin uses it to label the association.

- [ ] **Step 9: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1853 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 10: Commit**

```bash
git add app/models/admin_authorization.rb app/admin/mso_role_periods.rb \
  test/models/admin_authorization_test.rb test/integration/admin_mso_role_periods_test.rb
git commit -m "feat(mso): admin-only MSO roster page

The roster decides who is paid executive compensation, so the
authorization guard sits above the blanket lead grant and covers every
action including read."
```

---

### Task 3: The Top-N setting

**Files:**
- Modify: `app/models/system.rb`
- Modify: `test/models/system_test.rb`

**Interfaces:**
- Consumes: nothing
- Produces: `System.mso_top_n -> Integer` (always ≥ 1; `3` when unset, blank or invalid)

`System` stores settings with Storext, which keeps whatever was written — an Integer attribute can come back as `""` or `"5"`. Read it only through the class method below. It uses `System.first`, not `System.instance`, which is memoized per process and returns stale rows in tests.

- [ ] **Step 1: Write the failing test**

Append inside the existing test class in `test/models/system_test.rb` (it already has a `@sys` helper built with `System.first_or_create!(settings: {})`; create the row the same way here):

```ruby
  test "mso_top_n defaults to 3" do
    System.first_or_create!(settings: {})
    assert_equal 3, System.mso_top_n
  end

  test "mso_top_n defaults to 3 when no System row exists" do
    System.delete_all
    assert_equal 3, System.mso_top_n
  end

  test "mso_top_n reads a stored value, coercing strings" do
    system = System.first_or_create!(settings: {})
    system.update!(mso_top_n: 5)
    assert_equal 5, System.mso_top_n

    system.update_column(:settings, system.settings.merge("mso_top_n" => "4"))
    assert_equal 4, System.mso_top_n
  end

  test "mso_top_n falls back to 3 for blank, zero or negative values" do
    system = System.first_or_create!(settings: {})
    ["", "0", "-2", "abc"].each do |bad|
      system.update_column(:settings, system.settings.merge("mso_top_n" => bad))
      assert_equal 3, System.mso_top_n, "expected fallback for #{bad.inspect}"
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/system_test.rb
```

Expected: the four new tests error with `NoMethodError: undefined method 'mso_top_n' for System:Class`.

- [ ] **Step 3: Add the setting and its reader**

In `app/models/system.rb`, inside the `store_attributes :settings do` block, after the `runn_synced_at` line, add:

```ruby

    # How many of Sanctuary's top earners are averaged into the MSO benchmark.
    # Read it through System.mso_top_n, never directly.
    mso_top_n Integer, default: 3
```

Then add these two methods above the `private` keyword:

```ruby
  MSO_TOP_N_DEFAULT = 3

  # Storext hands back whatever was stored ("" or "5" for an Integer
  # attribute), so coerce, and fall back rather than average over zero people.
  def mso_top_n_clamped
    n = mso_top_n.to_s.to_i
    n >= 1 ? n : MSO_TOP_N_DEFAULT
  end

  # Uses `first`, not `instance`: `instance` is memoized per process.
  def self.mso_top_n
    (first || new(settings: {})).mso_top_n_clamped
  end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rails test test/models/system_test.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/models/system.rb test/models/system_test.rb
git commit -m "feat(mso): configurable Top-N for the MSO benchmark, default 3"
```

---

### Task 4: `Ledger::QualifyingIncome`

One ledger's qualifying compensation for one calendar month: contributor payouts, true-ups and pay stubs. Reimbursements, adjustments, profit shares and Deel invoice adjustments are not compensation and are left out.

This is deliberately **not** the same sum as `Ledger#items_grouped_by_month`'s `total_income`, which reads soft-deleted rows too so the ledger page can show strikethroughs. A deleted payout is not income. Leave `items_grouped_by_month` untouched.

**Files:**
- Create: `app/models/ledger/qualifying_income.rb`
- Create: `test/models/ledger/qualifying_income_test.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `Ledger::QualifyingIncome.for(ledger:, month:, excluding: []) -> BigDecimal`
  - `month:` is any `Date` in the month
  - `excluding:` is an array of records to leave out, matched by class and id
  - `Ledger::QualifyingIncome::KLASSES` — the classes that count

Dates: a row counts in the month of its `effective_on_for_display` — a payout by its invoice pass's month, a true-up by its pass's month end, a pay stub by its pay cycle's end.

- [ ] **Step 1: Write the failing test**

Create `test/models/ledger/qualifying_income_test.rb`:

```ruby
require "test_helper"

class Ledger::QualifyingIncomeTest < ActiveSupport::TestCase
  setup do
    @sanctuary = enterprises(:sanctuary)
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                email: "qi-#{SecureRandom.hex(3)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @contributor)
    @admin = AdminUser.create!(email: "qi-admin-#{SecureRandom.hex(3)}@example.com",
                               password: "password12345", roles: ["admin"])
    @march = Date.new(2090, 3, 1)
    @march_pass = InvoicePass.create!(start_of_month: @march, enterprise: @sanctuary, data: {})
    @april_pass = InvoicePass.create!(start_of_month: Date.new(2090, 4, 1), enterprise: @sanctuary, data: {})
  end

  teardown do
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  def trueup(pass, amount)
    Trueup.create!(ledger: @ledger, invoice_pass: pass, amount: amount, description: "test trueup")
  end

  def payout(pass, amount)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "QI Client #{SecureRandom.hex(3)}")
    tracker = InvoiceTracker.create!(
      invoice_pass: pass,
      forecast_client: client,
      qbo_account: Enterprise.find(@sanctuary.id).qbo_account,
      # A blueprint gives the tracker a non-zero total, without which every
      # payout trips ContributorPayout's 70%-of-invoice validation.
      blueprint: { "lines" => { "Line" => { "quantity" => 100, "unit_price" => 1000 } } },
    )
    ContributorPayout.create!(ledger: @ledger, invoice_tracker: tracker, created_by: @admin, amount: amount)
  end

  test "an empty month is zero, as a BigDecimal" do
    result = Ledger::QualifyingIncome.for(ledger: @ledger, month: @march)
    assert_equal BigDecimal("0"), result
    assert_kind_of BigDecimal, result
  end

  test "sums true-ups and payouts that fall in the month" do
    trueup(@march_pass, "1000.25")
    payout(@march_pass, "2500.50")

    assert_equal BigDecimal("3500.75"), Ledger::QualifyingIncome.for(ledger: @ledger, month: @march)
  end

  test "any date within the month selects that month" do
    trueup(@march_pass, "1000")
    assert_equal BigDecimal("1000"), Ledger::QualifyingIncome.for(ledger: @ledger, month: Date.new(2090, 3, 19))
  end

  test "rows from other months are left out" do
    trueup(@march_pass, "1000")
    trueup(@april_pass, "9999")

    assert_equal BigDecimal("1000"), Ledger::QualifyingIncome.for(ledger: @ledger, month: @march)
  end

  test "soft-deleted rows are not income" do
    trueup(@march_pass, "1000")
    trueup(@march_pass, "10300").destroy

    assert_equal BigDecimal("1000"), Ledger::QualifyingIncome.for(ledger: @ledger, month: @march)
  end

  test "another contributor's ledger is not counted" do
    other_fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                      email: "qi-other-#{SecureRandom.hex(3)}@example.com", data: {})
    other_ledger = Ledger.find_or_create_for(enterprise: @sanctuary,
                                             contributor: Contributor.create!(forecast_person: other_fp))
    Trueup.create!(ledger: other_ledger, invoice_pass: @march_pass, amount: 7777, description: "other")
    trueup(@march_pass, "1000")

    assert_equal BigDecimal("1000"), Ledger::QualifyingIncome.for(ledger: @ledger, month: @march)
  end

  test "excluded records are left out, matched by class and id" do
    kept = trueup(@march_pass, "1000")
    dropped = trueup(@march_pass, "400")

    assert_equal BigDecimal("1000"),
      Ledger::QualifyingIncome.for(ledger: @ledger, month: @march, excluding: [dropped])
    assert_equal BigDecimal("1400"),
      Ledger::QualifyingIncome.for(ledger: @ledger, month: @march, excluding: [])
    assert kept.persisted?
  end

  test "reimbursements and adjustments are not compensation" do
    assert_equal [ContributorPayout, Trueup, PayStub], Ledger::QualifyingIncome::KLASSES
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/ledger/qualifying_income_test.rb
```

Expected: errors with `NameError: uninitialized constant Ledger::QualifyingIncome`.

- [ ] **Step 3: Write the implementation**

Create `app/models/ledger/qualifying_income.rb`:

```ruby
# One ledger's qualifying compensation for one calendar month: contributor
# payouts, true-ups and pay stubs. Reimbursements, adjustments, profit shares
# and Deel invoice adjustments are not compensation.
#
# Reads live rows only. Ledger#items_grouped_by_month's total_income is a
# different number on purpose — it includes soft-deleted rows so the ledger
# page can show strikethroughs. A deleted payout is not income.
module Ledger::QualifyingIncome
  # class => associations to preload so effective_on_for_display is query-free
  SOURCES = {
    ContributorPayout => { invoice_tracker: :invoice_pass },
    Trueup => :invoice_pass,
    PayStub => :pay_cycle,
  }.freeze

  KLASSES = SOURCES.keys.freeze

  ZERO = BigDecimal("0")

  def self.for(ledger:, month:, excluding: [])
    range = month.beginning_of_month..month.end_of_month
    excluded = excluding.map { |record| [record.class.name, record.id] }.to_set

    SOURCES.sum(ZERO) do |klass, preloads|
      klass.where(ledger_id: ledger.id).includes(preloads).sum(ZERO) do |item|
        next ZERO if excluded.include?([item.class.name, item.id])

        effective_on = item.effective_on_for_display
        next ZERO unless effective_on && range.cover?(effective_on.to_date)

        BigDecimal(item.amount.to_s)
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/models/ledger/qualifying_income_test.rb
```

Expected: PASS, 8 runs, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1865 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 6: Commit**

```bash
git add app/models/ledger/qualifying_income.rb test/models/ledger/qualifying_income_test.rb
git commit -m "feat(mso): Ledger::QualifyingIncome — one ledger's compensation for a month

Live rows only. The ledger page's total_income includes soft-deleted rows
for strikethrough display; a deleted payout is not income."
```

---

### Task 5: `Mso::Benchmark`

The average qualifying income of Sanctuary's top N earners for a month.

Who is in the pool:

1. Contributors with a login (`forecast_person.admin_user`). Commission-only payouts go to outside parties who have a `Contributor` row but no `AdminUser`; they are not Sanctuary contributors and must not set executive pay.
2. Not anyone who holds, or has held, an MSO role starting on or before the end of the month — an executive's own earnings must not set their benchmark, and a departed executive's must not set their former peers'.
3. Only people with positive qualifying income on their **Sanctuary** ledger that month.

**Files:**
- Create: `app/services/mso/benchmark.rb`
- Create: `test/services/mso/benchmark_test.rb`

**Interfaces:**
- Consumes: `Ledger::QualifyingIncome.for` (Task 4), `MsoRolePeriod` (Task 1), `System.mso_top_n` (Task 3)
- Produces:
  - `Mso::Benchmark.for_month(date, top_n: System.mso_top_n) -> Mso::Benchmark::Result`
  - `Result = Struct.new(:average, :configured_n, :counted, :members, :small_sample, keyword_init: true)`
    - `average` BigDecimal (unrounded; `0` when nobody qualifies)
    - `configured_n` Integer — the N asked for
    - `counted` Integer — how many were actually averaged
    - `members` `[{ contributor_id: Integer, amount: BigDecimal }]`, highest first
    - `small_sample` Boolean — `counted < configured_n`

- [ ] **Step 1: Write the failing test**

Create `test/services/mso/benchmark_test.rb`:

```ruby
require "test_helper"

class Mso::BenchmarkTest < ActiveSupport::TestCase
  setup do
    @sanctuary = enterprises(:sanctuary)
    @month = Date.new(2091, 3, 1)
    @pass = InvoicePass.create!(start_of_month: @month, enterprise: @sanctuary, data: {})
  end

  teardown do
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  # A contributor with a login and `amount` of Sanctuary income in @month.
  def earner(tag, amount, login: true, enterprise: @sanctuary)
    email = "bm-#{tag}-#{SecureRandom.hex(3)}@example.com"
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    AdminUser.create!(email: email, password: "password12345") if login
    contributor = Contributor.create!(forecast_person: fp)
    ledger = Ledger.find_or_create_for(enterprise: enterprise, contributor: contributor)
    Trueup.create!(ledger: ledger, invoice_pass: @pass, amount: amount, description: "income") if amount
    contributor
  end

  test "averages the top N earners" do
    a = earner("a", 30_000)
    b = earner("b", 20_000)
    c = earner("c", 10_000)
    earner("d", 5_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
    assert_equal 3, result.configured_n
    assert_equal 3, result.counted
    assert_equal false, result.small_sample
    assert_equal [a.id, b.id, c.id], result.members.map { |m| m[:contributor_id] }
    assert_equal BigDecimal("30000"), result.members.first[:amount]
    assert_kind_of BigDecimal, result.average
  end

  test "fewer earners than N averages over those present and flags a small sample" do
    earner("a", 30_000)
    earner("b", 10_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
    assert_equal 3, result.configured_n
    assert_equal 2, result.counted
    assert_equal true, result.small_sample
  end

  test "nobody earning gives a zero average, not a division error" do
    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("0"), result.average
    assert_equal 0, result.counted
    assert_equal true, result.small_sample
    assert_equal [], result.members
  end

  test "a payee with no login is not a Sanctuary contributor" do
    earner("a", 20_000)
    earner("b", 10_000)
    earner("outside-referrer", 21_024.90, login: false)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("15000"), result.average
    assert_equal 2, result.counted
  end

  test "a current MSO executive is left out of the pool" do
    exec = earner("exec", 90_000)
    MsoRolePeriod.create!(contributor: exec, tier: :chief, title: "Ops", started_at: Date.new(2091, 1, 1))
    earner("a", 20_000)
    earner("b", 10_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("15000"), result.average
    refute_includes result.members.map { |m| m[:contributor_id] }, exec.id
  end

  test "a former MSO executive is left out of the pool" do
    former = earner("former", 90_000)
    MsoRolePeriod.create!(contributor: former, tier: :chief, title: "Ops",
                          started_at: Date.new(2090, 1, 1), ended_at: Date.new(2090, 12, 31))
    earner("a", 20_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
  end

  test "an executive whose role starts after the month still counts for it" do
    future = earner("future", 30_000)
    MsoRolePeriod.create!(contributor: future, tier: :chief, title: "Ops", started_at: Date.new(2091, 6, 1))
    earner("a", 10_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
  end

  test "income on another enterprise's ledger does not count" do
    earner("a", 20_000)
    earner("elsewhere", 80_000, enterprise: enterprises(:garden3d))

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
    assert_equal 1, result.counted
  end

  test "zero and negative earners are left out" do
    earner("a", 20_000)
    earner("zero", 0)
    earner("negative", -500)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal 1, result.counted
    assert_equal BigDecimal("20000"), result.average
  end

  test "ties are broken by contributor id, so the result is stable" do
    first = earner("tie-1", 10_000)
    second = earner("tie-2", 10_000)
    lower, = [first, second].sort_by(&:id)

    result = Mso::Benchmark.for_month(@month, top_n: 1)

    assert_equal [lower.id], result.members.map { |m| m[:contributor_id] }
  end

  test "top_n defaults to the System setting" do
    System.stubs(:mso_top_n).returns(1)
    earner("a", 30_000)
    earner("b", 10_000)

    result = Mso::Benchmark.for_month(@month)

    assert_equal 1, result.configured_n
    assert_equal BigDecimal("30000"), result.average
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/mso/benchmark_test.rb
```

Expected: errors with `NameError: uninitialized constant Mso::Benchmark` (or `Mso`).

- [ ] **Step 3: Write the implementation**

Create `app/services/mso/benchmark.rb`:

```ruby
module Mso
  # The average qualifying income of Sanctuary's top N earners for a month —
  # the figure each MSO executive's tier multiplier is applied to.
  #
  # Current month only; no smoothing across months.
  class Benchmark
    Result = Struct.new(:average, :configured_n, :counted, :members, :small_sample, keyword_init: true)

    ZERO = BigDecimal("0")

    def self.for_month(date, top_n: System.mso_top_n)
      new(date, top_n).call
    end

    def initialize(date, top_n)
      @date = date
      @top_n = top_n
    end

    def call
      members = scored_members.sort_by { |m| [-m[:amount], m[:contributor_id]] }.first(@top_n)
      average = members.empty? ? ZERO : members.sum(ZERO) { |m| m[:amount] } / members.size

      Result.new(
        average: average,
        configured_n: @top_n,
        counted: members.size,
        members: members,
        small_sample: members.size < @top_n,
      )
    end

    private

    def scored_members
      pool.filter_map do |ledger|
        # Commission-only payees have a Contributor row but no login. They are
        # outside parties, not Sanctuary contributors.
        next if ledger.contributor&.forecast_person&.admin_user.nil?

        amount = Ledger::QualifyingIncome.for(ledger: ledger, month: @date)
        next unless amount.positive?

        { contributor_id: ledger.contributor_id, amount: amount }
      end
    end

    # Sanctuary ledgers, minus anyone who holds or has held an MSO role by the
    # end of this month: an executive's own earnings must not set their
    # benchmark, and a departed executive's must not set their former peers'.
    def pool
      Ledger
        .where(enterprise: Enterprise.sanctuary)
        .where.not(contributor_id: executive_contributor_ids)
        .includes(contributor: { forecast_person: :admin_user })
    end

    def executive_contributor_ids
      MsoRolePeriod.where("started_at <= ?", @date.end_of_month).distinct.pluck(:contributor_id)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/benchmark_test.rb
```

Expected: PASS, 11 runs, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1876 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 6: Commit**

```bash
git add app/services/mso/benchmark.rb test/services/mso/benchmark_test.rb
git commit -m "feat(mso): Top-N Sanctuary benchmark

Leaves out payees with no login (outside commission recipients) and anyone
who holds or has held an MSO role, so an executive's own earnings never set
executive pay."
```

---

## Self-Review

**Spec coverage.** §7.1 `MsoRolePeriod` (table, tiers, multipliers, month boundaries, overlap incl. the future-dated case, `active_during` in SQL) → Task 1. §10's admin-only roster above the blanket lead grant → Task 2. §7.3's `mso_top_n` with a coerced, clamped reader via `System.first` → Task 3. §7.2 `QualifyingIncome` (live rows only, month bucketing on `effective_on_for_display`, `excluding:` by class and id, BigDecimal) → Task 4. §7.3 pool rules (login required, current and former executives out, Sanctuary ledger only, positive income, top N, small sample, never divide by N) → Task 5.

**Deliberate differences from the spec, to carry back into it:**

1. `BustsTaskCache` is **not** included on `MsoRolePeriod`. Nothing in this plan turns a role period into a task; S4's nag keys off true-ups. Add it when something needs it.
2. The tier enum is declared with `_prefix: :tier` (`tier_head?`), so its generated scopes and predicates cannot collide with anything named `head` or `chief`.
3. `Ledger#items_grouped_by_month` is left untouched; spec §7.2's instruction to add `MsoTrueup` to its class list belongs to S4, which creates that class.
4. `KLASSES` ships without `MsoTrueup`; S4 adds it together with the model.
5. "Has ever held a role" is implemented as "has a role period starting on or before the end of the month", so an appointment entered ahead of time does not remove someone from earlier months' pools.
6. `mso_top_n` has no admin form — `System` settings have none today. It is changed from the console: `System.first.update!(mso_top_n: 5)`.

**Placeholders.** None.

**Type consistency.** `MsoRolePeriod#tier_multiplier` returns `BigDecimal` and is what S3's `Line#multiplier` takes. `Ledger::QualifyingIncome.for(ledger:, month:, excluding:)` matches spec §4.1 and is called with exactly those keywords in Task 5. `Mso::Benchmark::Result` field names match spec §7.3. `System.mso_top_n` is the only reader used.

**Cost note.** `Mso::Benchmark` runs three queries per Sanctuary ledger (about 200 ledgers today). It is an admin-triggered monthly computation, so that is acceptable; batch it if it is ever called in a loop.
