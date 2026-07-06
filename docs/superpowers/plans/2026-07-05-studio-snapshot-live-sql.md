# Studio Snapshot Live SQL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Stages 1 + 2 of `docs/superpowers/specs/2026-07-05-studio-snapshot-live-sql-design.md`: normalized sync-time tables, a live read service that reproduces `studios.snapshot[gradation]` rows via fast SQL, a QBO backfill, and an oracle rake task that diffs live output against the stored blob. Consumer swaps (Stage 3) and deletion (Stage 4) happen in a follow-up PR after the oracle runs clean in production.

**Architecture:** Three sync services project already-synced data into queryable tables (`qbo_profit_and_loss_line_items`, `studio_forecast_people`, `notion_leads`). Read services (`Studios::Snapshots::*`) compute snapshot rows on demand from span-wide grouped queries folded into periods in Ruby. An oracle service diffs live output against the stored blob.

**Tech Stack:** Rails 6.1, PostgreSQL, minitest (+ mocha), fixtures already loaded via `fixtures :all`.

## Global Constraints

- **The read path never triggers a network call.** `Studios::Snapshots::*` read only local tables. Missing data → `Rails.logger.warn` + compute from what's present (legacy `find_row` returns 0 defaults; replicate).
- **Replicate legacy semantics exactly, bug-for-bug.** The oracle diff is the acceptance test; "more correct" output is a failure here. Notable legacy semantics to preserve:
  - `QboProfitAndLossReport#find_row` takes the **first** matching row (lowest position), NOT a sum. That's why line items store `position`.
  - Growth math uses `.to_f` division: `0/0 → NaN`, `x/0 → Infinity`. ActiveSupport JSON encoded those as `null` in the blob, so the oracle treats non-finite live floats as equal to stored `nil`.
  - `work_completed_at` (datetime) compared against Date-range bounds casts to midnight — completions later in the day on `ends_at` are excluded. Keep it.
  - Periods with `starts_at < Stacks::System::UTILIZATION_START_AT` (2021-06-01) get nil utilization datapoints.
- **No new fixture files** (`fixtures :all` loads them for every test and existing tests assume current DB contents). Create records inline in test `setup`.
- Tests that touch `Enterprise.sanctuary` must reset the memo: `Thread.current[:sanctuary_enterprise] = nil` in `setup` (existing convention, see `test/models/qbo_profit_and_loss_report_test.rb:5`).
- Service objects follow repo convention: `Domain::Verb` class with `.call` (see `app/services/deel_invoice_adjustments/sync_from_deel.rb`).
- Migration timestamps: use the next available `202607050000NN_` sequence.
- Run tests with `bundle exec rails test <path>`.

---

### Task 1: `qbo_profit_and_loss_line_items` table + `Qbo::SyncProfitAndLossLineItems`

**Files:**
- Create: `db/migrate/20260705000001_create_qbo_profit_and_loss_line_items.rb`
- Create: `app/models/qbo_profit_and_loss_line_item.rb`
- Create: `app/services/qbo/sync_profit_and_loss_line_items.rb`
- Modify: `app/models/qbo_profit_and_loss_report.rb` (hook in `find_or_fetch_for_range`)
- Test: `test/services/qbo/sync_profit_and_loss_line_items_test.rb`

**Interfaces:**
- Produces: `Qbo::SyncProfitAndLossLineItems.call(report)` → `:synced` | `:not_monthly`. `QboProfitAndLossLineItem` columns: `qbo_account_id`, `qbo_profit_and_loss_report_id`, `starts_at` (first of month), `accounting_method` ("cash"/"accrual"), `position` (int, row order), `label` (text), `amount` (decimal).

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260705000001_create_qbo_profit_and_loss_line_items.rb
class CreateQboProfitAndLossLineItems < ActiveRecord::Migration[6.1]
  def change
    create_table :qbo_profit_and_loss_line_items do |t|
      t.references :qbo_account, null: false, foreign_key: true, index: false
      # Cascade at the FK level: find_or_fetch_for_range(force:) uses
      # delete_all, which skips AR callbacks.
      t.references :qbo_profit_and_loss_report, null: false,
        foreign_key: { on_delete: :cascade }, index: false
      t.date :starts_at, null: false
      t.string :accounting_method, null: false
      t.integer :position, null: false
      t.text :label, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.timestamps
    end

    add_index :qbo_profit_and_loss_line_items,
      [:qbo_profit_and_loss_report_id, :accounting_method, :position],
      unique: true, name: "idx_pnl_line_items_report_method_position"
    add_index :qbo_profit_and_loss_line_items,
      [:qbo_account_id, :accounting_method, :starts_at],
      name: "idx_pnl_line_items_account_method_month"
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bundle exec rails db:migrate && RAILS_ENV=test bundle exec rails db:schema:load`
Expected: migrates cleanly; `db/schema.rb` gains the table.

- [ ] **Step 3: Write the model**

```ruby
# app/models/qbo_profit_and_loss_line_item.rb
class QboProfitAndLossLineItem < ApplicationRecord
  belongs_to :qbo_account
  belongs_to :qbo_profit_and_loss_report
end
```

- [ ] **Step 4: Write the failing test**

```ruby
# test/services/qbo/sync_profit_and_loss_line_items_test.rb
require "test_helper"

class Qbo::SyncProfitAndLossLineItemsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @account = qbo_accounts(:one)
  end

  def build_report(starts_at:, ends_at:, data:)
    QboProfitAndLossReport.create!(
      qbo_account: @account,
      starts_at: starts_at,
      ends_at: ends_at,
      data: data
    )
  end

  test "explodes a monthly report into line items for both methods" do
    report = build_report(
      starts_at: Date.new(2024, 3, 1),
      ends_at: Date.new(2024, 3, 31),
      data: {
        cash: { rows: [["Total Income", "100.5"], ["Total Expenses", "40"]] },
        accrual: { rows: [["Total Income", "120"]] }
      }
    )

    assert_equal :synced, Qbo::SyncProfitAndLossLineItems.call(report)

    items = QboProfitAndLossLineItem.where(qbo_profit_and_loss_report_id: report.id)
    assert_equal 3, items.count

    cash_income = items.find_by(accounting_method: "cash", label: "Total Income")
    assert_equal Date.new(2024, 3, 1), cash_income.starts_at
    assert_equal 0, cash_income.position
    assert_equal 100.5, cash_income.amount.to_f
    assert_equal @account.id, cash_income.qbo_account_id

    cash_expenses = items.find_by(accounting_method: "cash", label: "Total Expenses")
    assert_equal 1, cash_expenses.position
  end

  test "handles freshly-created reports whose data hash still has symbol keys" do
    # create! leaves symbol keys in the in-memory attribute until reload
    report = build_report(
      starts_at: Date.new(2024, 4, 1),
      ends_at: Date.new(2024, 4, 30),
      data: { cash: { rows: [["Total Income", 55]] }, accrual: { rows: [] } }
    )
    # Do NOT reload — the service must cope with either key type.
    assert_equal :synced, Qbo::SyncProfitAndLossLineItems.call(report)
    assert_equal 1, QboProfitAndLossLineItem.where(qbo_profit_and_loss_report: report).count
  end

  test "is idempotent — re-running replaces rows instead of duplicating" do
    report = build_report(
      starts_at: Date.new(2024, 3, 1),
      ends_at: Date.new(2024, 3, 31),
      data: { cash: { rows: [["Total Income", 1]] }, accrual: { rows: [] } }
    )
    Qbo::SyncProfitAndLossLineItems.call(report)
    Qbo::SyncProfitAndLossLineItems.call(report)
    assert_equal 1, QboProfitAndLossLineItem.where(qbo_profit_and_loss_report: report).count
  end

  test "skips non-monthly reports" do
    report = build_report(
      starts_at: Date.new(2024, 1, 1),
      ends_at: Date.new(2024, 3, 31),
      data: { cash: { rows: [["Total Income", 1]] }, accrual: { rows: [] } }
    )
    assert_equal :not_monthly, Qbo::SyncProfitAndLossLineItems.call(report)
    assert_equal 0, QboProfitAndLossLineItem.count
  end

  test "nil row values coerce to 0 (find_row .to_f parity)" do
    report = build_report(
      starts_at: Date.new(2024, 3, 1),
      ends_at: Date.new(2024, 3, 31),
      data: { cash: { rows: [["Income Section Header", nil]] }, accrual: { rows: [] } }
    )
    Qbo::SyncProfitAndLossLineItems.call(report)
    assert_equal 0.0, QboProfitAndLossLineItem.last.amount.to_f
  end

  test "line items cascade-delete when the report row is delete_all'd" do
    report = build_report(
      starts_at: Date.new(2024, 3, 1),
      ends_at: Date.new(2024, 3, 31),
      data: { cash: { rows: [["Total Income", 1]] }, accrual: { rows: [] } }
    )
    Qbo::SyncProfitAndLossLineItems.call(report)
    QboProfitAndLossReport.where(id: report.id).delete_all
    assert_equal 0, QboProfitAndLossLineItem.count
  end
end
```

- [ ] **Step 5: Run test to verify it fails**

Run: `bundle exec rails test test/services/qbo/sync_profit_and_loss_line_items_test.rb`
Expected: FAIL with `NameError: uninitialized constant Qbo::SyncProfitAndLossLineItems`

- [ ] **Step 6: Write the service**

```ruby
# app/services/qbo/sync_profit_and_loss_line_items.rb
module Qbo
  # Projects a MONTHLY QboProfitAndLossReport's jsonb rows into
  # qbo_profit_and_loss_line_items so studio datapoints can be computed with
  # SQL instead of Ruby row-walking. Idempotent: replaces the report's rows
  # in one transaction. Non-monthly reports are skipped — the monthly grain
  # is the fact table; wider ranges are folded from months at read time.
  class SyncProfitAndLossLineItems
    def self.call(report)
      return :not_monthly unless monthly?(report)

      # A freshly create!'d report still holds symbol keys in memory;
      # persisted jsonb reads back with string keys. Cope with both.
      data = report.data || {}
      now = Time.current
      rows = []
      %w[cash accrual].each do |method|
        source_rows = data.dig(method, "rows") || data.dig(method.to_sym, :rows) || []
        source_rows.each_with_index do |row, position|
          label, amount = row[0], row[1]
          next if label.nil?
          rows << {
            qbo_account_id: report.qbo_account_id,
            qbo_profit_and_loss_report_id: report.id,
            starts_at: report.starts_at,
            accounting_method: method,
            position: position,
            label: label,
            amount: amount.to_f, # find_row does r[1].to_f — nil → 0.0
            created_at: now,
            updated_at: now,
          }
        end
      end

      ActiveRecord::Base.transaction do
        QboProfitAndLossLineItem
          .where(qbo_profit_and_loss_report_id: report.id)
          .delete_all
        QboProfitAndLossLineItem.insert_all!(rows) if rows.any?
      end
      :synced
    end

    def self.monthly?(report)
      report.starts_at == report.starts_at.beginning_of_month &&
        report.ends_at == report.starts_at.end_of_month
    end
  end
end
```

- [ ] **Step 7: Run test to verify it passes**

Run: `bundle exec rails test test/services/qbo/sync_profit_and_loss_line_items_test.rb`
Expected: PASS (6 runs)

- [ ] **Step 8: Hook into `find_or_fetch_for_range`**

In `app/models/qbo_profit_and_loss_report.rb`, the `create!` at the end of `find_or_fetch_for_range` (currently the transaction block's last expression, lines 97–105) becomes:

```ruby
      report = create!(
        qbo_account: resolved_qbo_account,
        starts_at: start_of_range,
        ends_at: end_of_range,
        data: {
          cash: { rows: cash_report.all_rows },
          accrual: { rows: accrual_report.all_rows }
        }
      )
      # Keep the monthly line-item projection in lockstep with the source
      # report. QboAccount#sync_all! force-refreshes every monthly report
      # nightly, so this hook is the steady-state maintenance path.
      Qbo::SyncProfitAndLossLineItems.call(report)
      report
```

Add a test to the same test file:

```ruby
  test "find_or_fetch_for_range creates line items for monthly ranges" do
    cash = mock; cash.stubs(:all_rows).returns([["Total Income", 10]])
    accrual = mock; accrual.stubs(:all_rows).returns([["Total Income", 12]])
    @account.stubs(:fetch_profit_and_loss_report_for_range)
      .returns(cash).then.returns(accrual)

    report = QboProfitAndLossReport.find_or_fetch_for_range(
      Date.new(2024, 5, 1), Date.new(2024, 5, 31), false, @account
    )
    assert_equal 2, QboProfitAndLossLineItem.where(qbo_profit_and_loss_report: report).count
  end
```

- [ ] **Step 9: Run test file again**

Run: `bundle exec rails test test/services/qbo/sync_profit_and_loss_line_items_test.rb`
Expected: PASS (7 runs)

- [ ] **Step 10: Commit**

```bash
git add db/migrate db/schema.rb app/models/qbo_profit_and_loss_line_item.rb app/services/qbo/sync_profit_and_loss_line_items.rb app/models/qbo_profit_and_loss_report.rb test/services/qbo/sync_profit_and_loss_line_items_test.rb
git commit -m "Add qbo_profit_and_loss_line_items projection synced from monthly P&L reports"
```

---

### Task 2: `Qbo::BackfillMonthlyProfitAndLossReports` + rake tasks file

**Files:**
- Create: `app/services/qbo/backfill_monthly_profit_and_loss_reports.rb`
- Create: `lib/tasks/studio_snapshots.rake`
- Test: `test/services/qbo/backfill_monthly_profit_and_loss_reports_test.rb`

**Interfaces:**
- Consumes: `Qbo::SyncProfitAndLossLineItems.call(report)` (Task 1).
- Produces: `Qbo::BackfillMonthlyProfitAndLossReports.call(qbo_account:, from:, through:, sleep_between_fetches:)` → summary hash `{ existing:, fetched:, failed: [months], line_item_reports: }`. Rake task `stacks:backfill_monthly_pnl_line_items`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/qbo/backfill_monthly_profit_and_loss_reports_test.rb
require "test_helper"

class Qbo::BackfillMonthlyProfitAndLossReportsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @account = qbo_accounts(:one)
  end

  test "syncs line items for existing months and fetches missing ones" do
    existing = QboProfitAndLossReport.create!(
      qbo_account: @account,
      starts_at: Date.new(2024, 1, 1),
      ends_at: Date.new(2024, 1, 31),
      data: { cash: { rows: [["Total Income", 5]] }, accrual: { rows: [] } }
    )

    # Feb exists in the DB (so line-item inserts have a valid FK target) but
    # the service must see it as MISSING so it takes the fetch path. Stub the
    # existence probe per-month, and stub the fetch (no network in tests).
    fetched = QboProfitAndLossReport.create!(
      qbo_account: @account,
      starts_at: Date.new(2024, 2, 1),
      ends_at: Date.new(2024, 2, 29),
      data: { cash: { rows: [["Total Income", 7]] }, accrual: { rows: [] } }
    )
    QboProfitAndLossReport.stubs(:find_by)
      .with(qbo_account: @account, starts_at: Date.new(2024, 1, 1), ends_at: Date.new(2024, 1, 31))
      .returns(existing)
    QboProfitAndLossReport.stubs(:find_by)
      .with(qbo_account: @account, starts_at: Date.new(2024, 2, 1), ends_at: Date.new(2024, 2, 29))
      .returns(nil)
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range)
      .with(Date.new(2024, 2, 1), Date.new(2024, 2, 29), false, @account)
      .returns(fetched)

    summary = Qbo::BackfillMonthlyProfitAndLossReports.call(
      qbo_account: @account,
      from: Date.new(2024, 1, 1),
      through: Date.new(2024, 2, 29),
      sleep_between_fetches: 0
    )

    assert_equal 1, summary[:existing]
    assert_equal 1, summary[:fetched]
    assert_equal [], summary[:failed]
    assert_equal 2, summary[:line_item_reports]
    assert QboProfitAndLossLineItem.where(qbo_profit_and_loss_report_id: existing.id).exists?
  end

  test "a failed fetch is recorded and does not abort the run" do
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range).raises(StandardError.new("QBO down"))

    summary = Qbo::BackfillMonthlyProfitAndLossReports.call(
      qbo_account: @account,
      from: Date.new(2024, 1, 1),
      through: Date.new(2024, 2, 29),
      sleep_between_fetches: 0
    )

    assert_equal [Date.new(2024, 1, 1), Date.new(2024, 2, 1)], summary[:failed]
    assert_equal 0, summary[:line_item_reports]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/services/qbo/backfill_monthly_profit_and_loss_reports_test.rb`
Expected: FAIL with `NameError: uninitialized constant Qbo::BackfillMonthlyProfitAndLossReports`

- [ ] **Step 3: Write the service**

```ruby
# app/services/qbo/backfill_monthly_profit_and_loss_reports.rb
module Qbo
  # One-time rollout backfill: ensure a monthly QboProfitAndLossReport row
  # exists for every calendar month in [from, through] (fetching missing ones
  # from QBO, throttled), then (re)project line items for each. Idempotent
  # and resumable — safe to re-run after a partial failure. Steady-state
  # maintenance afterwards is the find_or_fetch_for_range hook driven by the
  # nightly QboAccount#sync_all!.
  class BackfillMonthlyProfitAndLossReports
    def self.call(qbo_account:, from: Date.new(2020, 1, 1),
                  through: Date.today.last_month.end_of_month,
                  sleep_between_fetches: 1)
      summary = { existing: 0, fetched: 0, failed: [], line_item_reports: 0 }
      month = from.beginning_of_month

      while month <= through
        report = QboProfitAndLossReport.find_by(
          qbo_account: qbo_account, starts_at: month, ends_at: month.end_of_month
        )

        if report
          summary[:existing] += 1
        else
          begin
            report = QboProfitAndLossReport.find_or_fetch_for_range(
              month, month.end_of_month, false, qbo_account
            )
            summary[:fetched] += 1
            sleep(sleep_between_fetches)
          rescue StandardError => e
            Rails.logger.warn(
              "[Qbo::BackfillMonthlyProfitAndLossReports] #{month} failed: #{e.class} #{e.message}"
            )
            summary[:failed] << month
            report = nil
          end
        end

        if report && SyncProfitAndLossLineItems.call(report) == :synced
          summary[:line_item_reports] += 1
        end

        month = month.advance(months: 1)
      end

      summary
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/services/qbo/backfill_monthly_profit_and_loss_reports_test.rb`
Expected: PASS (2 runs)

- [ ] **Step 5: Create the rake file with the backfill task**

```ruby
# lib/tasks/studio_snapshots.rake
namespace :stacks do
  desc "Backfill monthly P&L reports + line items for every QBO account (rollout, idempotent)"
  task backfill_monthly_pnl_line_items: :environment do
    QboAccount.all.each do |account|
      summary = Qbo::BackfillMonthlyProfitAndLossReports.call(qbo_account: account)
      puts "~~~> qbo_account=#{account.id} #{summary.inspect}"
    end
  end
end
```

- [ ] **Step 6: Verify the task loads**

Run: `bundle exec rake -T | grep backfill_monthly_pnl`
Expected: `rake stacks:backfill_monthly_pnl_line_items` listed.

- [ ] **Step 7: Commit**

```bash
git add app/services/qbo/backfill_monthly_profit_and_loss_reports.rb lib/tasks/studio_snapshots.rake test/services/qbo/backfill_monthly_profit_and_loss_reports_test.rb
git commit -m "Add monthly P&L backfill service and rake task"
```

---

### Task 3: `studio_forecast_people` table + `Studios::SyncForecastPeople` + daily rake hook

**Files:**
- Create: `db/migrate/20260705000002_create_studio_forecast_people.rb`
- Create: `app/models/studio_forecast_person.rb`
- Create: `app/services/studios/sync_forecast_people.rb`
- Modify: `lib/tasks/stacks.rake` (daily task, immediately before `puts "~~~> DOING SNAPSHOTS"`)
- Test: `test/services/studios/sync_forecast_people_test.rb`

**Interfaces:**
- Produces: `Studios::SyncForecastPeople.call` (full rebuild). `StudioForecastPerson` columns: `studio_id`, `forecast_person_id` (references `forecast_people.id`, NOT `forecast_id`), unique on the pair.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260705000002_create_studio_forecast_people.rb
class CreateStudioForecastPeople < ActiveRecord::Migration[6.1]
  def change
    create_table :studio_forecast_people do |t|
      t.references :studio, null: false, foreign_key: true, index: false
      t.references :forecast_person, null: false, foreign_key: true
      t.timestamps
    end

    add_index :studio_forecast_people, [:studio_id, :forecast_person_id], unique: true
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bundle exec rails db:migrate && RAILS_ENV=test bundle exec rails db:schema:load`
Expected: clean.

- [ ] **Step 3: Write the model**

```ruby
# app/models/studio_forecast_person.rb
class StudioForecastPerson < ApplicationRecord
  belongs_to :studio
  belongs_to :forecast_person
end
```

- [ ] **Step 4: Write the failing test**

```ruby
# test/services/studios/sync_forecast_people_test.rb
require "test_helper"

class Studios::SyncForecastPeopleTest < ActiveSupport::TestCase
  setup do
    @g3d = Studio.create!(name: "garden3d", mini_name: "g3d", studio_type: :client_services)
    @xxix = Studio.create!(name: "XXIX", mini_name: "xxix", studio_type: :client_services, accounting_prefix: "XXIX")
    # Person matched to XXIX by Forecast role name
    @role_matched = ForecastPerson.create!(forecast_id: 9001, email: "role@x.com", roles: ["XXIX"])
    # Person with no studio at all
    @unmatched = ForecastPerson.create!(forecast_id: 9002, email: "none@x.com", roles: [])
  end

  test "mirrors Studio#forecast_people into the join table" do
    Studios::SyncForecastPeople.call

    # garden3d gets everyone (Studio#forecast_people returns all people for g3d)
    g3d_ids = StudioForecastPerson.where(studio: @g3d).pluck(:forecast_person_id)
    assert_includes g3d_ids, @role_matched.id
    assert_includes g3d_ids, @unmatched.id

    xxix_ids = StudioForecastPerson.where(studio: @xxix).pluck(:forecast_person_id)
    assert_equal [@role_matched.id], xxix_ids
  end

  test "rebuild removes stale mappings" do
    StudioForecastPerson.create!(studio: @xxix, forecast_person: @unmatched)
    Studios::SyncForecastPeople.call
    refute StudioForecastPerson.where(studio: @xxix, forecast_person: @unmatched).exists?
  end
end
```

- [ ] **Step 5: Run test to verify it fails**

Run: `bundle exec rails test test/services/studios/sync_forecast_people_test.rb`
Expected: FAIL with `NameError: uninitialized constant Studios::SyncForecastPeople`

- [ ] **Step 6: Write the service**

```ruby
# app/services/studios/sync_forecast_people.rb
module Studios
  # Materializes Studio#forecast_people into studio_forecast_people so
  # utilization aggregation can happen in SQL. Deliberately implemented BY
  # CALLING Studio#forecast_people — the Ruby heuristics (admin_user studio
  # memberships, Forecast role-name matching, garden3d-gets-everyone) stay
  # the single source of truth and this table can never drift in logic,
  # only in time. Full rebuild each run; the table is tiny.
  class SyncForecastPeople
    def self.call(all_studios: Studio.all.to_a)
      now = Time.current
      rows = all_studios.flat_map do |studio|
        studio.forecast_people(all_studios).map do |fp|
          {
            studio_id: studio.id,
            forecast_person_id: fp.id,
            created_at: now,
            updated_at: now,
          }
        end
      end

      ActiveRecord::Base.transaction do
        StudioForecastPerson.delete_all
        StudioForecastPerson.insert_all!(rows) if rows.any?
      end
    end
  end
end
```

- [ ] **Step 7: Run test to verify it passes**

Run: `bundle exec rails test test/services/studios/sync_forecast_people_test.rb`
Expected: PASS (2 runs). Note: `Studio#forecast_people` calls `ForecastPerson.includes(admin_user: [:studios, :full_time_periods])` — if the test errors on an association, inspect and adapt setup (people need no admin_user for this test).

- [ ] **Step 8: Hook into the daily rake task**

In `lib/tasks/stacks.rake`, directly above `puts "~~~> DOING SNAPSHOTS"` (after the `fp.sync_utilization_reports!` Parallel block), add:

```ruby
      puts "~~~> SYNCING SNAPSHOT SOURCE TABLES"
      Studios::SyncForecastPeople.call
```

- [ ] **Step 9: Commit**

```bash
git add db/migrate db/schema.rb app/models/studio_forecast_person.rb app/services/studios/sync_forecast_people.rb lib/tasks/stacks.rake test/services/studios/sync_forecast_people_test.rb
git commit -m "Materialize studio forecast-people membership for SQL aggregation"
```

---

### Task 4: `notion_leads` tables + `Leads::SyncFromNotionPages` + rake hooks

**Files:**
- Create: `db/migrate/20260705000003_create_notion_leads.rb`
- Create: `app/models/notion_lead.rb`
- Create: `app/models/notion_lead_studio.rb`
- Modify: `lib/tasks/stacks.rake` (two hooks: daily task + end of "Sync Notion" task)
- Create: `app/services/leads/sync_from_notion_pages.rb`
- Test: `test/services/leads/sync_from_notion_pages_test.rb`

**Interfaces:**
- Produces: `Leads::SyncFromNotionPages.call` (full rebuild). `NotionLead` columns: `notion_page_id` (unique), `received_at`, `settled_at`, `proposal_sent_at`, `won_at` (all date, nullable). Scope `NotionLead.for_studio(studio)` → all leads for garden3d, else join-scoped. `NotionLeadStudio` join.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260705000003_create_notion_leads.rb
class CreateNotionLeads < ActiveRecord::Migration[6.1]
  def change
    create_table :notion_leads do |t|
      t.references :notion_page, null: false, foreign_key: true, index: { unique: true }
      t.date :received_at
      t.date :settled_at
      t.date :proposal_sent_at
      t.date :won_at
      t.timestamps
    end

    create_table :notion_lead_studios do |t|
      t.references :notion_lead, null: false, foreign_key: true, index: false
      t.references :studio, null: false, foreign_key: true
      t.timestamps
    end

    add_index :notion_lead_studios, [:notion_lead_id, :studio_id], unique: true
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bundle exec rails db:migrate && RAILS_ENV=test bundle exec rails db:schema:load`
Expected: clean.

- [ ] **Step 3: Write the models**

```ruby
# app/models/notion_lead.rb
# Derived projection of NotionPage lead rows (dates parsed once at sync time
# by Leads::SyncFromNotionPages) so lead datapoints are computable in SQL.
class NotionLead < ApplicationRecord
  belongs_to :notion_page
  has_many :notion_lead_studios, dependent: :delete_all
  has_many :studios, through: :notion_lead_studios

  # garden3d sees every lead (mirrors Studio#new_biz_leads).
  scope :for_studio, ->(studio) {
    if studio.is_garden3d?
      all
    else
      joins(:notion_lead_studios).where(notion_lead_studios: { studio_id: studio.id })
    end
  }
end
```

```ruby
# app/models/notion_lead_studio.rb
class NotionLeadStudio < ApplicationRecord
  belongs_to :notion_lead
  belongs_to :studio
end
```

- [ ] **Step 4: Write the failing test**

```ruby
# test/services/leads/sync_from_notion_pages_test.rb
require "test_helper"

class Leads::SyncFromNotionPagesTest < ActiveSupport::TestCase
  setup do
    @xxix = Studio.create!(name: "XXIX", mini_name: "xxix", studio_type: :client_services)
    # Studio.all_studios memoizes at class level — reset between tests
    Studio.instance_variable_set(:@all_studios, nil)
  end

  teardown do
    Studio.instance_variable_set(:@all_studios, nil)
  end

  def lead_page!(props)
    NotionPage.create!(
      notion_id: SecureRandom.uuid,
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]),
      data: { "properties" => props }
    )
  end

  test "projects lead pages into notion_leads with parsed dates and studio links" do
    page = lead_page!(
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => "2024-03-02" } },
      "Settled Date" => { "type" => "formula", "formula" => { "string" => "2024-04-01" } },
      "✨ Proposal Sent" => { "type" => "date", "date" => { "start" => "2024-03-10" } },
      "✨ Status: Won" => { "type" => "date", "date" => { "start" => "2024-04-01" } },
      "Studio" => { "type" => "multi_select", "multi_select" => [{ "name" => "XXIX" }] }
    )

    Leads::SyncFromNotionPages.call

    lead = NotionLead.find_by!(notion_page_id: page.id)
    assert_equal Date.new(2024, 3, 2), lead.received_at
    assert_equal Date.new(2024, 4, 1), lead.settled_at
    assert_equal Date.new(2024, 3, 10), lead.proposal_sent_at
    assert_equal Date.new(2024, 4, 1), lead.won_at
    assert_equal [@xxix.id], lead.studios.pluck(:id)
  end

  test "unparseable or absent dates become nil without dropping the lead" do
    page = lead_page!(
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => "not a date" } }
    )

    Leads::SyncFromNotionPages.call

    lead = NotionLead.find_by!(notion_page_id: page.id)
    assert_nil lead.received_at
    assert_nil lead.settled_at
  end

  test "rebuild drops leads whose pages were deleted" do
    page = lead_page!({})
    Leads::SyncFromNotionPages.call
    assert_equal 1, NotionLead.count

    page.destroy # acts_as_paranoid soft delete; NotionPage.lead excludes it
    Leads::SyncFromNotionPages.call
    assert_equal 0, NotionLead.count
  end

  test "for_studio scopes by join, garden3d sees all" do
    g3d = Studio.create!(name: "garden3d", mini_name: "g3d")
    Studio.instance_variable_set(:@all_studios, nil)
    lead_page!("Studio" => { "type" => "multi_select", "multi_select" => [{ "name" => "XXIX" }] })
    lead_page!({})
    Leads::SyncFromNotionPages.call

    assert_equal 1, NotionLead.for_studio(@xxix).count
    assert_equal 2, NotionLead.for_studio(g3d).count
  end
end
```

- [ ] **Step 5: Run test to verify it fails**

Run: `bundle exec rails test test/services/leads/sync_from_notion_pages_test.rb`
Expected: FAIL with `NameError: uninitialized constant Leads::SyncFromNotionPages`

- [ ] **Step 6: Write the service**

```ruby
# app/services/leads/sync_from_notion_pages.rb
module Leads
  # Projects NotionPage lead rows into notion_leads(+studios) so lead
  # datapoints are computable without parsing jsonb per request. Field
  # extraction goes through the existing Stacks::Notion::Lead accessors —
  # they stay the single source of truth for Notion property names. Full
  # rebuild each run (hundreds of rows); per-row failures warn and skip so
  # one malformed page can't sink the rebuild.
  class SyncFromNotionPages
    def self.call
      pages = NotionPage.lead.to_a

      ActiveRecord::Base.transaction do
        NotionLeadStudio.delete_all
        NotionLead.delete_all

        pages.each do |page|
          lead = page.as_lead
          row = NotionLead.create!(
            notion_page_id: page.id,
            received_at: parse_date(page, :received_at, lead.received_at),
            settled_at: parse_date(page, :settled_at, lead.settled_at),
            proposal_sent_at: parse_date(page, :proposal_sent_at, lead.proposal_sent_at),
            won_at: parse_date(page, :won_at, lead.won_at),
          )
          lead.studios.each do |studio|
            NotionLeadStudio.create!(notion_lead: row, studio: studio)
          end
        rescue StandardError => e
          Rails.logger.warn(
            "[Leads::SyncFromNotionPages] skipping notion_page=#{page.id}: #{e.class} #{e.message}"
          )
        end
      end
    end

    def self.parse_date(page, attr, raw)
      return nil if raw.blank?
      Date.parse(raw.to_s)
    rescue Date::Error
      Rails.logger.warn(
        "[Leads::SyncFromNotionPages] unparseable #{attr}=#{raw.inspect} on notion_page=#{page.id}"
      )
      nil
    end
  end
end
```

- [ ] **Step 7: Run test to verify it passes**

Run: `bundle exec rails test test/services/leads/sync_from_notion_pages_test.rb`
Expected: PASS (4 runs). Note: the lead accessors return `{}.dig(...)` → nil for absent props, so no special-casing needed; if `NotionPage.create!` demands more columns, add the minimum.

- [ ] **Step 8: Add rake hooks**

In `lib/tasks/stacks.rake`:

1. Daily task — extend the block added in Task 3 to:

```ruby
      puts "~~~> SYNCING SNAPSHOT SOURCE TABLES"
      Studios::SyncForecastPeople.call
      Leads::SyncFromNotionPages.call
```

2. End of the "Sync Notion" task (after the `Parallel.map(Stacks::Notion::DATABASE_IDS.values...)` block finishes, inside the task):

```ruby
      Leads::SyncFromNotionPages.call
```

- [ ] **Step 9: Commit**

```bash
git add db/migrate db/schema.rb app/models/notion_lead.rb app/models/notion_lead_studio.rb app/services/leads/sync_from_notion_pages.rb lib/tasks/stacks.rake test/services/leads/sync_from_notion_pages_test.rb
git commit -m "Project Notion lead pages into notion_leads for SQL datapoints"
```

---

### Task 5: `Studios::Snapshots::PnlByMonth` read service

**Files:**
- Create: `app/services/studios/snapshots/pnl_by_month.rb`
- Test: `test/services/studios/snapshots/pnl_by_month_test.rb`

**Interfaces:**
- Consumes: `QboProfitAndLossLineItem` (Task 1).
- Produces: `Studios::Snapshots::PnlByMonth.call(studio:, from:, through:, qbo_account: Enterprise.sanctuary.qbo_account)` → `{ "cash" => { Date(first-of-month) => { income:, cost_of_goods_sold:, expenses:, net_operating_income: } }, "accrual" => { ... } }`. All Float. Months with no line items are absent from the hash.

**CRITICAL SEMANTICS:** legacy `find_row` returns the FIRST matching row's value (`rows.find { ... }`), defaulting to 0 — never a sum. A report can contain both a section-header row and a `Total …` row matching the same substring. Replicate by fetching candidate rows ordered by `position` and taking the first match per (method, month, metric) in Ruby.

Legacy per-metric predicates (from `Studio#profit_and_loss_for_period`):
- garden3d (`studio.is_garden3d?`): exact labels — income `== "Total Income"`, cogs `== "Total Cost of Goods Sold"`, expenses `== "Total Expenses"`, noi `== "Net Operating Income"`; all four read directly.
- other studios (`prefix = studio.accounting_prefix`): `income_raw` = first row where `label.include?("Revenue - #{prefix}")`; `cos_raw` = first row where `label.start_with?("Total") && label.include?("COS - #{prefix}")`; `expenses_raw` = first row where `label.include?("Tools and Subscriptions - #{prefix}")`. Then: `income = income_raw`, `expenses = expenses_raw`, `cost_of_goods_sold = cos_raw - expenses_raw`, `net_operating_income = income_raw - cos_raw`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/studios/snapshots/pnl_by_month_test.rb
require "test_helper"

class Studios::Snapshots::PnlByMonthTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @account = qbo_accounts(:one)
    @g3d = Studio.create!(name: "garden3d", mini_name: "g3d")
    @xxix = Studio.create!(name: "XXIX", mini_name: "xxix", accounting_prefix: "XXIX")
  end

  def seed_month!(month, method, rows)
    report = QboProfitAndLossReport.find_or_create_by!(
      qbo_account: @account, starts_at: month, ends_at: month.end_of_month
    ) { |r| r.data = {} }
    rows.each_with_index do |(label, amount), position|
      QboProfitAndLossLineItem.create!(
        qbo_account: @account, qbo_profit_and_loss_report: report,
        starts_at: month, accounting_method: method,
        position: position, label: label, amount: amount
      )
    end
  end

  test "garden3d reads the four total rows per month" do
    seed_month!(Date.new(2024, 1, 1), "cash", [
      ["Total Income", 100], ["Total Cost of Goods Sold", 30],
      ["Total Expenses", 20], ["Net Operating Income", 50]
    ])
    seed_month!(Date.new(2024, 2, 1), "cash", [["Total Income", 10]])

    out = Studios::Snapshots::PnlByMonth.call(
      studio: @g3d, from: Date.new(2024, 1, 1), through: Date.new(2024, 2, 29),
      qbo_account: @account
    )

    jan = out["cash"][Date.new(2024, 1, 1)]
    assert_equal 100.0, jan[:income]
    assert_equal 30.0, jan[:cost_of_goods_sold]
    assert_equal 20.0, jan[:expenses]
    assert_equal 50.0, jan[:net_operating_income]

    feb = out["cash"][Date.new(2024, 2, 1)]
    assert_equal 10.0, feb[:income]
    assert_equal 0.0, feb[:cost_of_goods_sold] # find_row default when label absent
  end

  test "prefixed studio takes FIRST matching row by position, then derives" do
    seed_month!(Date.new(2024, 1, 1), "cash", [
      ["Revenue - XXIX", 200],          # first match wins for income
      ["Total Revenue - XXIX", 999],    # ignored — later position
      ["Total COS - XXIX", 80],
      ["Tools and Subscriptions - XXIX", 15]
    ])

    out = Studios::Snapshots::PnlByMonth.call(
      studio: @xxix, from: Date.new(2024, 1, 1), through: Date.new(2024, 1, 31),
      qbo_account: @account
    )

    jan = out["cash"][Date.new(2024, 1, 1)]
    assert_equal 200.0, jan[:income]
    assert_equal 65.0, jan[:cost_of_goods_sold]       # 80 - 15
    assert_equal 15.0, jan[:expenses]
    assert_equal 120.0, jan[:net_operating_income]    # 200 - 80
  end

  test "months without line items are absent" do
    out = Studios::Snapshots::PnlByMonth.call(
      studio: @g3d, from: Date.new(2024, 1, 1), through: Date.new(2024, 3, 31),
      qbo_account: @account
    )
    assert_equal({}, out["cash"])
    assert_equal({}, out["accrual"])
  end

  test "methods are kept separate" do
    seed_month!(Date.new(2024, 1, 1), "cash", [["Total Income", 100]])
    seed_month!(Date.new(2024, 1, 1), "accrual", [["Total Income", 140]])

    out = Studios::Snapshots::PnlByMonth.call(
      studio: @g3d, from: Date.new(2024, 1, 1), through: Date.new(2024, 1, 31),
      qbo_account: @account
    )
    assert_equal 100.0, out["cash"][Date.new(2024, 1, 1)][:income]
    assert_equal 140.0, out["accrual"][Date.new(2024, 1, 1)][:income]
  end
end
```

Note for the implementer: `seed_month!` re-uses one report per (account, month) — when called twice for the same month with different methods, positions restart at 0. That violates the unique index `(report_id, accounting_method, position)`? No — the index includes `accounting_method`, so cash-0 and accrual-0 coexist.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/services/studios/snapshots/pnl_by_month_test.rb`
Expected: FAIL with `NameError: uninitialized constant Studios::Snapshots`

- [ ] **Step 3: Write the service**

```ruby
# app/services/studios/snapshots/pnl_by_month.rb
module Studios
  module Snapshots
    # Monthly P&L totals for a studio from qbo_profit_and_loss_line_items.
    # Returns { "cash" => { Date => {income:, cost_of_goods_sold:, expenses:,
    # net_operating_income:} }, "accrual" => ... } with Float values; months
    # with no line items are absent.
    #
    # Replicates Studio#profit_and_loss_for_period / find_row semantics
    # exactly: FIRST matching row by report position (never SUM — a report
    # can hold both a section row and a "Total …" row matching the same
    # substring), 0.0 default when no row matches.
    class PnlByMonth
      def self.call(studio:, from:, through:, qbo_account: Enterprise.sanctuary.qbo_account)
        new(studio, from, through, qbo_account).call
      end

      G3D_LABELS = [
        "Total Income",
        "Total Cost of Goods Sold",
        "Total Expenses",
        "Net Operating Income",
      ].freeze

      def initialize(studio, from, through, qbo_account)
        @studio = studio
        @from = from.beginning_of_month
        @through = through
        @qbo_account = qbo_account
      end

      def call
        candidates = candidate_rows
        out = { "cash" => {}, "accrual" => {} }
        candidates
          .group_by { |method, starts_at, _pos, _label, _amount| [method, starts_at] }
          .each do |(method, starts_at), rows|
            # rows are position-ordered (query orders by position)
            labels_and_amounts = rows.map { |_m, _s, _p, label, amount| [label, amount.to_f] }
            out[method][starts_at] = totals_for(labels_and_amounts)
          end
        out
      end

      private

      def candidate_rows
        QboProfitAndLossLineItem
          .where(qbo_account_id: @qbo_account.id, starts_at: @from..@through)
          .where(candidate_predicate)
          .order(:accounting_method, :starts_at, :position)
          .pluck(:accounting_method, :starts_at, :position, :label, :amount)
      end

      def candidate_predicate
        if @studio.is_garden3d?
          QboProfitAndLossLineItem.arel_table[:label].in(G3D_LABELS)
        else
          p = ActiveRecord::Base.sanitize_sql_like(@studio.accounting_prefix.to_s)
          ActiveRecord::Base.sanitize_sql_array([
            "(label LIKE :income OR (label LIKE 'Total%' AND label LIKE :cos) OR label LIKE :tools)",
            income: "%Revenue - #{p}%",
            cos: "%COS - #{p}%",
            tools: "%Tools and Subscriptions - #{p}%",
          ])
        end
      end

      # first_match mirrors find_row: first row (by position) passing the
      # Ruby predicate; 0.0 when none does.
      def first_match(labels_and_amounts)
        row = labels_and_amounts.find { |label, _| yield(label) }
        row ? row[1] : 0.0
      end

      def totals_for(labels_and_amounts)
        if @studio.is_garden3d?
          {
            income: first_match(labels_and_amounts) { |l| l == "Total Income" },
            cost_of_goods_sold: first_match(labels_and_amounts) { |l| l == "Total Cost of Goods Sold" },
            expenses: first_match(labels_and_amounts) { |l| l == "Total Expenses" },
            net_operating_income: first_match(labels_and_amounts) { |l| l == "Net Operating Income" },
          }
        else
          prefix = @studio.accounting_prefix
          income = first_match(labels_and_amounts) { |l| l.include?("Revenue - #{prefix}") }
          cos = first_match(labels_and_amounts) { |l| l.start_with?("Total") && l.include?("COS - #{prefix}") }
          expenses = first_match(labels_and_amounts) { |l| l.include?("Tools and Subscriptions - #{prefix}") }
          {
            income: income,
            cost_of_goods_sold: cos - expenses,
            expenses: expenses,
            net_operating_income: income - cos,
          }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/services/studios/snapshots/pnl_by_month_test.rb`
Expected: PASS (4 runs)

- [ ] **Step 5: Commit**

```bash
git add app/services/studios/snapshots/pnl_by_month.rb test/services/studios/snapshots/pnl_by_month_test.rb
git commit -m "Add PnlByMonth read service replicating find_row first-match semantics"
```

---

### Task 6: `Studios::Snapshots::UtilizationByMonth` read service

**Files:**
- Create: `app/services/studios/snapshots/utilization_by_month.rb`
- Test: `test/services/studios/snapshots/utilization_by_month_test.rb`

**Interfaces:**
- Consumes: `StudioForecastPerson` (Task 3), `ForecastPersonUtilizationReport` (existing; enum `period_gradation`, monthly rows have `period_gradation: :month`).
- Produces: `Studios::Snapshots::UtilizationByMonth.call(studio:, from:, through:)` → `{ Date(first-of-month) => { ForecastPerson => { time_off:, billable: {"rate"=>hours}, non_billable:, non_sellable:, sellable: } } }`. Field mapping identical to legacy `Studio#utilization_for_period`: `time_off: actual_hours_time_off, billable: actual_hours_sold_by_rate, non_billable: actual_hours_internal, non_sellable: expected_hours_unsold, sellable: expected_hours_sold`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/studios/snapshots/utilization_by_month_test.rb
require "test_helper"

class Studios::Snapshots::UtilizationByMonthTest < ActiveSupport::TestCase
  setup do
    @studio = Studio.create!(name: "XXIX", mini_name: "xxix")
    @fp = ForecastPerson.create!(forecast_id: 9101, email: "a@x.com")
    @other_fp = ForecastPerson.create!(forecast_id: 9102, email: "b@x.com")
    StudioForecastPerson.create!(studio: @studio, forecast_person: @fp)
  end

  def report!(fp, month, gradation: :month, sellable: 100, billable_map: { "150.0" => 40.0 })
    ForecastPersonUtilizationReport.create!(
      forecast_person_id: fp.id,
      starts_at: month,
      ends_at: month.end_of_month,
      period_gradation: gradation,
      expected_hours_sold: sellable,
      expected_hours_unsold: 10,
      actual_hours_sold: 40,
      actual_hours_internal: 5,
      actual_hours_time_off: 8,
      actual_hours_sold_by_rate: billable_map,
      utilization_rate: 40.0
    )
  end

  test "returns per-month per-person maps for the studio's people only" do
    report!(@fp, Date.new(2024, 1, 1))
    report!(@other_fp, Date.new(2024, 1, 1)) # not in studio → excluded

    out = Studios::Snapshots::UtilizationByMonth.call(
      studio: @studio, from: Date.new(2024, 1, 1), through: Date.new(2024, 1, 31)
    )

    month = out[Date.new(2024, 1, 1)]
    assert_equal [@fp.id], month.keys.map(&:id)
    data = month[@fp]
    assert_equal 8, data[:time_off]
    assert_equal({ "150.0" => 40.0 }, data[:billable])
    assert_equal 5, data[:non_billable]
    assert_equal 10, data[:non_sellable]
    assert_equal 100, data[:sellable]
  end

  test "only monthly-gradation rows are read" do
    report!(@fp, Date.new(2024, 1, 1), gradation: :quarter)
    out = Studios::Snapshots::UtilizationByMonth.call(
      studio: @studio, from: Date.new(2024, 1, 1), through: Date.new(2024, 3, 31)
    )
    assert_equal({}, out)
  end

  test "spans multiple months" do
    report!(@fp, Date.new(2024, 1, 1))
    report!(@fp, Date.new(2024, 2, 1))
    out = Studios::Snapshots::UtilizationByMonth.call(
      studio: @studio, from: Date.new(2024, 1, 1), through: Date.new(2024, 2, 29)
    )
    assert_equal [Date.new(2024, 1, 1), Date.new(2024, 2, 1)], out.keys.sort
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/services/studios/snapshots/utilization_by_month_test.rb`
Expected: FAIL with `NameError: uninitialized constant Studios::Snapshots::UtilizationByMonth`

- [ ] **Step 3: Write the service**

```ruby
# app/services/studios/snapshots/utilization_by_month.rb
module Studios
  module Snapshots
    # Monthly per-person utilization for a studio, from monthly-grain
    # ForecastPersonUtilizationReport rows scoped through the
    # studio_forecast_people projection. Field mapping matches legacy
    # Studio#utilization_for_period exactly. Monthly rows are additive per
    # person, so callers fold quarters / years / trailing windows from these.
    class UtilizationByMonth
      def self.call(studio:, from:, through:)
        ForecastPersonUtilizationReport
          .where(period_gradation: :month)
          .where(starts_at: from.beginning_of_month..through)
          .where(
            forecast_person_id: StudioForecastPerson
              .where(studio_id: studio.id)
              .select(:forecast_person_id)
          )
          .includes(:forecast_person)
          .reduce({}) do |acc, report|
            (acc[report.starts_at] ||= {})[report.forecast_person] = {
              time_off: report.actual_hours_time_off,
              billable: report.actual_hours_sold_by_rate,
              non_billable: report.actual_hours_internal,
              non_sellable: report.expected_hours_unsold,
              sellable: report.expected_hours_sold,
            }
            acc
          end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/services/studios/snapshots/utilization_by_month_test.rb`
Expected: PASS (3 runs)

- [ ] **Step 5: Commit**

```bash
git add app/services/studios/snapshots/utilization_by_month.rb test/services/studios/snapshots/utilization_by_month_test.rb
git commit -m "Add UtilizationByMonth read service over studio_forecast_people"
```

---

### Task 7: Extract `Studios::Snapshots::OkrRows` (shared by legacy blob path)

**Files:**
- Create: `app/services/studios/snapshots/okr_rows.rb`
- Modify: `app/models/studio.rb` (`okrs_for_period` and `hint_for_okr` become delegations)
- Test: `test/services/studios/snapshots/okr_rows_test.rb`

**Interfaces:**
- Produces: `Studios::Snapshots::OkrRows.call(studio:, period:, datapoints:, okrs:)` → hash keyed by OKR name (same output as legacy `Studio#okrs_for_period`). `Studios::Snapshots::OkrRows.hint_for_okr(okr, datapoints)` → String.
- The legacy blob path (`Studio#snapshot_data_for_period`) keeps working unchanged through the delegation — both paths share one implementation, so the oracle compares aggregation math, not OKR-logic drift.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/studios/snapshots/okr_rows_test.rb
require "test_helper"

class Studios::Snapshots::OkrRowsTest < ActiveSupport::TestCase
  setup do
    @studio = Studio.create!(name: "XXIX", mini_name: "xxix")
    @okr = Okr.create!(name: "Profit Margin", datapoint: "profit_margin", operator: "greater_than")
    @okr_period = OkrPeriod.create!(
      okr: @okr,
      period_starts_at: Date.new(2024, 1, 1),
      period_ends_at: Date.new(2024, 12, 31),
      target: 20,
      tolerance: 5
    )
    OkrPeriodStudio.create!(okr_period: @okr_period, studio: @studio)
    @period = Stacks::Period.new("January, 2024", Date.new(2024, 1, 1), Date.new(2024, 1, 31), :month)
    @datapoints = {
      profit_margin: { value: 30.0, unit: :percentage },
      income: { value: 1000.0, unit: :usd },
      net_operating_income: { value: 300.0, unit: :usd },
    }
  end

  test "returns health-annotated okr rows and synthesized Profit rows" do
    okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio } }).all
    out = Studios::Snapshots::OkrRows.call(
      studio: @studio, period: @period, datapoints: @datapoints, okrs: okrs
    )

    assert out.key?("Profit Margin")
    assert_equal 30.0, out["Profit Margin"][:value]
    assert out["Profit Margin"][:health].present?
    # profit_margin OKRs synthesize Profit / Surplus Profit rows
    assert out.key?("Profit")
    assert_equal 300.0, out["Profit"][:value]
    assert_equal 200.0, out["Profit"][:target] # 1000 * (20/100)
  end

  test "Studio#okrs_for_period delegates to the service (legacy path parity)" do
    okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio } }).all
    legacy = @studio.okrs_for_period(@period, @datapoints, okrs)
    extracted = Studios::Snapshots::OkrRows.call(
      studio: @studio, period: @period, datapoints: @datapoints, okrs: okrs
    )
    assert_equal extracted, legacy
  end

  test "studio without matching okr periods gets raw datapoint row" do
    other = Studio.create!(name: "Other", mini_name: "oth")
    okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio } }).all
    out = Studios::Snapshots::OkrRows.call(
      studio: other, period: @period, datapoints: @datapoints, okrs: okrs
    )
    assert_equal({}, out)
  end
end
```

Note: check `okrs` / `okr_periods` schema columns before running (e.g. `operator` on `okrs`, `period_starts_at` on `okr_periods`) — adjust creation attributes to satisfy validations; the assertions are the contract.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/services/studios/snapshots/okr_rows_test.rb`
Expected: FAIL with `NameError: uninitialized constant Studios::Snapshots::OkrRows`

- [ ] **Step 3: Create the service by MOVING the bodies of `Studio#okrs_for_period` (studio.rb:188-244) and `Studio#hint_for_okr` (studio.rb:246-267)**

```ruby
# app/services/studios/snapshots/okr_rows.rb
module Studios
  module Snapshots
    # OKR health rows for one (studio, period, datapoints) triple. Extracted
    # verbatim from Studio#okrs_for_period / #hint_for_okr so the legacy blob
    # path and the live GradationRows path share one implementation.
    class OkrRows
      def self.call(studio:, period:, datapoints:, okrs:)
        okrs.reduce({}) do |acc, okr|
          # Find all OKR periods that are associated with this studio
          okrps_for_studio = okr.okr_periods
            .select{|okrp| okrp.okr_period_studios.map(&:studio).include?(studio)}
            .sort_by{|okrp| okrp.period_starts_at}
          next acc if okrps_for_studio.empty?

          # Find the OKR period that has the most overlap with the period
          period_range = period.starts_at..period.ends_at
          okrp_candidate = okrps_for_studio.reduce({ overlap_days: nil, okrp: nil }) do |agg, okrp|
            okrp_range = okrp.period_starts_at..okrp.period_ends_at
            overlap_days = (period_range.to_a & okrp_range.to_a).count
            next { overlap_days: overlap_days, okrp: okrp } if (agg[:overlap_days].nil? || overlap_days >= agg[:overlap_days])
            agg
          end

          data = datapoints[okr.datapoint.to_sym]
          okrp = okrp_candidate[:okrp]
          acc[okr.name] = data
          next acc if okrp.nil?

          acc[okr.name] =
            okrp.health_for_value(data[:value], period.total_days)
              .merge(data)
              .merge({ hint: hint_for_okr(okr, datapoints) })

          if okrp.okr.datapoint == "profit_margin"
            target_usd =
              datapoints[:income][:value] * (acc[okrp.okr.name][:target]/100)
            surplus_usd =
              datapoints[:net_operating_income][:value]
            acc["Profit"] = {
              health: acc[okrp.okr.name][:health],
              hint: acc[okrp.okr.name][:hint],
              surplus: surplus_usd,
              value: surplus_usd,
              target: target_usd,
              unit: :usd
            }

            target_usd =
              datapoints[:income][:value] * (acc[okrp.okr.name][:target]/100)
            surplus_usd =
              datapoints[:income][:value] * (acc[okrp.okr.name][:surplus]/100)
            acc["Surplus Profit"] = {
              health: acc[okrp.okr.name][:health],
              hint: acc[okrp.okr.name][:hint],
              surplus: surplus_usd,
              value: surplus_usd,
              target: target_usd,
              unit: :usd
            }
          end
          acc
        end
      end

      def self.hint_for_okr(okr, datapoints)
        case okr.datapoint
        when "time_to_merge_pr"
          "#{datapoints[:prs_merged][:value].try(:round, 0)} PRs merged, taking #{datapoints[:time_to_merge_pr][:value].try(:round, 2)} days (average)"
        when "story_points_per_billable_week"
          "#{datapoints[:story_points][:value].try(:round, 0)} story points closed, #{((datapoints[:billable_hours][:value] || 0) / 40.0).try(:round, 2)} weeks sold"
        when "cost_per_story_point"
          "#{ActionController::Base.helpers.number_to_currency(datapoints[:cogs][:value])} spent, #{datapoints[:story_points][:value].try(:round, 0)} story points closed"
        when "sellable_hours_sold"
          "#{datapoints[:billable_hours][:value].try(:round, 0)} hrs sold of #{datapoints[:sellable_hours][:value].try(:round, 0)} sellable hrs"
        when "free_hours"
          "#{datapoints[:free_hours_count][:value].try(:round, 0)} free hrs of #{datapoints[:sellable_hours][:value].try(:round, 0)} sellable hrs"
        when "profit_margin"
          "#{ActionController::Base.helpers.number_to_currency(datapoints[:income][:value] - datapoints[:net_operating_income][:value])} spent, #{ActionController::Base.helpers.number_to_currency(datapoints[:income][:value])} earnt"
        when "income_growth"
          "#{ActionController::Base.helpers.number_to_currency(datapoints[:income][:value])} income recieved"
        when "lead_growth"
          "#{datapoints[:lead_count][:value]} leads recieved"
        else
          ""
        end
      end
    end
  end
end
```

In `app/models/studio.rb`, replace the bodies of the two methods (KEEP the methods — the legacy blob path calls them):

```ruby
  def okrs_for_period(period, datapoints, okrs)
    Studios::Snapshots::OkrRows.call(studio: self, period: period, datapoints: datapoints, okrs: okrs)
  end

  def hint_for_okr(okr, datapoints)
    Studios::Snapshots::OkrRows.hint_for_okr(okr, datapoints)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/services/studios/snapshots/okr_rows_test.rb`
Expected: PASS (3 runs)

- [ ] **Step 5: Commit**

```bash
git add app/services/studios/snapshots/okr_rows.rb app/models/studio.rb test/services/studios/snapshots/okr_rows_test.rb
git commit -m "Extract OKR row assembly into Studios::Snapshots::OkrRows"
```

---

### Task 8: `Studios::Snapshots::GradationRows` — the live snapshot service

**Files:**
- Create: `app/services/studios/snapshots/gradation_rows.rb`
- Test: `test/services/studios/snapshots/gradation_rows_test.rb`

**Interfaces:**
- Consumes: `PnlByMonth` (Task 5), `UtilizationByMonth` (Task 6), `OkrRows` (Task 7), `NotionLead.for_studio` (Task 4), `Studio#project_trackers_with_recorded_time_by_periods` (existing), `Stacks::Utils.weighted_average` (existing).
- Produces: `Studios::Snapshots::GradationRows.call(studio:, gradation:, periods: nil)` → array of hashes shape-identical to `studios.snapshot[gradation]` rows: `{ label:, period_starts_at:, period_ends_at:, cash: {datapoints:, okrs:}, accrual: {datapoints:, okrs:}, utilization: {email_or_name => five-field-hash} }`. `periods:` kwarg overrides `Stacks::Period.for_gradation(gradation)` (used by tests and single-period consumers).

The datapoint math replicates `Studio#key_datapoints_for_period` (studio.rb:421-609) exactly — including `.to_f` division NaN/Infinity artifacts. Do not "fix" anything; the oracle is the referee.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/studios/snapshots/gradation_rows_test.rb
require "test_helper"

class Studios::Snapshots::GradationRowsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    Studio.instance_variable_set(:@all_studios, nil)
    @account = qbo_accounts(:one)
    @studio = Studio.create!(name: "XXIX", mini_name: "xxix", accounting_prefix: "XXIX")
    @fp = ForecastPerson.create!(forecast_id: 9201, email: "a@x.com", first_name: "Aye", last_name: "Person")
    StudioForecastPerson.create!(studio: @studio, forecast_person: @fp)
    # Periods must postdate UTILIZATION_START_AT (2021-06-01)
    @jan = Stacks::Period.new("January, 2024", Date.new(2024, 1, 1), Date.new(2024, 1, 31), :month)
    @feb = Stacks::Period.new("February, 2024", Date.new(2024, 2, 1), Date.new(2024, 2, 29), :month)
  end

  teardown do
    Studio.instance_variable_set(:@all_studios, nil)
  end

  def seed_pnl!(month, income:, cos:, tools:)
    report = QboProfitAndLossReport.find_or_create_by!(
      qbo_account: @account, starts_at: month, ends_at: month.end_of_month
    ) { |r| r.data = {} }
    %w[cash accrual].each do |method|
      [["Revenue - XXIX", income], ["Total COS - XXIX", cos], ["Tools and Subscriptions - XXIX", tools]]
        .each_with_index do |(label, amount), position|
          QboProfitAndLossLineItem.create!(
            qbo_account: @account, qbo_profit_and_loss_report: report,
            starts_at: month, accounting_method: method,
            position: position, label: label, amount: amount
          )
        end
    end
  end

  def seed_utilization!(month, sellable:, billable_map:, time_off: 0, internal: 0, unsold: 0)
    ForecastPersonUtilizationReport.create!(
      forecast_person_id: @fp.id,
      starts_at: month, ends_at: month.end_of_month,
      period_gradation: :month,
      expected_hours_sold: sellable, expected_hours_unsold: unsold,
      actual_hours_sold: billable_map.values.sum,
      actual_hours_internal: internal, actual_hours_time_off: time_off,
      actual_hours_sold_by_rate: billable_map,
      utilization_rate: 0
    )
  end

  test "produces blob-shaped rows with correct P&L, growth, utilization and lead datapoints" do
    seed_pnl!(Date.new(2024, 1, 1), income: 100, cos: 40, tools: 10)
    seed_pnl!(Date.new(2024, 2, 1), income: 150, cos: 40, tools: 10)
    seed_utilization!(Date.new(2024, 1, 1), sellable: 100, billable_map: { "150.0" => 40.0, "0.0" => 10.0 }, time_off: 8, internal: 5, unsold: 20)
    seed_utilization!(Date.new(2024, 2, 1), sellable: 110, billable_map: { "150.0" => 50.0 })

    page = NotionPage.create!(
      notion_id: SecureRandom.uuid,
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]),
      data: { "properties" => {} }
    )
    lead = NotionLead.create!(notion_page_id: page.id, received_at: Date.new(2024, 2, 5))
    NotionLeadStudio.create!(notion_lead: lead, studio: @studio)

    rows = Studios::Snapshots::GradationRows.call(
      studio: @studio, gradation: :month, periods: [@jan, @feb]
    )

    assert_equal 2, rows.length
    jan, feb = rows

    assert_equal "January, 2024", jan[:label]
    assert_equal "01/01/2024", jan[:period_starts_at]
    assert_equal "01/31/2024", jan[:period_ends_at]

    # P&L (prefixed studio: cogs = cos - tools, noi = income - cos)
    d = jan[:cash][:datapoints]
    assert_equal 100.0, d[:income][:value]
    assert_equal 30.0, d[:cost_of_goods_sold][:value]
    assert_equal 10.0, d[:expenses][:value]
    assert_equal 60.0, d[:net_operating_income][:value]
    assert_equal 60.0, d[:profit_margin][:value]
    assert_nil d[:income][:growth] # first period has no prev

    # Feb growth: ((150/100)*100)-100 = 50
    assert_in_delta 50.0, feb[:cash][:datapoints][:income][:growth], 0.001
    assert_in_delta 50.0, feb[:cash][:datapoints][:income_growth][:value], 0.001

    # Utilization (Jan): billable total 50, sellable 100
    assert_equal 100, d[:sellable_hours][:value]
    assert_equal 50.0, d[:billable_hours][:value]
    assert_in_delta 50.0, d[:sellable_hours_sold][:value].to_f, 0.001
    # free hours: rate "0.0" bucket = 10 hrs → 10% of sellable
    assert_in_delta 10.0, d[:free_hours][:value].to_f, 0.001
    assert_equal 10.0, d[:free_hours_count][:value]
    assert_equal 8, d[:time_off][:value]
    assert_equal 5, d[:non_billable_hours][:value]
    assert_equal 20, d[:non_sellable_hours][:value]
    # weighted avg rate: (150*40 + 0*10) / 50 = 120
    assert_in_delta 120.0, d[:average_hourly_rate][:value].to_f, 0.001
    # cost per hour sold: (income - noi) / billable = 40/50
    assert_in_delta 0.8, d[:actual_cost_per_hour_sold][:value].to_f, 0.001

    # Leads: 1 received in Feb, 0 in Jan
    assert_equal 0, d[:lead_count][:value]
    assert_equal 1, feb[:cash][:datapoints][:lead_count][:value]

    # Per-person utilization breakdown keyed by email
    assert_equal ["a@x.com"], jan[:utilization].keys
    assert_equal 8, jan[:utilization]["a@x.com"][:time_off]

    # okrs key exists on both methods (empty hash without OKR rows)
    assert_equal({}, jan[:cash][:okrs])
    assert jan[:accrual].key?(:datapoints)
  end

  test "periods predating utilization data get nil utilization datapoints" do
    old_period = Stacks::Period.new("January, 2021", Date.new(2021, 1, 1), Date.new(2021, 1, 31), :month)
    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [old_period])
    d = rows.first[:cash][:datapoints]
    assert_nil d[:sellable_hours][:value]
    assert_nil d[:billable_hours][:value]
    assert_nil d[:average_hourly_rate][:value]
    assert_equal({}, rows.first[:utilization])
  end

  test "quarter periods fold multiple months" do
    seed_pnl!(Date.new(2024, 1, 1), income: 100, cos: 40, tools: 10)
    seed_pnl!(Date.new(2024, 2, 1), income: 150, cos: 40, tools: 10)
    seed_utilization!(Date.new(2024, 1, 1), sellable: 100, billable_map: { "150.0" => 40.0 })
    seed_utilization!(Date.new(2024, 2, 1), sellable: 110, billable_map: { "150.0" => 50.0, "100.0" => 10.0 })

    q1 = Stacks::Period.new("Q1, 2024", Date.new(2024, 1, 1), Date.new(2024, 3, 31), :quarter)
    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :quarter, periods: [q1])
    d = rows.first[:cash][:datapoints]

    assert_equal 250.0, d[:income][:value]        # 100 + 150
    assert_equal 170.0, d[:net_operating_income][:value] # 60 + 110
    assert_equal 210, d[:sellable_hours][:value]  # 100 + 110
    assert_equal 100.0, d[:billable_hours][:value] # 40 + 50 + 10
    # rate map merged across months: 150.0 → 90, 100.0 → 10 → weighted avg = (150*90 + 100*10)/100 = 145
    assert_in_delta 145.0, d[:average_hourly_rate][:value].to_f, 0.001
  end

  test "empty project set yields NaN successful_projects (legacy parity)" do
    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [@jan])
    d = rows.first[:cash][:datapoints]
    assert_equal 0, d[:total_projects][:value]
    assert d[:successful_projects][:value].nan?
    assert d[:successful_proposals][:value].nan?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/services/studios/snapshots/gradation_rows_test.rb`
Expected: FAIL with `NameError: uninitialized constant Studios::Snapshots::GradationRows`

- [ ] **Step 3: Write the service**

```ruby
# app/services/studios/snapshots/gradation_rows.rb
module Studios
  module Snapshots
    # Live replacement for `studios.snapshot[gradation]`: computes rows
    # shape-identical to the blob from span-wide grouped queries folded into
    # periods in Ruby. Every period Stacks::Period builds is month-aligned,
    # and each datapoint is additive over months or a ratio of additive
    # sums, so the monthly grain reproduces every gradation exactly.
    #
    # HARD RULES:
    # - Never trigger a network call. Reads only locally-synced tables.
    # - Replicate Studio#key_datapoints_for_period bug-for-bug (NaN/Infinity
    #   from .to_f division, midnight-cast work_completed_at bounds, ...).
    #   The DiffAgainstStored oracle is the referee — "more correct" is a
    #   diff, and a diff is a bug here.
    class GradationRows
      def self.call(studio:, gradation:, periods: nil)
        new(studio, gradation, periods).call
      end

      def initialize(studio, gradation, periods)
        @studio = studio
        @gradation = gradation
        @periods = periods || Stacks::Period.for_gradation(gradation)
      end

      def call
        return [] if @periods.empty?
        preload_span_data!
        warn_on_pnl_gaps!
        @periods.each_with_index.map do |period, i|
          prev_period = i.zero? ? nil : @periods[i - 1]
          row_for(period, prev_period)
        end
      end

      private

      def preload_span_data!
        @from = @periods.map(&:starts_at).min
        @through = @periods.map(&:ends_at).max
        @pnl_by_month = PnlByMonth.call(studio: @studio, from: @from, through: @through)
        @utilization_by_month = UtilizationByMonth.call(studio: @studio, from: @from, through: @through)
        @lead_rows = NotionLead.for_studio(@studio).to_a
        @projects_by_period = @studio.project_trackers_with_recorded_time_by_periods(@periods)
        @completed_projects = ProjectTracker
          .includes(project_capsule: { project_satisfaction_survey: :project_satisfaction_survey_responses })
          .where(work_completed_at: @from..@through)
          .to_a
        @closed_surveys = @studio.surveys.where.not(closed_at: nil).order(closed_at: :desc).to_a
        @all_okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio } }).all.to_a
      end

      def warn_on_pnl_gaps!
        expected = months_in_range(@from, @through)
        present = (@pnl_by_month["cash"].keys | @pnl_by_month["accrual"].keys)
        missing = expected - present
        return if missing.empty?
        Rails.logger.warn(
          "[Studios::Snapshots::GradationRows] studio=#{@studio.mini_name} " \
          "gradation=#{@gradation} missing P&L months: #{missing.map(&:iso8601).join(', ')}"
        )
      end

      def months_in_range(from, through)
        months = []
        m = from.beginning_of_month
        while m <= through
          months << m
          m = m.advance(months: 1)
        end
        months
      end

      def row_for(period, prev_period)
        row = {
          label: period.label,
          period_starts_at: period.starts_at.strftime("%m/%d/%Y"),
          period_ends_at: period.ends_at.strftime("%m/%d/%Y"),
          cash: {},
          accrual: {},
          utilization: utilization_breakdown(period),
        }
        %w[cash accrual].each do |method|
          datapoints = datapoints_for(period, prev_period, method)
          row[method.to_sym][:datapoints] = datapoints
          row[method.to_sym][:okrs] = OkrRows.call(
            studio: @studio, period: period, datapoints: datapoints, okrs: @all_okrs
          )
        end
        row
      end

      # ------------------------------------------------------- utilization

      # Per-person period totals folded from monthly rows. Mirrors legacy
      # utilization_for_period: {} for periods predating utilization data.
      def person_utilization_for(period)
        @person_utilization ||= {}
        @person_utilization[period] ||= begin
          if period.has_utilization_data?
            months_in_range(period.starts_at, period.ends_at).reduce({}) do |acc, month|
              (@utilization_by_month[month] || {}).each do |fp, data|
                acc[fp] = acc[fp].nil? ? data : merge_utilization(acc[fp], data)
              end
              acc
            end
          else
            {}
          end
        end
      end

      # Mirrors the merge inside legacy merged_utilization_data.
      def merge_utilization(a, b)
        a.merge(b) do |_k, old, new|
          old.is_a?(Hash) ? old.merge(new) { |_kk, o, n| o + n } : old + new
        end
      end

      def merged_utilization_for(period)
        person_utilization_for(period).values.reduce(nil) do |acc, data|
          acc.nil? ? data : merge_utilization(acc, data)
        end
      end

      def utilization_breakdown(period)
        person_utilization_for(period).transform_keys do |fp|
          fp.email.blank? ? "#{fp.first_name} #{fp.last_name}" : fp.email
        end
      end

      # -------------------------------------------------------------- P&L

      def pnl_totals_for(period, accounting_method)
        totals = { income: 0.0, cost_of_goods_sold: 0.0, expenses: 0.0, net_operating_income: 0.0 }
        months_in_range(period.starts_at, period.ends_at).each do |month|
          m = @pnl_by_month.dig(accounting_method, month)
          next if m.nil?
          totals.each_key { |k| totals[k] += m[k] }
        end
        totals
      end

      # ------------------------------------------------------- datapoints

      # Replicates Studio#key_datapoints_for_period exactly.
      def datapoints_for(period, prev_period, accounting_method)
        profit_and_loss = pnl_totals_for(period, accounting_method)
        prev_profit_and_loss = pnl_totals_for(prev_period, accounting_method) if prev_period.present?
        v = merged_utilization_for(period)
        cost_of_doing_business = profit_and_loss[:income] - profit_and_loss[:net_operating_income]

        leads_recieved = leads_received_in(period)
        prev_leads_recieved = prev_period.present? ? leads_received_in(prev_period) : []
        all_proposals = proposals_settled_in(period)
        all_projects = @projects_by_period.fetch(period, [])

        completed_projects_in_period = completed_projects_in(period).select do |pt|
          pt.capsule_complete? &&
            pt.project_capsule.project_satisfaction_survey.present? &&
            pt.project_capsule.project_satisfaction_survey.closed?
        end
        project_satisfaction_score = nil
        if completed_projects_in_period.any?
          scores = completed_projects_in_period.map { |pt| pt.project_capsule.project_satisfaction_survey.results[:overall] }
          project_satisfaction_score = (scores.reduce(&:+) / scores.count).round(1)
        end

        latest_survey_closed = @closed_surveys.find do |s|
          s.closed_at.beginning_of_year <= period.starts_at
        end

        data = {
          income: {
            value: profit_and_loss[:income],
            unit: :usd,
            growth: prev_profit_and_loss ? ((profit_and_loss[:income].to_f / prev_profit_and_loss[:income].to_f) * 100) - 100 : nil
          },
          income_growth: {
            value: prev_profit_and_loss ? ((profit_and_loss[:income].to_f / prev_profit_and_loss[:income].to_f) * 100) - 100 : nil,
            unit: :percentage
          },
          cost_of_goods_sold: {
            value: profit_and_loss[:cost_of_goods_sold],
            unit: :usd
          },
          expenses: {
            value: profit_and_loss[:expenses],
            unit: :usd
          },
          net_operating_income: {
            value: profit_and_loss[:net_operating_income],
            unit: :usd
          },
          profit_margin: {
            value: profit_and_loss[:income] ? (profit_and_loss[:net_operating_income] / profit_and_loss[:income]) * 100 : 0,
            unit: :percentage
          },
          lead_count: {
            value: leads_recieved.length,
            unit: :count,
            growth: prev_period ? ((leads_recieved.length.to_f / prev_leads_recieved.length.to_f) * 100) - 100 : nil
          },
          lead_growth: {
            value: prev_period ? ((leads_recieved.length.to_f / prev_leads_recieved.length.to_f) * 100) - 100 : nil,
            unit: :percentage
          },
          total_projects: {
            value: all_projects.count,
            unit: :count,
            extras: {
              project_tracker_ids: all_projects.map(&:id)
            }
          },
          successful_projects: {
            value: ((all_projects.map(&:considered_successful?).count { |x| !!x } / all_projects.count.to_f) * 100),
            unit: :percentage,
            extras: {
              project_tracker_ids: all_projects.map(&:id)
            }
          },
          successful_proposals: {
            value: ((all_proposals.map { |l| l.won_at.present? }.count { |x| !!x } / all_proposals.count.to_f) * 100),
            unit: :percentage,
            extras: {
              notion_page_ids: all_proposals.map(&:notion_page_id)
            }
          },
          project_satisfaction: {
            value: project_satisfaction_score,
            unit: :count,
            extras: {
              project_tracker_ids: completed_projects_in_period.map(&:id)
            }
          },
          workplace_satisfaction: {
            value: latest_survey_closed.try(:results).try(:dig, :overall),
            unit: :count
          }
        }

        data[:free_hours] = { unit: :percentage, value: nil }
        data[:free_hours_count] = { unit: :count, value: nil }
        unless v.nil?
          free_hours_given = v[:billable]["0.0"] || 0
          data[:free_hours][:value] = v[:sellable] == 0 ? 0 : ((free_hours_given / v[:sellable]) * 100)
          data[:free_hours_count][:value] = free_hours_given
        end

        data[:sellable_hours] = { unit: :hours, value: nil }
        unless v.nil?
          data[:sellable_hours][:value] = v[:sellable]
        end

        data[:non_sellable_hours] = { unit: :hours, value: nil }
        unless v.nil?
          data[:non_sellable_hours][:value] = v[:non_sellable]
        end

        data[:billable_hours] = { unit: :hours, value: nil }
        unless v.nil?
          total_billable = v[:billable].values.reduce(&:+) || 0
          data[:billable_hours][:value] = total_billable
        end

        data[:non_billable_hours] = { unit: :hours, value: nil }
        unless v.nil?
          data[:non_billable_hours][:value] = v[:non_billable]
        end

        data[:time_off] = { unit: :hours, value: nil }
        unless v.nil?
          data[:time_off][:value] = v[:time_off]
        end

        data[:sellable_hours_sold] = { unit: :percentage, value: nil }
        unless v.nil?
          total_billable = v[:billable].values.reduce(&:+) || 0
          begin
            data[:sellable_hours_sold][:value] = (total_billable / v[:sellable]) * 100
          rescue ZeroDivisionError
            data[:sellable_hours_sold][:value] = 0
          end
        end

        data[:sellable_hours_ratio] = { unit: :percentage, value: nil }
        unless v.nil?
          begin
            data[:sellable_hours_ratio][:value] =
              (v[:sellable] / (v[:sellable] + v[:non_sellable])) * 100
          rescue ZeroDivisionError
            data[:sellable_hours_ratio][:value] = 0
          end
        end

        data[:average_hourly_rate] = { unit: :usd, value: nil }
        unless v.nil?
          data[:average_hourly_rate][:value] =
            Stacks::Utils.weighted_average(v[:billable].map { |k, hours| [k.to_f, hours] })
        end

        data[:actual_cost_per_hour_sold] = { unit: :usd, value: nil }
        unless v.nil?
          total_billable = v[:billable].values.reduce(&:+) || 0
          data[:actual_cost_per_hour_sold][:value] = total_billable > 0 ? (cost_of_doing_business / total_billable) : 0
        end

        data
      end

      # ------------------------------------------------------------ leads

      def leads_received_in(period)
        @lead_rows.select { |l| l.received_at && period.include?(l.received_at) }
      end

      def proposals_settled_in(period)
        @lead_rows.select { |l| l.settled_at && l.proposal_sent_at && period.include?(l.settled_at) }
      end

      # --------------------------------------------------------- projects

      # Legacy queried `work_completed_at: period.starts_at..period.ends_at`
      # — a Date range against a datetime column casts both bounds to
      # midnight, so completions later in the day on ends_at fall out.
      # Preserve that quirk.
      def completed_projects_in(period)
        start_t = period.starts_at.in_time_zone
        end_t = period.ends_at.in_time_zone
        @completed_projects.select do |pt|
          pt.work_completed_at >= start_t && pt.work_completed_at <= end_t
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/services/studios/snapshots/gradation_rows_test.rb`
Expected: PASS (4 runs). Likely friction points: `ProjectTracker` includes chain (`project_capsule` association names) — verify against `app/models/project_tracker.rb` if it errors; `Studio#surveys` requires the `survey_studios` join (empty is fine).

- [ ] **Step 5: Commit**

```bash
git add app/services/studios/snapshots/gradation_rows.rb test/services/studios/snapshots/gradation_rows_test.rb
git commit -m "Add GradationRows: live SQL-backed replacement for studio snapshot rows"
```

---

### Task 9: `Studios::Snapshots::DiffAgainstStored` oracle + rake tasks

**Files:**
- Create: `app/services/studios/snapshots/diff_against_stored.rb`
- Modify: `lib/tasks/studio_snapshots.rake` (add `studio_snapshot_oracle` + `pnl_additivity_check`)
- Test: `test/services/studios/snapshots/diff_against_stored_test.rb`

**Interfaces:**
- Consumes: `GradationRows` (Task 8), `studio.snapshot` blob (legacy).
- Produces: `Studios::Snapshots::DiffAgainstStored.call(studio:, gradations: GRADATIONS)` → `Result` struct with `checked` (Integer) and `mismatches` (Array of Strings). Rake tasks `stacks:studio_snapshot_oracle`, `stacks:pnl_additivity_check`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/studios/snapshots/diff_against_stored_test.rb
require "test_helper"

class Studios::Snapshots::DiffAgainstStoredTest < ActiveSupport::TestCase
  setup do
    Studio.instance_variable_set(:@all_studios, nil)
    @studio = Studio.create!(name: "XXIX", mini_name: "xxix", accounting_prefix: "XXIX")
  end

  def stored_row(label:, income:)
    {
      "label" => label,
      "period_starts_at" => "01/01/2024",
      "period_ends_at" => "01/31/2024",
      "cash" => { "datapoints" => { "income" => { "value" => income, "unit" => "usd" } }, "okrs" => {} },
      "accrual" => { "datapoints" => {} , "okrs" => {} },
      "utilization" => {}
    }
  end

  def live_row(label:, income:)
    {
      label: label,
      period_starts_at: "01/01/2024",
      period_ends_at: "01/31/2024",
      cash: { datapoints: { income: { value: income, unit: :usd } }, okrs: {} },
      accrual: { datapoints: {}, okrs: {} },
      utilization: {}
    }
  end

  test "matching rows produce zero mismatches" do
    @studio.update!(snapshot: { "month" => [stored_row(label: "January, 2024", income: 100.0)] })
    Studios::Snapshots::GradationRows.stubs(:call).returns([live_row(label: "January, 2024", income: 100.004)])

    result = Studios::Snapshots::DiffAgainstStored.call(studio: @studio, gradations: ["month"])
    assert_equal 1, result.checked
    assert_equal [], result.mismatches
  end

  test "value drift beyond tolerance is reported" do
    @studio.update!(snapshot: { "month" => [stored_row(label: "January, 2024", income: 100.0)] })
    Studios::Snapshots::GradationRows.stubs(:call).returns([live_row(label: "January, 2024", income: 150.0)])

    result = Studios::Snapshots::DiffAgainstStored.call(studio: @studio, gradations: ["month"])
    assert_equal 1, result.mismatches.length
    assert_match(/month\/January, 2024\/cash\/income/, result.mismatches.first)
  end

  test "stored nil matches live NaN and Infinity (JSON encoding parity)" do
    @studio.update!(snapshot: { "month" => [stored_row(label: "January, 2024", income: nil)] })
    Studios::Snapshots::GradationRows.stubs(:call).returns([live_row(label: "January, 2024", income: Float::NAN)])

    result = Studios::Snapshots::DiffAgainstStored.call(studio: @studio, gradations: ["month"])
    assert_equal [], result.mismatches
  end

  test "missing live row is a mismatch" do
    @studio.update!(snapshot: { "month" => [stored_row(label: "January, 2024", income: 1.0)] })
    Studios::Snapshots::GradationRows.stubs(:call).returns([])

    result = Studios::Snapshots::DiffAgainstStored.call(studio: @studio, gradations: ["month"])
    assert_match(/no live row/, result.mismatches.first)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/services/studios/snapshots/diff_against_stored_test.rb`
Expected: FAIL with `NameError: uninitialized constant Studios::Snapshots::DiffAgainstStored`

- [ ] **Step 3: Write the service**

```ruby
# app/services/studios/snapshots/diff_against_stored.rb
module Studios
  module Snapshots
    # Oracle for the live-SQL migration: diffs GradationRows output against
    # the stored legacy `studios.snapshot` blob, datapoint by datapoint.
    # Run right after a nightly generate_snapshot! so both sides read the
    # same synced data; diffs found at other times may just be staleness.
    class DiffAgainstStored
      GRADATIONS = %w[
        year month quarter
        trailing_3_months trailing_4_months trailing_6_months trailing_12_months
      ].freeze
      TOLERANCE = 0.01

      Result = Struct.new(:checked, :mismatches, keyword_init: true)

      def self.call(studio:, gradations: GRADATIONS)
        checked = 0
        mismatches = []

        gradations.each do |gradation|
          stored_rows = studio.snapshot[gradation]
          next unless stored_rows.is_a?(Array)

          live_rows = GradationRows.call(studio: studio, gradation: gradation.to_sym)
          live_by_label = live_rows.index_by { |r| r[:label] }

          stored_rows.each do |stored|
            label = stored["label"]
            live = live_by_label[label]
            if live.nil?
              mismatches << "#{gradation}/#{label}: no live row"
              next
            end

            %w[cash accrual].each do |method|
              (stored.dig(method, "datapoints") || {}).each do |key, stored_dp|
                checked += 1
                live_dp = live[method.to_sym][:datapoints][key.to_sym]
                stored_value = stored_dp.is_a?(Hash) ? stored_dp["value"] : nil
                live_value = live_dp.is_a?(Hash) ? live_dp[:value] : nil
                next if values_match?(stored_value, live_value)
                mismatches << "#{gradation}/#{label}/#{method}/#{key}: " \
                  "stored=#{stored_value.inspect} live=#{live_value.inspect}"
              end
            end
          end
        end

        Result.new(checked: checked, mismatches: mismatches)
      end

      # The blob went through ActiveSupport JSON: NaN/Infinity became nil,
      # BigDecimal became String. Compare accordingly.
      def self.values_match?(stored, live)
        live = nil if live.is_a?(Float) && !live.finite?
        return true if stored.nil? && live.nil?
        return false if stored.nil? || live.nil?
        (stored.to_f - live.to_f).abs <= TOLERANCE
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/services/studios/snapshots/diff_against_stored_test.rb`
Expected: PASS (4 runs)

- [ ] **Step 5: Add the oracle + additivity rake tasks**

Append inside `namespace :stacks` in `lib/tasks/studio_snapshots.rake`:

```ruby
  desc "Diff live GradationRows output against every studio's stored snapshot blob"
  task studio_snapshot_oracle: :environment do
    Studio.all.each do |studio|
      result = Studios::Snapshots::DiffAgainstStored.call(studio: studio)
      status = result.mismatches.empty? ? "CLEAN" : "#{result.mismatches.length} MISMATCHES"
      puts "~~~> #{studio.mini_name}: checked=#{result.checked} #{status}"
      result.mismatches.first(100).each { |m| puts "     #{m}" }
    end
  end

  desc "Verify monthly line items reproduce stored range reports (additivity check)"
  task pnl_additivity_check: :environment do
    account = Enterprise.sanctuary.qbo_account
    mismatches = 0
    QboProfitAndLossReport.where(qbo_account: account).find_each do |report|
      # Skip monthly rows — they ARE the line-item source.
      next if report.starts_at == report.starts_at.beginning_of_month &&
              report.ends_at == report.starts_at.end_of_month

      %w[cash accrual].each do |method|
        row = (report.data.dig(method, "rows") || []).find { |r| r[0] == "Total Income" }
        next if row.nil?
        stored = row[1].to_f
        summed = QboProfitAndLossLineItem.where(
          qbo_account: account,
          accounting_method: method,
          label: "Total Income",
          starts_at: report.starts_at..report.ends_at
        ).sum(:amount).to_f
        next if (stored - summed).abs <= 0.01
        mismatches += 1
        puts "MISMATCH #{report.starts_at}..#{report.ends_at} #{method}: stored=#{stored} summed=#{summed}"
      end
    end
    puts mismatches.zero? ? "~~~> additivity CLEAN" : "~~~> #{mismatches} additivity mismatches"
  end
```

- [ ] **Step 6: Verify tasks load**

Run: `bundle exec rake -T | grep -E "oracle|additivity"`
Expected: both tasks listed.

- [ ] **Step 7: Commit**

```bash
git add app/services/studios/snapshots/diff_against_stored.rb lib/tasks/studio_snapshots.rake test/services/studios/snapshots/diff_against_stored_test.rb
git commit -m "Add snapshot oracle and P&L additivity rake checks"
```

---

### Task 10: Full suite, review, PR

- [ ] **Step 1: Run the full test suite**

Run: `bundle exec rails test`
Expected: 0 failures, 0 errors. Fix any fallout (most likely: tests sensitive to `Studio.all_studios`/`Enterprise.sanctuary` memoization, or the `find_or_fetch_for_range` hook changing a stubbed return path).

- [ ] **Step 2: Code review pass** (superpowers:requesting-code-review)

- [ ] **Step 3: Push branch + open PR**

PR description must state: this is Stages 1+2 of the spec; rollout steps for the operator are (a) deploy, (b) run `rake stacks:backfill_monthly_pnl_line_items`, (c) after the next nightly snapshot run, run `rake stacks:pnl_additivity_check` and `rake stacks:studio_snapshot_oracle`; Stage 3 consumer swap PR follows once the oracle is clean.
