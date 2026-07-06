# get_pnl + get_capacity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the final two P1a read-only MCP tools — `get_pnl` (persisted QBO P&L, never live) and `get_capacity` (per-person utilization from nightly reports) — completing the P1a read layer.

**Architecture:** Two thin presenter tools following the established one-file-per-tool pattern (`Mcp::Responses` envelope, read-only annotations, skip+warn+Sentry, param validation). Both read already-computed persisted rows; neither ever triggers a live external API call.

**Tech Stack:** Rails, `mcp` Ruby gem, Minitest + mocha.

**Spec:** `docs/superpowers/specs/2026-07-06-mcp-pnl-capacity-design.md`

## Global Constraints

- `annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)`; `Mcp::Responses.ok(payload)` / `.error(message)` envelope (`app/services/mcp/responses.rb`).
- **NEVER a live external API call.** `get_pnl` must query persisted `QboProfitAndLossReport` rows directly and MUST NOT call `QboProfitAndLossReport.find_or_fetch_for_range` (it fires live QBO fetches when a row is absent, even with `force: false`). `get_capacity` reads persisted `ForecastPersonUtilizationReport` rows only.
- Per-row mapping failure → skip + `Rails.logger.warn` + `Sentry.capture_exception(e) if defined?(Sentry)`, never fail the report.
- Invalid/unknown params → `Responses.error` listing valid values. Empty results → valid empty payloads.
- No schema changes, no new gems, no model changes (the `data_for_enterprise` discarded-margin bug is noted for a SEPARATE PR — do not fix it here; compute margin in the tool instead).
- Tests: `bin/rails test <path>`; mocha available; `mcp_payload` (test_helper) and `call_tool` (mcp_endpoint_test.rb) helpers exist and must be reused. Worktree already has `config/master.key`. Do not modify initializers/credentials/unrelated code.
- Known pre-existing failure to ignore: `AdminUserTest` salary-window date flake (environment-date-sensitive).

---

### Task 1: `get_pnl` tool

**Files:**
- Create: `app/services/mcp/get_pnl_tool.rb`
- Create: `test/services/mcp/pnl_tool_test.rb`
- Modify: `app/services/mcp/server.rb` (TOOLS array, currently 9 entries)
- Modify: `test/integration/mcp_endpoint_test.rb` (tool-name array + round-trip)

**Interfaces:**
- Consumes: `Enterprise` (`has_one :qbo_account`; `.sanctuary`; name column), `QboAccount` (`has_many :qbo_profit_and_loss_reports`), `QboProfitAndLossReport` (`#data` jsonb: `{"cash" => {"rows" => [[label, value], …]}, "accrual" => {…}}` after jsonb round-trip — STRING keys; `#starts_at`/`#ends_at` date columns; `#data_for_enterprise(enterprise, accounting_method_string, period_label, vertical_symbol)` → `{revenue:, cogs:, expenses:, net_revenue:, profit_margin:(always 0 — bug)}`). `Mcp::Responses.ok/.error`.
- Produces: the `get_pnl` MCP tool. Payload: `{ enterprise, accounting_method, vertical, period: { starts_at, ends_at }, revenue, cogs, expenses, net_revenue, profit_margin }`.

- [ ] **Step 1: Confirm the data-key and accounting-method-arg types**

Run: `grep -n "def data_for_enterprise\|data\[accounting_method\]\|data: {" app/models/qbo_profit_and_loss_report.rb`
Confirm: `data_for_enterprise` indexes `data[accounting_method]["rows"]`, and `data` is created with `{ cash: {...}, accrual: {...} }` (symbol keys → stored as jsonb string keys `"cash"`/`"accrual"`). So the tool passes the STRING `"cash"`/`"accrual"` as `accounting_method`, and the fixture `data` must use string keys. Note the exact `vertical` handling: `:All` symbol vs a `:SC`-style symbol via `Enterprise::VERTICAL_MATCHER`.

- [ ] **Step 2: Write the failing tests**

Create `test/services/mcp/pnl_tool_test.rb`:

```ruby
require 'test_helper'

class Mcp::PnlToolTest < ActiveSupport::TestCase
  def qbo_account_for(enterprise)
    enterprise.qbo_account ||
      QboAccount.create!(enterprise: enterprise, client_id: 'x', client_secret: 'x',
                         realm_id: "realm-#{SecureRandom.hex(3)}")
  end

  # A persisted P&L report with the QBO row shape data_for_enterprise reads.
  def pnl_report!(enterprise:, starts_at:, ends_at:, income:, cogs:, expenses:)
    rows = [
      ['Total Income', income],
      ['Total Cost of Goods Sold', cogs],
      ['Total Expenses', expenses],
      ['Net Income', income - cogs - expenses],
    ]
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account_for(enterprise),
      starts_at: starts_at, ends_at: ends_at,
      data: { 'cash' => { 'rows' => rows }, 'accrual' => { 'rows' => rows } }
    )
  end

  setup { @sanctuary = enterprises(:sanctuary) }

  test 'returns bucketed P&L with a tool-computed margin (not the model bug 0)' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 100_000.0, cogs: 40_000.0, expenses: 20_000.0)
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_equal 'Sanctuary Computer Inc', payload['enterprise']
    assert_equal 'cash', payload['accounting_method']
    assert_equal 100_000.0, payload['revenue']
    assert_equal 40_000.0, payload['cogs']
    assert_equal 20_000.0, payload['expenses']
    assert_equal 40_000.0, payload['net_revenue']
    assert_equal 40.0, payload['profit_margin'] # 40k/100k*100 — NOT the model's 0
  end

  test 'never triggers a live fetch' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 10.0, cogs: 1.0, expenses: 1.0)
    QboProfitAndLossReport.expects(:find_or_fetch_for_range).never
    Mcp::GetPnlTool.call(server_context: {})
  end

  test 'defaults to the most recent persisted report' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31),
                income: 1.0, cogs: 0.0, expenses: 0.0)
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 2.0, cogs: 0.0, expenses: 0.0)
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_equal '2026-06-30', payload['period']['ends_at']
    assert_equal 2.0, payload['revenue']
  end

  test 'accrual accounting_method is selectable' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 5.0, cogs: 0.0, expenses: 0.0)
    payload = mcp_payload(Mcp::GetPnlTool.call(accounting_method: 'accrual', server_context: {}))
    assert_equal 'accrual', payload['accounting_method']
    assert_equal 5.0, payload['revenue']
  end

  test 'an explicit range with no persisted report errors listing available ranges' do
    pnl_report!(enterprise: @sanctuary, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30),
                income: 1.0, cogs: 0.0, expenses: 0.0)
    payload = mcp_payload(Mcp::GetPnlTool.call(start_date: '2026-01-01', end_date: '2026-01-31', server_context: {}))
    assert_includes payload['error'], 'No P&L report'
    assert_includes payload['error'], '2026-06-01 to 2026-06-30'
  end

  test 'unknown enterprise errors listing qbo-account enterprises' do
    qbo_account_for(@sanctuary)
    payload = mcp_payload(Mcp::GetPnlTool.call(enterprise: 'Nope Inc', server_context: {}))
    assert_includes payload['error'], "Unknown enterprise 'Nope Inc'"
    assert_includes payload['error'], 'Sanctuary Computer Inc'
  end

  test 'invalid accounting_method errors' do
    payload = mcp_payload(Mcp::GetPnlTool.call(accounting_method: 'both', server_context: {}))
    assert_includes payload['error'], "Invalid accounting_method 'both'"
  end

  test 'no synced reports at all is a clear error, not a fetch' do
    qbo_account_for(@sanctuary)
    QboProfitAndLossReport.expects(:find_or_fetch_for_range).never
    payload = mcp_payload(Mcp::GetPnlTool.call(server_context: {}))
    assert_includes payload['error'], 'no synced P&L reports'
  end
end
```

NOTE: if `QboAccount.create!` needs different attributes, mirror `test/fixtures/qbo_accounts.yml` (`client_id`, `client_secret`, `realm_id`, `enterprise`). If `enterprises(:sanctuary)` already has a qbo_account via fixtures, `qbo_account_for` returns it.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/services/mcp/pnl_tool_test.rb`
Expected: FAIL — `NameError: uninitialized constant Mcp::GetPnlTool`.

- [ ] **Step 4: Implement the tool**

Create `app/services/mcp/get_pnl_tool.rb`:

```ruby
module Mcp
  class GetPnlTool < MCP::Tool
    tool_name 'get_pnl'
    description 'Profit & Loss (revenue, COGS, expenses, net revenue, profit margin) for an ' \
                'enterprise from the nightly-synced QBO P&L reports. Reads persisted reports ' \
                'only — never calls QBO live. Defaults to the most recent synced period.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Enterprise name (default: Sanctuary Computer Inc)' },
        accounting_method: { type: 'string', description: 'cash (default) or accrual' },
        start_date: { type: 'string', description: 'ISO period start; with end_date, selects an exact synced report' },
        end_date: { type: 'string', description: 'ISO period end' },
        vertical: { type: 'string', description: 'Vertical tag within a combined P&L (e.g. SC, XXIX); default All (whole entity)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    ACCOUNTING_METHODS = %w[cash accrual].freeze

    def self.call(enterprise: nil, accounting_method: 'cash', start_date: nil, end_date: nil, vertical: 'All', server_context:)
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end

      # Resolve enterprise (must have a qbo_account — P&L is per QBO realm).
      accounts_by_enterprise = Enterprise.joins(:qbo_account).to_a
      ent =
        if enterprise.present?
          match = accounts_by_enterprise.find { |e| e.name.to_s.casecmp?(enterprise.to_s.strip) }
          unless match
            valid = accounts_by_enterprise.map(&:name).sort.join(', ')
            return Responses.error("Unknown enterprise '#{enterprise}'. Valid enterprises: #{valid}")
          end
          match
        else
          Enterprise.sanctuary
        end

      reports = QboProfitAndLossReport.where(qbo_account_id: ent.qbo_account.id)
      if reports.none?
        return Responses.error("Enterprise '#{ent.name}' has no synced P&L reports yet.")
      end

      # Select the persisted report — explicit range (exact match, never fetch)
      # or the most recent. NEVER find_or_fetch_for_range (it fires live QBO).
      report =
        if start_date.present? || end_date.present?
          reports.find_by(starts_at: Date.parse(start_date.to_s), ends_at: Date.parse(end_date.to_s))
        else
          reports.order(:ends_at).last
        end

      if report.nil?
        available = reports.order(:ends_at).map { |r| "#{r.starts_at} to #{r.ends_at}" }.join(', ')
        return Responses.error("No P&L report synced for that range. Available: #{available}")
      end

      vertical_sym = vertical.to_s.presence&.to_sym || :All
      d = report.data_for_enterprise(ent, method, "", vertical_sym)
      revenue = d[:revenue].to_f
      # data_for_enterprise discards its own margin computation (returns 0) —
      # compute it here from the (sound) bucketed net_revenue/revenue.
      margin = revenue.positive? ? (d[:net_revenue].to_f / revenue * 100).round(1) : 0.0

      Responses.ok(
        enterprise: ent.name,
        accounting_method: method,
        vertical: vertical.to_s,
        period: { starts_at: report.starts_at.iso8601, ends_at: report.ends_at.iso8601 },
        revenue: revenue.round(2),
        cogs: d[:cogs].to_f.round(2),
        expenses: d[:expenses].to_f.round(2),
        net_revenue: d[:net_revenue].to_f.round(2),
        profit_margin: margin
      )
    rescue Date::Error, ArgumentError => e
      Responses.error("Invalid date: #{e.message}. Use ISO format, e.g. 2026-06-01.")
    end
  end
end
```

Append `Mcp::GetPnlTool,` to `TOOLS` in `app/services/mcp/server.rb`.

- [ ] **Step 5: Run unit tests to verify they pass**

Run: `bin/rails test test/services/mcp/pnl_tool_test.rb`
Expected: PASS (8 tests). If `Date.parse` on a bad string raises something other than `Date::Error`/`ArgumentError`, widen the rescue to match; verify with a bad-date test if you add one.

- [ ] **Step 6: Update the integration test**

In `test/integration/mcp_endpoint_test.rb`, the sorted tool-name array becomes:

```ruby
    assert_equal %w[get_ar_aging get_document get_pnl get_studio_health list_documents list_open_admin_tasks list_overdue_invoices list_projects_at_risk list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
```

Add a round-trip test using the existing `call_tool` helper:

```ruby
  test "tools/call round-trip for get_pnl returns a payload or a clear error" do
    payload = call_tool("get_pnl")
    # Empty test DB may have no synced reports — either a P&L payload or the
    # descriptive no-reports error is valid; both prove dispatch + envelope.
    assert(payload.key?("revenue") || payload.key?("error"))
  end
```

Run: `bin/rails test test/integration/mcp_endpoint_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/services/mcp/get_pnl_tool.rb app/services/mcp/server.rb \
        test/services/mcp/pnl_tool_test.rb test/integration/mcp_endpoint_test.rb
git commit -m "Add get_pnl MCP tool (persisted QBO P&L, never live-fetches)"
```

---

### Task 2: `get_capacity` tool

**Files:**
- Create: `app/services/mcp/get_capacity_tool.rb`
- Create: `test/services/mcp/capacity_tool_test.rb`
- Modify: `app/services/mcp/server.rb` (TOOLS array, 10 entries after Task 1)
- Modify: `test/integration/mcp_endpoint_test.rb` (tool-name array + round-trip)

**Interfaces:**
- Consumes: `ForecastPerson` (`.active` scope [`where.not(archived: true)`]; `#email`, `#first_name`, `#last_name`, `#id`), `ForecastPersonUtilizationReport` (`belongs_to :forecast_person`; `period_gradation` enum with keys `year/month/quarter/trailing_3_months/trailing_4_months/trailing_6_months/trailing_12_months`; columns `expected_hours_sold`/`expected_hours_unsold`/`actual_hours_sold`/`actual_hours_internal`/`actual_hours_time_off`/`utilization_rate` (decimals), `starts_at`/`ends_at`), `Studio` (`.all`; `#name`/`#mini_name`; `#forecast_people` → Array<ForecastPerson>). `Mcp::Responses.ok/.error`.
- Produces: the `get_capacity` MCP tool. Payload: `{ gradation, period: { starts_at, ends_at }, studio, benched_count, people: [{ person, sellable_hours, billable_hours, internal_hours, time_off_hours, unsold_hours, utilization_rate, benched }] }`.

- [ ] **Step 1: Confirm the enum + person label**

Run: `grep -n "enum period_gradation\|def email\|def name\|scope :active" app/models/forecast_person_utilization_report.rb app/models/forecast_person.rb`
Confirm the gradation enum keys and that `ForecastPerson#email` is the person label (name/display_name also return email). Use `email` for the `person` field. `.active` = `where.not(archived: true)`.

- [ ] **Step 2: Write the failing tests**

Create `test/services/mcp/capacity_tool_test.rb`:

```ruby
require 'test_helper'

class Mcp::CapacityToolTest < ActiveSupport::TestCase
  def person!(email:, archived: false)
    ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email,
                           archived: archived, data: {})
  end

  def util!(person:, starts_at:, ends_at:, gradation: 'month', unsold: 0.0,
            sold: 100.0, internal: 0.0, time_off: 0.0, rate: 0.9)
    ForecastPersonUtilizationReport.create!(
      forecast_person: person, starts_at: starts_at, ends_at: ends_at,
      period_gradation: gradation,
      expected_hours_sold: sold, expected_hours_unsold: unsold,
      actual_hours_sold: sold, actual_hours_internal: internal,
      actual_hours_time_off: time_off, actual_hours_sold_by_rate: {}, utilization_rate: rate
    )
  end

  test 'maps report columns to fields and flags benched people' do
    booked = person!(email: 'booked@sanctuary.computer')
    benched = person!(email: 'benched@sanctuary.computer')
    util!(person: booked, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30), unsold: 0.0, sold: 120.0)
    util!(person: benched, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30), unsold: 60.0, sold: 40.0)
    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    assert_equal 'month', payload['gradation']
    assert_equal '2026-06-30', payload['period']['ends_at']
    assert_equal 1, payload['benched_count']
    b = payload['people'].find { |p| p['person'] == 'benched@sanctuary.computer' }
    assert_equal true, b['benched']
    assert_equal 60.0, b['unsold_hours']
    assert_equal 40.0, b['billable_hours']
    bk = payload['people'].find { |p| p['person'] == 'booked@sanctuary.computer' }
    assert_equal false, bk['benched']
    persons = payload['people'].map { |p| p['person'] }
    assert_equal persons.sort, persons, 'people sorted by person'
  end

  test 'excludes archived people' do
    active = person!(email: 'active@sanctuary.computer')
    gone = person!(email: 'gone@sanctuary.computer', archived: true)
    util!(person: active, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30))
    util!(person: gone, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30))
    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    persons = payload['people'].map { |p| p['person'] }
    assert_includes persons, 'active@sanctuary.computer'
    refute_includes persons, 'gone@sanctuary.computer'
  end

  test 'uses the most recent period for the gradation' do
    p = person!(email: 'p@sanctuary.computer')
    util!(person: p, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31), sold: 1.0)
    util!(person: p, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30), sold: 2.0)
    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    assert_equal '2026-06-30', payload['period']['ends_at']
    assert_equal [2.0], payload['people'].map { |x| x['billable_hours'] }
  end

  test 'invalid gradation errors listing valid values' do
    payload = mcp_payload(Mcp::GetCapacityTool.call(gradation: 'weekly', server_context: {}))
    assert_includes payload['error'], "Invalid gradation 'weekly'"
    assert_includes payload['error'], 'trailing_3_months'
  end

  test 'unknown studio errors listing valid studios' do
    Studio.create!(name: 'Only Studio', mini_name: 'only')
    payload = mcp_payload(Mcp::GetCapacityTool.call(studio: 'nope', server_context: {}))
    assert_includes payload['error'], "Unknown studio 'nope'"
    assert_includes payload['error'], 'Only Studio'
  end

  test 'no reports for the period is a valid empty payload' do
    payload = mcp_payload(Mcp::GetCapacityTool.call(server_context: {}))
    assert_equal 0, payload['benched_count']
    assert_equal [], payload['people']
  end
end
```

NOTE: if `ForecastPersonUtilizationReport.create!` rejects any attribute, all columns are `null: false` per schema — the factory sets every one; adjust only if a validation (not just NOT NULL) demands more.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/services/mcp/capacity_tool_test.rb`
Expected: FAIL — `NameError: uninitialized constant Mcp::GetCapacityTool`.

- [ ] **Step 4: Implement the tool**

Create `app/services/mcp/get_capacity_tool.rb`:

```ruby
module Mcp
  class GetCapacityTool < MCP::Tool
    tool_name 'get_capacity'
    description 'Per-person capacity / resourcing from the nightly utilization reports: each ' \
                'active person\'s sellable / billable / internal / time-off / unsold hours, ' \
                'utilization rate, and whether they are benched (have unsold hours to staff). ' \
                'Reads persisted reports only — never calls Forecast live. This is resourcing ' \
                'data (who is free to staff), NOT compensation, HR, or 1:1 content.'
    input_schema(
      properties: {
        studio: { type: 'string', description: 'Optional studio name or mini_name; default all studios' },
        gradation: { type: 'string', description: 'month (default), quarter, year, trailing_3_months, trailing_4_months, trailing_6_months, trailing_12_months' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    GRADATIONS = ForecastPersonUtilizationReport.period_gradations.keys.freeze

    def self.call(studio: nil, gradation: 'month', server_context:)
      grad = gradation.to_s
      unless GRADATIONS.include?(grad)
        return Responses.error("Invalid gradation '#{grad}'. Valid: #{GRADATIONS.join(', ')}")
      end

      people = ForecastPerson.active.to_a
      studio_label = 'all'
      if studio.present?
        all_studios = Studio.all.to_a
        key = studio.to_s.strip
        match = all_studios.find { |s| s.name.to_s.casecmp?(key) } ||
                all_studios.find { |s| s.mini_name.to_s.split(',').map(&:strip).any? { |m| m.casecmp?(key) } }
        unless match
          valid = all_studios.map { |s| "#{s.name} (#{s.mini_name})" }.sort.join(', ')
          return Responses.error("Unknown studio '#{studio}'. Valid studios: #{valid}")
        end
        studio_label = match.name
        studio_person_ids = match.forecast_people.map(&:id).to_set
        people = people.select { |p| studio_person_ids.include?(p.id) }
      end

      reports = ForecastPersonUtilizationReport
        .where(forecast_person_id: people.map(&:id), period_gradation: grad)
      # Now-state: the most recent persisted period for this gradation.
      latest = reports.maximum(:ends_at)
      if latest.nil?
        return Responses.ok(gradation: grad, period: nil, studio: studio_label, benched_count: 0, people: [])
      end
      period_reports = reports.where(ends_at: latest).includes(:forecast_person)
      starts_at = period_reports.first.starts_at

      rows = period_reports.filter_map do |r|
        {
          person: r.forecast_person.email,
          sellable_hours: r.expected_hours_sold.to_f,
          billable_hours: r.actual_hours_sold.to_f,
          internal_hours: r.actual_hours_internal.to_f,
          time_off_hours: r.actual_hours_time_off.to_f,
          unsold_hours: r.expected_hours_unsold.to_f,
          utilization_rate: r.utilization_rate.to_f,
          benched: r.expected_hours_unsold.to_f.positive?,
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::GetCapacityTool] skipping utilization report id=#{r.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end.sort_by { |x| x[:person].to_s }

      Responses.ok(
        gradation: grad,
        period: { starts_at: starts_at.iso8601, ends_at: latest.iso8601 },
        studio: studio_label,
        benched_count: rows.count { |x| x[:benched] },
        people: rows
      )
    end
  end
end
```

Append `Mcp::GetCapacityTool,` to `TOOLS` in `app/services/mcp/server.rb`.

- [ ] **Step 5: Run unit tests to verify they pass**

Run: `bin/rails test test/services/mcp/capacity_tool_test.rb`
Expected: PASS (6 tests).

- [ ] **Step 6: Update the integration test**

Sorted tool-name array becomes:

```ruby
    assert_equal %w[get_ar_aging get_capacity get_document get_pnl get_studio_health list_documents list_open_admin_tasks list_overdue_invoices list_projects_at_risk list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
```

Add a round-trip test:

```ruby
  test "tools/call round-trip for get_capacity returns a valid payload" do
    payload = call_tool("get_capacity")
    assert payload.key?("people")
    assert payload.key?("benched_count")
  end
```

Run: `bin/rails test test/services/mcp/capacity_tool_test.rb test/integration/mcp_endpoint_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/services/mcp/get_capacity_tool.rb app/services/mcp/server.rb \
        test/services/mcp/capacity_tool_test.rb test/integration/mcp_endpoint_test.rb
git commit -m "Add get_capacity MCP tool (per-person utilization, resourcing-framed)"
```

---

### Task 3: Full-suite verification

**Files:** none new — fix only branch-caused fallout.

**Interfaces:**
- Consumes: everything from Tasks 1–2.
- Produces: a green suite (modulo the known pre-existing `AdminUserTest` date flake — classify, don't fix).

- [ ] **Step 1: Run the MCP suites**

Run: `bin/rails test test/services/mcp test/integration/mcp_endpoint_test.rb`
Expected: PASS.

- [ ] **Step 2: Run the full suite**

Run: `bin/rails test`
Expected: no new failures relative to `main`.

- [ ] **Step 3: Commit (only if fixes were needed)**

```bash
git add -A && git commit -m "Fix test fallout from get_pnl + get_capacity"
```
