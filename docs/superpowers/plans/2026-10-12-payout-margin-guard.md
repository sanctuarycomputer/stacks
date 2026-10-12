# Payout Margin Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an admin clicks "Calculate Default Payouts" and the generated payouts would exceed the invoice's cap, write nothing and show a full-screen overlay with a per-line breakdown and a reasoned override.

**Architecture:** `InvoicePayouts::Build` computes the complete payout set (base shares plus lead surplus) in memory; `InvoicePayouts::Cap` computes the cap (weighted by each line's billing model, or a per-tracker override); `InvoicePayouts::MarginCheck` compares them and produces display rows. `InvoiceTracker#make_contributor_payouts!` writes exactly what Build returns. The save-time validation on `ContributorPayout` uses the same `Cap`.

**Tech Stack:** Rails 6.1, ActiveAdmin 2.9, Minitest + Mocha, PostgreSQL.

Spec: `docs/superpowers/specs/2026-10-12-payout-margin-guard-design.md`

## Global Constraints

- Work ONLY in `/Users/hhff/Documents/Code/stacks/.worktrees/payout-margin-guard` on branch `feat/payout-margin-guard`. Never `cd` to `/Users/hhff/Documents/Code/stacks`. Before every commit run `git rev-parse --abbrev-ref HEAD`; if it does not print `feat/payout-margin-guard`, STOP and report BLOCKED.
- Every Rails command MUST be prefixed with `DATABASE_URL=postgres:///stacks_test_margin_guard` (a database dedicated to this worktree; the default `stacks_test` is shared with other checkouts that still expect the old column). Example: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/models/contributor_payout_test.rb`.
- Never run `test/lib/tasks/etl_rake_test.rb` (it makes a live network call and hangs). Full suite: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test --exclude "/EtlRakeTest/"`.
- `db/schema.rb` is hand-curated. Never let a Rails task rewrite it; if one does, `git checkout db/schema.rb` and redo the hand edit.
- Money written into jsonb blueprints must be `Float` rounded to 2 decimals, never `BigDecimal`.
- Commit trailer, exactly: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Match the surrounding code's style and comment density. No new gems.
- `Mocha::ExpectationError` is not a `StandardError`; an unexpected call on a strict `mock` aborts the test. Stub every method a mock will receive.

---

### Task 1: Rename the column, add the `margin_override` reader

**Files:**
- Create: `db/migrate/20261012120000_rename_invoice_tracker_treasury_split_to_target_margin_override.rb`
- Modify: `db/schema.rb` (version line 13; `invoice_trackers` table, the `company_treasury_split` column line and its check constraint line)
- Modify: `app/models/invoice_tracker.rb` (add reader after `delegate :billing_enterprise`)
- Modify: `app/admin/invoice_trackers.rb:7` and `:373`
- Modify: `app/models/contributor_payout.rb:316,322` (read through the new reader; full rewrite comes in Task 6)
- Modify: `test/models/contributor_payout_test.rb:65,87`
- Test: `test/models/invoice_tracker_margin_override_test.rb`

**Interfaces:**
- Produces: `InvoiceTracker#margin_override` → `BigDecimal` or `nil`. The only reader of the column anywhere.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/invoice_tracker_margin_override_test.rb
require "test_helper"

class InvoiceTrackerMarginOverrideTest < ActiveSupport::TestCase
  test "the column is nullable with no default" do
    col = InvoiceTracker.columns_hash["target_margin_override"]
    assert col, "expected invoice_trackers.target_margin_override to exist"
    assert_nil col.default
    assert_not InvoiceTracker.column_names.include?("company_treasury_split")
  end

  test "margin_override reads the new column" do
    assert_nil InvoiceTracker.new.margin_override
    assert_equal BigDecimal("0.33"), InvoiceTracker.new(target_margin_override: 0.33).margin_override
  end

  # Between deploy and the manual migration the row still has the old column.
  test "margin_override falls back to the old column when the new one is absent" do
    it = InvoiceTracker.new
    it.stubs(:has_attribute?).with(:target_margin_override).returns(false)
    it.stubs(:[]).with(:company_treasury_split).returns(BigDecimal("0.3"))
    assert_equal BigDecimal("0.3"), it.margin_override
  end
end
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/models/invoice_tracker_margin_override_test.rb`
Expected: failures (`target_margin_override` does not exist / `margin_override` undefined).

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20261012120000_rename_invoice_tracker_treasury_split_to_target_margin_override.rb
class RenameInvoiceTrackerTreasurySplitToTargetMarginOverride < ActiveRecord::Migration[6.1]
  def up
    remove_check_constraint :invoice_trackers, name: "check_company_treasury_split_range"
    rename_column :invoice_trackers, :company_treasury_split, :target_margin_override
    change_column_default :invoice_trackers, :target_margin_override, from: 0.3, to: nil
    add_check_constraint :invoice_trackers,
      "target_margin_override >= 0 AND target_margin_override <= 1",
      name: "check_target_margin_override_range"

    # Trackers that already have payouts keep 0.3 as an explicit override:
    # ProjectTracker#billing_model is live, not a per-invoice snapshot, so
    # nulling them would re-cap invoices already paid out at 70%.
    execute <<~SQL
      UPDATE invoice_trackers
      SET target_margin_override = NULL
      WHERE target_margin_override = 0.3
        AND NOT EXISTS (
          SELECT 1 FROM contributor_payouts cp
          WHERE cp.invoice_tracker_id = invoice_trackers.id
            AND cp.deleted_at IS NULL
        )
    SQL
  end

  def down
    execute "UPDATE invoice_trackers SET target_margin_override = 0.3 WHERE target_margin_override IS NULL"
    remove_check_constraint :invoice_trackers, name: "check_target_margin_override_range"
    change_column_default :invoice_trackers, :target_margin_override, from: nil, to: 0.3
    rename_column :invoice_trackers, :target_margin_override, :company_treasury_split
    add_check_constraint :invoice_trackers,
      "company_treasury_split >= 0 AND company_treasury_split <= 1",
      name: "check_company_treasury_split_range"
  end
end
```

- [ ] **Step 4: Run the migration both ways against the dedicated DB, then restore schema.rb**

```bash
DATABASE_URL=postgres:///stacks_test_margin_guard RAILS_ENV=test bin/rails db:migrate
DATABASE_URL=postgres:///stacks_test_margin_guard RAILS_ENV=test bin/rails db:rollback
DATABASE_URL=postgres:///stacks_test_margin_guard RAILS_ENV=test bin/rails db:migrate
git checkout db/schema.rb
```
Expected: each command exits 0. `git checkout` discards any automatic dump.

- [ ] **Step 5: Hand-edit `db/schema.rb`**

- Line 13: `ActiveRecord::Schema.define(version: 2026_10_12_120000) do`
- In `create_table "invoice_trackers"`: replace `t.decimal "company_treasury_split", default: "0.3"` with `t.decimal "target_margin_override"`.
- Replace the check constraint line with:
  `t.check_constraint "(target_margin_override >= (0)::numeric) AND (target_margin_override <= (1)::numeric)", name: "check_target_margin_override_range"`

- [ ] **Step 6: Add the reader to `app/models/invoice_tracker.rb`** (directly below `delegate :billing_enterprise, to: :forecast_client`)

```ruby
  # The share the company keeps on this invoice, when set by hand. nil means
  # "derive the cap from each project's billing model" (InvoicePayouts::Cap).
  # The only reader of the column: migrations here run by hand after the
  # deploy, so until then the row still carries company_treasury_split.
  def margin_override
    if has_attribute?(:target_margin_override)
      target_margin_override
    else
      self[:company_treasury_split]
    end
  end
```

- [ ] **Step 7: Update the admin form and permitted params in `app/admin/invoice_trackers.rb`**

Replace line 7 with:

```ruby
  permit_params do
    permitted = [:notes, :allow_early_contributor_payouts_on, :qbo_invoice_id, :qbo_account_id]
    # Admin-only, and absent until the (manual) migration has run.
    if current_admin_user.is_admin? && InvoiceTracker.column_names.include?("target_margin_override")
      permitted << :target_margin_override
    end
    permitted
  end
```

Replace the `if current_admin_user.is_admin?` block containing `f.input :company_treasury_split` with:

```ruby
      if current_admin_user.is_admin? && InvoiceTracker.column_names.include?("target_margin_override")
        f.input :target_margin_override,
          as: :number,
          label: "Target margin override",
          hint: "Blank = derive the cap from each project's billing model. 0.33 keeps 33% and caps payouts at 67%.",
          input_html: { step: 0.01 }
      end
```

- [ ] **Step 8: Keep the existing validation working until Task 6**

In `app/models/contributor_payout.rb`, inside `contributor_payouts_within_seventy_percent`, replace everything from `commissions_total = ...` down to (not including) `contributor_pool_sum = ...` with:

```ruby
    commissions_total = cps.sum(&:as_commission)
    split = invoice_tracker.margin_override || Stacks::BillingModel.for(Stacks::BillingModel::DEFAULT).treasury_share
    post_commission_total = invoice_tracker.total - commissions_total
    max_amount = invoice_tracker.forecast_client.is_internal? ? post_commission_total : post_commission_total * (1 - split)
```

and in the error message replace `invoice_tracker.company_treasury_split` with `split`.

In `test/models/contributor_payout_test.rb` lines 65 and 87 change `stubs(:company_treasury_split)` to `stubs(:margin_override)`.

- [ ] **Step 9: Run tests**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/models/invoice_tracker_margin_override_test.rb test/models/contributor_payout_test.rb test/models/invoice_tracker_payouts_test.rb`
Expected: all pass. Then `grep -rn "company_treasury_split" app lib test` must show only `app/models/invoice_tracker.rb` (the fallback), `app/models/project_tracker.rb` and `test/models/project_tracker_test.rb` (an unrelated derived method), and the new test.

- [ ] **Step 10: Commit**

```bash
git add -A db app test
git commit -m "feat: rename invoice tracker treasury split to a nullable target margin override

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Shared test fixtures and `InvoicePayouts::Cap`

**Files:**
- Create: `test/support/payout_fixtures.rb`
- Create: `app/services/invoice_payouts/cap.rb`
- Test: `test/services/invoice_payouts/cap_test.rb`

**Interfaces:**
- Consumes: `InvoiceTracker#margin_override`.
- Produces:
  - `InvoicePayouts::Cap.new(invoice_tracker, commissions_by_line: {})` — keys are QBO line ids as strings (or nil), values dollars.
  - `#cap` → Float (2dp), `#post_commission_total` → Float, `#total_commissions` → Float.
  - `#mapped_lines` → array of `Cap::Line` (`id` String, `amount` Float, `project_tracker`, `rules`).
  - `#treasury_share_for(line_id)` → BigDecimal: 0 for an internal client, else the override, else the mapped line's `rules.treasury_share`, else the default model's.
  - `PayoutFixtures` test module (see code) with `setup_payout_people`, `build_tracker(model, project: @project)`, `build_invoice_tracker(lines)`, `stub_qbo_invoice(lines, total: nil)`.

- [ ] **Step 1: Write the fixtures module**

```ruby
# test/support/payout_fixtures.rb
# Real rows for payout tests, with the QBO invoice stubbed on every
# InvoiceTracker instance (admin actions reload the tracker, so a stub on one
# object would be lost).
module PayoutFixtures
  def setup_payout_people
    Thread.current[:sanctuary_enterprise] = nil
    @pass = InvoicePass.find_or_create_by!(start_of_month: Date.new(2026, 8, 1)) { |ip| ip.data = {} }
    @client = ForecastClient.create!(forecast_id: 710_001, name: "Margin Guard Client")
    @project = ForecastProject.create!(forecast_id: 710_001, client_id: @client.forecast_id, name: "Guard Proj", code: "MG-1", tags: ["100p/h"])
    @ic = ForecastPerson.create!(forecast_id: 710_001, email: "ic-guard@example.com", data: {})
    @ic2 = ForecastPerson.create!(forecast_id: 710_005, email: "ic2-guard@example.com", data: {})
    @al_admin = AdminUser.create!(email: "al-guard@example.com", password: "password123", password_confirmation: "password123")
    @al = ForecastPerson.create!(forecast_id: 710_002, email: @al_admin.email, data: {})
    @pl_admin = AdminUser.create!(email: "pl-guard@example.com", password: "password123", password_confirmation: "password123")
    @pl = ForecastPerson.create!(forecast_id: 710_003, email: @pl_admin.email, data: {})
    @creator = AdminUser.create!(email: "creator-guard@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
  end

  def build_tracker(model, project: @project)
    pt = ProjectTracker.new(name: "Guard Tracker #{model} #{project.forecast_id}", billing_model: model)
    pt.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: project)
    AccountLeadPeriod.create!(project_tracker: pt, admin_user: @al_admin, started_at: Date.new(2026, 8, 1))
    ProjectLeadPeriod.create!(project_tracker: pt, admin_user: @pl_admin, started_at: Date.new(2026, 8, 1))
    pt
  end

  # lines: [{ id: "1", person: @ic, project: @project, hours: 100.0, rate: 100.0 }, ...]
  def build_invoice_tracker(lines, total: nil)
    blueprint_lines = lines.each_with_object({}) do |l, h|
      project = l[:project] || @project
      h["#{project.code} line #{l[:id]} [FP-#{l[:person].forecast_id}]"] = {
        "id" => l[:id],
        "forecast_project" => project.forecast_id,
        "forecast_person" => l[:person].forecast_id,
        "quantity" => l[:hours],
        "unit_price" => l[:rate],
      }
    end
    it = InvoiceTracker.create!(
      forecast_client: @client,
      invoice_pass: @pass,
      qbo_account: qbo_accounts(:one),
      blueprint: { "generated_at" => DateTime.now.to_s, "lines" => blueprint_lines },
    )
    stub_qbo_invoice(lines, total: total)
    it
  end

  def stub_qbo_invoice(lines, total: nil)
    items = lines.map do |l|
      project = l[:project] || @project
      { "id" => l[:id], "amount" => (l[:hours] * l[:rate]).to_f, "description" => "#{project.code} line #{l[:id]} [FP-#{l[:person].forecast_id}]" }
    end
    qbo_invoice = mock("qbo_invoice")
    qbo_invoice.stubs(:line_items).returns(items)
    qbo_invoice.stubs(:data).returns({})
    qbo_invoice.stubs(:total).returns(total || items.sum { |i| i["amount"] })
    qbo_invoice.stubs(:display_name).returns("Guard Invoice")
    qbo_invoice.stubs(:status).returns(:unpaid)
    InvoiceTracker.any_instance.stubs(:qbo_invoice).returns(qbo_invoice)
    qbo_invoice
  end
end
```

- [ ] **Step 2: Write the failing Cap tests**

```ruby
# test/services/invoice_payouts/cap_test.rb
require "test_helper"

class InvoicePayoutsCapTest < ActiveSupport::TestCase
  include PayoutFixtures

  setup do
    setup_payout_people
    @project2 = ForecastProject.create!(forecast_id: 710_002, client_id: @client.forecast_id, name: "Guard Proj 2", code: "MG-2", tags: ["100p/h"])
  end

  def one_line(project: @project, id: "1")
    { id: id, person: @ic, project: project, hours: 100.0, rate: 100.0 } # $10,000
  end

  test "an all-v1 invoice caps at 70%" do
    build_tracker("new_deal_v1")
    cap = InvoicePayouts::Cap.new(build_invoice_tracker([one_line]))
    assert_in_delta 7000.0, cap.cap, 0.001
    assert_in_delta 10_000.0, cap.post_commission_total, 0.001
  end

  test "an all-v2 invoice caps at 67%" do
    build_tracker("new_deal_v2")
    assert_in_delta 6700.0, InvoicePayouts::Cap.new(build_invoice_tracker([one_line])).cap, 0.001
  end

  test "a mixed invoice is weighted by line" do
    build_tracker("new_deal_v1")
    build_tracker("new_deal_v2", project: @project2)
    it = build_invoice_tracker([one_line, one_line(project: @project2, id: "2")])
    assert_in_delta 13_700.0, InvoicePayouts::Cap.new(it).cap, 0.001
  end

  test "target_margin_override wins over the billing models" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker([one_line])
    it.update!(target_margin_override: 0.25)
    assert_in_delta 7500.0, InvoicePayouts::Cap.new(it).cap, 0.001
    assert_equal BigDecimal("0.25"), InvoicePayouts::Cap.new(it).treasury_share_for("1")
  end

  test "commissions come off the line before its share is applied" do
    build_tracker("new_deal_v2")
    cap = InvoicePayouts::Cap.new(build_invoice_tracker([one_line]), commissions_by_line: { "1" => 1000.0 })
    assert_in_delta 6030.0, cap.cap, 0.001 # (10000 - 1000) * 0.67
    assert_in_delta 9000.0, cap.post_commission_total, 0.001
  end

  test "the unmapped remainder and unattributed commissions use the default model" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker([one_line], total: 12_000.0)
    cap = InvoicePayouts::Cap.new(it, commissions_by_line: { nil => 500.0, "999" => 500.0 })
    # 10000 * 0.67 + (2000 - 1000) * 0.70
    assert_in_delta 7400.0, cap.cap, 0.001
  end

  test "an internal client caps at the whole post-commission total" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker([one_line])
    ForecastClient.any_instance.stubs(:is_internal?).returns(true)
    cap = InvoicePayouts::Cap.new(it, commissions_by_line: { "1" => 1000.0 })
    assert_in_delta 9000.0, cap.cap, 0.001
    assert_equal 0, cap.treasury_share_for("1")
  end

  test "a line whose project has no tracker falls into the remainder" do
    it = build_invoice_tracker([one_line])
    assert_in_delta 7000.0, InvoicePayouts::Cap.new(it).cap, 0.001
    assert_empty InvoicePayouts::Cap.new(it).mapped_lines
  end
end
```

- [ ] **Step 3: Run, confirm failure**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/services/invoice_payouts/cap_test.rb`
Expected: `NameError: uninitialized constant InvoicePayouts`.

- [ ] **Step 4: Implement**

```ruby
# app/services/invoice_payouts/cap.rb
module InvoicePayouts
  # The most an invoice may pay out to contributors, net of commissions.
  #
  # One calculation shared by the pre-flight (MarginCheck) and the save-time
  # validation on ContributorPayout, so the two cannot disagree. Each line
  # mapped to a ProjectTracker is capped by that tracker's billing model;
  # anything else on the invoice uses the default model. A tracker-level
  # target_margin_override replaces all of that with one share.
  #
  # commissions_by_line: QBO line id (String, or nil when unknown) => dollars
  # of commission actually paid out against that line.
  class Cap
    Line = Struct.new(:id, :amount, :project_tracker, :rules, keyword_init: true)

    def initialize(invoice_tracker, commissions_by_line: {})
      @invoice_tracker = invoice_tracker
      @commissions_by_line = commissions_by_line.each_with_object(Hash.new(0.0)) do |(id, amount), h|
        h[id&.to_s] += amount.to_f
      end
    end

    def total
      @invoice_tracker.total.to_f
    end

    def total_commissions
      @commissions_by_line.values.sum.to_f
    end

    def post_commission_total
      (total - total_commissions).round(2)
    end

    def internal?
      @invoice_tracker.forecast_client.is_internal?
    end

    def override
      @invoice_tracker.margin_override
    end

    def default_rules
      Stacks::BillingModel.for(Stacks::BillingModel::DEFAULT)
    end

    def mapped_lines
      @mapped_lines ||= begin
        blueprint_lines = ((@invoice_tracker.blueprint || {})["lines"] || {}).values
        (@invoice_tracker.qbo_invoice&.line_items || []).filter_map do |line_item|
          metadata = blueprint_lines.find { |l| l["id"] == line_item["id"] }
          next unless metadata.present?
          ptfps = ProjectTrackerForecastProject.includes(:project_tracker).where(forecast_project_id: metadata["forecast_project"])
          next unless ptfps.length == 1
          pt = ptfps.first.project_tracker
          Line.new(id: line_item["id"].to_s, amount: line_item["amount"].to_f, project_tracker: pt, rules: pt.billing_rules)
        end
      end
    end

    def commission_for(line_id)
      @commissions_by_line.fetch(line_id.to_s, 0.0)
    end

    def treasury_share_for(line_id)
      return 0 if internal?
      return override if override
      line = mapped_lines.find { |l| l.id == line_id.to_s }
      (line&.rules || default_rules).treasury_share
    end

    def cap
      return post_commission_total if internal?
      return (post_commission_total * (1 - override)).to_f.round(2) if override

      mapped = mapped_lines
      attributed = mapped.sum { |l| commission_for(l.id) }
      mapped_part = mapped.sum { |l| (l.amount - commission_for(l.id)) * (1 - l.rules.treasury_share) }
      remainder = total - mapped.sum(&:amount) - (total_commissions - attributed)
      (mapped_part + remainder * (1 - default_rules.treasury_share)).to_f.round(2)
    end
  end
end
```

- [ ] **Step 5: Run, confirm pass**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/services/invoice_payouts/cap_test.rb`
Expected: 8 runs, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/services/invoice_payouts/cap.rb test/support/payout_fixtures.rb test/services/invoice_payouts/cap_test.rb
git commit -m "feat: InvoicePayouts::Cap, the payout cap weighted by each line's billing model

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `InvoicePayouts::Build`

**Files:**
- Create: `app/services/invoice_payouts/build.rb`
- Test: `test/services/invoice_payouts/build_test.rb`
- Read first (do not modify in this task): `app/models/invoice_tracker.rb` `make_contributor_payouts!` (starts ~line 338 after Task 1) and `app/models/contributor_payout.rb#calculate_surplus`.

**Interfaces:**
- Produces:
  - `InvoicePayouts::Build.new(invoice_tracker)`; everything is computed lazily on first read and memoized. No writes, ever.
  - `Build::Entry` struct: `role` (String: `"AccountLead"`, `"ProjectLead"`, `"IndividualContributor"`, `"Commission"`, `"AccountLeadSurplus"`, `"ProjectLeadSurplus"`), `payee` (ForecastPerson), `amount` (Float), `description_line` (String or nil), `rate_override` (true/false), `metadata` (slim Hash with string keys `id`, `forecast_project`, `forecast_person`), and `#to_blueprint` → `{ "blueprint_metadata" => metadata, "amount" => amount, "description_line" => description_line }.compact`.
  - `Build::Line` struct: `qbo_line_item`, `metadata`, `project_tracker` (may be nil), `rules` (may be nil), `billed` (Float), `commission_total` (Float), `working_amount` (Float), `entries` (Array of Entry, base then surplus).
  - `Build::Payee` struct: `forecast_person`, `payable` (true/false), `entries`; `#amount` → Float 2dp; `#commission_amount` → Float; `#blueprint` → Hash role => array of `to_blueprint`, always containing the four base roles (possibly empty) and the surplus roles only when present.
  - `#lines` → Array<Line>; `#payees` → Array<Payee> (every payee, including unpaid); `#paid_payees` → payees with `payable && amount != 0`; `#paid?(forecast_person)` → bool.
  - `#paid_commissions_by_line` → Hash line id String => Float (Commission entries of paid payees).
  - `#retained_orphans` → Array<ContributorPayout>: existing non-deleted payouts whose ledger is not one a paid payee will use and whose cached `qbo_bill&.has_payments?` is true.

**Behaviour to mirror exactly** (from the existing method; read it): the internal-project branch; the client-project branch including the `raise` on zero or multiple project trackers; commissions off the top; the June 2025 first-month recompute; AL/PL shares; the hourly-rate-override IC path; `ic_share`. Amounts and `description_line` strings must be byte-identical to today's.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/invoice_payouts/build_test.rb
require "test_helper"

class InvoicePayoutsBuildTest < ActiveSupport::TestCase
  include PayoutFixtures

  setup { setup_payout_people }

  def payee(build, person)
    build.payees.find { |p| p.forecast_person == person }
  end

  test "base shares for a v2 line, with nothing written" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])

    assert_no_difference ["ContributorPayout.count", "Contributor.count", "Ledger.count"] do
      build = InvoicePayouts::Build.new(it)
      assert_in_delta 5400.0, payee(build, @ic).amount, 0.001
      assert_in_delta 800.0, payee(build, @al).amount, 0.001
      assert_in_delta 500.0, payee(build, @pl).amount, 0.001
      line = build.lines.first
      assert_in_delta 10_000.0, line.billed, 0.001
      assert_equal %w[AccountLead ProjectLead IndividualContributor], line.entries.map(&:role)
      assert_equal "- 100.0 hrs * $100.00 p/h * 54.0% = $5,400.00", payee(build, @ic).blueprint["IndividualContributor"].first["description_line"]
      assert_equal %w[AccountLead ProjectLead IndividualContributor Commission], payee(build, @ic).blueprint.keys
      assert_kind_of Float, payee(build, @ic).blueprint["IndividualContributor"].first["amount"]
    end
  end

  test "a rate override is flagged and its surplus goes to both leads" do
    build_tracker("new_deal_v1")
    @project.update!(notes: "#{@ic.email}:20p/h")
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    build = InvoicePayouts::Build.new(it)

    ic_entry = build.lines.first.entries.find { |e| e.role == "IndividualContributor" }
    assert ic_entry.rate_override
    assert_in_delta 2000.0, ic_entry.amount, 0.001
    # margin 0.80, threshold 0.43 → surplus 3700 → 555 to each lead
    assert_in_delta 800.0 + 555.0, payee(build, @al).amount, 0.001
    assert_in_delta 500.0 + 555.0, payee(build, @pl).amount, 0.001
    assert_equal 1, payee(build, @al).blueprint["AccountLeadSurplus"].length
    assert_kind_of Float, payee(build, @al).blueprint["AccountLeadSurplus"].first["amount"]
    assert_includes build.lines.first.entries.map(&:role), "ProjectLeadSurplus"
  end

  test "a full-time lead is listed but not paid, base or surplus" do
    build_tracker("new_deal_v1")
    @project.update!(notes: "#{@ic.email}:20p/h")
    FullTimePeriod.create!(admin_user: @al_admin, started_at: Date.new(2020, 1, 1), contributor_type: :five_day, expected_utilization: 0.8)
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    build = InvoicePayouts::Build.new(it)

    assert_not payee(build, @al).payable
    assert_not build.paid?(@al)
    assert_not_includes build.paid_payees.map(&:forecast_person), @al
    assert_nil payee(build, @al).blueprint["AccountLeadSurplus"]
    assert_in_delta 500.0 + 555.0, payee(build, @pl).amount, 0.001
  end

  test "commission to a payable recipient is recorded against its line" do
    pt = build_tracker("new_deal_v2")
    recipient = ForecastPerson.create!(forecast_id: 710_004, email: "comm-guard@example.com", data: {})
    recipient.ensure_contributor_exists!
    PercentageCommission.create!(project_tracker: pt, contributor: recipient.reload.contributor, rate: 0.10)
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    build = InvoicePayouts::Build.new(it)

    assert_in_delta 1000.0, build.paid_commissions_by_line["1"], 0.001
    assert_in_delta 9000.0, build.lines.first.working_amount, 0.001
    assert_in_delta 1000.0, payee(build, recipient).commission_amount, 0.001
    assert_in_delta 4860.0, payee(build, @ic).amount, 0.001 # 9000 * 0.54
  end

  # The one case where a line's commission_total (everything deducted) and the
  # commissions actually paid differ: surplus is then priced on the full line.
  test "commission owed to a salaried recipient is deducted but not paid" do
    pt = build_tracker("new_deal_v2")
    recipient_admin = AdminUser.create!(email: "comm-salaried-guard@example.com", password: "password123", password_confirmation: "password123")
    recipient = ForecastPerson.create!(forecast_id: 710_006, email: recipient_admin.email, data: {})
    recipient.ensure_contributor_exists!
    FullTimePeriod.create!(admin_user: recipient_admin, started_at: Date.new(2020, 1, 1), contributor_type: :five_day, expected_utilization: 0.8)
    PercentageCommission.create!(project_tracker: pt, contributor: recipient.reload.contributor, rate: 0.10)
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    build = InvoicePayouts::Build.new(it)

    assert_empty build.paid_commissions_by_line
    assert_in_delta 9000.0, build.lines.first.working_amount, 0.001
    assert_in_delta 4860.0, payee(build, @ic).amount, 0.001
    # surplus priced on 10,000: margin 0.514 - 0.46 = 540 → 81 to each lead
    assert_in_delta 720.0 + 81.0, payee(build, @al).amount, 0.001
    assert_in_delta 450.0 + 81.0, payee(build, @pl).amount, 0.001
    assert_not build.paid?(recipient)
  end

  test "zero or multiple project trackers for a client project raises as generation does" do
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    err = assert_raises(RuntimeError) { InvoicePayouts::Build.new(it).lines }
    assert_match(/No project trackers found/, err.message)
  end

  test "retained_orphans are existing payouts generation cannot remove" do
    build_tracker("new_deal_v1")
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    stranger = ForecastPerson.create!(forecast_id: 710_009, email: "gone-guard@example.com", data: {})
    stranger.ensure_contributor_exists!
    ledger = Ledger.find_or_create_for(enterprise: @client.billing_enterprise, contributor: stranger.reload.contributor)
    paid = ContributorPayout.new(invoice_tracker: it, ledger: ledger, amount: 3000.0, blueprint: {}, created_by: @creator)
    paid.skip_seventy_percent_check = true
    paid.save!

    bill = mock("qbo_bill")
    bill.stubs(:has_payments?).returns(true)
    ContributorPayout.any_instance.stubs(:qbo_bill).returns(bill)
    assert_equal [paid], InvoicePayouts::Build.new(it.reload).retained_orphans

    bill.stubs(:has_payments?).returns(false)
    assert_empty InvoicePayouts::Build.new(it.reload).retained_orphans
  end
end
```

Notes for the implementer: check `FullTimePeriod`'s required attributes in `app/models/full_time_period.rb` and adjust the `create!` call so the period is NOT `variable_hours?` and covers 2026-08-31; if `@client.billing_enterprise` is nil in tests, look at how `Ledger.find_or_create_for` is exercised in `test/models/invoice_tracker_payouts_test.rb` (generation there succeeds, so a billing enterprise resolves) and mirror it.

- [ ] **Step 2: Run, confirm failure**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/services/invoice_payouts/build_test.rb`
Expected: `NameError: uninitialized constant InvoicePayouts::Build`.

- [ ] **Step 3: Implement**

```ruby
# app/services/invoice_payouts/build.rb
module InvoicePayouts
  # Everything InvoiceTracker#make_contributor_payouts! will pay, computed in
  # memory with no writes: base shares per line (commission, Account Lead,
  # Project Lead, Individual Contributor) and the lead surplus shares on top.
  # The write saves exactly what this returns, so MarginCheck can rule on an
  # invoice before anything touches the database.
  class Build
    BASE_ROLES = %w[AccountLead ProjectLead IndividualContributor Commission].freeze
    SURPLUS_ROLES = %w[AccountLeadSurplus ProjectLeadSurplus].freeze

    Entry = Struct.new(:role, :payee, :amount, :description_line, :rate_override, :metadata, keyword_init: true) do
      def to_blueprint
        { "blueprint_metadata" => metadata, "amount" => amount, "description_line" => description_line }.compact
      end
    end

    Line = Struct.new(:qbo_line_item, :metadata, :project_tracker, :rules, :billed, :commission_total, :working_amount, :entries, keyword_init: true)

    Payee = Struct.new(:forecast_person, :payable, :entries, keyword_init: true) do
      def amount
        entries.sum(&:amount).round(2).to_f
      end

      def commission_amount
        entries.select { |e| e.role == "Commission" }.sum(&:amount).to_f
      end

      def blueprint
        bp = BASE_ROLES.index_with { [] }
        entries.each { |e| (bp[e.role] ||= []) << e.to_blueprint }
        bp
      end
    end

    def initialize(invoice_tracker)
      @invoice_tracker = invoice_tracker
    end

    attr_reader :invoice_tracker

    def lines
      compute
      @lines
    end

    def payees
      compute
      @payees.values
    end

    def paid_payees
      payees.select { |p| p.payable && p.amount != 0 }
    end

    def paid?(forecast_person)
      paid_payees.any? { |p| p.forecast_person == forecast_person }
    end

    def paid_commissions_by_line
      paid_payees.flat_map(&:entries).select { |e| e.role == "Commission" }.each_with_object(Hash.new(0.0)) do |e, h|
        h[e.metadata["id"].to_s] += e.amount
      end
    end

    # Existing payouts the write would normally delete as no longer earned,
    # but cannot: their QBO bill has payments against it. They stay on the
    # tracker, so they stay in the pool.
    def retained_orphans
      @retained_orphans ||= begin
        enterprise = invoice_tracker.forecast_client.billing_enterprise
        kept_ledger_ids = paid_payees.filter_map do |p|
          contributor = p.forecast_person.contributor
          contributor && Ledger.find_by(enterprise: enterprise, contributor: contributor)&.id
        end
        invoice_tracker.contributor_payouts.reload.reject { |cp| kept_ledger_ids.include?(cp.ledger_id) }.select do |cp|
          cp.qbo_bill&.has_payments?
        end
      end
    end

    private

    def invoice_pass
      invoice_tracker.invoice_pass
    end

    def end_of_month
      invoice_pass.start_of_month.end_of_month
    end

    def n2c(*args, **kwargs)
      ActionController::Base.helpers.number_to_currency(*args, **kwargs)
    end

    # Only people on variable hours (or with no AdminUser / employment history
    # at all) are paid per invoice; everyone else is salaried.
    def payable?(forecast_person)
      admin_user = forecast_person.admin_user
      admin_user.nil? || admin_user.full_time_periods.empty? || admin_user.full_time_period_at(end_of_month).variable_hours?
    end

    def add_entry(line, role:, payee:, amount:, description_line: nil, rate_override: false, metadata: nil)
      entry = Entry.new(
        role: role,
        payee: payee,
        amount: amount,
        description_line: description_line,
        rate_override: rate_override,
        metadata: ContributorPayout.slim_metadata(metadata || line.metadata),
      )
      line.entries << entry
      @payees[payee] ||= Payee.new(forecast_person: payee, payable: false, entries: [])
      @payees[payee].entries << entry
      entry
    end

    def compute
      return if @computed
      @lines = []
      @payees = {}
      blueprint_lines = ((invoice_tracker.blueprint || {})["lines"] || {}).values

      invoice_tracker.qbo_invoice.line_items.each do |line_item|
        metadata = blueprint_lines.find { |l| l["id"] == line_item["id"] }
        next unless metadata.present?

        forecast_project = ForecastProject.includes(:forecast_client).find(metadata["forecast_project"])
        next unless forecast_project.present?

        if forecast_project.forecast_client.is_internal?
          compute_internal_line(line_item, metadata)
        else
          compute_client_line(line_item, metadata, forecast_project)
        end
      end

      # Payability is only asked of people who are actually owed something:
      # full_time_period_at can be nil for someone with no period this month.
      @payees.each_value { |p| p.payable = p.amount != 0 && payable?(p.forecast_person) }

      compute_surplus
      @computed = true
    end

    def new_line(line_item, metadata, project_tracker)
      line = Line.new(
        qbo_line_item: line_item,
        metadata: metadata,
        project_tracker: project_tracker,
        rules: project_tracker&.billing_rules,
        billed: line_item["amount"].to_f,
        commission_total: 0.0,
        working_amount: line_item["amount"].to_f,
        entries: [],
      )
      @lines << line
      line
    end

    # Commissions come off the top of a line before any other share.
    def deduct_commissions(line)
      return 0.0 unless line.project_tracker
      deductions = invoice_tracker.commission_deductions_for_line(line.project_tracker, line.qbo_line_item, line.metadata)
      deductions.each do |d|
        recipient = d[:commission].contributor.forecast_person
        next unless recipient.present?
        add_entry(line,
          role: "Commission",
          payee: recipient,
          amount: d[:amount],
          description_line: d[:commission].description_line(line.qbo_line_item, line.metadata, d[:amount]))
      end
      line.commission_total = deductions.sum { |d| d[:amount] }
    end

    # Internal projects may or may not have a ProjectTracker. The IC takes the
    # whole line, less any commissions.
    def compute_internal_line(line_item, metadata)
      individual_contributor = ForecastPerson.find(metadata["forecast_person"])
      return unless individual_contributor.present?

      ptfps = ProjectTrackerForecastProject.includes(:project_tracker).where(forecast_project_id: metadata["forecast_project"])
      line = new_line(line_item, metadata, ptfps.first&.project_tracker)
      commission_total = deduct_commissions(line)
      line.working_amount = (line.billed - commission_total).round(2)
      add_entry(line, role: "IndividualContributor", payee: individual_contributor, amount: line.working_amount)
    end

    def compute_client_line(line_item, metadata, forecast_project)
      ptfps = ProjectTrackerForecastProject.includes(:project_tracker).where(forecast_project_id: metadata["forecast_project"])
      raise "Multiple project trackers found for forecast project #{metadata["forecast_project"]}" if ptfps.length > 1
      raise "No project trackers found for forecast project #{metadata["forecast_project"]}" if ptfps.length == 0

      pt = ptfps.first.project_tracker
      line = new_line(line_item, metadata, pt)
      rules = line.rules

      working_amount = line.billed
      working_hours = metadata["quantity"].to_f
      working_rate = metadata["unit_price"].to_f

      commission_total = deduct_commissions(line)
      working_amount -= commission_total

      if invoice_pass.start_of_month == Date.new(2025, 6, 1)
        # The New Deal began mid-June 2025: only the second half of that month counts.
        working_hours =
          ForecastAssignment
            .where(
              'end_date >= ? AND start_date <= ? AND project_id = ? AND person_id = ?',
              Date.new(2025, 6, 16),
              Date.new(2025, 6, 30),
              metadata["forecast_project"],
              metadata["forecast_person"]
            ).map do |a|
              a.allocation_during_range_in_hours(Date.new(2025, 6, 16), Date.new(2025, 6, 30))
            end.compact.sum
        working_amount = working_hours * working_rate
        working_amount -= commission_total
      end
      line.working_amount = working_amount

      lead_line = lambda do |share, amount|
        if commission_total > 0
          "- (#{working_hours} hrs * #{n2c(working_rate)} p/h) - #{n2c(commission_total)} commission = #{n2c(working_amount)} * #{(share * 100).round(2)}% = #{n2c(amount)}"
        else
          "- #{working_hours} hrs * #{n2c(working_rate)} p/h * #{(share * 100).round(2)}% = #{n2c(amount)}"
        end
      end

      account_lead = pt.account_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
      if account_lead.present?
        amount = (working_amount * rules.account_lead_share).round(2).to_f
        add_entry(line, role: "AccountLead", payee: account_lead, amount: amount, description_line: lead_line.call(rules.account_lead_share, amount))
      end

      project_lead = pt.project_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
      if project_lead.present?
        amount = (working_amount * rules.project_lead_share).round(2).to_f
        add_entry(line, role: "ProjectLead", payee: project_lead, amount: amount, description_line: lead_line.call(rules.project_lead_share, amount))
      end

      individual_contributor = ForecastPerson.find(metadata["forecast_person"])
      return unless individual_contributor.present?

      hourly_rate_of_pay_override = forecast_project.hourly_rate_override_for_email_address(individual_contributor.email)
      if hourly_rate_of_pay_override.present?
        amount = (working_hours * hourly_rate_of_pay_override).round(2).to_f
        add_entry(line,
          role: "IndividualContributor",
          payee: individual_contributor,
          amount: amount,
          rate_override: true,
          description_line: "- #{working_hours} hrs * #{n2c(hourly_rate_of_pay_override)} p/h = #{n2c(amount)}")
      else
        ic_share = rules.ic_share(account_lead: account_lead.present?, project_lead: project_lead.present?)
        amount = (working_amount * ic_share).round(2).to_f
        add_entry(line, role: "IndividualContributor", payee: individual_contributor, amount: amount, description_line: lead_line.call(ic_share, amount))
      end
    end

    # When an IC is paid below the model's ceiling, the line's margin above
    # the threshold is surplus, and each lead takes a share of it. Mirrors
    # ContributorPayout#calculate_surplus, which reads the same figures back
    # from saved payouts: the working amount is the billed line less the
    # commissions actually paid on it, and only paid ICs generate surplus.
    def compute_surplus
      paid = @payees.values.select(&:payable)
      paid_commissions = Hash.new(0.0)
      paid.flat_map(&:entries).each { |e| paid_commissions[e.metadata["id"]] += e.amount if e.role == "Commission" }

      paid.each do |payee|
        payee.entries.select { |e| e.role == "IndividualContributor" }.each do |ic|
          line = @lines.find { |l| l.entries.any? { |e| e.equal?(ic) } }
          pt = line.project_tracker
          next unless pt.present?

          rules = pt.billing_rules
          surplus = rules.surplus_for(working_amount: line.billed - paid_commissions[ic.metadata["id"]], ic_amount: ic.amount)
          next unless surplus > 0

          lead_share = (surplus * rules.surplus_lead_share).round(2).to_f
          lead_pct = "#{(rules.surplus_lead_share * 100).round(2)}%"
          description = line.qbo_line_item.dig("description")

          account_lead = pt.account_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
          if account_lead.present? && payable?(account_lead)
            add_entry(line,
              role: "AccountLeadSurplus",
              payee: account_lead,
              amount: lead_share,
              metadata: ic.metadata,
              description_line: "- #{n2c(surplus)} * #{lead_pct} = #{n2c(lead_share)} (`#{description}` generated #{n2c(surplus)} surplus revenue, #{lead_pct} of which is shared with the Account Lead)")
            @payees[account_lead].payable = true
          end

          project_lead = pt.project_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
          if project_lead.present? && payable?(project_lead)
            add_entry(line,
              role: "ProjectLeadSurplus",
              payee: project_lead,
              amount: lead_share,
              metadata: ic.metadata,
              description_line: "- #{n2c(surplus)} * #{lead_pct} = #{n2c(lead_share)} (`#{description}` generated #{n2c(surplus)} surplus revenue, #{lead_pct} of which is shared with the Project Lead)")
            @payees[project_lead].payable = true
          end
        end
      end
    end
  end
end
```

`InvoiceTracker#commission_deductions_for_line` is already public. Compare every amount expression and description string against the original method line by line; where this listing and the original differ in a way that changes a number or a string, the original wins (except the Project Lead surplus string, whose original has a stray `)` after the backtick — use the form above).

- [ ] **Step 4: Run, confirm pass**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/services/invoice_payouts/build_test.rb`
Expected: 7 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/invoice_payouts/build.rb test/services/invoice_payouts/build_test.rb
git commit -m "feat: InvoicePayouts::Build computes an invoice's payouts in memory, surplus included

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Write payouts from the Build

**Files:**
- Modify: `app/models/invoice_tracker.rb` — replace the whole body of `make_contributor_payouts!`
- Test: `test/models/invoice_tracker_payouts_test.rb` (existing cases must pass unchanged; add the cases below)

**Interfaces:**
- Consumes: `InvoicePayouts::Build#paid_payees`, `Payee#forecast_person`, `#amount`, `#blueprint`.
- Produces: `InvoiceTracker#make_contributor_payouts!(created_by, build: nil)` → the reloaded `contributor_payouts`. Every save it performs sets `skip_seventy_percent_check = true`.

- [ ] **Step 1: Add failing tests** (append inside `InvoiceTrackerPayoutsTest`)

```ruby
  test "a regenerate keeps acceptance on a payout whose surplus-inclusive amount is unchanged" do
    build_tracker("new_deal_v2")
    @project.update!(notes: "#{@ic.email}:80p/h")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)
    al_cp = it.contributor_payouts.reload.find { |c| c.contributor.forecast_person == @al }
    al_cp.update_columns(accepted_at: Time.current)

    it.make_contributor_payouts!(@creator)
    assert al_cp.reload.accepted_at.present?, "acceptance should survive an identical regenerate"
    assert_equal 1, al_cp.blueprint["AccountLeadSurplus"].length, "surplus must not accumulate across regenerates"
  end

  test "a regenerate succeeds when stale payouts would have tripped the cap mid-write" do
    build_tracker("new_deal_v1")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)
    # A leftover payout from an earlier generation, for someone no longer on the invoice.
    stranger = ForecastPerson.create!(forecast_id: 700_009, email: "stale-split@example.com", data: {})
    stranger.ensure_contributor_exists!
    ledger = Ledger.find_or_create_for(enterprise: @client.billing_enterprise, contributor: stranger.reload.contributor)
    stale = ContributorPayout.new(invoice_tracker: it, ledger: ledger, amount: 900.0, blueprint: {}, created_by: @creator)
    stale.skip_seventy_percent_check = true
    stale.save!
    it.contributor_payouts.reset # the tracker's association was loaded before the stale row existed

    assert_nothing_raised { it.make_contributor_payouts!(@creator) }
    assert_nil ContributorPayout.find_by(id: stale.id), "the stale payout should be removed"
    assert_in_delta 1400.0, it.contributor_payouts.reload.sum { |cp| cp.amount.to_f }, 0.01
  end

  test "generation accepts a prebuilt Build" do
    build_tracker("new_deal_v1")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator, build: InvoicePayouts::Build.new(it))
    assert_in_delta 1140.0, amount_for(it, @ic), 0.01
  end
```

- [ ] **Step 2: Run, confirm the new ones fail**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/models/invoice_tracker_payouts_test.rb`
Expected: the three new tests fail or error (`unknown keyword: :build`, `RecordInvalid`, lost acceptance); the five existing pass.

- [ ] **Step 3: Replace `make_contributor_payouts!`**

Replace the entire method (from `def make_contributor_payouts!(created_by)` to its matching `end`, just before the comment that begins `# Retroactively updates the QBO item_ref`) with:

```ruby
  # Saves exactly what InvoicePayouts::Build computed. The per-payout cap
  # validation is skipped on every save here: it sums the tracker's payouts
  # mid-write, while stale ones from the last generation still exist. The
  # caller is expected to have run InvoicePayouts::MarginCheck on the build
  # first (the admin action does); called bare, this writes whatever the
  # build says, over the cap or not.
  def make_contributor_payouts!(created_by, build: nil)
    raise "Payment splits are not supported for this invoice pass" unless invoice_pass.allows_payment_splits?
    return [] if qbo_invoice.nil?

    build ||= InvoicePayouts::Build.new(self)

    ActiveRecord::Base.transaction do
      synced = build.paid_payees.map do |payee|
        forecast_person = payee.forecast_person
        forecast_person.ensure_contributor_exists!
        ledger = Ledger.find_or_create_for(enterprise: forecast_client.billing_enterprise, contributor: forecast_person.contributor)
        cp = contributor_payouts.with_deleted.find_or_initialize_by(ledger_id: ledger.id)
        preserve_acceptance =
          cp.persisted? && cp.accepted_at.present? && amount_equals?(cp.amount, payee.amount)

        attrs = {
          deleted_at: nil,
          amount: payee.amount,
          blueprint: payee.blueprint,
          created_by: created_by,
          description: "",
        }
        # Commission-only CPs (no admin_user behind them) auto-accept now and always.
        # Otherwise: preserve acceptance only when the recomputed amount matches the
        # existing one. Mismatches reset accepted_at so the contributor re-reviews.
        if forecast_person.admin_user.nil?
          attrs[:accepted_at] = DateTime.now
        elsif !preserve_acceptance
          attrs[:accepted_at] = nil
        end
        cp.skip_seventy_percent_check = true
        cp.update!(attrs)
        cp
      end

      # Per-row rescue around obsolete CP destroys: ContributorPayout's
      # before_destroy chain runs SyncsAsQboBill#detach_and_destroy_qbo_bill
      # which raises PaidQboBillError on a paid bill. Without this rescue
      # the exception would roll back the whole transaction. Skip the one
      # paid-bill orphan with a log; the rest of the tracker still updates.
      (contributor_payouts.reload.to_a - synced).each do |orphan|
        begin
          orphan.destroy
        rescue SyncsAsQboBill::PaidQboBillError => e
          Rails.logger.error("[invoice_tracker_make_payouts] ##{id} cannot destroy orphan CP ##{orphan.id}: #{e.message}")
        end
      end

      # Commission-only CPs auto-accept: no contributor is reviewing their own work,
      # since the commission rate was agreed up-front on the project tracker.
      contributor_payouts.reload.each do |cp|
        bp = cp.blueprint || {}
        commission_amount = (bp["Commission"] || []).sum { |e| e["amount"].to_f }
        other_amount = ["AccountLead", "AccountLeadSurplus", "ProjectLead", "ProjectLeadSurplus", "IndividualContributor"].sum do |role|
          (bp[role] || []).sum { |e| e["amount"].to_f }
        end
        if commission_amount > 0 && other_amount == 0 && cp.accepted_at.nil?
          cp.update_columns(accepted_at: DateTime.now)
        end
      end

      contributor_payouts.reload.each do |cp|
        description =
          cp.blueprint.reduce("") do |acc, (role, data)|
            next acc if data.empty?
            acc << "# #{role.to_s.underscore.humanize}\n"
            acc << data.map{|vv| vv["description_line"]}.join("\n")
            acc << "\n\n"
            acc
          end

        description = description << "# Total: #{n2c(cp.amount)}"
        cp.skip_seventy_percent_check = true
        cp.update!(description: description)
      end

      contributor_payouts.reload
    end
  end
```

Keep `n2c`, `commission_deductions_for_line`, `amount_equals?` and `surplus_chunks` where they are; other code uses them.

- [ ] **Step 4: Run**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/models/invoice_tracker_payouts_test.rb test/services/invoice_payouts test/models/contributor_payout_test.rb`
Expected: all pass (8 in the payouts test).

- [ ] **Step 5: Mutation check**

Temporarily delete the first `cp.skip_seventy_percent_check = true`, run the "stale payouts" test, confirm it FAILS, restore the line, confirm it passes.

- [ ] **Step 6: Commit**

```bash
git add app/models/invoice_tracker.rb test/models/invoice_tracker_payouts_test.rb
git commit -m "refactor: make_contributor_payouts! writes what InvoicePayouts::Build computed

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `InvoicePayouts::MarginCheck`

**Files:**
- Create: `app/services/invoice_payouts/margin_check.rb`
- Test: `test/services/invoice_payouts/margin_check_test.rb`

**Interfaces:**
- Consumes: `Build#lines`, `#paid_payees`, `#paid?`, `#paid_commissions_by_line`, `#retained_orphans`, `#invoice_tracker`; `Cap.new(it, commissions_by_line:)`, `#cap`, `#post_commission_total`, `#treasury_share_for`.
- Produces:
  - `InvoicePayouts::MarginCheck.new(build)`; `#build`.
  - `#cap`, `#pool`, `#post_commission_total`, `#over_by` → Float 2dp.
  - `#payout_percentage`, `#cap_percentage` → Float, one decimal (e.g. `73.6`); 0.0 when the post-commission total is not positive.
  - `#breached?` → `pool > cap + 1`.
  - `#rows` → Array of `MarginCheck::Row` (`line`, `billed`, `commissions`, `payouts`, `allowed`, `entries`) with `#over` (Float ≥ 0), `#over?`, `#payout_percentage`, `#margin_percentage`.
  - `#other_billed`, `#other_allowed` → Float (the unmapped remainder; reconciles the table to the totals).
  - `#retained_orphans`, `#retained_total` → payouts that cannot be removed and their pool contribution.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/invoice_payouts/margin_check_test.rb
require "test_helper"

class InvoicePayoutsMarginCheckTest < ActiveSupport::TestCase
  include PayoutFixtures

  setup { setup_payout_people }

  def check_for(lines, **opts)
    InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(build_invoice_tracker(lines, **opts)))
  end

  test "an ordinary invoice sits exactly on its cap and is not breached" do
    build_tracker("new_deal_v2")
    check = check_for([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    assert_in_delta 6700.0, check.pool, 0.01
    assert_in_delta 6700.0, check.cap, 0.01
    assert_not check.breached?
    assert_in_delta 67.0, check.cap_percentage, 0.01
  end

  # A cheap line creates headroom AND surplus; the surplus spends headroom the
  # expensive line was relying on. Pre-surplus the pool is 13,600 (under).
  test "lead surplus on a cheap line counts toward a breach caused by an expensive one" do
    build_tracker("new_deal_v1")
    @project.update!(notes: "#{@ic.email}:20p/h, #{@ic2.email}:90p/h")
    check = check_for([
      { id: "1", person: @ic, hours: 100.0, rate: 100.0 },
      { id: "2", person: @ic2, hours: 100.0, rate: 100.0 },
    ])

    assert_in_delta 14_710.0, check.pool, 0.01
    assert_in_delta 14_000.0, check.cap, 0.01
    assert check.breached?
    assert_in_delta 710.0, check.over_by, 0.01
    assert_in_delta 73.6, check.payout_percentage, 0.01
    assert_in_delta 70.0, check.cap_percentage, 0.01

    cheap, expensive = check.rows
    assert_in_delta 4410.0, cheap.payouts, 0.01     # 2000 + 800 + 500 + 2 * 555
    assert_not cheap.over?
    assert_in_delta 10_300.0, expensive.payouts, 0.01
    assert_in_delta 7000.0, expensive.allowed, 0.01
    assert_in_delta 3300.0, expensive.over, 0.01
    assert expensive.over?
    assert_in_delta 103.0, expensive.payout_percentage, 0.01
    assert_in_delta(-3.0, expensive.margin_percentage, 0.01)
    assert expensive.entries.find { |e| e.role == "IndividualContributor" }.rate_override
    assert_in_delta 0.0, check.other_billed, 0.01
    assert_in_delta 0.0, check.other_allowed, 0.01
  end

  test "payees who are not paid out are left out of the pool" do
    build_tracker("new_deal_v1")
    FullTimePeriod.create!(admin_user: @al_admin, started_at: Date.new(2020, 1, 1), contributor_type: :five_day, expected_utilization: 0.8)
    check = check_for([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    assert_in_delta 6200.0, check.pool, 0.01 # 5700 IC + 500 PL; the AL's 800 is salaried
    assert_in_delta 6200.0, check.rows.first.payouts, 0.01
    assert_equal 3, check.rows.first.entries.length, "unpaid entries are still listed"
  end

  test "commissions are outside the pool and come off the cap's basis" do
    pt = build_tracker("new_deal_v2")
    recipient = ForecastPerson.create!(forecast_id: 710_004, email: "comm-guard@example.com", data: {})
    recipient.ensure_contributor_exists!
    PercentageCommission.create!(project_tracker: pt, contributor: recipient.reload.contributor, rate: 0.10)
    check = check_for([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    assert_in_delta 9000.0, check.post_commission_total, 0.01
    assert_in_delta 6030.0, check.cap, 0.01
    assert_in_delta 6030.0, check.pool, 0.01
    assert_in_delta 1000.0, check.rows.first.commissions, 0.01
    assert_not check.breached?
  end

  test "the unmapped remainder reconciles the rows to the cap" do
    build_tracker("new_deal_v2")
    check = check_for([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }], total: 12_000.0)
    assert_in_delta 2000.0, check.other_billed, 0.01
    assert_in_delta 1400.0, check.other_allowed, 0.01
    assert_in_delta check.cap, check.rows.sum(&:allowed) + check.other_allowed, 0.01
  end

  test "a payout that cannot be removed stays in the pool" do
    build_tracker("new_deal_v1")
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    stranger = ForecastPerson.create!(forecast_id: 710_009, email: "gone-guard@example.com", data: {})
    stranger.ensure_contributor_exists!
    ledger = Ledger.find_or_create_for(enterprise: @client.billing_enterprise, contributor: stranger.reload.contributor)
    paid = ContributorPayout.new(invoice_tracker: it, ledger: ledger, amount: 3000.0, blueprint: {}, created_by: @creator)
    paid.skip_seventy_percent_check = true
    paid.save!
    bill = mock("qbo_bill")
    bill.stubs(:has_payments?).returns(true)
    ContributorPayout.any_instance.stubs(:qbo_bill).returns(bill)

    check = InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(it.reload))
    assert_in_delta 3000.0, check.retained_total, 0.01
    assert_in_delta 10_000.0, check.pool, 0.01
    assert check.breached?
  end

  test "the surplus invariant: a lone line with surplus never exceeds its own cap" do
    Stacks::BillingModel::ALL.each_value do |rules|
      assert rules.surplus_lead_share * 2 < 1, "#{rules.name}: lead surplus shares must leave some surplus for the company"
    end
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/services/invoice_payouts/margin_check_test.rb`
Expected: `NameError: uninitialized constant InvoicePayouts::MarginCheck`.

- [ ] **Step 3: Implement**

```ruby
# app/services/invoice_payouts/margin_check.rb
module InvoicePayouts
  # Rules on a Build before it is written: would the invoice pay out more
  # than its cap? Also the row-by-row breakdown the admin overlay shows.
  #
  # The pool is everything that will sit on the tracker after the write, net
  # of commissions: the payees Build will pay, plus any existing payout the
  # write cannot remove because its QBO bill is already paid.
  class MarginCheck
    Row = Struct.new(:line, :billed, :commissions, :payouts, :allowed, :entries, keyword_init: true) do
      def basis
        billed - commissions
      end

      def over
        [(payouts - allowed).round(2), 0.0].max
      end

      def over?
        over > 1
      end

      def payout_percentage
        basis > 0 ? (payouts / basis * 100).round(1) : 0.0
      end

      def margin_percentage
        basis > 0 ? (100 - payouts / basis * 100).round(1) : 0.0
      end
    end

    attr_reader :build

    def initialize(build)
      @build = build
    end

    def retained_orphans
      build.retained_orphans
    end

    def retained_total
      retained_orphans.sum { |cp| cp.amount.to_f - cp.as_commission }.round(2)
    end

    def cap_calculation
      @cap_calculation ||= begin
        commissions = build.paid_commissions_by_line.dup
        retained_orphans.each do |cp|
          (cp.blueprint["Commission"] || []).each do |entry|
            line_id = entry["blueprint_metadata"].is_a?(Hash) ? entry["blueprint_metadata"]["id"]&.to_s : nil
            commissions[line_id] = commissions.fetch(line_id, 0.0) + entry["amount"].to_f
          end
        end
        Cap.new(build.invoice_tracker, commissions_by_line: commissions)
      end
    end

    def cap
      cap_calculation.cap
    end

    def post_commission_total
      cap_calculation.post_commission_total
    end

    def pool
      (build.paid_payees.sum { |p| p.amount - p.commission_amount } + retained_total).round(2)
    end

    def breached?
      pool > cap + 1 # a dollar of slack for rounding, as the save-time validation allows
    end

    def over_by
      [(pool - cap).round(2), 0.0].max
    end

    def payout_percentage
      percentage_of_total(pool)
    end

    def cap_percentage
      percentage_of_total(cap)
    end

    def rows
      @rows ||= build.lines.map do |line|
        line_id = line.qbo_line_item["id"].to_s
        commissions = build.paid_commissions_by_line.fetch(line_id, 0.0)
        paid_entries = line.entries.select { |e| e.role != "Commission" && build.paid?(e.payee) }
        Row.new(
          line: line,
          billed: line.billed,
          commissions: commissions,
          payouts: paid_entries.sum(&:amount).round(2),
          allowed: ((line.billed - commissions) * (1 - cap_calculation.treasury_share_for(line_id))).to_f.round(2),
          entries: line.entries,
        )
      end
    end

    # Whatever is on the invoice but not on a blueprint line (recurring
    # charges, discounts), so the table adds up to the totals above it.
    def other_billed
      (build.invoice_tracker.total.to_f - rows.sum(&:billed)).round(2)
    end

    def other_allowed
      (cap - rows.sum(&:allowed)).round(2)
    end

    private

    def percentage_of_total(amount)
      post_commission_total > 0 ? (amount / post_commission_total * 100).round(1) : 0.0
    end
  end
end
```

- [ ] **Step 4: Run, confirm pass**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/services/invoice_payouts`
Expected: all pass.

- [ ] **Step 5: Cross-check the pre-flight against the write**

Add to `margin_check_test.rb`:

```ruby
  test "the pool the check predicts is the pool generation saves" do
    build_tracker("new_deal_v1")
    @project.update!(notes: "#{@ic.email}:20p/h, #{@ic2.email}:90p/h")
    it = build_invoice_tracker([
      { id: "1", person: @ic, hours: 100.0, rate: 100.0 },
      { id: "2", person: @ic2, hours: 100.0, rate: 100.0 },
    ])
    predicted = InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(it)).pool
    it.make_contributor_payouts!(@creator)
    saved = it.contributor_payouts.reload.sum { |cp| cp.amount.to_f - cp.as_commission }
    assert_in_delta predicted, saved, 0.01
    assert_in_delta it.surplus, 3700.0, 0.01, "the saved-state surplus view still agrees"
  end
```

Run the file again; expected pass.

- [ ] **Step 6: Commit**

```bash
git add app/services/invoice_payouts/margin_check.rb test/services/invoice_payouts/margin_check_test.rb
git commit -m "feat: InvoicePayouts::MarginCheck rules on a payout build before it is written

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Save-time validation uses the same cap and sees the edit

**Files:**
- Modify: `app/models/contributor_payout.rb` (the `validate` line and `contributor_payouts_within_seventy_percent`)
- Modify: `test/models/contributor_payout_test.rb` (the two existing "70% cap" tests call the private method by name)
- Test: `test/models/contributor_payout_cap_validation_test.rb`

**Interfaces:**
- Consumes: `InvoicePayouts::Cap`.
- Produces: `ContributorPayout#contributor_payouts_within_cap` (validation; same skip rules as before).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/models/contributor_payout_cap_validation_test.rb
require "test_helper"

class ContributorPayoutCapValidationTest < ActiveSupport::TestCase
  include PayoutFixtures

  setup do
    setup_payout_people
    build_tracker("new_deal_v2")
    @it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    @it.make_contributor_payouts!(@creator) # IC 5400, AL 800, PL 500 = 6700 = the 67% cap
    @ic_cp = @it.contributor_payouts.reload.find { |cp| cp.contributor.forecast_person == @ic }
  end

  test "editing a persisted payout over the cap is rejected" do
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 9000.0
    assert_not cp.valid?
    assert_match(/may not exceed \$6,700\.00 \(67\.0% of post-commission invoice total\)/, cp.errors[:base].join)
  end

  test "an edit that stays within the cap is accepted" do
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 5400.5 # within the dollar of slack
    assert cp.valid?, cp.errors.full_messages.join(", ")
  end

  test "a new manual payout that pushes the invoice over is rejected" do
    stranger = ForecastPerson.create!(forecast_id: 710_009, email: "extra-guard@example.com", data: {})
    stranger.ensure_contributor_exists!
    ledger = Ledger.find_or_create_for(enterprise: @client.billing_enterprise, contributor: stranger.reload.contributor)
    cp = ContributorPayout.new(invoice_tracker: @it, ledger: ledger, amount: 50.0, blueprint: {}, created_by: @creator)
    assert_not cp.valid?
  end

  test "a v2 invoice is capped at 67%, not the old flat 70%" do
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 5600.0 # pool 6900: under 70%, over 67%
    assert_not cp.valid?
  end

  test "target_margin_override loosens the cap" do
    @it.update!(target_margin_override: 0.25)
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 6100.0 # pool 7400 <= 7500
    assert cp.valid?, cp.errors.full_messages.join(", ")
  end

  test "the admin override and acceptance-only saves still skip the check" do
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 9000.0
    cp.skip_seventy_percent_check = "1"
    assert cp.valid?

    @ic_cp.update_columns(amount: 9000.0)
    over = ContributorPayout.find(@ic_cp.id)
    over.accepted_at = Time.current
    assert over.valid?
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/models/contributor_payout_cap_validation_test.rb`
Expected: "editing a persisted payout" and "a v2 invoice is capped at 67%" fail (others may pass).

- [ ] **Step 3: Implement**

In `app/models/contributor_payout.rb` change `validate :contributor_payouts_within_seventy_percent` to `validate :contributor_payouts_within_cap`, and replace the whole `contributor_payouts_within_seventy_percent` method with:

```ruby
  def contributor_payouts_within_cap
    return if ActiveModel::Type::Boolean.new.cast(skip_seventy_percent_check) # Ephemeral admin override
    return if changes.keys == ["accepted_at"] # Don't check if the payout is being accepted or unaccepted

    # Swap this record in for its saved copy: the association reads from the
    # database, which still holds the amount from before this edit.
    others = invoice_tracker.contributor_payouts.reject { |cp| cp.equal?(self) || (persisted? && cp.id == id) }
    cps = [*others, self]

    commissions_by_line = Hash.new(0.0)
    cps.each do |cp|
      (cp.blueprint["Commission"] || []).each do |entry|
        commissions_by_line[cp.entry_line_id(entry)] += entry["amount"].to_f
      end
    end

    cap = InvoicePayouts::Cap.new(invoice_tracker, commissions_by_line: commissions_by_line)
    max_amount = cap.cap
    contributor_pool_sum = cps.sum { |cp| cp.amount.to_f - cp.as_commission }

    if contributor_pool_sum > (max_amount + 1) # Add a dollar to account for rounding errors
      percentage = cap.post_commission_total > 0 ? (max_amount / cap.post_commission_total * 100).round(1) : 0.0
      errors.add(:base, "Contributor Payouts may not exceed #{ActionController::Base.helpers.number_to_currency(max_amount)} (#{percentage}% of post-commission invoice total).")
    end
  end
```

and next to `entry_forecast_project` add:

```ruby
  def entry_line_id(entry)
    metadata = entry["blueprint_metadata"]
    metadata.is_a?(Hash) ? metadata["id"]&.to_s : nil
  end
```

- [ ] **Step 4: Update the two existing mock-based tests in `test/models/contributor_payout_test.rb`**

They call `send(:contributor_payouts_within_seventy_percent)` on payouts whose tracker is a Mocha mock. Rename the call to `contributor_payouts_within_cap`. The mock tracker must now answer what `Cap` asks of it on the override branch: keep `margin_override` → `BigDecimal("0.30")`, `total`, `forecast_client` (with `is_internal?`), and `contributor_payouts`. Read the two tests and add any stub the new code path needs; do not weaken their assertions (the first asserts no error at 630 post-commission cap, the second asserts the "may not exceed" error). If the error-message assertion matches the old "70.0%" wording, update it to the new message format `(70.0% of post-commission invoice total)`.

- [ ] **Step 5: Run**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/models/contributor_payout_cap_validation_test.rb test/models/contributor_payout_test.rb test/models/invoice_tracker_payouts_test.rb test/services/invoice_payouts`
Expected: all pass. Then `grep -rn "seventy_percent" app test` should show only `skip_seventy_percent_check` references.

- [ ] **Step 6: Commit**

```bash
git add app/models/contributor_payout.rb test/models/contributor_payout_test.rb test/models/contributor_payout_cap_validation_test.rb
git commit -m "fix: payout cap validation follows the billing model and sees the edited amount

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Gate "Calculate Default Payouts" on the margin check

**Files:**
- Modify: `app/admin/contributor_payouts.rb` (`collection_action :make_payouts`; `controller do` → `create`, add `update`)
- Test: `test/integration/admin_payout_margin_guard_test.rb`

**Interfaces:**
- Consumes: `InvoicePayouts::Build`, `InvoicePayouts::MarginCheck#breached?`, `#payout_percentage`, `#cap_percentage`; `InvoiceTracker#make_contributor_payouts!(created_by, build:)`.
- Produces: `POST make_payouts` params `force` and `override_reason`; redirect to `admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)` on a breach.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/integration/admin_payout_margin_guard_test.rb
require "test_helper"

class AdminPayoutMarginGuardTest < ActionDispatch::IntegrationTest
  include PayoutFixtures

  setup do
    setup_payout_people
    build_tracker("new_deal_v1")
    sign_in @creator
  end

  def within_cap_tracker
    build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
  end

  def breaching_tracker
    @project.update!(notes: "#{@ic.email}:90p/h")
    build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }]) # 9000 + 800 + 500 vs 7000
  end

  test "within the cap: payouts are generated" do
    it = within_cap_tracker
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_equal "Payouts processed!", flash[:notice]
    assert_equal 3, it.contributor_payouts.count
  end

  test "over the cap: nothing is written and the admin is sent to the overlay" do
    it = breaching_tracker
    assert InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(it)).breached?, "fixture must breach"

    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    end
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
  end

  test "force without a reason writes nothing" do
    it = breaching_tracker
    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "   " }
    end
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_match(/reason is required/i, flash[:alert])
    assert_nil it.reload.notes
  end

  test "force with a reason generates and records the override in the notes" do
    it = breaching_tracker
    it.update!(notes: "Existing note")
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "Agreed fixed fee with the contractor" }

    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_equal 3, it.contributor_payouts.count
    assert_in_delta 10_300.0, it.contributor_payouts.sum(:amount).to_f, 0.01
    notes = it.reload.notes
    assert notes.start_with?("Existing note\n\n"), notes
    assert_match(/\[\d{4}-\d{2}-\d{2}\] #{Regexp.escape(@creator.email)} generated payouts over the cap \(103\.0% vs 70\.0%\): Agreed fixed fee with the contractor/, notes)
  end

  test "non-admins cannot generate payouts" do
    it = within_cap_tracker
    delete destroy_admin_user_session_path
    lead = AdminUser.create!(email: "lead-guard@example.com", password: "password123", password_confirmation: "password123")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    sign_in lead

    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    end
    assert_equal "Admins only.", flash[:alert]
  end

  test "a build failure is reported, not a 500" do
    it = within_cap_tracker
    ProjectTrackerForecastProject.delete_all
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_match(/Could not calculate payouts: No project trackers found/, flash[:alert])
  end

  test "a non-admin cannot smuggle skip_seventy_percent_check through update" do
    it = within_cap_tracker
    it.make_contributor_payouts!(@creator)
    cp = it.contributor_payouts.find { |c| c.contributor.forecast_person == @ic }
    delete destroy_admin_user_session_path
    lead = AdminUser.create!(email: "lead2-guard@example.com", password: "password123", password_confirmation: "password123")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    sign_in lead

    patch admin_invoice_tracker_contributor_payout_path(it, cp), params: { contributor_payout: { amount: 9000, skip_seventy_percent_check: "1" } }
    assert_in_delta 5700.0, cp.reload.amount.to_f, 0.01

    delete destroy_admin_user_session_path
    sign_in @creator
    patch admin_invoice_tracker_contributor_payout_path(it, cp), params: { contributor_payout: { amount: 9000, skip_seventy_percent_check: "1" } }
    assert_in_delta 9000.0, cp.reload.amount.to_f, 0.01, "an admin can still use the override"
  end

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
```

Notes for the implementer: confirm how a global `lead` grant is created by reading `app/models/permission_grant.rb` and `test/integration/admin_permission_grants_test.rb`, and adjust the two `PermissionGrant.create!` calls to match; confirm the sign-out route name with `bin/rails routes | grep admin_user_session`. If a lead cannot reach `update` on someone else's payout at all (the request is refused before the controller), keep the assertion that the amount is unchanged and ALSO assert the admin half, which is the half that proves the param is wired up.

- [ ] **Step 2: Run, confirm failures**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/integration/admin_payout_margin_guard_test.rb`
Expected: "over the cap", both force tests, "non-admins", "build failure" and the smuggle test fail.

- [ ] **Step 3: Replace `collection_action :make_payouts`**

```ruby
  collection_action :make_payouts, method: :post do
    invoice_tracker = InvoiceTracker.find(params["invoice_tracker_id"])
    index_path = admin_invoice_tracker_contributor_payouts_path(invoice_tracker)
    return redirect_to(index_path, alert: "Admins only.") unless current_admin_user.is_admin?

    begin
      if invoice_tracker.qbo_invoice.nil?
        invoice_tracker.make_contributor_payouts!(current_admin_user)
        return redirect_to(index_path, notice: "Payouts processed!")
      end

      # Rule on the whole invoice before writing anything. Over the cap, the
      # index re-runs this check and shows the breakdown; an admin can then
      # come back here with a reason to generate regardless.
      build = InvoicePayouts::Build.new(invoice_tracker)
      check = InvoicePayouts::MarginCheck.new(build)

      if check.breached?
        breach_path = admin_invoice_tracker_contributor_payouts_path(invoice_tracker, margin_breach: 1)
        return redirect_to(breach_path) unless params[:force].present?

        reason = params[:override_reason].to_s.strip
        return redirect_to(breach_path, alert: "A reason is required to generate payouts over the cap.") if reason.blank?

        override_note = "[#{Date.today.iso8601}] #{current_admin_user.email} generated payouts over the cap (#{check.payout_percentage}% vs #{check.cap_percentage}%): #{reason}"
        ActiveRecord::Base.transaction do
          invoice_tracker.make_contributor_payouts!(current_admin_user, build: build)
          invoice_tracker.update!(notes: [invoice_tracker.notes.presence, override_note].compact.join("\n\n"))
        end
      else
        invoice_tracker.make_contributor_payouts!(current_admin_user, build: build)
      end

      redirect_to index_path, notice: "Payouts processed!"
    rescue StandardError => e
      Rails.logger.error("[contributor_payouts_make_payouts] it=#{invoice_tracker.id}: #{e.class}: #{e.message}")
      redirect_to index_path, alert: "Could not calculate payouts: #{e.message}"
    end
  end
```

- [ ] **Step 4: Strip the override param for non-admins**

In the `controller do` block, change `create` and add `update`:

```ruby
    def create
      params[:contributor_payout]["created_by_id"] = current_admin_user.id
      params[:contributor_payout]["blueprint"] = {}
      strip_admin_only_params
      super
    end

    def update
      strip_admin_only_params
      super
    end

    # The form only shows this box to admins, but hiding an input enforces
    # nothing: permit_params is one list for everyone.
    def strip_admin_only_params
      return if current_admin_user.is_admin?
      params[:contributor_payout]&.delete(:skip_seventy_percent_check)
      # A hand-written Commission entry is subtracted from the pool the cap
      # is checked against, so the raw blueprint is admin-only too.
      params[:contributor_payout]&.delete(:blueprint) if action_name == "update"
    end
```

Also in the `form do |f|` block change the checkbox label to `"Skip payout cap validation (one-time override, not persisted)"` and its hint's "would exceed 70% of the invoice total" to "would exceed the invoice's payout cap".

- [ ] **Step 5: Run**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/integration/admin_payout_margin_guard_test.rb`
Expected: all pass.

- [ ] **Step 6: Mutation checks**

(a) Remove the `unless current_admin_user.is_admin?` guard line → "non-admins cannot generate payouts" must fail. Restore.
(b) Remove the `strip_admin_only_params` call in `update` → the smuggle test must fail on its first assertion. Restore. If (b) does not fail, the lead never reached `update`; say so in your report rather than leaving a vacuous test unexplained.

- [ ] **Step 7: Commit**

```bash
git add app/admin/contributor_payouts.rb test/integration/admin_payout_margin_guard_test.rb
git commit -m "feat: block Calculate Default Payouts when the invoice would exceed its cap

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The overlay

**Files:**
- Create: `app/views/admin/contributor_payouts/_margin_breach.html.erb`
- Modify: `app/admin/contributor_payouts.rb` (new `action_item :margin_breach`)
- Modify: `app/assets/stylesheets/active_admin.scss` (append a small block after the `.full-screen-modal` rules)
- Test: `test/integration/admin_payout_margin_guard_test.rb` (append)

**Interfaces:**
- Consumes: `MarginCheck#breached?`, `#payout_percentage`, `#cap_percentage`, `#post_commission_total`, `#pool`, `#cap`, `#over_by`, `#rows` (Row: `line.qbo_line_item["description"]`, `billed`, `commissions`, `payouts`, `payout_percentage`, `margin_percentage`, `allowed`, `over`, `over?`, `entries`), Entry (`role`, `payee.email`, `amount`, `description_line`, `rate_override`), `#build.paid?(payee)`, `#other_billed`, `#other_allowed`, `#retained_orphans`, `#retained_total`.

- [ ] **Step 1: Write the failing tests** (append inside `AdminPayoutMarginGuardTest`, above `private`)

```ruby
  test "the overlay lists every line with its roles and the override form" do
    it = breaching_tracker
    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success

    assert_select ".full-screen-modal.margin-breach" do
      assert_select "h2", text: /The generated payouts would be 103\.0% of gross earnings\. The cap for this invoice is 70\.0%\./
      assert_select "tr.margin-breach__line", 1
      assert_select "tr.margin-breach__line.over", 1
      assert_select "tr.margin-breach__entry", 3
      assert_select "tr.margin-breach__entry", text: /rate override/
      assert_select "tr.margin-breach__entry", text: /#{Regexp.escape(@ic.email)}/
      assert_select "form[action=?][method=post]", make_payouts_admin_invoice_tracker_contributor_payouts_path(it) do
        assert_select "input[name=force][value='1']"
        assert_select "textarea[name=override_reason][required]"
        assert_select "input[type=submit][value='Generate anyway']"
      end
      assert_select "a[href=?]", admin_invoice_tracker_contributor_payouts_path(it), text: /Close/
    end
    assert_select ".margin-breach tr.margin-breach__entry", text: /not paid out/, count: 0
    assert_match "$10,300.00", response.body
    assert_match "$7,000.00", response.body
    assert_match "$3,300.00", response.body
  end

  test "no overlay when the invoice is within its cap, even with the flag" do
    it = within_cap_tracker
    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success
    assert_select ".margin-breach", 0
  end

  test "no overlay without the flag" do
    it = breaching_tracker
    get admin_invoice_tracker_contributor_payouts_path(it)
    assert_response :success
    assert_select ".margin-breach", 0
  end

  test "no overlay, and no error, when the build cannot be computed" do
    it = breaching_tracker
    ProjectTrackerForecastProject.delete_all
    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success
    assert_select ".margin-breach", 0
  end

  test "non-admins never see the overlay" do
    it = breaching_tracker
    delete destroy_admin_user_session_path
    viewer = AdminUser.create!(email: "viewer-guard@example.com", password: "password123", password_confirmation: "password123")
    PermissionGrant.create!(admin_user: viewer, permission: "lead") # a lead can read the index; a bare user is redirected
    sign_in viewer

    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success
    assert_select ".margin-breach", 0
    assert_no_match(/rate override/, response.body)
  end
```

- [ ] **Step 2: Run, confirm the first test fails**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/integration/admin_payout_margin_guard_test.rb`
Expected: "the overlay lists every line" fails; the "no overlay" tests pass already.

- [ ] **Step 3: Add the action item** (in `app/admin/contributor_payouts.rb`, directly after the existing `action_item :make_payouts` block)

```ruby
  # The breakdown shown after make_payouts refused to write. It re-runs the
  # check here rather than carrying the result across the redirect; the modal
  # is position: fixed, so it covers the page from wherever it is rendered.
  action_item :margin_breach, only: :index, if: proc { params[:margin_breach].present? && current_admin_user.is_admin? } do
    check =
      begin
        candidate = InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(invoice_tracker)) if invoice_tracker.qbo_invoice.present?
        candidate if candidate&.breached? && candidate.rows
      rescue StandardError => e
        Rails.logger.error("[contributor_payouts_margin_breach] it=#{invoice_tracker.id}: #{e.class}: #{e.message}")
        nil
      end
    render(partial: "admin/contributor_payouts/margin_breach", locals: { check: check, invoice_tracker: invoice_tracker }) if check
  end
```

- [ ] **Step 4: Write the partial**

```erb
<%# app/views/admin/contributor_payouts/_margin_breach.html.erb %>
<%
  role_labels = {
    "IndividualContributor" => "IC",
    "AccountLead" => "AL",
    "ProjectLead" => "PL",
    "Commission" => "Commission",
    "AccountLeadSurplus" => "AL surplus",
    "ProjectLeadSurplus" => "PL surplus",
  }
  index_path = admin_invoice_tracker_contributor_payouts_path(invoice_tracker)
%>
<div class="full-screen-modal margin-breach">
  <div class="full-screen-modal__contents">
    <div class="full-screen-modal__contents__title">
      <% if flash[:alert].present? %><p class="margin-breach__alert"><%= flash[:alert] %></p><% end %>
      <h2>The generated payouts would be <%= check.payout_percentage %>% of gross earnings. The cap for this invoice is <%= check.cap_percentage %>%.</h2>
      <p>
        Nothing has been written. Billed after commissions: <strong><%= number_to_currency check.post_commission_total %></strong>.
        Generated payouts: <strong><%= number_to_currency check.pool %></strong>.
        Allowed: <strong><%= number_to_currency check.cap %></strong>.
        Over by: <strong><%= number_to_currency check.over_by %></strong>.
      </p>
    </div>

    <div class="full-screen-modal__contents__body">
      <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
        <thead>
          <tr>
            <th class="col">Invoice Item</th>
            <th class="col text-right">Billed</th>
            <th class="col text-right">Payouts</th>
            <th class="col text-right">Payout %</th>
            <th class="col text-right">Margin %</th>
            <th class="col text-right">Allowed</th>
            <th class="col text-right">Over</th>
          </tr>
        </thead>
        <tbody>
          <% check.rows.each do |row| %>
            <tr class="margin-breach__line <%= "over" if row.over? %>">
              <td class="col"><strong><%= row.line.qbo_line_item["description"] %></strong></td>
              <td class="col text-right"><%= number_to_currency row.billed %></td>
              <td class="col text-right"><%= number_to_currency row.payouts %></td>
              <td class="col text-right"><%= row.payout_percentage %>%</td>
              <td class="col text-right"><%= row.margin_percentage %>%</td>
              <td class="col text-right"><%= number_to_currency row.allowed %></td>
              <td class="col text-right"><%= row.over? ? "+ #{number_to_currency(row.over)}" : "—" %></td>
            </tr>
            <% row.entries.each do |entry| %>
              <tr class="margin-breach__entry">
                <td class="col">
                  <%= role_labels.fetch(entry.role, entry.role) %> · <%= entry.payee.email %>
                  <% if entry.rate_override %><span class="pill error">rate override</span><% end %>
                  <% unless check.build.paid?(entry.payee) %><span class="pill">not paid out</span><% end %>
                  <% if entry.description_line.present? %><br><small><%= entry.description_line %></small><% end %>
                </td>
                <td class="col"></td>
                <td class="col text-right"><%= number_to_currency entry.amount %></td>
                <td class="col" colspan="4"></td>
              </tr>
            <% end %>
          <% end %>

          <% if check.retained_orphans.any? %>
            <tr class="margin-breach__other">
              <td class="col"><strong>Earlier payouts that can't be removed (QBO bill already paid)</strong></td>
              <td class="col"></td>
              <td class="col text-right"><%= number_to_currency check.retained_total %></td>
              <td class="col" colspan="4"></td>
            </tr>
          <% end %>

          <% if check.other_billed.abs > 0.01 || check.other_allowed.abs > 0.01 %>
            <tr class="margin-breach__other">
              <td class="col"><strong>Unmapped / other invoice lines</strong></td>
              <td class="col text-right"><%= number_to_currency check.other_billed %></td>
              <td class="col text-right">—</td>
              <td class="col" colspan="2"></td>
              <td class="col text-right"><%= number_to_currency check.other_allowed %></td>
              <td class="col"></td>
            </tr>
          <% end %>

          <tr class="margin-breach__total">
            <td class="col"><strong>TOTAL</strong> <small>(billed is before commissions)</small></td>
            <td class="col text-right"><%= number_to_currency invoice_tracker.total %></td>
            <td class="col text-right"><%= number_to_currency check.pool %></td>
            <td class="col text-right"><%= check.payout_percentage %>%</td>
            <td class="col text-right"><%= (100 - check.payout_percentage).round(1) %>%</td>
            <td class="col text-right"><%= number_to_currency check.cap %></td>
            <td class="col text-right">+ <%= number_to_currency check.over_by %></td>
          </tr>
        </tbody>
      </table>
    </div>

    <%= form_tag make_payouts_admin_invoice_tracker_contributor_payouts_path(invoice_tracker), method: :post, class: "margin-breach__override" do %>
      <%= hidden_field_tag :force, "1" %>
      <%= text_area_tag :override_reason, nil, required: true, rows: 2, placeholder: "Why should this invoice pay out more than its cap? Saved to the invoice's notes." %>
      <div class="margin-breach__actions">
        <%= link_to "Close", index_path %>
        <%= submit_tag "Generate anyway" %>
      </div>
    <% end %>
  </div>
</div>
<script>
  // Rendered inside the title bar, which is its own stacking context
  // (z-index: 800): move it to <body> so it sits above the nav badges too.
  document.body.appendChild(document.querySelector(".full-screen-modal.margin-breach"));
</script>
```

- [ ] **Step 5: Add styles** (append after the `.full-screen-modal { ... }` block in `app/assets/stylesheets/active_admin.scss`)

```scss
.full-screen-modal.margin-breach {
  text-align: left;
  font-weight: normal;

  h2 {
    font-size: 20px;
    line-height: 1.3;
    font-weight: 700;
  }

  .margin-breach__alert {
    color: $color-red;
  }

  .full-screen-modal__contents__body {
    padding: 0 20px;
  }

  tr.margin-breach__line.over td {
    color: $color-red;
  }

  tr.margin-breach__entry td {
    padding-top: 4px;
    padding-bottom: 4px;
    padding-left: 30px;
    border-bottom: none;
  }

  form.margin-breach__override {
    padding: 20px;
    display: flex;
    align-items: center;
    gap: 20px;

    textarea {
      flex-grow: 1;
      margin-bottom: 0;
    }

    .margin-breach__actions {
      display: flex;
      align-items: center;
      gap: 12px;
      white-space: nowrap;
    }
  }
}
```

`$color-red` is already used in this file (the rule just above `.full-screen-modal`). If the stylesheet fails to compile, find the variable's definition with `grep -rn "color-red" app/assets/stylesheets` and use what exists.

- [ ] **Step 6: Run**

Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test test/integration/admin_payout_margin_guard_test.rb`
Expected: all pass. If `assert_select "tr.margin-breach__entry", 3` counts differently, print the entries for the fixture and reconcile against Task 3's expectations (one AL, one PL, one IC; no surplus because the IC is above the ceiling) before changing any number.

- [ ] **Step 7: Full suite**

First `ps -o pid,etime,command -ax | grep "[r]ails test"` must print nothing. Then:
Run: `DATABASE_URL=postgres:///stacks_test_margin_guard bin/rails test --exclude "/EtlRakeTest/"`
Expected: 0 failures, 0 errors. A failure in `AdminUserTest` "initial salary window" between 20:00 and 24:00 ET is a known clock issue unrelated to this work; report any other failure.

- [ ] **Step 8: Commit**

```bash
git add app/admin/contributor_payouts.rb app/views/admin/contributor_payouts/_margin_breach.html.erb app/assets/stylesheets/active_admin.scss test/integration/admin_payout_margin_guard_test.rb
git commit -m "feat: full-screen breakdown when generated payouts would exceed the cap

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
