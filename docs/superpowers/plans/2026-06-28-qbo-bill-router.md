# QBO Bill Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate all QBO bill line-splitting and account-selection logic, currently scattered across six sites, into a single `Qbo::BillRouter` service object driven by per-enterprise GL codes.

**Architecture:** One service object with two internal layers. Layer 1 (routing) is pure: it inspects the ledger item's type/blueprint/studio/internal-client status and emits `(amount, description, concept)` lines with no GL codes or API calls. Layer 2 (resolution) maps `(enterprise, concept) → GL code → concrete account` from the enterprise's chart of accounts, which is fetched once per enterprise per sync session via an in-memory cache.

**Tech Stack:** Ruby on Rails, Minitest + Mocha (`test/`), the `quickbooks-ruby` gem (`Quickbooks::Model::BillLineItem`).

## Global Constraints

- **Test framework is Minitest + Mocha**, not RSpec. Tests live under `test/`, use `require "test_helper"`, subclass `ActiveSupport::TestCase`, and use `mock`/`stubs`/`expects` (Mocha) and `OpenStruct` for fake accounts. Copy the style of `test/services/contributor_payouts/qbo_bill_lines_test.rb`.
- **Behavior must be preserved exactly** versus today's scattered logic, with ONE intentional, user-approved divergence: a missing `:profit_share_liability` account now **raises** instead of silently falling back to the subcontractor account (old `ProfitShare#find_qbo_account!` fell back via `super`).
- **No schema changes, no migration.** All GL codes — including per-studio subcontractor codes — live in the `CONCEPT_GL_BY_ENTERPRISE` Ruby constant.
- **Enterprise name constants** (verbatim): `Enterprise::SANCTUARY_NAME == "Sanctuary Computer Inc"`, `Enterprise::GARDEN3D_NAME == "garden3d, LLC"`.
- **Studio enum:** `studio_type` → `client_services: 0, internal: 1, reinvestment: 2, collective: 3`, giving the predicate `studio.client_services?`.
- **Run tests with:** `bin/rails test test/path/to/file_test.rb` (single file) or `bin/rails test test/path/to/file_test.rb -n test_name_regex`.
- **GL code values for `bonuses` (5710), `commission` (6120), `profit_share_liability` (2340) are known and real.** All other GL codes (`subcontractor_default`, `marketing`, `salaries`, and every per-studio code) are placeholders until Task 9 fills them from live data. Tests never depend on the real constant — they stub the `enterprise_gl_map` seam.

---

## File Structure

- **Create** `app/services/qbo/accounts_cache.rb` — `Qbo::AccountsCache`, memoizes `qbo_account.fetch_all_accounts` per `qbo_account.id`.
- **Create** `app/services/qbo/bill_router.rb` — `Qbo::BillRouter`, the one object: constant + routing layer + resolution layer.
- **Create** `test/services/qbo/accounts_cache_test.rb`
- **Create** `test/services/qbo/bill_router_test.rb`
- **Modify** `app/models/concerns/syncs_as_qbo_bill.rb` — `sync_qbo_bill!` uses the router; delete `find_qbo_account!` and `bill_line_items`.
- **Modify** `app/models/contributor_payout.rb` — delete `find_qbo_account!` and `bill_line_items`.
- **Modify** `app/models/profit_share.rb` — delete `find_qbo_account!` and `PROFIT_SHARE_LIABILITY_ACCT_NUM`.
- **Modify** `app/models/pay_stub.rb` — delete `find_qbo_account!`.
- **Modify** `app/models/studio.rb` — delete `qbo_subcontractors_categories`.
- **Modify** `app/models/contributor.rb` — `sync_qbo_bills!` builds one cache and threads it.
- **Modify** `lib/tasks/stacks.rake` — `sync_contributor_qbo_bills` builds one cache and threads it.
- **Delete** `app/services/contributor_payouts/qbo_bill_lines.rb` and `test/services/contributor_payouts/qbo_bill_lines_test.rb` (ported into the router test).
- **Modify/replace** `test/models/profit_share_test.rb`, `test/models/contributor_payout_test.rb`, `test/models/concerns/syncs_as_qbo_bill_test.rb` — remove tests for deleted methods.

---

### Task 1: `Qbo::AccountsCache`

**Files:**
- Create: `app/services/qbo/accounts_cache.rb`
- Test: `test/services/qbo/accounts_cache_test.rb`

**Interfaces:**
- Produces: `Qbo::AccountsCache.new`; `#accounts_for(qbo_account) -> Array` — returns `qbo_account.fetch_all_accounts`, memoized per `qbo_account.id` so repeated calls for the same account do not re-fetch.

- [ ] **Step 1: Write the failing test**

Create `test/services/qbo/accounts_cache_test.rb`:

```ruby
require "test_helper"
require "ostruct"

class Qbo::AccountsCacheTest < ActiveSupport::TestCase
  test "fetches accounts once per qbo_account and memoizes by id" do
    accounts = [OpenStruct.new(name: "A", acct_num: "1")]
    qa = mock("qbo_account")
    qa.stubs(:id).returns(7)
    qa.expects(:fetch_all_accounts).once.returns(accounts)

    cache = Qbo::AccountsCache.new
    assert_same accounts, cache.accounts_for(qa)
    assert_same accounts, cache.accounts_for(qa) # second call: no second fetch
  end

  test "fetches separately for different qbo_accounts" do
    a1 = [OpenStruct.new(name: "A")]
    a2 = [OpenStruct.new(name: "B")]
    qa1 = mock("qa1"); qa1.stubs(:id).returns(1); qa1.expects(:fetch_all_accounts).once.returns(a1)
    qa2 = mock("qa2"); qa2.stubs(:id).returns(2); qa2.expects(:fetch_all_accounts).once.returns(a2)

    cache = Qbo::AccountsCache.new
    assert_same a1, cache.accounts_for(qa1)
    assert_same a2, cache.accounts_for(qa2)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/qbo/accounts_cache_test.rb`
Expected: FAIL with `uninitialized constant Qbo::AccountsCache`.

- [ ] **Step 3: Write minimal implementation**

Create `app/services/qbo/accounts_cache.rb`:

```ruby
module Qbo
  # In-memory cache of each QboAccount's chart of accounts for the duration of a
  # bill-sync session. Created once at the top of a sync run and threaded into
  # every Qbo::BillRouter so the chart is fetched once per enterprise, not once
  # per bill.
  class AccountsCache
    def initialize
      @by_account_id = {}
    end

    def accounts_for(qbo_account)
      @by_account_id[qbo_account.id] ||= qbo_account.fetch_all_accounts
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/qbo/accounts_cache_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/services/qbo/accounts_cache.rb test/services/qbo/accounts_cache_test.rb
git commit -m "Add Qbo::AccountsCache for per-session chart-of-accounts caching"
```

---

### Task 2: `Qbo::BillRouter` resolution layer

Build the class skeleton, the `CONCEPT_GL_BY_ENTERPRISE` constant (with placeholder codes), and the resolution layer (`#resolve`, with the fallback chain and raise behavior). Routing comes in Tasks 3–5.

**Files:**
- Create: `app/services/qbo/bill_router.rb`
- Test: `test/services/qbo/bill_router_test.rb`

**Interfaces:**
- Consumes: `Qbo::AccountsCache#accounts_for` (Task 1).
- Produces:
  - `Qbo::BillRouter.new(item, accounts_cache:)` — lazy; derives nothing on init.
  - `#resolve(concept) -> account` — finds the account whose `acct_num` matches the concept's GL code in the enterprise's cached chart; falls back to `:subcontractor_default` for `:subcontractor`/`:bonuses`/`:commission`; raises otherwise.
  - Private stubbable seams used by tests: `#enterprise_gl_map -> Hash`, `#studio -> Studio|nil`, `#accounts -> Array`, `#enterprise`, `#qbo_account`.
  - `FALLBACKABLE_CONCEPTS = %i[subcontractor bonuses commission]`.

- [ ] **Step 1: Write the failing test**

Create `test/services/qbo/bill_router_test.rb`:

```ruby
require "test_helper"
require "ostruct"

class Qbo::BillRouterTest < ActiveSupport::TestCase
  # A router whose context (gl map, studio, accounts) is fully stubbed so these
  # tests never touch the DB or the real CONCEPT_GL_BY_ENTERPRISE constant.
  def router_with(accounts:, gl_map:, studio: nil, item: nil)
    r = Qbo::BillRouter.new(item || Object.new, accounts_cache: Qbo::AccountsCache.new)
    r.stubs(:accounts).returns(accounts)
    r.stubs(:enterprise_gl_map).returns(gl_map)
    r.stubs(:studio).returns(studio)
    r.stubs(:enterprise).returns(OpenStruct.new(name: "Test Enterprise"))
    r
  end

  def acct(num, id)
    OpenStruct.new(acct_num: num, id: id, name: "Acct #{num}")
  end

  test "resolve finds the account whose acct_num matches the concept's GL code" do
    gl_map = { bonuses: "5710", subcontractor_default: "5000" }
    accounts = [acct("5710", 5710), acct("5000", 5000)]
    r = router_with(accounts: accounts, gl_map: gl_map)
    assert_equal 5710, r.resolve(:bonuses).id
  end

  test "resolve falls back to subcontractor_default for a missing fallbackable concept" do
    gl_map = { bonuses: "5710", subcontractor_default: "5000" }
    accounts = [acct("5000", 5000)] # 5710 absent
    r = router_with(accounts: accounts, gl_map: gl_map)
    assert_equal 5000, r.resolve(:bonuses).id, "missing bonuses falls back to default"
  end

  test "resolve resolves :subcontractor via the studio's GL code" do
    studio = OpenStruct.new(name: "Bakery")
    gl_map = { subcontractor_default: "5000", subcontractor_by_studio: { "Bakery" => "5010" } }
    accounts = [acct("5000", 5000), acct("5010", 5010)]
    r = router_with(accounts: accounts, gl_map: gl_map, studio: studio)
    assert_equal 5010, r.resolve(:subcontractor).id
  end

  test "resolve :subcontractor falls back to default when studio has no GL entry" do
    studio = OpenStruct.new(name: "Unknown Studio")
    gl_map = { subcontractor_default: "5000", subcontractor_by_studio: {} }
    accounts = [acct("5000", 5000)]
    r = router_with(accounts: accounts, gl_map: gl_map, studio: studio)
    assert_equal 5000, r.resolve(:subcontractor).id
  end

  test "resolve raises when subcontractor_default itself is missing" do
    gl_map = { subcontractor_default: "5000" }
    accounts = [] # nothing
    r = router_with(accounts: accounts, gl_map: gl_map)
    err = assert_raises(RuntimeError) { r.resolve(:subcontractor_default) }
    assert_match(/subcontractor_default/, err.message)
  end

  test "resolve raises when a non-fallbackable concept (salaries) is missing" do
    gl_map = { salaries: "1500", subcontractor_default: "5000" }
    accounts = [acct("5000", 5000)] # 1500 absent
    r = router_with(accounts: accounts, gl_map: gl_map)
    err = assert_raises(RuntimeError) { r.resolve(:salaries) }
    assert_match(/salaries/, err.message)
    assert_match(/1500/, err.message)
  end

  test "resolve raises when profit_share_liability is missing (no silent fallback)" do
    gl_map = { profit_share_liability: "2340", subcontractor_default: "5000" }
    accounts = [acct("5000", 5000)] # 2340 absent
    r = router_with(accounts: accounts, gl_map: gl_map)
    assert_raises(RuntimeError) { r.resolve(:profit_share_liability) }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/qbo/bill_router_test.rb`
Expected: FAIL with `uninitialized constant Qbo::BillRouter`.

- [ ] **Step 3: Write minimal implementation**

Create `app/services/qbo/bill_router.rb`:

```ruby
module Qbo
  # The single source of truth for "given this ledger item, what QBO bill lines
  # does it become, and which account does each line land in?"
  #
  #   Qbo::BillRouter.new(item, accounts_cache: cache).lines
  #   # => [ { amount:, description:, account: }, ... ]
  #
  # Two internal layers:
  #   1. Routing  (#concept_lines)  — pure: item -> [{amount, description, concept}]
  #   2. Resolution (#resolve)      — concept -> concrete QBO account by GL code
  class BillRouter
    # Concepts whose missing account falls back to :subcontractor_default rather
    # than raising. Everything else (subcontractor_default, marketing, salaries,
    # profit_share_liability) raises when absent — silently misrouting payroll or
    # a liability is worse than failing the sync.
    FALLBACKABLE_CONCEPTS = %i[subcontractor bonuses commission].freeze

    # Stable enterprise key -> concept -> GL code. The known real codes are
    # bonuses (5710), commission (6120), profit_share_liability (2340). All "____"
    # entries are placeholders filled from live data in Task 9. Per-studio
    # subcontractor codes are nested under :subcontractor_by_studio.
    CONCEPT_GL_BY_ENTERPRISE = {
      sanctuary: {
        subcontractor_default:  "____",
        marketing:              "____",
        salaries:               "____",
        bonuses:                "5710",
        commission:             "6120",
        profit_share_liability: "2340",
        subcontractor_by_studio: {
          # "<studio name>" => "<gl code>",
        },
      },
      garden3d: {
        subcontractor_default:  "____",
        marketing:              "____",
        salaries:               "____",
        bonuses:                "____",
        commission:             "____",
        profit_share_liability: "____",
        subcontractor_by_studio: {
          # garden3d routes all subcontractors to one account today.
        },
      },
    }.freeze

    ENTERPRISE_KEY_BY_NAME = {
      Enterprise::SANCTUARY_NAME => :sanctuary,
      Enterprise::GARDEN3D_NAME  => :garden3d,
    }.freeze

    def initialize(item, accounts_cache:)
      @item = item
      @accounts_cache = accounts_cache
    end

    def resolve(concept)
      gl = gl_code_for(concept)
      account = gl && find_account(gl)
      return account if account

      if FALLBACKABLE_CONCEPTS.include?(concept)
        fallback = find_account(gl_code_for(:subcontractor_default))
        return fallback if fallback
      end

      raise "Qbo::BillRouter: no account for concept #{concept.inspect} " \
            "(gl #{gl.inspect}) in enterprise #{enterprise.name.inspect}"
    end

    private

    attr_reader :item

    def gl_code_for(concept)
      if concept == :subcontractor
        studio && enterprise_gl_map[:subcontractor_by_studio]&.fetch(studio.name, nil)
      else
        enterprise_gl_map[concept]
      end
    end

    def find_account(gl)
      return nil if gl.nil?
      accounts.find { |a| a.respond_to?(:acct_num) && a.acct_num == gl }
    end

    def accounts
      @accounts ||= @accounts_cache.accounts_for(qbo_account)
    end

    def enterprise_gl_map
      key = ENTERPRISE_KEY_BY_NAME[enterprise.name]
      raise "Qbo::BillRouter: unknown enterprise #{enterprise.name.inspect}" if key.nil?
      CONCEPT_GL_BY_ENTERPRISE.fetch(key)
    end

    def ledger
      item.ledger
    end

    def enterprise
      ledger.enterprise
    end

    def contributor
      ledger.contributor
    end

    def qbo_account
      enterprise.qbo_account
    end

    def studio
      contributor&.forecast_person&.studio
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/qbo/bill_router_test.rb`
Expected: PASS (7 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/services/qbo/bill_router.rb test/services/qbo/bill_router_test.rb
git commit -m "Add Qbo::BillRouter resolution layer (concept -> account by GL code)"
```

---

### Task 3: Routing layer for single-line items

Add `#concept_lines` (public) plus the single-line item dispatch: `PayStub → :salaries`, `ProfitShare → :profit_share_liability`, and the default (`Trueup`, `ContributorAdjustment`) `→ :subcontractor`.

**Files:**
- Modify: `app/services/qbo/bill_router.rb`
- Test: `test/services/qbo/bill_router_test.rb`

**Interfaces:**
- Produces: `#concept_lines -> Array<{amount:, description:, concept:}>`. Dispatches on `item.class`. For non-payout items it returns a single line `{ amount: item.amount, description: item.bill_description, concept: <type concept> }`.

- [ ] **Step 1: Write the failing test**

Append to `test/services/qbo/bill_router_test.rb` (inside the class):

```ruby
  # --- routing: single-line items ---

  def line_item_stub(klass, amount:, description:)
    m = mock(klass.name)
    m.stubs(:is_a?).returns(false)
    m.stubs(:is_a?).with(klass).returns(true)
    m.stubs(:amount).returns(amount)
    m.stubs(:bill_description).returns(description)
    m
  end

  def router_for_routing(item)
    Qbo::BillRouter.new(item, accounts_cache: Qbo::AccountsCache.new)
  end

  test "PayStub routes to a single :salaries line" do
    item = line_item_stub(PayStub, amount: 1000.0, description: "stub-url")
    lines = router_for_routing(item).concept_lines
    assert_equal [{ amount: 1000.0, description: "stub-url", concept: :salaries }], lines
  end

  test "ProfitShare routes to a single :profit_share_liability line" do
    item = line_item_stub(ProfitShare, amount: 250.0, description: "ps-url")
    lines = router_for_routing(item).concept_lines
    assert_equal [{ amount: 250.0, description: "ps-url", concept: :profit_share_liability }], lines
  end

  test "Trueup routes to a single :subcontractor line" do
    item = line_item_stub(Trueup, amount: 42.0, description: "tu-url")
    lines = router_for_routing(item).concept_lines
    assert_equal [{ amount: 42.0, description: "tu-url", concept: :subcontractor }], lines
  end

  test "ContributorAdjustment routes to a single :subcontractor line" do
    item = line_item_stub(ContributorAdjustment, amount: 15.0, description: "ca-url")
    lines = router_for_routing(item).concept_lines
    assert_equal [{ amount: 15.0, description: "ca-url", concept: :subcontractor }], lines
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/qbo/bill_router_test.rb -n "/PayStub routes/"`
Expected: FAIL with `NoMethodError: undefined method 'concept_lines'`.

- [ ] **Step 3: Write minimal implementation**

In `app/services/qbo/bill_router.rb`, add a public `#concept_lines` (place it directly after `#resolve`, before `private`):

```ruby
    def concept_lines
      case item
      when PayStub
        [single_line(:salaries)]
      when ProfitShare
        [single_line(:profit_share_liability)]
      when ContributorPayout
        payout_concept_lines
      else # Trueup, ContributorAdjustment
        [single_line(:subcontractor)]
      end
    end
```

And add these private helpers (anywhere in the `private` section):

```ruby
    def single_line(concept)
      { amount: item.amount, description: item.bill_description, concept: concept }
    end
```

> `payout_concept_lines` is implemented in Task 4. To keep this task's suite green, add a temporary stub now and replace it in Task 4:

```ruby
    def payout_concept_lines
      [single_line(:subcontractor)] # replaced in Task 4
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/qbo/bill_router_test.rb`
Expected: PASS (11 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/services/qbo/bill_router.rb test/services/qbo/bill_router_test.rb
git commit -m "Add Qbo::BillRouter routing for single-line bill types"
```

---

### Task 4: Routing layer for `ContributorPayout` multi-line (port `QboBillLines`)

Port the full bucket-splitting logic from `ContributorPayouts::QboBillLines` into `#payout_concept_lines`, emitting concept-tagged lines. This is the largest task. Tests assert concepts, amounts, and descriptions — no accounts.

**Files:**
- Modify: `app/services/qbo/bill_router.rb`
- Test: `test/services/qbo/bill_router_test.rb`

**Interfaces:**
- Consumes (from `item`, a `ContributorPayout`): `#in_sync? -> Boolean`, `#blueprint -> Hash`, `#amount -> Numeric`, `#bill_description -> String`.
- Consumes (router context, stubbable in tests): `#base_concept -> Symbol` (`:subcontractor` or `:marketing`) — full impl in Task 5; for this task it returns `:subcontractor`.
- Produces: `#payout_concept_lines -> Array<{amount:, description:, concept:}>`. Buckets: `individual_contributor`, `account_lead_base`, `project_lead_base` → `base_concept`; `account_lead_surplus`, `project_lead_surplus` → `:bonuses`; `commission` → `:commission`. Collapses to a single `base_concept` line at `item.amount` when `!in_sync?`, when no non-zero buckets, or when bucket sums drift from `item.amount`.

- [ ] **Step 1: Write the failing tests**

Append to `test/services/qbo/bill_router_test.rb` (inside the class). These are the `QboBillLines` cases re-expressed against the router's concept output:

```ruby
  # --- routing: ContributorPayout multi-line (ported from QboBillLinesTest) ---

  # cp mock with the payout-routing surface; base_concept is stubbed on the
  # router so these tests are independent of the internal-client logic (Task 5).
  def make_cp(blueprint:, amount:, in_sync: true)
    cp = mock("contributor_payout")
    cp.stubs(:is_a?).returns(false)
    cp.stubs(:is_a?).with(ContributorPayout).returns(true)
    cp.stubs(:in_sync?).returns(in_sync)
    cp.stubs(:blueprint).returns(blueprint)
    cp.stubs(:amount).returns(amount)
    cp.stubs(:bill_description).returns("https://example.com/cp/42")
    cp
  end

  def payout_router(cp, base_concept: :subcontractor)
    r = Qbo::BillRouter.new(cp, accounts_cache: Qbo::AccountsCache.new)
    r.stubs(:base_concept).returns(base_concept)
    r
  end

  def all_buckets_blueprint
    {
      "IndividualContributor" => [{ "amount" => 100.0, "description_line" => "- IC line" }],
      "AccountLead"           => [
        { "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8 base" },
        { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
      "ProjectLead"           => [
        { "amount" => 5.0, "description_line" => "- 100hrs * 5% = $5 base" },
        { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
      "Commission"            => [{ "amount" => 10.0, "description_line" => "- 5% of $200 = $10" }],
    }
  end

  test "multi-line happy path: 6 buckets with correct concepts" do
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 129.0)
    lines = payout_router(cp).concept_lines

    assert_equal 6, lines.size
    by_concept = lines.group_by { |l| l[:concept] }
    assert_equal 1, by_concept[:commission].size
    assert_equal 10.0, by_concept[:commission].first[:amount]
    assert_equal 2, by_concept[:bonuses].size, "AL + PL surplus both -> :bonuses"
    assert_equal 3, by_concept[:subcontractor].size, "IC + AL base + PL base -> base concept"
    assert_equal 129.0, lines.sum { |l| l[:amount] }.round(2)
  end

  test "Account Lead split into base/surplus by 'surplus revenue' marker" do
    blueprint = { "AccountLead" => [
      { "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8" },
      { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
    ] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 11.0)).concept_lines

    base    = lines.find { |l| l[:description].include?("Account Lead\n") }
    surplus = lines.find { |l| l[:description].include?("Account Lead Surplus") }
    assert_equal [8.0, :subcontractor], [base[:amount], base[:concept]]
    assert_equal [3.0, :bonuses], [surplus[:amount], surplus[:concept]]
  end

  test "Project Lead split into base/surplus by marker" do
    blueprint = { "ProjectLead" => [
      { "amount" => 5.0, "description_line" => "- 100hrs * 5% = $5" },
      { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
    ] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 8.0)).concept_lines

    surplus = lines.find { |l| l[:description].include?("Project Lead Surplus") }
    assert_equal [3.0, :bonuses], [surplus[:amount], surplus[:concept]]
  end

  test "zero-amount bucket is skipped" do
    blueprint = {
      "IndividualContributor" => [{ "amount" => 100.0, "description_line" => "-" }],
      "Commission"            => [],
    }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 100.0)).concept_lines
    assert_equal 1, lines.size
    assert_equal 100.0, lines.first[:amount]
  end

  test "not in_sync? -> single collapsed line at base concept and cp.amount" do
    blueprint = { "IndividualContributor" => [{ "amount" => 200.0, "description_line" => "-" }] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 100.0, in_sync: false)).concept_lines
    assert_equal 1, lines.size
    assert_equal 100.0, lines.first[:amount]
    assert_equal "https://example.com/cp/42", lines.first[:description]
    assert_equal :subcontractor, lines.first[:concept]
  end

  test "per-bucket drift from cp.amount -> collapse + WARN" do
    blueprint = { "IndividualContributor" => [{ "amount" => 105.0, "description_line" => "-" }] }
    Rails.logger.expects(:warn).at_least_once
    lines = payout_router(make_cp(blueprint: blueprint, amount: 100.0)).concept_lines
    assert_equal 1, lines.size
    assert_equal 100.0, lines.first[:amount]
  end

  test "every bucket empty -> collapse to single line" do
    blueprint = { "IndividualContributor" => [] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 0.0)).concept_lines
    assert_equal 1, lines.size
    assert_equal 0.0, lines.first[:amount]
  end

  test "structured AccountLeadSurplus key routes to :bonuses without marker" do
    blueprint = {
      "AccountLead"        => [{ "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8" }],
      "AccountLeadSurplus" => [{ "amount" => 3.0, "description_line" => "- marker-free copy" }],
    }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 11.0)).concept_lines
    surplus = lines.find { |l| l[:description].include?("Account Lead Surplus") }
    assert_equal [3.0, :bonuses], [surplus[:amount], surplus[:concept]]
  end

  test "structured ProjectLeadSurplus key routes to :bonuses" do
    blueprint = {
      "ProjectLead"        => [{ "amount" => 5.0, "description_line" => "- 100hrs * 5% = $5" }],
      "ProjectLeadSurplus" => [{ "amount" => 3.0, "description_line" => "- marker-free copy" }],
    }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 8.0)).concept_lines
    surplus = lines.find { |l| l[:description].include?("Project Lead Surplus") }
    assert_equal [3.0, :bonuses], [surplus[:amount], surplus[:concept]]
  end

  test "mixed structured + legacy AccountLead surplus entries are summed" do
    blueprint = {
      "AccountLead"        => [
        { "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8 base" },
        { "amount" => 2.0, "description_line" => "- legacy surplus revenue share = $2" },
      ],
      "AccountLeadSurplus" => [{ "amount" => 3.0, "description_line" => "- marker-free copy" }],
    }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 13.0)).concept_lines
    surplus = lines.find { |l| l[:description].include?("Account Lead Surplus") }
    assert_equal 5.0, surplus[:amount], "structured $3 + parsed legacy $2"
    base = lines.find { |l| l[:description].include?("Account Lead\n") }
    assert_equal 8.0, base[:amount]
  end

  test "description format: role header + entry lines + admin URL" do
    blueprint = { "Commission" => [
      { "amount" => 10.0, "description_line" => "- 5% of $200 = $10" },
      { "amount" => 5.0,  "description_line" => "- 5% of $100 = $5" },
    ] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 15.0)).concept_lines
    desc = lines.first[:description]
    assert_match(/\A# Commission\n/, desc)
    assert_includes desc, "- 5% of $200 = $10"
    assert_includes desc, "- 5% of $100 = $5"
    assert_includes desc, "https://example.com/cp/42"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/qbo/bill_router_test.rb -n "/multi-line happy path/"`
Expected: FAIL (the temporary stub returns a single `:subcontractor` line, so `assert_equal 6, lines.size` fails).

- [ ] **Step 3: Write the implementation**

In `app/services/qbo/bill_router.rb`, add the ported constants near the top of the class (after `ENTERPRISE_KEY_BY_NAME`):

```ruby
    ROLE_LABEL_BY_BUCKET = {
      individual_contributor: "Individual Contributor",
      account_lead_base:      "Account Lead",
      account_lead_surplus:   "Account Lead Surplus",
      project_lead_base:      "Project Lead",
      project_lead_surplus:   "Project Lead Surplus",
      commission:             "Commission",
    }.freeze

    SURPLUS_DESCRIPTION_MARKER = "surplus revenue".freeze
```

Replace the temporary `payout_concept_lines` stub (from Task 3) with the full implementation, and add its helpers, in the `private` section:

```ruby
    def payout_concept_lines
      return [collapsed_payout_line] unless item.in_sync?

      buckets = bucket_blueprint(item.blueprint || {})

      lines = ROLE_LABEL_BY_BUCKET.keys.each_with_object([]) do |bucket, acc|
        entries = buckets[bucket]
        next if entries.blank?

        amount = entries.sum { |e| e["amount"].to_f }.round(2)
        next if amount.zero?

        acc << {
          amount: amount,
          description: build_bucket_description(bucket, entries),
          concept: concept_for_bucket(bucket),
        }
      end

      return [collapsed_payout_line] if lines.empty?

      if lines.sum { |l| l[:amount] }.round(2) != item.amount.to_f.round(2)
        Rails.logger.warn(
          "Qbo::BillRouter: per-bucket sums drifted from cp.amount " \
          "(cp_id=#{item.id}, cp.amount=#{item.amount}, " \
          "bucket_sum=#{lines.sum { |l| l[:amount] }}); falling back to single-line bill"
        )
        return [collapsed_payout_line]
      end

      lines
    end

    def collapsed_payout_line
      { amount: item.amount, description: item.bill_description, concept: base_concept }
    end

    def concept_for_bucket(bucket)
      case bucket
      when :account_lead_surplus, :project_lead_surplus then :bonuses
      when :commission then :commission
      else base_concept
      end
    end

    # base_concept is :subcontractor here; Task 5 adds the internal-client
    # :marketing override.
    def base_concept
      :subcontractor
    end

    def bucket_blueprint(blueprint)
      buckets = ROLE_LABEL_BY_BUCKET.keys.each_with_object({}) { |k, h| h[k] = [] }

      Array(blueprint["IndividualContributor"]).each { |e| buckets[:individual_contributor] << e }
      Array(blueprint["Commission"]).each            { |e| buckets[:commission] << e }
      Array(blueprint["AccountLeadSurplus"]).each    { |e| buckets[:account_lead_surplus] << e }
      Array(blueprint["ProjectLeadSurplus"]).each    { |e| buckets[:project_lead_surplus] << e }

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

    def build_bucket_description(bucket, entries)
      role_header = "# #{ROLE_LABEL_BY_BUCKET.fetch(bucket)}"
      entry_lines = entries.map { |e| e["description_line"].to_s }
      ([role_header] + entry_lines + [item.bill_description]).join("\n")
    end
```

> Note: `collapsed_payout_line` calls `item.id` only inside the WARN string; the `make_cp` mock must respond to `id`. Add `cp.stubs(:id).returns(42)` to `make_cp` if a drift test raises an unexpected-invocation error.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/qbo/bill_router_test.rb`
Expected: PASS (all routing + resolution tests green).

- [ ] **Step 5: Commit**

```bash
git add app/services/qbo/bill_router.rb test/services/qbo/bill_router_test.rb
git commit -m "Port QboBillLines bucket-splitting into Qbo::BillRouter routing layer"
```

---

### Task 5: Internal-client `:marketing` override + `#lines`

Implement the real `#base_concept` (internal-client → `:marketing`, with the non-client-services-studio exception) and the public `#lines` that joins routing to resolution.

**Files:**
- Modify: `app/services/qbo/bill_router.rb`
- Test: `test/services/qbo/bill_router_test.rb`

**Interfaces:**
- Consumes (router context, stubbable): `#internal_client? -> Boolean`, `#studio -> Studio|nil`.
- Produces:
  - `#base_concept` — `:subcontractor` unless `internal_client?`; when internal, `:marketing` unless the studio is present and **not** `client_services?` (then `:subcontractor`).
  - `#lines -> Array<{amount:, description:, account:}>` — maps each `concept_lines` entry through `#resolve`.

- [ ] **Step 1: Write the failing tests**

Append to `test/services/qbo/bill_router_test.rb` (inside the class):

```ruby
  # --- base_concept (internal-client marketing override) ---

  def base_concept_router(internal:, studio:)
    r = Qbo::BillRouter.new(Object.new, accounts_cache: Qbo::AccountsCache.new)
    r.stubs(:internal_client?).returns(internal)
    r.stubs(:studio).returns(studio)
    r
  end

  test "base_concept is :subcontractor for a non-internal client" do
    r = base_concept_router(internal: false, studio: nil)
    assert_equal :subcontractor, r.send(:base_concept)
  end

  test "base_concept is :marketing for an internal client with no studio" do
    r = base_concept_router(internal: true, studio: nil)
    assert_equal :marketing, r.send(:base_concept)
  end

  test "base_concept is :marketing for an internal client on a client-services studio" do
    studio = OpenStruct.new(name: "CS", client_services?: true)
    r = base_concept_router(internal: true, studio: studio)
    assert_equal :marketing, r.send(:base_concept)
  end

  test "base_concept stays :subcontractor for an internal client on a NON-client-services studio" do
    studio = OpenStruct.new(name: "Internal Studio", client_services?: false)
    r = base_concept_router(internal: true, studio: studio)
    assert_equal :subcontractor, r.send(:base_concept)
  end

  # --- #lines joins routing to resolution ---

  test "#lines resolves each concept line to a concrete account" do
    item = line_item_stub(Trueup, amount: 42.0, description: "tu-url")
    r = Qbo::BillRouter.new(item, accounts_cache: Qbo::AccountsCache.new)
    r.stubs(:studio).returns(nil)
    default = acct("5000", 5000)
    r.stubs(:accounts).returns([default])
    r.stubs(:enterprise).returns(OpenStruct.new(name: "Test Enterprise"))
    r.stubs(:enterprise_gl_map).returns({ subcontractor_default: "5000" })

    lines = r.lines
    assert_equal 1, lines.size
    assert_equal 42.0, lines.first[:amount]
    assert_equal "tu-url", lines.first[:description]
    assert_same default, lines.first[:account]
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/qbo/bill_router_test.rb -n "/base_concept is :marketing for an internal client with no studio/"`
Expected: FAIL (current `base_concept` always returns `:subcontractor`).

- [ ] **Step 3: Write the implementation**

In `app/services/qbo/bill_router.rb`, replace the placeholder `base_concept` (from Task 4) with:

```ruby
    def base_concept
      return :subcontractor unless internal_client?

      # Internal client → marketing, except when the contributor sits on a
      # non-client-services studio (then the studio's own cost account applies).
      if studio.nil? || studio.client_services?
        :marketing
      else
        :subcontractor
      end
    end

    def internal_client?
      item.respond_to?(:invoice_tracker) &&
        item.invoice_tracker.forecast_client.is_internal?
    end
```

Add the public `#lines` directly after `#concept_lines` (before `private`):

```ruby
    def lines
      concept_lines.map do |line|
        {
          amount: line[:amount],
          description: line[:description],
          account: resolve(line[:concept]),
        }
      end
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/qbo/bill_router_test.rb`
Expected: PASS (all router tests green).

- [ ] **Step 5: Commit**

```bash
git add app/services/qbo/bill_router.rb test/services/qbo/bill_router_test.rb
git commit -m "Add internal-client marketing override and #lines to Qbo::BillRouter"
```

---

### Task 6: Wire `sync_qbo_bill!` to the router and thread the session cache

Replace `find_qbo_account!` + `bill_line_items` + the inline `fetch_all_accounts` in `SyncsAsQboBill#sync_qbo_bill!` with the router, accepting an optional `accounts_cache:`. Thread one shared cache through `Contributor#sync_qbo_bills!` and the rake loop.

**Files:**
- Modify: `app/models/concerns/syncs_as_qbo_bill.rb:104` (`sync_qbo_bill!`)
- Modify: `app/models/contributor.rb:260` (`sync_qbo_bills!`)
- Modify: `lib/tasks/stacks.rake:395` (`sync_contributor_qbo_bills`)
- Test: `test/services/qbo/bill_router_test.rb` (cache-sharing assertion)

**Interfaces:**
- Consumes: `Qbo::BillRouter#lines`, `Qbo::AccountsCache.new`.
- Produces: `SyncsAsQboBill#sync_qbo_bill!(accounts_cache: nil)` — unchanged behavior except line building now comes from the router; a nil cache is lazily created per call.

- [ ] **Step 1: Write the failing test**

Append to `test/services/qbo/bill_router_test.rb` (inside the class):

```ruby
  test "two routers sharing one cache fetch the chart of accounts only once" do
    accounts = [acct("5000", 5000)]
    qa = mock("qa"); qa.stubs(:id).returns(99)
    qa.expects(:fetch_all_accounts).once.returns(accounts)

    cache = Qbo::AccountsCache.new
    item1 = line_item_stub(Trueup, amount: 1.0, description: "u1")
    item2 = line_item_stub(Trueup, amount: 2.0, description: "u2")

    [item1, item2].each do |it|
      r = Qbo::BillRouter.new(it, accounts_cache: cache)
      r.stubs(:studio).returns(nil)
      r.stubs(:qbo_account).returns(qa)
      r.stubs(:enterprise).returns(OpenStruct.new(name: "Test Enterprise"))
      r.stubs(:enterprise_gl_map).returns({ subcontractor_default: "5000" })
      r.lines
    end
  end
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `bin/rails test test/services/qbo/bill_router_test.rb -n "/sharing one cache/"`
Expected: PASS (this validates the cache wiring; `#qbo_account` is private but stubbable). If it errors on `qbo_account` being unstubbable, it confirms the method exists — proceed.

- [ ] **Step 3: Rewire `sync_qbo_bill!`**

In `app/models/concerns/syncs_as_qbo_bill.rb`, change the method signature and the line-item construction. Replace:

```ruby
  def sync_qbo_bill!
    qa = qbo_account_for_bill
    return if qa.nil?
```

with:

```ruby
  def sync_qbo_bill!(accounts_cache: nil)
    qa = qbo_account_for_bill
    return if qa.nil?
    accounts_cache ||= Qbo::AccountsCache.new
```

Then replace:

```ruby
    qbo_accounts = qa.fetch_all_accounts
    bill.line_items = bill_line_items(qbo_accounts)
```

with:

```ruby
    bill.line_items = Qbo::BillRouter.new(self, accounts_cache: accounts_cache).lines.map do |data|
      line = Quickbooks::Model::BillLineItem.new(description: data[:description], amount: data[:amount])
      line.account_based_expense_item! do |detail|
        detail.account_ref = Quickbooks::Model::BaseReference.new(data[:account].id)
      end
      line
    end
```

- [ ] **Step 4: Thread the cache through the two callers**

In `app/models/contributor.rb`, replace `sync_qbo_bills!` (lines 260-270) with:

```ruby
  def sync_qbo_bills!
    cache = Qbo::AccountsCache.new
    contributor_payouts.each { |cp| cp.sync_qbo_bill!(accounts_cache: cache) }
    contributor_adjustments.each { |adj| adj.sync_qbo_bill!(accounts_cache: cache) }
    profit_shares.each { |ps| ps.sync_qbo_bill!(accounts_cache: cache) }
  end
```

In `lib/tasks/stacks.rake`, inside the `sync_contributor_qbo_bills` task, add a cache above the `sync_record` lambda and pass it in. Replace:

```ruby
    sync_record = ->(record) {
      begin
        record.sync_qbo_bill!
```

with:

```ruby
    accounts_cache = Qbo::AccountsCache.new
    sync_record = ->(record) {
      begin
        record.sync_qbo_bill!(accounts_cache: accounts_cache)
```

- [ ] **Step 5: Run the router suite and the concern suite**

Run: `bin/rails test test/services/qbo/bill_router_test.rb test/models/concerns/syncs_as_qbo_bill_test.rb`
Expected: The router suite passes. The concern suite may report failures only for the soon-deleted `find_qbo_account!` / `bill_line_items` tests — those are removed in Task 7. All other tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/models/concerns/syncs_as_qbo_bill.rb app/models/contributor.rb lib/tasks/stacks.rake test/services/qbo/bill_router_test.rb
git commit -m "Route bill line items through Qbo::BillRouter with a per-session accounts cache"
```

---

### Task 7: Delete the scattered logic and its tests

Remove every method and class the router replaced, plus their now-obsolete tests.

**Files:**
- Modify: `app/models/concerns/syncs_as_qbo_bill.rb` (delete `find_qbo_account!`, `bill_line_items`)
- Modify: `app/models/contributor_payout.rb` (delete `find_qbo_account!`, `bill_line_items`)
- Modify: `app/models/profit_share.rb` (delete `find_qbo_account!`, `PROFIT_SHARE_LIABILITY_ACCT_NUM`)
- Modify: `app/models/pay_stub.rb` (delete `find_qbo_account!`)
- Modify: `app/models/studio.rb` (delete `qbo_subcontractors_categories`)
- Delete: `app/services/contributor_payouts/qbo_bill_lines.rb`
- Delete: `test/services/contributor_payouts/qbo_bill_lines_test.rb`
- Modify: `test/models/profit_share_test.rb` (remove the 2 `find_qbo_account!` tests)
- Modify: `test/models/contributor_payout_test.rb` (remove the `bill_line_items` delegation test)
- Modify: `test/models/concerns/syncs_as_qbo_bill_test.rb` (remove the `find_qbo_account!` raise test)

**Interfaces:** none produced; this task only removes code.

- [ ] **Step 1: Delete the obsolete service and its test**

```bash
git rm app/services/contributor_payouts/qbo_bill_lines.rb test/services/contributor_payouts/qbo_bill_lines_test.rb
```

- [ ] **Step 2: Remove `find_qbo_account!` and `bill_line_items` from `SyncsAsQboBill`**

In `app/models/concerns/syncs_as_qbo_bill.rb`, delete the entire `find_qbo_account!` method (the `def find_qbo_account!(qbo_accounts = nil) ... end` block and its leading comment) and the entire `bill_line_items(qbo_accounts)` method (and its leading comment). Leave `qbo_account_for_bill`, `qbo_bill`, `detach_and_destroy_qbo_bill`, `qbo_url`, `load_qbo_bill!`, `payable?`, `sync_qbo_bill!`, and the host-contract comment intact.

- [ ] **Step 3: Remove the overrides from the host models**

- In `app/models/contributor_payout.rb`: delete `find_qbo_account!` (lines ~29-52) and `bill_line_items` (the method delegating to `ContributorPayouts::QboBillLines`, ~54-73), with their comments.
- In `app/models/profit_share.rb`: delete `find_qbo_account!` (~41-49) and the `PROFIT_SHARE_LIABILITY_ACCT_NUM` constant (~39).
- In `app/models/pay_stub.rb`: delete `find_qbo_account!` (~65-72).
- In `app/models/studio.rb`: delete `qbo_subcontractors_categories` (~668-673).

- [ ] **Step 4: Remove the obsolete tests**

- In `test/models/profit_share_test.rb`: delete the two tests named `"find_qbo_account! returns the profit-share liability account when present"` and `"find_qbo_account! falls back to the default SyncsAsQboBill routing when the liability account is missing"`.
- In `test/models/contributor_payout_test.rb`: delete the test `"bill_line_items delegates to ContributorPayouts::QboBillLines and converts hashes to BillLineItem objects"`.
- In `test/models/concerns/syncs_as_qbo_bill_test.rb`: delete the test `"find_qbo_account! raises a descriptive error when enterprise has no qbo_account"`.

- [ ] **Step 5: Grep to confirm no remaining references**

Run:
```bash
grep -rn "find_qbo_account!\|qbo_subcontractors_categories\|QboBillLines\|def bill_line_items\|PROFIT_SHARE_LIABILITY_ACCT_NUM" app lib test
```
Expected: no output (empty). If anything remains (e.g. a stray comment), remove it.

- [ ] **Step 6: Run the full suites for the touched models + services**

Run:
```bash
bin/rails test test/services/qbo test/models/profit_share_test.rb test/models/pay_stub_test.rb test/models/contributor_payout_test.rb test/models/concerns/syncs_as_qbo_bill_test.rb test/models/studio_test.rb
```
Expected: PASS (0 failures, 0 errors).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Delete scattered bill account-selection logic now owned by Qbo::BillRouter"
```

---

### Task 8: Full suite green

**Files:** none (verification only).

- [ ] **Step 1: Run the entire test suite**

Run: `bin/rails test`
Expected: PASS. If any failure references a deleted method, fix the calling test/code per Task 7's intent and re-run.

- [ ] **Step 2: Commit any fixups**

```bash
git add -A
git commit -m "Fix up references after Qbo::BillRouter consolidation"
```

(Skip the commit if there were no fixups.)

---

### Task 9: Fill real GL codes in `CONCEPT_GL_BY_ENTERPRISE` (data task — gated on user confirmation)

This is the one non-TDD task: it fills the `"____"` placeholders with each enterprise's actual GL codes by inspecting the live chart of accounts. It requires the live QBO connection and **must be confirmed with the user before committing**, because wrong codes silently misroute money.

**Files:**
- Modify: `app/services/qbo/bill_router.rb` (`CONCEPT_GL_BY_ENTERPRISE`)

- [ ] **Step 1: Dump each enterprise's chart of accounts**

Run (read-only; lists name + acct_num for both enterprises):
```bash
bin/rails runner '
[Enterprise.sanctuary, Enterprise.garden3d].each do |e|
  puts "== #{e.name} =="
  e.qbo_account.fetch_all_accounts
   .select { |a| a.respond_to?(:acct_num) && a.acct_num.present? }
   .sort_by(&:acct_num)
   .each { |a| puts "  #{a.acct_num}\t#{a.name}" }
end
'
```

- [ ] **Step 2: Map each concept to its GL code**

From the dump, identify, per enterprise, the GL code (`acct_num`) for:
`subcontractor_default` (today "Contractors - Client Services"), `marketing` (today "Contractors - Marketing Services"), `salaries` (today "Facilities Management Salaries"), and confirm `bonuses` (5710), `commission` (6120), `profit_share_liability` (2340) for Sanctuary and find garden3d's equivalents. For `subcontractor_by_studio`, list each studio and the GL code of its `Contractors - <accounting_prefix>` account; garden3d maps its single "Total [SC] Subcontractors" account.

- [ ] **Step 3: Present the proposed constant to the user and get confirmation**

Show the filled `CONCEPT_GL_BY_ENTERPRISE` and the name→code mapping you derived. **Wait for the user to confirm the values before editing the file.**

- [ ] **Step 4: Fill the constant and re-run the suite**

Replace every `"____"` with the confirmed codes and populate `subcontractor_by_studio`. The studio map is keyed by `studio.name` (matching `BillRouter#gl_code_for`).

Run: `bin/rails test test/services/qbo`
Expected: PASS (tests stub `enterprise_gl_map`, so they remain green regardless; this confirms no syntax error).

- [ ] **Step 5: Commit**

```bash
git add app/services/qbo/bill_router.rb
git commit -m "Fill real per-enterprise GL codes in Qbo::BillRouter"
```

---

## Self-Review

**Spec coverage:**
- One service object, two layers → Tasks 2–5. ✓
- Input = ledger item, derives ledger/enterprise/contributor/studio → Task 2 (`#ledger`/`#enterprise`/`#contributor`/`#studio`). ✓
- Owns line-splitting + selection → Tasks 3–5 (`#concept_lines`, `#payout_concept_lines`, `#lines`). ✓
- Concept catalog + routing rules per type → Tasks 3–5. ✓
- Per-enterprise GL map (code constant), studios nested in-constant → Task 2 constant; Task 9 fills it. ✓
- Internal-client marketing override w/ non-CS-studio exception → Task 5. ✓
- Preserved safety (in_sync collapse, drift WARN, blueprint shapes, description format) → Task 4. ✓
- Fallback chain then raise (incl. intentional profit-share divergence) → Task 2 + Global Constraints. ✓
- Per-session cache, fetched once per enterprise → Tasks 1 & 6. ✓
- Deletions of all six sites → Task 7. ✓
- `amount <= 0` guard unchanged → untouched in `sync_qbo_bill!` (Task 6 only swaps line building). ✓

**Placeholder scan:** The only `"____"` are the GL-code data values, explicitly owned by Task 9 with a live-data procedure and user-confirmation gate — not logic placeholders. No "TBD"/"handle edge cases"/"similar to" present.

**Type consistency:** `concept_lines`/`payout_concept_lines`/`collapsed_payout_line`/`single_line` all return `{amount:, description:, concept:}`; `lines`/`resolve` consume `concept` and return `{amount:, description:, account:}`. `base_concept` returns a Symbol used by `concept_for_bucket` and `collapsed_payout_line`. `gl_code_for`/`find_account`/`enterprise_gl_map`/`accounts` names are consistent across Tasks 2–6. `FALLBACKABLE_CONCEPTS`, `ROLE_LABEL_BY_BUCKET`, `SURPLUS_DESCRIPTION_MARKER`, `ENTERPRISE_KEY_BY_NAME`, `CONCEPT_GL_BY_ENTERPRISE` referenced consistently.
