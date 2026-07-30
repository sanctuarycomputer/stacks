# Studio OKR: Client & Pipeline KPIs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four new Studio-level OKR datapoints — `average_client_lifetime_value`, `average_client_tenure`, `client_revenue_concentration`, `forecasted_sales_revenue` — plus a `needs_budget_estimate` data-hygiene task, per the approved spec at `docs/superpowers/specs/2026-07-29-studio-okr-client-kpis-design.md`.

**Architecture:** A new PORO `Stacks::ClientRevenue` turns InvoiceTracker history into per-client revenue rows (studio-attributed via blueprint lines) and answers LTV/tenure/concentration queries. `Studio#key_datapoints_for_period` merges four new datapoint hash entries, so the existing OKR machinery (targets, health, nightly snapshots, OKR Explorer, MCP tool) picks them up with no further plumbing. `Stacks::Notion::Lead` gains status/budget readers shared by the pipeline KPI and a new TaskBuilder discovery rule.

**Tech Stack:** Rails, PostgreSQL (jsonb), Minitest + mocha (NOT RSpec — the spec doc says RSpec but this repo uses Minitest; follow this plan), ActiveAdmin.

## Global Constraints

- New `Okr#datapoint` enum values are APPEND-ONLY: use exactly `27, 28, 29, 30`. Never renumber existing entries.
- Test framework is Minitest with mocha (`require 'test_helper'`, `ActiveSupport::TestCase`, `.stubs`/`.expects`). Run with `bin/rails test <path>`.
- No new gems.
- Lead property names are exact Notion strings: `"Lead Status"`, `"Est. Budget Low"`, `"Est. Budget High"`. Open statuses are exactly: `"Active"`, `"Not started"`, `"On hold (re-engage)"`.
- Countable revenue = InvoiceTracker with a linked, non-voided QboInvoice on an external (`!is_internal?`) ForecastClient. Dollar value = `qbo_invoice.total`, dated by `invoice_pass.start_of_month`.
- `lib/` is autoloaded (existing `Stacks::*` classes live there); no `require` statements needed for new `Stacks::` classes.
- Commit after every task.

---

### Task 1: Lead status & budget readers on `Stacks::Notion::Lead`

**Files:**
- Modify: `lib/stacks/notion/lead.rb`
- Test: `test/lib/stacks/notion/lead_test.rb` (create)

**Interfaces:**
- Consumes: `Stacks::Notion::Base#get_prop_value(key)` — returns the property's inner value: a Hash like `{"name" => "Active"}` for status props, a Numeric (or nil) for number props, `{}` when the property key doesn't exist.
- Produces (used by Tasks 3 and 4):
  - `Lead::OPEN_STATUSES` — frozen Array of the three open status strings
  - `#lead_status` → String or nil
  - `#open?` → Boolean
  - `#estimated_budget` → Float, Integer, or nil (midpoint of Low/High; single value if only one filled; nil if neither)

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/notion/lead_test.rb`:

```ruby
require 'test_helper'

class StacksNotionLeadTest < ActiveSupport::TestCase
  def lead_with_props(props)
    NotionPage.new(data: { "properties" => props }).as_lead
  end

  def status_prop(name)
    { "type" => "status", "status" => { "name" => name } }
  end

  def number_prop(value)
    { "type" => "number", "number" => value }
  end

  test "#lead_status returns the Lead Status name" do
    lead = lead_with_props("Lead Status" => status_prop("Active"))
    assert_equal "Active", lead.lead_status
  end

  test "#lead_status returns nil when the property is missing or empty" do
    assert_nil lead_with_props({}).lead_status
    assert_nil lead_with_props("Lead Status" => { "type" => "status", "status" => nil }).lead_status
  end

  test "#open? is true for Active, Not started, and On hold (re-engage)" do
    ["Active", "Not started", "On hold (re-engage)"].each do |status|
      assert lead_with_props("Lead Status" => status_prop(status)).open?, "expected #{status} to be open"
    end
  end

  test "#open? is false for terminal statuses and missing status" do
    ["Won", "Lost", "Passed", "Cold", "Settled", "Project Paused"].each do |status|
      refute lead_with_props("Lead Status" => status_prop(status)).open?, "expected #{status} to not be open"
    end
    refute lead_with_props({}).open?
  end

  test "#estimated_budget returns the midpoint when both Low and High are set" do
    lead = lead_with_props(
      "Est. Budget Low" => number_prop(40_000),
      "Est. Budget High" => number_prop(60_000)
    )
    assert_equal 50_000, lead.estimated_budget
  end

  test "#estimated_budget returns the single value when only one is set" do
    assert_equal 75_000, lead_with_props("Est. Budget High" => number_prop(75_000)).estimated_budget
    assert_equal 30_000, lead_with_props("Est. Budget Low" => number_prop(30_000)).estimated_budget
  end

  test "#estimated_budget returns nil when neither is set" do
    assert_nil lead_with_props({}).estimated_budget
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/notion/lead_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'lead_status'` (and similar for `open?` / `estimated_budget`)

- [ ] **Step 3: Write minimal implementation**

In `lib/stacks/notion/lead.rb`, add inside the class (after the `won_at` / `considered_successful?` methods around line 44):

```ruby
  # Current-status is the source of truth for "open pipeline". The terminal
  # date stamps (✨ Status: Won/Lost/Ghosted) are missing on most dead leads,
  # so they must not be used to decide openness.
  OPEN_STATUSES = ["Active", "Not started", "On hold (re-engage)"].freeze

  def lead_status
    (get_prop_value("Lead Status") || {}).dig("name")
  end

  def open?
    OPEN_STATUSES.include?(lead_status)
  end

  # Midpoint of the Est. Budget Low/High Notion number props; a single value
  # if only one is filled; nil when unbudgeted (callers treat nil as $0 and
  # file a needs_budget_estimate task).
  def estimated_budget
    values = [
      get_prop_value("Est. Budget Low"),
      get_prop_value("Est. Budget High")
    ].select { |v| v.is_a?(Numeric) }
    return nil if values.empty?
    values.sum / values.length.to_f
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/notion/lead_test.rb`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/notion/lead.rb test/lib/stacks/notion/lead_test.rb
git commit -m "feat(leads): add lead_status, open?, and estimated_budget readers"
```

---

### Task 2: `Stacks::ClientRevenue` PORO

**Files:**
- Create: `lib/stacks/client_revenue.rb`
- Test: `test/lib/stacks/client_revenue_test.rb` (create)

**Interfaces:**
- Consumes:
  - `InvoiceTracker#qbo_invoice` (`QboInvoice` or nil), `#forecast_client` (`ForecastClient`), `#invoice_pass` (`InvoicePass`, has `start_of_month` Date), `#blueprint` (jsonb Hash: `{"lines" => {"<description>" => {"forecast_person" => <id>, "quantity" => <num>, "unit_price" => <num>, ...}}}`)
  - `QboInvoice#status` (`:voided` among others), `#total` (Float)
  - `ForecastClient#is_internal?`, `#name`
  - `InvoiceTracker.forecast_person_id_from_description(description)` — extracts the `[FP-<id>]` tag from legacy line descriptions, or nil
  - `ForecastPerson#studio(all_studios)` — the person's Studio, matched by Forecast roles
  - `Studio#is_garden3d?`
- Produces (used by Task 3):
  - `Stacks::ClientRevenue.new(studio, preloaded_studios = Studio.all, trackers = nil)` — `trackers: nil` loads all InvoiceTrackers with includes; tests inject in-memory trackers
  - `#average_lifetime_value_asof(date)` → Float (0 when no clients)
  - `#average_tenure_months_asof(date)` → Float (whole-month diff between first and last invoice month per client, averaged; 0 when no clients)
  - `#client_count_asof(date)` → Integer
  - `#concentration_for_range(starts_at, ends_at)` → `{ value: Float (0-100), top_client_name: String|nil, top_client_amount: Float, total_revenue: Float }`

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/client_revenue_test.rb`:

```ruby
require 'test_helper'

class StacksClientRevenueTest < ActiveSupport::TestCase
  def setup
    @g3d = Studio.new(name: "garden3d", mini_name: "g3d")
    @sanctu = Studio.new(name: "Sanctuary Computer", mini_name: "sanctu")
    @studios = [@g3d, @sanctu]
    @acme = ForecastClient.new(name: "Acme")
    @globex = ForecastClient.new(name: "Globex")
  end

  def make_tracker(client:, month:, total:, blueprint: nil, voided: false, no_invoice: false, internal: false)
    tracker = InvoiceTracker.new
    if no_invoice
      tracker.stubs(:qbo_invoice).returns(nil)
    else
      invoice = QboInvoice.new
      invoice.stubs(:status).returns(voided ? :voided : :paid)
      invoice.stubs(:total).returns(total.to_f)
      tracker.stubs(:qbo_invoice).returns(invoice)
    end
    client.stubs(:is_internal?).returns(true) if internal
    tracker.stubs(:forecast_client).returns(client)
    tracker.stubs(:invoice_pass).returns(InvoicePass.new(start_of_month: month))
    tracker.stubs(:blueprint).returns(blueprint)
    tracker
  end

  test "garden3d counts full invoice totals grouped by client" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 1, 1), total: 10_000),
      make_tracker(client: @acme, month: Date.new(2025, 3, 1), total: 20_000),
      make_tracker(client: @globex, month: Date.new(2025, 2, 1), total: 30_000)
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)

    assert_equal 2, cr.client_count_asof(Date.new(2025, 12, 31))
    assert_equal 30_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
  end

  test "excludes voided, unlinked, and internal-client trackers" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 1, 1), total: 10_000),
      make_tracker(client: @acme, month: Date.new(2025, 2, 1), total: 99_999, voided: true),
      make_tracker(client: @acme, month: Date.new(2025, 3, 1), total: 99_999, no_invoice: true),
      make_tracker(client: @globex, month: Date.new(2025, 1, 1), total: 99_999, internal: true)
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)

    assert_equal 1, cr.client_count_asof(Date.new(2025, 12, 31))
    assert_equal 10_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
  end

  test "asof date excludes later invoices" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 1, 1), total: 10_000),
      make_tracker(client: @acme, month: Date.new(2025, 6, 1), total: 50_000)
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)

    assert_equal 10_000.0, cr.average_lifetime_value_asof(Date.new(2025, 3, 31))
  end

  test "average tenure is whole months between first and last invoice month per client" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 1, 1), total: 1),
      make_tracker(client: @acme, month: Date.new(2025, 7, 1), total: 1),   # 6 months
      make_tracker(client: @globex, month: Date.new(2025, 3, 1), total: 1)  # 0 months
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)

    assert_equal 3.0, cr.average_tenure_months_asof(Date.new(2025, 12, 31))
  end

  test "concentration is the largest client's share of in-range revenue" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 4, 1), total: 75_000),
      make_tracker(client: @globex, month: Date.new(2025, 5, 1), total: 25_000),
      make_tracker(client: @globex, month: Date.new(2024, 1, 1), total: 900_000) # out of range
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)
    result = cr.concentration_for_range(Date.new(2025, 4, 1), Date.new(2025, 6, 30))

    assert_equal 75.0, result[:value]
    assert_equal "Acme", result[:top_client_name]
    assert_equal 75_000.0, result[:top_client_amount]
    assert_equal 100_000.0, result[:total_revenue]
  end

  test "concentration with no in-range revenue returns zeros" do
    cr = Stacks::ClientRevenue.new(@g3d, @studios, [])
    result = cr.concentration_for_range(Date.new(2025, 1, 1), Date.new(2025, 1, 31))

    assert_equal 0, result[:value]
    assert_nil result[:top_client_name]
  end

  test "empty rows return 0 for averages" do
    cr = Stacks::ClientRevenue.new(@g3d, @studios, [])
    assert_equal 0, cr.average_lifetime_value_asof(Date.today)
    assert_equal 0, cr.average_tenure_months_asof(Date.today)
  end

  test "sub-studio takes a pro-rata share of the invoice via blueprint person lines" do
    person_in_sanctu = ForecastPerson.create!(
      id: 111, first_name: "Sanctu", last_name: "Person", email: "sanctu@sanctuary.computer",
      archived: false, roles: ["Sanctuary Computer"], updated_at: Date.today
    )
    person_elsewhere = ForecastPerson.create!(
      id: 222, first_name: "Other", last_name: "Person", email: "other@sanctuary.computer",
      archived: false, roles: ["XXIX"], updated_at: Date.today
    )

    blueprint = {
      "lines" => {
        "ACME-1 Acme (July 2025) Sanctu Person [FP-111]" => {
          "forecast_person" => person_in_sanctu.forecast_id, "quantity" => 10, "unit_price" => 100
        },
        "ACME-1 Acme (July 2025) Other Person [FP-222]" => {
          "forecast_person" => person_elsewhere.forecast_id, "quantity" => 30, "unit_price" => 100
        }
      }
    }
    # blueprint sums to $4,000; sanctu's share is 1,000/4,000 = 25% of the $8,000 invoice
    trackers = [make_tracker(client: @acme, month: Date.new(2025, 7, 1), total: 8_000, blueprint: blueprint)]
    cr = Stacks::ClientRevenue.new(@sanctu, @studios, trackers)

    assert_equal 2_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
  end

  test "sub-studio resolves legacy lines via the [FP-id] description tag" do
    person_in_sanctu = ForecastPerson.create!(
      id: 111, first_name: "Sanctu", last_name: "Person", email: "sanctu@sanctuary.computer",
      archived: false, roles: ["Sanctuary Computer"], updated_at: Date.today
    )

    blueprint = {
      "lines" => {
        "ACME-1 Acme (July 2025) Sanctu Person [FP-111]" => { "quantity" => 10, "unit_price" => 100 }
      }
    }
    trackers = [make_tracker(client: @acme, month: Date.new(2025, 7, 1), total: 1_000, blueprint: blueprint)]
    cr = Stacks::ClientRevenue.new(@sanctu, @studios, trackers)

    assert_equal 1_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
  end

  test "sub-studio skips malformed blueprint lines and trackers with no usable lines" do
    blueprint = {
      "lines" => {
        "bad line" => { "quantity" => "ten", "unit_price" => 100 }
      }
    }
    trackers = [make_tracker(client: @acme, month: Date.new(2025, 7, 1), total: 1_000, blueprint: blueprint)]
    cr = Stacks::ClientRevenue.new(@sanctu, @studios, trackers)

    assert_equal 0, cr.client_count_asof(Date.new(2025, 12, 31))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/client_revenue_test.rb`
Expected: FAIL — `NameError: uninitialized constant Stacks::ClientRevenue`

- [ ] **Step 3: Write the implementation**

Create `lib/stacks/client_revenue.rb`:

```ruby
# Per-client invoiced revenue for a studio, derived from InvoiceTracker
# history (June 2021 onward). Countable revenue = trackers with a linked,
# non-voided QBO invoice on an external client. garden3d counts full invoice
# totals; sub-studios take a pro-rata share via blueprint person lines
# (person -> studio by Forecast roles), the same attribution the cost
# explorer uses. Feeds the average_client_lifetime_value,
# average_client_tenure, and client_revenue_concentration OKR datapoints.
class Stacks::ClientRevenue
  Row = Struct.new(:client, :month, :amount, keyword_init: true)

  def initialize(studio, preloaded_studios = Studio.all, trackers = nil)
    @studio = studio
    @preloaded_studios = preloaded_studios
    @trackers = trackers || self.class.all_trackers
    @rows = build_rows
  end

  def self.all_trackers
    InvoiceTracker
      .includes(:invoice_pass, :qbo_invoice, forecast_client: :enterprise_forecast_client)
      .to_a
  end

  def average_lifetime_value_asof(date)
    totals = totals_by_client_asof(date)
    return 0 if totals.empty?
    totals.values.sum / totals.length
  end

  def average_tenure_months_asof(date)
    rows = @rows.select { |r| r.month <= date }
    return 0 if rows.empty?
    tenures = rows.group_by(&:client).values.map do |client_rows|
      first, last = client_rows.map(&:month).minmax
      (last.year * 12 + last.month) - (first.year * 12 + first.month)
    end
    tenures.sum.to_f / tenures.length
  end

  def client_count_asof(date)
    totals_by_client_asof(date).length
  end

  def concentration_for_range(starts_at, ends_at)
    in_range = @rows.select { |r| r.month >= starts_at.beginning_of_month && r.month <= ends_at }
    total = in_range.sum(&:amount)
    return { value: 0, top_client_name: nil, top_client_amount: 0, total_revenue: 0 } if total.zero?

    top_client, top_amount = in_range
      .group_by(&:client)
      .transform_values { |rs| rs.sum(&:amount) }
      .max_by { |_, amount| amount }

    {
      value: (top_amount / total) * 100,
      top_client_name: top_client.name,
      top_client_amount: top_amount,
      total_revenue: total
    }
  end

  private

  def totals_by_client_asof(date)
    @rows
      .select { |r| r.month <= date }
      .group_by(&:client)
      .transform_values { |rs| rs.sum(&:amount) }
  end

  def build_rows
    @trackers.filter_map do |tracker|
      invoice = tracker.qbo_invoice
      client = tracker.forecast_client
      next if invoice.nil? || invoice.status == :voided
      next if client.nil? || client.is_internal?

      amount = @studio.is_garden3d? ? invoice.total : studio_share(tracker, invoice.total)
      next if amount.nil? || amount.zero?

      Row.new(client: client, month: tracker.invoice_pass.start_of_month, amount: amount)
    end
  end

  # Pro-rata share of the invoice total from blueprint lines whose person
  # belongs to this studio. Legacy lines without a forecast_person key fall
  # back to the [FP-<id>] description tag. Malformed lines are skipped and
  # logged; a tracker with no usable lines is omitted from sub-studio numbers
  # (it still counts for garden3d).
  def studio_share(tracker, invoice_total)
    lines = (tracker.blueprint || {})["lines"] || {}
    studio_sum = 0.0
    all_sum = 0.0

    lines.each do |description, line|
      unless line.is_a?(Hash) && line["quantity"].is_a?(Numeric) && line["unit_price"].is_a?(Numeric)
        Rails.logger.warn("[ClientRevenue] invoice_tracker=#{tracker.id} skipping malformed blueprint line #{description.inspect}")
        next
      end
      line_value = line["quantity"] * line["unit_price"]
      all_sum += line_value

      person_id = line["forecast_person"] || InvoiceTracker.forecast_person_id_from_description(description)
      next if person_id.nil?
      person = forecast_people_by_id[person_id]
      studio_sum += line_value if person&.studio(@preloaded_studios) == @studio
    end

    return nil if all_sum.zero?
    (studio_sum / all_sum) * invoice_total
  end

  def forecast_people_by_id
    @_forecast_people_by_id ||= ForecastPerson.all.index_by(&:forecast_id)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/client_revenue_test.rb`
Expected: PASS (10 tests)

Note: the two `ForecastPerson.create!` tests hit the DB (an `after_create` creates a Contributor); that's normal for this suite.

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/client_revenue.rb test/lib/stacks/client_revenue_test.rb
git commit -m "feat: add Stacks::ClientRevenue for per-client studio revenue"
```

---

### Task 3: Okr enum entries + the four datapoints on Studio

**Files:**
- Modify: `app/models/okr.rb:46` (end of `datapoint` enum)
- Modify: `app/models/studio.rb` (`key_datapoints_for_period`, ends ~line 629; add two new methods after it)
- Test: `test/models/studio_test.rb` (append tests)

**Interfaces:**
- Consumes:
  - `Stacks::ClientRevenue` public interface from Task 2 (exact signatures listed there)
  - `Stacks::Notion::Lead#open?` / `#estimated_budget` from Task 1
  - `Stacks::Period.new(label, starts_at, ends_at)` with `#starts_at` / `#ends_at`
- Produces (used by Task 5):
  - `Okr.datapoints` gains `average_client_lifetime_value: 27, average_client_tenure: 28, client_revenue_concentration: 29, forecasted_sales_revenue: 30`
  - `Studio#client_revenue(preloaded_studios = Studio.all)` → memoized `Stacks::ClientRevenue`
  - `Studio#client_and_pipeline_datapoints(period, preloaded_new_biz_leads, client_revenue)` → Hash with the four datapoint keys, each `{value:, unit:, extras:}` shaped like existing datapoints
  - `Studio#key_datapoints_for_period` gains a final positional param `preloaded_client_revenue = client_revenue(preloaded_studios)` and merges the four keys into its return value

- [ ] **Step 1: Write the failing test**

Append to `test/models/studio_test.rb` (inside `class StudioTest`):

```ruby
  test "datapoint enum includes the four client & pipeline KPIs at 27-30" do
    assert_equal 27, Okr.datapoints["average_client_lifetime_value"]
    assert_equal 28, Okr.datapoints["average_client_tenure"]
    assert_equal 29, Okr.datapoints["client_revenue_concentration"]
    assert_equal 30, Okr.datapoints["forecasted_sales_revenue"]
  end

  test "#client_and_pipeline_datapoints returns the four KPI entries" do
    studio = Studio.new(name: "garden3d", mini_name: "g3d")
    acme = ForecastClient.new(name: "Acme")

    invoice = QboInvoice.new
    invoice.stubs(:status).returns(:paid)
    invoice.stubs(:total).returns(10_000.0)
    tracker = InvoiceTracker.new
    tracker.stubs(:qbo_invoice).returns(invoice)
    tracker.stubs(:forecast_client).returns(acme)
    tracker.stubs(:invoice_pass).returns(InvoicePass.new(start_of_month: Date.new(2025, 2, 1)))
    tracker.stubs(:blueprint).returns(nil)

    client_revenue = Stacks::ClientRevenue.new(studio, [studio], [tracker])

    open_budgeted = NotionPage.new(data: { "properties" => {
      "Lead Status" => { "type" => "status", "status" => { "name" => "Active" } },
      "Est. Budget Low" => { "type" => "number", "number" => 40_000 },
      "Est. Budget High" => { "type" => "number", "number" => 60_000 }
    } }).as_lead
    open_unbudgeted = NotionPage.new(data: { "properties" => {
      "Lead Status" => { "type" => "status", "status" => { "name" => "Not started" } }
    } }).as_lead
    lost = NotionPage.new(data: { "properties" => {
      "Lead Status" => { "type" => "status", "status" => { "name" => "Lost" } },
      "Est. Budget High" => { "type" => "number", "number" => 999_999 }
    } }).as_lead

    period = Stacks::Period.new("Feb 2025", Date.new(2025, 2, 1), Date.new(2025, 2, 28))
    data = studio.client_and_pipeline_datapoints(period, [open_budgeted, open_unbudgeted, lost], client_revenue)

    assert_equal 10_000.0, data[:average_client_lifetime_value][:value]
    assert_equal :usd, data[:average_client_lifetime_value][:unit]
    assert_equal 1, data[:average_client_lifetime_value][:extras][:client_count]

    assert_equal 0.0, data[:average_client_tenure][:value]
    assert_equal :count, data[:average_client_tenure][:unit]

    assert_equal 100.0, data[:client_revenue_concentration][:value]
    assert_equal :percentage, data[:client_revenue_concentration][:unit]
    assert_equal "Acme", data[:client_revenue_concentration][:extras][:top_client_name]

    assert_equal 50_000.0, data[:forecasted_sales_revenue][:value]
    assert_equal :usd, data[:forecasted_sales_revenue][:unit]
    assert_equal 2, data[:forecasted_sales_revenue][:extras][:open_lead_count]
    assert_equal 1, data[:forecasted_sales_revenue][:extras][:budgeted_lead_count]
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/studio_test.rb`
Expected: the two new tests FAIL (`Okr.datapoints["average_client_lifetime_value"]` is nil; `NoMethodError: undefined method 'client_and_pipeline_datapoints'`). Pre-existing tests in this file must PASS — if any fail before your change, stop and report.

- [ ] **Step 3: Write the implementation**

In `app/models/okr.rb`, add to the end of the `datapoint` enum (after `project_satisfaction: 26,` on line 46):

```ruby
    project_satisfaction: 26,
    average_client_lifetime_value: 27,
    average_client_tenure: 28,
    client_revenue_concentration: 29,
    forecasted_sales_revenue: 30,
```

In `app/models/studio.rb`:

(a) Add a final positional parameter to `key_datapoints_for_period` (line 441-451):

```ruby
  def key_datapoints_for_period(
    period,
    prev_period,
    accounting_method,
    preloaded_studios = Studio.all,
    preloaded_new_biz_leads = new_biz_leads,
    utilization_for_period = utilization_for_period(period, preloaded_studios),
    utilization_for_prev_period = utilization_for_period(prev_period, preloaded_studios),
    g3d_utilization_for_period = preloaded_studios.find(&:is_garden3d?).utilization_for_period(period, preloaded_studios),
    g3d_utilization_for_prev_period = preloaded_studios.find(&:is_garden3d?).utilization_for_period(prev_period, preloaded_studios),
    preloaded_client_revenue = client_revenue(preloaded_studios)
  )
```

(b) At the end of `key_datapoints_for_period`, immediately before the final `data` return (currently line 628), add:

```ruby
    data.merge!(client_and_pipeline_datapoints(period, preloaded_new_biz_leads, preloaded_client_revenue))

    data
  end
```

(c) After `key_datapoints_for_period` ends, add the two new methods:

```ruby
  def client_revenue(preloaded_studios = Studio.all)
    @_client_revenue ||= Stacks::ClientRevenue.new(self, preloaded_studios)
  end

  def client_and_pipeline_datapoints(period, preloaded_new_biz_leads, client_revenue)
    open_leads = preloaded_new_biz_leads.select(&:open?)
    budgets = open_leads.filter_map(&:estimated_budget)
    concentration = client_revenue.concentration_for_range(period.starts_at, period.ends_at)
    client_count = client_revenue.client_count_asof(period.ends_at)

    {
      average_client_lifetime_value: {
        value: client_revenue.average_lifetime_value_asof(period.ends_at),
        unit: :usd,
        extras: { client_count: client_count }
      },
      average_client_tenure: {
        value: client_revenue.average_tenure_months_asof(period.ends_at),
        unit: :count,
        extras: { client_count: client_count }
      },
      client_revenue_concentration: {
        value: concentration[:value],
        unit: :percentage,
        extras: {
          top_client_name: concentration[:top_client_name],
          top_client_amount: concentration[:top_client_amount],
          total_revenue: concentration[:total_revenue]
        }
      },
      forecasted_sales_revenue: {
        value: budgets.sum,
        unit: :usd,
        extras: {
          open_lead_count: open_leads.count,
          budgeted_lead_count: budgets.count
        }
      }
    }
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/studio_test.rb`
Expected: PASS (including the pre-existing tests)

- [ ] **Step 5: Commit**

```bash
git add app/models/okr.rb app/models/studio.rb test/models/studio_test.rb
git commit -m "feat(okrs): add client LTV, tenure, concentration & pipeline datapoints"
```

---

### Task 4: `needs_budget_estimate` TaskBuilder discovery

**Files:**
- Modify: `lib/stacks/task_builder/discoveries/notion_leads.rb:42` (in `issues_for`)
- Modify: `app/models/stacks_task.rb:38` (HUMANIZED_TYPES, Notion lead section)
- Test: `test/lib/stacks/task_builder/discoveries/notion_leads_test.rb` (create)

**Interfaces:**
- Consumes: `Stacks::Notion::Lead#open?` / `#estimated_budget` (Task 1); `Discoveries::Base#task(subject:, type:, owners:)` which falls back to `admin_fallback` owners; `StacksTask` (`#type`, `#owners`)
- Produces: leads that are open and unbudgeted yield a `StacksTask` with `type == :needs_budget_estimate`, routed to the lead's Account Lead admin users (or the admin fallback)

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/task_builder/discoveries/notion_leads_test.rb`:

```ruby
require 'test_helper'

class StacksTaskBuilderDiscoveriesNotionLeadsTest < ActiveSupport::TestCase
  def setup
    @admin = AdminUser.create!(email: "admin@sanctuary.computer", password: "passw0rd")
  end

  def lead_page(props)
    NotionPage.new(data: { "properties" => props })
  end

  def discover(pages)
    NotionPage.stubs(:lead).returns(pages)
    Stacks::TaskBuilder::Discoveries::NotionLeads.new(admin_fallback: [@admin]).tasks
  end

  test "an open lead with no budget yields a needs_budget_estimate task owned by the fallback" do
    tasks = discover([lead_page(
      "Lead Status" => { "type" => "status", "status" => { "name" => "Active" } },
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => Date.today.iso8601 } }
    )])

    task = tasks.find { |t| t.type == :needs_budget_estimate }
    assert task, "expected a needs_budget_estimate task"
    assert_equal [@admin], task.owners
  end

  test "an open lead with a budget yields no needs_budget_estimate task" do
    tasks = discover([lead_page(
      "Lead Status" => { "type" => "status", "status" => { "name" => "Active" } },
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => Date.today.iso8601 } },
      "Est. Budget High" => { "type" => "number", "number" => 50_000 }
    )])

    refute tasks.any? { |t| t.type == :needs_budget_estimate }
  end

  test "a closed lead with no budget yields no needs_budget_estimate task" do
    tasks = discover([lead_page(
      "Lead Status" => { "type" => "status", "status" => { "name" => "Lost" } },
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => Date.today.iso8601 } }
    )])

    refute tasks.any? { |t| t.type == :needs_budget_estimate }
  end

  test "needs_budget_estimate has an explicit humanized label" do
    assert_equal "Notion lead needs an estimated budget",
      StacksTask::HUMANIZED_TYPES[:needs_budget_estimate]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/task_builder/discoveries/notion_leads_test.rb`
Expected: FAIL — first and last tests fail (no `:needs_budget_estimate` task produced; no HUMANIZED_TYPES entry). The two `refute` tests pass trivially.

- [ ] **Step 3: Write the implementation**

In `lib/stacks/task_builder/discoveries/notion_leads.rb`, inside `issues_for(lead)` add after the `no_studios_set` check (line 40):

```ruby
          out << :needs_budget_estimate if lead.open? && lead.estimated_budget.nil?
```

In `app/models/stacks_task.rb`, in the `# Notion lead issues` section of `HUMANIZED_TYPES` (after `no_studios_set:` on line 38):

```ruby
    no_studios_set: "Notion lead needs studios assigned",
    needs_budget_estimate: "Notion lead needs an estimated budget",
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/task_builder/discoveries/notion_leads_test.rb`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/task_builder/discoveries/notion_leads.rb app/models/stacks_task.rb test/lib/stacks/task_builder/discoveries/notion_leads_test.rb
git commit -m "feat(tasks): file needs_budget_estimate for open unbudgeted leads"
```

---

### Task 5: Snapshot wiring, OKR hints, and OKR Explorer

**Files:**
- Modify: `app/models/studio.rb` — `snapshot_data_for_period` (lines 103-147), `generate_snapshot!` (lines 149-191), `hint_for_okr` (lines 251-272)
- Modify: `app/admin/okr_explorer.rb:8`

**Interfaces:**
- Consumes: `Studio#client_revenue` and the new datapoint `extras` keys from Task 3 (`client_count`, `top_client_name`, `top_client_amount`, `total_revenue`, `open_lead_count`, `budgeted_lead_count`)
- Produces: nightly snapshots include the four datapoints for every gradation/period; OKR chips show hints; OKR Explorer can chart the four datapoints

Why the wiring matters: `generate_snapshot!` runs `snapshot_data_for_period` inside `Parallel.map(in_threads: 5)`. Without eager construction, five threads would race to memoize `@_client_revenue`. Building it once in the method signature (single-threaded, same trick as `preloaded_new_biz_leads`) avoids that.

- [ ] **Step 1: Thread the preloaded ClientRevenue through the snapshot pipeline**

In `app/models/studio.rb`, change `generate_snapshot!`'s signature (line 149-152) to:

```ruby
  def generate_snapshot!(
    preloaded_studios = Studio.all,
    preloaded_new_biz_leads = new_biz_leads,
    preloaded_client_revenue = client_revenue(preloaded_studios)
  )
```

and pass it to `snapshot_data_for_period` (the call at lines 175-183):

```ruby
            snapshot_data_for_period(
              period,
              prev_period,
              utilization_by_period,
              g3d_utilization_by_period,
              preloaded_studios,
              preloaded_new_biz_leads,
              all_okrs,
              preloaded_client_revenue
            )
```

Change `snapshot_data_for_period`'s signature (lines 103-111) to accept it:

```ruby
  def snapshot_data_for_period(
    period,
    prev_period,
    utilization_by_period,
    g3d_utilization_by_period,
    preloaded_studios,
    preloaded_new_biz_leads,
    all_okrs,
    preloaded_client_revenue = client_revenue(preloaded_studios)
  )
```

and append `preloaded_client_revenue` as the final argument to BOTH `key_datapoints_for_period` calls inside it (the `cash` call at lines 121-131 and the `accrual` call at lines 134-144), e.g. for cash:

```ruby
    d[:cash][:datapoints] = self.key_datapoints_for_period(
      period,
      prev_period,
      "cash",
      preloaded_studios,
      preloaded_new_biz_leads,
      utilization_by_period[period],
      utilization_by_period[prev_period],
      g3d_utilization_by_period[period],
      g3d_utilization_by_period[prev_period],
      preloaded_client_revenue
    )
```

(repeat identically for the `accrual` call, keeping `"accrual"` as the third argument).

- [ ] **Step 2: Add hints for the four OKRs**

In `app/models/studio.rb`, in `hint_for_okr`'s `case okr.datapoint` (add before the `else` on line 269):

```ruby
    when "average_client_lifetime_value"
      "across #{datapoints[:average_client_lifetime_value][:extras][:client_count]} clients invoiced since June 2021"
    when "average_client_tenure"
      "across #{datapoints[:average_client_tenure][:extras][:client_count]} clients invoiced since June 2021"
    when "client_revenue_concentration"
      "#{datapoints[:client_revenue_concentration][:extras][:top_client_name] || "no top client"}: #{ActionController::Base.helpers.number_to_currency(datapoints[:client_revenue_concentration][:extras][:top_client_amount])} of #{ActionController::Base.helpers.number_to_currency(datapoints[:client_revenue_concentration][:extras][:total_revenue])}"
    when "forecasted_sales_revenue"
      "#{datapoints[:forecasted_sales_revenue][:extras][:budgeted_lead_count]} of #{datapoints[:forecasted_sales_revenue][:extras][:open_lead_count]} open leads budgeted"
```

- [ ] **Step 3: Add the datapoints to the OKR Explorer list**

In `app/admin/okr_explorer.rb`, change line 8 to:

```ruby
    all_okrs = ["average_hourly_rate", "successful_projects", "successful_proposals", "average_client_lifetime_value", "average_client_tenure", "client_revenue_concentration", "forecasted_sales_revenue"]
```

(The explorer partial renders unknown datapoints through its generic value path; no partial changes needed.)

- [ ] **Step 4: Run the full test suite**

Run: `bin/rails test`
Expected: PASS — no regressions. If pre-existing failures exist on the branch base, note them and confirm your changes add none.

- [ ] **Step 5: Verify against real dev data (read-only)**

Run:

```bash
bin/rails runner '
g3d = Studio.garden3d
cr = g3d.client_revenue
today = Date.today
puts "LTV:      #{cr.average_lifetime_value_asof(today).round(0)} across #{cr.client_count_asof(today)} clients"
puts "Tenure:   #{cr.average_tenure_months_asof(today).round(1)} months"
puts "Conc YTD: #{cr.concentration_for_range(today.beginning_of_year, today).inspect}"
period = Stacks::Period.new("YTD", today.beginning_of_year, today)
puts "Pipeline: #{g3d.client_and_pipeline_datapoints(period, g3d.new_biz_leads, cr)[:forecasted_sales_revenue].inspect}"
'
```

Expected: LTV a positive dollar figure with ~100+ clients; tenure a positive number of months; concentration value between 0 and 100 with a real client name; pipeline value ≥ 0 with `open_lead_count` around 120 and `budgeted_lead_count` around 13 (July 2026 dev data). Sanity-check these against the spec's data findings; if wildly off (e.g. concentration > 100, client_count 0), stop and investigate.

- [ ] **Step 6: Commit**

```bash
git add app/models/studio.rb app/admin/okr_explorer.rb
git commit -m "feat(okrs): wire client & pipeline KPIs into snapshots, hints, explorer"
```

---

## Post-implementation (manual, not code)

Creating the Okr records is an admin-UI step, done after deploy via ActiveAdmin ("Okey Dokeys"): one Okr per KPI with a name, description, operator (`greater_than` for LTV/tenure/forecast, `less_than` for concentration), the matching datapoint, and OkrPeriods (target, tolerance, date range, studios). Recommended names: "Average Client Lifetime Value", "Average Client Tenure", "Client Revenue Concentration", "Forecasted Sales Revenue".
