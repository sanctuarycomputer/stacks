# Pay Cycles & Pay Stubs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate contributor pay from Forecast hours for work billed against `is_internal?` forecast clients, via a new `PayCycle` → `PayStub` flow that coexists with the existing `InvoiceTracker → ContributorPayout` flow.

**Architecture:** Two new models. `PayCycle` is a per-`(enterprise, date_range)` container with computed status. `PayStub` is a first-class `LedgerItem` sibling to `ContributorPayout` — same Ledger landing, same `SyncsAsQboBill` plumbing, distinct from CP because the pay-stub world has no client invoice, no role-allocation blueprint, and no 70% cap. Stub generation pulls forecast assignments overlapping the cycle window, pro-rates them via the existing `ForecastAssignment#allocation_during_range_in_hours`, and groups by contributor.

**Tech Stack:** Rails 6.1, PostgreSQL, ActiveAdmin 2.9.0, Formtastic, paranoia (`acts_as_paranoid`), minitest.

---

## File Structure

**Created**
- `db/migrate/<TS>_create_pay_cycles_and_pay_stubs.rb` — schema for both tables + `enterprises.pay_cycle_cadence`.
- `app/models/pay_cycle.rb` — the container model.
- `app/models/pay_stub.rb` — the LedgerItem.
- `app/services/pay_cycles/generate_stubs.rb` — generation service (kept out of the AR model to keep `PayCycle` thin).
- `app/admin/pay_cycles.rb` — nested under Enterprise.
- `app/admin/pay_stubs.rb` — nested under PayCycle.
- `app/views/admin/pay_cycles/_show.html.erb` — show partial (cycle header + stubs table).
- `app/views/admin/pay_stubs/_show.html.erb` — show partial (line items table + accept toggle).
- `app/views/admin/enterprises/_pay_cycles_section.html.erb` — section embedded in enterprise show.
- `test/models/pay_cycle_test.rb`
- `test/models/pay_stub_test.rb`
- `test/services/pay_cycles/generate_stubs_test.rb`

**Modified**
- `app/models/enterprise.rb` — adds `has_many :pay_cycles`, accessor for `pay_cycle_cadence`, helper `pay_cycle_default_range_for(date)`.
- `app/models/ledger.rb` — `visible_items` and `all_items_with_deleted` include `pay_stubs`; `items_grouped_by_month` total_income picks up PayStub.
- `app/models/contributor.rb` — `has_many :pay_stubs, through: :ledgers`; `pay_stubs_with_deleted`; `preload_for_ledger_view!`; `new_deal_balance` switch.
- `app/admin/enterprises.rb` — adds `pay_cycle_cadence` form input + permits it; embeds pay_cycles section in show.
- `app/models/invoice_tracker.rb` — `make_contributor_payouts!` preserves `accepted_at` when amount unchanged (the CP fix).
- `config/routes.rb` — no manual change expected; ActiveAdmin auto-mounts pay_cycles/pay_stubs.

---

## Phase 0 — Branch & baseline

### Task 0: Confirm baseline

**Files:** none.

- [ ] **Step 0.1: Confirm you're on `feat/pay-stubs` off main**

Run:
```bash
git status
git branch --show-current
```
Expected: clean working tree, branch `feat/pay-stubs`. (The pay-stubs spec is already committed on this branch; the multi-enterprise spec lives uncommitted in the working tree from the prior session — leave it alone.)

- [ ] **Step 0.2: Run the full test suite to capture a green baseline**

Run:
```bash
bin/rails test
```
Expected: green. If anything fails, stop and report — don't proceed on a red baseline.

---

## Phase 1 — Schema

### Task 1: Migration for pay_cycles, pay_stubs, and enterprises.pay_cycle_cadence

**Files:**
- Create: `db/migrate/<TS>_create_pay_cycles_and_pay_stubs.rb` (generate with `bin/rails g`)

- [ ] **Step 1.1: Generate the migration shell**

Run:
```bash
bin/rails g migration CreatePayCyclesAndPayStubs
```

- [ ] **Step 1.2: Replace the generated file's contents**

Open the new file under `db/migrate/`. Replace its body with:

```ruby
class CreatePayCyclesAndPayStubs < ActiveRecord::Migration[6.1]
  def change
    create_table :pay_cycles do |t|
      t.references :enterprise, null: false, foreign_key: true
      t.date :starts_at, null: false
      t.date :ends_at, null: false
      t.references :created_by, foreign_key: { to_table: :admin_users }
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :pay_cycles, [:enterprise_id, :starts_at, :ends_at], unique: true, name: "index_pay_cycles_unique_window"
    add_index :pay_cycles, :deleted_at

    create_table :pay_stubs do |t|
      t.references :pay_cycle, null: false, foreign_key: true
      t.references :ledger, null: false, foreign_key: true
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.jsonb :blueprint, null: false, default: {}
      t.datetime :accepted_at
      t.references :accepted_by, foreign_key: { to_table: :admin_users }
      t.string :qbo_bill_id
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :pay_stubs, [:pay_cycle_id, :ledger_id], unique: true, name: "index_pay_stubs_unique_per_cycle_ledger"
    add_index :pay_stubs, :deleted_at
    add_index :pay_stubs, :qbo_bill_id, unique: true, where: "qbo_bill_id IS NOT NULL"

    add_column :enterprises, :pay_cycle_cadence, :string
  end
end
```

- [ ] **Step 1.3: Run the migration**

Run:
```bash
bin/rails db:migrate
```
Expected: two new tables, one new nullable column, schema.rb updated.

- [ ] **Step 1.4: Commit**

```bash
git add db/migrate/*_create_pay_cycles_and_pay_stubs.rb db/schema.rb
git commit -m "Add pay_cycles, pay_stubs, enterprises.pay_cycle_cadence"
```

---

## Phase 2 — Enterprise cadence helpers

### Task 2: Enterprise gains `pay_cycle_cadence` accessor and default-range helper

**Files:**
- Modify: `app/models/enterprise.rb`
- Test: `test/models/enterprise_test.rb`

- [ ] **Step 2.1: Write failing tests**

Append to `test/models/enterprise_test.rb`:

```ruby
class EnterprisePayCycleCadenceTest < ActiveSupport::TestCase
  setup do
    @ent = Enterprise.create!(name: "Test Enterprise #{SecureRandom.hex(4)}")
  end

  test "pay_cycle_cadence is nullable" do
    assert_nil @ent.pay_cycle_cadence
  end

  test "pay_cycle_default_range_for monthly returns the whole calendar month" do
    @ent.update!(pay_cycle_cadence: "monthly")
    range = @ent.pay_cycle_default_range_for(Date.new(2026, 5, 20))
    assert_equal Date.new(2026, 5, 1), range.first
    assert_equal Date.new(2026, 5, 31), range.last
  end

  test "pay_cycle_default_range_for twice_monthly returns first half when day <= 15" do
    @ent.update!(pay_cycle_cadence: "twice_monthly")
    range = @ent.pay_cycle_default_range_for(Date.new(2026, 5, 15))
    assert_equal Date.new(2026, 5, 1), range.first
    assert_equal Date.new(2026, 5, 15), range.last
  end

  test "pay_cycle_default_range_for twice_monthly returns second half when day >= 16" do
    @ent.update!(pay_cycle_cadence: "twice_monthly")
    range = @ent.pay_cycle_default_range_for(Date.new(2026, 5, 16))
    assert_equal Date.new(2026, 5, 16), range.first
    assert_equal Date.new(2026, 5, 31), range.last
  end

  test "pay_cycle_default_range_for returns nil when cadence is unset" do
    assert_nil @ent.pay_cycle_default_range_for(Date.new(2026, 5, 20))
  end
end
```

- [ ] **Step 2.2: Run the tests; expect failures**

```bash
bin/rails test test/models/enterprise_test.rb -n /PayCycleCadence/
```
Expected: NoMethodError on `pay_cycle_default_range_for`.

- [ ] **Step 2.3: Implement on Enterprise**

Open `app/models/enterprise.rb`. Just below the existing `has_many :enterprise_forecast_clients` (or wherever the associations block ends), add:

```ruby
  has_many :pay_cycles, dependent: :destroy

  # Returns a Date range to pre-fill a new PayCycle's starts_at/ends_at,
  # or nil if this enterprise hasn't been configured to run pay cycles.
  # "monthly"      → entire calendar month containing `date`
  # "twice_monthly" → 1..15 of `date`'s month if date.day <= 15, else 16..end_of_month
  def pay_cycle_default_range_for(date)
    case pay_cycle_cadence
    when "monthly"
      date.beginning_of_month..date.end_of_month
    when "twice_monthly"
      if date.day <= 15
        date.beginning_of_month..(date.beginning_of_month + 14)
      else
        (date.beginning_of_month + 15)..date.end_of_month
      end
    else
      nil
    end
  end
```

- [ ] **Step 2.4: Tests pass**

```bash
bin/rails test test/models/enterprise_test.rb -n /PayCycleCadence/
```
Expected: 5 passing.

- [ ] **Step 2.5: Commit**

```bash
git add app/models/enterprise.rb test/models/enterprise_test.rb
git commit -m "Enterprise: pay_cycle_cadence accessor + default-range helper"
```

---

## Phase 3 — PayCycle model

### Task 3: PayCycle associations, validations, and stubs_status

**Files:**
- Create: `app/models/pay_cycle.rb`
- Create: `test/models/pay_cycle_test.rb`

- [ ] **Step 3.1: Write failing tests**

Create `test/models/pay_cycle_test.rb`:

```ruby
require "test_helper"

class PayCycleTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "G3D Test #{SecureRandom.hex(2)}")
    @starts = Date.new(2026, 5, 1)
    @ends = Date.new(2026, 5, 31)
  end

  test "valid with enterprise, starts_at, ends_at" do
    pc = PayCycle.new(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    assert pc.valid?, pc.errors.full_messages.inspect
  end

  test "requires starts_at <= ends_at" do
    pc = PayCycle.new(enterprise: @enterprise, starts_at: @ends, ends_at: @starts)
    refute pc.valid?
    assert_includes pc.errors[:ends_at], "must be on or after starts_at"
  end

  test "uniqueness on (enterprise_id, starts_at, ends_at)" do
    PayCycle.create!(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    dup = PayCycle.new(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    refute dup.valid?
  end

  test "stubs_status returns :no_stubs when there are no pay_stubs" do
    pc = PayCycle.create!(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    assert_equal :no_stubs, pc.stubs_status
  end

  test "acts_as_paranoid soft-deletes" do
    pc = PayCycle.create!(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    pc.destroy
    assert pc.deleted_at.present?
    assert_equal 0, PayCycle.where(id: pc.id).count
    assert_equal 1, PayCycle.with_deleted.where(id: pc.id).count
  end
end
```

- [ ] **Step 3.2: Run; expect failures**

```bash
bin/rails test test/models/pay_cycle_test.rb
```
Expected: NameError: uninitialized constant PayCycle.

- [ ] **Step 3.3: Implement PayCycle**

Create `app/models/pay_cycle.rb`:

```ruby
class PayCycle < ApplicationRecord
  acts_as_paranoid

  belongs_to :enterprise
  belongs_to :created_by, class_name: "AdminUser", optional: true
  has_many :pay_stubs, dependent: :destroy

  validates :starts_at, :ends_at, presence: true
  validates :enterprise_id, uniqueness: { scope: [:starts_at, :ends_at] }
  validate :ends_at_on_or_after_starts_at

  # Computed status across this cycle's stubs.
  #   :no_stubs       → no stubs have been generated yet
  #   :some_pending   → at least one stub is unaccepted
  #   :all_accepted   → every stub is accepted (implicit lock)
  def stubs_status
    return :no_stubs unless pay_stubs.exists?
    pay_stubs.where(accepted_at: nil).none? ? :all_accepted : :some_pending
  end

  private

  def ends_at_on_or_after_starts_at
    return if starts_at.blank? || ends_at.blank?
    errors.add(:ends_at, "must be on or after starts_at") if ends_at < starts_at
  end
end
```

- [ ] **Step 3.4: Tests pass**

```bash
bin/rails test test/models/pay_cycle_test.rb
```
Expected: 5 passing.

- [ ] **Step 3.5: Commit**

```bash
git add app/models/pay_cycle.rb test/models/pay_cycle_test.rb
git commit -m "Add PayCycle model with stubs_status"
```

---

## Phase 4 — PayStub model

### Task 4: PayStub as a LedgerItem with payable? + toggle_acceptance!

**Files:**
- Create: `app/models/pay_stub.rb`
- Create: `test/models/pay_stub_test.rb`

- [ ] **Step 4.1: Write failing tests**

Create `test/models/pay_stub_test.rb`:

```ruby
require "test_helper"

class PayStubTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "G3D-Stub-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 999_001, email: "stubtest@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
    @blueprint = { "lines" => [{ "forecast_project" => "fp-1", "hours" => 10, "rate" => 100, "amount" => 1000.0, "description" => "Test" }] }
    @admin = AdminUser.create!(email: "admin#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123")
  end

  test "valid with required fields" do
    stub = PayStub.new(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    assert stub.valid?, stub.errors.full_messages.inspect
  end

  test "delegates contributor and enterprise via LedgerItem" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    assert_equal @contributor, stub.contributor
    assert_equal @enterprise, stub.enterprise
  end

  test "uniqueness on (pay_cycle_id, ledger_id)" do
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    dup = PayStub.new(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    refute dup.valid?
  end

  test "rejects stub when pay_cycle.enterprise differs from ledger.enterprise" do
    other = Enterprise.find_or_create_by!(name: "Other-#{SecureRandom.hex(2)}")
    other_cycle = PayCycle.create!(enterprise: other, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
    stub = PayStub.new(pay_cycle: other_cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    refute stub.valid?
    assert_includes stub.errors[:ledger], "must belong to the same enterprise as the pay_cycle"
  end

  test "amount must equal sum of blueprint lines (within rounding)" do
    stub = PayStub.new(pay_cycle: @cycle, ledger: @ledger, amount: 999, blueprint: @blueprint)
    refute stub.valid?
    assert_includes stub.errors[:amount], "must equal the sum of blueprint['lines'] amounts"
  end

  test "accepted_at and accepted_by must be both set or both nil" do
    stub = PayStub.new(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint, accepted_at: DateTime.now)
    refute stub.valid?
    assert_includes stub.errors[:accepted_by_id], "must be set when accepted_at is set"
  end

  test "payable? requires accepted AND all stubs in cycle accepted" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    refute stub.payable?
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)
    assert_equal :all_accepted, @cycle.reload.stubs_status
    assert stub.reload.payable?
  end

  test "toggle_acceptance! flips accepted_at and tracks accepted_by" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    stub.toggle_acceptance!(by: @admin)
    assert stub.accepted?
    assert_equal @admin.id, stub.accepted_by_id
    stub.toggle_acceptance!(by: @admin)
    refute stub.accepted?
    assert_nil stub.accepted_by_id
  end

  test "toggle_acceptance! refuses unaccept when cycle is all_accepted" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint, accepted_at: DateTime.now, accepted_by: @admin)
    assert_equal :all_accepted, @cycle.reload.stubs_status
    assert_raises(RuntimeError, /Cannot unaccept/) do
      stub.toggle_acceptance!(by: @admin)
    end
  end

  test "effective_on_for_display is the cycle's ends_at" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    assert_equal @cycle.ends_at, stub.effective_on_for_display
  end
end
```

- [ ] **Step 4.2: Run; expect failures**

```bash
bin/rails test test/models/pay_stub_test.rb
```
Expected: NameError: uninitialized constant PayStub.

- [ ] **Step 4.3: Implement PayStub**

Create `app/models/pay_stub.rb`:

```ruby
class PayStub < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill

  before_destroy :detach_and_destroy_qbo_bill

  belongs_to :pay_cycle
  belongs_to :accepted_by, class_name: "AdminUser", optional: true
  belongs_to :qbo_bill, class_name: "QboBill", foreign_key: "qbo_bill_id", primary_key: "qbo_id", optional: true

  validates :amount, presence: true
  validates :blueprint, presence: true
  validate :blueprint_has_lines_array
  validate :amount_matches_blueprint_sum
  validate :ledger_enterprise_matches_pay_cycle_enterprise
  validate :acceptance_pair_consistent

  def accepted?
    accepted_at.present?
  end

  # Same pattern as ContributorPayout#toggle_acceptance! but tracks accepted_by_id.
  # Caller must pass the AdminUser doing the toggle (controllers pass current_admin_user).
  def toggle_acceptance!(by:)
    if accepted?
      raise "Cannot unaccept a pay stub once all stubs in the cycle are accepted." if pay_cycle.stubs_status == :all_accepted
      update!(accepted_at: nil, accepted_by_id: nil)
    else
      update!(accepted_at: DateTime.now, accepted_by_id: by.id)
    end
  end

  # LedgerItem contract overrides.
  def payable?
    accepted? && pay_cycle.stubs_status == :all_accepted
  end

  def effective_on_for_display
    pay_cycle.ends_at
  end

  # SyncsAsQboBill contract.
  def bill_txn_date
    pay_cycle.ends_at
  end

  def bill_description
    "https://stacks.garden3d.net/admin/pay_cycles/#{pay_cycle_id}/pay_stubs/#{id}"
  end

  def bill_doc_number_code
    "PS"
  end

  private

  def blueprint_has_lines_array
    return if blueprint.is_a?(Hash) && blueprint["lines"].is_a?(Array)
    errors.add(:blueprint, "must contain a 'lines' array")
  end

  def amount_matches_blueprint_sum
    return unless blueprint.is_a?(Hash) && blueprint["lines"].is_a?(Array)
    sum = blueprint["lines"].sum { |l| l["amount"].to_f }.round(2)
    return if (amount.to_f.round(2) - sum).abs < 0.01
    errors.add(:amount, "must equal the sum of blueprint['lines'] amounts")
  end

  def ledger_enterprise_matches_pay_cycle_enterprise
    return if ledger.blank? || pay_cycle.blank?
    return if ledger.enterprise_id == pay_cycle.enterprise_id
    errors.add(:ledger, "must belong to the same enterprise as the pay_cycle")
  end

  def acceptance_pair_consistent
    if accepted_at.present? && accepted_by_id.blank?
      errors.add(:accepted_by_id, "must be set when accepted_at is set")
    elsif accepted_at.blank? && accepted_by_id.present?
      errors.add(:accepted_at, "must be set when accepted_by_id is set")
    end
  end
end
```

- [ ] **Step 4.4: Tests pass**

```bash
bin/rails test test/models/pay_stub_test.rb
```
Expected: 10 passing.

- [ ] **Step 4.5: Commit**

```bash
git add app/models/pay_stub.rb test/models/pay_stub_test.rb
git commit -m "Add PayStub LedgerItem with payable + toggle_acceptance!"
```

---

## Phase 5 — Wire PayStub into Ledger & Contributor aggregations

### Task 5: PayStub appears in ledger aggregations

**Files:**
- Modify: `app/models/ledger.rb`
- Modify: `test/models/ledger_test.rb`

- [ ] **Step 5.1: Write failing tests**

Append to `test/models/ledger_test.rb`:

```ruby
class LedgerWithPayStubsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "LedgerStubs-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 998_001, email: "lstest@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.create!(enterprise: @enterprise, contributor: @contributor)
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
    @admin = AdminUser.create!(email: "lsadm#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123")
  end

  test "balance counts payable pay stubs" do
    blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: blueprint, accepted_at: DateTime.now, accepted_by: @admin)
    assert_equal 100, @ledger.balance.to_f
    assert_equal 0, @ledger.unsettled.to_f
  end

  test "unsettled counts un-payable pay stubs" do
    blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: blueprint)  # not accepted
    assert_equal 0, @ledger.balance.to_f
    assert_equal 100, @ledger.unsettled.to_f
  end

  test "all_items_with_deleted includes soft-deleted pay stubs" do
    blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: blueprint)
    stub.destroy
    grouped = @ledger.items_grouped_by_month
    assert_includes grouped[:all].map(&:id), stub.id
  end
end
```

- [ ] **Step 5.2: Run; expect failures**

```bash
bin/rails test test/models/ledger_test.rb -n /WithPayStubs/
```
Expected: `balance` returns 0 (pay stubs not yet wired in) → first test fails.

- [ ] **Step 5.3: Wire pay_stubs into Ledger**

Edit `app/models/ledger.rb`. Add `has_many :pay_stubs` alongside other has_many lines (after `has_many :deel_invoice_adjustments`):

```ruby
  has_many :pay_stubs
```

Update `visible_items` (currently lines 69-78) to include pay_stubs:

```ruby
  def visible_items
    [
      contributor_payouts.to_a,
      contributor_adjustments.to_a,
      trueups.to_a,
      reimbursements.to_a,
      profit_shares.to_a,
      deel_invoice_adjustments.to_a,
      pay_stubs.to_a,
    ].flatten
  end
```

Update `all_items_with_deleted` (currently lines 81-90):

```ruby
  def all_items_with_deleted
    [
      ContributorPayout.with_deleted.includes(invoice_tracker: :invoice_pass).where(ledger_id: id).to_a,
      ContributorAdjustment.with_deleted.where(ledger_id: id).to_a,
      Trueup.with_deleted.includes(:invoice_pass).where(ledger_id: id).to_a,
      Reimbursement.with_deleted.where(ledger_id: id).to_a,
      ProfitShare.with_deleted.includes(:periodic_report).where(ledger_id: id).to_a,
      DeelInvoiceAdjustment.with_deleted.where(ledger_id: id).to_a,
      PayStub.with_deleted.includes(:pay_cycle).where(ledger_id: id).to_a,
    ].flatten
  end
```

Update `items_grouped_by_month` total_income calculation (currently lines 53-55) to include PayStub:

```ruby
      total_income = sorted.sum do |li|
        (li.is_a?(ContributorPayout) || li.is_a?(Trueup) || li.is_a?(PayStub)) ? li.amount.to_f : 0
      end
```

- [ ] **Step 5.4: Tests pass**

```bash
bin/rails test test/models/ledger_test.rb -n /WithPayStubs/
```
Expected: 3 passing.

- [ ] **Step 5.5: Commit**

```bash
git add app/models/ledger.rb test/models/ledger_test.rb
git commit -m "Ledger: include PayStub in visible_items, all_items_with_deleted, total_income"
```

### Task 6: PayStub appears in Contributor aggregations + preload

**Files:**
- Modify: `app/models/contributor.rb`

- [ ] **Step 6.1: Add `has_many :pay_stubs, through: :ledgers`**

Edit `app/models/contributor.rb`, after the existing `has_many :deel_invoice_adjustments, through: :ledgers` (around line 15):

```ruby
  has_many :pay_stubs, through: :ledgers
```

- [ ] **Step 6.2: Add `pay_stubs_with_deleted` memoized method**

Below `deel_invoice_adjustments_with_deleted` (around line 52), add:

```ruby
  def pay_stubs_with_deleted
    @_pay_stubs_with_deleted ||=
      PayStub.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id }).to_a
  end
```

- [ ] **Step 6.3: Add PayStub to `preload_for_ledger_view!`**

Inside `preload_for_ledger_view!` (around line 60), after the `@_deel_invoice_adjustments_with_deleted = ...` assignment, add:

```ruby
    @_pay_stubs_with_deleted =
      PayStub.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id })
        .includes(:ledger, :pay_cycle).to_a
```

Then include it in the contributor-target-stamping loop (the `[@_..., @_..., ...].each do |items|` block):

```ruby
    [
      @_contributor_payouts_with_deleted,
      @_contributor_adjustments_with_deleted,
      @_trueups_with_deleted,
      @_reimbursements_with_deleted,
      @_profit_shares_with_deleted,
      @_deel_invoice_adjustments_with_deleted,
      @_pay_stubs_with_deleted,
    ].each do |items|
      items.each do |item|
        item.ledger.association(:contributor).target = self
      end
    end
```

- [ ] **Step 6.4: Add PayStub case to `new_deal_balance`**

Inside `new_deal_balance` (around lines 198-233), add a PayStub branch matching the ContributorPayout branch (also payable-gated):

```ruby
      elsif li.is_a?(PayStub)
        if li.payable?
          acc[:balance] += li.amount
        else
          acc[:unsettled] += li.amount
        end
```
Add this branch directly before the `elsif li.is_a?(DeelInvoiceAdjustment)` line.

- [ ] **Step 6.5: Run the existing contributor-touching tests as a regression check**

```bash
bin/rails test test/models/contributor_payout_test.rb test/models/ledger_test.rb test/models/contributor_adjustment_test.rb
```
Expected: still all green.

- [ ] **Step 6.6: Commit**

```bash
git add app/models/contributor.rb
git commit -m "Contributor: through-association, memoized cache, preload, balance branch for PayStub"
```

---

## Phase 6 — Generation service

### Task 7: PayCycles::GenerateStubs service — scaffold + finder

**Files:**
- Create: `app/services/pay_cycles/generate_stubs.rb`
- Create: `test/services/pay_cycles/generate_stubs_test.rb`

- [ ] **Step 7.1: Write failing test (finder scope)**

Create `test/services/pay_cycles/generate_stubs_test.rb`:

```ruby
require "test_helper"

class PayCycles::GenerateStubsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "GenStubs-#{SecureRandom.hex(2)}")
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
  end

  test "considers only assignments on internal forecast clients of this enterprise" do
    # Internal client mapped to THIS enterprise
    internal_client = ForecastClient.create!(forecast_id: SecureRandom.hex(8), name: "G3D internal", data: {}, is_internal: true)
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: internal_client.forecast_id)
    internal_project = ForecastProject.create!(forecast_id: SecureRandom.hex(8), client_id: internal_client.forecast_id, data: { name: "Internal proj" }, hourly_rate: 100)

    # External client (not is_internal) on this enterprise — should be ignored
    external_client = ForecastClient.create!(forecast_id: SecureRandom.hex(8), name: "Acme", data: {}, is_internal: false)
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client_id: external_client.forecast_id)
    external_project = ForecastProject.create!(forecast_id: SecureRandom.hex(8), client_id: external_client.forecast_id, data: { name: "Acme proj" }, hourly_rate: 100)

    fp = ForecastPerson.create!(forecast_id: SecureRandom.hex(8), email: "gen1@example.com", data: {})
    AdminUser.create!(email: fp.email, password: "password123", password_confirmation: "password123", forecast_person_id: fp.forecast_id)

    ForecastAssignment.create!(forecast_id: SecureRandom.hex(8), person_id: fp.forecast_id, project_id: internal_project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)
    ForecastAssignment.create!(forecast_id: SecureRandom.hex(8), person_id: fp.forecast_id, project_id: external_project.forecast_id, start_date: @cycle.starts_at, end_date: @cycle.ends_at, allocation: 8 * 60 * 60)

    qualifying = PayCycles::GenerateStubs.new(@cycle).qualifying_assignments
    assert_equal 1, qualifying.size
    assert_equal internal_project.forecast_id, qualifying.first.project_id
  end
end
```

- [ ] **Step 7.2: Run; expect failures**

```bash
bin/rails test test/services/pay_cycles/generate_stubs_test.rb -n test_considers_only_assignments_on_internal_forecast_clients_of_this_enterprise
```
Expected: NameError: uninitialized constant PayCycles.

- [ ] **Step 7.3: Implement the scaffold + qualifying_assignments**

Create `app/services/pay_cycles/generate_stubs.rb`:

```ruby
module PayCycles
  class GenerateStubs
    class MissingRateError < StandardError; end
    class AcceptedStubMissingHoursError < StandardError; end

    attr_reader :pay_cycle

    def initialize(pay_cycle)
      @pay_cycle = pay_cycle
    end

    def self.call(pay_cycle)
      new(pay_cycle).call
    end

    def call
      raise NotImplementedError, "Implemented in Task 8+"
    end

    # Returns ForecastAssignments overlapping this cycle whose project's
    # forecast_client.is_internal? AND whose forecast_client is mapped to
    # this cycle's enterprise.
    def qualifying_assignments
      ForecastAssignment
        .joins(forecast_project: :forecast_client)
        .joins("INNER JOIN enterprise_forecast_clients efc ON efc.forecast_client_id = forecast_clients.forecast_id")
        .where(forecast_clients: { is_internal: true })
        .where(efc: { enterprise_id: pay_cycle.enterprise_id })
        .where("forecast_assignments.start_date <= ?", pay_cycle.ends_at)
        .where("forecast_assignments.end_date >= ?", pay_cycle.starts_at)
        .includes(:forecast_person, forecast_project: :forecast_client)
    end
  end
end
```

- [ ] **Step 7.4: Tests pass**

```bash
bin/rails test test/services/pay_cycles/generate_stubs_test.rb -n test_considers_only_assignments_on_internal_forecast_clients_of_this_enterprise
```
Expected: 1 passing.

- [ ] **Step 7.5: Commit**

```bash
git add app/services/pay_cycles/generate_stubs.rb test/services/pay_cycles/generate_stubs_test.rb
git commit -m "PayCycles::GenerateStubs: qualifying_assignments finder"
```

### Task 8: Rate resolution + missing-rate hard fail

**Files:**
- Modify: `app/services/pay_cycles/generate_stubs.rb`
- Modify: `test/services/pay_cycles/generate_stubs_test.rb`

- [ ] **Step 8.1: Write failing tests**

Append to `test/services/pay_cycles/generate_stubs_test.rb`:

```ruby
  test "resolve_rate uses per-email override when present" do
    project = ForecastProject.create!(forecast_id: SecureRandom.hex(8), client_id: SecureRandom.hex(8), data: {}, hourly_rate: 50, notes: "alice@example.com:120p/h")
    rate = PayCycles::GenerateStubs.new(@cycle).resolve_rate(project, "alice@example.com")
    assert_equal 120.0, rate
  end

  test "resolve_rate falls back to project's hourly_rate" do
    project = ForecastProject.create!(forecast_id: SecureRandom.hex(8), client_id: SecureRandom.hex(8), data: {}, hourly_rate: 75)
    rate = PayCycles::GenerateStubs.new(@cycle).resolve_rate(project, "bob@example.com")
    assert_equal 75.0, rate
  end

  test "resolve_rate returns nil when neither override nor hourly_rate set" do
    project = ForecastProject.create!(forecast_id: SecureRandom.hex(8), client_id: SecureRandom.hex(8), data: {}, hourly_rate: nil)
    rate = PayCycles::GenerateStubs.new(@cycle).resolve_rate(project, "bob@example.com")
    assert_nil rate
  end
```

- [ ] **Step 8.2: Run; expect failures**

```bash
bin/rails test test/services/pay_cycles/generate_stubs_test.rb -n /resolve_rate/
```
Expected: NoMethodError: resolve_rate.

- [ ] **Step 8.3: Implement resolve_rate**

In `app/services/pay_cycles/generate_stubs.rb`, add inside the class:

```ruby
    # Reuses the existing rate hierarchy used by InvoiceTracker#make_contributor_payouts!:
    # per-email override on the forecast project's notes wins, else the project's hourly_rate.
    def resolve_rate(forecast_project, email)
      override = forecast_project.hourly_rate_override_for_email_address(email)
      return override.to_f if override.present?
      rate = forecast_project.hourly_rate
      return nil if rate.blank?
      rate.to_f
    end
```

- [ ] **Step 8.4: Tests pass**

```bash
bin/rails test test/services/pay_cycles/generate_stubs_test.rb -n /resolve_rate/
```
Expected: 3 passing.

- [ ] **Step 8.5: Commit**

```bash
git add app/services/pay_cycles/generate_stubs.rb test/services/pay_cycles/generate_stubs_test.rb
git commit -m "PayCycles::GenerateStubs: resolve_rate (override then project rate)"
```

### Task 9: Salaried-contributor skip guard

**Files:**
- Modify: `app/services/pay_cycles/generate_stubs.rb`
- Modify: `test/services/pay_cycles/generate_stubs_test.rb`

- [ ] **Step 9.1: Write failing tests**

Append to `test/services/pay_cycles/generate_stubs_test.rb`:

```ruby
  test "salaried_skip? true when contributor's admin_user has a non-variable_hours full-time period overlapping cycle end" do
    fp = ForecastPerson.create!(forecast_id: SecureRandom.hex(8), email: "salary@example.com", data: {})
    au = AdminUser.create!(email: fp.email, password: "password123", password_confirmation: "password123", forecast_person_id: fp.forecast_id)
    FullTimePeriod.create!(admin_user: au, started_at: Date.new(2025, 1, 1), ended_at: Date.new(2027, 1, 1), kind: :five_day)
    skip = PayCycles::GenerateStubs.new(@cycle).salaried_skip?(fp)
    assert skip
  end

  test "salaried_skip? false when contributor has no full-time period (pure contractor)" do
    fp = ForecastPerson.create!(forecast_id: SecureRandom.hex(8), email: "contractor#{SecureRandom.hex(2)}@example.com", data: {})
    au = AdminUser.create!(email: fp.email, password: "password123", password_confirmation: "password123", forecast_person_id: fp.forecast_id)
    refute PayCycles::GenerateStubs.new(@cycle).salaried_skip?(fp)
  end

  test "salaried_skip? false when variable_hours at cycle end" do
    fp = ForecastPerson.create!(forecast_id: SecureRandom.hex(8), email: "variable#{SecureRandom.hex(2)}@example.com", data: {})
    au = AdminUser.create!(email: fp.email, password: "password123", password_confirmation: "password123", forecast_person_id: fp.forecast_id)
    FullTimePeriod.create!(admin_user: au, started_at: Date.new(2025, 1, 1), ended_at: Date.new(2027, 1, 1), kind: :variable_hours)
    refute PayCycles::GenerateStubs.new(@cycle).salaried_skip?(fp)
  end
```

- [ ] **Step 9.2: Run; expect failures**

```bash
bin/rails test test/services/pay_cycles/generate_stubs_test.rb -n /salaried_skip/
```
Expected: NoMethodError: salaried_skip?.

- [ ] **Step 9.3: Implement**

Add to `app/services/pay_cycles/generate_stubs.rb`:

```ruby
    # Mirrors invoice_tracker.rb:467's guard. Salaried (non-variable_hours) people
    # are paid via their full-time arrangement, not pay stubs.
    def salaried_skip?(forecast_person)
      admin_user = forecast_person.admin_user
      return false if admin_user.nil?
      return false if admin_user.full_time_periods.empty?
      ftp = admin_user.full_time_period_at(pay_cycle.ends_at)
      return false if ftp.nil?
      !ftp.variable_hours?
    end
```

- [ ] **Step 9.4: Tests pass**

```bash
bin/rails test test/services/pay_cycles/generate_stubs_test.rb -n /salaried_skip/
```
Expected: 3 passing.

- [ ] **Step 9.5: Commit**

```bash
git add app/services/pay_cycles/generate_stubs.rb test/services/pay_cycles/generate_stubs_test.rb
git commit -m "PayCycles::GenerateStubs: salaried_skip? guard"
```

### Task 10: `#call` — end-to-end generation with pro-rating, create/update stubs, preserve acceptance

**Files:**
- Modify: `app/services/pay_cycles/generate_stubs.rb`
- Modify: `test/services/pay_cycles/generate_stubs_test.rb`

- [ ] **Step 10.1: Write failing tests**

Append to `test/services/pay_cycles/generate_stubs_test.rb`:

```ruby
  test "call creates one stub per contributor with itemized blueprint" do
    setup_one_assignment(hours_per_day: 8, days_in_cycle_only: true)
    PayCycles::GenerateStubs.call(@cycle)
    assert_equal 1, @cycle.pay_stubs.count
    stub = @cycle.pay_stubs.first
    assert_equal 1, stub.blueprint["lines"].size
    line = stub.blueprint["lines"].first
    assert_equal @internal_project.forecast_id, line["forecast_project"]
    assert line["hours"] > 0
    assert_equal 100.0, line["rate"]
    assert_in_delta line["hours"] * 100.0, stub.amount.to_f, 0.01
  end

  test "call pro-rates assignments that cross cycle boundary" do
    # Twice-monthly cycle 1..15
    @cycle.update!(ends_at: Date.new(2026, 5, 15))
    setup_one_assignment(start_date: Date.new(2026, 5, 10), end_date: Date.new(2026, 5, 20), hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    # Days 10..15 = 6 days × 8h = 48 hours in this half
    assert_equal 48.0, stub.blueprint["lines"].first["hours"]
  end

  test "call skips salaried contributors" do
    setup_one_assignment(hours_per_day: 8)
    FullTimePeriod.create!(admin_user: @assignment_admin_user, started_at: Date.new(2025, 1, 1), ended_at: Date.new(2027, 1, 1), kind: :five_day)
    PayCycles::GenerateStubs.call(@cycle)
    assert_equal 0, @cycle.pay_stubs.count
  end

  test "call hard-fails when a qualifying assignment has no resolvable rate" do
    setup_one_assignment(hours_per_day: 8, hourly_rate: nil)
    assert_raises(PayCycles::GenerateStubs::MissingRateError) do
      PayCycles::GenerateStubs.call(@cycle)
    end
  end

  test "call preserves accepted_at when re-running with unchanged amount" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)
    original_accepted_at = stub.accepted_at
    PayCycles::GenerateStubs.call(@cycle)
    stub.reload
    assert_equal original_accepted_at.to_i, stub.accepted_at.to_i
    assert_equal @admin.id, stub.accepted_by_id
  end

  test "call resets accepted_at when amount changes on re-run" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)
    @assignment.update!(allocation: 4 * 60 * 60)   # halve daily allocation
    PayCycles::GenerateStubs.call(@cycle)
    stub.reload
    assert_nil stub.accepted_at
    assert_nil stub.accepted_by_id
  end

  test "call soft-deletes a stub whose contributor no longer has qualifying hours" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    @assignment.update!(end_date: @cycle.starts_at - 1.day)   # move out of window
    @assignment.update!(start_date: @cycle.starts_at - 5.days)
    PayCycles::GenerateStubs.call(@cycle)
    stub.reload
    assert stub.deleted_at.present?
  end

  test "call raises when an accepted stub's contributor loses qualifying hours" do
    setup_one_assignment(hours_per_day: 8)
    PayCycles::GenerateStubs.call(@cycle)
    stub = @cycle.pay_stubs.first
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)
    @assignment.update!(start_date: @cycle.starts_at - 5.days, end_date: @cycle.starts_at - 1.day)
    assert_raises(PayCycles::GenerateStubs::AcceptedStubMissingHoursError) do
      PayCycles::GenerateStubs.call(@cycle)
    end
  end

  test "call does not write a stub for $0 amount" do
    setup_one_assignment(hours_per_day: 0)
    PayCycles::GenerateStubs.call(@cycle)
    assert_equal 0, @cycle.pay_stubs.count
  end

  private

  # Helper to seed a single qualifying assignment for the cycle.
  def setup_one_assignment(start_date: nil, end_date: nil, hours_per_day: 8, hourly_rate: 100)
    @internal_client ||= ForecastClient.create!(forecast_id: SecureRandom.hex(8), name: "Internal #{SecureRandom.hex(2)}", data: {}, is_internal: true)
    EnterpriseForecastClient.find_or_create_by!(enterprise: @enterprise, forecast_client_id: @internal_client.forecast_id)
    @internal_project ||= ForecastProject.create!(forecast_id: SecureRandom.hex(8), client_id: @internal_client.forecast_id, data: { name: "P #{SecureRandom.hex(2)}" }, hourly_rate: hourly_rate)
    @assignment_fp ||= ForecastPerson.create!(forecast_id: SecureRandom.hex(8), email: "asg#{SecureRandom.hex(3)}@example.com", data: {})
    @assignment_admin_user ||= AdminUser.create!(email: @assignment_fp.email, password: "password123", password_confirmation: "password123", forecast_person_id: @assignment_fp.forecast_id)
    @assignment_contributor ||= Contributor.find_or_create_by!(forecast_person: @assignment_fp)
    @admin ||= AdminUser.create!(email: "approver#{SecureRandom.hex(3)}@example.com", password: "password123", password_confirmation: "password123")
    @assignment = ForecastAssignment.create!(
      forecast_id: SecureRandom.hex(8),
      person_id: @assignment_fp.forecast_id,
      project_id: @internal_project.forecast_id,
      start_date: start_date || @cycle.starts_at,
      end_date: end_date || @cycle.ends_at,
      allocation: hours_per_day * 60 * 60,
    )
  end
```

- [ ] **Step 10.2: Run; expect failures**

```bash
bin/rails test test/services/pay_cycles/generate_stubs_test.rb -n /call/
```
Expected: NotImplementedError from the stub `#call`.

- [ ] **Step 10.3: Implement `#call`**

Replace the stub `def call ... end` in `app/services/pay_cycles/generate_stubs.rb` with:

```ruby
    # Idempotent. Pro-rates each qualifying assignment to the cycle window,
    # groups by contributor, and emits/updates one PayStub per contributor.
    # Preserves accepted_at when amount is unchanged; resets when it changes.
    # Soft-deletes stubs whose contributor no longer has qualifying hours
    # (raises if the stub was already accepted).
    def call
      ActiveRecord::Base.transaction do
        per_contributor = group_qualifying_by_contributor
        validate_all_rates_resolvable!(per_contributor)
        synced_stub_ids = upsert_stubs(per_contributor)
        soft_delete_missing_stubs(synced_stub_ids)
      end
      pay_cycle.reload
    end

    private

    def group_qualifying_by_contributor
      assignments_by_fp = qualifying_assignments.group_by(&:forecast_person)
      assignments_by_fp.reject { |fp, _| salaried_skip?(fp) }
    end

    def validate_all_rates_resolvable!(per_contributor)
      missing = []
      per_contributor.each do |fp, assignments|
        assignments.each do |a|
          rate = resolve_rate(a.forecast_project, fp.email)
          missing << "#{a.forecast_project.try(:display_name) || a.project_id} / #{fp.email}" if rate.nil?
        end
      end
      return if missing.empty?
      raise MissingRateError, "Missing hourly rate for: #{missing.join('; ')}"
    end

    def upsert_stubs(per_contributor)
      ids = []
      per_contributor.each do |fp, assignments|
        fp.ensure_contributor_exists!
        contributor = fp.contributor
        ledger = Ledger.find_or_create_for(enterprise: pay_cycle.enterprise, contributor: contributor)
        lines = build_lines(fp, assignments)
        amount = lines.sum { |l| l["amount"].to_f }.round(2)
        next if amount.zero?

        stub = PayStub.with_deleted.find_or_initialize_by(pay_cycle_id: pay_cycle.id, ledger_id: ledger.id)
        preserve_acceptance = stub.persisted? && stub.amount.to_f.round(2) == amount
        stub.assign_attributes(
          amount: amount,
          blueprint: { "lines" => lines },
          deleted_at: nil,
        )
        unless preserve_acceptance
          stub.accepted_at = nil
          stub.accepted_by_id = nil
        end
        stub.save!
        ids << stub.id
      end
      ids
    end

    def build_lines(forecast_person, assignments)
      assignments.map do |a|
        hours = a.allocation_during_range_in_hours(pay_cycle.starts_at, pay_cycle.ends_at)
        rate = resolve_rate(a.forecast_project, forecast_person.email)
        amount = (hours * rate).round(2)
        {
          "forecast_project" => a.project_id,
          "hours" => hours,
          "rate" => rate,
          "amount" => amount,
          "description" => "#{a.forecast_project.try(:display_name) || a.project_id} — #{hours}h × $#{rate}",
        }
      end
    end

    def soft_delete_missing_stubs(synced_stub_ids)
      pay_cycle.pay_stubs.where.not(id: synced_stub_ids).each do |orphan|
        if orphan.accepted_at.present?
          raise AcceptedStubMissingHoursError, "PayStub ##{orphan.id} (#{orphan.ledger.contributor.forecast_person.email}) was already accepted but has no qualifying hours after regen."
        end
        orphan.destroy
      end
    end
```

Note: the `attr_reader :pay_cycle` line is already public; the new helpers stay private. The original `qualifying_assignments`, `resolve_rate`, `salaried_skip?` defined in Tasks 7-9 stay public for direct testing — leave them above the `private` keyword.

- [ ] **Step 10.4: Tests pass**

```bash
bin/rails test test/services/pay_cycles/generate_stubs_test.rb
```
Expected: all passing (10+).

- [ ] **Step 10.5: Commit**

```bash
git add app/services/pay_cycles/generate_stubs.rb test/services/pay_cycles/generate_stubs_test.rb
git commit -m "PayCycles::GenerateStubs#call: end-to-end generation with acceptance preservation"
```

---

## Phase 7 — Existing ContributorPayout regen fix (acceptance preservation)

### Task 11: Preserve `accepted_at` on CP regen when amount is unchanged

**Files:**
- Modify: `app/models/invoice_tracker.rb` (around lines 469-477)
- Modify: `test/models/invoice_tracker_test.rb`

- [ ] **Step 11.1: Write failing test**

Append to `test/models/invoice_tracker_test.rb` (or create with the basic setup if the file is bare). Choose the simplest path that creates one InvoiceTracker, one CP for a variable_hours person, calls `make_contributor_payouts!` once, marks the CP accepted, calls it again with unchanged amount, and asserts the acceptance is preserved.

The simplest version, mirroring the patterns in `test/models/contributor_payout_test.rb`:

```ruby
class InvoiceTrackerRegenAcceptancePreservationTest < ActiveSupport::TestCase
  test "amount_equals? compares amounts within $0.01 rounding tolerance" do
    # Predicate covers the only new conditional. End-to-end integration
    # coverage relies on the analogous PayStub preservation test in Task 10
    # (same code shape).
    it = InvoiceTracker.new
    assert it.send(:amount_equals?, 100.0, 100.00)
    assert it.send(:amount_equals?, 100.0, 100.005)
    refute it.send(:amount_equals?, 100.0, 101.0)
  end
end
```

- [ ] **Step 11.2: Run; expect failures**

```bash
bin/rails test test/models/invoice_tracker_test.rb -n /amount_equals/
```
Expected: NoMethodError: amount_equals?.

- [ ] **Step 11.3: Modify `invoice_tracker.rb`**

Open `app/models/invoice_tracker.rb`. At the bottom of the class (before `end`), add the predicate:

```ruby
  private

  def amount_equals?(a, b)
    (a.to_f.round(2) - b.to_f.round(2)).abs < 0.01
  end
```

Now find the existing update block in `make_contributor_payouts!` (currently lines 469-477):

```ruby
cp = contributor_payouts.with_deleted.find_or_initialize_by(ledger_id: ledger.id)
cp.update!(
  deleted_at: nil,
  amount: amount,
  blueprint: payee_data[:blueprint],
  created_by: created_by,
  description: "",
  accepted_at: payee.admin_user.present? ? nil : DateTime.now
)
```

Replace with:

```ruby
cp = contributor_payouts.with_deleted.find_or_initialize_by(ledger_id: ledger.id)
preserve_acceptance =
  cp.persisted? && cp.accepted_at.present? && amount_equals?(cp.amount, amount)

attrs = {
  deleted_at: nil,
  amount: amount,
  blueprint: payee_data[:blueprint],
  created_by: created_by,
  description: "",
}
# Commission-only CPs (no admin_user behind them) auto-accept now and always.
# Otherwise: preserve acceptance only when the recomputed amount matches the
# existing one. Mismatches reset accepted_at so the contributor re-reviews.
if payee.admin_user.nil?
  attrs[:accepted_at] = DateTime.now
elsif !preserve_acceptance
  attrs[:accepted_at] = nil
end
cp.update!(attrs)
```

- [ ] **Step 11.4: Tests pass**

```bash
bin/rails test test/models/invoice_tracker_test.rb -n /amount_equals/
```
Expected: 1 passing.

- [ ] **Step 11.5: Run the broader payout-related tests as a regression gate**

```bash
bin/rails test test/models/contributor_payout_test.rb test/models/invoice_tracker_test.rb
```
Expected: still green.

- [ ] **Step 11.6: Commit**

```bash
git add app/models/invoice_tracker.rb test/models/invoice_tracker_test.rb
git commit -m "InvoiceTracker: preserve accepted_at on regen when amount unchanged"
```

---

## Phase 8 — Admin UI

### Task 12: Enterprise admin form — pay_cycle_cadence

**Files:**
- Modify: `app/admin/enterprises.rb`

- [ ] **Step 12.1: Add `pay_cycle_cadence` to permit_params**

Edit `app/admin/enterprises.rb`. The current `permit_params` list (lines 5-15) starts with `:name, :deel_legal_entity_id, ...`. Add `:pay_cycle_cadence` to that list:

```ruby
  permit_params :name,
    :deel_legal_entity_id,
    :pay_cycle_cadence,
    forecast_client_ids: [],
    qbo_account_attributes: [
      :id,
      :_edit,
      :_destroy,
      :client_id,
      :client_secret,
      :realm_id,
    ]
```

- [ ] **Step 12.2: Add the form input**

Inside the `form do |f|` block, after the existing `f.input :forecast_clients ...` block (around line 100), add:

```ruby
      f.input :pay_cycle_cadence,
        as: :select,
        collection: [["Monthly", "monthly"], ["Twice monthly (1–15, 16–end)", "twice_monthly"]],
        include_blank: "(disabled — no pay cycles)",
        hint: "Setting this enables the \"New Pay Cycle\" button on this enterprise's show page. " \
              "Choose Monthly for a single cycle per calendar month, or Twice monthly to split the month in half."
```

- [ ] **Step 12.3: Manual verification**

Run:
```bash
bin/rails server
```
Open `http://localhost:3000/admin/enterprises/<id>/edit`. Confirm the new select appears with three options. Save with each value; reopen edit; confirm the value persists.

- [ ] **Step 12.4: Commit**

```bash
git add app/admin/enterprises.rb
git commit -m "Enterprise admin: pay_cycle_cadence form input"
```

### Task 13: PayCycle admin (nested under Enterprise)

**Files:**
- Create: `app/admin/pay_cycles.rb`
- Create: `app/views/admin/pay_cycles/_show.html.erb`

- [ ] **Step 13.1: Create the admin file**

Create `app/admin/pay_cycles.rb`:

```ruby
ActiveAdmin.register PayCycle do
  belongs_to :enterprise
  menu false
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :show, :destroy
  permit_params :starts_at, :ends_at

  controller do
    def new
      parent = Enterprise.find(params[:enterprise_id])
      default_range = parent.pay_cycle_default_range_for(Date.today)
      @pay_cycle = parent.pay_cycles.new(
        starts_at: default_range&.first,
        ends_at: default_range&.last,
      )
    end

    def create
      parent = Enterprise.find(params[:enterprise_id])
      @pay_cycle = parent.pay_cycles.new(
        permitted_params[:pay_cycle].merge(created_by: current_admin_user),
      )
      if @pay_cycle.save
        redirect_to admin_enterprise_pay_cycle_path(parent, @pay_cycle), notice: "Pay cycle created."
      else
        flash.now[:error] = @pay_cycle.errors.full_messages.join(", ")
        render :new
      end
    end
  end

  action_item :regenerate, only: :show do
    link_to "Regenerate from Forecast",
      regenerate_admin_enterprise_pay_cycle_path(resource.enterprise, resource),
      method: :post,
      data: { confirm: regen_confirm_message(resource) }
  end

  member_action :regenerate, method: :post do
    PayCycles::GenerateStubs.call(resource)
    redirect_to admin_enterprise_pay_cycle_path(resource.enterprise, resource), notice: "Stubs regenerated."
  rescue PayCycles::GenerateStubs::MissingRateError, PayCycles::GenerateStubs::AcceptedStubMissingHoursError => e
    redirect_to admin_enterprise_pay_cycle_path(resource.enterprise, resource), alert: e.message
  end

  show do
    render partial: "show", locals: { resource: resource }
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :starts_at, as: :date_picker
      f.input :ends_at, as: :date_picker
    end
    f.actions
  end

  controller do
    helper_method :regen_confirm_message

    def regen_confirm_message(cycle)
      n = cycle.pay_stubs.where.not(accepted_at: nil).count
      return nil if n.zero?
      "Regen may reset acceptance on up to #{n} already-accepted stub(s) if amounts change. Continue?"
    end
  end
end
```

- [ ] **Step 13.2: Create show partial**

Create `app/views/admin/pay_cycles/_show.html.erb`:

```erb
<h2><%= resource.enterprise.name %> — <%= resource.starts_at %> to <%= resource.ends_at %></h2>
<p>Status:
  <% case resource.stubs_status
     when :no_stubs %>No stubs yet
  <% when :some_pending %>Some pending
  <% when :all_accepted %>All accepted (locked)
  <% end %>
</p>

<table style="width: 100%; margin-top: 16px">
  <thead>
    <tr>
      <th>Contributor</th>
      <th>Amount</th>
      <th>Accepted</th>
      <th>Accepted by</th>
      <th></th>
    </tr>
  </thead>
  <tbody>
    <% resource.pay_stubs.includes(ledger: { contributor: :forecast_person }, accepted_by: []).each do |stub| %>
      <tr>
        <td><%= stub.contributor.forecast_person.email %></td>
        <td><%= number_to_currency(stub.amount) %></td>
        <td><%= stub.accepted_at&.to_date || "—" %></td>
        <td><%= stub.accepted_by&.email || "—" %></td>
        <td><%= link_to "View stub", admin_pay_cycle_pay_stub_path(resource, stub) %></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

- [ ] **Step 13.3: Manual verification**

```bash
bin/rails server
```
Open `/admin/enterprises/<id>` (with `pay_cycle_cadence` set). Click "New Pay Cycle". Confirm pre-filled dates. Save. Open the cycle show page; confirm the status text and empty stubs table.

- [ ] **Step 13.4: Commit**

```bash
git add app/admin/pay_cycles.rb app/views/admin/pay_cycles/_show.html.erb
git commit -m "PayCycle admin (nested under Enterprise) + show partial"
```

### Task 14: PayStub admin (nested under PayCycle) + accept toggle

**Files:**
- Create: `app/admin/pay_stubs.rb`
- Create: `app/views/admin/pay_stubs/_show.html.erb`

- [ ] **Step 14.1: Create admin**

Create `app/admin/pay_stubs.rb`:

```ruby
ActiveAdmin.register PayStub do
  belongs_to :pay_cycle
  menu false
  config.filters = false
  config.paginate = false
  actions :show

  action_item :toggle_acceptance, only: :show do
    label = resource.accepted? ? "Unaccept" : "Accept"
    link_to label,
      toggle_acceptance_admin_pay_cycle_pay_stub_path(resource.pay_cycle, resource),
      method: :post
  end

  member_action :toggle_acceptance, method: :post do
    resource.toggle_acceptance!(by: current_admin_user)
    redirect_to admin_pay_cycle_pay_stub_path(resource.pay_cycle, resource), notice: "Updated."
  rescue RuntimeError => e
    redirect_to admin_pay_cycle_pay_stub_path(resource.pay_cycle, resource), alert: e.message
  end

  show do
    render partial: "show", locals: { resource: resource }
  end
end
```

- [ ] **Step 14.2: Create show partial**

Create `app/views/admin/pay_stubs/_show.html.erb`:

```erb
<h2><%= resource.contributor.forecast_person.email %> — <%= resource.pay_cycle.starts_at %> to <%= resource.pay_cycle.ends_at %></h2>
<p>Total: <strong><%= number_to_currency(resource.amount) %></strong></p>
<p>Status:
  <%= resource.accepted? ? "Accepted on #{resource.accepted_at.to_date} by #{resource.accepted_by&.email}" : "Pending acceptance" %>
</p>

<table style="width: 100%; margin-top: 16px">
  <thead>
    <tr>
      <th>Forecast project</th>
      <th>Hours</th>
      <th>Rate</th>
      <th>Amount</th>
    </tr>
  </thead>
  <tbody>
    <% (resource.blueprint["lines"] || []).each do |line| %>
      <tr>
        <td><%= line["forecast_project"] %></td>
        <td><%= line["hours"] %></td>
        <td><%= number_to_currency(line["rate"]) %></td>
        <td><%= number_to_currency(line["amount"]) %></td>
      </tr>
    <% end %>
  </tbody>
</table>

<% if resource.payable? && resource.qbo_bill.present? %>
  <h3 style="margin-top: 24px">QBO Bill</h3>
  <p><%= link_to "Open in QBO", resource.qbo_url, target: "_blank" %></p>
<% end %>
```

- [ ] **Step 14.3: Manual verification**

In a console:
```bash
bin/rails console
```
Create a cycle and a stub manually:
```ruby
ent = Enterprise.find_or_create_by!(name: "ManualTest")
ent.update!(pay_cycle_cadence: "monthly")
pc = ent.pay_cycles.create!(starts_at: Date.current.beginning_of_month, ends_at: Date.current.end_of_month)
fp = ForecastPerson.find_or_create_by!(forecast_id: 9999, email: "t@x.com", data: {})
c = Contributor.find_or_create_by!(forecast_person: fp)
l = Ledger.find_or_create_for(enterprise: ent, contributor: c)
PayStub.create!(pay_cycle: pc, ledger: l, amount: 100, blueprint: { "lines" => [{ "forecast_project" => "x", "hours" => 1, "rate" => 100, "amount" => 100, "description" => "manual" }] })
```
Open the stub's show URL; confirm the Accept button works (toggle, then unaccept while it's the only stub — should refuse with the all_accepted lockout).

- [ ] **Step 14.4: Commit**

```bash
git add app/admin/pay_stubs.rb app/views/admin/pay_stubs/_show.html.erb
git commit -m "PayStub admin (nested under PayCycle) + accept toggle"
```

### Task 15: Embed pay-cycles section into Enterprise show

**Files:**
- Modify: `app/admin/enterprises.rb` (around the existing `show do` block — currently lines 120-242)
- Create: `app/views/admin/enterprises/_pay_cycles_section.html.erb`

- [ ] **Step 15.1: Create the section partial**

Create `app/views/admin/enterprises/_pay_cycles_section.html.erb`:

```erb
<% return unless enterprise.pay_cycle_cadence.present? %>

<h2 style="margin-top: 32px">Pay cycles</h2>
<p>
  <%= link_to "New Pay Cycle",
    new_admin_enterprise_pay_cycle_path(enterprise),
    class: "button" %>
</p>

<table style="width: 100%; margin-top: 16px">
  <thead>
    <tr>
      <th>Period</th>
      <th>Status</th>
      <th>Stub count</th>
      <th></th>
    </tr>
  </thead>
  <tbody>
    <% enterprise.pay_cycles.includes(:pay_stubs).order(starts_at: :desc).each do |pc| %>
      <tr>
        <td><%= pc.starts_at %> – <%= pc.ends_at %></td>
        <td>
          <% case pc.stubs_status
             when :no_stubs %>No stubs
          <% when :some_pending %>Some pending
          <% when :all_accepted %>All accepted
          <% end %>
        </td>
        <td><%= pc.pay_stubs.size %></td>
        <td><%= link_to "Open", admin_enterprise_pay_cycle_path(enterprise, pc) %></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

- [ ] **Step 15.2: Render the partial from the enterprise show partial**

Find the existing enterprise show partial — it's rendered via `render(partial: "show", ...)` in `app/admin/enterprises.rb`. Open `app/views/admin/enterprises/_show.html.erb` (the existing file).

Append at the bottom of `_show.html.erb`:

```erb
<%= render partial: "admin/enterprises/pay_cycles_section", locals: { enterprise: enterprise } %>
```

Confirm the existing show partial passes an `enterprise` local — if it instead uses `resource`, swap the local name accordingly when calling the new partial.

- [ ] **Step 15.3: Manual verification**

```bash
bin/rails server
```
Open `/admin/enterprises/<id>` for an enterprise with `pay_cycle_cadence` set. Confirm the new section appears with the New button and an empty/populated cycle list. For an enterprise without cadence set, the section should NOT appear.

- [ ] **Step 15.4: Commit**

```bash
git add app/views/admin/enterprises/_pay_cycles_section.html.erb app/views/admin/enterprises/_show.html.erb
git commit -m "Enterprise show: pay cycles section"
```

---

## Phase 9 — Validate end-to-end

### Task 16: Full-suite regression + manual smoke

**Files:** none.

- [ ] **Step 16.1: Run the entire test suite**

```bash
bin/rails test
```
Expected: all green. The new PayCycle, PayStub, and GenerateStubs tests pass; existing CP/IT/Ledger/Contributor tests still pass.

- [ ] **Step 16.2: Manual end-to-end smoke (dev server)**

```bash
bin/rails server
```
Sequence:
1. `/admin/enterprises/<id>/edit` — set `pay_cycle_cadence = "monthly"`.
2. Confirm "Pay cycles" section appears on the show page.
3. Click "New Pay Cycle"; defaults to the current month.
4. Save → land on cycle show.
5. Click "Regenerate from Forecast". If the enterprise has no internal forecast clients, it should produce zero stubs (no error).
6. Set up an internal forecast client and one assignment in dev DB (or use seed data). Regenerate.
7. Click into a stub; Accept; confirm `payable?` flips, balance moves from `unsettled` to `balance` on the contributor admin show page.

- [ ] **Step 16.3: Final commit (no-op, marker)**

If any one-off doc tweaks come up during smoke, commit them here. Otherwise skip.

---

## Open follow-ups (explicitly out of scope for this plan)

These are listed in the spec §13 as future direction; no tasks here:

- Move `InvoicePass` under `Enterprise` (today implicitly Sanctuary's).
- Scheduled auto-creation of cycles per `pay_cycle_cadence`.
- Per-contributor exclusion from a cycle.
- Editing stub blueprint by hand (corrections continue to flow via `ContributorAdjustment`).
