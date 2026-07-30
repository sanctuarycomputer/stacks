# Recurring Forecast Assignments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Stacks own a "recurring assignment" rule and materialize each occurrence as a concrete Forecast assignment via the `api.forecastapp.com` write API, respecting manual deletions (never recreate a deleted assignment).

**Architecture:** Two local models — `RecurringAssignment` (the rule) and `RecurringAssignmentOccurrence` (one row per occurrence date, tracking the materialized `forecast_assignment_id` + a `materialized`/`deleted` status). `RecurringAssignment#materialize!` runs two ordered passes (deletion-detection, then creation) and is invoked inline right after `Stacks::Forecast#sync_all!` in the daily cron, so the local `ForecastAssignment` mirror is authoritative and "absent from mirror" unambiguously means "deleted in Forecast." An ActiveAdmin resource provides CRUD + "materialize now".

**Tech Stack:** Rails 6.1, Postgres (jsonb, integer arrays), HTTParty (Forecast client), ActiveAdmin, Minitest + Mocha (HTTP stubbed at the class-method level, no WebMock/VCR).

## Global Constraints

- Rails `~> 6.1`; migrations subclass `ActiveRecord::Migration[6.1]`.
- Forecast mirror models (`ForecastPerson`, `ForecastProject`, `ForecastAssignment`) use `self.primary_key = "forecast_id"`; new models reference them by `forecast_id` via `belongs_to ... primary_key: "forecast_id"`, `optional: true` (mirror rows can be pruned — don't couple validity to their presence).
- Allocation is stored in **seconds/day** (Forecast native). Admin enters hours.
- Forecast writes wrap the body as `{ assignment: { ... } }`, `Content-Type: application/json`.
- Tests stub Forecast HTTP with `Stacks::Forecast.expects(:post)/:delete` (per `test/lib/stacks/runn_test.rb`); build the client with `Stacks::Forecast.allocate` + `instance_variable_set(:@headers, {...})` to skip config-dependent `initialize` (per `test/lib/stacks/forecast_test.rb`).
- Commit after every task. End commit messages with the Co-Authored-By trailer.

---

### Task 1: Forecast write methods (`create_assignment`, `delete_assignment`)

**Files:**
- Modify: `lib/stacks/forecast.rb`
- Test: `test/lib/stacks/forecast_test.rb`

**Interfaces:**
- Produces:
  - `Stacks::Forecast#create_assignment(project_id:, person_id:, start_date:, end_date:, allocation:, notes: "", active_on_days_off: false)` → returns the parsed `"assignment"` Hash (includes `"id"`). Raises on non-2xx.
  - `Stacks::Forecast#delete_assignment(forecast_id)` → returns `true`; treats HTTP 404 as already-deleted (idempotent). Raises on other non-2xx.

- [ ] **Step 1: Write the failing tests**

Add to `test/lib/stacks/forecast_test.rb`:

```ruby
def build_forecast_client
  fc = Stacks::Forecast.allocate
  fc.instance_variable_set(:@headers, { "Authorization": "Bearer test" })
  fc
end

test "create_assignment POSTs the assignment envelope and returns the assignment hash" do
  fc = build_forecast_client
  response = mock("response")
  response.stubs(:success?).returns(true)
  response.stubs(:parsed_response).returns({ "assignment" => { "id" => 42, "allocation" => 900 } })

  posted = {}
  Stacks::Forecast.expects(:post).once.with do |path, opts|
    posted[:path] = path
    posted[:body] = JSON.parse(opts[:body])
    true
  end.returns(response)

  result = fc.create_assignment(
    project_id: 5039734, person_id: 324711,
    start_date: Date.new(2035, 6, 1), end_date: Date.new(2035, 6, 1),
    allocation: 900, notes: "hi", active_on_days_off: false,
  )

  assert_equal 42, result["id"]
  assert_equal "/assignments", posted[:path]
  assert_equal 5039734, posted[:body]["assignment"]["project_id"]
  assert_equal "2035-06-01", posted[:body]["assignment"]["start_date"]
  assert_equal 900, posted[:body]["assignment"]["allocation"]
end

test "create_assignment raises on failure" do
  fc = build_forecast_client
  response = mock("response")
  response.stubs(:success?).returns(false)
  response.stubs(:code).returns(422)
  response.stubs(:body).returns("nope")
  Stacks::Forecast.stubs(:post).returns(response)

  assert_raises(RuntimeError) do
    fc.create_assignment(project_id: 1, person_id: 2, start_date: Date.today, end_date: Date.today, allocation: 900)
  end
end

test "delete_assignment DELETEs by id and treats 404 as already-gone" do
  fc = build_forecast_client

  ok = mock("ok"); ok.stubs(:success?).returns(true)
  Stacks::Forecast.expects(:delete).once.with("/assignments/99", has_entry(:headers, instance_of(Hash))).returns(ok)
  assert_equal true, fc.delete_assignment(99)

  gone = mock("gone"); gone.stubs(:success?).returns(false); gone.stubs(:code).returns(404)
  Stacks::Forecast.expects(:delete).once.returns(gone)
  assert_equal true, fc.delete_assignment(1234)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/stacks/forecast_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'create_assignment'`.

- [ ] **Step 3: Implement the write methods**

In `lib/stacks/forecast.rb`, add these public methods (after `roles`, before `private`):

```ruby
def create_assignment(project_id:, person_id:, start_date:, end_date:, allocation:, notes: "", active_on_days_off: false)
  body = { assignment: {
    project_id: project_id,
    person_id: person_id,
    start_date: start_date.to_s,
    end_date: end_date.to_s,
    allocation: allocation,
    notes: notes.to_s,
    active_on_days_off: active_on_days_off,
  } }
  response = self.class.post("/assignments", headers: write_headers, body: JSON.dump(body))
  raise "Forecast create_assignment failed: #{response.code} #{response.body}" unless response.success?
  response.parsed_response["assignment"]
end

def delete_assignment(forecast_id)
  response = self.class.delete("/assignments/#{forecast_id}", headers: write_headers)
  return true if response.success?
  return true if response.code == 404 # already gone — idempotent
  raise "Forecast delete_assignment failed: #{response.code} #{response.body}"
end
```

And in the `private` section add:

```ruby
def write_headers
  @headers.merge("Content-Type": "application/json")
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/stacks/forecast_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/forecast.rb test/lib/stacks/forecast_test.rb
git commit -m "feat(forecast): add create_assignment/delete_assignment write methods"
```

---

### Task 2: Migrations + models

**Files:**
- Create: `db/migrate/20260730000001_create_recurring_assignments.rb`
- Create: `db/migrate/20260730000002_create_recurring_assignment_occurrences.rb`
- Create: `app/models/recurring_assignment.rb`
- Create: `app/models/recurring_assignment_occurrence.rb`
- Test: `test/models/recurring_assignment_test.rb`
- Test: `test/models/recurring_assignment_occurrence_test.rb`

**Interfaces:**
- Produces:
  - `RecurringAssignment` columns: `forecast_person_id:bigint`, `forecast_project_id:bigint`, `allocation:integer` (sec/day), `active_on_days_off:boolean`, `notes:text`, `weekdays:integer[]` (0=Sun..6=Sat), `starts_on:date`, `ends_on:date?`, `paused_at:datetime?`.
  - `RecurringAssignment.active` scope (`where(paused_at: nil)`), `#paused?`, `HORIZON = 26.weeks`, `allocation_in_hours` / `allocation_in_hours=` accessors.
  - `RecurringAssignmentOccurrence` columns: `recurring_assignment_id`, `occurs_on:date`, `forecast_assignment_id:bigint?`, `status:string` (`materialized`|`deleted`). Scopes `.materialized`, `.deleted`. `STATUSES` constant.

- [ ] **Step 1: Write the migrations**

`db/migrate/20260730000001_create_recurring_assignments.rb`:

```ruby
class CreateRecurringAssignments < ActiveRecord::Migration[6.1]
  def change
    create_table :recurring_assignments do |t|
      t.bigint :forecast_person_id, null: false
      t.bigint :forecast_project_id, null: false
      t.integer :allocation, null: false
      t.boolean :active_on_days_off, null: false, default: false
      t.text :notes, null: false, default: ""
      t.integer :weekdays, array: true, null: false, default: [1, 2, 3, 4, 5]
      t.date :starts_on, null: false
      t.date :ends_on
      t.datetime :paused_at
      t.timestamps
    end
    add_index :recurring_assignments, :forecast_person_id
    add_index :recurring_assignments, :forecast_project_id
    add_index :recurring_assignments, :paused_at
  end
end
```

`db/migrate/20260730000002_create_recurring_assignment_occurrences.rb`:

```ruby
class CreateRecurringAssignmentOccurrences < ActiveRecord::Migration[6.1]
  def change
    create_table :recurring_assignment_occurrences do |t|
      t.references :recurring_assignment, null: false, foreign_key: true
      t.date :occurs_on, null: false
      t.bigint :forecast_assignment_id
      t.string :status, null: false, default: "materialized"
      t.timestamps
    end
    add_index :recurring_assignment_occurrences,
      [:recurring_assignment_id, :occurs_on],
      unique: true,
      name: "idx_recurring_occurrences_on_rule_and_date"
    add_index :recurring_assignment_occurrences, :forecast_assignment_id
  end
end
```

- [ ] **Step 2: Run the migrations**

Run: `bin/rails db:migrate`
Expected: both tables created; `db/schema.rb` updated.

- [ ] **Step 3: Write the failing model tests**

`test/models/recurring_assignment_test.rb`:

```ruby
require "test_helper"

class RecurringAssignmentTest < ActiveSupport::TestCase
  def valid_attrs(overrides = {})
    { forecast_person_id: 1, forecast_project_id: 2, allocation: 28_800,
      weekdays: [1, 2, 3, 4, 5], starts_on: Date.new(2026, 8, 3) }.merge(overrides)
  end

  test "valid with default attrs" do
    assert RecurringAssignment.new(valid_attrs).valid?
  end

  test "requires positive integer allocation" do
    assert_not RecurringAssignment.new(valid_attrs(allocation: 0)).valid?
    assert_not RecurringAssignment.new(valid_attrs(allocation: nil)).valid?
  end

  test "weekdays must be present and within 0..6" do
    assert_not RecurringAssignment.new(valid_attrs(weekdays: [])).valid?
    assert_not RecurringAssignment.new(valid_attrs(weekdays: [7])).valid?
    assert RecurringAssignment.new(valid_attrs(weekdays: [0, 6])).valid?
  end

  test "ends_on must not precede starts_on" do
    assert_not RecurringAssignment.new(valid_attrs(ends_on: Date.new(2026, 8, 2))).valid?
    assert RecurringAssignment.new(valid_attrs(ends_on: Date.new(2026, 8, 3))).valid?
  end

  test "active scope excludes paused rows" do
    a = RecurringAssignment.create!(valid_attrs)
    b = RecurringAssignment.create!(valid_attrs(paused_at: Time.current))
    assert_includes RecurringAssignment.active, a
    assert_not_includes RecurringAssignment.active, b
  end

  test "allocation_in_hours converts to/from seconds" do
    ra = RecurringAssignment.new(valid_attrs(allocation: 28_800))
    assert_equal 8.0, ra.allocation_in_hours
    ra.allocation_in_hours = 4
    assert_equal 14_400, ra.allocation
  end
end
```

`test/models/recurring_assignment_occurrence_test.rb`:

```ruby
require "test_helper"

class RecurringAssignmentOccurrenceTest < ActiveSupport::TestCase
  setup do
    @ra = RecurringAssignment.create!(
      forecast_person_id: 1, forecast_project_id: 2, allocation: 900,
      weekdays: [1], starts_on: Date.new(2026, 8, 3),
    )
  end

  test "status must be a known value" do
    occ = @ra.recurring_assignment_occurrences.new(occurs_on: Date.new(2026, 8, 3), status: "bogus")
    assert_not occ.valid?
  end

  test "materialized/deleted scopes" do
    m = @ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 3), status: "materialized")
    d = @ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 10), status: "deleted")
    assert_includes RecurringAssignmentOccurrence.materialized, m
    assert_includes RecurringAssignmentOccurrence.deleted, d
  end

  test "occurs_on is unique per rule" do
    @ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 3))
    dup = @ra.recurring_assignment_occurrences.new(occurs_on: Date.new(2026, 8, 3))
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end
end
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `bin/rails test test/models/recurring_assignment_test.rb test/models/recurring_assignment_occurrence_test.rb`
Expected: FAIL — models not defined.

- [ ] **Step 5: Write the models**

`app/models/recurring_assignment.rb`:

```ruby
class RecurringAssignment < ApplicationRecord
  HORIZON = 26.weeks

  belongs_to :forecast_person, class_name: "ForecastPerson",
    foreign_key: "forecast_person_id", primary_key: "forecast_id", optional: true
  belongs_to :forecast_project, class_name: "ForecastProject",
    foreign_key: "forecast_project_id", primary_key: "forecast_id", optional: true
  has_many :recurring_assignment_occurrences, dependent: :destroy

  validates :forecast_person_id, presence: true
  validates :forecast_project_id, presence: true
  validates :allocation, presence: true, numericality: { greater_than: 0, only_integer: true }
  validates :starts_on, presence: true
  validate :weekdays_valid
  validate :ends_on_not_before_starts_on

  scope :active, -> { where(paused_at: nil) }

  def paused?
    paused_at.present?
  end

  def allocation_in_hours
    allocation && allocation / 3600.0
  end

  def allocation_in_hours=(hours)
    self.allocation = (hours.to_f * 3600).round
  end

  private

  def weekdays_valid
    if weekdays.blank?
      errors.add(:weekdays, "must include at least one day")
    elsif weekdays.any? { |d| !(0..6).cover?(d) }
      errors.add(:weekdays, "must be integers 0 (Sun) through 6 (Sat)")
    end
  end

  def ends_on_not_before_starts_on
    return if ends_on.blank? || starts_on.blank?
    errors.add(:ends_on, "cannot be before starts_on") if ends_on < starts_on
  end
end
```

`app/models/recurring_assignment_occurrence.rb`:

```ruby
class RecurringAssignmentOccurrence < ApplicationRecord
  STATUSES = %w[materialized deleted].freeze

  belongs_to :recurring_assignment

  validates :occurs_on, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :materialized, -> { where(status: "materialized") }
  scope :deleted, -> { where(status: "deleted") }
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/models/recurring_assignment_test.rb test/models/recurring_assignment_occurrence_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260730000001_create_recurring_assignments.rb db/migrate/20260730000002_create_recurring_assignment_occurrences.rb db/schema.rb app/models/recurring_assignment.rb app/models/recurring_assignment_occurrence.rb test/models/recurring_assignment_test.rb test/models/recurring_assignment_occurrence_test.rb
git commit -m "feat(recurring-assignments): add RecurringAssignment + Occurrence models"
```

---

### Task 3: `RecurringAssignment#materialize!`

**Files:**
- Modify: `app/models/recurring_assignment.rb`
- Test: `test/models/recurring_assignment_materialize_test.rb`

**Interfaces:**
- Consumes: `Stacks::Forecast#create_assignment` (Task 1), `ForecastAssignment.exists?(forecast_id:)`.
- Produces: `RecurringAssignment#materialize!(forecast_client: nil)` — deletion-detection pass then creation pass; idempotent; returns nothing meaningful. `#expected_occurrence_dates` (public, for testing the horizon).

- [ ] **Step 1: Write the failing tests**

`test/models/recurring_assignment_materialize_test.rb`:

```ruby
require "test_helper"

class RecurringAssignmentMaterializeTest < ActiveSupport::TestCase
  def build_client
    Stacks::Forecast.allocate.tap { |c| c.instance_variable_set(:@headers, {}) }
  end

  def rule(overrides = {})
    RecurringAssignment.create!({
      forecast_person_id: 324711, forecast_project_id: 3033811, allocation: 900,
      weekdays: [1], starts_on: Date.new(2026, 8, 3), ends_on: Date.new(2026, 8, 24),
    }.merge(overrides))
  end

  test "creates one Forecast assignment per expected weekday and records occurrences" do
    ra = rule # Mondays 2026-08-03,10,17,24 => 4 occurrences
    client = build_client
    client.expects(:create_assignment).times(4).returns(
      { "id" => 1 }, { "id" => 2 }, { "id" => 3 }, { "id" => 4 }
    )

    ra.materialize!(forecast_client: client)

    occ = ra.recurring_assignment_occurrences.order(:occurs_on)
    assert_equal 4, occ.count
    assert_equal [Date.new(2026,8,3), Date.new(2026,8,10), Date.new(2026,8,17), Date.new(2026,8,24)], occ.map(&:occurs_on)
    assert occ.all? { |o| o.status == "materialized" && o.forecast_assignment_id.present? }
  end

  test "is idempotent — a second run POSTs nothing new" do
    ra = rule
    c1 = build_client
    c1.stubs(:create_assignment).returns({ "id" => 1 })
    ra.materialize!(forecast_client: c1)
    assert_equal 4, ra.recurring_assignment_occurrences.count

    c2 = build_client
    c2.expects(:create_assignment).never
    ra.materialize!(forecast_client: c2)
    assert_equal 4, ra.recurring_assignment_occurrences.count
  end

  test "tombstones an occurrence whose Forecast assignment was deleted in the UI" do
    ra = rule(ends_on: Date.new(2026, 8, 3)) # single Monday
    # present-in-mirror occurrence stays materialized; absent one gets tombstoned.
    # save!(validate: false) skips the required belongs_to person/project — we only
    # need a bare mirror row for the exists?(forecast_id:) check.
    ForecastAssignment.new(forecast_id: 555).save!(validate: false)
    kept = ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 3), status: "materialized", forecast_assignment_id: 555)
    gone = ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 7, 27), status: "materialized", forecast_assignment_id: 999)

    client = build_client
    client.expects(:create_assignment).never # both dates already have occurrence rows
    ra.materialize!(forecast_client: client)

    assert_equal "materialized", kept.reload.status
    assert_equal "deleted", gone.reload.status
  end

  test "never recreates a tombstoned occurrence" do
    ra = rule(ends_on: Date.new(2026, 8, 3)) # single Monday 08-03
    ra.recurring_assignment_occurrences.create!(occurs_on: Date.new(2026, 8, 3), status: "deleted", forecast_assignment_id: 111)

    client = build_client
    client.expects(:create_assignment).never
    ra.materialize!(forecast_client: client)

    assert_equal 1, ra.recurring_assignment_occurrences.count
    assert_equal "deleted", ra.recurring_assignment_occurrences.first.status
  end

  test "open-ended rule stops at the 26-week horizon" do
    ra = rule(starts_on: Date.today, ends_on: nil, weekdays: [Date.today.wday])
    dates = ra.expected_occurrence_dates
    assert dates.max <= Date.today + RecurringAssignment::HORIZON
    assert dates.max > Date.today + (RecurringAssignment::HORIZON - 1.week)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/recurring_assignment_materialize_test.rb`
Expected: FAIL — `materialize!` / `expected_occurrence_dates` undefined.

- [ ] **Step 3: Implement `materialize!`**

Add to `app/models/recurring_assignment.rb` (public section):

```ruby
# Idempotent. Pass 1 tombstones occurrences deleted in Forecast (absent from the
# freshly-synced ForecastAssignment mirror); Pass 2 creates any missing occurrence.
# MUST run after Stacks::Forecast#sync_all! so the mirror is authoritative — see the
# daily_tasks wiring. Detection runs BEFORE creation so this-run creations are never
# mistaken for deletions.
def materialize!(forecast_client: nil)
  return if paused?
  detect_deletions!
  create_missing_occurrences!(forecast_client || Stacks::Forecast.new)
end

def expected_occurrence_dates
  last = [ends_on, Date.today + HORIZON].compact.min
  return [] if starts_on > last
  (starts_on..last).select { |d| weekdays.include?(d.wday) }
end
```

And in the `private` section:

```ruby
def detect_deletions!
  recurring_assignment_occurrences.materialized.where.not(forecast_assignment_id: nil).find_each do |occ|
    next if ForecastAssignment.exists?(forecast_id: occ.forecast_assignment_id)
    occ.update!(status: "deleted")
  end
end

def create_missing_occurrences!(forecast_client)
  existing = recurring_assignment_occurrences.pluck(:occurs_on).to_set
  expected_occurrence_dates.each do |date|
    next if existing.include?(date)
    begin
      assignment = forecast_client.create_assignment(
        project_id: forecast_project_id,
        person_id: forecast_person_id,
        start_date: date,
        end_date: date,
        allocation: allocation,
        notes: notes,
        active_on_days_off: active_on_days_off,
      )
      recurring_assignment_occurrences.create!(
        occurs_on: date,
        status: "materialized",
        forecast_assignment_id: assignment["id"],
      )
    rescue => e
      Sentry.capture_exception(e)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/recurring_assignment_materialize_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/recurring_assignment.rb test/models/recurring_assignment_materialize_test.rb
git commit -m "feat(recurring-assignments): materialize! with tombstone-on-delete"
```

---

### Task 4: Destroy cleanup — remove future Forecast assignments

**Files:**
- Modify: `app/models/recurring_assignment.rb`
- Test: `test/models/recurring_assignment_destroy_test.rb`

**Interfaces:**
- Consumes: `Stacks::Forecast#delete_assignment` (Task 1).
- Produces: `before_destroy` deletes future (`occurs_on >= Date.today`) materialized occurrences from Forecast via `#remove_future_forecast_assignments!(forecast_client = Stacks::Forecast.new)`.

- [ ] **Step 1: Write the failing test**

`test/models/recurring_assignment_destroy_test.rb`:

```ruby
require "test_helper"

class RecurringAssignmentDestroyTest < ActiveSupport::TestCase
  test "destroying a rule deletes future materialized occurrences from Forecast, not past ones" do
    ra = RecurringAssignment.create!(
      forecast_person_id: 1, forecast_project_id: 2, allocation: 900,
      weekdays: [1], starts_on: Date.today - 30,
    )
    past   = ra.recurring_assignment_occurrences.create!(occurs_on: Date.today - 7, status: "materialized", forecast_assignment_id: 100)
    future = ra.recurring_assignment_occurrences.create!(occurs_on: Date.today + 7, status: "materialized", forecast_assignment_id: 200)
    tomb   = ra.recurring_assignment_occurrences.create!(occurs_on: Date.today + 8, status: "deleted",      forecast_assignment_id: 300)

    client = Stacks::Forecast.allocate.tap { |c| c.instance_variable_set(:@headers, {}) }
    Stacks::Forecast.stubs(:new).returns(client)
    client.expects(:delete_assignment).with(200).once.returns(true)
    # past (100) and tombstoned (300) must NOT be deleted
    client.expects(:delete_assignment).with(100).never
    client.expects(:delete_assignment).with(300).never

    ra.destroy!
    assert_equal 0, RecurringAssignmentOccurrence.where(recurring_assignment_id: ra.id).count
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/recurring_assignment_destroy_test.rb`
Expected: FAIL — no delete happens (`delete_assignment` expected once, called never).

- [ ] **Step 3: Implement the callback**

Add to `app/models/recurring_assignment.rb`:

```ruby
# (near the associations)
before_destroy :remove_future_forecast_assignments!
```

```ruby
# (public method)
# Deletes only FUTURE materialized occurrences from Forecast on rule teardown;
# past occurrences are left for historical accuracy, tombstoned ones are already gone.
def remove_future_forecast_assignments!(forecast_client = Stacks::Forecast.new)
  recurring_assignment_occurrences
    .materialized
    .where.not(forecast_assignment_id: nil)
    .where("occurs_on >= ?", Date.today)
    .find_each { |occ| forecast_client.delete_assignment(occ.forecast_assignment_id) }
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/recurring_assignment_destroy_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/recurring_assignment.rb test/models/recurring_assignment_destroy_test.rb
git commit -m "feat(recurring-assignments): delete future Forecast assignments on rule destroy"
```

---

### Task 5: Wire materialization into the daily cron

**Files:**
- Modify: `lib/tasks/stacks.rake` (inside `stacks:daily_tasks`, immediately after line 511 `Stacks::Forecast.new.sync_all!`)

**Interfaces:**
- Consumes: `RecurringAssignment.active`, `#materialize!` (Task 3).

- [ ] **Step 1: Add the materialization loop**

In `lib/tasks/stacks.rake`, directly after `Stacks::Forecast.new.sync_all!` (~line 511), insert:

```ruby
      # Materialize Stacks-owned recurring assignments into Forecast. MUST run
      # right after sync_all! so the ForecastAssignment mirror is fresh — that's
      # how materialize! distinguishes "deleted in the UI" from "not yet synced".
      forecast_client = Stacks::Forecast.new
      RecurringAssignment.active.find_each do |ra|
        begin
          ra.materialize!(forecast_client: forecast_client)
        rescue => e
          Sentry.capture_exception(e)
        end
      end
```

- [ ] **Step 2: Verify the file parses**

Run: `bin/rails runner 'puts "ok"'`
Expected: prints `ok` (Rails loads the rake-adjacent code without syntax error). Also run `ruby -c lib/tasks/stacks.rake` → `Syntax OK`.

- [ ] **Step 3: Commit**

```bash
git add lib/tasks/stacks.rake
git commit -m "feat(recurring-assignments): materialize active rules after daily Forecast sync"
```

---

### Task 6: ActiveAdmin UI

**Files:**
- Create: `app/admin/recurring_assignments.rb`

**Interfaces:**
- Consumes: `RecurringAssignment` (models + `materialize!` + `allocation_in_hours`), `ForecastPerson.active`, `ForecastProject.active`.

- [ ] **Step 1: Write the admin resource**

`app/admin/recurring_assignments.rb`:

```ruby
ActiveAdmin.register RecurringAssignment do
  menu label: "Recurring Assignments", parent: "Team"
  config.filters = false
  actions :index, :new, :create, :edit, :update, :destroy

  WEEKDAY_CHOICES = [%w[Mon 1], %w[Tue 2], %w[Wed 3], %w[Thu 4], %w[Fri 5], %w[Sat 6], %w[Sun 0]].freeze

  permit_params :forecast_person_id, :forecast_project_id, :allocation_in_hours,
    :active_on_days_off, :notes, :starts_on, :ends_on, :paused_at, weekdays: []

  controller do
    def scoped_collection
      super.includes(:forecast_person, :forecast_project, :recurring_assignment_occurrences)
    end
  end

  action_item :materialize_now, only: :edit do
    link_to "Materialize Now",
      materialize_now_admin_recurring_assignment_path(resource),
      method: :post,
      data: { confirm: "Create/refresh Forecast assignments for this rule now?" }
  end

  member_action :materialize_now, method: :post do
    resource.materialize!
    redirect_to edit_admin_recurring_assignment_path(resource), notice: "Materialized."
  rescue => e
    redirect_to edit_admin_recurring_assignment_path(resource), alert: e.message
  end

  action_item :toggle_pause, only: :edit do
    link_to(resource.paused? ? "Resume" : "Pause",
      toggle_pause_admin_recurring_assignment_path(resource), method: :post)
  end

  member_action :toggle_pause, method: :post do
    resource.update!(paused_at: resource.paused? ? nil : Time.current)
    redirect_to edit_admin_recurring_assignment_path(resource),
      notice: resource.paused? ? "Paused." : "Resumed."
  end

  index download_links: false do
    column(:person) { |r| r.forecast_person&.email || "Person ##{r.forecast_person_id}" }
    column(:project) { |r| r.forecast_project&.name || "Project ##{r.forecast_project_id}" }
    column(:hours_per_day) { |r| r.allocation_in_hours }
    column(:weekdays) { |r| r.weekdays.sort.map { |d| Date::ABBR_DAYNAMES[d] }.join(", ") }
    column :starts_on
    column :ends_on
    column(:occurrences) do |r|
      m = r.recurring_assignment_occurrences.count { |o| o.status == "materialized" }
      d = r.recurring_assignment_occurrences.count { |o| o.status == "deleted" }
      "#{m} live / #{d} deleted"
    end
    column(:status) { |r| r.paused? ? status_tag("Paused") : status_tag("Active") }
    actions
  end

  show do
    attributes_table do
      row(:person) { |r| r.forecast_person&.email }
      row(:project) { |r| r.forecast_project&.name }
      row(:hours_per_day) { |r| r.allocation_in_hours }
      row(:weekdays) { |r| r.weekdays.sort.map { |d| Date::ABBR_DAYNAMES[d] }.join(", ") }
      row :starts_on
      row :ends_on
      row :active_on_days_off
      row :notes
      row(:status) { |r| r.paused? ? "Paused" : "Active" }
    end
    panel "Occurrences" do
      table_for resource.recurring_assignment_occurrences.order(occurs_on: :desc) do
        column :occurs_on
        column :status
        column(:forecast_assignment) do |o|
          if o.forecast_assignment_id
            link_to o.forecast_assignment_id,
              "https://forecastapp.com/#{Stacks::Utils.config[:forecast][:account_id]}/schedule/projects/#{o.recurring_assignment.forecast_project_id}/assignments/#{o.forecast_assignment_id}/edit",
              target: "_blank"
          end
        end
      end
    end
  end

  form do |f|
    f.semantic_errors
    f.inputs do
      f.input :forecast_person_id, as: :select,
        collection: ForecastPerson.active.order(:email).map { |p| [p.email, p.forecast_id] },
        prompt: "Choose a person…"
      f.input :forecast_project_id, as: :select,
        collection: ForecastProject.active.map { |p| [p.name, p.forecast_id] }.sort_by(&:first),
        prompt: "Choose a project…"
      f.input :allocation_in_hours, label: "Hours per day", hint: "Stored as seconds/day for Forecast."
      f.input :weekdays, as: :check_boxes, collection: WEEKDAY_CHOICES
      f.input :starts_on, as: :datepicker
      f.input :ends_on, as: :datepicker, hint: "Leave blank for open-ended (materializes 26 weeks ahead, extending each day)."
      f.input :active_on_days_off
      f.input :notes
    end
    f.actions
  end
end
```

- [ ] **Step 2: Smoke-test that admin + app boot cleanly**

Run: `bin/rails runner 'ActiveAdmin.application.namespaces[:admin].resources.keys.include?("RecurringAssignment") ? puts("registered") : abort("missing")'`
Expected: prints `registered` (resource loads, no NameError/syntax error in the admin file).

- [ ] **Step 3: Commit**

```bash
git add app/admin/recurring_assignments.rb
git commit -m "feat(recurring-assignments): ActiveAdmin CRUD + materialize-now UI"
```

---

## Self-Review

**Spec coverage:**
- Ownership model (create + respect-delete, no reconcile) → Task 3 (`materialize!`).
- Data model (both tables/models, validations, scopes) → Task 2.
- Forecast write API (create + delete only) → Task 1.
- Deletion detection before creation, inline-after-sync rationale → Task 3 + Task 5.
- 26-week horizon → Task 3 (`expected_occurrence_dates` + test).
- One-assignment-per-day → Task 3 (`start_date == end_date == date`).
- Scheduling/wiring → Task 5.
- Rule destroy (future-only cleanup) → Task 4.
- Admin UI (form/index/show/materialize-now, hours↔seconds, weekdays checkboxes) → Task 6.
- Testing conventions (Mocha class-method stubs, `allocate`+`@headers`) → Tasks 1 & 3.

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `create_assignment` keyword args match between Task 1 definition and Task 3 call site; `forecast_assignment_id`, `status` (`"materialized"`/`"deleted"`), `occurs_on`, `allocation_in_hours`, `expected_occurrence_dates`, `materialize!(forecast_client:)`, `remove_future_forecast_assignments!` are used identically across tasks.
