# Billing Model Implementation Plan (Part 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every `ProjectTracker` a `billing_model` enum that owns the payout split rules (treasury, lead shares, surplus), replacing the `company_treasury_split` column and the hardcoded percentages in the payout builder and surplus calc, so new-rate-card trackers pay a 54% IC ceiling with 33% treasury.

**Architecture:** A frozen registry `Stacks::BillingModel` maps each model name to a `Rules` value object with derived `ic_ceiling` / `surplus_threshold` / `ic_share`. `ProjectTracker#billing_rules` reads it; `company_treasury_split` becomes a method. `InvoiceTracker#make_contributor_payouts!` and `ContributorPayout#calculate_surplus` read the rules instead of literals.

**Tech Stack:** Rails 6.1, PostgreSQL, ActiveAdmin, minitest + mocha.

**Spec:** `docs/superpowers/specs/2026-09-08-contributor-payment-projections-design.md` (Part 1).

## Global Constraints

- Work ONLY in the worktree `/Users/hhff/Documents/Code/stacks/.claude/worktrees/feat+contributor-payment-projections`. Never `cd` to `/Users/hhff/Documents/Code/stacks`. Before every commit run `git rev-parse --abbrev-ref HEAD`; if it does not print `worktree-feat+contributor-payment-projections`, STOP and report BLOCKED.
- Model names are exactly `new_deal_v1` (default) and `new_deal_v2`. Rule values: v1 = treasury 0.30 / AL 0.08 / PL 0.05 / surplus lead share 0.15; v2 = treasury 0.33 / AL 0.08 / PL 0.05 / surplus lead share 0.15. Derived: v1 IC ceiling 0.57, threshold 0.43; v2 IC ceiling 0.54, threshold 0.46.
- `invoice_trackers.company_treasury_split` and `ContributorPayout#contributor_payouts_within_seventy_percent` are NOT touched.
- Shares are `BigDecimal`; coerce with `.to_f` only where a Float is written into a jsonb blueprint.
- Run targeted test files only (`bin/rails test path/to/file_test.rb`); the full suite takes ~100 minutes and is run once at the end of Part 3.
- `stacks_development` and `stacks_test` are SHARED with the main checkout and every other worktree (`config/database.yml` has no per-worktree naming). Migrating here changes them for everyone. Do not run the main checkout's dev server or tests until this branch merges. If this worktree's tests start failing with `unknown attribute 'billing_model'` or `PendingMigrationError`, another checkout reloaded the test DB — re-run the Schema procedure's two `RAILS_ENV=test` commands.
- After adding the migration, follow the **Schema procedure** below exactly. `db/schema.rb` is hand-curated in this repo (pgvector and a generated column are deliberately omitted so `schema:load` works without pgvector); a raw dump must not be committed.

## Schema procedure

```bash
bin/rails db:migrate
git diff db/schema.rb
```
Keep ONLY: the `ActiveRecord::Schema.define(version: ...)` bump and the changes this task makes to `project_trackers` (the new `billing_model` column, the removed `company_treasury_split` column and its check constraint). Revert everything else the dumper re-emitted: restore the pgvector comment block under `enable_extension`, remove any re-added `enable_extension "vector"`, `t.vector "embedding"`, `hnsw` index, and the `content_tsv` column / GIN index on `chunks` (restore that comment block too). Compare against the last schema commit (`git log -1 -- db/schema.rb`) — the diff must otherwise be byte-identical to HEAD. Then:
```bash
RAILS_ENV=test bin/rails db:environment:set   # test DB lacks ar_internal_metadata.environment; schema:load aborts without this
RAILS_ENV=test bin/rails db:schema:load
```
Expected: schema loads with no error. If `schema:load` fails, the leftover is almost always a re-dumped `content_tsv` DEFAULT or `vector` column — re-check the diff.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8
  ```

---

## File map

| File | Responsibility |
|---|---|
| `lib/stacks/billing_model.rb` (create) | Registry of `Rules` value objects; `for(name)`; `DEFAULT` |
| `test/lib/stacks/billing_model_test.rb` (create) | Rules math |
| `db/migrate/20260909000001_add_billing_model_to_project_trackers.rb` (create) | Add enum column, backfill from treasury split, drop the decimal column |
| `app/models/project_tracker.rb` (modify) | `enum billing_model`, `#billing_rules`, `#company_treasury_split` |
| `test/models/project_tracker_test.rb` (modify) | Enum + rules tests |
| `app/models/invoice_tracker.rb` (modify, ~:444-520, :586-625) | Read rules instead of literals |
| `app/models/contributor_payout.rb` (modify, ~:208-243) | Threshold/maximum from rules |
| `test/models/contributor_payout_test.rb` (modify) | v2 surplus tests |
| `test/models/invoice_tracker_payouts_test.rb` (create) | End-to-end split on a v2 tracker |
| `app/admin/project_trackers.rb` (modify, :13, :501) | permit + select |
| `app/views/admin/project_trackers/_show.html.erb` (modify, ~:160) | Billing Model row |
| `app/views/admin/invoice_trackers/_invoice_tracker.html.erb` (modify, :331, :357) | Replace 57% literals |

---

### Task 1: `Stacks::BillingModel` registry

**Files:**
- Create: `lib/stacks/billing_model.rb`
- Test: `test/lib/stacks/billing_model_test.rb`

**Interfaces:**
- Produces: `Stacks::BillingModel::Rules` (Struct, keyword_init) with `name`, `treasury_share`, `account_lead_share`, `project_lead_share`, `surplus_lead_share` (all `BigDecimal` except `name`), and methods `ic_ceiling`, `surplus_threshold`, `ic_share(account_lead:, project_lead:)`, `label`. `Stacks::BillingModel::ALL` (frozen Hash of name → Rules), `Stacks::BillingModel::DEFAULT = "new_deal_v1"`, `Stacks::BillingModel.for(name)` (raises `ArgumentError` on unknown), `Stacks::BillingModel.names`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/billing_model_test.rb
require "test_helper"

class StacksBillingModelTest < ActiveSupport::TestCase
  test "new_deal_v1 derives the legacy 57% ceiling and 43% threshold" do
    rules = Stacks::BillingModel.for("new_deal_v1")
    assert_equal BigDecimal("0.30"), rules.treasury_share
    assert_equal BigDecimal("0.08"), rules.account_lead_share
    assert_equal BigDecimal("0.05"), rules.project_lead_share
    assert_equal BigDecimal("0.15"), rules.surplus_lead_share
    assert_equal BigDecimal("0.57"), rules.ic_ceiling
    assert_equal BigDecimal("0.43"), rules.surplus_threshold
  end

  test "new_deal_v2 derives the 54% ceiling and 46% threshold" do
    rules = Stacks::BillingModel.for("new_deal_v2")
    assert_equal BigDecimal("0.33"), rules.treasury_share
    assert_equal BigDecimal("0.54"), rules.ic_ceiling
    assert_equal BigDecimal("0.46"), rules.surplus_threshold
  end

  test "ic_share subtracts only the leads that are present" do
    rules = Stacks::BillingModel.for("new_deal_v2")
    assert_equal BigDecimal("0.54"), rules.ic_share(account_lead: true, project_lead: true)
    assert_equal BigDecimal("0.62"), rules.ic_share(account_lead: false, project_lead: true)
    assert_equal BigDecimal("0.59"), rules.ic_share(account_lead: true, project_lead: false)
    assert_equal BigDecimal("0.67"), rules.ic_share(account_lead: false, project_lead: false)
  end

  test "for raises on an unknown model" do
    assert_raises(ArgumentError) { Stacks::BillingModel.for("old_deal") }
    assert_raises(ArgumentError) { Stacks::BillingModel.for(nil) }
  end

  test "DEFAULT is new_deal_v1 and names lists both models in order" do
    assert_equal "new_deal_v1", Stacks::BillingModel::DEFAULT
    assert_equal %w[new_deal_v1 new_deal_v2], Stacks::BillingModel.names
  end

  test "label is human readable" do
    assert_equal "new_deal_v2 — 33% treasury, 54% IC ceiling", Stacks::BillingModel.for("new_deal_v2").label
  end

  test "registry is frozen" do
    assert Stacks::BillingModel::ALL.frozen?
    assert Stacks::BillingModel.for("new_deal_v1").frozen?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/billing_model_test.rb`
Expected: `7 runs, 0 failures, 7 errors` — every test errors with `NameError: uninitialized constant Stacks::BillingModel` (minitest reports raised exceptions as errors, not failures)

- [ ] **Step 3: Write the registry**

```ruby
# lib/stacks/billing_model.rb
# The payout split rules for a ProjectTracker. One entry per rate card /
# deal structure; ProjectTracker#billing_model names the entry.
#
#   treasury_share      — what the company keeps off a client-work line
#   account_lead_share  — Account Lead's cut of the post-commission line
#   project_lead_share  — Project Lead's cut of the post-commission line
#   surplus_lead_share  — each lead's cut of any surplus on a line
#   ic_ceiling          — 1 - treasury - AL - PL: the IC's maximum share
#   surplus_threshold   — treasury + AL + PL: margin above which surplus exists
#
# Shares are BigDecimal so `1 - treasury_share` is exact. Coerce to Float only
# when writing into a jsonb blueprint.
module Stacks::BillingModel
  Rules = Struct.new(:name, :treasury_share, :account_lead_share, :project_lead_share, :surplus_lead_share, keyword_init: true) do
    def ic_ceiling
      1 - treasury_share - account_lead_share - project_lead_share
    end

    def surplus_threshold
      treasury_share + account_lead_share + project_lead_share
    end

    # The IC's share of a line given which leads are actually assigned this
    # month. Mirrors the inline arithmetic the payout builder used to do.
    def ic_share(account_lead:, project_lead:)
      1 - treasury_share - (account_lead ? account_lead_share : 0) - (project_lead ? project_lead_share : 0)
    end

    def label
      "#{name} — #{(treasury_share * 100).to_i}% treasury, #{(ic_ceiling * 100).to_i}% IC ceiling"
    end
  end

  ALL = {
    "new_deal_v1" => Rules.new(
      name: "new_deal_v1",
      treasury_share: BigDecimal("0.30"),
      account_lead_share: BigDecimal("0.08"),
      project_lead_share: BigDecimal("0.05"),
      surplus_lead_share: BigDecimal("0.15"),
    ).freeze,
    "new_deal_v2" => Rules.new(
      name: "new_deal_v2",
      treasury_share: BigDecimal("0.33"),
      account_lead_share: BigDecimal("0.08"),
      project_lead_share: BigDecimal("0.05"),
      surplus_lead_share: BigDecimal("0.15"),
    ).freeze,
  }.freeze

  DEFAULT = "new_deal_v1".freeze

  def self.for(name)
    ALL.fetch(name.to_s) { raise ArgumentError, "unknown billing model #{name.inspect}" }
  end

  def self.names
    ALL.keys
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/billing_model_test.rb`
Expected: `7 runs, 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD   # must print worktree-feat+contributor-payment-projections
git add lib/stacks/billing_model.rb test/lib/stacks/billing_model_test.rb
git commit -m "feat: Stacks::BillingModel registry of payout split rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 2: `billing_model` column and `ProjectTracker` enum

**Files:**
- Create: `db/migrate/20260909000001_add_billing_model_to_project_trackers.rb`
- Modify: `app/models/project_tracker.rb` (add after the `belongs_to :runn_project` line, ~:41)
- Modify: `db/schema.rb` (regenerated)
- Test: `test/models/project_tracker_test.rb` (append)

**Interfaces:**
- Consumes: `Stacks::BillingModel` (Task 1).
- Produces: `ProjectTracker#billing_model` (string enum: `new_deal_v1?`, `new_deal_v2?`, scopes), `ProjectTracker#billing_rules` → `Stacks::BillingModel::Rules`, `ProjectTracker#company_treasury_split` → `BigDecimal` (now derived). The `project_trackers.company_treasury_split` column no longer exists.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/project_tracker_test.rb` (inside the class, before the final `end`):

```ruby
  test "billing_model defaults to new_deal_v1" do
    pt = ProjectTracker.new(name: "Default model")
    pt.save!(validate: false)
    assert_equal "new_deal_v1", pt.reload.billing_model
    assert pt.new_deal_v1?
  end

  test "billing_rules and company_treasury_split derive from the model" do
    pt = ProjectTracker.new(name: "V2 model", billing_model: "new_deal_v2")
    pt.save!(validate: false)
    assert_equal Stacks::BillingModel.for("new_deal_v2"), pt.billing_rules
    assert_equal BigDecimal("0.33"), pt.company_treasury_split
    assert_equal BigDecimal("0.30"), ProjectTracker.new(name: "V1").company_treasury_split
  end

  test "billing_model rejects unknown values" do
    assert_raises(ArgumentError) { ProjectTracker.new(name: "Bad", billing_model: "old_deal") }
  end

  test "company_treasury_split is no longer a column" do
    assert_not ProjectTracker.column_names.include?("company_treasury_split")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/project_tracker_test.rb`
Expected: 3 errors (`unknown attribute 'billing_model'` / `NoMethodError: undefined method 'billing_model'`) and 1 failure (the `column_names` assertion); the pre-existing tests still pass.

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260909000001_add_billing_model_to_project_trackers.rb
class AddBillingModelToProjectTrackers < ActiveRecord::Migration[6.1]
  def up
    add_column :project_trackers, :billing_model, :string, null: false, default: "new_deal_v1"

    execute <<~SQL
      UPDATE project_trackers SET billing_model = 'new_deal_v1' WHERE company_treasury_split = 0.30;
      UPDATE project_trackers SET billing_model = 'new_deal_v2' WHERE company_treasury_split = 0.33;
    SQL

    unmapped = select_values(<<~SQL)
      SELECT id FROM project_trackers
      WHERE company_treasury_split IS NOT NULL
        AND company_treasury_split NOT IN (0.30, 0.33)
    SQL
    if unmapped.any?
      raise ActiveRecord::MigrationError,
        "project_trackers #{unmapped.join(', ')} have a company_treasury_split that maps to no billing model; " \
        "set them to 0.30 or 0.33 before migrating"
    end

    remove_check_constraint :project_trackers, name: "check_company_treasury_split_range"
    remove_column :project_trackers, :company_treasury_split
  end

  def down
    add_column :project_trackers, :company_treasury_split, :decimal, default: 0.3
    add_check_constraint :project_trackers, "company_treasury_split >= 0 AND company_treasury_split <= 1", name: "check_company_treasury_split_range"
    execute <<~SQL
      UPDATE project_trackers SET company_treasury_split = 0.33 WHERE billing_model = 'new_deal_v2';
      UPDATE project_trackers SET company_treasury_split = 0.30 WHERE billing_model = 'new_deal_v1';
    SQL
    remove_column :project_trackers, :billing_model
  end
end
```

- [ ] **Step 4: Add the enum and methods to `ProjectTracker`**

In `app/models/project_tracker.rb`, directly after the line
`belongs_to :runn_project, class_name: "RunnProject", foreign_key: "runn_project_id", primary_key: "runn_id", optional: true`
insert:

```ruby
  # Which payout split rules apply to this project's client work. The rules
  # themselves live in Stacks::BillingModel; this column only names them.
  enum billing_model: Stacks::BillingModel.names.index_by(&:itself), _default: Stacks::BillingModel::DEFAULT

  def billing_rules
    Stacks::BillingModel.for(billing_model)
  end

  # Kept as a method for the readers that pre-date billing_model
  # (InvoiceTracker#make_contributor_payouts!, admin views). Derived, never stored.
  def company_treasury_split
    billing_rules.treasury_share
  end
```

- [ ] **Step 5: Migrate, curate the schema dump, reload the test schema**

Follow the **Schema procedure** in Global Constraints. The migration must run with no error. The curated `db/schema.rb` diff must show only: the version bump to `2026_09_09_000001`; `t.string "billing_model", default: "new_deal_v1", null: false` under `project_trackers`; and the removal of the `company_treasury_split` line and the `check_company_treasury_split_range` constraint under `project_trackers` (the `invoice_trackers` ones remain).

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/models/project_tracker_test.rb`
Expected: all pass, including the four new tests.

- [ ] **Step 7: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add db/migrate/20260909000001_add_billing_model_to_project_trackers.rb db/schema.rb app/models/project_tracker.rb test/models/project_tracker_test.rb
git commit -m "feat: billing_model enum on ProjectTracker replaces company_treasury_split column

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 3: Surplus calc reads the tracker's rules

**Files:**
- Modify: `app/models/contributor_payout.rb:208-243` (`calculate_surplus`)
- Test: `test/models/contributor_payout_test.rb` (append)

**Interfaces:**
- Consumes: `ProjectTracker#billing_rules` (Task 2).
- Produces: `calculate_surplus` chunks whose `:surplus` uses `rules.surplus_threshold` and whose `:maximum` is `rules.ic_ceiling * working_amount` (Float). A chunk with no resolvable tracker uses `Stacks::BillingModel::DEFAULT`.

- [ ] **Step 1: Write the failing tests**

Append inside `ContributorPayoutTest`:

```ruby
  def surplus_cp_for(tracker, ic_amount:)
    qbo_line = { "id" => "5", "amount" => 1000.0, "description" => "ABC-1 Foo" }
    qbo_invoice = mock("qbo_invoice")
    qbo_invoice.stubs(:line_items).returns([qbo_line])

    invoice_tracker = mock("invoice_tracker")
    invoice_tracker.stubs(:qbo_invoice).returns(qbo_invoice)
    invoice_tracker.stubs(:project_trackers).returns([tracker].compact)
    invoice_tracker.stubs(:commission_total_for_line).with("5").returns(0.0)

    cp = ContributorPayout.new(
      amount: ic_amount,
      blueprint: {
        "IndividualContributor" => [
          { "amount" => ic_amount, "blueprint_metadata" => { "id" => "5", "forecast_project" => 99 } },
        ],
      },
    )
    cp.stubs(:invoice_tracker).returns(invoice_tracker)
    cp.stubs(:contributor).returns(mock("contributor"))
    cp.stubs(:in_sync?).returns(true)
    cp
  end

  def tracker_with_model(model)
    pt = ProjectTracker.new(name: "Surplus #{model}", billing_model: model)
    pt.stubs(:forecast_project_ids).returns([99])
    pt
  end

  test "calculate_surplus on a new_deal_v2 tracker uses the 46% threshold and 54% maximum" do
    # IC paid 540 of 1000 = exactly the v2 ceiling → margin 0.46 → zero surplus
    chunk = surplus_cp_for(tracker_with_model("new_deal_v2"), ic_amount: 540.0).calculate_surplus.first
    assert_in_delta 0.0, chunk[:surplus], 0.001
    assert_in_delta 540.0, chunk[:maximum], 0.001
  end

  test "calculate_surplus on a new_deal_v2 tracker: 57% pay is under the 46% threshold, 40% pay yields (0.60 - 0.46) * 1000" do
    # IC paid 570 (old 57%) → margin 0.43 → below the 0.46 threshold → still no surplus
    chunk = surplus_cp_for(tracker_with_model("new_deal_v2"), ic_amount: 570.0).calculate_surplus.first
    assert_in_delta 0.0, chunk[:surplus], 0.001

    # IC paid 400 → margin 0.60 → (0.60 - 0.46) * 1000 = 140
    chunk = surplus_cp_for(tracker_with_model("new_deal_v2"), ic_amount: 400.0).calculate_surplus.first
    assert_in_delta 140.0, chunk[:surplus], 0.001
  end

  test "calculate_surplus on a new_deal_v1 tracker keeps the 43% threshold and 57% maximum" do
    chunk = surplus_cp_for(tracker_with_model("new_deal_v1"), ic_amount: 400.0).calculate_surplus.first
    # margin 0.60 → (0.60 - 0.43) * 1000 = 170
    assert_in_delta 170.0, chunk[:surplus], 0.001
    assert_in_delta 570.0, chunk[:maximum], 0.001
  end

  test "calculate_surplus falls back to the default model when no tracker resolves" do
    chunk = surplus_cp_for(nil, ic_amount: 400.0).calculate_surplus.first
    assert_nil chunk[:project_tracker]
    assert_in_delta 170.0, chunk[:surplus], 0.001
    assert_in_delta 570.0, chunk[:maximum], 0.001
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/contributor_payout_test.rb`
Expected: the two v2 tests FAIL (surplus 30.0 instead of 0.0 for the 540 case; maximum 570 instead of 540). The v1 and fallback tests pass already.

- [ ] **Step 3: Rewrite `calculate_surplus`**

Replace the body of `calculate_surplus` in `app/models/contributor_payout.rb` (the method starting `def calculate_surplus` through its `end`) with:

```ruby
  def calculate_surplus
    return [] unless in_sync?

    qbo_inv = invoice_tracker.qbo_invoice
    return [] unless qbo_inv.present?

    project_trackers = invoice_tracker.project_trackers
    default_rules = Stacks::BillingModel.for(Stacks::BillingModel::DEFAULT)

    blueprint["IndividualContributor"].map do |ic|
      blueprint_metadata = ic.dig("blueprint_metadata")
      qbo_line_item = qbo_inv.line_items.find{|li| li["id"] == blueprint_metadata.dig("id")} || {}
      amount_paid = ic.dig("amount").try(:to_f) || 0
      amount_billed = qbo_line_item.dig("amount").try(:to_f) || 0

      commission_for_line = invoice_tracker.commission_total_for_line(blueprint_metadata.dig("id"))
      working_amount = amount_billed - commission_for_line

      # The tracker decides the split rules for this line. Resolve it before
      # the surplus math so the threshold and ceiling come from its model.
      project_tracker = project_trackers.find{|pt| pt.forecast_project_ids.include?(blueprint_metadata.dig("forecast_project"))}
      rules = project_tracker&.billing_rules || default_rules

      surplus = 0
      if working_amount > 0
        profit_margin = (working_amount - amount_paid) / working_amount
        surplus = ((profit_margin - rules.surplus_threshold) * working_amount).round(2).to_f
        surplus = 0 if surplus <= 0
      end

      {
        project_tracker: project_tracker,
        contributor: contributor,
        surplus: surplus,
        actual: amount_paid,
        maximum: (rules.ic_ceiling * working_amount).to_f,
        chunk: ic,
        qbo_line_item: qbo_line_item,
        blueprint_metadata: blueprint_metadata,
      }
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/contributor_payout_test.rb`
Expected: all pass (the pre-existing `calculate_surplus uses post-commission working_amount as basis` test still passes: it stubs `project_trackers` as `[]`, so the default v1 rules apply).

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/models/contributor_payout.rb test/models/contributor_payout_test.rb
git commit -m "feat: surplus threshold and ceiling come from the tracker's billing model

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 4: Payout builder reads the tracker's rules

**Files:**
- Modify: `app/models/invoice_tracker.rb` — the per-line loop (~:444-520) and the surplus block (~:586-625)
- Test: `test/models/invoice_tracker_payouts_test.rb` (create)

**Interfaces:**
- Consumes: `ProjectTracker#billing_rules`, `Rules#ic_share`, `Rules#account_lead_share`, `Rules#project_lead_share`, `Rules#surplus_lead_share`.
- Produces: no signature change. Blueprint amounts for a v2 tracker: AL 8%, PL 5%, IC 54%; description lines render the rule's percentage.

- [ ] **Step 1: Write the failing end-to-end test**

```ruby
# test/models/invoice_tracker_payouts_test.rb
require "test_helper"

# Exercises make_contributor_payouts! against real rows with the QBO invoice
# stubbed, so the split percentages can be asserted per billing model.
class InvoiceTrackerPayoutsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @pass = InvoicePass.find_or_create_by!(start_of_month: Date.new(2026, 8, 1)) { |ip| ip.data = {} }
    @client = ForecastClient.create!(forecast_id: 700_001, name: "Payout Split Client")
    @project = ForecastProject.create!(forecast_id: 700_001, client_id: @client.forecast_id, name: "Split Proj", code: "SPL-1", tags: ["200p/h"])

    @ic = ForecastPerson.create!(forecast_id: 700_001, email: "ic-split@example.com", data: {})
    @al_admin = AdminUser.create!(email: "al-split@example.com", password: "password123", password_confirmation: "password123")
    @al = ForecastPerson.create!(forecast_id: 700_002, email: @al_admin.email, data: {})
    @pl_admin = AdminUser.create!(email: "pl-split@example.com", password: "password123", password_confirmation: "password123")
    @pl = ForecastPerson.create!(forecast_id: 700_003, email: @pl_admin.email, data: {})
    @creator = AdminUser.create!(email: "creator-split@example.com", password: "password123", password_confirmation: "password123")
  end

  def build_tracker(model)
    pt = ProjectTracker.new(name: "Split Tracker #{model}", billing_model: model)
    pt.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: @project)
    AccountLeadPeriod.create!(project_tracker: pt, admin_user: @al_admin, started_at: Date.new(2026, 8, 1))
    ProjectLeadPeriod.create!(project_tracker: pt, admin_user: @pl_admin, started_at: Date.new(2026, 8, 1))
    pt
  end

  def build_invoice_tracker
    it = InvoiceTracker.create!(
      forecast_client: @client,
      invoice_pass: @pass,
      qbo_account: qbo_accounts(:one),
      blueprint: {
        "generated_at" => DateTime.now.to_s,
        "lines" => {
          "SPL-1 Split Proj (August 2026) IC [FP-700001]" => {
            "id" => "1",
            "forecast_project" => @project.forecast_id,
            "forecast_person" => @ic.forecast_id,
            "quantity" => 10.0,
            "unit_price" => 200.0,
          },
        },
      },
    )
    qbo_invoice = mock("qbo_invoice")
    qbo_invoice.stubs(:line_items).returns([{ "id" => "1", "amount" => 2000.0, "description" => "SPL-1 Split Proj (August 2026) IC [FP-700001]" }])
    qbo_invoice.stubs(:data).returns({})
    it.stubs(:qbo_invoice).returns(qbo_invoice)
    it
  end

  def amount_for(invoice_tracker, forecast_person)
    invoice_tracker.contributor_payouts.reload.find { |cp| cp.contributor.forecast_person == forecast_person }&.amount&.to_f
  end

  test "a new_deal_v2 tracker pays IC 54%, Account Lead 8%, Project Lead 5%" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)

    assert_in_delta 1080.0, amount_for(it, @ic), 0.01   # 2000 * 0.54
    assert_in_delta 160.0, amount_for(it, @al), 0.01    # 2000 * 0.08
    assert_in_delta 100.0, amount_for(it, @pl), 0.01    # 2000 * 0.05

    ic_cp = it.contributor_payouts.find { |cp| cp.contributor.forecast_person == @ic }
    assert_match(/54\.0%/, ic_cp.blueprint["IndividualContributor"].first["description_line"])
  end

  test "a new_deal_v1 tracker still pays IC 57%" do
    build_tracker("new_deal_v1")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)

    assert_in_delta 1140.0, amount_for(it, @ic), 0.01   # 2000 * 0.57
    assert_in_delta 160.0, amount_for(it, @al), 0.01
    assert_in_delta 100.0, amount_for(it, @pl), 0.01
  end
end
```

- [ ] **Step 2: Run the test to verify the v2 case fails**

Run: `bin/rails test test/models/invoice_tracker_payouts_test.rb`
Expected: both tests already PASS for the amounts, because the existing `ic_share` line reads `pt.company_treasury_split`, which Task 2 made derive from the model. This test therefore pins current behavior; Steps 3-4 replace the remaining AL / PL / surplus literals and description strings without changing these numbers. If the setup itself errors (a validation on `InvoiceTracker` or `ContributorPayout` this plan did not anticipate), fix the test setup rather than the models, and say what you changed in the commit message.

To make the literal replacement itself observable, add this third test before moving on:

```ruby
  test "description lines render the model's lead percentages" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)
    al_cp = it.contributor_payouts.reload.find { |cp| cp.contributor.forecast_person == @al }
    pl_cp = it.contributor_payouts.find { |cp| cp.contributor.forecast_person == @pl }
    assert_match(/\* 8\.0% =/, al_cp.blueprint["AccountLead"].first["description_line"])
    assert_match(/\* 5\.0% =/, pl_cp.blueprint["ProjectLead"].first["description_line"])
  end
```

Run again. Expected: this new test FAILS (`* 8% =` is what the literal strings produce today).

- [ ] **Step 3: Replace the literals in the per-line loop**

In `app/models/invoice_tracker.rb`, inside `make_contributor_payouts!`, find the line
`pt = ptfps.first.project_tracker`
(in the "Handle Client Project" branch, ~:398) and add directly after it:

```ruby
        rules = pt.billing_rules
```

Then make these exact replacements in the same method:

1. `amount = (working_amount * 0.08).round(2)` → `amount = (working_amount * rules.account_lead_share).round(2).to_f`
2. In the AccountLead `description_line` strings, both occurrences of `* 8% =` → `* #{(rules.account_lead_share * 100).round(2)}% =`
3. `amount = (working_amount * 0.05).round(2)` → `amount = (working_amount * rules.project_lead_share).round(2).to_f`
4. In the ProjectLead `description_line` strings, both occurrences of `* 5% =` → `* #{(rules.project_lead_share * 100).round(2)}% =`
5. `ic_share = 1 - pt.company_treasury_split - (account_lead.present? ? 0.08 : 0) - (project_lead.present? ? 0.05 : 0)` → `ic_share = rules.ic_share(account_lead: account_lead.present?, project_lead: project_lead.present?)`
   and update the comment above `amount = (working_amount * ic_share).round(2).to_f` to read `# ic_share is a BigDecimal (the rules are BigDecimal), so coerce the product to Float before it lands in the jsonb blueprint.`

- [ ] **Step 4: Replace the literals in the surplus block**

In the `chunks.each do |c|` block (~:588), replace
`lead_share = (c[:surplus] * 0.15).round(2)`
with
```ruby
        rules = c[:project_tracker].billing_rules
        lead_share = (c[:surplus] * rules.surplus_lead_share).round(2).to_f
        lead_pct = "#{(rules.surplus_lead_share * 100).round(2)}%"
```
and in the two `description_line` strings below it replace `* 15% =` with `* #{lead_pct} =` and `15% of which is shared` with `#{lead_pct} of which is shared`.

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/models/invoice_tracker_payouts_test.rb test/models/invoice_tracker_test.rb test/models/contributor_payout_test.rb`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/models/invoice_tracker.rb test/models/invoice_tracker_payouts_test.rb
git commit -m "feat: payout builder reads lead and surplus shares from the tracker's billing model

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 5: Admin form, show row, and invoice partial

**Files:**
- Modify: `app/admin/project_trackers.rb` (`permit_params` at :13; form input at :501)
- Modify: `app/views/admin/project_trackers/_show.html.erb` (after the "Profit Margin" row, ~:167)
- Modify: `app/views/admin/invoice_trackers/_invoice_tracker.html.erb` (:331 and :357)

**Interfaces:**
- Consumes: `Stacks::BillingModel.names`, `Rules#label`, `ProjectTracker#billing_rules`, `InvoiceTracker#project_trackers`.

- [ ] **Step 1: Permit and select**

In `app/admin/project_trackers.rb`, change the start of `permit_params` from

```ruby
  permit_params :name,
    :budget_low_end,
```
to
```ruby
  permit_params :name,
    :billing_model,
    :budget_low_end,
```

and replace the line
```ruby
        f.input :company_treasury_split, hint: "The percentage of the project's profit that will be allocated to the company treasury. This is used to calculate the project's profit margin."
```
with
```ruby
        f.input :billing_model,
          as: :select,
          collection: Stacks::BillingModel.names.map { |n| [Stacks::BillingModel.for(n).label, n] },
          include_blank: false,
          hint: "Which payout split rules apply to this project's client work. new_deal_v2 is the 2026 rate card (33% treasury / 54% IC ceiling). Existing projects stay on new_deal_v1 until they wrap."
```

- [ ] **Step 2: Show row**

In `app/views/admin/project_trackers/_show.html.erb`, directly after the `</tr>` that closes the "Profit Margin" row (the row containing `<strong>Profit Margin</strong>`), insert:

```erb
            <tr class="odd">
              <td class="col"><strong>Billing Model</strong></td>
              <td class="col text-right">
                <code><%= @project_tracker.billing_rules.label %></code>
              </td>
            </tr>
```

Then fix the alternation of the rows that follow: the next row ("Considered Successful?") was `odd`; change it to `even`, and flip each subsequent `even`/`odd` in that table so the stripes stay alternating. If the table has no further rows after "Considered Successful?", only that one flip is needed.

- [ ] **Step 3: Invoice partial literals**

In `app/views/admin/invoice_trackers/_invoice_tracker.html.erb`, directly above the line `<% surplus = invoice_tracker.surplus(surplus_chunks) %>` insert:

```erb
<%
  ceilings = invoice_tracker.project_trackers.map { |pt| pt.billing_rules.ic_ceiling }.uniq
  ceiling_pct = ((ceilings.max || Stacks::BillingModel.for(Stacks::BillingModel::DEFAULT).ic_ceiling) * 100).round(2)
  ceiling_label = ceilings.size > 1 ? "#{ceiling_pct}% (highest across trackers)" : "#{ceiling_pct}%"
%>
```

Replace `cheaper than <code>57%</code>` with `cheaper than <code><%= ceiling_label %></code>`, and replace `<th class="col">Maximum Payout (57%)</th>` with `<th class="col">Maximum Payout (<%= ceiling_label %>)</th>`.

- [ ] **Step 4: Boot check**

Run: `bin/rails runner 'puts ProjectTracker.first&.billing_rules&.label; puts ActiveAdmin.application.namespaces[:admin].resources["ProjectTracker"].present?'`
Expected: prints a label like `new_deal_v1 — 30% treasury, 57% IC ceiling` and `true`, with no exception. Then render one tracker page and one invoice tracker page in the dev server (`bin/rails s`, visit `/admin/project_trackers/<id>` and `/admin/invoice_trackers/<id>` for any existing ids) and confirm the Billing Model row and the "Maximum Payout (57.0%)" header render.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/admin/project_trackers.rb app/views/admin/project_trackers/_show.html.erb app/views/admin/invoice_trackers/_invoice_tracker.html.erb
git commit -m "feat: billing model select on the tracker form, show row, invoice partial reads the ceiling

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 6: Part 1 regression check

- [ ] **Step 1: Run every test file touched or adjacent**

Run:
```bash
bin/rails test test/lib/stacks/billing_model_test.rb test/models/project_tracker_test.rb test/models/contributor_payout_test.rb test/models/invoice_tracker_test.rb test/models/invoice_tracker_payouts_test.rb test/models/project_tracker_workstream_test.rb test/models/project_tracker_provision_test.rb test/services/mcp/project_cost_breakdown_tool_test.rb test/services/mcp/projects_at_risk_tool_test.rb
```
Expected: `0 failures, 0 errors`.

- [ ] **Step 2: Grep for stragglers**

Run: `grep -rn "company_treasury_split" app lib db/migrate --include='*.rb' --include='*.erb' | grep -v invoice_tracker`
Expected: exactly three sources — `app/models/project_tracker.rb` (the derived method), `db/migrate/20250630223026_add_company_treasury_split_to_project_trackers.rb` (historical, leave it), and `db/migrate/20260909000001_add_billing_model_to_project_trackers.rb` (new). Anything else is a reader the spec missed; convert it to `billing_rules` and add a test.

No commit for this task unless Step 2 found something.
