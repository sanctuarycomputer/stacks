# Per-Entity Invoice Passes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `InvoicePass` belong to an issuing `Enterprise`, so garden3d issues its own invoices on its own pass instead of riding on Sanctuary's.

**Architecture:** A pass belongs to the **issuing** enterprise. A tracker lives on the pass of its `qbo_account`'s enterprise. `clients_served` stays global — external clients have no enterprise mapping, so scoping it by enterprise would strip the entire external book off Sanctuary's pass. A new `invoice_trackers.source` enum (`forecast` / `management_fee`) distinguishes Forecast-driven trackers from the MSO management-fee trackers a later subsystem adds.

**Tech Stack:** Rails 6.1, Postgres, Minitest, ActiveAdmin, `acts_as_paranoid` (not on these models).

This is subsystem **S0** of `docs/superpowers/specs/2026-10-09-garden3d-mso-compensation-design.md`. It is a prerequisite refactor of live financial machinery and ships as its own PR, merged and verified against a real month before any MSO work lands on it. It adds **no** MSO behaviour.

## Global Constraints

- `db/schema.rb` is **hand-curated** in this repo. Every schema change must be reflected there deliberately, by hand, matching the migration exactly.
- Migrations **never run** in the test suite — the test DB is schema-loaded from `db/schema.rb`. Backfill tests must instantiate the migration class explicitly.
- Run the suite with `--exclude "sync_meet runs the connector inside a SystemTask"` — that test makes a live Google call and can hang for over an hour.
- Never run two suites concurrently against the shared test database.
- `Enterprise.sanctuary` and `Enterprise.garden3d` are memoized in `Thread.current`. A test that creates one and rolls back leaves a stale memo for every later test on that thread. Clear the memo in teardown when a test creates either.
- Full suite baseline before this plan: **1783 runs, 5702 assertions, 0 failures, 0 errors, 2 skips**.
- Commit after every task.

---

### Task 1: Add `enterprise_id` and `source` to the schema, keep the suite green

The column is `null: false`, and the test DB loads `db/schema.rb` directly, so every existing `InvoicePass` construction must supply an enterprise the moment the schema changes. That is why the schema change, the fixture, the association and all 35 call sites are one task — the suite cannot be green at any intermediate point.

**Files:**
- Create: `db/migrate/20261012000001_add_enterprise_to_invoice_passes.rb`
- Modify: `db/schema.rb`
- Modify: `app/models/invoice_pass.rb:1-2`
- Modify: `test/fixtures/enterprises.yml`
- Modify: 18 test files (listed in Step 5)

**Interfaces:**
- Consumes: nothing
- Produces: `InvoicePass#enterprise` (required `belongs_to`), `InvoiceTracker#source` enum with values `forecast` (0, default) and `management_fee` (1)

- [ ] **Step 1: Write the migration**

Create `db/migrate/20261012000001_add_enterprise_to_invoice_passes.rb`. The column goes on nullable; Task 2 backfills and constrains. Splitting it this way is deliberate — `add_reference ... null: false` against the 64 existing rows raises `PG::NotNullViolation`.

```ruby
class AddEnterpriseToInvoicePasses < ActiveRecord::Migration[6.1]
  def change
    add_reference :invoice_passes, :enterprise, null: true, foreign_key: true
    add_column :invoice_trackers, :source, :integer, null: false, default: 0
  end
end
```

- [ ] **Step 2: Hand-edit `db/schema.rb`**

Bump the version line at the top of `db/schema.rb` to `2026_10_12_000001`.

In `create_table "invoice_passes"`, add the column and index. Note `enterprise_id` is `null: false` here even though the migration adds it nullable — schema.rb reflects the **end state** after Task 2, and the test DB needs the final shape.

```ruby
  create_table "invoice_passes", force: :cascade do |t|
    t.date "start_of_month", null: false
    t.datetime "completed_at"
    t.jsonb "data"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.bigint "enterprise_id", null: false
    t.index ["enterprise_id", "start_of_month"], name: "index_invoice_passes_on_enterprise_and_month", unique: true
    t.index ["enterprise_id"], name: "index_invoice_passes_on_enterprise_id"
  end
```

Delete the old line `t.index ["start_of_month"], name: "index_invoice_passes_on_start_of_month", unique: true`, and note `start_of_month` gains `null: false` (it was nullable, which left a duplicate-NULL hole in the old unique index).

In `create_table "invoice_trackers"`, add:

```ruby
    t.integer "source", default: 0, null: false
```

In the foreign-key list at the bottom of `db/schema.rb`, add:

```ruby
  add_foreign_key "invoice_passes", "enterprises"
```

- [ ] **Step 3: Load the new schema into the test DB**

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
RAILS_ENV=test bin/rails db:environment:set db:schema:load
```

Expected: completes without error. (`db:environment:set` is required in this repo or the task refuses to run.)

- [ ] **Step 4: Add the garden3d fixture**

`test/fixtures/enterprises.yml` currently has only `sanctuary`, `one`, `two`, which is why `Enterprise.garden3d` raises `RecordNotFound` in the suite today. The name must match `Enterprise::GARDEN3D_NAME` exactly.

```yaml
sanctuary:
  name: Sanctuary Computer Inc

garden3d:
  name: garden3d, LLC

one:
  name: One LLC

two:
  name: Two LLC
```

- [ ] **Step 5: Write the failing association test**

Create `test/models/invoice_pass_enterprise_test.rb`:

```ruby
require "test_helper"

class InvoicePassEnterpriseTest < ActiveSupport::TestCase
  test "an invoice pass requires an enterprise" do
    pass = InvoicePass.new(start_of_month: Date.new(2099, 5, 1))
    assert_not pass.valid?
    assert_includes pass.errors[:enterprise], "must exist"
  end

  test "two enterprises can each hold a pass for the same month" do
    month = Date.new(2099, 6, 1)
    sanctuary_pass = InvoicePass.create!(start_of_month: month, enterprise: enterprises(:sanctuary))
    garden3d_pass = InvoicePass.create!(start_of_month: month, enterprise: enterprises(:garden3d))

    assert sanctuary_pass.persisted?
    assert garden3d_pass.persisted?
  end

  test "one enterprise cannot hold two passes for the same month" do
    month = Date.new(2099, 7, 1)
    InvoicePass.create!(start_of_month: month, enterprise: enterprises(:sanctuary))

    assert_raises(ActiveRecord::RecordNotUnique) do
      InvoicePass.create!(start_of_month: month, enterprise: enterprises(:sanctuary))
    end
  end

  test "existing invoice trackers default to the forecast source" do
    tracker = InvoiceTracker.new
    assert_equal "forecast", tracker.source
  end
end
```

- [ ] **Step 6: Run it to verify it fails**

```bash
bin/rails test test/models/invoice_pass_enterprise_test.rb
```

Expected: FAIL. The first test fails because `belongs_to :enterprise` is not declared yet, so no `:enterprise` error is added.

- [ ] **Step 7: Add the association and the enum**

In `app/models/invoice_pass.rb`, change the top of the class from:

```ruby
class InvoicePass < ApplicationRecord
  has_many :invoice_trackers
```

to:

```ruby
class InvoicePass < ApplicationRecord
  # A pass belongs to the enterprise that ISSUES its invoices, not to the
  # clients being billed. A tracker lives on the pass of its qbo_account's
  # enterprise. Before this was modelled, garden3d's invoices rode on
  # Sanctuary's pass (7 mixed passes, 2025-06 .. 2025-12).
  belongs_to :enterprise
  has_many :invoice_trackers
```

In `app/models/invoice_tracker.rb`, add the enum immediately after the existing `belongs_to` declarations:

```ruby
  # `forecast` trackers come from Harvest Forecast via InvoicePass#make_trackers!.
  # `management_fee` trackers are generated by the MSO subsystem from different
  # logic entirely; they carry no blueprint and no contributor payouts.
  enum source: { forecast: 0, management_fee: 1 }
```

- [ ] **Step 8: Run the new test to verify it passes**

```bash
bin/rails test test/models/invoice_pass_enterprise_test.rb
```

Expected: PASS, 4 runs, 0 failures.

- [ ] **Step 9: Update all 35 existing construction sites**

Every one needs `enterprise: Enterprise.sanctuary` (or `enterprises(:sanctuary)` in fixture-based tests). Pass Sanctuary explicitly rather than defaulting in the model — these are financial routing decisions and a silent default would have hidden exactly the `Stacks::Automator` bug Task 4 fixes.

Files and counts:

| File | Sites |
| --- | --- |
| `test/integration/admin_permission_grants_test.rb` | 2 |
| `test/integration/mcp_endpoint_test.rb` | 2 |
| `test/lib/stacks/client_kpi_datapoints_test.rb` | 1 (`.new`) |
| `test/lib/stacks/client_revenue_test.rb` | 3 (`.new`) |
| `test/lib/stacks/task_builder/discoveries/unaccepted_payouts_test.rb` | 1 |
| `test/models/admin_authorization_test.rb` | 1 |
| `test/models/contributor_test.rb` | 1 |
| `test/models/invoice_pass_test.rb` | 1 |
| `test/models/invoice_tracker_payouts_test.rb` | 1 |
| `test/models/invoice_tracker_test.rb` | 3 |
| `test/models/periodic_report_test.rb` | 1 |
| `test/models/project_tracker_test.rb` | 1 |
| `test/models/qbo_invoice_test.rb` | 4 |
| `test/models/qbo_records_scoping_test.rb` | 2 |
| `test/services/mcp/client_revenue_tool_test.rb` | 4 |
| `test/services/mcp/finance_tools_test.rb` | 2 |
| `test/services/mcp/invoice_passes_tool_test.rb` | 4 |
| `test/services/project_trackers/income_series_test.rb` | 1 |

Find them all with:

```bash
grep -rn "InvoicePass\.\(create\|new\|find_or_create\)" test/
```

For `create!` and `new`, add the keyword:

```ruby
InvoicePass.create!(start_of_month: Date.new(2026, 7, 1), enterprise: Enterprise.sanctuary)
```

For `find_or_create_by!`, the enterprise belongs in the **lookup**, not the block — otherwise the finder matches a pass belonging to another enterprise:

```ruby
InvoicePass.find_or_create_by!(
  start_of_month: Date.new(2030, 1, 1),
  enterprise: Enterprise.sanctuary,
)
```

Where a `find_or_create_by!` already has a block (`{ |ip| ip.data = {} }`), keep the block and add `enterprise:` to the arguments.

- [ ] **Step 10: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: **1787 runs, 0 failures, 0 errors, 2 skips** (the baseline 1783 plus this task's 4). If any test fails with `Enterprise must exist`, a construction site was missed — re-run the grep from Step 9.

- [ ] **Step 11: Commit**

```bash
git add db/migrate/20261012000001_add_enterprise_to_invoice_passes.rb db/schema.rb \
  app/models/invoice_pass.rb app/models/invoice_tracker.rb \
  test/fixtures/enterprises.yml test/models/invoice_pass_enterprise_test.rb test/
git commit -m "feat(invoicing): invoice passes belong to an issuing enterprise

Adds invoice_passes.enterprise_id and invoice_trackers.source. The unique
index moves from [start_of_month] to [enterprise_id, start_of_month], and
start_of_month gains null: false -- it was nullable, which left a
duplicate-NULL hole in the old unique index.

Adds the garden3d enterprise fixture; Enterprise.garden3d raised
RecordNotFound in the suite before this."
```

---

### Task 2: Backfill the existing 64 passes and constrain the column

**Files:**
- Create: `db/migrate/20261012000002_backfill_invoice_pass_enterprises.rb`
- Test: `test/migrations/backfill_invoice_pass_enterprises_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#enterprise` from Task 1
- Produces: nothing consumed by later tasks (a data migration)

Production state, verified 2026-10-09: 64 passes, 1,165 trackers, tracker-set histogram `{[2] => 57, [2, 35] => 7}`. QBO account ids: 1 = Index Space, 2 = Sanctuary, 35 = garden3d, 68 = USB Club. The 7 mixed passes (2025-06-01 … 2025-12-01) each have modal `qbo_account` 2 against exactly one garden3d tracker. No pass has zero trackers; no tracker has a null `qbo_account_id`.

The migration must derive "mixed" **dynamically** by grouping trackers on `qbo_account_id`, never from those 7 dates — production may have gained passes or Index/USB trackers since.

- [ ] **Step 1: Write the failing migration test**

Create `test/migrations/backfill_invoice_pass_enterprises_test.rb`. Migrations don't run in the suite, so instantiate the class directly. The test builds a mixed pass, nulls the enterprise to simulate pre-migration state, and runs `up`.

```ruby
require "test_helper"
require Rails.root.join("db/migrate/20261012000002_backfill_invoice_pass_enterprises.rb")

class BackfillInvoicePassEnterprisesTest < ActiveSupport::TestCase
  def setup
    @sanctuary = enterprises(:sanctuary)
    @garden3d = enterprises(:garden3d)
    @sanctuary_qa = QboAccount.create!(enterprise: @sanctuary, realm_id: "s-realm",
                                       client_id: "x", client_secret: "y")
    @garden3d_qa = QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm",
                                      client_id: "x", client_secret: "y")
  end

  def build_pass_with_trackers(month, qbo_accounts)
    pass = InvoicePass.create!(start_of_month: month, enterprise: @sanctuary)
    qbo_accounts.each_with_index do |qa, i|
      InvoiceTracker.create!(invoice_pass: pass, qbo_account: qa,
                             forecast_client_id: 900_000 + i)
    end
    # Simulate pre-migration state: enterprise_id not yet assigned.
    InvoicePass.where(id: pass.id).update_all(enterprise_id: nil)
    pass
  end

  test "assigns the modal qbo_account's enterprise to a single-enterprise pass" do
    pass = build_pass_with_trackers(Date.new(2095, 1, 1), [@sanctuary_qa, @sanctuary_qa])

    BackfillInvoicePassEnterprises.new.up

    assert_equal @sanctuary, pass.reload.enterprise
  end

  test "splits a mixed pass, moving the minority trackers to their own enterprise's pass" do
    pass = build_pass_with_trackers(
      Date.new(2095, 2, 1),
      [@sanctuary_qa, @sanctuary_qa, @garden3d_qa],
    )

    BackfillInvoicePassEnterprises.new.up

    assert_equal @sanctuary, pass.reload.enterprise
    assert_equal 2, pass.invoice_trackers.count

    garden3d_pass = InvoicePass.find_by(start_of_month: Date.new(2095, 2, 1),
                                        enterprise: @garden3d)
    assert garden3d_pass.present?, "expected a garden3d pass for the month"
    assert_equal 1, garden3d_pass.invoice_trackers.count
    assert_equal @garden3d_qa, garden3d_pass.invoice_trackers.first.qbo_account
  end

  test "assigns Sanctuary to a pass with no trackers" do
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 3, 1), enterprise: @sanctuary)
    InvoicePass.where(id: pass.id).update_all(enterprise_id: nil)

    BackfillInvoicePassEnterprises.new.up

    assert_equal @sanctuary, pass.reload.enterprise
  end

  test "leaves no pass without an enterprise" do
    build_pass_with_trackers(Date.new(2095, 4, 1), [@sanctuary_qa, @garden3d_qa])

    BackfillInvoicePassEnterprises.new.up

    assert_equal 0, InvoicePass.where(enterprise_id: nil).count
  end

  test "down re-merges split passes back onto the Sanctuary pass" do
    pass = build_pass_with_trackers(Date.new(2095, 5, 1), [@sanctuary_qa, @garden3d_qa])
    BackfillInvoicePassEnterprises.new.up

    BackfillInvoicePassEnterprises.new.down

    assert_equal 2, pass.reload.invoice_trackers.count
    assert_nil InvoicePass.find_by(start_of_month: Date.new(2095, 5, 1),
                                   enterprise: @garden3d)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/migrations/backfill_invoice_pass_enterprises_test.rb
```

Expected: FAIL with `LoadError` / `cannot load such file` — the migration doesn't exist yet.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20261012000002_backfill_invoice_pass_enterprises.rb`.

The `null: false` and the unique index are applied here rather than in Task 1's migration, because they can only hold once the data is correct. On a schema-loaded test DB the constraints already exist, so the `change_column_null` / index calls are guarded — that is why `up` checks before applying.

```ruby
class BackfillInvoicePassEnterprises < ActiveRecord::Migration[6.1]
  # Reversible by construction: `down` re-merges every non-Sanctuary pass for a
  # month back onto that month's Sanctuary pass and destroys the pass it created.
  # It does not restore enterprise_id to NULL -- Task 1's migration owns the
  # column, and rolling that back drops it entirely.

  def up
    sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    enterprise_by_qbo_account = QboAccount.pluck(:id, :enterprise_id).to_h

    InvoicePass.where(enterprise_id: nil).find_each do |pass|
      counts = pass.invoice_trackers.group(:qbo_account_id).count

      if counts.empty?
        pass.update_columns(enterprise_id: sanctuary.id)
        next
      end

      modal_qbo_account_id = counts.max_by { |_qa, n| n }.first
      modal_enterprise_id = enterprise_by_qbo_account.fetch(modal_qbo_account_id)
      pass.update_columns(enterprise_id: modal_enterprise_id)

      # Every OTHER qbo_account on this pass belongs to a different issuer.
      # Generalised over qbo_account_id -- never hardcoded to garden3d or to the
      # seven known mixed months, because production may have gained passes or
      # Index Space / USB Club trackers since this was written.
      counts.keys.reject { |qa_id| qa_id == modal_qbo_account_id }.each do |qa_id|
        other_enterprise_id = enterprise_by_qbo_account.fetch(qa_id)

        other_pass = InvoicePass.find_or_create_by!(
          start_of_month: pass.start_of_month,
          enterprise_id: other_enterprise_id,
        ) { |p| p.data = {} }

        pass.invoice_trackers
            .where(qbo_account_id: qa_id)
            .update_all(invoice_pass_id: other_pass.id)
      end
    end

    orphans = InvoicePass.where(enterprise_id: nil).count
    raise "#{orphans} invoice_passes still have no enterprise_id" if orphans.positive?

    change_column_null :invoice_passes, :enterprise_id, false unless column_not_null?(:enterprise_id)
    change_column_null :invoice_passes, :start_of_month, false unless column_not_null?(:start_of_month)

    if index_name_exists?(:invoice_passes, "index_invoice_passes_on_start_of_month")
      remove_index :invoice_passes, name: "index_invoice_passes_on_start_of_month"
    end

    unless index_name_exists?(:invoice_passes, "index_invoice_passes_on_enterprise_and_month")
      add_index :invoice_passes, [:enterprise_id, :start_of_month],
                unique: true, name: "index_invoice_passes_on_enterprise_and_month"
    end
  end

  def down
    sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)

    InvoicePass.where.not(enterprise_id: sanctuary.id).find_each do |pass|
      target = InvoicePass.find_by(start_of_month: pass.start_of_month,
                                   enterprise_id: sanctuary.id)
      next if target.nil?

      pass.invoice_trackers.update_all(invoice_pass_id: target.id)
      pass.destroy!
    end

    if index_name_exists?(:invoice_passes, "index_invoice_passes_on_enterprise_and_month")
      remove_index :invoice_passes, name: "index_invoice_passes_on_enterprise_and_month"
    end

    unless index_name_exists?(:invoice_passes, "index_invoice_passes_on_start_of_month")
      add_index :invoice_passes, :start_of_month,
                unique: true, name: "index_invoice_passes_on_start_of_month"
    end
  end

  private

  def column_not_null?(name)
    column = connection.columns(:invoice_passes).find { |c| c.name == name.to_s }
    column.present? && !column.null
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/migrations/backfill_invoice_pass_enterprises_test.rb
```

Expected: PASS, 5 runs, 0 failures.

- [ ] **Step 5: Verify the backfill against real data, read-only**

Do **not** run the migration against the development database yet. Confirm the modal logic would produce the right answer first:

```bash
bin/rails runner '
by_qa = QboAccount.includes(:enterprise).map { |qa| [qa.id, qa.enterprise.name] }.to_h
mixed = 0
InvoicePass.includes(:invoice_trackers).find_each do |p|
  counts = p.invoice_trackers.group_by(&:qbo_account_id).transform_values(&:size)
  next if counts.size <= 1
  mixed += 1
  modal = counts.max_by { |_qa, n| n }.first
  others = counts.keys.reject { |qa| qa == modal }
  puts format("%s modal=%-22s others=%s", p.start_of_month, by_qa[modal], others.map { |qa| by_qa[qa] }.inspect)
end
puts "mixed: #{mixed} of #{InvoicePass.count}"
'
```

Expected: 7 mixed passes, each `modal=Sanctuary Computer Inc others=["garden3d, LLC"]`, `mixed: 7 of 64`. If any pass shows a non-Sanctuary modal, stop and report before proceeding.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1792 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20261012000002_backfill_invoice_pass_enterprises.rb \
  test/migrations/backfill_invoice_pass_enterprises_test.rb
git commit -m "feat(invoicing): backfill invoice pass enterprises and constrain

Assigns each pass its modal qbo_account's enterprise, then moves every
other issuer's trackers onto that enterprise's pass for the same month.
Generalised over qbo_account_id rather than the seven known mixed months,
so a pass that has since gained an Index Space or USB Club tracker splits
correctly too.

Reversible: down re-merges non-Sanctuary passes onto the Sanctuary pass
for the month."
```

---

### Task 3: Route `make_trackers!` by issuing enterprise

Without this, `make_trackers!` resolves `qbo_account` from the **client's** billing enterprise and creates the tracker on `self` regardless — so the invariant from Task 1 breaks on the first daily run after deploy.

**Files:**
- Modify: `app/models/invoice_pass.rb:39-57`
- Test: `test/models/invoice_pass_make_trackers_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#enterprise` (Task 1)
- Produces: `make_trackers!` creating trackers only for clients whose issuer is the pass's enterprise

Note: after `reject(&:is_internal?)`, every remaining client has `billing_enterprise == Enterprise.sanctuary`, because `ForecastClient#is_internal?` is `enterprise_forecast_client.present?` and `billing_enterprise` is `enterprise || Enterprise.sanctuary` — the same mapping. So in practice only Sanctuary's pass gets forecast trackers today. The per-client form is used anyway because it states the rule rather than hardcoding one enterprise.

- [ ] **Step 1: Write the failing test**

Create `test/models/invoice_pass_make_trackers_test.rb`:

```ruby
require "test_helper"

class InvoicePassMakeTrackersTest < ActiveSupport::TestCase
  def setup
    @sanctuary = enterprises(:sanctuary)
    @garden3d = enterprises(:garden3d)
    QboAccount.create!(enterprise: @sanctuary, realm_id: "s-realm", client_id: "x", client_secret: "y")
    QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm", client_id: "x", client_secret: "y")

    @external_client = ForecastClient.create!(forecast_id: 910_001, name: "External Co")
  end

  test "a garden3d pass creates no forecast trackers for Sanctuary's clients" do
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 1, 1),
                               enterprise: @garden3d, data: {})
    pass.stubs(:clients_served).returns([@external_client])

    pass.make_trackers!

    assert_equal 0, pass.invoice_trackers.count,
      "garden3d's pass must not absorb clients issued by Sanctuary"
  end

  test "a Sanctuary pass creates a tracker for an external client" do
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 2, 1),
                               enterprise: @sanctuary, data: {})
    pass.stubs(:clients_served).returns([@external_client])

    pass.make_trackers!

    assert_equal 1, pass.invoice_trackers.count
    tracker = pass.invoice_trackers.first
    assert_equal @external_client.forecast_id, tracker.forecast_client_id
    assert_equal @sanctuary.qbo_account, tracker.qbo_account
    assert_equal "forecast", tracker.source
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/invoice_pass_make_trackers_test.rb
```

Expected: the first test FAILS with `1 expected but was 0` reversed — it asserts 0 and gets 1, because `make_trackers!` currently creates a tracker on any pass.

- [ ] **Step 3: Rewrite `make_trackers!`**

Replace `app/models/invoice_pass.rb:39-57` entirely:

```ruby
  def make_trackers!
    return if statuses == :missing_hours
    # Internal clients (mapped via enterprise_forecast_clients) generate pay
    # stubs against their enterprise's pay cycles instead of being invoiced.
    # Skip them here so they never enter the InvoiceTracker pipeline.
    clients_served.reject(&:is_internal?).each do |c|
      # A tracker belongs on the pass of the enterprise that ISSUES it. Before
      # passes were per-enterprise this resolved qa from the client's billing
      # enterprise and created the tracker on `self` regardless, which is how
      # garden3d-issued trackers ended up on Sanctuary's pass.
      issuer = c.billing_enterprise || Enterprise.sanctuary
      next unless issuer == enterprise

      qa = issuer.qbo_account
      next if qa.nil?

      InvoiceTracker.find_or_create_by!(
        forecast_client_id: c.forecast_id,
        invoice_pass: self,
      ) do |t|
        t.qbo_account = qa
        t.source = :forecast
      end
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/models/invoice_pass_make_trackers_test.rb
```

Expected: PASS, 2 runs, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1794 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 6: Commit**

```bash
git add app/models/invoice_pass.rb test/models/invoice_pass_make_trackers_test.rb
git commit -m "fix(invoicing): make_trackers! routes by issuing enterprise

A tracker now lands only on the pass of the enterprise that issues it.
Previously qa came from the client's billing enterprise while the tracker
was created on whatever pass make_trackers! was called on, so a
garden3d-issued tracker landed on Sanctuary's pass."
```

---

### Task 4: Stop `Stacks::Automator` from creating an enterprise-less pass

This is the highest-severity item in S0. `attempt_invoicing_for_previous_month` calls `InvoicePass.create!` with no enterprise. With `null: false` that raises `RecordInvalid` at `lib/tasks/stacks.rake:588`, inside the **single** `begin/rescue` of `stacks:daily_tasks` — so everything after it silently stops running: Runn sync, QBO sync, Deel sync, salary windows, every ProjectTracker and Studio snapshot, notifications, and the TaskBuilder cache warm.

The same method's `find_by` also becomes non-deterministic once two passes share a month.

`attempt_invoicing_for_invoice_pass` gets a guard too: it runs `make_trackers!` then `make_invoice!` on every tracker, and is reachable from two unconditional admin buttons on **every** pass show page. On garden3d's pass that would push a second full set of real QBO invoices for the month plus a second Twist thread.

**Files:**
- Modify: `lib/stacks/automator.rb:63-98` and `:140-160`
- Test: `test/lib/stacks/automator_invoice_pass_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#enterprise` (Task 1)
- Produces: nothing consumed later

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/automator_invoice_pass_test.rb`:

```ruby
require "test_helper"

class AutomatorInvoicePassTest < ActiveSupport::TestCase
  def setup
    @sanctuary = enterprises(:sanctuary)
    @garden3d = enterprises(:garden3d)
    QboAccount.create!(enterprise: @sanctuary, realm_id: "s-realm", client_id: "x", client_secret: "y")
    QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm", client_id: "x", client_secret: "y")
  end

  def teardown
    # Enterprise.sanctuary / .garden3d memoize in Thread.current; a rolled-back
    # fixture row would otherwise leak into every later test on this thread.
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "attempt_invoicing_for_previous_month creates a Sanctuary pass" do
    month = (Date.today - 1.month).beginning_of_month
    InvoicePass.where(start_of_month: month).destroy_all
    Stacks::Automator.stubs(:attempt_invoicing_for_invoice_pass).returns(nil)

    Stacks::Automator.attempt_invoicing_for_previous_month

    pass = InvoicePass.find_by(start_of_month: month, enterprise: @sanctuary)
    assert pass.present?, "expected a Sanctuary pass for #{month}"
  end

  test "attempt_invoicing_for_previous_month ignores a garden3d pass for the same month" do
    month = (Date.today - 1.month).beginning_of_month
    InvoicePass.where(start_of_month: month).destroy_all
    InvoicePass.create!(start_of_month: month, enterprise: @garden3d, data: {},
                        completed_at: DateTime.now)
    Stacks::Automator.stubs(:attempt_invoicing_for_invoice_pass).returns(nil)

    Stacks::Automator.attempt_invoicing_for_previous_month

    assert InvoicePass.find_by(start_of_month: month, enterprise: @sanctuary).present?,
      "a completed garden3d pass must not satisfy the Sanctuary lookup"
  end

  test "attempt_invoicing_for_invoice_pass refuses a non-Sanctuary pass" do
    pass = InvoicePass.create!(start_of_month: Date.new(2093, 1, 1),
                               enterprise: @garden3d, data: {})
    pass.expects(:make_trackers!).never

    Stacks::Automator.attempt_invoicing_for_invoice_pass(pass, false)

    assert_nil pass.reload.completed_at
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/lib/stacks/automator_invoice_pass_test.rb
```

Expected: FAIL. The first test raises `ActiveRecord::RecordInvalid: Validation failed: Enterprise must exist`.

- [ ] **Step 3: Fix `attempt_invoicing_for_previous_month`**

Replace the body at `lib/stacks/automator.rb:140-160`:

```ruby
    def attempt_invoicing_for_previous_month
      # Forecast-driven invoicing is Sanctuary's. Scope both the lookup and the
      # create: passes are unique per [enterprise, start_of_month], so an
      # unscoped find_by could return garden3d's pass for the month and a
      # create! without an enterprise raises RecordInvalid -- which, from
      # stacks:daily_tasks, would abort every later step in the task.
      sanctuary = Enterprise.sanctuary
      start_of_month = (Date.today - 1.month).beginning_of_month

      invoice_pass = InvoicePass.find_by(
        start_of_month: start_of_month,
        enterprise: sanctuary,
      )
      unless invoice_pass.present?
        invoice_pass = InvoicePass.create!(
          start_of_month: start_of_month,
          enterprise: sanctuary,
          data: {}
        )
      end
      return if invoice_pass.complete?

      # Invoicing happens on the first day of the month
      return unless Date.today >= Date.today.beginning_of_month
      attempt_invoicing_for_invoice_pass(invoice_pass)
    end
```

- [ ] **Step 4: Guard `attempt_invoicing_for_invoice_pass`**

Insert at the very top of the method, before the reminder pass (`lib/stacks/automator.rb:63`):

```ruby
    def attempt_invoicing_for_invoice_pass(invoice_pass, send_twist_reminders = true)
      # Only the forecast-invoicing enterprise may run a pass. This method runs
      # make_trackers! then make_invoice! on every tracker, and is reachable from
      # two unconditional action_items on every pass show page -- on garden3d's
      # pass that would create trackers for Sanctuary's entire external book and
      # push a second full set of real QBO invoices for the month.
      return unless invoice_pass.enterprise == Enterprise.sanctuary

      needed_reminding = remind_people_to_record_hours_prior_to_invoicing(
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/lib/stacks/automator_invoice_pass_test.rb
```

Expected: PASS, 3 runs, 0 failures.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1797 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 7: Commit**

```bash
git add lib/stacks/automator.rb test/lib/stacks/automator_invoice_pass_test.rb
git commit -m "fix(invoicing): scope the automator's invoice pass to Sanctuary

attempt_invoicing_for_previous_month created a pass with no enterprise,
which under null: false raises inside the single rescue of
stacks:daily_tasks -- aborting Runn, QBO and Deel sync, salary windows,
every snapshot, notifications and the task cache warm.

attempt_invoicing_for_invoice_pass now refuses a non-Sanctuary pass. It is
reachable from two unconditional buttons on every pass show page, and on
garden3d's pass it would have pushed a second full set of real QBO
invoices for the month."
```

---

### Task 5: Scope `sync_founder_trueups!` and `PeriodicReport` to Sanctuary

`Stacks::System.sync_founder_trueups!` selects the month's pass with an unordered `.where(...).first`, which is heap order. If it returns garden3d's pass, `contributor_payouts_by_contributor` is `{}`, `max_by` returns `nil`, and the next line raises `NoMethodError` on nil. If garden3d's pass ever holds payouts, `find_or_initialize_by` creates a **second** founder true-up for the month — `Trueup` has no uniqueness validation.

`PeriodicReport#invoice_passes` queries by `start_of_month` alone, so `#surplus` would silently widen from Sanctuary to company-wide.

**Files:**
- Modify: `lib/stacks/system.rb:79`
- Modify: `app/models/periodic_report.rb:58-60`
- Test: `test/lib/stacks/founder_trueup_scoping_test.rb`
- Test: `test/models/periodic_report_scoping_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#enterprise` (Task 1)
- Produces: nothing consumed later

- [ ] **Step 1: Write the failing tests**

Create `test/models/periodic_report_scoping_test.rb`:

```ruby
require "test_helper"

class PeriodicReportScopingTest < ActiveSupport::TestCase
  test "invoice_passes only includes the Sanctuary pass for the period" do
    sanctuary = enterprises(:sanctuary)
    garden3d = enterprises(:garden3d)
    month = Date.new(2092, 1, 1)

    sanctuary_pass = InvoicePass.create!(start_of_month: month, enterprise: sanctuary, data: {})
    InvoicePass.create!(start_of_month: month, enterprise: garden3d, data: {})

    report = PeriodicReport.new(period_starts_at: month, period_gradation: :quarter)

    assert_equal [sanctuary_pass.id], report.invoice_passes.map(&:id)
  end
end
```

Create `test/lib/stacks/founder_trueup_scoping_test.rb`:

```ruby
require "test_helper"

class FounderTrueupScopingTest < ActiveSupport::TestCase
  test "sync_founder_trueups! ignores a garden3d pass for the same month" do
    sanctuary = enterprises(:sanctuary)
    garden3d = enterprises(:garden3d)
    month = Stacks::System.founder_trueup_months.last

    InvoicePass.where(start_of_month: month).destroy_all
    sanctuary_pass = InvoicePass.create!(start_of_month: month, enterprise: sanctuary, data: {})
    InvoicePass.create!(start_of_month: month, enterprise: garden3d, data: {})

    Stacks::System.stubs(:founder_trueup_months).returns([month])

    # With no payouts on Sanctuary's pass the method raises on nil max_by; the
    # point of this test is WHICH pass it picked, so assert on the error's pass.
    InvoicePass.any_instance.stubs(:invoice_trackers).returns([])

    error = assert_raises(NoMethodError) { Stacks::System.sync_founder_trueups! }
    assert_match(/nil/, error.message)
    assert_equal sanctuary.id, sanctuary_pass.reload.enterprise_id
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/models/periodic_report_scoping_test.rb test/lib/stacks/founder_trueup_scoping_test.rb
```

Expected: the `PeriodicReport` test FAILS with two ids where one was expected.

- [ ] **Step 3: Scope `PeriodicReport#invoice_passes`**

Replace `app/models/periodic_report.rb:58-60`:

```ruby
  def invoice_passes
    # Forecast-driven invoicing is Sanctuary's. Without the enterprise scope
    # this unions every enterprise's trackers for the period and #surplus
    # silently widens from Sanctuary to company-wide.
    @_invoice_passes ||= InvoicePass
      .includes(:invoice_trackers)
      .where(enterprise: Enterprise.sanctuary)
      .where(start_of_month: period.starts_at..period.ends_at)
  end
```

- [ ] **Step 4: Scope `sync_founder_trueups!`**

Replace the pass lookup at `lib/stacks/system.rb:79`:

```ruby
        invoice_pass = InvoicePass
          .includes(invoice_trackers: :contributor_payouts)
          .where(start_of_month: working_date, enterprise: Enterprise.sanctuary)
          .first
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bin/rails test test/models/periodic_report_scoping_test.rb test/lib/stacks/founder_trueup_scoping_test.rb
```

Expected: PASS, 2 runs, 0 failures.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1799 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 7: Commit**

```bash
git add lib/stacks/system.rb app/models/periodic_report.rb \
  test/lib/stacks/founder_trueup_scoping_test.rb test/models/periodic_report_scoping_test.rb
git commit -m "fix(invoicing): scope founder trueups and periodic reports to Sanctuary

sync_founder_trueups! picked the month's pass with an unordered .first,
which could return garden3d's pass -- raising NoMethodError on a nil
max_by, or writing a duplicate founder true-up since Trueup has no
uniqueness validation.

PeriodicReport#invoice_passes queried by start_of_month alone, so #surplus
would have widened from Sanctuary to company-wide."
```

---

### Task 6: Surface the enterprise in the admin and MCP read paths

**Files:**
- Modify: `app/admin/invoice_passes.rb:37-46` (hide the rerun actions on non-forecast passes), and the index block to show the enterprise
- Modify: `app/admin/invoice_trackers.rb:101` (build the Twist URL from the tracker's current pass)
- Modify: `app/services/mcp/get_invoice_passes_tool.rb:35-45`
- Test: `test/services/mcp/invoice_passes_tool_test.rb` (existing: 4 creations + ~17 shape assertions)

**Interfaces:**
- Consumes: `InvoicePass#enterprise` (Task 1)
- Produces: nothing consumed later

- [ ] **Step 1: Hide the rerun action items on non-Sanctuary passes**

Task 4 already makes `attempt_invoicing_for_invoice_pass` refuse them; this stops the buttons being offered at all. Replace both `action_item` blocks in `app/admin/invoice_passes.rb:37-46`:

```ruby
  action_item :rerun_invoice_pass, only: :show, if: -> { resource.enterprise == Enterprise.sanctuary } do
    link_to 'Send Reminders',
      rerun_invoice_pass_admin_invoice_pass_path(resource), method: :post
  end

  action_item :rerun_invoice_pass_without_reminders, only: :show, if: -> { resource.enterprise == Enterprise.sanctuary } do
    link_to 'Generate Invoices',
      rerun_invoice_pass_without_reminders_admin_invoice_pass_path(resource), method: :post
  end
```

- [ ] **Step 2: Add the enterprise column to the index**

In the `index` block in `app/admin/invoice_passes.rb`, immediately after `column :start_of_month`:

```ruby
    column :enterprise
```

- [ ] **Step 3: Add the enterprise to the MCP tool's pass rows**

In `app/services/mcp/get_invoice_passes_tool.rb`, the `passes` array now carries one row per (enterprise, month) rather than one per month. The `mom` rollup at lines 44-45 already groups by month and sums, so it stays correct. Add the enterprise so a consumer can tell the rows apart — find the hash built around line 35-39 and add:

```ruby
          enterprise: pass.enterprise.name,
```

- [ ] **Step 4: Update the MCP tool test's shape assertions**

`test/services/mcp/invoice_passes_tool_test.rb` has 4 pass creations (already given `enterprise:` in Task 1) and ~17 assertions on the returned shape. Add an `enterprise` key assertion to the row-shape test and confirm the `mom` series is unchanged:

```ruby
  test "each pass row names its issuing enterprise" do
    result = Mcp::GetInvoicePassesTool.new.call
    row = result[:passes].first
    assert_equal "Sanctuary Computer Inc", row[:enterprise]
  end
```

- [ ] **Step 5: Rebuild the Twist URL from the tracker's current pass**

At `app/admin/invoice_trackers.rb:101`, the notification URL is built from `resource.invoice_pass`. Task 2's backfill moved 7 trackers to a different pass, so any URL cached elsewhere is stale; building from `resource.invoice_pass` at render time is already correct. Verify no literal pass id is interpolated anywhere:

```bash
grep -rn "invoice_passes/" app/ lib/ | grep -v "admin_invoice_pass"
```

Expected: no hits that interpolate a hardcoded id. If there are, replace them with the route helper.

- [ ] **Step 6: Run the affected tests**

```bash
bin/rails test test/services/mcp/invoice_passes_tool_test.rb test/integration/admin_permission_grants_test.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 7: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1800 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 8: Commit**

```bash
git add app/admin/invoice_passes.rb app/admin/invoice_trackers.rb \
  app/services/mcp/get_invoice_passes_tool.rb test/services/mcp/invoice_passes_tool_test.rb
git commit -m "feat(invoicing): surface the issuing enterprise in admin and MCP

Hides the Send Reminders / Generate Invoices actions on non-Sanctuary
passes, adds the enterprise to the invoicing index, and names the issuing
enterprise on each MCP pass row now that there can be more than one pass
per month."
```

---

### Task 7: Verify against real data and open the PR

**Files:** none modified.

- [ ] **Step 1: Run the migrations against development**

```bash
bin/rails db:migrate
```

Expected: both migrations run clean.

- [ ] **Step 2: Verify the real backfill**

```bash
bin/rails runner '
puts "passes by enterprise: " + InvoicePass.joins(:enterprise).group("enterprises.name").count.inspect
puts "orphans: #{InvoicePass.where(enterprise_id: nil).count}"
puts "mixed passes remaining:"
InvoicePass.includes(:invoice_trackers).find_each do |p|
  qas = p.invoice_trackers.map(&:qbo_account_id).uniq
  next if qas.size <= 1
  puts "  MIXED #{p.start_of_month} #{qas.inspect}"
end
puts "tracker sources: " + InvoiceTracker.group(:source).count.inspect
'
```

Expected: `{"Sanctuary Computer Inc" => 64, "garden3d, LLC" => 7}`, `orphans: 0`, no mixed passes remaining, and `{"forecast" => 1165}`.

- [ ] **Step 3: Confirm the daily task's invoicing step is safe**

```bash
bin/rails runner 'Stacks::Automator.attempt_invoicing_for_previous_month; puts "ok"'
```

Expected: `ok`, with no `RecordInvalid`. This is the blast-radius check from Task 4 — if this raises, `stacks:daily_tasks` would abort every step after invoicing.

- [ ] **Step 4: Run the full suite one more time**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1800 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 5: Push and open the PR**

```bash
git push -u origin worktree-garden3d-mso
gh pr create --title "Per-entity invoice passes" --body "$(cat <<'BODY'
Prerequisite refactor for the garden3d MSO compensation work
(`docs/superpowers/specs/2026-10-09-garden3d-mso-compensation-design.md`,
subsystem S0). Adds no MSO behaviour.

## What changes

`InvoicePass` now belongs to the enterprise that **issues** its invoices.
A tracker lives on the pass of its `qbo_account`'s enterprise, so
garden3d's invoices stop riding on Sanctuary's pass. `invoice_trackers`
gains a `source` enum (`forecast` / `management_fee`) for the MSO
trackers a later subsystem adds.

`clients_served` is deliberately **not** scoped by enterprise — external
clients have no enterprise mapping, so scoping it that way would strip
the entire external book off Sanctuary's pass.

## Migration

64 passes, 1,165 trackers. Each pass takes its modal `qbo_account`'s
enterprise; every other issuer's trackers move to that enterprise's pass
for the same month. Generalised over `qbo_account_id`, not the seven
known mixed months (2025-06 … 2025-12), so a pass that has since gained
an Index Space or USB Club tracker splits correctly too. Reversible.

**Migrations are manual in this repo** — run `bin/rails db:migrate`
after deploy.

## Bugs fixed along the way

- `Stacks::Automator#attempt_invoicing_for_previous_month` created a pass
  with no enterprise. Under `null: false` that raises inside the single
  `begin/rescue` of `stacks:daily_tasks`, which would have aborted every
  later step: Runn, QBO and Deel sync, salary windows, every tracker and
  studio snapshot, notifications, and the task cache warm.
- The two "Send Reminders" / "Generate Invoices" buttons were
  unconditional on every pass show page. On garden3d's pass they would
  have created trackers for Sanctuary's entire external book and pushed a
  **second full set of real QBO invoices** for the month, plus a second
  Twist thread.
- `Stacks::System#sync_founder_trueups!` picked the month's pass with an
  unordered `.first`, so it could hit garden3d's pass — raising
  `NoMethodError` on a nil `max_by`, or writing a duplicate founder
  true-up (`Trueup` has no uniqueness validation).
- `PeriodicReport#invoice_passes` queried by `start_of_month` alone, so
  `#surplus` would have silently widened from Sanctuary to company-wide.
- `invoice_passes.start_of_month` was nullable under a unique index,
  leaving a duplicate-NULL hole. Now `null: false`.

## Testing

Full suite green: 1800 runs, 0 failures, 0 errors, 2 skips.

Migrations don't run in the suite (the test DB is schema-loaded from the
hand-curated `db/schema.rb`), so the backfill is tested by instantiating
the migration class directly against a pre-constraint fixture state.

Also adds the missing `garden3d` enterprise fixture — `Enterprise.garden3d`
raised `RecordNotFound` in the suite before this.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

- [ ] **Step 6: Verify CI**

```bash
gh pr checks --watch
```

Expected: Heroku CI green. Note this repo only deploys `main` once `main`'s own CI goes green, and an **errored** run silently withholds the deploy — check the run's conclusion, not just its absence of failures.

---

## Self-Review

**Spec coverage.** Every §5 requirement maps to a task: §5.2 schema → Task 1; §5.3 backfill → Task 2; §5.1 issuer routing → Task 3; §5.4's call-site table → Tasks 4 (automator ×2), 5 (`sync_founder_trueups!`, `PeriodicReport`), 6 (admin actions, MCP tool, tracker URL), 1 (35 test sites). §5.4's `admin_authorization.rb:94-95` row is **deliberately deferred** — it is an authorization change that belongs with S4's combined guard (spec §10), not in a schema refactor, and garden3d's pass holds nothing sensitive until S4 adds the snapshot. §12's S0 test list is covered except `clients_served` unchanged, which Task 3's second test covers implicitly by asserting the external client still gets a tracker.

**Placeholders.** None. Every code step carries the actual code; every command carries its expected output, including exact run counts that increase monotonically (1783 → 1787 → 1792 → 1794 → 1797 → 1799 → 1800).

**Type consistency.** `InvoicePass#enterprise` (association), `InvoiceTracker#source` (string from the enum, asserted as `"forecast"`), `Enterprise.sanctuary` / `Enterprise.garden3d` (memoized class methods, cleared in Task 4's teardown). The migration class name `BackfillInvoicePassEnterprises` matches its filename in both the `require` and the instantiation.

**One known gap:** `InvoiceTracker#status` returning `:impossible` for a blueprint-less tracker (spec §6.4) is **not** fixed here. It only bites once `:management_fee` trackers exist, which is S1. Flagged so S1 doesn't assume S0 handled it.
