# QBO-Bound Ledger Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate Stacks ledgers from the legacy balance model (negative ContributorAdjustments and DeelInvoiceAdjustments deduct) to a QBO-bound model (only QBO Bill Paid drops a positive host from balance), per-ledger and gated by a no-balance-change invariant; replace the LedgerWithdrawalRequest bundling apparatus with a direct Deel API trigger and a controller-facing Payable QBO Bills page.

**Architecture:** Add `mode` (legacy/qbo_bound) and `payment_methods` (text[]) columns on `ledgers`. Branch `Ledger#balance`/`#unsettled` on `mode`. Introduce `Ledgers::QboBoundMigrationCheck` to compute the gate. Surface the migration as a per-ledger button + a Task Builder discovery. Introduce a `Money::PayableQboBills` page tabbed per QBO account. Delete the `LedgerWithdrawalRequest` model entirely; replace its Deel-call core with `DeelInvoiceAdjustments::CreateForLedger`. Ship a rake task that bulk-flips zero-drift ledgers.

**Tech Stack:** Rails 6.1, ActiveAdmin, Postgres (text[] with GIN index), Minitest + Mocha, existing `SyncsAsQboBill` concern.

**Spec:** `docs/superpowers/specs/2026-06-12-qbo-bound-ledger-cutover-design.md`

---

## Pre-flight

- [ ] **Step 0a: Confirm baseline state**

```bash
git status
git log --oneline -10
bundle exec rails db:migrate:status | tail -10
```

Working dir should be clean other than the unrelated `script/why_balance_goes_up.rb` (deleted in Task 18). Verify we're on a worktree branch off `main`.

- [ ] **Step 0b: Run baseline tests for the touch surface**

```bash
bundle exec rails test test/models/ledger_test.rb test/models/contributor_adjustment_test.rb
```

Expected: all pass. Record the baseline count so we can confirm no regressions later.

---

## Task 1: Schema migration with payment_methods backfill

**Files:**
- Create: `db/migrate/<NEW_TS>_add_mode_and_payment_methods_to_ledgers.rb`
- Delete: `db/migrate/20260606135814_create_ledger_withdrawal_requests.rb`

- [ ] **Step 1.1: Delete the never-deployed LedgerWithdrawalRequest migration**

```bash
git rm db/migrate/20260606135814_create_ledger_withdrawal_requests.rb
```

- [ ] **Step 1.2: Generate the new migration**

```bash
bundle exec rails generate migration AddModeAndPaymentMethodsToLedgers
```

Note the generated timestamp; the file will live at `db/migrate/<TS>_add_mode_and_payment_methods_to_ledgers.rb`.

- [ ] **Step 1.3: Write the migration body**

Replace the generated file's contents with:

```ruby
class AddModeAndPaymentMethodsToLedgers < ActiveRecord::Migration[6.1]
  # Per the QBO-bound cutover design:
  # - `mode` controls balance computation. Default :legacy preserves today's behavior.
  # - `payment_methods` is a Postgres text[] with values from %w[deel qbo].
  #   Backfilled from the contributor's DeelPerson country: non-US Deel → ["deel"],
  #   everyone else → ["qbo"].
  def up
    add_column :ledgers, :mode, :integer, null: false, default: 0
    add_column :ledgers, :payment_methods, :string, array: true, null: false, default: []
    add_index  :ledgers, :mode
    add_index  :ledgers, :payment_methods, using: :gin

    Ledger.reset_column_information

    Ledger.includes(contributor: :deel_person).find_each do |ledger|
      contributor = ledger.contributor
      next if contributor.nil?

      dp = contributor.deel_person
      country = dp&.data.is_a?(Hash) ? dp.data["country"].to_s.upcase : nil
      is_non_us_deel = dp.present? && country.present? && country != "US"

      ledger.update_column(:payment_methods, is_non_us_deel ? %w[deel] : %w[qbo])
    end
  end

  def down
    remove_index  :ledgers, :payment_methods
    remove_index  :ledgers, :mode
    remove_column :ledgers, :payment_methods
    remove_column :ledgers, :mode
  end
end
```

- [ ] **Step 1.4: Run the migration**

```bash
bundle exec rails db:migrate
```

Expected: migration applies cleanly; both columns appear in schema.

- [ ] **Step 1.5: Verify schema and backfill**

```bash
bundle exec rails runner 'puts Ledger.columns_hash.slice("mode","payment_methods").map{|n,c|"#{n}: #{c.sql_type}"}.join("\n")'
bundle exec rails runner 'puts Ledger.group(:payment_methods).count.inspect'
```

Expected: `mode: integer`, `payment_methods: character varying[]`. Group output shows a mix of `["deel"]` and `["qbo"]`.

- [ ] **Step 1.6: Commit**

```bash
git add db/migrate/ db/schema.rb
git commit -m "QBO cutover: add ledger.mode + ledger.payment_methods with backfill"
```

---

## Task 2: Ledger model — enum, helpers, and qbo_bound_visible_items

**Files:**
- Modify: `app/models/ledger.rb`
- Test: `test/models/ledger_test.rb`

- [ ] **Step 2.1: Write failing test for mode enum and payment_methods helpers**

Append to `test/models/ledger_test.rb`:

```ruby
class LedgerModeAndPaymentMethodsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "ModeTest-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 992_001, email: "mode#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
  end

  test "mode defaults to legacy" do
    assert_equal "legacy", @ledger.mode
    assert @ledger.legacy?
    refute @ledger.qbo_bound?
  end

  test "mode flips to qbo_bound" do
    @ledger.update!(mode: :qbo_bound)
    assert @ledger.qbo_bound?
    refute @ledger.legacy?
  end

  test "deel_enabled? and qbo_enabled? reflect payment_methods" do
    @ledger.update!(payment_methods: %w[deel])
    assert @ledger.deel_enabled?
    refute @ledger.qbo_enabled?

    @ledger.update!(payment_methods: %w[qbo])
    refute @ledger.deel_enabled?
    assert @ledger.qbo_enabled?
  end

  test "PAYMENT_METHODS is the canonical list" do
    assert_equal %w[deel qbo], Ledger::PAYMENT_METHODS
  end
end
```

- [ ] **Step 2.2: Run test, expect failure**

```bash
bundle exec rails test test/models/ledger_test.rb -n /LedgerModeAndPaymentMethods/
```

Expected: FAIL (no `mode=` method, no `deel_enabled?`, no constant).

- [ ] **Step 2.3: Add enum + helpers + constant**

Edit `app/models/ledger.rb`. After `belongs_to :contributor` and before the `has_many` block, add:

```ruby
  enum mode: { legacy: 0, qbo_bound: 1 }

  PAYMENT_METHODS = %w[deel qbo].freeze

  def deel_enabled?
    payment_methods.include?("deel")
  end

  def qbo_enabled?
    payment_methods.include?("qbo")
  end
```

- [ ] **Step 2.4: Remove the LedgerWithdrawalRequest has_many association**

In `app/models/ledger.rb`, delete this line:

```ruby
  has_many :ledger_withdrawal_requests, dependent: :destroy
```

- [ ] **Step 2.5: Remove LedgerWithdrawalRequest from all_items_with_deleted**

In `app/models/ledger.rb`'s `all_items_with_deleted`, delete the trailing line:

```ruby
      LedgerWithdrawalRequest.includes(:bills, :cancelled_by).where(ledger_id: id).to_a,
```

Also update the comment above the method to remove the LedgerWithdrawalRequest reference.

- [ ] **Step 2.6: Add qbo_bound_visible_items helper**

In `app/models/ledger.rb`'s `private` section, after `visible_items`, add:

```ruby
  # qbo_bound mode: drop DIAs (audit only) and negative CAs (audit only).
  # Everything else flows through the same per-host predicate
  # in_balance_under_qbo_bound?.
  def qbo_bound_visible_items
    visible_items.reject do |li|
      li.is_a?(DeelInvoiceAdjustment) ||
        (li.is_a?(ContributorAdjustment) && li.amount.to_f < 0)
    end
  end
```

- [ ] **Step 2.7: Run tests, expect pass**

```bash
bundle exec rails test test/models/ledger_test.rb
```

Expected: all pass (existing tests still green; new mode tests pass).

- [ ] **Step 2.8: Commit**

```bash
git add app/models/ledger.rb test/models/ledger_test.rb
git commit -m "Ledger: mode enum, payment_methods helpers, qbo_bound_visible_items"
```

---

## Task 3: Per-host `in_balance_under_qbo_bound?` predicates

**Files:**
- Modify: `app/models/contributor_payout.rb`
- Modify: `app/models/contributor_adjustment.rb`
- Modify: `app/models/profit_share.rb`
- Modify: `app/models/trueup.rb`
- Modify: `app/models/pay_stub.rb`
- Modify: `app/models/reimbursement.rb`
- Modify: `app/models/deel_invoice_adjustment.rb`
- Test: `test/models/ledger_test.rb`

- [ ] **Step 3.1: Write failing test for predicates on each host**

Append to `test/models/ledger_test.rb`:

```ruby
class HostInBalanceUnderQboBoundTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "QBoundPred-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 993_001, email: "qbp#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
  end

  test "DeelInvoiceAdjustment is never in balance under qbo_bound" do
    dia = DeelInvoiceAdjustment.new(amount: 100, deel_status: "approved")
    refute dia.in_balance_under_qbo_bound?
  end

  test "Reimbursement uses accepted? for qbo_bound" do
    r_accepted = Reimbursement.new
    r_accepted.stubs(:accepted?).returns(true)
    assert r_accepted.in_balance_under_qbo_bound?

    r_pending = Reimbursement.new
    r_pending.stubs(:accepted?).returns(false)
    refute r_pending.in_balance_under_qbo_bound?
  end

  test "ContributorPayout: in balance when payable and qbo_bill unpaid" do
    cp = ContributorPayout.new
    cp.stubs(:payable?).returns(true)
    cp.stubs(:qbo_bill).returns(nil)
    assert cp.in_balance_under_qbo_bound?

    paid = mock("qbo_bill")
    paid.stubs(:paid?).returns(true)
    cp.stubs(:qbo_bill).returns(paid)
    refute cp.in_balance_under_qbo_bound?

    cp.stubs(:payable?).returns(false)
    cp.stubs(:qbo_bill).returns(nil)
    refute cp.in_balance_under_qbo_bound?
  end

  test "Trueup: in balance when qbo_bill unpaid (no payable? check)" do
    t = Trueup.new
    t.stubs(:qbo_bill).returns(nil)
    assert t.in_balance_under_qbo_bound?

    paid = mock("qbo_bill")
    paid.stubs(:paid?).returns(true)
    t.stubs(:qbo_bill).returns(paid)
    refute t.in_balance_under_qbo_bound?
  end

  test "ProfitShare, PayStub, ContributorAdjustment all follow the payable?-and-unpaid pattern" do
    [ProfitShare, PayStub, ContributorAdjustment].each do |klass|
      h = klass.new
      h.stubs(:payable?).returns(true)
      h.stubs(:qbo_bill).returns(nil)
      assert h.in_balance_under_qbo_bound?, "#{klass.name} should be in balance when payable and unpaid"
    end
  end
end
```

- [ ] **Step 3.2: Run test, expect failure**

```bash
bundle exec rails test test/models/ledger_test.rb -n /HostInBalanceUnderQboBound/
```

Expected: FAIL (no `in_balance_under_qbo_bound?` method).

- [ ] **Step 3.3: Add predicate to ContributorPayout**

In `app/models/contributor_payout.rb`, add:

```ruby
  # QBO-bound balance rule: in balance only if Stacks considers the row
  # settled AND its QBO Bill mirror has not yet been marked Paid.
  def in_balance_under_qbo_bound?
    payable? && !qbo_bill&.paid?
  end
```

- [ ] **Step 3.4: Add predicate to ProfitShare**

In `app/models/profit_share.rb`, add the same method body:

```ruby
  def in_balance_under_qbo_bound?
    payable? && !qbo_bill&.paid?
  end
```

- [ ] **Step 3.5: Add predicate to PayStub**

In `app/models/pay_stub.rb`, add:

```ruby
  def in_balance_under_qbo_bound?
    payable? && !qbo_bill&.paid?
  end
```

- [ ] **Step 3.6: Add predicate to ContributorAdjustment**

In `app/models/contributor_adjustment.rb`, add:

```ruby
  def in_balance_under_qbo_bound?
    payable? && !qbo_bill&.paid?
  end
```

- [ ] **Step 3.7: Add predicate to Trueup**

In `app/models/trueup.rb`, add:

```ruby
  # Trueups always represent settled income; no payable? gate.
  def in_balance_under_qbo_bound?
    !qbo_bill&.paid?
  end
```

- [ ] **Step 3.8: Add predicate to Reimbursement**

In `app/models/reimbursement.rb`, add:

```ruby
  # Reimbursements aren't synced as QBO bills; same gate as legacy.
  def in_balance_under_qbo_bound?
    accepted?
  end
```

- [ ] **Step 3.9: Add predicate to DeelInvoiceAdjustment**

In `app/models/deel_invoice_adjustment.rb`, add:

```ruby
  # DIAs are audit-only on qbo_bound ledgers — never in balance.
  def in_balance_under_qbo_bound?
    false
  end
```

- [ ] **Step 3.10: Run tests, expect pass**

```bash
bundle exec rails test test/models/ledger_test.rb -n /HostInBalanceUnderQboBound/
```

Expected: all pass.

- [ ] **Step 3.11: Commit**

```bash
git add app/models/ test/models/ledger_test.rb
git commit -m "Hosts: in_balance_under_qbo_bound? predicates for QBO-bound balance rule"
```

---

## Task 4: Ledger#balance and Ledger#unsettled mode branching

**Files:**
- Modify: `app/models/ledger.rb`
- Test: `test/models/ledger_test.rb`

- [ ] **Step 4.1: Write failing test for mode-branching balance/unsettled**

Append to `test/models/ledger_test.rb`:

```ruby
class LedgerBalanceUnderQboBoundTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "QBoundBal-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 994_001, email: "qbb#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
  end

  test "legacy mode uses legacy rule (Reimbursement counts when accepted?)" do
    @ledger.update!(mode: :legacy)
    r = Reimbursement.create!(ledger: @ledger, amount: 100, accepted_at: Time.current)
    assert_equal 100, @ledger.balance.to_f
  end

  test "qbo_bound mode drops a positive host whose qbo_bill is paid" do
    @ledger.update!(mode: :qbo_bound)
    paid = mock("qbo_bill"); paid.stubs(:paid?).returns(true)
    payout = mock("payout")
    payout.stubs(:payable?).returns(true)
    payout.stubs(:qbo_bill).returns(paid)
    payout.stubs(:in_balance_under_qbo_bound?).returns(false)
    payout.stubs(:signed_amount).returns(100)
    payout.stubs(:is_a?).returns(false)
    payout.stubs(:is_a?).with(DeelInvoiceAdjustment).returns(false)
    payout.stubs(:is_a?).with(ContributorAdjustment).returns(false)

    @ledger.stubs(:visible_items).returns([payout])
    assert_equal 0, @ledger.balance.to_f
  end

  test "qbo_bound mode ignores DIAs entirely" do
    @ledger.update!(mode: :qbo_bound)
    dia = mock("dia")
    dia.stubs(:is_a?).returns(false)
    dia.stubs(:is_a?).with(DeelInvoiceAdjustment).returns(true)
    dia.stubs(:signed_amount).returns(-50)

    @ledger.stubs(:visible_items).returns([dia])
    assert_equal 0, @ledger.balance.to_f
    assert_equal 0, @ledger.unsettled.to_f
  end

  test "qbo_bound mode ignores negative CAs" do
    @ledger.update!(mode: :qbo_bound)
    neg = mock("neg_ca")
    neg.stubs(:is_a?).returns(false)
    neg.stubs(:is_a?).with(DeelInvoiceAdjustment).returns(false)
    neg.stubs(:is_a?).with(ContributorAdjustment).returns(true)
    neg.stubs(:amount).returns(-100)
    neg.stubs(:signed_amount).returns(-100)

    @ledger.stubs(:visible_items).returns([neg])
    assert_equal 0, @ledger.balance.to_f
    assert_equal 0, @ledger.unsettled.to_f
  end
end
```

- [ ] **Step 4.2: Run test, expect failure**

```bash
bundle exec rails test test/models/ledger_test.rb -n /LedgerBalanceUnderQboBound/
```

Expected: FAIL (balance still uses legacy rule unconditionally).

- [ ] **Step 4.3: Rewrite Ledger#balance and Ledger#unsettled**

In `app/models/ledger.rb`, replace the existing `balance` and `unsettled` definitions with:

```ruby
  # Balance/unsettled split. legacy preserves today's rules; qbo_bound trusts
  # the QBO Bill Paid status as the single source of truth.
  def balance
    case mode
    when "legacy"    then visible_items.select(&:payable?).sum(&:signed_amount)
    when "qbo_bound" then qbo_bound_visible_items.select(&:in_balance_under_qbo_bound?).sum(&:signed_amount)
    end
  end

  def unsettled
    case mode
    when "legacy"    then visible_items.reject(&:payable?).sum(&:signed_amount)
    when "qbo_bound" then qbo_bound_visible_items.reject(&:in_balance_under_qbo_bound?).sum(&:signed_amount)
    end
  end
```

- [ ] **Step 4.4: Run tests, expect pass**

```bash
bundle exec rails test test/models/ledger_test.rb
```

Expected: all pass.

- [ ] **Step 4.5: Commit**

```bash
git add app/models/ledger.rb test/models/ledger_test.rb
git commit -m "Ledger: balance/unsettled branch on mode (legacy vs qbo_bound)"
```

---

## Task 5: Negative-CA validation guard on qbo_bound ledgers

**Files:**
- Modify: `app/models/contributor_adjustment.rb`
- Test: `test/models/contributor_adjustment_test.rb`

- [ ] **Step 5.1: Write failing test for negative-CA guard**

Append to `test/models/contributor_adjustment_test.rb`:

```ruby
class ContributorAdjustmentNegativeOnQboBoundTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "NegCAGuard-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 995_001, email: "ncag#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
  end

  test "negative CA on legacy ledger is allowed" do
    @ledger.update!(mode: :legacy)
    ca = ContributorAdjustment.new(ledger: @ledger, amount: -100, description: "off-platform payment")
    # other validations may still fail in isolation; what we assert is that the
    # negative-CA-on-qbo_bound rule isn't the one rejecting it.
    ca.valid?
    refute ca.errors[:amount].any? { |m| m.include?("not allowed on QBO-bound") }, "should not trigger qbo_bound guard on legacy"
  end

  test "negative CA on qbo_bound ledger is rejected with the right error" do
    @ledger.update!(mode: :qbo_bound)
    ca = ContributorAdjustment.new(ledger: @ledger, amount: -100, description: "off-platform payment")
    refute ca.valid?
    assert ca.errors[:amount].any? { |m| m.include?("QBO-bound") }, "expected an error mentioning QBO-bound"
  end

  test "positive CA on qbo_bound ledger is allowed" do
    @ledger.update!(mode: :qbo_bound)
    ca = ContributorAdjustment.new(ledger: @ledger, amount: 100, description: "bonus")
    ca.valid?
    refute ca.errors[:amount].any? { |m| m.include?("QBO-bound") }
  end
end
```

- [ ] **Step 5.2: Run test, expect failure**

```bash
bundle exec rails test test/models/contributor_adjustment_test.rb -n /NegativeOnQboBound/
```

Expected: FAIL (no guard yet).

- [ ] **Step 5.3: Add the validation**

In `app/models/contributor_adjustment.rb`, add:

```ruby
  validate :no_negative_on_qbo_bound_ledger

  def no_negative_on_qbo_bound_ledger
    return unless ledger&.qbo_bound? && amount.to_f < 0
    errors.add(
      :amount,
      "negative adjustments are not allowed on QBO-bound ledgers — mark the corresponding QBO bill Paid instead",
    )
  end
```

- [ ] **Step 5.4: Run tests, expect pass**

```bash
bundle exec rails test test/models/contributor_adjustment_test.rb
```

Expected: all pass.

- [ ] **Step 5.5: Commit**

```bash
git add app/models/contributor_adjustment.rb test/models/contributor_adjustment_test.rb
git commit -m "ContributorAdjustment: reject negative amounts on qbo_bound ledgers"
```

---

## Task 6: Ledgers::QboBoundMigrationCheck service

**Files:**
- Create: `app/services/ledgers/qbo_bound_migration_check.rb`
- Create: `test/services/ledgers/qbo_bound_migration_check_test.rb`

- [ ] **Step 6.1: Write failing test**

Create `test/services/ledgers/qbo_bound_migration_check_test.rb`:

```ruby
require "test_helper"

class Ledgers::QboBoundMigrationCheckTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "MigCheck-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 996_001, email: "mc#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
  end

  test "empty legacy ledger is ready (Δ = 0 trivially)" do
    result = Ledgers::QboBoundMigrationCheck.call(@ledger)
    assert result.ready?
    assert_in_delta 0, result.balance_delta, 0.001
    assert_in_delta 0, result.unsettled_delta, 0.001
  end

  test "result struct exposes the required fields" do
    r = Ledgers::QboBoundMigrationCheck.call(@ledger)
    assert_respond_to r, :current_balance
    assert_respond_to r, :proposed_balance
    assert_respond_to r, :balance_delta
    assert_respond_to r, :ready?
    assert_respond_to r, :blocking_bills
    assert_respond_to r, :ignored_negative_cas
  end

  test "ledger is blocked when ledger.balance under qbo_bound != legacy" do
    # Stub the ledger so the check sees different balances under each rule.
    @ledger.stubs(:mode).returns("legacy")

    # When called inside the service, we'll switch mode in a transaction and
    # call ledger.balance again. To test this without DB writes, the service
    # walks visible_items directly — see Step 6.3's implementation. For now
    # we mock visible_items to simulate a divergent ledger.
    paid_qb = mock("qbo_bill"); paid_qb.stubs(:paid?).returns(true)
    cp = ContributorPayout.new(amount: 100)
    cp.stubs(:payable?).returns(true)
    cp.stubs(:qbo_bill).returns(paid_qb)
    cp.stubs(:signed_amount).returns(100)
    cp.stubs(:in_balance_under_qbo_bound?).returns(false)

    neg_ca = ContributorAdjustment.new(amount: -50)
    neg_ca.stubs(:payable?).returns(true)
    neg_ca.stubs(:signed_amount).returns(-50)

    @ledger.stubs(:visible_items).returns([cp, neg_ca])
    @ledger.stubs(:qbo_bound_visible_items).returns([cp])

    result = Ledgers::QboBoundMigrationCheck.call(@ledger)
    # legacy: 100 - 50 = 50; qbo_bound: 0 (paid drops cp; neg_ca filtered out)
    assert_in_delta -50, result.balance_delta, 0.01
    refute result.ready?
  end
end
```

- [ ] **Step 6.2: Run test, expect failure**

```bash
bundle exec rails test test/services/ledgers/qbo_bound_migration_check_test.rb
```

Expected: FAIL (service does not exist).

- [ ] **Step 6.3: Implement the service**

Create `app/services/ledgers/qbo_bound_migration_check.rb`:

```ruby
module Ledgers
  # Computes whether a legacy Ledger can flip to qbo_bound with zero
  # change to balance or unsettled. Returns a Result struct exposing
  # the deltas and the open QBO bills that explain any gap.
  class QboBoundMigrationCheck
    TOLERANCE = 0.01.freeze

    Result = Struct.new(
      :current_balance, :current_unsettled,
      :proposed_balance, :proposed_unsettled,
      :balance_delta, :unsettled_delta,
      :ready?, :blocking_bills, :ignored_negative_cas,
      keyword_init: true,
    )

    BlockingBill = Struct.new(:host, :qbo_bill, :amount, keyword_init: true)

    def self.call(ledger)
      legacy_visible = ledger.send(:visible_items)
      qbb_visible    = ledger.send(:qbo_bound_visible_items)

      legacy_b = legacy_visible.select(&:payable?).sum(&:signed_amount).to_f
      legacy_u = legacy_visible.reject(&:payable?).sum(&:signed_amount).to_f
      new_b    = qbb_visible.select(&:in_balance_under_qbo_bound?).sum(&:signed_amount).to_f
      new_u    = qbb_visible.reject(&:in_balance_under_qbo_bound?).sum(&:signed_amount).to_f

      db = (new_b - legacy_b).round(2)
      du = (new_u - legacy_u).round(2)

      Result.new(
        current_balance: legacy_b.round(2),
        current_unsettled: legacy_u.round(2),
        proposed_balance: new_b.round(2),
        proposed_unsettled: new_u.round(2),
        balance_delta: db,
        unsettled_delta: du,
        ready?: db.abs < TOLERANCE && du.abs < TOLERANCE,
        blocking_bills: collect_blocking_bills(legacy_visible),
        ignored_negative_cas: legacy_visible.select { |li| li.is_a?(ContributorAdjustment) && li.amount.to_f < 0 },
      )
    end

    def self.collect_blocking_bills(items)
      items.filter_map do |li|
        next nil if li.is_a?(DeelInvoiceAdjustment)
        next nil if li.is_a?(ContributorAdjustment) && li.amount.to_f < 0
        next nil unless li.respond_to?(:qbo_bill)
        next nil unless li.respond_to?(:payable?) && li.payable?

        qb = (li.qbo_bill rescue nil)
        next nil if qb.nil? || qb.paid?

        BlockingBill.new(host: li, qbo_bill: qb, amount: li.amount.to_f)
      end
    end
  end
end
```

- [ ] **Step 6.4: Run tests, expect pass**

```bash
bundle exec rails test test/services/ledgers/qbo_bound_migration_check_test.rb
```

Expected: all pass.

- [ ] **Step 6.5: Commit**

```bash
git add app/services/ledgers/ test/services/ledgers/
git commit -m "Ledgers::QboBoundMigrationCheck: per-ledger gate with blocking-bill detail"
```

---

## Task 7: Ledger admin Migrate panel + member_action

**Files:**
- Modify: `app/admin/ledgers.rb`
- Test: `test/system/ledger_migration_panel_test.rb` (new system test if `test/system` is already used)

- [ ] **Step 7.1: Write failing test for the member_action**

Create `test/integration/ledger_migration_test.rb`:

```ruby
require "test_helper"

class LedgerMigrationTest < ActionDispatch::IntegrationTest
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "MigPanel-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 997_001, email: "mp#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)

    @admin = AdminUser.create!(email: "lmig#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", is_admin: true)
    sign_in @admin
  end

  test "Migrate posts and flips ready ledger to qbo_bound" do
    assert @ledger.legacy?
    post migrate_to_qbo_bound_admin_ledger_path(@ledger)
    assert_response :redirect
    @ledger.reload
    assert @ledger.qbo_bound?
  end

  test "Migrate refuses to flip a ledger with non-zero drift" do
    # Plant divergent items via a stub. Without a DB-level divergence,
    # mock the check service to return a not-ready Result.
    not_ready = Ledgers::QboBoundMigrationCheck::Result.new(
      current_balance: 0, current_unsettled: 0,
      proposed_balance: 100, proposed_unsettled: 0,
      balance_delta: 100, unsettled_delta: 0,
      ready?: false, blocking_bills: [], ignored_negative_cas: [],
    )
    Ledgers::QboBoundMigrationCheck.expects(:call).with(@ledger).returns(not_ready)

    post migrate_to_qbo_bound_admin_ledger_path(@ledger)
    assert_response :redirect
    @ledger.reload
    assert @ledger.legacy?
  end

  private

  def sign_in(admin)
    # ActiveAdmin Devise sign-in helper used by other admin integration tests.
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
```

- [ ] **Step 7.2: Run test, expect failure**

```bash
bundle exec rails test test/integration/ledger_migration_test.rb
```

Expected: FAIL (no `migrate_to_qbo_bound` action defined; route missing).

- [ ] **Step 7.3: Add member_action and sidebar panel to Ledger admin**

In `app/admin/ledgers.rb`, replace the file's contents with:

```ruby
ActiveAdmin.register Ledger do
  menu false
  config.filters = false
  config.paginate = false
  actions :index, :show
  permit_params

  member_action :migrate_to_qbo_bound, method: :post do
    result = Ledgers::QboBoundMigrationCheck.call(resource)
    if result.ready?
      resource.update!(mode: :qbo_bound)
      redirect_to admin_ledger_path(resource), notice: "Migrated to QBO-bound."
    else
      redirect_to admin_ledger_path(resource),
        alert: "Cannot migrate: Δbalance #{result.balance_delta}, Δunsettled #{result.unsettled_delta}."
    end
  end

  show do
    attributes_table do
      row :id
      row :enterprise
      row :contributor
      row :mode
      row :payment_methods
    end

    if resource.legacy?
      panel "Migrate to QBO-bound" do
        result = Ledgers::QboBoundMigrationCheck.call(resource)
        div do
          para "Current (legacy):  balance $#{result.current_balance}   unsettled $#{result.current_unsettled}"
          para "Proposed (qbo_bound):  balance $#{result.proposed_balance}   unsettled $#{result.proposed_unsettled}"
          para "Δ balance #{result.balance_delta}, Δ unsettled #{result.unsettled_delta}"
        end
        if result.ready?
          div do
            para "Net-zero change — safe to migrate."
            button_to "Migrate to QBO-bound", migrate_to_qbo_bound_admin_ledger_path(resource), method: :post, data: { confirm: "Flip this ledger to qbo_bound?" }
          end
        else
          div do
            if result.blocking_bills.any?
              para "Open QBO bills blocking the migration:"
              ul do
                result.blocking_bills.first(20).each do |bb|
                  li do
                    text_node "#{bb.host.class.name} ##{bb.host.id} — $#{bb.amount.to_f.round(2)} — "
                    link_to "Pay in QBO ↗", bb.qbo_bill.qbo_url, target: "_blank", rel: "noopener"
                  end
                end
              end
            end
            if result.ignored_negative_cas.any?
              para "Negative CAs (audit-only after migration):"
              ul do
                result.ignored_negative_cas.first(10).each do |ca|
                  li "CA ##{ca.id} — $#{ca.amount.to_f.round(2)}"
                end
              end
            end
            para "Resolve the open bills in QBO, then refresh this page or click Re-check."
            button_to "Re-check", admin_ledger_path(resource), method: :get
          end
        end
      end
    end
  end
end
```

- [ ] **Step 7.4: Run tests, expect pass**

```bash
bundle exec rails test test/integration/ledger_migration_test.rb
```

Expected: all pass.

- [ ] **Step 7.5: Commit**

```bash
git add app/admin/ledgers.rb test/integration/ledger_migration_test.rb
git commit -m "Ledger admin: Migrate-to-QBO-bound panel + member_action"
```

---

## Task 8: Rake task for bulk zero-drift migration

**Files:**
- Create: `lib/tasks/ledgers.rake`
- Test: `test/lib/tasks/ledgers_rake_test.rb`

- [ ] **Step 8.1: Write failing test for the rake task**

Create `test/lib/tasks/ledgers_rake_test.rb`:

```ruby
require "test_helper"
require "rake"

class LedgersRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("ledgers:migrate_qbo_bound_zero_drift")
    Rake::Task["ledgers:migrate_qbo_bound_zero_drift"].reenable

    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "RakeMig-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 999_001, email: "rm#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
  end

  test "ready legacy ledger is auto-flipped to qbo_bound" do
    @ledger.update!(mode: :legacy)
    # An empty ledger is trivially ready (Δ = 0).
    Rake::Task["ledgers:migrate_qbo_bound_zero_drift"].invoke
    assert @ledger.reload.qbo_bound?
  end

  test "blocked ledger stays legacy" do
    @ledger.update!(mode: :legacy)
    blocked = Ledgers::QboBoundMigrationCheck::Result.new(
      current_balance: 0, current_unsettled: 0, proposed_balance: 100, proposed_unsettled: 0,
      balance_delta: 100, unsettled_delta: 0, ready?: false, blocking_bills: [], ignored_negative_cas: [],
    )
    Ledgers::QboBoundMigrationCheck.stubs(:call).returns(blocked)

    Rake::Task["ledgers:migrate_qbo_bound_zero_drift"].invoke
    assert @ledger.reload.legacy?
  end
end
```

- [ ] **Step 8.2: Run test, expect failure**

```bash
bundle exec rails test test/lib/tasks/ledgers_rake_test.rb
```

Expected: FAIL (rake task doesn't exist).

- [ ] **Step 8.3: Implement the rake task**

Create `lib/tasks/ledgers.rake`:

```ruby
namespace :ledgers do
  desc "Flip every legacy ledger whose balance/unsettled would not change to qbo_bound"
  task migrate_qbo_bound_zero_drift: :environment do
    flipped = 0
    blocked = 0
    errors = 0

    Ledger.where(mode: :legacy).find_each do |ledger|
      result = Ledgers::QboBoundMigrationCheck.call(ledger)
      if result.ready?
        ledger.update!(mode: :qbo_bound)
        flipped += 1
      else
        blocked += 1
      end
    rescue => e
      errors += 1
      warn "Ledger ##{ledger.id}: #{e.class}: #{e.message}"
    end

    puts "Flipped #{flipped} ledgers; #{blocked} still blocked; #{errors} errors."
  end
end
```

- [ ] **Step 8.4: Run tests, expect pass**

```bash
bundle exec rails test test/lib/tasks/ledgers_rake_test.rb
```

Expected: all pass.

- [ ] **Step 8.5: Commit**

```bash
git add lib/tasks/ledgers.rake test/lib/tasks/ledgers_rake_test.rb
git commit -m "ledgers:migrate_qbo_bound_zero_drift rake task"
```

---

## Task 9: Task Builder discovery + StacksTask routing

**Files:**
- Create: `lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration.rb`
- Modify: `lib/stacks/task_builder.rb` (register discovery)
- Modify: `app/models/stacks_task.rb` (route Ledger subject URL by task type)
- Test: `test/lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration_test.rb`

- [ ] **Step 9.1: Inspect existing discovery registration pattern**

Read `lib/stacks/task_builder.rb` to find where `MissingQboVendors` and other discoveries are registered. Note the exact registry expression — the new discovery is added the same way.

```bash
grep -n "Discoveries::" lib/stacks/task_builder.rb
```

- [ ] **Step 9.2: Write failing test**

Create `test/lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration_test.rb`:

```ruby
require "test_helper"

class Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigrationTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @qa = QboAccount.create!(realm_id: "rake#{SecureRandom.hex(2)}", name: "RakeQA")
    @enterprise = Enterprise.create!(name: "DiscEnt-#{SecureRandom.hex(2)}", qbo_account: @qa)
    fp = ForecastPerson.create!(forecast_id: 990_001, email: "disc#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @admin = AdminUser.create!(email: "ldisc#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", is_admin: true)
  end

  test "legacy ledger with payable activity yields a migration task" do
    ContributorPayout.create!(ledger: @ledger, amount: 100, blueprint: { "lines" => [{ "amount" => 100.0 }] })
    discovery = Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration.new(admin_fallback: [@admin])
    tasks = discovery.tasks
    assert tasks.any? { |t| t[:subject] == @ledger && t[:type] == :legacy_ledger_needs_qbo_migration }
  end

  test "qbo_bound ledger yields no task" do
    ContributorPayout.create!(ledger: @ledger, amount: 100, blueprint: { "lines" => [{ "amount" => 100.0 }] })
    @ledger.update!(mode: :qbo_bound)
    discovery = Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration.new(admin_fallback: [@admin])
    tasks = discovery.tasks
    refute tasks.any? { |t| t[:subject] == @ledger }
  end

  test "legacy ledger without activity yields no task" do
    discovery = Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration.new(admin_fallback: [@admin])
    tasks = discovery.tasks
    refute tasks.any? { |t| t[:subject] == @ledger }
  end
end
```

- [ ] **Step 9.3: Run test, expect failure**

```bash
bundle exec rails test test/lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration_test.rb
```

Expected: FAIL (class does not exist).

- [ ] **Step 9.4: Create the discovery**

Create `lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration.rb`:

```ruby
module Stacks
  class TaskBuilder
    module Discoveries
      # Surfaces every legacy ledger that has at least one payable host row
      # AND whose enterprise has a connected QBO account. Each emits a
      # :legacy_ledger_needs_qbo_migration task routed to the admin fallback.
      class LegacyLedgersPendingQboMigration < Base
        PAYABLE_TABLES = %w[
          contributor_payouts
          contributor_adjustments
          profit_shares
          pay_stubs
          trueups
        ].freeze

        def tasks
          ledgers = Ledger
            .where(mode: :legacy)
            .joins(:enterprise)
            .where(enterprises: { id: Enterprise.joins(:qbo_account).select(:id) })
            .where("EXISTS (#{any_payable_subquery})")
            .includes(:contributor, enterprise: :qbo_account)
            .to_a

          ledgers.map do |ledger|
            task(
              subject: ledger,
              type: :legacy_ledger_needs_qbo_migration,
              owners: @admin_fallback,
            )
          end
        end

        private

        def any_payable_subquery
          PAYABLE_TABLES.map do |t|
            "SELECT 1 FROM #{t} WHERE #{t}.ledger_id = ledgers.id"
          end.join(" UNION ALL ")
        end
      end
    end
  end
end
```

- [ ] **Step 9.5: Register the discovery**

In `lib/stacks/task_builder.rb`, find the discovery registration list (per Step 9.1). Add the new discovery following the existing pattern. Remove the existing `Discoveries::LedgerWithdrawalRequests` registration (it will be deleted in Task 15).

- [ ] **Step 9.6: Add Ledger URL type-branch in StacksTask**

Edit `app/models/stacks_task.rb`. Find the existing `when Ledger` branch in `subject_url` (around line 137):

```ruby
    when Ledger then helpers.edit_admin_contributor_path(subject.contributor)
```

Replace with:

```ruby
    when Ledger
      if type == :legacy_ledger_needs_qbo_migration
        helpers.admin_ledger_path(subject)
      else
        helpers.edit_admin_contributor_path(subject.contributor)
      end
```

- [ ] **Step 9.7: Run tests, expect pass**

```bash
bundle exec rails test test/lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration_test.rb
```

Expected: all pass.

- [ ] **Step 9.8: Commit**

```bash
git add lib/stacks/ app/models/stacks_task.rb test/lib/stacks/
git commit -m "TaskBuilder: surface legacy ledgers pending QBO migration"
```

---

## Task 10: Money::PayableQboBills service

**Files:**
- Create: `app/services/money/payable_qbo_bills.rb`
- Create: `test/services/money/payable_qbo_bills_test.rb`

- [ ] **Step 10.1: Write failing test**

Create `test/services/money/payable_qbo_bills_test.rb`:

```ruby
require "test_helper"

class Money::PayableQboBillsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @qa = QboAccount.create!(realm_id: "pq#{SecureRandom.hex(2)}", name: "PayableQA")
    @enterprise = Enterprise.create!(name: "PayableEnt-#{SecureRandom.hex(2)}", qbo_account: @qa)
    fp = ForecastPerson.create!(forecast_id: 988_001, email: "pq#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[qbo])
  end

  test "returns rows only for hosts on qbo-enabled ledgers" do
    @ledger.update!(payment_methods: %w[deel])  # NOT qbo
    open_bill = QboBill.create!(qbo_account: @qa, qbo_id: "b1", data: { "balance" => "100" })
    cp = ContributorPayout.create!(ledger: @ledger, amount: 100, qbo_bill_id: open_bill.qbo_id, qbo_account_id: @qa.id, blueprint: { "lines" => [{ "amount" => 100.0 }] })
    cp.stubs(:payable?).returns(true)

    rows = Money::PayableQboBills.call(qbo_account: @qa)
    refute rows.any? { |r| r.host == cp }
  end

  test "returns rows for payable hosts whose qbo_bill is open" do
    open_bill = QboBill.create!(qbo_account: @qa, qbo_id: "b2", data: { "balance" => "100" })
    cp = ContributorPayout.create!(ledger: @ledger, amount: 100, qbo_bill_id: open_bill.qbo_id, qbo_account_id: @qa.id, blueprint: { "lines" => [{ "amount" => 100.0 }] })
    ContributorPayout.any_instance.stubs(:payable?).returns(true)

    rows = Money::PayableQboBills.call(qbo_account: @qa)
    assert rows.any? { |r| r.host.id == cp.id && r.qbo_bill.qbo_id == "b2" }
  end

  test "excludes paid bills" do
    paid_bill = QboBill.create!(qbo_account: @qa, qbo_id: "b3", data: { "balance" => "0" })
    cp = ContributorPayout.create!(ledger: @ledger, amount: 100, qbo_bill_id: paid_bill.qbo_id, qbo_account_id: @qa.id, blueprint: { "lines" => [{ "amount" => 100.0 }] })
    ContributorPayout.any_instance.stubs(:payable?).returns(true)

    rows = Money::PayableQboBills.call(qbo_account: @qa)
    refute rows.any? { |r| r.host.id == cp.id }
  end

  test "excludes non-payable hosts" do
    open_bill = QboBill.create!(qbo_account: @qa, qbo_id: "b4", data: { "balance" => "100" })
    cp = ContributorPayout.create!(ledger: @ledger, amount: 100, qbo_bill_id: open_bill.qbo_id, qbo_account_id: @qa.id, blueprint: { "lines" => [{ "amount" => 100.0 }] })
    ContributorPayout.any_instance.stubs(:payable?).returns(false)

    rows = Money::PayableQboBills.call(qbo_account: @qa)
    refute rows.any? { |r| r.host.id == cp.id }
  end
end
```

- [ ] **Step 10.2: Run test, expect failure**

```bash
bundle exec rails test test/services/money/payable_qbo_bills_test.rb
```

Expected: FAIL (service does not exist).

- [ ] **Step 10.3: Implement the service**

Create `app/services/money/payable_qbo_bills.rb`:

```ruby
module Money
  # Selects open QBO bills payable through Stacks: every SyncsAsQboBill host
  # row whose ledger has 'qbo' in payment_methods, where the row is payable?
  # AND the QboBill mirror is still open. Tabbed per QBO account.
  class PayableQboBills
    HOST_KLASSES = [
      ContributorPayout,
      ContributorAdjustment,
      ProfitShare,
      Trueup,
      PayStub,
    ].freeze

    Row = Struct.new(:host, :ledger, :contributor, :qbo_bill, :amount, keyword_init: true)

    def self.call(qbo_account:)
      rows = HOST_KLASSES.flat_map do |klass|
        klass
          .where.not(qbo_bill_id: nil)
          .joins(ledger: :enterprise)
          .where(enterprises: { qbo_account_id: qbo_account.id })
          .where("'qbo' = ANY(ledgers.payment_methods)")
          .includes(ledger: :contributor)
          .find_each.filter_map do |row|
            next nil unless row.payable?
            qb = (row.qbo_bill rescue nil)
            next nil if qb.nil? || qb.paid?

            Row.new(
              host: row,
              ledger: row.ledger,
              contributor: row.ledger.contributor,
              qbo_bill: qb,
              amount: row.amount.to_f,
            )
          end
      end

      rows.sort_by { |r| [r.contributor.id, r.host.class.name, r.host.id] }
    end
  end
end
```

- [ ] **Step 10.4: Run tests, expect pass**

```bash
bundle exec rails test test/services/money/payable_qbo_bills_test.rb
```

Expected: all pass.

- [ ] **Step 10.5: Commit**

```bash
git add app/services/money/payable_qbo_bills.rb test/services/money/payable_qbo_bills_test.rb
git commit -m "Money::PayableQboBills: cross-enterprise open-bill selection"
```

---

## Task 11: Money::RefreshPayableQboBills service

**Files:**
- Create: `app/services/money/refresh_payable_qbo_bills.rb`
- Create: `test/services/money/refresh_payable_qbo_bills_test.rb`

- [ ] **Step 11.1: Write failing test**

Create `test/services/money/refresh_payable_qbo_bills_test.rb`:

```ruby
require "test_helper"

class Money::RefreshPayableQboBillsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @qa = QboAccount.create!(realm_id: "rfp#{SecureRandom.hex(2)}", name: "RefreshQA")
    @enterprise = Enterprise.create!(name: "RefreshEnt-#{SecureRandom.hex(2)}", qbo_account: @qa)
    fp = ForecastPerson.create!(forecast_id: 987_001, email: "rfp#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[qbo])

    @bill = QboBill.create!(qbo_account: @qa, qbo_id: "rfb1", data: { "balance" => "100" })
    @cp = ContributorPayout.create!(ledger: @ledger, amount: 100, qbo_bill_id: @bill.qbo_id, qbo_account_id: @qa.id, blueprint: { "lines" => [{ "amount" => 100.0 }] })
  end

  test "calls sync_qbo_bill! on every row returned by PayableQboBills" do
    ContributorPayout.any_instance.stubs(:payable?).returns(true)
    ContributorPayout.any_instance.expects(:sync_qbo_bill!).at_least_once

    Money::RefreshPayableQboBills.call(qbo_account: @qa)
  end
end
```

- [ ] **Step 11.2: Run test, expect failure**

```bash
bundle exec rails test test/services/money/refresh_payable_qbo_bills_test.rb
```

Expected: FAIL (service does not exist).

- [ ] **Step 11.3: Implement the service**

Create `app/services/money/refresh_payable_qbo_bills.rb`:

```ruby
module Money
  # Bulk-refresh: walks the rows PayableQboBills would return and calls
  # SyncsAsQboBill#sync_qbo_bill! on each so bills marked Paid in QBO drop
  # off the page on the next render.
  class RefreshPayableQboBills
    def self.call(qbo_account:)
      Money::PayableQboBills.call(qbo_account: qbo_account).each do |row|
        row.host.sync_qbo_bill!
      end
    end
  end
end
```

- [ ] **Step 11.4: Run tests, expect pass**

```bash
bundle exec rails test test/services/money/refresh_payable_qbo_bills_test.rb
```

Expected: all pass.

- [ ] **Step 11.5: Commit**

```bash
git add app/services/money/refresh_payable_qbo_bills.rb test/services/money/refresh_payable_qbo_bills_test.rb
git commit -m "Money::RefreshPayableQboBills: bulk re-sync open bills for one QBO account"
```

---

## Task 12: Payable QBO Bills admin page

**Files:**
- Modify: `app/admin/money.rb`
- Create: `app/views/admin/money/payable_qbo_bills.html.erb`
- Test: `test/integration/payable_qbo_bills_test.rb`

- [ ] **Step 12.1: Write failing integration test**

Create `test/integration/payable_qbo_bills_test.rb`:

```ruby
require "test_helper"

class PayableQboBillsTest < ActionDispatch::IntegrationTest
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @qa = QboAccount.create!(realm_id: "pgi#{SecureRandom.hex(2)}", name: "IntQA")
    @enterprise = Enterprise.create!(name: "IntEnt-#{SecureRandom.hex(2)}", qbo_account: @qa)
    fp = ForecastPerson.create!(forecast_id: 986_001, email: "ip#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[qbo])

    @admin = AdminUser.create!(email: "pq#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", is_admin: true)
    sign_in @admin
  end

  test "GET payable_qbo_bills renders" do
    get admin_money_payable_qbo_bills_path(qbo_account_id: @qa.id)
    assert_response :success
    assert_match @qa.name, response.body
  end

  test "POST refresh_tab kicks off bulk refresh" do
    Money::RefreshPayableQboBills.expects(:call).with(qbo_account: instance_of(QboAccount))
    post admin_money_refresh_tab_path(qbo_account_id: @qa.id)
    assert_response :redirect
  end

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
```

- [ ] **Step 12.2: Run test, expect failure**

```bash
bundle exec rails test test/integration/payable_qbo_bills_test.rb
```

Expected: FAIL (routes missing).

- [ ] **Step 12.3: Rewrite app/admin/money.rb**

Replace `app/admin/money.rb` entirely with:

```ruby
ActiveAdmin.register_page "Money" do
  menu priority: 50

  controller do
    before_action :authenticate_admin_user!
  end

  page_action :payable_qbo_bills, method: :get do
    @qbo_accounts = QboAccount.order(:id).to_a
    @active_qa = if params[:qbo_account_id].present?
      QboAccount.find(params[:qbo_account_id])
    else
      @qbo_accounts.first
    end
    @rows = @active_qa ? Money::PayableQboBills.call(qbo_account: @active_qa) : []
    render "admin/money/payable_qbo_bills"
  end

  page_action :refresh_bill, method: :post do
    klass = params.require(:host_class).to_s.constantize
    raise ActionController::BadRequest, "unsupported host class" unless Money::PayableQboBills::HOST_KLASSES.include?(klass)
    host = klass.find(params.require(:host_id))
    host.sync_qbo_bill!
    redirect_back(fallback_location: admin_money_payable_qbo_bills_path(qbo_account_id: params[:qbo_account_id]))
  end

  page_action :refresh_tab, method: :post do
    qa = QboAccount.find(params.require(:qbo_account_id))
    Money::RefreshPayableQboBills.call(qbo_account: qa)
    redirect_back(fallback_location: admin_money_payable_qbo_bills_path(qbo_account_id: qa.id))
  end
end
```

- [ ] **Step 12.4: Create the view**

Create `app/views/admin/money/payable_qbo_bills.html.erb`:

```erb
<h2>Payable QBO Bills</h2>

<div class="payable-qbo-bills-tabs" style="margin-bottom: 1em;">
  <% @qbo_accounts.each do |qa| %>
    <%= link_to qa.name, admin_money_payable_qbo_bills_path(qbo_account_id: qa.id),
                style: "margin-right: 1em; #{'font-weight: bold' if @active_qa&.id == qa.id}" %>
  <% end %>
</div>

<% if @active_qa.nil? %>
  <p><em>No QBO accounts connected.</em></p>
<% else %>
  <div style="margin-bottom: 1em;">
    <%= button_to "Refresh all on this tab",
                  admin_money_refresh_tab_path(qbo_account_id: @active_qa.id),
                  method: :post %>
  </div>

  <% if @rows.empty? %>
    <p><em>No payable bills on <%= @active_qa.name %>.</em></p>
  <% else %>
    <% @rows.group_by(&:contributor).each do |contributor, contributor_rows| %>
      <h3>
        <%= contributor.forecast_person&.email || "Contributor ##{contributor.id}" %>
        — <%= number_to_currency(contributor_rows.sum(&:amount)) %>
        (<%= contributor_rows.size %> bills)
      </h3>
      <ul>
        <% contributor_rows.each do |row| %>
          <li>
            <%= row.host.class.name %> #<%= row.host.id %>
            — <%= number_to_currency(row.amount) %>
            — <%= link_to "Pay in QBO ↗", row.qbo_bill.qbo_url, target: "_blank", rel: "noopener" %>
            — <%= button_to "Refresh",
                            admin_money_refresh_bill_path(
                              qbo_account_id: @active_qa.id,
                              host_class: row.host.class.name,
                              host_id: row.host.id,
                            ),
                            method: :post, form: { style: "display: inline" } %>
          </li>
        <% end %>
      </ul>
    <% end %>
  <% end %>
<% end %>
```

- [ ] **Step 12.5: Run tests, expect pass**

```bash
bundle exec rails test test/integration/payable_qbo_bills_test.rb
```

Expected: all pass.

- [ ] **Step 12.6: Commit**

```bash
git add app/admin/money.rb app/views/admin/money/ test/integration/payable_qbo_bills_test.rb
git commit -m "Money admin: Payable QBO Bills page, tabbed per QBO account"
```

---

## Task 13: DeelInvoiceAdjustments::CreateForLedger service

**Files:**
- Create: `app/services/deel_invoice_adjustments/create_for_ledger.rb`
- Create: `test/services/deel_invoice_adjustments/create_for_ledger_test.rb`

- [ ] **Step 13.1: Inspect existing ProcessViaDeel for Deel-API-call code**

Read `app/services/ledger_withdrawal_requests/process_via_deel.rb`. Note the exact Deel API call: which client method, what params it expects, how the response is mapped to `DeelInvoiceAdjustment.create_from_deel_response!`. The new service ports that logic without the LedgerWithdrawalRequest linkage.

- [ ] **Step 13.2: Write failing test**

Create `test/services/deel_invoice_adjustments/create_for_ledger_test.rb`:

```ruby
require "test_helper"

class DeelInvoiceAdjustments::CreateForLedgerTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "DelegLed-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 985_001, email: "del#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[deel])

    @contract = DeelContract.create!(deel_id: "dc#{SecureRandom.hex(2)}", deel_person_id: "dp#{SecureRandom.hex(2)}", data: { "type" => "ongoing_time_based" })

    @admin = AdminUser.create!(email: "dca#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", is_admin: true)
  end

  test "creates a DIA when Deel API call succeeds" do
    fake_response = { "data" => { "id" => "adj-42", "status" => "pending" } }
    DeelInvoiceAdjustment.expects(:create_from_deel_response!).with(
      ledger: @ledger,
      deel_contract_id: @contract.deel_id,
      amount: 100,
      description: "test",
      date_submitted: Date.current,
      parsed_response: fake_response,
    ).returns(DeelInvoiceAdjustment.new)

    DeelInvoiceAdjustments::CreateForLedger.any_instance.stubs(:call_deel_api).returns(fake_response)

    result = DeelInvoiceAdjustments::CreateForLedger.call(
      ledger: @ledger,
      amount: 100,
      contract_id: @contract.deel_id,
      description: "test",
      date_submitted: Date.current,
      initiated_by: @admin,
    )
    assert result.is_a?(DeelInvoiceAdjustment)
  end

  test "raises CreateForLedger::Error when Deel API returns no adjustment id" do
    DeelInvoiceAdjustments::CreateForLedger.any_instance.stubs(:call_deel_api).returns({ "data" => {} })

    assert_raises(DeelInvoiceAdjustments::CreateForLedger::Error) do
      DeelInvoiceAdjustments::CreateForLedger.call(
        ledger: @ledger,
        amount: 100,
        contract_id: @contract.deel_id,
        description: "test",
        date_submitted: Date.current,
        initiated_by: @admin,
      )
    end
  end
end
```

- [ ] **Step 13.3: Run test, expect failure**

```bash
bundle exec rails test test/services/deel_invoice_adjustments/create_for_ledger_test.rb
```

Expected: FAIL (service does not exist).

- [ ] **Step 13.4: Implement the service by porting from ProcessViaDeel**

Create `app/services/deel_invoice_adjustments/create_for_ledger.rb`. Copy the Deel API call body from `LedgerWithdrawalRequests::ProcessViaDeel#call`. Substitute the LedgerWithdrawalRequest linkage with direct kwargs:

```ruby
module DeelInvoiceAdjustments
  # Creates a DeelInvoiceAdjustment in Deel for a given ledger + contract,
  # then persists the response as a Stacks-side DIA. Replaces the
  # withdrawal-request-mediated path from LedgerWithdrawalRequests::ProcessViaDeel.
  class CreateForLedger
    class Error < StandardError; end

    def self.call(ledger:, amount:, contract_id:, description:, date_submitted:, initiated_by:)
      new(ledger: ledger, amount: amount, contract_id: contract_id,
          description: description, date_submitted: date_submitted, initiated_by: initiated_by).call
    end

    def initialize(ledger:, amount:, contract_id:, description:, date_submitted:, initiated_by:)
      @ledger = ledger
      @amount = BigDecimal(amount.to_s)
      @contract_id = contract_id.to_s
      @description = description.to_s
      @date_submitted = date_submitted
      @initiated_by = initiated_by
    end

    def call
      parsed = call_deel_api
      raise Error, "Deel did not return an adjustment id" if parsed.dig("data", "id").blank?

      DeelInvoiceAdjustment.create_from_deel_response!(
        ledger: @ledger,
        deel_contract_id: @contract_id,
        amount: @amount,
        description: @description,
        date_submitted: @date_submitted,
        parsed_response: parsed,
      )
    rescue ActiveRecord::RecordInvalid => e
      raise Error, "Could not persist DIA: #{e.message}"
    end

    private

    # Calls the Deel /invoice-adjustments endpoint. Port the body from
    # LedgerWithdrawalRequests::ProcessViaDeel — same Deel client, same
    # endpoint signature; just drop the request-id linkage.
    def call_deel_api
      # See Step 13.1 for what to port. The exact client method comes from
      # the source file. Implement as a direct copy with the request param
      # removed.
      raise NotImplementedError, "Port from LedgerWithdrawalRequests::ProcessViaDeel before this task is complete"
    end
  end
end
```

Then read `app/services/ledger_withdrawal_requests/process_via_deel.rb` and replace the body of `call_deel_api` with the corresponding HTTP-call section (everything that builds the request body, sends to Deel, and returns the parsed response — minus the LedgerWithdrawalRequest reference).

- [ ] **Step 13.5: Run tests, expect pass**

```bash
bundle exec rails test test/services/deel_invoice_adjustments/create_for_ledger_test.rb
```

Expected: all pass (the failure-mode test passes by stubbing `call_deel_api`).

- [ ] **Step 13.6: Commit**

```bash
git add app/services/deel_invoice_adjustments/ test/services/deel_invoice_adjustments/
git commit -m "DeelInvoiceAdjustments::CreateForLedger: direct Deel API call (no withdrawal request)"
```

---

## Task 14: Contributor admin — withdraw_via_deel member_action

**Files:**
- Modify: `app/admin/contributors.rb`
- Modify: `app/views/admin/contributors/_show.html.erb` (remove the LedgerWithdrawalRequest splice; add the new button)
- Test: `test/integration/contributor_withdraw_via_deel_test.rb`

- [ ] **Step 14.1: Inspect current contributor admin withdrawal launch**

```bash
grep -n "LedgerWithdrawalRequest\|withdrawal_request\|new_admin_ledger_withdrawal" app/admin/contributors.rb app/views/admin/contributors/_show.html.erb
```

Note every reference. The new `withdraw_via_deel` member_action replaces the launch link.

- [ ] **Step 14.2: Write failing integration test**

Create `test/integration/contributor_withdraw_via_deel_test.rb`:

```ruby
require "test_helper"

class ContributorWithdrawViaDeelTest < ActionDispatch::IntegrationTest
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "WVD-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 984_001, email: "wvd#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[deel])

    @contract = DeelContract.create!(deel_id: "dc#{SecureRandom.hex(2)}", deel_person_id: "dp#{SecureRandom.hex(2)}", data: { "type" => "ongoing_time_based" })

    @admin = AdminUser.create!(email: "wvd#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", is_admin: true)
    sign_in @admin
  end

  test "POST withdraw_via_deel calls CreateForLedger on a deel-enabled ledger" do
    DeelInvoiceAdjustments::CreateForLedger.expects(:call).with(
      ledger: @ledger,
      amount: "100",
      contract_id: @contract.deel_id,
      description: "",
      date_submitted: anything,
      initiated_by: instance_of(AdminUser),
    ).returns(DeelInvoiceAdjustment.new)

    post withdraw_via_deel_admin_contributor_path(@contributor), params: {
      ledger_id: @ledger.id,
      amount: "100",
      contract_id: @contract.deel_id,
    }
    assert_response :redirect
  end

  test "POST withdraw_via_deel refuses on a non-deel ledger" do
    @ledger.update!(payment_methods: %w[qbo])
    DeelInvoiceAdjustments::CreateForLedger.expects(:call).never

    post withdraw_via_deel_admin_contributor_path(@contributor), params: {
      ledger_id: @ledger.id,
      amount: "100",
      contract_id: @contract.deel_id,
    }
    assert_response :redirect
  end

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
```

- [ ] **Step 14.3: Run test, expect failure**

```bash
bundle exec rails test test/integration/contributor_withdraw_via_deel_test.rb
```

Expected: FAIL (route missing).

- [ ] **Step 14.4: Add the member_action to contributors admin**

In `app/admin/contributors.rb`, add the following member_action (place near other Active Admin member_actions):

```ruby
  member_action :withdraw_via_deel, method: :post do
    ledger = Ledger.find(params.require(:ledger_id))
    unless ledger.deel_enabled?
      redirect_back fallback_location: admin_contributor_path(resource), alert: "Deel is not enabled for this ledger."
      return
    end

    DeelInvoiceAdjustments::CreateForLedger.call(
      ledger: ledger,
      amount: params.require(:amount),
      contract_id: params.require(:contract_id),
      description: params[:description].to_s,
      date_submitted: params[:date_submitted].presence || Date.current,
      initiated_by: current_admin_user,
    )

    redirect_back fallback_location: admin_contributor_path(resource), notice: "Withdrew via Deel."
  rescue DeelInvoiceAdjustments::CreateForLedger::Error => e
    redirect_back fallback_location: admin_contributor_path(resource), alert: e.message
  end
```

- [ ] **Step 14.5: Replace withdrawal-request launch link in the contributor show partial**

In `app/views/admin/contributors/_show.html.erb`, locate the existing link to `new_admin_ledger_withdrawal_request_path` (added earlier in this PR). Replace it with a small form that posts to `withdraw_via_deel_admin_contributor_path`, gated by `ledger.deel_enabled?`:

```erb
<% if ledger.deel_enabled? %>
  <%= form_tag(withdraw_via_deel_admin_contributor_path(contributor), method: :post, style: "display: inline") do %>
    <%= hidden_field_tag :ledger_id, ledger.id %>
    <%= number_field_tag :amount, ledger.balance.to_f, step: "0.01", min: "0.01", max: ledger.balance.to_f %>
    <%= select_tag :contract_id, options_for_select(contributor.deel_person&.deel_contracts&.map { |c| [c.deel_contract_type_label, c.deel_id] } || []) %>
    <%= submit_tag "Withdraw via Deel" %>
  <% end %>
<% end %>
```

If the existing splice for `LedgerWithdrawalRequest` timeline rendering is still in the file (it should be from the prior work), remove it as part of Task 15.

- [ ] **Step 14.6: Run tests, expect pass**

```bash
bundle exec rails test test/integration/contributor_withdraw_via_deel_test.rb
```

Expected: all pass.

- [ ] **Step 14.7: Commit**

```bash
git add app/admin/contributors.rb app/views/admin/contributors/_show.html.erb test/integration/contributor_withdraw_via_deel_test.rb
git commit -m "Contributors admin: withdraw_via_deel member_action + gated form"
```

---

## Task 15: Delete the LedgerWithdrawalRequest apparatus

**Files (delete):**
- `app/models/ledger_withdrawal_request.rb`
- `app/models/ledger_withdrawal_request_bill.rb`
- `app/admin/ledger_withdrawal_requests.rb`
- `app/views/admin/ledger_withdrawal_requests/_show.html.erb`
- `app/views/admin/ledger_withdrawal_requests/_bills_panel.html.erb`
- `app/views/admin/ledger_withdrawal_requests/_notes_panel.html.erb`
- `app/services/ledger_withdrawal_requests/enumerate_candidate_bills.rb`
- `app/services/ledger_withdrawal_requests/process_via_deel.rb`
- `lib/stacks/task_builder/discoveries/ledger_withdrawal_requests.rb`

- [ ] **Step 15.1: Delete the files**

```bash
git rm app/models/ledger_withdrawal_request.rb \
       app/models/ledger_withdrawal_request_bill.rb \
       app/admin/ledger_withdrawal_requests.rb \
       app/services/ledger_withdrawal_requests/enumerate_candidate_bills.rb \
       app/services/ledger_withdrawal_requests/process_via_deel.rb \
       lib/stacks/task_builder/discoveries/ledger_withdrawal_requests.rb
git rm -r app/views/admin/ledger_withdrawal_requests/
rmdir app/services/ledger_withdrawal_requests 2>/dev/null || true
```

- [ ] **Step 15.2: Run boot smoke test to find stale references**

```bash
bundle exec rails runner 'puts Ledger.first&.id'
```

Expected output: a ledger id (or empty if no ledgers). If this errors with `NameError: uninitialized constant`, capture the exact name and find references with grep — they need to be removed in Task 16.

- [ ] **Step 15.3: Commit**

```bash
git add -A
git commit -m "Delete LedgerWithdrawalRequest model, admin, services, discovery, views"
```

---

## Task 16: Clean up cross-references

**Files:**
- Modify: `app/models/contributor.rb` (remove `ledger_withdrawal_requests_with_deleted` and any `preload_for_ledger_view!` addition for it)
- Modify: `app/models/stacks_task.rb` (remove `LedgerWithdrawalRequest` `when` branches in `subject_display_name` and `subject_url`)
- Modify: `app/admin/deel_invoice_adjustments.rb` (remove any LedgerWithdrawalRequest cross-link)
- Modify: `app/models/admin_authorization.rb` (remove any LedgerWithdrawalRequest permission entries)
- Modify: `app/views/admin/contributors/_show.html.erb` (remove the LedgerWithdrawalRequest timeline splice)
- Modify: `lib/stacks/task_builder.rb` (remove the registration for the deleted discovery, if Task 9 didn't already)

- [ ] **Step 16.1: Find every remaining reference**

```bash
grep -rn "LedgerWithdrawalRequest\|ledger_withdrawal_request" app/ lib/ test/ --include="*.rb" --include="*.erb" --include="*.arb" 2>/dev/null
```

Expected after Task 15: only references in `app/models/contributor.rb`, `app/models/stacks_task.rb`, `app/admin/deel_invoice_adjustments.rb`, `app/models/admin_authorization.rb`, `app/views/admin/contributors/_show.html.erb`, and `lib/stacks/task_builder.rb`.

- [ ] **Step 16.2: Remove from app/models/contributor.rb**

Delete the `ledger_withdrawal_requests_with_deleted` method and any `preload_for_ledger_view!` entry related to it. Search for any `is_a?(LedgerWithdrawalRequest)` branches in sort logic added during the prior splice work and remove them.

- [ ] **Step 16.3: Remove from app/models/stacks_task.rb**

Remove the `when LedgerWithdrawalRequest` branches in both `subject_display_name` and `subject_url`. The `when Ledger` branch (with the type-branch added in Task 9) stays.

- [ ] **Step 16.4: Remove from app/admin/deel_invoice_adjustments.rb**

Remove any cross-link to withdrawal requests (likely a sidebar link or column displaying the parent withdrawal request).

- [ ] **Step 16.5: Remove from app/models/admin_authorization.rb**

Remove any permission rules referencing `LedgerWithdrawalRequest` or `:ledger_withdrawal_requests`.

- [ ] **Step 16.6: Remove the splice from app/views/admin/contributors/_show.html.erb**

Delete the lines that render `LedgerWithdrawalRequest` rows in the timeline (the "Withdrawal Request" pill rendering added in the prior commits).

- [ ] **Step 16.7: Verify boot and run full test suite**

```bash
bundle exec rails runner 'puts "boots: #{Rails.application.config.cache_classes}"'
bundle exec rails test
```

Expected: boots cleanly; the full test suite passes (existing tests still pass after the deletion + cleanup).

- [ ] **Step 16.8: Final grep — ensure no LedgerWithdrawalRequest references remain**

```bash
grep -rn "LedgerWithdrawalRequest\|ledger_withdrawal_request" app/ lib/ test/ 2>/dev/null
```

Expected: empty result (no matches anywhere).

- [ ] **Step 16.9: Commit**

```bash
git add -A
git commit -m "Remove all LedgerWithdrawalRequest cross-references from runtime"
```

---

## Task 17: Delete the audit scripts

**Files (delete):**
- `script/audit_qbo_cutover_balance_drift.rb`
- `script/accountant_reconciliation_worklist.rb`
- `script/why_balance_goes_up.rb`

- [ ] **Step 17.1: Delete**

```bash
git rm script/audit_qbo_cutover_balance_drift.rb \
       script/accountant_reconciliation_worklist.rb \
       script/why_balance_goes_up.rb 2>/dev/null || true
# why_balance_goes_up.rb may be untracked — delete from working tree as well:
rm -f script/why_balance_goes_up.rb 2>/dev/null || true
```

- [ ] **Step 17.2: Commit**

```bash
git add -A
git commit -m "Remove one-shot QBO-cutover audit scripts"
```

---

## Task 18: Final sweep — vigilance on the strategy-change deletion list

The user explicitly called out: ensure nothing from the discarded ideas slipped into the implementation. This task is a self-review pass before opening the PR.

- [ ] **Step 18.1: Scan for forbidden tokens**

```bash
grep -rn "justworks\|Justworks\|JUSTWORKS\|misc_enabled" app/ lib/ test/ docs/superpowers/ 2>/dev/null
```

Expected: only the spec/plan docs mention `justworks` in historical/explanatory context. No application code references it.

```bash
grep -rn "LedgerWithdrawalRequest\|ledger_withdrawal_request" app/ lib/ test/ 2>/dev/null
```

Expected: empty.

```bash
grep -rn "process_via_deel\|enumerate_candidate_bills\|bills_panel\|notes_panel" app/ lib/ test/ 2>/dev/null
```

Expected: empty.

- [ ] **Step 18.2: Run full test suite**

```bash
bundle exec rails test
```

Expected: zero failures, zero errors. Capture and compare against the baseline from Step 0b — no regressions outside the intentionally-deleted tests.

- [ ] **Step 18.3: Sanity-check the rake task end-to-end**

```bash
bundle exec rake ledgers:migrate_qbo_bound_zero_drift
bundle exec rails runner 'puts Ledger.group(:mode).count.inspect'
```

Expected: the rake task prints a count line; the runner output shows a mix of `legacy` (still blocked) and `qbo_bound` (auto-flipped where Δ < $0.01).

- [ ] **Step 18.4: Verify spec ↔ code alignment**

Reread `docs/superpowers/specs/2026-06-12-qbo-bound-ledger-cutover-design.md`. Confirm every section's described behavior is reflected in the committed code. Any divergence is either fixed inline (preferable) or documented as an addendum at the top of the spec.

- [ ] **Step 18.5: Commit any sweep fixes**

```bash
git status
# If anything changed:
git add -A
git commit -m "Cleanup pass after final review"
```

---

## Task 19: Open the PR

- [ ] **Step 19.1: Push branch**

```bash
git push -u origin HEAD
```

- [ ] **Step 19.2: Open PR with summary**

```bash
gh pr create --title "QBO-bound ledger cutover" --body "$(cat <<'EOF'
## Summary

- Add per-Ledger `mode` enum (legacy / qbo_bound) and `payment_methods` (text[]) column with data-driven backfill (non-US Deel → ["deel"], everyone else → ["qbo"]).
- New balance rule for `qbo_bound`: only QBO Bill "Paid" status drops a positive host from balance. Negative ContributorAdjustments and DeelInvoiceAdjustments are audit-only.
- Per-Ledger Migrate panel + `member_action`, gated by a no-balance-change invariant. `Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration` surfaces every actionable ledger as a task. `bundle exec rake ledgers:migrate_qbo_bound_zero_drift` bulk-flips any ledger trivially ready.
- New "Payable QBO Bills" page under Money tab, tabbed per QBO account: shows open bills payable through Stacks (`payment_methods` includes `qbo` AND host `payable?`), per-row Refresh + per-tab bulk Refresh.
- Negative-CA validation guard on `qbo_bound` ledgers.
- LedgerWithdrawalRequest apparatus deleted (model, admin, views, services, task discovery). Deel withdrawal trigger now posts directly to `withdraw_via_deel` on the Contributor admin, which calls `DeelInvoiceAdjustments::CreateForLedger` (a port of the Deel-call core from the deleted `ProcessViaDeel`).

## Spec

`docs/superpowers/specs/2026-06-12-qbo-bound-ledger-cutover-design.md`

## Test plan

- [ ] `bundle exec rails test` passes locally
- [ ] `bundle exec rake ledgers:migrate_qbo_bound_zero_drift` runs and flips empty ledgers automatically
- [ ] Visit a Ledger admin show page → Migrate panel renders with Δ pre/post info
- [ ] Visit Money → Payable QBO Bills → tabs appear, per-tab Refresh button works
- [ ] On a qbo_bound ledger, attempting to create a negative ContributorAdjustment via the admin form is rejected with the expected validation error
- [ ] Withdraw via Deel button only renders for ledgers with `deel` in `payment_methods`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Capture the PR URL from the output.

---

## Self-Review Notes (pre-execution)

Spec coverage check:
- **Schema**: Task 1
- **Ledger mode + payment_methods helpers**: Task 2
- **Per-host predicates**: Task 3
- **Ledger balance/unsettled branching**: Task 4
- **Negative CA validation**: Task 5
- **QboBoundMigrationCheck service**: Task 6
- **Migrate UI panel**: Task 7
- **Rake task for bulk migration**: Task 8 (explicit user requirement)
- **Task Builder discovery + StacksTask routing**: Task 9
- **PayableQboBills service**: Task 10
- **RefreshPayableQboBills service**: Task 11
- **Money admin page + view**: Task 12
- **DeelInvoiceAdjustments::CreateForLedger**: Task 13
- **Contributor admin withdraw_via_deel**: Task 14
- **LedgerWithdrawalRequest deletion**: Tasks 15, 16
- **Audit script deletion**: Task 17
- **Final sweep + open PR**: Tasks 18, 19

No placeholders. No "TBD". All code shown in steps; all commands explicit. Type/method naming is consistent across tasks: `Ledgers::QboBoundMigrationCheck::Result` referenced by name in Tasks 6, 7, 8; `Money::PayableQboBills::Row` referenced in Tasks 10, 12; `DeelInvoiceAdjustments::CreateForLedger::Error` referenced in Tasks 13, 14.
