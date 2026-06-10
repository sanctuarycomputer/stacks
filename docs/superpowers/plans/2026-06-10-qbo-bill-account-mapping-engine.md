# QBO Bill Account Mapping Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard-coded QBO account routing for Stacks-managed bills with a database-backed mapping engine resolved project tracker → contributor → entity default, plus a local chart-of-accounts mirror and admin UI.

**Architecture:** A `QboChartAccount` mirror table (synced from QBO like `QboVendor`), a `QboBillAccountMapping` rules table (entity-scoped, with optional contributor/project-tracker subject), and a single `Qbo::BillAccountResolver` that replaces every `find_qbo_account!` override in `SyncsAsQboBill` hosts. A seeding service reproduces today's behavior; unmapped line items raise `Qbo::UnmappedLineItemError` (no silent fallback).

**Tech Stack:** Rails 6.1, Ruby 3.1, Postgres, minitest + mocha + fixtures, ActiveAdmin/formtastic, quickbooks-ruby gem.

**Spec:** `docs/superpowers/specs/2026-06-10-qbo-bill-account-mapping-engine-design.md`

**Two implementation-level deviations from the spec (Task 12 amends the spec to match):**
1. **Explicit FK columns instead of polymorphic subject.** `qbo_bill_account_mappings` gets nullable `project_tracker_id` and `contributor_id` columns (at most one set) rather than `subject_type`/`subject_id`. Reasons: real foreign-key integrity, simpler ActiveAdmin forms (no dependent dropdowns), and Postgres unique indexes treat NULLs as distinct, so the polymorphic shape would need partial indexes anyway.
2. **Seeding is a service + rake task, not a Rails migration.** Seeding requires live QBO API calls (chart-of-accounts sync); API calls don't belong in migrations. Run `rake stacks:seed_qbo_bill_account_mappings` once after deploy.

**Conventions used throughout:**
- Run tests with `bin/rails test <path>`.
- Test files reset `Thread.current[:sanctuary_enterprise] = nil` in setup (existing convention, see `test/models/qbo_account_test.rb`).
- The "realm connection" model is `QboAccount` (OAuth credentials per enterprise). The new chart-of-accounts mirror is `QboChartAccount`. Do not confuse them.
- `ForecastProject` and `ForecastPerson` use `self.primary_key = "forecast_id"`, so `project_tracker.forecast_project_ids` returns Forecast IDs (which is what blueprint metadata stores).

---

### Task 1: `QboChartAccount` mirror table + model

**Files:**
- Create: `db/migrate/20260610000001_create_qbo_chart_accounts.rb`
- Create: `app/models/qbo_chart_account.rb`
- Test: `test/models/qbo_chart_account_test.rb`

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260610000001_create_qbo_chart_accounts.rb
class CreateQboChartAccounts < ActiveRecord::Migration[6.1]
  def change
    create_table :qbo_chart_accounts do |t|
      t.string :qbo_id, null: false
      t.bigint :qbo_account_id, null: false
      t.string :name, null: false
      t.string :acct_num
      t.string :classification
      t.string :account_type
      t.boolean :active, null: false, default: true
      t.jsonb :data
    end

    add_index :qbo_chart_accounts, [:qbo_account_id, :qbo_id],
      unique: true, name: "index_qbo_chart_accounts_on_qbo_account_and_qbo_id"
    add_index :qbo_chart_accounts, :qbo_account_id
    add_foreign_key :qbo_chart_accounts, :qbo_accounts
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: migrates cleanly; `db/schema.rb` gains the `qbo_chart_accounts` table.

- [ ] **Step 3: Write the failing model test**

```ruby
# test/models/qbo_chart_account_test.rb
require "test_helper"

class QboChartAccountTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @qa = qbo_accounts(:one)
  end

  test "display_label includes acct_num when present" do
    row = QboChartAccount.create!(
      qbo_account: @qa, qbo_id: "10", name: "Bonuses", acct_num: "5710", data: {},
    )
    assert_equal "Bonuses (5710)", row.display_label
  end

  test "display_label is just the name when acct_num is blank" do
    row = QboChartAccount.create!(qbo_account: @qa, qbo_id: "11", name: "Contractors - Client Services", data: {})
    assert_equal "Contractors - Client Services", row.display_label
  end

  test "current_balance reads from data jsonb, defaulting to 0" do
    row = QboChartAccount.create!(qbo_account: @qa, qbo_id: "12", name: "Checking", data: { "current_balance" => 1234.5 })
    assert_equal 1234.5, row.current_balance
    bare = QboChartAccount.create!(qbo_account: @qa, qbo_id: "13", name: "Bare", data: nil)
    assert_equal 0.0, bare.current_balance
  end

  test "(qbo_account_id, qbo_id) must be unique" do
    QboChartAccount.create!(qbo_account: @qa, qbo_id: "14", name: "A", data: {})
    assert_raises(ActiveRecord::RecordNotUnique) do
      QboChartAccount.insert_all!([{ qbo_account_id: @qa.id, qbo_id: "14", name: "B", active: true }])
    end
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bin/rails test test/models/qbo_chart_account_test.rb`
Expected: FAIL with `NameError: uninitialized constant QboChartAccount`

- [ ] **Step 5: Write the model**

```ruby
# app/models/qbo_chart_account.rb
# Local mirror of one QBO chart-of-accounts entry ("Account" in the QBO
# API — that name is taken locally by the realm-connection model, hence
# "chart account"). Synced by QboAccount#sync_all_chart_accounts!,
# following the same upsert pattern as QboVendor / QboBill. Rows that
# disappear from QBO are soft-deactivated (active: false), never deleted,
# so QboBillAccountMapping references can't dangle silently.
class QboChartAccount < ApplicationRecord
  belongs_to :qbo_account

  validates :qbo_id, presence: true
  validates :name, presence: true

  scope :active, -> { where(active: true) }

  def display_label
    acct_num.present? ? "#{name} (#{acct_num})" : name
  end

  def current_balance
    (data || {}).fetch("current_balance", 0).to_f
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/models/qbo_chart_account_test.rb`
Expected: PASS (4 tests)

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260610000001_create_qbo_chart_accounts.rb db/schema.rb app/models/qbo_chart_account.rb test/models/qbo_chart_account_test.rb
git commit -m "Add QboChartAccount mirror of the QBO chart of accounts"
```

---

### Task 2: `QboAccount#sync_all_chart_accounts!`

**Files:**
- Modify: `app/models/qbo_account.rb` (add method next to `sync_all_vendors!`, around line 214)
- Test: `test/models/qbo_account_test.rb` (append tests)

- [ ] **Step 1: Write the failing tests**

Append to `test/models/qbo_account_test.rb` (inside the existing `QboAccountTest` class, which already has `@qa = qbo_accounts(:one)` in setup):

```ruby
  # ---------------------------------------------------------------------------
  # sync_all_chart_accounts!
  # ---------------------------------------------------------------------------

  test "sync_all_chart_accounts! upserts mirror rows with metadata columns" do
    fake = OpenStruct.new(
      id: 99, name: "Bonuses", acct_num: "5710",
      classification: "Expense", account_type: "Expense",
      as_json: { "name" => "Bonuses", "current_balance" => 0 },
    )
    @qa.stubs(:fetch_all_accounts).returns([fake])

    @qa.sync_all_chart_accounts!

    row = QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "99")
    assert_not_nil row
    assert_equal "Bonuses", row.name
    assert_equal "5710", row.acct_num
    assert_equal "Expense", row.account_type
    assert row.active?
    assert_equal fake.as_json, row.data
  end

  test "sync_all_chart_accounts! is idempotent and updates changed names in place" do
    fake = OpenStruct.new(id: 99, name: "Bonuses", acct_num: "5710", classification: "Expense", account_type: "Expense", as_json: {})
    @qa.stubs(:fetch_all_accounts).returns([fake])
    @qa.sync_all_chart_accounts!

    renamed = OpenStruct.new(id: 99, name: "Bonuses & Awards", acct_num: "5710", classification: "Expense", account_type: "Expense", as_json: {})
    @qa.stubs(:fetch_all_accounts).returns([renamed])
    @qa.sync_all_chart_accounts!

    rows = QboChartAccount.where(qbo_account_id: @qa.id, qbo_id: "99")
    assert_equal 1, rows.count
    assert_equal "Bonuses & Awards", rows.first.name
  end

  test "sync_all_chart_accounts! deactivates rows that disappear from QBO and reactivates returning ones" do
    a = OpenStruct.new(id: "1", name: "Keep", acct_num: nil, classification: "Expense", account_type: "Expense", as_json: {})
    b = OpenStruct.new(id: "2", name: "Gone", acct_num: nil, classification: "Expense", account_type: "Expense", as_json: {})
    @qa.stubs(:fetch_all_accounts).returns([a, b])
    @qa.sync_all_chart_accounts!

    @qa.stubs(:fetch_all_accounts).returns([a])
    @qa.sync_all_chart_accounts!

    assert QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "1").active?
    refute QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "2").active?

    @qa.stubs(:fetch_all_accounts).returns([a, b])
    @qa.sync_all_chart_accounts!
    assert QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "2").active?, "returning account should reactivate"
  end

  test "sync_all_chart_accounts! is a no-op when QBO returns no accounts" do
    a = OpenStruct.new(id: "1", name: "Keep", acct_num: nil, classification: "Expense", account_type: "Expense", as_json: {})
    @qa.stubs(:fetch_all_accounts).returns([a])
    @qa.sync_all_chart_accounts!

    @qa.stubs(:fetch_all_accounts).returns([])
    @qa.sync_all_chart_accounts!

    assert QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "1").active?,
      "an empty fetch (likely an API hiccup) must not deactivate the whole mirror"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/qbo_account_test.rb`
Expected: 4 new FAILs with `NoMethodError: undefined method 'sync_all_chart_accounts!'`

- [ ] **Step 3: Implement the sync method**

In `app/models/qbo_account.rb`, directly below `sync_all_vendors!`:

```ruby
  # Mirrors this realm's QBO chart of accounts into QboChartAccount rows,
  # following the sync_all_vendors! upsert pattern. QBO's query API only
  # returns active accounts by default, so anything absent from the fetch
  # is soft-deactivated (and reactivated if it comes back). An empty fetch
  # is treated as an API hiccup and skipped entirely rather than
  # deactivating the whole mirror.
  def sync_all_chart_accounts!
    accounts = fetch_all_accounts
    data = accounts.map do |a|
      {
        qbo_id: a.id.to_s,
        qbo_account_id: id,
        name: a.name,
        acct_num: (a.respond_to?(:acct_num) ? a.acct_num : nil),
        classification: a.classification,
        account_type: a.account_type,
        active: true,
        data: a.as_json,
      }
    end
    return if data.empty?

    QboChartAccount.upsert_all(data, unique_by: :index_qbo_chart_accounts_on_qbo_account_and_qbo_id)
    QboChartAccount
      .where(qbo_account_id: id, active: true)
      .where.not(qbo_id: data.map { |d| d[:qbo_id] })
      .update_all(active: false)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/qbo_account_test.rb`
Expected: PASS (all, including pre-existing)

- [ ] **Step 5: Commit**

```bash
git add app/models/qbo_account.rb test/models/qbo_account_test.rb
git commit -m "Add QboAccount#sync_all_chart_accounts! mirror sync"
```

---

### Task 3: Wire chart-account sync into the daily task and enterprise admin

**Files:**
- Modify: `lib/tasks/stacks.rake` (the `QboAccount.find_each` block around line 50)
- Modify: `app/admin/enterprises.rb` (member actions ~line 19-27, show block ~line 183)

No automated tests for this task (rake tasks and ActiveAdmin pages are untested in this codebase); verification is by booting the console/server.

- [ ] **Step 1: Add chart sync to the daily task**

In `lib/tasks/stacks.rake`, replace:

```ruby
      QboAccount.find_each do |qa|
        qa.sync_all_vendors!
      rescue => e
        Rails.logger.error("[stacks:daily_enterprise_tasks] sync_all_vendors! failed for qbo_account=#{qa.id} (#{qa.enterprise&.name}): #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
```

with:

```ruby
      QboAccount.find_each do |qa|
        qa.sync_all_vendors!
        # Keep the chart-of-accounts mirror fresh so bill account mappings
        # (QboBillAccountMapping) validate against current data and admin
        # pickers don't need a live QBO call.
        qa.sync_all_chart_accounts!
      rescue => e
        Rails.logger.error("[stacks:daily_enterprise_tasks] QBO mirror sync failed for qbo_account=#{qa.id} (#{qa.enterprise&.name}): #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
```

- [ ] **Step 2: Add the on-demand refresh action and sync-on-regenerate in admin**

In `app/admin/enterprises.rb`, replace the existing action item + member action block:

```ruby
  action_item :trigger_generate_snapshot, only: :show do
    link_to "Regenerate Data", trigger_generate_snapshot_admin_enterprise_path(resource), method: :post
  end

  member_action :trigger_generate_snapshot, method: :post do
    resource.qbo_account.sync_all!
    resource.generate_snapshot!
    redirect_to admin_enterprise_path(resource), notice: "Regenerated!"
  end
```

with:

```ruby
  action_item :trigger_generate_snapshot, only: :show do
    link_to "Regenerate Data", trigger_generate_snapshot_admin_enterprise_path(resource), method: :post
  end

  action_item :refresh_chart_accounts, only: :show, if: proc { resource.qbo_account.present? } do
    link_to "Refresh Chart of Accounts", refresh_chart_accounts_admin_enterprise_path(resource), method: :post
  end

  member_action :trigger_generate_snapshot, method: :post do
    resource.qbo_account.sync_all!
    resource.qbo_account.sync_all_chart_accounts!
    resource.generate_snapshot!
    redirect_to admin_enterprise_path(resource), notice: "Regenerated!"
  end

  member_action :refresh_chart_accounts, method: :post do
    resource.qbo_account.sync_all_chart_accounts!
    redirect_to admin_enterprise_path(resource), notice: "Chart of accounts refreshed from QuickBooks."
  end
```

- [ ] **Step 3: Switch the enterprise show page to the mirror**

In `app/admin/enterprises.rb` show block, replace:

```ruby
    qbo_accounts = resource.qbo_account.fetch_all_accounts
```

with:

```ruby
    # Read bank/CC balances from the local chart-of-accounts mirror (synced
    # daily + via the Refresh / Regenerate actions) instead of a live QBO
    # fetch on every page load. Prime the mirror lazily on first view.
    if QboChartAccount.where(qbo_account_id: resource.qbo_account.id).none?
      resource.qbo_account.sync_all_chart_accounts!
    end
    qbo_accounts = QboChartAccount.active.where(qbo_account_id: resource.qbo_account.id)
```

The downstream code (`a.account_type`, `a.classification`, `a.current_balance`) works unchanged: `account_type`/`classification` are columns, `current_balance` is the model method from Task 1.

- [ ] **Step 4: Sanity-check the page renders**

Run: `bin/rails runner 'puts QboChartAccount.count'`
Expected: prints a number (0 is fine) with no NameError. (Full page render requires live QBO creds; manual QA happens post-deploy.)

- [ ] **Step 5: Commit**

```bash
git add lib/tasks/stacks.rake app/admin/enterprises.rb
git commit -m "Wire chart-of-accounts mirror sync into daily task and enterprise admin"
```

---

### Task 4: `QboBillAccountMapping` table + model

**Files:**
- Create: `db/migrate/20260610000002_create_qbo_bill_account_mappings.rb`
- Create: `app/models/qbo_bill_account_mapping.rb`
- Modify: `app/models/qbo_account.rb` (warn on mappings pointing at deactivated accounts)
- Test: `test/models/qbo_bill_account_mapping_test.rb`

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260610000002_create_qbo_bill_account_mappings.rb
class CreateQboBillAccountMappings < ActiveRecord::Migration[6.1]
  def change
    create_table :qbo_bill_account_mappings do |t|
      t.references :enterprise, null: false, foreign_key: true
      t.string :line_item_key, null: false
      # At most one subject column may be set (enforced by check constraint
      # + model validation). Both NULL = entity-level default.
      t.references :project_tracker, null: true, foreign_key: true
      t.references :contributor, null: true, foreign_key: true
      t.string :qbo_chart_account_qbo_id, null: false
      t.timestamps
    end

    # Postgres unique indexes treat NULLs as distinct, so a plain composite
    # unique index would allow duplicate entity-default rows. Three partial
    # indexes cover the three mapping levels.
    add_index :qbo_bill_account_mappings, [:enterprise_id, :line_item_key],
      unique: true,
      where: "project_tracker_id IS NULL AND contributor_id IS NULL",
      name: "idx_qbo_bill_acct_mappings_default"
    add_index :qbo_bill_account_mappings, [:enterprise_id, :line_item_key, :contributor_id],
      unique: true, where: "contributor_id IS NOT NULL",
      name: "idx_qbo_bill_acct_mappings_contributor"
    add_index :qbo_bill_account_mappings, [:enterprise_id, :line_item_key, :project_tracker_id],
      unique: true, where: "project_tracker_id IS NOT NULL",
      name: "idx_qbo_bill_acct_mappings_tracker"

    add_check_constraint :qbo_bill_account_mappings,
      "project_tracker_id IS NULL OR contributor_id IS NULL",
      name: "qbo_bill_acct_mappings_one_subject"
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: migrates cleanly.

- [ ] **Step 3: Write the failing model tests**

```ruby
# test/models/qbo_bill_account_mapping_test.rb
require "test_helper"

class QboBillAccountMappingTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "MapTest-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "x", client_secret: "y", realm_id: "realm-#{SecureRandom.hex(4)}")
    @chart_account = QboChartAccount.create!(qbo_account: @qa, qbo_id: "77", name: "Contractors - Client Services", data: {})
  end

  test "valid entity-default mapping" do
    m = QboBillAccountMapping.new(
      enterprise: @enterprise,
      line_item_key: "trueup",
      qbo_chart_account_qbo_id: "77",
    )
    assert m.valid?, m.errors.full_messages.join(", ")
    assert_equal "Entity default", m.subject_label
  end

  test "rejects unknown line_item_key" do
    m = QboBillAccountMapping.new(enterprise: @enterprise, line_item_key: "nonsense", qbo_chart_account_qbo_id: "77")
    refute m.valid?
    assert m.errors[:line_item_key].any?
  end

  test "rejects a mapping whose chart account is missing from the mirror" do
    m = QboBillAccountMapping.new(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "NOPE")
    refute m.valid?
    assert_match(/not found/, m.errors[:qbo_chart_account_qbo_id].join)
  end

  test "rejects a mapping whose chart account is inactive" do
    @chart_account.update!(active: false)
    m = QboBillAccountMapping.new(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "77")
    refute m.valid?
    assert_match(/inactive/, m.errors[:qbo_chart_account_qbo_id].join)
  end

  test "rejects setting both contributor and project tracker" do
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "m#{SecureRandom.hex(2)}@x.com", data: {})
    contributor = Contributor.create!(forecast_person: fp)
    tracker = ProjectTracker.new(name: "PT-#{SecureRandom.hex(2)}")
    tracker.save!(validate: false)

    m = QboBillAccountMapping.new(
      enterprise: @enterprise, line_item_key: "trueup",
      contributor: contributor, project_tracker: tracker,
      qbo_chart_account_qbo_id: "77",
    )
    refute m.valid?
    assert m.errors[:base].any?
  end

  test "duplicate entity-default rows are rejected" do
    QboBillAccountMapping.create!(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "77")
    dup = QboBillAccountMapping.new(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "77")
    refute dup.valid?
  end

  test "chart_account returns the mirror row" do
    m = QboBillAccountMapping.create!(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "77")
    assert_equal @chart_account, m.chart_account
  end
end
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `bin/rails test test/models/qbo_bill_account_mapping_test.rb`
Expected: FAIL with `NameError: uninitialized constant QboBillAccountMapping`

- [ ] **Step 5: Write the model**

```ruby
# app/models/qbo_bill_account_mapping.rb
# One routing rule for the QBO bill account mapping engine: for a given
# enterprise + line-item kind, which QBO chart account should the bill
# line post to. Subject columns scope the rule:
#   - project_tracker_id set  → project-tracker-level override (wins first)
#   - contributor_id set      → contributor-level override (wins second)
#   - both NULL               → entity-level default (fallback)
# Resolution happens in Qbo::BillAccountResolver. See the design doc at
# docs/superpowers/specs/2026-06-10-qbo-bill-account-mapping-engine-design.md
class QboBillAccountMapping < ApplicationRecord
  LINE_ITEM_KEYS = %w[
    payout_individual_contributor
    payout_account_lead_base
    payout_account_lead_surplus
    payout_project_lead_base
    payout_project_lead_surplus
    payout_commission
    trueup
    contributor_adjustment
    profit_share
    pay_stub
  ].freeze

  belongs_to :enterprise
  belongs_to :project_tracker, optional: true
  belongs_to :contributor, optional: true

  validates :line_item_key, presence: true, inclusion: { in: LINE_ITEM_KEYS }
  validates :line_item_key, uniqueness: { scope: [:enterprise_id, :project_tracker_id, :contributor_id] }
  validates :qbo_chart_account_qbo_id, presence: true
  validate :at_most_one_subject
  validate :chart_account_exists_and_active

  def subject_label
    return "Project: #{project_tracker.name}" if project_tracker.present?
    return "Contributor: #{contributor.display_name}" if contributor.present?
    "Entity default"
  end

  # The mirrored chart-of-accounts row this mapping points at, scoped to
  # the enterprise's realm. Composite (qbo_account_id, qbo_id) lookup,
  # same style as SyncsAsQboBill#qbo_bill.
  def chart_account
    qa = enterprise&.qbo_account
    return nil if qa.nil?
    QboChartAccount.find_by(qbo_account_id: qa.id, qbo_id: qbo_chart_account_qbo_id)
  end

  private

  def at_most_one_subject
    if project_tracker_id.present? && contributor_id.present?
      errors.add(:base, "Set a project tracker OR a contributor, not both. Leave both blank for the entity-level default.")
    end
  end

  def chart_account_exists_and_active
    return if qbo_chart_account_qbo_id.blank? || enterprise.nil?

    qa = enterprise.qbo_account
    if qa.nil?
      errors.add(:enterprise, "has no connected QBO account")
      return
    end

    ca = QboChartAccount.find_by(qbo_account_id: qa.id, qbo_id: qbo_chart_account_qbo_id)
    if ca.nil?
      errors.add(:qbo_chart_account_qbo_id, "not found in this enterprise's chart of accounts mirror (try Refresh Chart of Accounts)")
    elsif !ca.active?
      errors.add(:qbo_chart_account_qbo_id, "is inactive in QBO")
    end
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/models/qbo_bill_account_mapping_test.rb`
Expected: PASS (7 tests)

- [ ] **Step 7: Warn when the sync deactivates accounts that mappings point at**

In `app/models/qbo_account.rb#sync_all_chart_accounts!`, replace the deactivation tail:

```ruby
    QboChartAccount.upsert_all(data, unique_by: :index_qbo_chart_accounts_on_qbo_account_and_qbo_id)
    QboChartAccount
      .where(qbo_account_id: id, active: true)
      .where.not(qbo_id: data.map { |d| d[:qbo_id] })
      .update_all(active: false)
```

with:

```ruby
    QboChartAccount.upsert_all(data, unique_by: :index_qbo_chart_accounts_on_qbo_account_and_qbo_id)

    newly_inactive = QboChartAccount
      .where(qbo_account_id: id, active: true)
      .where.not(qbo_id: data.map { |d| d[:qbo_id] })

    # Surface mappings that point at a just-deactivated account BEFORE a
    # bill sync hard-fails on them (strict resolver, no fallback).
    affected = QboBillAccountMapping
      .where(enterprise_id: enterprise_id, qbo_chart_account_qbo_id: newly_inactive.select(:qbo_id))
    affected.find_each do |m|
      Rails.logger.warn(
        "[QboAccount#sync_all_chart_accounts!] mapping ##{m.id} (#{m.line_item_key}, #{m.subject_label}) " \
        "points at QBO chart account #{m.qbo_chart_account_qbo_id} which is no longer active in realm #{realm_id} — " \
        "bill syncs using it will fail until it's remapped"
      )
    end

    newly_inactive.update_all(active: false)
```

- [ ] **Step 8: Add a test for the warning path**

Append to `test/models/qbo_account_test.rb`:

```ruby
  test "sync_all_chart_accounts! logs a warning when a mapping points at a deactivated account" do
    a = OpenStruct.new(id: "1", name: "Keep", acct_num: nil, classification: "Expense", account_type: "Expense", as_json: {})
    b = OpenStruct.new(id: "2", name: "Mapped Then Gone", acct_num: nil, classification: "Expense", account_type: "Expense", as_json: {})
    @qa.stubs(:fetch_all_accounts).returns([a, b])
    @qa.sync_all_chart_accounts!

    # save!(validate: false): the sanctuary enterprise has TWO fixture
    # QboAccounts, and has_one :qbo_account may return the other one —
    # the chart_account_exists_and_active validation would then look in
    # the wrong realm. The warn path under test matches on enterprise_id
    # + qbo_chart_account_qbo_id, which doesn't care.
    QboBillAccountMapping.new(
      enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "2",
    ).save!(validate: false)

    old_logger = Rails.logger
    io = StringIO.new
    Rails.logger = Logger.new(io)
    begin
      @qa.stubs(:fetch_all_accounts).returns([a])
      @qa.sync_all_chart_accounts!
    ensure
      Rails.logger = old_logger
    end

    assert_match(/no longer active/, io.string)
    refute QboChartAccount.find_by(qbo_account_id: @qa.id, qbo_id: "2").active?
  end
```

Note: `@enterprise` is already set in this file's setup (`@qa.enterprise`).

- [ ] **Step 9: Run tests**

Run: `bin/rails test test/models/qbo_account_test.rb test/models/qbo_bill_account_mapping_test.rb`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add db/migrate/20260610000002_create_qbo_bill_account_mappings.rb db/schema.rb app/models/qbo_bill_account_mapping.rb app/models/qbo_account.rb test/models/qbo_bill_account_mapping_test.rb test/models/qbo_account_test.rb
git commit -m "Add QboBillAccountMapping rules table with strict chart-account validation"
```

---

### Task 5: `Qbo::BillAccountResolver` + `Qbo::UnmappedLineItemError`

**Files:**
- Create: `app/services/qbo/unmapped_line_item_error.rb`
- Create: `app/services/qbo/bill_account_resolver.rb`
- Test: `test/services/qbo/bill_account_resolver_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/qbo/bill_account_resolver_test.rb
require "test_helper"

class Qbo::BillAccountResolverTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "ResolverTest-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "x", client_secret: "y", realm_id: "realm-#{SecureRandom.hex(4)}")

    @default_acct = QboChartAccount.create!(qbo_account: @qa, qbo_id: "100", name: "Contractors - Client Services", data: {})
    @contributor_acct = QboChartAccount.create!(qbo_account: @qa, qbo_id: "200", name: "Contractors - Special", data: {})
    @tracker_acct = QboChartAccount.create!(qbo_account: @qa, qbo_id: "300", name: "Contractors - Marketing Services", data: {})

    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "r#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @tracker = ProjectTracker.new(name: "RT-#{SecureRandom.hex(2)}")
    @tracker.save!(validate: false)

    @resolver = Qbo::BillAccountResolver.new(@enterprise)
  end

  def map!(key, qbo_id, contributor: nil, project_tracker: nil)
    QboBillAccountMapping.create!(
      enterprise: @enterprise, line_item_key: key,
      contributor: contributor, project_tracker: project_tracker,
      qbo_chart_account_qbo_id: qbo_id,
    )
  end

  test "falls through to the entity default when no override matches" do
    map!("trueup", "100")
    account = @resolver.account_for("trueup", contributor: @contributor)
    assert_equal @default_acct, account
  end

  test "contributor mapping beats entity default" do
    map!("trueup", "100")
    map!("trueup", "200", contributor: @contributor)
    assert_equal @contributor_acct, @resolver.account_for("trueup", contributor: @contributor)
  end

  test "project tracker mapping beats contributor mapping" do
    map!("payout_individual_contributor", "100")
    map!("payout_individual_contributor", "200", contributor: @contributor)
    map!("payout_individual_contributor", "300", project_tracker: @tracker)
    account = @resolver.account_for("payout_individual_contributor", contributor: @contributor, project_tracker: @tracker)
    assert_equal @tracker_acct, account
  end

  test "ignores tracker mappings when no tracker is given" do
    map!("payout_individual_contributor", "300", project_tracker: @tracker)
    map!("payout_individual_contributor", "100")
    assert_equal @default_acct, @resolver.account_for("payout_individual_contributor", contributor: @contributor)
  end

  test "raises UnmappedLineItemError naming the chain when nothing matches" do
    err = assert_raises(Qbo::UnmappedLineItemError) do
      @resolver.account_for("pay_stub", contributor: @contributor, project_tracker: @tracker)
    end
    assert_match(/no QBO account mapping for pay_stub/, err.message)
    assert_match(/ProjectTracker##{@tracker.id}/, err.message)
    assert_match(/Contributor##{@contributor.id}/, err.message)
    assert_match(/entity default/, err.message)
  end

  test "raises UnmappedLineItemError when the mapped chart account has been deactivated" do
    map!("trueup", "100")
    @default_acct.update!(active: false)
    err = assert_raises(Qbo::UnmappedLineItemError) { @resolver.account_for("trueup", contributor: @contributor) }
    assert_match(/inactive/, err.message)
  end

  test "raises UnmappedLineItemError when the enterprise has no qbo_account" do
    bare = Enterprise.find_or_create_by!(name: "Bare-#{SecureRandom.hex(2)}")
    err = assert_raises(Qbo::UnmappedLineItemError) do
      Qbo::BillAccountResolver.new(bare).account_for("trueup", contributor: @contributor)
    end
    assert_match(/no connected QboAccount/, err.message)
  end

  test "raises ArgumentError for unknown line_item_key" do
    assert_raises(ArgumentError) { @resolver.account_for("bogus", contributor: @contributor) }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/qbo/bill_account_resolver_test.rb`
Expected: FAIL with `NameError: uninitialized constant Qbo::BillAccountResolver` (or `Qbo`)

- [ ] **Step 3: Write the error class and resolver**

```ruby
# app/services/qbo/unmapped_line_item_error.rb
module Qbo
  # Raised when the bill account mapping engine can't resolve a QBO chart
  # account for a line item. Deliberately strict: there is NO fallback to
  # hard-coded routing. Fix by adding the missing QboBillAccountMapping
  # in admin (Enterprise → QBO Bill Account Mappings).
  class UnmappedLineItemError < StandardError; end
end
```

```ruby
# app/services/qbo/bill_account_resolver.rb
module Qbo
  # Resolves which QBO chart account a Stacks-managed bill line posts to.
  #
  #   Qbo::BillAccountResolver.new(enterprise)
  #     .account_for("payout_commission", contributor: c, project_tracker: pt)
  #   # => QboChartAccount
  #
  # Precedence (first mapping wins):
  #   1. project-tracker-level (when a tracker is given)
  #   2. contributor-level
  #   3. entity-level default
  #
  # Raises Qbo::UnmappedLineItemError when no mapping matches or the mapped
  # chart account is missing/inactive in the local mirror. No silent
  # fallback — replaces the legacy hard-coded find_qbo_account! routing.
  class BillAccountResolver
    def initialize(enterprise)
      @enterprise = enterprise
    end

    def account_for(line_item_key, contributor:, project_tracker: nil)
      key = line_item_key.to_s
      unless QboBillAccountMapping::LINE_ITEM_KEYS.include?(key)
        raise ArgumentError, "Unknown line_item_key #{key.inspect} (valid: #{QboBillAccountMapping::LINE_ITEM_KEYS.join(', ')})"
      end

      qa = @enterprise&.qbo_account
      if qa.nil?
        raise UnmappedLineItemError, "Enterprise #{@enterprise&.name.inspect} has no connected QboAccount"
      end

      tried = []
      mapping = nil

      if project_tracker.present?
        tried << "ProjectTracker##{project_tracker.id}"
        mapping = scope(key).find_by(project_tracker_id: project_tracker.id)
      end
      if mapping.nil? && contributor.present?
        tried << "Contributor##{contributor.id}"
        mapping = scope(key).find_by(contributor_id: contributor.id, project_tracker_id: nil)
      end
      if mapping.nil?
        tried << "entity default"
        mapping = scope(key).find_by(project_tracker_id: nil, contributor_id: nil)
      end

      if mapping.nil?
        raise UnmappedLineItemError,
          "Enterprise #{@enterprise.name.inspect} has no QBO account mapping for #{key} " \
          "(tried #{tried.join(', ')})"
      end

      chart_account = QboChartAccount.find_by(qbo_account_id: qa.id, qbo_id: mapping.qbo_chart_account_qbo_id)
      if chart_account.nil? || !chart_account.active?
        state = chart_account.nil? ? "missing from" : "inactive in"
        raise UnmappedLineItemError,
          "Enterprise #{@enterprise.name.inspect}: mapping for #{key} (#{mapping.subject_label}) points at " \
          "QBO chart account #{mapping.qbo_chart_account_qbo_id.inspect} which is #{state} the local mirror"
      end

      chart_account
    end

    private

    def scope(key)
      QboBillAccountMapping.where(enterprise_id: @enterprise.id, line_item_key: key)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/qbo/bill_account_resolver_test.rb`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add app/services/qbo/ test/services/qbo/
git commit -m "Add Qbo::BillAccountResolver with strict project->contributor->entity precedence"
```

---

### Task 6: Rewire `SyncsAsQboBill` + simple hosts (Trueup, ContributorAdjustment, ProfitShare)

**Files:**
- Modify: `app/models/concerns/syncs_as_qbo_bill.rb` (delete `find_qbo_account!`, rewrite `bill_line_items`, update `sync_qbo_bill!`)
- Modify: `app/models/trueup.rb` (add `bill_line_item_key`)
- Modify: `app/models/contributor_adjustment.rb` (add `bill_line_item_key`)
- Modify: `app/models/profit_share.rb` (delete override + constant, add `bill_line_item_key`)
- Modify: `app/models/invoice_tracker.rb:840` (comment references the deleted override)
- Test: `test/models/concerns/syncs_as_qbo_bill_test.rb`, `test/models/profit_share_test.rb`

**IMPORTANT ordering note:** This task temporarily breaks `ContributorPayout` and `PayStub` (their overrides reference `find_qbo_account!`/old signatures) — Tasks 7 and 8 fix them. Run only the test files listed in this task until Task 8 is done; the full suite run happens in Task 12.

- [ ] **Step 1: Update the concern**

In `app/models/concerns/syncs_as_qbo_bill.rb`:

(a) Delete the entire `find_qbo_account!` method (lines 38-55) and replace with nothing.

(b) Replace the host-contract comment block (lines 78-84) with:

```ruby
  # Host models MUST implement:
  # - bill_txn_date          → Date for QBO Bill txn_date and due_date
  # - bill_description       → String used as the line item description
  # - bill_doc_number_code   → Short 2-char tag in the QBO Bill doc_number
  #   (must be unique across all host models). Current mappings:
  #     CP = ContributorPayout, TU = Trueup, CA = ContributorAdjustment,
  #     PS = ProfitShare, SB = PayStub.
  # - bill_line_item_key     → QboBillAccountMapping::LINE_ITEM_KEYS entry
  #   used by the default single-line bill_line_items below. Hosts that
  #   override bill_line_items (ContributorPayout, PayStub) resolve their
  #   own per-line keys instead.
```

(c) Replace `bill_line_items` (lines 90-102) with:

```ruby
  # Returns the array of Quickbooks::Model::BillLineItem objects that will
  # be pushed for this host's bill. Default implementation produces a single
  # line at the account resolved by the bill account mapping engine
  # (project tracker → contributor → entity default; raises
  # Qbo::UnmappedLineItemError when unmapped). ContributorPayout and
  # PayStub override this to emit multiple lines.
  def bill_line_items
    account = Qbo::BillAccountResolver.new(enterprise)
      .account_for(bill_line_item_key, contributor: contributor)
    line = Quickbooks::Model::BillLineItem.new(description: bill_description, amount: amount)
    line.account_based_expense_item! do |detail|
      detail.account_ref = Quickbooks::Model::BaseReference.new(account.qbo_id)
    end
    [line]
  end
```

(d) In `sync_qbo_bill!`, replace:

```ruby
    qbo_accounts = qa.fetch_all_accounts
    bill.line_items = bill_line_items(qbo_accounts)
```

with:

```ruby
    # Lazily prime the chart-of-accounts mirror on first use so a bill sync
    # works even before the daily task has run for this realm. (Previously
    # every sync did a live fetch_all_accounts here anyway.)
    qa.sync_all_chart_accounts! if QboChartAccount.where(qbo_account_id: qa.id).none?
    bill.line_items = bill_line_items
```

- [ ] **Step 2: Update the simple hosts**

In `app/models/trueup.rb`, after `bill_doc_number_code`:

```ruby
  def bill_line_item_key
    "trueup"
  end
```

In `app/models/contributor_adjustment.rb`, after `bill_doc_number_code` (find it with grep; same pattern as Trueup):

```ruby
  def bill_line_item_key
    "contributor_adjustment"
  end
```

In `app/models/profit_share.rb`, delete the `PROFIT_SHARE_LIABILITY_ACCT_NUM` constant, its comment block, and the whole `find_qbo_account!` override (lines 34-48), replacing them with:

```ruby
  # Profit-share bills accrue to the account mapped for "profit_share" —
  # seeded to the dedicated liability account (acct 2340, Accrued Profit
  # Sharing) so finance can track exposure separately from contractor
  # expenses. See Qbo::BillAccountResolver.
  def bill_line_item_key
    "profit_share"
  end
```

In `app/models/invoice_tracker.rb` around line 840, update the stale comment that references `ContributorPayout#find_qbo_account!` to reference the mapping engine instead (read the surrounding comment and reword it to mention `QboBillAccountMapping` / internal project trackers being seeded to the Marketing account; keep its surrounding meaning intact).

- [ ] **Step 3: Update the concern tests**

In `test/models/concerns/syncs_as_qbo_bill_test.rb`:

(a) Replace the `find_qbo_account!` failure test (the `test "find_qbo_account! raises a descriptive error when enterprise has no qbo_account"` block) with:

```ruby
  # ---------------------------------------------------------------------------
  # bill_line_items via the mapping engine
  # ---------------------------------------------------------------------------

  test "default bill_line_items raises Qbo::UnmappedLineItemError when nothing is mapped" do
    adj = ContributorAdjustment.create!(ledger: @sanctuary_ledger, amount: 50, effective_on: Date.new(2031, 1, 15), qbo_account: @sanctuary_qa)
    err = assert_raises(Qbo::UnmappedLineItemError) { adj.bill_line_items }
    assert_match(/no QBO account mapping for contributor_adjustment/, err.message)
  end

  test "default bill_line_items builds a single line at the resolved chart account" do
    QboChartAccount.create!(qbo_account: @sanctuary_qa, qbo_id: "777", name: "Contractors - Client Services", data: {})
    QboBillAccountMapping.create!(enterprise: @sanctuary, line_item_key: "contributor_adjustment", qbo_chart_account_qbo_id: "777")

    adj = ContributorAdjustment.create!(ledger: @sanctuary_ledger, amount: 50, effective_on: Date.new(2031, 1, 15), qbo_account: @sanctuary_qa)
    lines = adj.bill_line_items

    assert_equal 1, lines.size
    assert_equal "777", lines.first.account_based_expense_line_detail.account_ref.value
    assert_equal 50, lines.first.amount
  end
```

Note: this lives in `SyncsAsQboBillFailureModeTest`, which already defines `@sanctuary`, `@sanctuary_qa`, and `@sanctuary_ledger` in setup.

(b) Leave every other test unchanged — they don't touch account resolution.

- [ ] **Step 4: Replace the ProfitShare tests**

Replace the two `find_qbo_account!` tests in `test/models/profit_share_test.rb` (keep anything else in the file) with:

```ruby
  test "bill_line_item_key routes profit shares through the mapping engine" do
    assert_equal "profit_share", @ps.bill_line_item_key
    assert_includes QboBillAccountMapping::LINE_ITEM_KEYS, @ps.bill_line_item_key
  end
```

- [ ] **Step 5: Run this task's tests**

Run: `bin/rails test test/models/concerns/syncs_as_qbo_bill_test.rb test/models/profit_share_test.rb test/models/qbo_account_test.rb`
Expected: PASS. (Do NOT run the full suite yet — CP/PayStub are mid-rewire.)

- [ ] **Step 6: Commit**

```bash
git add app/models/concerns/syncs_as_qbo_bill.rb app/models/trueup.rb app/models/contributor_adjustment.rb app/models/profit_share.rb app/models/invoice_tracker.rb test/models/concerns/syncs_as_qbo_bill_test.rb test/models/profit_share_test.rb
git commit -m "Route default bill lines through Qbo::BillAccountResolver; delete find_qbo_account!"
```

---

### Task 7: ContributorPayout — per-(bucket × project tracker) lines via the resolver

**Files:**
- Modify: `app/services/contributor_payouts/qbo_bill_lines.rb` (full rewrite below)
- Modify: `app/models/contributor_payout.rb` (delete `find_qbo_account!` override lines 29-52; update `bill_line_items` lines 61-73)
- Test: `test/services/contributor_payouts/qbo_bill_lines_test.rb` (full rewrite below)
- Test: `test/models/contributor_payout_test.rb` (update the `bill_line_items` test ~line 70)

- [ ] **Step 1: Rewrite the QboBillLines tests**

Replace the entire contents of `test/services/contributor_payouts/qbo_bill_lines_test.rb` with:

```ruby
require "test_helper"
require "ostruct"

class ContributorPayouts::QboBillLinesTest < ActiveSupport::TestCase
  # Records every account_for call and returns a canned QboChartAccount-like
  # OpenStruct per line_item_key (optionally per [key, tracker_id]).
  class FakeResolver
    attr_reader :calls

    def initialize(accounts)
      @accounts = accounts
      @calls = []
    end

    def account_for(key, contributor:, project_tracker: nil)
      @calls << { key: key, tracker_id: project_tracker&.id }
      @accounts.fetch([key, project_tracker&.id]) { @accounts.fetch(key) }
    end
  end

  DEFAULT_ACCT     = OpenStruct.new(qbo_id: "100", name: "Contractors - Client Services")
  BONUSES_ACCT     = OpenStruct.new(qbo_id: "5710", name: "Bonuses")
  COMMISSIONS_ACCT = OpenStruct.new(qbo_id: "6120", name: "Commissions")
  MARKETING_ACCT   = OpenStruct.new(qbo_id: "300", name: "Contractors - Marketing Services")

  def default_accounts
    {
      "payout_individual_contributor" => DEFAULT_ACCT,
      "payout_account_lead_base"      => DEFAULT_ACCT,
      "payout_account_lead_surplus"   => BONUSES_ACCT,
      "payout_project_lead_base"      => DEFAULT_ACCT,
      "payout_project_lead_surplus"   => BONUSES_ACCT,
      "payout_commission"             => COMMISSIONS_ACCT,
    }
  end

  # Synthetic CP stub. Mocha stubs:
  #   in_sync?, blueprint, amount, bill_description, contributor, invoice_tracker
  def make_cp(blueprint:, amount:, in_sync: true, trackers: [])
    contributor = OpenStruct.new(id: 7)
    invoice_tracker = OpenStruct.new(project_trackers: trackers)
    cp = mock("contributor_payout")
    cp.stubs(:in_sync?).returns(in_sync)
    cp.stubs(:blueprint).returns(blueprint)
    cp.stubs(:amount).returns(amount)
    cp.stubs(:id).returns(42)
    cp.stubs(:bill_description).returns("https://example.com/cp/42")
    cp.stubs(:contributor).returns(contributor)
    cp.stubs(:invoice_tracker).returns(invoice_tracker)
    cp
  end

  def all_buckets_blueprint
    {
      "IndividualContributor" => [{ "amount" => 100.0, "description_line" => "- IC line" }],
      "AccountLead"           => [
        { "amount" => 8.0,  "description_line" => "- 100hrs * 8% = $8 base" },
        { "amount" => 3.0,  "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
      "ProjectLead"           => [
        { "amount" => 5.0,  "description_line" => "- 100hrs * 5% = $5 base" },
        { "amount" => 3.0,  "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
      "Commission"            => [{ "amount" => 10.0, "description_line" => "- 5% of $200 = $10" }],
    }
  end

  test "multi-line happy path: 6 buckets resolve per line_item_key" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 129.0)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 6, lines.size
    by_qbo_id = lines.group_by { |l| l[:account].qbo_id }
    assert by_qbo_id["6120"].any? { |l| l[:amount] == 10.0 }, "commission line at Commissions"
    assert_equal 2, by_qbo_id["5710"].size, "AL surplus + PL surplus at Bonuses"
    assert_equal 3, by_qbo_id["100"].size, "IC + AL base + PL base at default"
    assert_equal 129.0, lines.sum { |l| l[:amount] }.round(2)
  end

  test "splits a bucket into one line per project tracker" do
    tracker_a = OpenStruct.new(id: 1, forecast_project_ids: ["fpA"])
    tracker_b = OpenStruct.new(id: 2, forecast_project_ids: ["fpB"])
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 60.0, "description_line" => "- A work", "blueprint_metadata" => { "forecast_project" => "fpA" } },
        { "amount" => 40.0, "description_line" => "- B work", "blueprint_metadata" => { "forecast_project" => "fpB" } },
      ],
    }
    accounts = default_accounts.merge(
      ["payout_individual_contributor", 2] => MARKETING_ACCT,
    )
    resolver = FakeResolver.new(accounts)
    cp = make_cp(blueprint: blueprint, amount: 100.0, trackers: [tracker_a, tracker_b])

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 2, lines.size, "one IC line per tracker"
    line_a = lines.find { |l| l[:amount] == 60.0 }
    line_b = lines.find { |l| l[:amount] == 40.0 }
    assert_equal "100", line_a[:account].qbo_id
    assert_equal "300", line_b[:account].qbo_id, "tracker B's override account"
    assert_includes resolver.calls, { key: "payout_individual_contributor", tracker_id: 1 }
    assert_includes resolver.calls, { key: "payout_individual_contributor", tracker_id: 2 }
  end

  test "entries with no resolvable tracker group into a nil-tracker line" do
    tracker_a = OpenStruct.new(id: 1, forecast_project_ids: ["fpA"])
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 60.0, "description_line" => "- A work", "blueprint_metadata" => { "forecast_project" => "fpA" } },
        { "amount" => 40.0, "description_line" => "- orphan", "blueprint_metadata" => { "forecast_project" => "fpZ" } },
        { "amount" => 29.0, "description_line" => "- no metadata" },
      ],
    }
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: blueprint, amount: 129.0, trackers: [tracker_a])

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 2, lines.size, "tracker-A line + combined nil-tracker line"
    nil_tracker_line = lines.find { |l| l[:amount] == 69.0 }
    assert_not_nil nil_tracker_line, "orphan + metadata-less entries combine into one line"
    assert_includes resolver.calls, { key: "payout_individual_contributor", tracker_id: nil }
  end

  test "legacy mixed AccountLead arrays still split base vs surplus via the description marker" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 129.0)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    surplus_keys = resolver.calls.map { |c| c[:key] }.select { |k| k.include?("surplus") }
    assert_equal ["payout_account_lead_surplus", "payout_project_lead_surplus"].sort, surplus_keys.sort
  end

  test "out-of-sync payout collapses to a single line at payout_individual_contributor" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 999.0, in_sync: false)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 1, lines.size
    assert_equal 999.0, lines.first[:amount]
    assert_equal "100", lines.first[:account].qbo_id
    assert_equal [{ key: "payout_individual_contributor", tracker_id: nil }], resolver.calls
  end

  test "empty blueprint collapses to a single line" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: {}, amount: 50.0)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 1, lines.size
    assert_equal 50.0, lines.first[:amount]
  end

  test "bucket-sum drift from cp.amount collapses to a single line and warns" do
    blueprint = { "IndividualContributor" => [{ "amount" => 100.0, "description_line" => "- IC" }] }
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: blueprint, amount: 101.0)
    # in_sync? is stubbed true but the sums disagree — belt-and-suspenders path.

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 1, lines.size
    assert_equal 101.0, lines.first[:amount]
  end

  test "line descriptions keep the role header and entry lines" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 129.0)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    ic_line = lines.find { |l| l[:amount] == 100.0 }
    assert_match(/# Individual Contributor/, ic_line[:description])
    assert_match(/- IC line/, ic_line[:description])
    assert_match(%r{https://example.com/cp/42}, ic_line[:description])
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/contributor_payouts/qbo_bill_lines_test.rb`
Expected: FAIL (wrong constructor arity / missing methods)

- [ ] **Step 3: Rewrite the service**

Replace the entire contents of `app/services/contributor_payouts/qbo_bill_lines.rb` with:

```ruby
module ContributorPayouts
  # Pure compute for the multi-line QBO Bill that ContributorPayout pushes.
  #
  # Given a ContributorPayout (and optionally an injected resolver — tests
  # pass a fake), returns an Array of
  #   { amount:, description:, account: }
  # Hashes — `account` is a QboChartAccount — that the caller turns into
  # Quickbooks::Model::BillLineItem instances.
  #
  # Lines are grouped per (role bucket × project tracker): every blueprint
  # entry carries blueprint_metadata.forecast_project, which locates a
  # ProjectTracker among invoice_tracker.project_trackers (same lookup as
  # ContributorPayout#calculate_surplus). Entries with no resolvable
  # tracker group into a per-bucket nil-tracker line. Each line's account
  # comes from Qbo::BillAccountResolver, so project-tracker-level mappings
  # (e.g. internal projects → Marketing) apply per line.
  #
  # Behavior preserved from the pre-engine version:
  # - When `cp.in_sync?` is false (blueprint sums disagree with cp.amount),
  #   collapses to a single line resolved as payout_individual_contributor
  #   with no tracker, so we never push a multi-line bill whose total can't
  #   be trusted.
  # - When the per-line sums drift from cp.amount (belt-and-suspenders
  #   after in_sync?), logs a WARN and collapses the same way.
  #
  # No QBO API calls happen inside this class.
  class QboBillLines
    ROLE_LABEL_BY_BUCKET = {
      individual_contributor:  "Individual Contributor",
      account_lead_base:       "Account Lead",
      account_lead_surplus:    "Account Lead Surplus",
      project_lead_base:       "Project Lead",
      project_lead_surplus:    "Project Lead Surplus",
      commission:              "Commission",
    }.freeze

    LINE_ITEM_KEY_BY_BUCKET = {
      individual_contributor:  "payout_individual_contributor",
      account_lead_base:       "payout_account_lead_base",
      account_lead_surplus:    "payout_account_lead_surplus",
      project_lead_base:       "payout_project_lead_base",
      project_lead_surplus:    "payout_project_lead_surplus",
      commission:              "payout_commission",
    }.freeze

    # Fallback marker for historical blueprints that pre-date the
    # AccountLeadSurplus / ProjectLeadSurplus first-class arrays. New
    # blueprints (post InvoiceTracker#make_contributor_payouts! change)
    # write surplus entries to their own keys; we only sniff
    # description_line for entries still living in the mixed
    # AccountLead / ProjectLead arrays.
    SURPLUS_DESCRIPTION_MARKER = "surplus revenue".freeze

    def initialize(contributor_payout, resolver: nil)
      @cp = contributor_payout
      @resolver = resolver || Qbo::BillAccountResolver.new(contributor_payout.enterprise)
    end

    def call
      return single_line unless cp.in_sync?

      buckets = bucket_blueprint(cp.blueprint || {})

      lines = ROLE_LABEL_BY_BUCKET.keys.each_with_object([]) do |bucket, acc|
        entries = buckets[bucket]
        next if entries.blank?

        entries.group_by { |e| tracker_for(e) }.each do |tracker, group|
          amount = group.sum { |e| e["amount"].to_f }.round(2)
          next if amount.zero?

          acc << {
            amount: amount,
            description: build_description(bucket, group),
            account: account_for(bucket, tracker),
          }
        end
      end

      return single_line if lines.empty?

      if lines.sum { |l| l[:amount] }.round(2) != cp.amount.to_f.round(2)
        Rails.logger.warn(
          "ContributorPayouts::QboBillLines: per-line sums drifted from cp.amount " \
          "(cp_id=#{cp.id}, cp.amount=#{cp.amount}, line_sum=#{lines.sum { |l| l[:amount] }}); " \
          "falling back to single-line bill"
        )
        return single_line
      end

      lines
    end

    private

    attr_reader :cp, :resolver

    def single_line
      [{
        amount: cp.amount,
        description: cp.bill_description,
        account: resolver.account_for("payout_individual_contributor", contributor: cp.contributor),
      }]
    end

    def bucket_blueprint(blueprint)
      buckets = ROLE_LABEL_BY_BUCKET.keys.each_with_object({}) { |k, h| h[k] = [] }

      Array(blueprint["IndividualContributor"]).each { |e| buckets[:individual_contributor] << e }
      Array(blueprint["Commission"]).each            { |e| buckets[:commission] << e }

      # First-class surplus arrays (new shape from make_contributor_payouts!).
      Array(blueprint["AccountLeadSurplus"]).each { |e| buckets[:account_lead_surplus] << e }
      Array(blueprint["ProjectLeadSurplus"]).each { |e| buckets[:project_lead_surplus] << e }

      # Historical shape: AL / PL arrays mix base and surplus, only
      # distinguishable by SURPLUS_DESCRIPTION_MARKER in description_line.
      Array(blueprint["AccountLead"]).each do |entry|
        bucket = surplus_entry?(entry) ? :account_lead_surplus : :account_lead_base
        buckets[bucket] << entry
      end

      Array(blueprint["ProjectLead"]).each do |entry|
        bucket = surplus_entry?(entry) ? :project_lead_surplus : :project_lead_base
        buckets[bucket] << entry
      end

      buckets
    end

    def surplus_entry?(entry)
      entry["description_line"].to_s.include?(SURPLUS_DESCRIPTION_MARKER)
    end

    def tracker_for(entry)
      fp_id = entry.is_a?(Hash) ? entry.dig("blueprint_metadata", "forecast_project") : nil
      return nil if fp_id.blank?
      project_trackers.find { |pt| pt.forecast_project_ids.include?(fp_id) }
    end

    def project_trackers
      @project_trackers ||= cp.invoice_tracker.project_trackers
    end

    def build_description(bucket, entries)
      role_header = "# #{ROLE_LABEL_BY_BUCKET.fetch(bucket)}"
      lines = entries.map { |e| e["description_line"].to_s }
      ([role_header] + lines + [cp.bill_description]).join("\n")
    end

    def account_for(bucket, tracker)
      key = LINE_ITEM_KEY_BY_BUCKET.fetch(bucket)
      @account_cache ||= {}
      @account_cache[[key, tracker&.id]] ||=
        resolver.account_for(key, contributor: cp.contributor, project_tracker: tracker)
    end
  end
end
```

- [ ] **Step 4: Update ContributorPayout**

In `app/models/contributor_payout.rb`:

(a) Delete the entire `find_qbo_account!` override (lines 29-52, including its comments).

(b) Replace `bill_line_items` (lines 54-73, including the comment) with:

```ruby
  # Multi-line override of SyncsAsQboBill#bill_line_items: breaks the bill
  # into per-(role bucket × project tracker) lines so finance can attribute
  # spend to per-role, per-project QBO accounts. Falls back to a single
  # line (payout_individual_contributor mapping) when the payout isn't
  # reconciled — see ContributorPayouts::QboBillLines + the design doc at
  # docs/superpowers/specs/2026-06-10-qbo-bill-account-mapping-engine-design.md
  def bill_line_items
    lines_data = ContributorPayouts::QboBillLines.new(self).call
    lines_data.map do |data|
      line = Quickbooks::Model::BillLineItem.new(
        description: data[:description],
        amount: data[:amount],
      )
      line.account_based_expense_item! do |detail|
        detail.account_ref = Quickbooks::Model::BaseReference.new(data[:account].qbo_id)
      end
      line
    end
  end
```

- [ ] **Step 5: Update the contributor_payout_test bill_line_items test**

In `test/models/contributor_payout_test.rb`, find the test at ~line 70 (`"bill_line_items delegates to ContributorPayouts::QboBillLines..."`). Update it: the call is now `cp.bill_line_items` (no argument), the stubbed `QboBillLines.new` expectation takes `(cp)` instead of `(cp, [])`, and the stubbed line-data account must be an object with `qbo_id` (e.g. `OpenStruct.new(qbo_id: "55")`); assert `line.account_based_expense_line_detail.account_ref.value == "55"`. Keep the test's existing structure otherwise — read it first, then make the minimal edits.

- [ ] **Step 6: Run this task's tests**

Run: `bin/rails test test/services/contributor_payouts/qbo_bill_lines_test.rb test/models/contributor_payout_test.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add app/services/contributor_payouts/qbo_bill_lines.rb app/models/contributor_payout.rb test/services/contributor_payouts/qbo_bill_lines_test.rb test/models/contributor_payout_test.rb
git commit -m "Split contributor payout bill lines per (bucket x project tracker) via the mapping engine"
```

---

### Task 8: PayStub — per-project lines via the resolver

**Files:**
- Modify: `app/models/pay_stub.rb` (delete `find_qbo_account!` lines 65-72; rewrite `bill_line_items` lines 74-97)
- Test: `test/models/pay_stub_test.rb` (append tests)

- [ ] **Step 1: Write the failing tests**

Append to `test/models/pay_stub_test.rb` (read the file's setup first; if it lacks an enterprise/ledger harness, create one in the new tests as below — mirroring `SyncsAsQboBillRoutingTest`):

```ruby
class PayStubBillLinesTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary, client_id: "x", client_secret: "y", realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ps#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @contributor)
    @cycle = PayCycle.create!(enterprise: @sanctuary, starts_at: Date.new(2032, 1, 1), ends_at: Date.new(2032, 1, 31))

    @facilities = QboChartAccount.create!(qbo_account: @qa, qbo_id: "880", name: "Facilities Management Salaries", data: {})
    QboBillAccountMapping.create!(enterprise: @sanctuary, line_item_key: "pay_stub", qbo_chart_account_qbo_id: "880")
  end

  test "bill_line_items groups lines per forecast project at the pay_stub mapping" do
    blueprint = { "lines" => [
      { "amount" => 100.0, "hours" => 2.0, "forecast_project" => 111, "description" => "a" },
      { "amount" => 50.0,  "hours" => 1.0, "forecast_project" => 111, "description" => "b" },
      { "amount" => 25.0,  "hours" => 0.5, "forecast_project" => 222, "description" => "c" },
    ] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 175, blueprint: blueprint)

    lines = stub.bill_line_items

    assert_equal 2, lines.size
    amounts = lines.map(&:amount).sort
    assert_equal [25.0, 150.0], amounts
    lines.each do |line|
      assert_equal "880", line.account_based_expense_line_detail.account_ref.value
    end
  end

  test "bill_line_items honors a project-tracker-level pay_stub override" do
    tracker = ProjectTracker.new(name: "PSO-#{SecureRandom.hex(2)}")
    tracker.save!(validate: false)
    # ForecastProject.belongs_to :forecast_client is non-optional in Rails
    # 6.1 defaults — give it a client (or fall back to save!(validate: false)).
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "PSC-#{SecureRandom.hex(2)}", data: {})
    fproj = ForecastProject.new(forecast_id: 333, client_id: fc.forecast_id, data: {})
    fproj.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: tracker, forecast_project: fproj)

    override_acct = QboChartAccount.create!(qbo_account: @qa, qbo_id: "881", name: "Special Salaries", data: {})
    QboBillAccountMapping.create!(
      enterprise: @sanctuary, line_item_key: "pay_stub",
      project_tracker: tracker, qbo_chart_account_qbo_id: "881",
    )

    blueprint = { "lines" => [
      { "amount" => 100.0, "hours" => 2.0, "forecast_project" => 333, "description" => "tracked" },
      { "amount" => 50.0,  "hours" => 1.0, "forecast_project" => 999, "description" => "untracked" },
    ] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 150, blueprint: blueprint)

    lines = stub.bill_line_items

    tracked = lines.find { |l| l.amount == 100.0 }
    untracked = lines.find { |l| l.amount == 50.0 }
    assert_equal "881", tracked.account_based_expense_line_detail.account_ref.value
    assert_equal "880", untracked.account_based_expense_line_detail.account_ref.value
  end

  test "bill_line_items raises Qbo::UnmappedLineItemError when pay_stub is unmapped" do
    QboBillAccountMapping.where(enterprise: @sanctuary, line_item_key: "pay_stub").destroy_all
    blueprint = { "lines" => [{ "amount" => 10.0, "hours" => 1.0, "forecast_project" => 111, "description" => "x" }] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 10, blueprint: blueprint)

    assert_raises(Qbo::UnmappedLineItemError) { stub.bill_line_items }
  end
end
```

Notes for the implementer:
- `ForecastProject.create!` — check the model for required fields; if `create!` fails on validations, use `.new(...).save!(validate: false)` like ProjectTracker.
- If `ProjectTrackerForecastProject` has a different class name, find it via `grep -n "has_many :project_tracker_forecast_projects" app/models/project_tracker.rb` and the corresponding model file.
- If a `PayStubTest` class already exists in this file, add this as a second class in the same file (Rails test files support multiple classes; `SyncsAsQboBillRoutingTest` does the same).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/pay_stub_test.rb`
Expected: new tests FAIL (`bill_line_items` arity / `find_qbo_account!` name match against `"Facilities Management Salaries"` no longer matching the flow)

- [ ] **Step 3: Rewrite PayStub's account routing**

In `app/models/pay_stub.rb`, delete `find_qbo_account!` (lines 65-72) and replace `bill_line_items` (lines 74-97) with:

```ruby
  def bill_line_item_key
    "pay_stub"
  end

  # Multi-line override: one line per forecast project in the blueprint.
  # Each group resolves its own account so project-tracker-level pay_stub
  # mappings apply; groups with no matching tracker resolve
  # contributor → entity default.
  def bill_line_items
    resolver = Qbo::BillAccountResolver.new(enterprise)
    lines = blueprint["lines"] || []
    grouped = lines.group_by { |l| l["forecast_project"] }

    fp_ids = grouped.keys.compact
    projects_by_id = ForecastProject.where(forecast_id: fp_ids).index_by(&:forecast_id)
    trackers = ProjectTracker.joins(:forecast_projects)
      .where(forecast_projects: { forecast_id: fp_ids }).distinct.to_a

    grouped.map do |fp_id, group|
      fp = projects_by_id[fp_id]
      project_name = fp&.display_name || "Forecast project ##{fp_id}"
      tracker = trackers.find { |pt| pt.forecast_project_ids.include?(fp_id) }
      account = resolver.account_for("pay_stub", contributor: contributor, project_tracker: tracker)

      hours = group.sum { |l| l["hours"].to_f }.round(2)
      line_amount = group.sum { |l| l["amount"].to_f }.round(2)

      line = Quickbooks::Model::BillLineItem.new(
        description: "#{project_name} — #{hours}h",
        amount: line_amount,
      )
      line.account_based_expense_item! do |detail|
        detail.account_ref = Quickbooks::Model::BaseReference.new(account.qbo_id)
      end
      line
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/pay_stub_test.rb test/models/concerns/syncs_as_qbo_bill_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/pay_stub.rb test/models/pay_stub_test.rb
git commit -m "Resolve PayStub bill lines per project tracker via the mapping engine"
```

---

### Task 9: Delete `Studio#qbo_subcontractors_categories`

**Files:**
- Modify: `app/models/studio.rb` (delete method at lines 668-673)
- Test: existing suites confirm nothing references it

- [ ] **Step 1: Verify no remaining callers**

Run: `grep -rn "qbo_subcontractors_categories" app lib test`
Expected: only the definition in `app/models/studio.rb` remains (the `syncs_as_qbo_bill.rb:50` caller was deleted in Task 6). If anything else shows up, fix it first.

- [ ] **Step 2: Delete the method**

Remove from `app/models/studio.rb`:

```ruby
  def qbo_subcontractors_categories
    return ["Total [SC] Subcontractors"] if is_garden3d?
    accounting_prefix.split(",").map(&:strip).map do |p|
      "Contractors - #{p}"
    end
  end
```

(Leave `accounting_prefix` itself alone — it's still used by P&L report parsing at `studio.rb:408-410` and by the seed service in Task 10.)

- [ ] **Step 3: Run the studio and bill-related tests**

Run: `bin/rails test test/models/studio_test.rb test/models/concerns/syncs_as_qbo_bill_test.rb` (skip the first file if it doesn't exist)
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add app/models/studio.rb
git commit -m "Delete Studio#qbo_subcontractors_categories (folded into mapping seeds)"
```

---

### Task 10: Seeding service + rake task

**Files:**
- Create: `app/services/qbo/seed_bill_account_mappings.rb`
- Modify: `lib/tasks/stacks.rake` (append task)
- Test: `test/services/qbo/seed_bill_account_mappings_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/qbo/seed_bill_account_mappings_test.rb
require "test_helper"

class Qbo::SeedBillAccountMappingsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "SeedTest-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "x", client_secret: "y", realm_id: "realm-#{SecureRandom.hex(4)}")

    # Mirror rows matching today's hard-coded targets.
    mk = ->(qbo_id, name, acct_num = nil) {
      QboChartAccount.create!(qbo_account: @qa, qbo_id: qbo_id, name: name, acct_num: acct_num, data: {})
    }
    @client_services = mk.call("1", "Contractors - Client Services")
    @marketing       = mk.call("2", "Contractors - Marketing Services")
    @bonuses         = mk.call("3", "Bonuses", "5710")
    @commissions     = mk.call("4", "Commissions", "6120")
    @profit_liab     = mk.call("5", "Accrued Profit Sharing", "2340")
    @facilities      = mk.call("6", "Facilities Management Salaries")
    @studio_acct     = mk.call("7", "Contractors - Design")
  end

  def seed!
    Qbo::SeedBillAccountMappings.new(@enterprise, sync_chart_accounts: false).call
  end

  def default_mapping(key)
    QboBillAccountMapping.find_by(
      enterprise: @enterprise, line_item_key: key,
      contributor_id: nil, project_tracker_id: nil,
    )
  end

  test "seeds entity defaults matching the legacy hard-coded routing" do
    seed!

    assert_equal "1", default_mapping("payout_individual_contributor").qbo_chart_account_qbo_id
    assert_equal "1", default_mapping("payout_account_lead_base").qbo_chart_account_qbo_id
    assert_equal "1", default_mapping("payout_project_lead_base").qbo_chart_account_qbo_id
    assert_equal "1", default_mapping("trueup").qbo_chart_account_qbo_id
    assert_equal "1", default_mapping("contributor_adjustment").qbo_chart_account_qbo_id
    assert_equal "3", default_mapping("payout_account_lead_surplus").qbo_chart_account_qbo_id
    assert_equal "3", default_mapping("payout_project_lead_surplus").qbo_chart_account_qbo_id
    assert_equal "4", default_mapping("payout_commission").qbo_chart_account_qbo_id
    assert_equal "5", default_mapping("profit_share").qbo_chart_account_qbo_id
    assert_equal "6", default_mapping("pay_stub").qbo_chart_account_qbo_id
  end

  test "profit_share falls back to the contractor default when acct 2340 is absent (legacy parity)" do
    @profit_liab.destroy!
    seed!
    assert_equal "1", default_mapping("profit_share").qbo_chart_account_qbo_id
  end

  test "is idempotent" do
    seed!
    before = QboBillAccountMapping.count
    result = seed!
    assert_equal before, QboBillAccountMapping.count
    assert_equal 0, result[:created]
  end

  test "skips (and reports) keys whose account is missing from the mirror" do
    @facilities.destroy!
    result = seed!
    assert_nil default_mapping("pay_stub")
    assert result[:skipped].any? { |s| s.include?("pay_stub") }
  end

  test "snapshots studio routing into contributor-level rows" do
    studio = Studio.create!(name: "DesignCo-#{SecureRandom.hex(2)}", accounting_prefix: "Design, Other", mini_name: "dc#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "s#{SecureRandom.hex(2)}@x.com", roles: [studio.name], data: {})
    contributor = Contributor.create!(forecast_person: fp)

    seed!

    row = QboBillAccountMapping.find_by(
      enterprise: @enterprise, line_item_key: "trueup", contributor: contributor,
    )
    assert_not_nil row, "expected a contributor-level studio snapshot row"
    assert_equal "7", row.qbo_chart_account_qbo_id, "first accounting_prefix entry wins (Contractors - Design)"
    assert_equal 5, QboBillAccountMapping.where(enterprise: @enterprise, contributor: contributor).count,
      "five contractor-services kinds snapshotted"
  end

  test "maps internal-client project trackers to Marketing Services" do
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Internal-#{SecureRandom.hex(2)}", data: {})
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client: fc)
    fproj = ForecastProject.create!(forecast_id: rand(1..2_000_000_000), client_id: fc.forecast_id, data: {})
    tracker = ProjectTracker.new(name: "INT-#{SecureRandom.hex(2)}")
    tracker.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: tracker, forecast_project: fproj)

    seed!

    %w[payout_individual_contributor payout_account_lead_base payout_project_lead_base].each do |key|
      row = QboBillAccountMapping.find_by(enterprise: @enterprise, line_item_key: key, project_tracker: tracker)
      assert_not_nil row, "expected tracker-level #{key} mapping"
      assert_equal "2", row.qbo_chart_account_qbo_id
    end
  end
end
```

Implementer notes:
- `ForecastPerson#studio` matches `roles` against `Studio#name` (see `forecast_person.rb:192-198`), hence `roles: [studio.name]` above.
- Check `Studio` for required attributes/validations before relying on `Studio.create!`; adjust to `save!(validate: false)` if needed.
- Same for `ForecastClient` / `ForecastProject` / `EnterpriseForecastClient` — check each model's validations and use the minimal valid attributes; `data: {}` columns exist on Forecast-synced models.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/qbo/seed_bill_account_mappings_test.rb`
Expected: FAIL with `NameError: uninitialized constant Qbo::SeedBillAccountMappings`

- [ ] **Step 3: Write the seed service**

```ruby
# app/services/qbo/seed_bill_account_mappings.rb
module Qbo
  # One-time, idempotent seeding of QboBillAccountMapping rows that
  # reproduce the legacy hard-coded account routing. Run via
  #   rake stacks:seed_qbo_bill_account_mappings
  # after deploying the mapping engine. Safe to re-run: existing rows are
  # never modified, only missing ones created.
  #
  # Reproduces (per enterprise with a connected QboAccount):
  # - Entity defaults: the five contractor-services kinds → "Contractors -
  #   Client Services"; surpluses → acct 5710; commission → 6120;
  #   profit_share → acct 2340 (falling back to the contractor default,
  #   matching ProfitShare's legacy fallback); pay_stub → "Facilities
  #   Management Salaries".
  # - Contributor-level snapshot of studio routing (the deleted
  #   Studio#qbo_subcontractors_categories): contributors whose studio has
  #   an accounting_prefix get the five contractor-services kinds mapped to
  #   "Contractors - <first prefix>" (garden3d: "Total [SC] Subcontractors").
  # - Project-tracker-level Marketing routing for trackers whose forecast
  #   clients are all internal to the enterprise (the deleted
  #   ContributorPayout#find_qbo_account! internal-client override).
  #
  # Accounts missing from the mirror are skipped and reported — affected
  # line kinds then fail strictly at sync time, which is the agreed
  # behavior.
  class SeedBillAccountMappings
    CONTRACTOR_SERVICES_KEYS = %w[
      payout_individual_contributor
      payout_account_lead_base
      payout_project_lead_base
      trueup
      contributor_adjustment
    ].freeze

    INTERNAL_CLIENT_KEYS = %w[
      payout_individual_contributor
      payout_account_lead_base
      payout_project_lead_base
    ].freeze

    def self.call(sync_chart_accounts: true)
      Enterprise.all.map do |enterprise|
        new(enterprise, sync_chart_accounts: sync_chart_accounts).call
      end
    end

    def initialize(enterprise, sync_chart_accounts: true)
      @enterprise = enterprise
      @sync_chart_accounts = sync_chart_accounts
      @created = 0
      @skipped = []
    end

    def call
      qa = enterprise.qbo_account
      if qa.nil?
        return { enterprise: enterprise.name, created: 0, skipped: ["no connected QboAccount"] }
      end

      qa.sync_all_chart_accounts! if @sync_chart_accounts
      @chart = QboChartAccount.active.where(qbo_account_id: qa.id).to_a

      seed_entity_defaults
      seed_contributor_studio_snapshots
      seed_internal_project_trackers

      { enterprise: enterprise.name, created: @created, skipped: @skipped }
    end

    private

    attr_reader :enterprise

    def by_name(name)
      @chart.find { |a| a.name == name }
    end

    def by_acct_num(num)
      @chart.find { |a| a.acct_num == num }
    end

    def seed_entity_defaults
      client_services = by_name("Contractors - Client Services")
      CONTRACTOR_SERVICES_KEYS.each { |key| upsert(key, client_services) }

      bonuses = by_acct_num("5710")
      upsert("payout_account_lead_surplus", bonuses)
      upsert("payout_project_lead_surplus", bonuses)
      upsert("payout_commission", by_acct_num("6120"))

      # Legacy parity: ProfitShare fell back to the contractor default when
      # acct 2340 was missing from the realm.
      upsert("profit_share", by_acct_num("2340") || client_services)
      upsert("pay_stub", by_name("Facilities Management Salaries"))
    end

    def seed_contributor_studio_snapshots
      Contributor.find_each do |contributor|
        studio = contributor.forecast_person&.studio
        next if studio.nil?

        account = studio_account(studio)
        next if account.nil?

        CONTRACTOR_SERVICES_KEYS.each { |key| upsert(key, account, contributor: contributor) }
      end
    end

    # Inlined from the deleted Studio#qbo_subcontractors_categories: the
    # studio's first accounting_prefix entry names its contractor expense
    # account; garden3d used a hard-coded rollup name.
    def studio_account(studio)
      return by_name("Total [SC] Subcontractors") if studio.is_garden3d?

      prefix = studio.accounting_prefix.to_s.split(",").map(&:strip).first
      return nil if prefix.blank?
      by_name("Contractors - #{prefix}")
    end

    def seed_internal_project_trackers
      marketing = by_name("Contractors - Marketing Services")
      if marketing.nil?
        @skipped << "internal project trackers: 'Contractors - Marketing Services' not in mirror"
        return
      end

      ProjectTracker.includes(forecast_projects: :forecast_client).find_each do |pt|
        clients = pt.forecast_projects.map(&:forecast_client).compact.uniq
        next if clients.empty?
        next unless clients.all? { |c| c.enterprise_forecast_client&.enterprise_id == enterprise.id }

        INTERNAL_CLIENT_KEYS.each { |key| upsert(key, marketing, project_tracker: pt) }
      end
    end

    def upsert(key, chart_account, contributor: nil, project_tracker: nil)
      if chart_account.nil?
        subject = contributor ? " (contributor ##{contributor.id})" : project_tracker ? " (tracker ##{project_tracker.id})" : ""
        @skipped << "#{key}#{subject}: account not found in mirror"
        return
      end

      existing = QboBillAccountMapping.find_by(
        enterprise_id: enterprise.id,
        line_item_key: key,
        contributor_id: contributor&.id,
        project_tracker_id: project_tracker&.id,
      )
      return if existing.present?

      QboBillAccountMapping.create!(
        enterprise: enterprise,
        line_item_key: key,
        contributor: contributor,
        project_tracker: project_tracker,
        qbo_chart_account_qbo_id: chart_account.qbo_id,
      )
      @created += 1
    end
  end
end
```

(Ruby parsing note: the nested ternary in `upsert` needs the parentheses-free form above to stay unambiguous; if RuboCop or the parser complains, rewrite as an explicit `if/elsif`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/qbo/seed_bill_account_mappings_test.rb`
Expected: PASS (6 tests)

- [ ] **Step 5: Add the rake task**

Append inside the `namespace :stacks do` block in `lib/tasks/stacks.rake`:

```ruby
  desc "Seed QBO bill account mappings from the legacy hard-coded routing (idempotent)"
  task :seed_qbo_bill_account_mappings => :environment do
    results = Qbo::SeedBillAccountMappings.call
    results.each do |r|
      puts "#{r[:enterprise]}: created #{r[:created]} mapping(s), #{r[:skipped].size} skipped"
      r[:skipped].each { |s| puts "  skipped: #{s}" }
    end
  end
```

- [ ] **Step 6: Commit**

```bash
git add app/services/qbo/seed_bill_account_mappings.rb test/services/qbo/seed_bill_account_mappings_test.rb lib/tasks/stacks.rake
git commit -m "Add idempotent seeding of bill account mappings from legacy routing"
```

---

### Task 11: Admin UI

**Files:**
- Create: `app/admin/qbo_bill_account_mappings.rb`
- Modify: `app/admin/enterprises.rb` (mappings panel in show)
- Modify: `app/admin/project_trackers.rb` (sidebar)
- Modify: `app/admin/contributors.rb` (sidebar)

No automated tests (admin pages are untested in this codebase). Verify by `bin/rails runner 'Rails.application.eager_load!'` (catches syntax/constant errors in admin files) plus manual QA post-deploy.

- [ ] **Step 1: Create the ActiveAdmin resource**

```ruby
# app/admin/qbo_bill_account_mappings.rb
ActiveAdmin.register QboBillAccountMapping do
  menu label: "QBO Account Mappings", parent: "Enterprises"
  actions :index, :show, :new, :create, :edit, :update, :destroy
  permit_params :enterprise_id, :line_item_key, :project_tracker_id, :contributor_id, :qbo_chart_account_qbo_id

  controller do
    # Supports prefilled "Add override" links from the Enterprise /
    # ProjectTracker / Contributor pages.
    def build_new_resource
      super.tap do |r|
        if params[:qbo_bill_account_mapping].present?
          r.assign_attributes(
            params.require(:qbo_bill_account_mapping)
              .permit(:enterprise_id, :line_item_key, :project_tracker_id, :contributor_id),
          )
        end
      end
    end
  end

  index download_links: false do
    column :enterprise
    column("Line item", :line_item_key)
    column("Subject") { |m| m.subject_label }
    column("QBO account") { |m| m.chart_account&.display_label || m.qbo_chart_account_qbo_id }
    actions
  end

  filter :enterprise
  filter :line_item_key, as: :select, collection: QboBillAccountMapping::LINE_ITEM_KEYS
  filter :project_tracker
  filter :contributor

  show do
    attributes_table do
      row :enterprise
      row :line_item_key
      row("Subject") { |m| m.subject_label }
      row("QBO account") { |m| m.chart_account&.display_label || m.qbo_chart_account_qbo_id }
      row :created_at
      row :updated_at
    end
  end

  form do |f|
    # When the enterprise is already known (edit, or prefilled new), scope
    # the chart-account options to its realm. qbo_ids are NOT unique across
    # realms, so the unscoped fallback prefixes each option with its
    # enterprise name — pick one matching the enterprise selected above
    # (validation rejects ids absent from the chosen enterprise's realm,
    # but cannot catch an id that exists in both realms).
    known_enterprise = f.object.enterprise
    chart_options =
      if known_enterprise&.qbo_account
        QboChartAccount.active
          .where(qbo_account_id: known_enterprise.qbo_account.id)
          .order(:name)
          .map { |a| [a.display_label, a.qbo_id] }
      else
        QboChartAccount.active
          .includes(qbo_account: :enterprise)
          .sort_by { |a| [a.qbo_account.enterprise&.name.to_s, a.name] }
          .map { |a| ["#{a.qbo_account.enterprise&.name} — #{a.display_label}", a.qbo_id] }
      end

    f.inputs(class: "admin_inputs") do
      f.semantic_errors
      f.input :enterprise, as: :select,
        collection: Enterprise.order(:name).pluck(:name, :id),
        include_blank: false
      f.input :line_item_key, as: :select,
        collection: QboBillAccountMapping::LINE_ITEM_KEYS,
        include_blank: false
      f.input :project_tracker_id, as: :select,
        collection: ProjectTracker.order(:name).pluck(:name, :id),
        include_blank: "(none — leave blank unless this is a project-tracker override)"
      f.input :contributor_id, as: :select,
        collection: Contributor.all.map { |c| [c.display_name, c.id] },
        include_blank: "(none — leave blank unless this is a contributor override)",
        hint: "Set a project tracker OR a contributor, not both. Both blank = entity-level default."
      f.input :qbo_chart_account_qbo_id, as: :select,
        collection: chart_options,
        include_blank: "Choose a QBO account…",
        label: "QBO chart account"
    end
    f.actions
  end
end
```

- [ ] **Step 2: Add the mappings panel to the Enterprise show page**

In `app/admin/enterprises.rb`, inside the `show do` block, immediately after the QBO-not-connected guard (`next` branch) and before `COLORS = Stacks::Utils::COLORS`, insert:

```ruby
    panel "QBO Bill Account Mappings" do
      defaults = QboBillAccountMapping
        .where(enterprise: resource, contributor_id: nil, project_tracker_id: nil)
        .index_by(&:line_item_key)
      chart_by_qbo_id = QboChartAccount
        .where(qbo_account_id: resource.qbo_account.id)
        .index_by(&:qbo_id)

      table_for QboBillAccountMapping::LINE_ITEM_KEYS do
        column("Line item") { |key| key }
        column("Entity default account") do |key|
          m = defaults[key]
          if m.nil?
            status_tag("unmapped", class: "error")
          else
            chart_by_qbo_id[m.qbo_chart_account_qbo_id]&.display_label || m.qbo_chart_account_qbo_id
          end
        end
        column("") do |key|
          m = defaults[key]
          if m
            link_to "Edit", edit_admin_qbo_bill_account_mapping_path(m)
          else
            link_to "Set", new_admin_qbo_bill_account_mapping_path(
              qbo_bill_account_mapping: { enterprise_id: resource.id, line_item_key: key },
            )
          end
        end
      end

      overrides = QboBillAccountMapping
        .where(enterprise: resource)
        .where("contributor_id IS NOT NULL OR project_tracker_id IS NOT NULL")
        .includes(:contributor, :project_tracker)
      if overrides.any?
        h4 "Overrides (#{overrides.size})"
        table_for overrides.first(25) do
          column("Subject") { |m| m.subject_label }
          column("Line item", :line_item_key)
          column("Account") { |m| chart_by_qbo_id[m.qbo_chart_account_qbo_id]&.display_label || m.qbo_chart_account_qbo_id }
          column("") { |m| link_to "Edit", edit_admin_qbo_bill_account_mapping_path(m) }
        end
      end

      div do
        link_to "All mappings for this enterprise →",
          admin_qbo_bill_account_mappings_path(q: { enterprise_id_eq: resource.id })
      end
    end
```

- [ ] **Step 3: Add sidebars to ProjectTracker and Contributor pages**

In `app/admin/project_trackers.rb`, add at the top level of the `ActiveAdmin.register ProjectTracker do` block (read the file first to place it alongside any existing `sidebar` calls):

```ruby
  sidebar "QBO Bill Account Mappings", only: :show do
    mappings = QboBillAccountMapping.where(project_tracker_id: resource.id).includes(:enterprise)
    if mappings.any?
      table_for mappings do
        column("Enterprise") { |m| m.enterprise.name }
        column("Line item", :line_item_key)
        column("Account") { |m| m.chart_account&.display_label || m.qbo_chart_account_qbo_id }
        column("") { |m| link_to "Edit", edit_admin_qbo_bill_account_mapping_path(m) }
      end
    else
      para "No project-specific account overrides."
    end
    div do
      link_to "Add override", new_admin_qbo_bill_account_mapping_path(
        qbo_bill_account_mapping: { project_tracker_id: resource.id },
      )
    end
  end
```

In `app/admin/contributors.rb`, the same shape:

```ruby
  sidebar "QBO Bill Account Mappings", only: :show do
    mappings = QboBillAccountMapping.where(contributor_id: resource.id).includes(:enterprise)
    if mappings.any?
      table_for mappings do
        column("Enterprise") { |m| m.enterprise.name }
        column("Line item", :line_item_key)
        column("Account") { |m| m.chart_account&.display_label || m.qbo_chart_account_qbo_id }
        column("") { |m| link_to "Edit", edit_admin_qbo_bill_account_mapping_path(m) }
      end
    else
      para "No contributor-specific account overrides."
    end
    div do
      link_to "Add override", new_admin_qbo_bill_account_mapping_path(
        qbo_bill_account_mapping: { contributor_id: resource.id },
      )
    end
  end
```

- [ ] **Step 4: Eager-load check**

Run: `bin/rails runner 'Rails.application.eager_load!; puts "OK"'`
Expected: prints `OK` with no constant/syntax errors.

- [ ] **Step 5: Commit**

```bash
git add app/admin/qbo_bill_account_mappings.rb app/admin/enterprises.rb app/admin/project_trackers.rb app/admin/contributors.rb
git commit -m "Add admin UI for QBO bill account mappings"
```

---

### Task 12: Spec amendments, full suite, rollout notes

**Files:**
- Modify: `docs/superpowers/specs/2026-06-10-qbo-bill-account-mapping-engine-design.md`

- [ ] **Step 1: Amend the spec to match implementation decisions**

In the spec document:

(a) In §2 (`QboBillAccountMapping`), replace the `subject_type`/`subject_id` polymorphic bullet with the explicit nullable FK columns (`project_tracker_id`, `contributor_id`, at most one set, check constraint + three partial unique indexes), with a one-line rationale (FK integrity; Postgres unique indexes treat NULLs as distinct).

(b) In §5 (Seeding), change "seeding migration" to "seeding service `Qbo::SeedBillAccountMappings` + `rake stacks:seed_qbo_bill_account_mappings`", with the rationale (live QBO API calls don't belong in migrations; idempotent and re-runnable).

(c) Add to "Decision notes & accepted behavior changes":

```markdown
- **Internal-project routing nuance:** the legacy internal-client override
  only applied when the contributor's studio was nil or client-services;
  seeded tracker-level Marketing mappings win over contributor-level studio
  snapshots unconditionally (tracker beats contributor). Contributors in
  non-client-services studios working on internal projects therefore now
  route to Marketing where they previously kept their studio account.
  Accepted: fix per-case by deleting the tracker mapping or adding a more
  specific one if it matters in practice.
```

- [ ] **Step 2: Run the full test suite**

Run: `bin/rails test`
Expected: PASS (no failures beyond any that pre-exist on the base branch — if unsure, compare against `git stash`-free baseline or the branch point).

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-06-10-qbo-bill-account-mapping-engine-design.md
git commit -m "Amend spec: explicit subject FKs, seed-via-rake, internal-routing nuance"
```

- [ ] **Step 4: Rollout checklist (goes in the PR description)**

```markdown
1. Deploy.
2. Run `rake stacks:seed_qbo_bill_account_mappings`; review the created/skipped output per enterprise.
3. In admin, open each Enterprise → check the "QBO Bill Account Mappings" panel shows no `unmapped` tags (or deliberately leave unmapped kinds that enterprise never bills).
4. Trigger one bill sync per host type (CP / Trueup / CA / PS / PayStub) on a staging-safe record and verify line accounts in QBO match the pre-deploy behavior.
5. Watch logs for Qbo::UnmappedLineItemError and the chart-sync deactivation warnings over the first daily-task run.
```
