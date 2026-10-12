# Per-Entity Invoice Passes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `InvoicePass` belong to an issuing `Enterprise`, so garden3d issues its own invoices on its own pass instead of riding on Sanctuary's.

**Architecture:** A pass belongs to the **issuing** enterprise. A tracker lives on the pass of its `qbo_account`'s enterprise. `clients_served` stays global — external clients have no enterprise mapping, so scoping it by enterprise would strip the entire external book off Sanctuary's pass. A new `invoice_trackers.source` enum (`forecast` / `management_fee`) distinguishes Forecast-driven trackers from the MSO management-fee trackers a later subsystem adds.

**Tech Stack:** Rails 6.1, Postgres, Minitest, Mocha, ActiveAdmin.

This is subsystem **S0** of `docs/superpowers/specs/2026-10-09-garden3d-mso-compensation-design.md`. It is a prerequisite refactor of live financial machinery and ships as its own PR, merged and verified against a real month before any MSO work lands on it. It adds **no** MSO behaviour.

## Global Constraints

- `db/schema.rb` is **hand-curated**. It deliberately omits things Rails would dump (the pgvector `embeddings.embedding` column and its HNSW index, `chunks.content_tsv`) and carries comments the repo depends on. Edit it by hand; **never** let `db:migrate` re-dump it (see Task 7 Step 1).
- Migrations **never run** in the test suite — the test DB is schema-loaded from `db/schema.rb`. Backfill tests instantiate the migration class explicitly.
- `maintain_test_schema` is **on** (`config.load_defaults 6.0`) and `rails/test_help` calls `check_pending!`. If `db/schema.rb`'s version is lower than the newest file in `db/migrate/`, **every** `bin/rails test` aborts before loading a test. So `db/schema.rb` must carry the version of this plan's **final** migration (`2026_10_12_000002`) from Task 1 onward. Any further migration added to this branch requires the version bump in the same commit.
- `belongs_to` is required by default. `InvoiceTracker belongs_to :forecast_client` has no `optional: true`, so test trackers need real `ForecastClient` rows.
- `test/fixtures/qbo_accounts.yml` already attaches **two** `QboAccount`s to `sanctuary`, and `has_one` emits `LIMIT 1` with no `ORDER BY`. Never create a third, and pin the one `has_one` picks via `Enterprise.find(id).qbo_account`.
- `Enterprise.sanctuary` / `.garden3d` memoize in `Thread.current`. Clear both in `teardown` of any test that relies on them.
- Run the suite with `--exclude "sync_meet runs the connector inside a SystemTask"` — that test makes a live Google call and can hang for over an hour.
- Never run two suites concurrently against the shared test database.
- Verified baseline: **1783 runs, 5702 assertions, 0 failures, 0 errors, 2 skips**.
- Commit after every task.

---

### Task 1: Add `enterprise_id` and `source` to the schema, keep the suite green

The column ends up `null: false` and the test DB loads `db/schema.rb` directly, so every existing `InvoicePass` construction must supply an enterprise the moment the schema changes. That is why the schema change, the fixture, the association and all 35 call sites are one task — the suite cannot be green at any intermediate point.

**Files:**
- Create: `db/migrate/20261012000001_add_enterprise_to_invoice_passes.rb`
- Modify: `db/schema.rb`
- Modify: `app/models/invoice_pass.rb:1-2`
- Modify: `app/models/invoice_tracker.rb` (add the enum after the `belongs_to` block)
- Modify: `test/fixtures/enterprises.yml`
- Create: `test/models/invoice_pass_enterprise_test.rb`
- Modify: 18 test files (table in Step 9)

**Interfaces:**
- Consumes: nothing
- Produces: `InvoicePass#enterprise` (required `belongs_to`), `InvoiceTracker#source` enum with values `forecast` (0, default) and `management_fee` (1)

- [ ] **Step 1: Write the migration**

Create `db/migrate/20261012000001_add_enterprise_to_invoice_passes.rb`. The column goes on **nullable**; Task 2 backfills and constrains. This split is deliberate — `add_reference ... null: false` against the 64 existing rows raises `PG::NotNullViolation`.

```ruby
class AddEnterpriseToInvoicePasses < ActiveRecord::Migration[6.1]
  def change
    add_reference :invoice_passes, :enterprise, null: true, foreign_key: true
    add_column :invoice_trackers, :source, :integer, null: false, default: 0
  end
end
```

- [ ] **Step 2: Hand-edit `db/schema.rb`**

**Set the version line to this plan's FINAL migration**, not this one. `db/schema.rb:14` currently reads `ActiveRecord::Schema.define(version: 2026_10_01_120000) do`. Change it to:

```ruby
ActiveRecord::Schema.define(version: 2026_10_12_000002) do
```

`assume_migrated_upto_version` inserts that version, so Task 2's migration file is never "pending" and `check_pending!` stays quiet. Using `...000001` here makes the entire suite unbootable from Task 2 Step 3 onward.

Replace the `invoice_passes` table block. Note `enterprise_id` is `null: false` and `start_of_month` gains `null: false` — schema.rb reflects the **end state** after Task 2.

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

The old `t.index ["start_of_month"], name: "index_invoice_passes_on_start_of_month", unique: true` line is **deleted**.

In `create_table "invoice_trackers"`, add:

```ruby
    t.integer "source", default: 0, null: false
```

In the foreign-key list, insert **between** `add_foreign_key "gifted_profit_shares", "admin_users"` (line 1591) and `add_foreign_key "invoice_trackers", "admin_users"` (line 1592) — the list is alphabetical by from-table:

```ruby
  add_foreign_key "invoice_passes", "enterprises"
```

- [ ] **Step 3: Load the new schema into the test DB**

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
RAILS_ENV=test bin/rails db:environment:set db:schema:load
```

Expected: completes without error. (`db:environment:set` is required in this repo or the task refuses.)

- [ ] **Step 4: Add the garden3d fixture**

`test/fixtures/enterprises.yml` has only `sanctuary`, `one`, `two`, which is why `Enterprise.garden3d` raises `RecordNotFound` in the suite today. The name must match `Enterprise::GARDEN3D_NAME` exactly.

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

Do **not** add a garden3d `QboAccount` fixture — Task 3 and Task 4 create one per-test, and adding a second to `sanctuary` would make `has_one` non-deterministic.

- [ ] **Step 5: Write the failing test**

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

    # There is no uniqueness validation, only the DB index — hence
    # RecordNotUnique rather than RecordInvalid. The test transaction is
    # opened joinable: false, so this nested save gets a real savepoint and
    # does not poison the surrounding fixtures.
    assert_raises(ActiveRecord::RecordNotUnique) do
      InvoicePass.create!(start_of_month: month, enterprise: enterprises(:sanctuary))
    end
  end

  test "a new invoice tracker defaults to the forecast source" do
    assert_equal "forecast", InvoiceTracker.new.source
  end
end
```

- [ ] **Step 6: Run it to verify it fails**

```bash
bin/rails test test/models/invoice_pass_enterprise_test.rb
```

Expected: **all 4 fail.** Test 1 fails its assertion (no `:enterprise` error exists yet). Tests 2 and 3 raise `ActiveModel::UnknownAttributeError: unknown attribute 'enterprise' for InvoicePass` — the association doesn't exist, so the keyword is rejected. Test 4 fails because `InvoiceTracker.new.source` returns the raw integer `0` until the `enum` declaration in Step 7 installs the string API — the column default alone is not enough.

- [ ] **Step 7: Add the association and the enum**

In `app/models/invoice_pass.rb`, replace lines 1-2:

```ruby
class InvoicePass < ApplicationRecord
  has_many :invoice_trackers
```

with:

```ruby
class InvoicePass < ApplicationRecord
  # A pass belongs to the enterprise that ISSUES its invoices, not to the
  # clients being billed. A tracker lives on the pass of its qbo_account's
  # enterprise. Before this was modelled, garden3d's invoices rode on
  # Sanctuary's pass (7 mixed passes, 2025-06 .. 2025-12).
  belongs_to :enterprise
  has_many :invoice_trackers
```

In `app/models/invoice_tracker.rb`, add the enum immediately after the existing `belongs_to` declarations (after line 9's `belongs_to :forecast_client ...`):

```ruby
  # `forecast` trackers come from Harvest Forecast via InvoicePass#make_trackers!.
  # `management_fee` trackers are generated by the MSO subsystem from different
  # logic entirely; they carry no blueprint and no contributor payouts.
  enum source: { forecast: 0, management_fee: 1 }
```

- [ ] **Step 8: Run the test to verify it passes**

```bash
bin/rails test test/models/invoice_pass_enterprise_test.rb
```

Expected: PASS, 4 runs, 0 failures.

- [ ] **Step 9: Update all 35 existing construction sites**

Each needs `enterprise: Enterprise.sanctuary`. Pass Sanctuary explicitly rather than defaulting in the model — these are financial routing decisions, and a silent default would hide exactly the `Stacks::Automator` bug Task 4 fixes.

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

Find them with:

```bash
grep -rn "InvoicePass\.\(create\|new\|find_or_create\)" test/
```

For `create!` and `new`, add the keyword:

```ruby
InvoicePass.create!(start_of_month: Date.new(2026, 7, 1), enterprise: Enterprise.sanctuary)
```

For `find_or_create_by!`, the enterprise belongs in the **lookup**, not the block — otherwise the finder matches another enterprise's pass:

```ruby
InvoicePass.find_or_create_by!(
  start_of_month: Date.new(2030, 1, 1),
  enterprise: Enterprise.sanctuary,
)
```

Where a block already exists (`{ |ip| ip.data = {} }`), keep it and add `enterprise:` to the arguments.

- [ ] **Step 10: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: **1787 runs, 0 failures, 0 errors, 2 skips** (baseline 1783 + 4). A failure reading `Enterprise must exist` means a site was missed — re-run the grep.

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

schema.rb carries version 2026_10_12_000002, the final migration of this
branch, so check_pending! stays quiet once that file lands.

Adds the garden3d enterprise fixture; Enterprise.garden3d raised
RecordNotFound in the suite before this."
```

---

### Task 2: Backfill the existing 64 passes and constrain the column

**Files:**
- Create: `db/migrate/20261012000002_backfill_invoice_pass_enterprises.rb`
- Create: `test/migrations/backfill_invoice_pass_enterprises_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#enterprise` from Task 1
- Produces: nothing consumed later (a data migration)

Production state, verified 2026-10-09: 64 passes, 1,165 trackers, tracker-set histogram `{[2] => 57, [2, 35] => 7}`. QBO account ids: 1 = Index Space, 2 = Sanctuary, 35 = garden3d, 68 = USB Club. The 7 mixed passes (2025-06-01 … 2025-12-01) each have modal `qbo_account` 2 against exactly one garden3d tracker.

The migration derives "mixed" **dynamically** by grouping on `qbo_account_id`, never from those 7 dates — production may have gained passes or Index/USB trackers since.

- [ ] **Step 1: Write the failing migration test**

Create `test/migrations/backfill_invoice_pass_enterprises_test.rb`. Two things make this fiddly and both are deliberate:

1. `db/schema.rb` has `enterprise_id null: false`, so the test must drop that constraint to simulate pre-migration state. It rolls back with the fixture transaction.
2. `InvoiceTracker belongs_to :forecast_client` is required, so real `ForecastClient` rows are needed.

```ruby
require "test_helper"
require Rails.root.join("db/migrate/20261012000002_backfill_invoice_pass_enterprises.rb")

class BackfillInvoicePassEnterprisesTest < ActiveSupport::TestCase
  def setup
    # schema.rb already carries the post-migration NOT NULL constraint, so drop
    # it for the duration to simulate the pre-backfill state. Rolls back with
    # the fixture transaction. The schema cache must be cleared too, or the
    # migration's own column_not_null? check reads the stale `null: false`.
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE invoice_passes ALTER COLUMN enterprise_id DROP NOT NULL"
    )
    ActiveRecord::Base.connection.schema_cache.clear!
    InvoicePass.reset_column_information

    @sanctuary = enterprises(:sanctuary)
    @garden3d = enterprises(:garden3d)
    # Sanctuary already has two qbo_account fixtures; pin the one has_one picks.
    @sanctuary_qa = Enterprise.find(@sanctuary.id).qbo_account
    @garden3d_qa = QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm",
                                      client_id: "x", client_secret: "y")
    @clients = 3.times.map do |i|
      ForecastClient.create!(forecast_id: 900_001 + i, name: "Backfill Co #{i}")
    end
  end

  def teardown
    InvoicePass.reset_column_information
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  def build_pass_with_trackers(month, qbo_accounts)
    pass = InvoicePass.create!(start_of_month: month, enterprise: @sanctuary, data: {})
    qbo_accounts.each_with_index do |qa, i|
      InvoiceTracker.create!(invoice_pass: pass, qbo_account: qa,
                             forecast_client: @clients[i])
    end
    InvoicePass.where(id: pass.id).update_all(enterprise_id: nil)
    pass
  end

  test "assigns the modal qbo_account's enterprise to a single-enterprise pass" do
    pass = build_pass_with_trackers(Date.new(2095, 1, 1), [@sanctuary_qa, @sanctuary_qa])

    BackfillInvoicePassEnterprises.new.up

    assert_equal @sanctuary, pass.reload.enterprise
  end

  test "splits a mixed pass, moving minority trackers to their own enterprise's pass" do
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
    assert garden3d_pass.data["created_by_backfill"],
      "a pass the backfill created must be tagged so `down` only removes its own"
  end

  test "assigns Sanctuary to a pass with no trackers" do
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 3, 1),
                               enterprise: @sanctuary, data: {})
    InvoicePass.where(id: pass.id).update_all(enterprise_id: nil)

    BackfillInvoicePassEnterprises.new.up

    assert_equal @sanctuary, pass.reload.enterprise
  end

  test "leaves no pass without an enterprise" do
    build_pass_with_trackers(Date.new(2095, 4, 1), [@sanctuary_qa, @garden3d_qa])

    BackfillInvoicePassEnterprises.new.up

    assert_equal 0, InvoicePass.where(enterprise_id: nil).count
  end

  test "down re-merges only the passes the backfill created" do
    pass = build_pass_with_trackers(Date.new(2095, 5, 1), [@sanctuary_qa, @garden3d_qa])
    BackfillInvoicePassEnterprises.new.up

    # A legitimate garden3d pass that the backfill did NOT create must survive.
    untagged = InvoicePass.create!(start_of_month: Date.new(2095, 9, 1),
                                   enterprise: @garden3d, data: {})

    BackfillInvoicePassEnterprises.new.down

    assert_equal 2, pass.reload.invoice_trackers.count
    assert_nil InvoicePass.find_by(start_of_month: Date.new(2095, 5, 1),
                                   enterprise: @garden3d)
    assert untagged.reload.persisted?, "an untagged pass must not be destroyed"
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

**The index drop comes first.** The old `index_invoice_passes_on_start_of_month` is still `unique: true` during the loop, so creating a second pass for the same month raises `PG::UniqueViolation` before any constraint work happens. Tests never catch this — the schema-loaded test DB has no such index — so it would only surface against the dev or production database.

```ruby
class BackfillInvoicePassEnterprises < ActiveRecord::Migration[6.1]
  # `down` is a one-shot rollback. It removes only passes tagged
  # data["created_by_backfill"], so a legitimate MSO-era garden3d pass is never
  # destroyed, and it refuses to proceed if such a pass has acquired a Trueup
  # (invoice_passes has an FK from trueups and no dependent: option).
  def up
    # MUST come before the loop: the old unique index on start_of_month alone
    # would reject the second pass for a month.
    if index_name_exists?(:invoice_passes, "index_invoice_passes_on_start_of_month")
      remove_index :invoice_passes, name: "index_invoice_passes_on_start_of_month"
    end

    sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    enterprise_by_qbo_account = QboAccount.pluck(:id, :enterprise_id).to_h

    InvoicePass.where(enterprise_id: nil).find_each do |pass|
      counts = pass.invoice_trackers.group(:qbo_account_id).count

      if counts.empty?
        pass.update_columns(enterprise_id: sanctuary.id)
        next
      end

      modal_qbo_account_id = counts.max_by { |_qa, n| n }.first
      pass.update_columns(enterprise_id: enterprise_by_qbo_account.fetch(modal_qbo_account_id))

      # Every OTHER qbo_account on this pass belongs to a different issuer.
      # Generalised over qbo_account_id -- never hardcoded to garden3d or to the
      # seven known mixed months, because production may have gained passes or
      # Index Space / USB Club trackers since this was written.
      counts.keys.reject { |qa_id| qa_id == modal_qbo_account_id }.each do |qa_id|
        other_enterprise_id = enterprise_by_qbo_account.fetch(qa_id)

        other_pass = InvoicePass.find_or_create_by!(
          start_of_month: pass.start_of_month,
          enterprise_id: other_enterprise_id,
        ) { |p| p.data = { "created_by_backfill" => true } }

        pass.invoice_trackers
            .where(qbo_account_id: qa_id)
            .update_all(invoice_pass_id: other_pass.id)
      end
    end

    orphans = InvoicePass.where(enterprise_id: nil).count
    raise "#{orphans} invoice_passes still have no enterprise_id" if orphans.positive?

    change_column_null :invoice_passes, :enterprise_id, false unless column_not_null?(:enterprise_id)
    change_column_null :invoice_passes, :start_of_month, false unless column_not_null?(:start_of_month)

    unless index_name_exists?(:invoice_passes, "index_invoice_passes_on_enterprise_and_month")
      add_index :invoice_passes, [:enterprise_id, :start_of_month],
                unique: true, name: "index_invoice_passes_on_enterprise_and_month"
    end
  end

  def down
    created = InvoicePass.where("data->>'created_by_backfill' = 'true'")

    created.each do |pass|
      if Trueup.where(invoice_pass_id: pass.id).exists?
        raise "InvoicePass #{pass.id} has trueups; refusing to roll back"
      end

      target = InvoicePass.find_by(
        start_of_month: pass.start_of_month,
        enterprise_id: Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME).id,
      )
      raise "No Sanctuary pass for #{pass.start_of_month} to re-merge into" if target.nil?

      pass.invoice_trackers.update_all(invoice_pass_id: target.id)
      pass.destroy!
    end

    if index_name_exists?(:invoice_passes, "index_invoice_passes_on_enterprise_and_month")
      remove_index :invoice_passes, name: "index_invoice_passes_on_enterprise_and_month"
    end

    change_column_null :invoice_passes, :start_of_month, true
    change_column_null :invoice_passes, :enterprise_id, true

    unless index_name_exists?(:invoice_passes, "index_invoice_passes_on_start_of_month")
      add_index :invoice_passes, :start_of_month,
                unique: true, name: "index_invoice_passes_on_start_of_month"
    end
  end

  private

  def column_not_null?(name)
    connection.schema_cache.clear!
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

- [ ] **Step 5: Verify the modal logic against real data, read-only**

Do **not** migrate the dev database yet.

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

Expected: 7 mixed passes, each `modal=Sanctuary Computer Inc others=["garden3d, LLC"]`, `mixed: 7 of 64`. If any pass shows a non-Sanctuary modal, **stop and report** before proceeding.

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

Drops the old unique index on start_of_month BEFORE the loop -- creating a
second pass for a month would otherwise violate it, which the
schema-loaded test DB cannot catch.

Passes the backfill creates are tagged data.created_by_backfill so down
re-merges only its own and never a later legitimate garden3d pass."
```

---

### Task 3: Route `make_trackers!` by issuing enterprise

Without this, `make_trackers!` resolves `qbo_account` from the **client's** billing enterprise and creates the tracker on `self` regardless — so Task 1's invariant breaks on the first daily run after deploy.

**Files:**
- Modify: `app/models/invoice_pass.rb:39-57`
- Create: `test/models/invoice_pass_make_trackers_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#enterprise` (Task 1)
- Produces: `make_trackers!` creating trackers only for clients whose issuer is the pass's enterprise

Note: after `reject(&:is_internal?)`, every remaining client has `billing_enterprise == Enterprise.sanctuary`, because `ForecastClient#is_internal?` is `enterprise_forecast_client.present?` and `billing_enterprise` is `enterprise || Enterprise.sanctuary` — the same mapping. So only Sanctuary's pass gets forecast trackers today. The per-client form is used anyway because it states the rule rather than hardcoding one enterprise.

- [ ] **Step 1: Write the failing test**

Create `test/models/invoice_pass_make_trackers_test.rb`:

```ruby
require "test_helper"

class InvoicePassMakeTrackersTest < ActiveSupport::TestCase
  def setup
    @sanctuary = enterprises(:sanctuary)
    @garden3d = enterprises(:garden3d)
    # Sanctuary already has two qbo_account fixtures and has_one has no ORDER BY;
    # pin the one it picks rather than creating a third.
    @sanctuary_qa = Enterprise.find(@sanctuary.id).qbo_account
    QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm",
                       client_id: "x", client_secret: "y")

    @external_client = ForecastClient.create!(forecast_id: 910_001, name: "External Co")
  end

  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
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
    assert_equal @sanctuary_qa, tracker.qbo_account
    assert_equal "forecast", tracker.source
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/invoice_pass_make_trackers_test.rb
```

Expected: test 1 FAILS — it asserts 0 trackers and gets 1, because `make_trackers!` currently creates a tracker on whatever pass it is called on.

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

The highest-severity item in S0. `attempt_invoicing_for_previous_month` calls `InvoicePass.create!` with no enterprise. Under `null: false` that raises `RecordInvalid` at `lib/tasks/stacks.rake:588`, inside the **single** `begin/rescue` of `stacks:daily_tasks` — so everything after it silently stops: Runn sync, QBO sync, Deel sync, salary windows, every ProjectTracker and Studio snapshot, notifications, and the TaskBuilder cache warm.

Its `find_by` also becomes non-deterministic once two passes share a month.

`attempt_invoicing_for_invoice_pass` needs a guard too: it runs `make_trackers!` then `make_invoice!` on every tracker, and is reachable from two unconditional admin buttons on **every** pass show page. On garden3d's pass that would push a second full set of real QBO invoices for the month plus a second Twist thread.

**Files:**
- Modify: `lib/stacks/automator.rb:145-160` (`attempt_invoicing_for_previous_month`)
- Modify: `lib/stacks/automator.rb:63` (guard at the top of `attempt_invoicing_for_invoice_pass`)
- Create: `test/lib/stacks/automator_invoice_pass_test.rb`

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
    QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm",
                       client_id: "x", client_secret: "y")
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

    assert InvoicePass.find_by(start_of_month: month, enterprise: @sanctuary).present?,
      "expected a Sanctuary pass for #{month}"
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
    # Before the guard exists, the method's first statement reaches
    # remind_people_to_record_hours_prior_to_invoicing -> twist.get_workspace_users,
    # a real outbound HTTP call. Stub it so the red phase fails on the assertion
    # rather than on the network. Dead weight once the guard lands, kept so the
    # test does not depend on guard ordering.
    Stacks::Twist.any_instance.stubs(:get_workspace_users)
                 .returns(stub(parsed_response: []))

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

Expected: tests 1 and 2 raise `ActiveRecord::RecordInvalid: Validation failed: Enterprise must exist`. Test 3 fails on the `make_trackers!` expectation (it is called).

- [ ] **Step 3: Fix `attempt_invoicing_for_previous_month`**

Replace `lib/stacks/automator.rb:145-160` — the method body only. Line 140 is the previous method's `end` and 142-144 are this method's doc comment; leave all of those intact.

```ruby
    def attempt_invoicing_for_previous_month
      # Forecast-driven invoicing is Sanctuary's. Scope both the lookup and the
      # create: passes are unique per [enterprise, start_of_month], so an
      # unscoped find_by could return garden3d's pass for the month, and a
      # create! without an enterprise raises RecordInvalid -- which, from
      # stacks:daily_tasks, aborts every later step in the task.
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

Insert the guard as the first statement of the method at `lib/stacks/automator.rb:63`, before `needed_reminding = ...`:

```ruby
    def attempt_invoicing_for_invoice_pass(invoice_pass, send_twist_reminders = true)
      # Only the forecast-invoicing enterprise may run a pass. This method runs
      # make_trackers! then make_invoice! on every tracker, and is reachable from
      # two action_items on every pass show page -- on garden3d's pass that would
      # create trackers for Sanctuary's entire external book and push a second
      # full set of real QBO invoices for the month.
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

Expected: 1798 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 7: Commit**

```bash
git add lib/stacks/automator.rb test/lib/stacks/automator_invoice_pass_test.rb
git commit -m "fix(invoicing): scope the automator's invoice pass to Sanctuary

attempt_invoicing_for_previous_month created a pass with no enterprise,
which under null: false raises inside the single rescue of
stacks:daily_tasks -- aborting Runn, QBO and Deel sync, salary windows,
every snapshot, notifications and the task cache warm.

attempt_invoicing_for_invoice_pass now refuses a non-Sanctuary pass. It is
reachable from two buttons on every pass show page, and on garden3d's pass
it would have pushed a second full set of real QBO invoices."
```

---

### Task 5: Scope `sync_founder_trueups!` and `PeriodicReport` to Sanctuary

`Stacks::System.sync_founder_trueups!` selects the month's pass with an unordered `.where(...).first`, which is heap order. If it returns garden3d's pass, the payout aggregation is empty and the method fails; if garden3d's pass ever holds payouts, `find_or_initialize_by` writes a **second** founder true-up for the month (`Trueup` has no uniqueness validation).

`PeriodicReport#invoice_passes` queries by `start_of_month` alone, so `#surplus` would silently widen from Sanctuary to company-wide.

**Files:**
- Modify: `lib/stacks/system.rb:79`
- Modify: `app/models/periodic_report.rb:58-60`
- Create: `test/lib/stacks/founder_trueup_scoping_test.rb`
- Create: `test/models/periodic_report_scoping_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#enterprise` (Task 1)
- Produces: nothing consumed later

- [ ] **Step 1: Write the failing tests**

Create `test/models/periodic_report_scoping_test.rb`:

```ruby
require "test_helper"

class PeriodicReportScopingTest < ActiveSupport::TestCase
  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "invoice_passes only includes the Sanctuary pass for the period" do
    month = Date.new(2092, 1, 1)
    sanctuary_pass = InvoicePass.create!(start_of_month: month,
                                         enterprise: enterprises(:sanctuary), data: {})
    InvoicePass.create!(start_of_month: month,
                        enterprise: enterprises(:garden3d), data: {})

    report = PeriodicReport.new(period_starts_at: month, period_gradation: :quarter)

    assert_equal [sanctuary_pass.id], report.invoice_passes.map(&:id)
  end

  test "surplus ignores other enterprises' trackers" do
    month = Date.new(2092, 4, 1)
    InvoicePass.create!(start_of_month: month,
                        enterprise: enterprises(:sanctuary), data: {})
    InvoicePass.create!(start_of_month: month,
                        enterprise: enterprises(:garden3d), data: {})

    report = PeriodicReport.new(period_starts_at: month, period_gradation: :quarter)

    assert_equal [], report.invoice_trackers
    assert_nil report.surplus
  end
end
```

Create `test/lib/stacks/founder_trueup_scoping_test.rb`. This asserts **which pass was selected** by observing the explicit raise, which only fires when the Sanctuary-scoped lookup finds nothing. Before the fix, garden3d's pass satisfies the unscoped `.first` and the method proceeds past that guard, failing later with a different error class — so the test genuinely discriminates.

```ruby
require "test_helper"

class FounderTrueupScopingTest < ActiveSupport::TestCase
  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "sync_founder_trueups! does not accept a garden3d pass as the month's pass" do
    month = Date.new(2091, 1, 1)
    InvoicePass.where(start_of_month: month).destroy_all
    InvoicePass.create!(start_of_month: month,
                        enterprise: enterprises(:garden3d), data: {})

    Stacks::System.stubs(:founder_trueup_months).returns([month])

    error = assert_raises(RuntimeError) { Stacks::System.sync_founder_trueups! }
    assert_match(/No invoice pass found/, error.message)
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/models/periodic_report_scoping_test.rb test/lib/stacks/founder_trueup_scoping_test.rb
```

Expected: the `PeriodicReport` tests FAIL (two pass ids where one was expected; two trackers where none were). The founder test FAILS because a `NoMethodError` is raised instead of the `RuntimeError` — the garden3d pass satisfied the unscoped lookup.

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

Expected: PASS, 3 runs, 0 failures.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1801 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 7: Commit**

```bash
git add lib/stacks/system.rb app/models/periodic_report.rb \
  test/lib/stacks/founder_trueup_scoping_test.rb test/models/periodic_report_scoping_test.rb
git commit -m "fix(invoicing): scope founder trueups and periodic reports to Sanctuary

sync_founder_trueups! picked the month's pass with an unordered .first,
so it could select garden3d's pass -- and if that pass ever held payouts,
write a duplicate founder true-up, since Trueup has no uniqueness
validation.

PeriodicReport#invoice_passes queried by start_of_month alone, so #surplus
would have widened from Sanctuary to company-wide."
```

---

### Task 6: Surface the enterprise in the admin and MCP read paths

**Files:**
- Modify: `app/admin/invoice_passes.rb:39-47` (the two `action_item` blocks) and the `index` block
- Modify: `app/services/mcp/get_invoice_passes_tool.rb:38` and `:66-73`
- Modify: `test/services/mcp/invoice_passes_tool_test.rb`
- Modify: `test/integration/admin_permission_grants_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#enterprise` (Task 1)
- Produces: nothing consumed later

- [ ] **Step 1: Hide the rerun action items on non-Sanctuary passes**

Task 4 already makes the `Automator` refuse them; this stops the buttons being offered. Replace **lines 39-47** of `app/admin/invoice_passes.rb` — exactly the two `action_item` blocks. Line 37 is the `controller do` block's `end`; do not touch it.

House style for a conditional action item is `if: proc { ... }` (see `app/admin/pay_stubs.rb:8`):

```ruby
  action_item :rerun_invoice_pass, only: :show,
    if: proc { resource.enterprise == Enterprise.sanctuary } do
    link_to 'Send Reminders',
      rerun_invoice_pass_admin_invoice_pass_path(resource), method: :post
  end

  action_item :rerun_invoice_pass_without_reminders, only: :show,
    if: proc { resource.enterprise == Enterprise.sanctuary } do
    link_to 'Generate Invoices',
      rerun_invoice_pass_without_reminders_admin_invoice_pass_path(resource), method: :post
  end
```

- [ ] **Step 1b: Guard both `member_action`s, not just the links**

Hiding an `action_item` does **not** unroute its `member_action` — a direct
`POST /admin/invoice_passes/:id/rerun_invoice_pass_without_reminders` still
reaches it. And the controller redirects with `notice: "Done!"`
unconditionally, so Task 4's silent `return` would report success having done
nothing. Concealment is not enforcement; guard the server side too.

Replace both `member_action` blocks in `app/admin/invoice_passes.rb:51-58`:

```ruby
  member_action :rerun_invoice_pass_without_reminders, method: :post do
    unless resource.enterprise == Enterprise.sanctuary
      return redirect_to admin_invoice_pass_path(resource),
        alert: "Forecast invoicing only runs on #{Enterprise::SANCTUARY_NAME}'s passes."
    end
    Stacks::Automator.attempt_invoicing_for_invoice_pass(resource, false)
    redirect_to admin_invoice_pass_path(resource), notice: "Done!"
  end

  member_action :rerun_invoice_pass, method: :post do
    unless resource.enterprise == Enterprise.sanctuary
      return redirect_to admin_invoice_pass_path(resource),
        alert: "Forecast invoicing only runs on #{Enterprise::SANCTUARY_NAME}'s passes."
    end
    Stacks::Automator.attempt_invoicing_for_invoice_pass(resource)
    redirect_to admin_invoice_pass_path(resource), notice: "Done!"
  end
```

Verify the real line numbers before editing — Step 1's edit shifts them.

- [ ] **Step 2: Add the enterprise column to the index**

In the `index` block, immediately after `column :start_of_month`:

```ruby
    column :enterprise
```

- [ ] **Step 3: Add the enterprise to the MCP tool's pass rows**

In `app/services/mcp/get_invoice_passes_tool.rb`, the row hash is built in `self.pass_block` at **lines 66-73** (not in the query at 35-39). Add the key there:

```ruby
          enterprise: pass.enterprise.name,
```

Then preload it — line 38's `includes(invoice_trackers: { qbo_account: :enterprise })` does **not** cover the pass's own enterprise, so the new key would fire one query per pass:

```ruby
      .includes(:enterprise, invoice_trackers: { qbo_account: :enterprise })
```

The `passes` array now carries one row per (enterprise, month). The `mom` rollup at lines 44-45 already groups by month and sums, so it stays correct.

- [ ] **Step 4: Add the MCP shape test**

Add this **inside the existing `Mcp::InvoicePassesToolTest` class** in `test/services/mcp/invoice_passes_tool_test.rb`, so it inherits that file's `setup` (which creates the June and July 2026 passes inside the frozen window). Standalone it would see zero passes and `.first` would be nil.

The tool's entry point is `self.call` with a required `server_context:`, and it returns an MCP envelope — use the file's existing `mcp_payload` helper, whose keys are **strings** because it JSON-parses:

```ruby
  test "each pass row names its issuing enterprise" do
    payload = mcp_payload(Mcp::GetInvoicePassesTool.call(server_context: {}))
    assert_equal 'Sanctuary Computer Inc', payload['passes'].first['enterprise']
  end
```

`.first` is deterministic: the query is `order(:start_of_month)` and the shared setup creates June 2026 before July 2026.

- [ ] **Step 5: Add the action-item visibility test**

Append to `test/integration/admin_permission_grants_test.rb`:

```ruby
  test "the Generate Invoices action is not offered on a non-Sanctuary pass" do
    pass = InvoicePass.create!(start_of_month: Date.new(2090, 1, 1),
                               enterprise: enterprises(:garden3d), data: {})
    sign_in_as_admin

    get admin_invoice_pass_path(pass)

    assert_response :success
    assert_select "a[href=?]",
      rerun_invoice_pass_without_reminders_admin_invoice_pass_path(pass), count: 0
  end

  test "POSTing the Generate Invoices action directly on a non-Sanctuary pass is refused" do
    pass = InvoicePass.create!(start_of_month: Date.new(2090, 2, 1),
                               enterprise: enterprises(:garden3d), data: {})
    sign_in_as_admin
    Stacks::Automator.expects(:attempt_invoicing_for_invoice_pass).never

    post rerun_invoice_pass_without_reminders_admin_invoice_pass_path(pass)

    assert_redirected_to admin_invoice_pass_path(pass)
    assert_equal "Forecast invoicing only runs on #{Enterprise::SANCTUARY_NAME}'s passes.",
      flash[:alert]
  end
```

The second test is the one that matters: hiding a link does not unroute its
`member_action`, so without the Step 1b guard this POST would succeed with
`notice: "Done!"` and no work done.

Match the file's existing sign-in idiom rather than `sign_in_as_admin` if it differs — check the top of the file.

- [ ] **Step 6: Run the affected tests**

```bash
bin/rails test test/services/mcp/invoice_passes_tool_test.rb test/integration/admin_permission_grants_test.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 7: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1804 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 8: Commit**

```bash
git add app/admin/invoice_passes.rb app/services/mcp/get_invoice_passes_tool.rb \
  test/services/mcp/invoice_passes_tool_test.rb test/integration/admin_permission_grants_test.rb
git commit -m "feat(invoicing): surface the issuing enterprise in admin and MCP

Hides the Send Reminders / Generate Invoices actions on non-Sanctuary
passes, adds the enterprise to the invoicing index, and names the issuing
enterprise on each MCP pass row now that a month can have more than one."
```

---

### Task 7: Verify against real data and open the PR

**Files:** none modified. `db/schema.rb` must be **restored** after migrating (Step 1).

- [ ] **Step 1: Migrate development without clobbering the hand-curated schema**

`config.active_record.dump_schema_after_migration = false` is set **only** in `config/environments/production.rb`, so in development `db:migrate` re-dumps `db/schema.rb` — wiping the deliberate omissions (pgvector's `embeddings.embedding` and its HNSW index, `chunks.content_tsv`) and the composite-FK comment. A dumped schema with `enable_extension "vector"` also breaks Heroku CI.

```bash
bin/rails db:migrate
git checkout -- db/schema.rb
git status --porcelain
```

Expected: both migrations run clean, and `git status --porcelain` prints **nothing**. If `db/schema.rb` shows as modified after the checkout, stop and report.

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

Expected: `{"Sanctuary Computer Inc" => 64, "garden3d, LLC" => 7}`, `orphans: 0`, no mixed passes remaining, `{"forecast" => 1165}`.

- [ ] **Step 3: Confirm the daily task's invoicing step is safe**

```bash
bin/rails runner 'Stacks::Automator.attempt_invoicing_for_previous_month; puts "ok"'
```

Expected: `ok`, no `RecordInvalid`. This is the blast-radius check from Task 4 — if this raises, `stacks:daily_tasks` would abort every step after invoicing.

- [ ] **Step 4: Run the full suite one more time**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 1804 runs, 0 failures, 0 errors, 2 skips.

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
gains a `source` enum (`forecast` / `management_fee`) for the MSO trackers
a later subsystem adds.

`clients_served` is deliberately **not** scoped by enterprise — external
clients have no enterprise mapping, so scoping it that way would strip the
entire external book off Sanctuary's pass.

## Migration

64 passes, 1,165 trackers. Each pass takes its modal `qbo_account`'s
enterprise; every other issuer's trackers move to that enterprise's pass
for the same month. Generalised over `qbo_account_id`, not the seven known
mixed months (2025-06 … 2025-12), so a pass that has since gained an Index
Space or USB Club tracker splits correctly too. Passes the backfill creates
are tagged `data.created_by_backfill` so `down` re-merges only its own.

**Migrations are manual in this repo** — run `bin/rails db:migrate` after
deploy.

## Bugs fixed along the way

- `Stacks::Automator#attempt_invoicing_for_previous_month` created a pass
  with no enterprise. Under `null: false` that raises inside the single
  `begin/rescue` of `stacks:daily_tasks`, which would have aborted every
  later step: Runn, QBO and Deel sync, salary windows, every tracker and
  studio snapshot, notifications, and the task cache warm.
- The "Send Reminders" / "Generate Invoices" buttons were unconditional on
  every pass show page. On garden3d's pass they would have created trackers
  for Sanctuary's entire external book and pushed a **second full set of
  real QBO invoices** for the month, plus a second Twist thread.
- `Stacks::System#sync_founder_trueups!` picked the month's pass with an
  unordered `.first`, so it could select garden3d's — and if that pass ever
  held payouts, write a duplicate founder true-up (`Trueup` has no
  uniqueness validation).
- `PeriodicReport#invoice_passes` queried by `start_of_month` alone, so
  `#surplus` would have silently widened from Sanctuary to company-wide.
- `invoice_passes.start_of_month` was nullable under a unique index,
  leaving a duplicate-NULL hole. Now `null: false`.

## Testing

Full suite green: 1802 runs, 0 failures, 0 errors, 2 skips.

Migrations don't run in this suite (the test DB is schema-loaded from the
hand-curated `db/schema.rb`), so the backfill is tested by instantiating
the migration class directly, with the `NOT NULL` constraint dropped for
the duration to simulate pre-migration state.

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

Expected: Heroku CI green. This repo only deploys `main` once `main`'s own CI goes green, and an **errored** run silently withholds the deploy — check the run's conclusion, not merely the absence of failures.

---

## Self-Review

**Spec coverage.** Every §5 requirement maps to a task: §5.2 schema → Task 1; §5.3 backfill → Task 2; §5.1 issuer routing → Task 3; §5.4's call-site table → Tasks 4 (automator ×2), 5 (`sync_founder_trueups!`, `PeriodicReport`), 6 (admin actions, MCP tool), 1 (35 test sites). §12's S0 list is covered, with one stated exception below.

**Two deliberate deferrals.**

1. `admin_authorization.rb:95`'s `return true if subject.is_a?(InvoicePass)` over-grant stays as-is. It predates S0, and S0 does not widen which trackers a lead-in-training can reach — the same 7 trackers were readable on Sanctuary's pass before. It is fixed in S4 alongside the combined MSO guard (spec §10). The deferral rests on "no change in exposure": the same 7 trackers were already readable, and verified against production data each of the 7 new garden3d passes holds exactly one tracker for the **internal** "garden3d" forecast client with no QBO invoice, nil value and zero surplus — no client invoice and no revenue is exposed. (An earlier revision of this sentence claimed the opposite; it was wrong.)
2. `InvoiceTracker#status` returning `:impossible` for a blueprint-less tracker (spec §6.4) is **not** fixed here. It only bites once `:management_fee` trackers exist, which is S1. Flagged so S1 does not assume otherwise.

**Known coverage gap.** §12's "`sync_founder_trueups!` writes exactly one founder true-up with two passes present" is covered only by the pass-selection test, not by asserting a `Trueup` count. Building the payouts that would make the stronger assertion possible requires defeating `contributor_payouts_within_seventy_percent` and `only_after_new_deal` plus an `AdminUser` for `created_by`, which buys a brittle test; Task 7 Step 2's real-data check covers the outcome instead.

**Placeholders.** None. Every code step carries the actual code; every command carries its expected output, with run counts increasing monotonically (1783 → 1787 → 1792 → 1795 → 1798 → 1801 → 1803; Task 3 contributes 3, one of which came from the tie-break flake fix).

**Type consistency.** `InvoicePass#enterprise` (association), `InvoiceTracker#source` (string from the enum, asserted as `"forecast"`), `Enterprise.sanctuary` / `.garden3d` (thread-memoized, cleared in teardown everywhere they are used). `BackfillInvoicePassEnterprises` matches its filename in both the `require` and the instantiation. MCP assertions use string keys via `mcp_payload`, matching the existing file.
