# list_projects_at_risk + get_studio_health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two read-only MCP tools — `list_projects_at_risk` (ProjectTracker snapshots judged against each tracker's own targets) and `get_studio_health` (pure pass-through of the persisted `Studio#snapshot` rollup) — unblocking Stacksbot automation #2 (Business pre-read v1).

**Architecture:** Two thin presenter tools following the established one-file-per-tool pattern (`Mcp::Responses` envelope, read-only annotations, skip-with-warn+Sentry doctrine). No new queries beyond batch-preloaded model reads of already-computed nightly data.

**Tech Stack:** Rails, `mcp` Ruby gem, Minitest + mocha.

**Spec:** `docs/superpowers/specs/2026-07-05-mcp-business-tools-design.md`

## Global Constraints

- `annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)` on both tools; `Mcp::Responses.ok(payload)` / `.error(message)` envelope.
- Risk judgments reuse the model's own predicates — `!target_profit_margin_satisfied?`, `!target_free_hours_ratio_satisfied?` — never re-derive the comparisons. Only `over_budget` (`budget_high_end` present and `spend > budget_high_end`) lives in the tool.
- `get_studio_health` NEVER regenerates snapshots — pure read of the persisted jsonb. It must NOT include the period-level `utilization` key (a per-person email → hours map; that's `get_capacity`'s future surface). Pass through only `label`, `period_starts_at`, `period_ends_at`, and the chosen accounting method's `datapoints` + `okrs`, verbatim.
- Per-row mapping failures: skip + `Rails.logger.warn` + `Sentry.capture_exception(e)`, never fail the report. Unknown/invalid params → error payloads listing valid values.
- No schema changes, no new gems, no cache changes, no live external API calls.
- Tests: `bin/rails test <path>`; mocha available; `build_admin!` helper exists in test_helper (not needed here); worktree already has `config/master.key`. Do not modify initializers/credentials/unrelated code.
- Known pre-existing failure to ignore: `AdminUserTest` salary-window date flake (environment-date-sensitive).

---

### Task 1: `list_projects_at_risk` tool

**Files:**
- Create: `app/services/mcp/list_projects_at_risk_tool.rb`
- Create: `test/services/mcp/projects_at_risk_tool_test.rb`
- Modify: `app/services/mcp/server.rb` (TOOLS array, currently 7 entries)
- Modify: `test/integration/mcp_endpoint_test.rb` (tool-name array) — done in Task 2 alongside its own entry? NO — each task keeps the suite green independently: update the array here to include `list_projects_at_risk` (7→8 names happens across the two tasks; after this task the sorted array is `%w[get_ar_aging get_document list_documents list_open_admin_tasks list_overdue_invoices list_projects_at_risk list_sources search]`).

**Interfaces:**
- Consumes: `ProjectTracker` — `.preload_for_render(trackers)` (class method taking an array), `#work_status` (`:in_progress`/`:likely_complete`/`:complete`/`:capsule_pending`), `#snapshot` (jsonb hash), `#spend`, `#profit_margin`, `#free_hours_ratio`, `#target_profit_margin`, `#target_free_hours_percent`, `#target_profit_margin_satisfied?`, `#target_free_hours_ratio_satisfied?`, `#likely_complete?`, `#considered_successful?`, `#budget_low_end`/`#budget_high_end` (nullable numeric columns), `#external_link` (absolute admin URL). `Mcp::Responses.ok/.error`.
- Produces: the `list_projects_at_risk` MCP tool. Payload: `{ count:, projects: [{ name, work_status, spend, budget_low_end, budget_high_end, profit_margin, target_profit_margin, free_hours_percent, target_free_hours_percent, likely_complete, considered_successful, at_risk, risk_reasons, url }] }` sorted most-at-risk first (`[-risk_reasons.length, name]`).

- [ ] **Step 1: Discover the free-hours snapshot key**

Run: `grep -n "def total_free_hours" -A 3 app/models/project_tracker.rb`
Note the exact snapshot key it reads (e.g. `"free_hours_total"`) — use that key in the test helper below wherever `FREE_HOURS_KEY` appears. Also run `grep -n "def estimated_cost" -A 3 app/models/project_tracker.rb` to confirm the cost key (expected `"cost_total"`).

- [ ] **Step 2: Write the failing tests**

Create `test/services/mcp/projects_at_risk_tool_test.rb` (replace `FREE_HOURS_KEY` per Step 1):

```ruby
require 'test_helper'

class Mcp::ProjectsAtRiskToolTest < ActiveSupport::TestCase
  # Snapshot-backed tracker factory. Defaults produce a HEALTHY project:
  # margin 50% (>= target 30), free hours 0% (<= target 10), no budget.
  def tracker!(name:, spend: 1000.0, cost: 500.0, hours: 100.0, free_hours: 0.0,
               budget_high: nil, budget_low: nil, margin_target: 30, free_target: 10)
    ProjectTracker.create!(
      name: name,
      budget_low_end: budget_low,
      budget_high_end: budget_high,
      target_profit_margin: margin_target,
      target_free_hours_percent: free_target,
      snapshot: {
        'invoiced_with_running_spend_total' => spend,
        'cost_total' => cost,
        'hours_total' => hours,
        'FREE_HOURS_KEY' => free_hours,
      }
    )
  end

  def payload_for(resp)
    JSON.parse(resp.content.first[:text])
  end

  test 'flags margin below the tracker target with a named reason' do
    tracker!(name: 'Thin Margin', spend: 1000.0, cost: 900.0) # margin 10% < target 30
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    row = payload['projects'].find { |p| p['name'] == 'Thin Margin' }
    assert row['at_risk']
    assert_includes row['risk_reasons'], 'margin_below_target'
    assert_equal 10.0, row['profit_margin']
    assert_equal 30.0, row['target_profit_margin']
  end

  test 'flags free hours above the tracker target' do
    tracker!(name: 'Free Heavy', hours: 100.0, free_hours: 20.0, free_target: 10)
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    row = payload['projects'].find { |p| p['name'] == 'Free Heavy' }
    assert_includes row['risk_reasons'], 'free_hours_above_target'
    assert_equal 20.0, row['free_hours_percent']
  end

  test 'flags spend beyond budget_high_end only when a budget is set' do
    tracker!(name: 'Over Budget', spend: 5000.0, cost: 1000.0, budget_low: 1000.0, budget_high: 4000.0)
    tracker!(name: 'No Budget', spend: 5000.0, cost: 1000.0)
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    over = payload['projects'].find { |p| p['name'] == 'Over Budget' }
    assert_includes over['risk_reasons'], 'over_budget'
    assert_nil payload['projects'].find { |p| p['name'] == 'No Budget' }, 'healthy-but-unbudgeted project must not be flagged'
  end

  test 'only_at_risk: false returns healthy projects too, sorted most-at-risk first' do
    tracker!(name: 'Healthy One')
    tracker!(name: 'Doubly Risky', spend: 5000.0, cost: 4800.0, budget_high: 4000.0, budget_low: 1000.0)
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(only_at_risk: false, server_context: {}))
    names = payload['projects'].map { |p| p['name'] }
    assert_includes names, 'Healthy One'
    assert_equal 'Doubly Risky', names.first, 'most tripped criteria sorts first'
    healthy = payload['projects'].find { |p| p['name'] == 'Healthy One' }
    assert_equal false, healthy['at_risk']
    assert_equal [], healthy['risk_reasons']
  end

  test 'completed trackers are excluded by default and included with include_complete' do
    done = tracker!(name: 'Done Project', spend: 1000.0, cost: 900.0)
    done.update!(work_completed_at: Time.current)
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_nil payload['projects'].find { |p| p['name'] == 'Done Project' }
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(include_complete: true, server_context: {}))
    assert payload['projects'].find { |p| p['name'] == 'Done Project' }
  end

  test 'trackers with a blank snapshot are skipped with a warning, never raise' do
    ProjectTracker.create!(name: 'Unsnapshotted', target_profit_margin: 30, target_free_hours_percent: 10)
    tracker!(name: 'Thin Margin', spend: 1000.0, cost: 900.0)
    Rails.logger.expects(:warn).with { |msg| msg.include?('Unsnapshotted') }.at_least_once
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_nil payload['projects'].find { |p| p['name'] == 'Unsnapshotted' }
    assert_equal 1, payload['count']
  end

  test 'empty result is a valid payload' do
    payload = payload_for(Mcp::ListProjectsAtRiskTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['projects']
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/services/mcp/projects_at_risk_tool_test.rb`
Expected: FAIL — `NameError: uninitialized constant Mcp::ListProjectsAtRiskTool`. (If `ProjectTracker.create!` itself fails a validation in the factory, add the minimal missing attribute and note it — do not change the model.)

- [ ] **Step 4: Implement the tool**

Create `app/services/mcp/list_projects_at_risk_tool.rb`:

```ruby
module Mcp
  class ListProjectsAtRiskTool < MCP::Tool
    tool_name 'list_projects_at_risk'
    description 'Projects at risk, judged against each ProjectTracker\'s own configured targets ' \
                '(margin below target, free hours above target, spend beyond budget). Reads the ' \
                'nightly tracker snapshots — never live data. Sorted most-at-risk first.'
    input_schema(
      properties: {
        only_at_risk: { type: 'boolean', description: 'Default true. When false, returns every project in scope with metrics + targets.' },
        include_complete: { type: 'boolean', description: 'Default false. Include completed / capsule-pending projects.' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    ACTIVE_STATUSES = %i[in_progress likely_complete].freeze

    def self.call(only_at_risk: true, include_complete: false, server_context:)
      trackers = ProjectTracker.all.to_a
      ProjectTracker.preload_for_render(trackers)

      rows = trackers.filter_map do |pt|
        status = pt.work_status
        next nil unless include_complete || ACTIVE_STATUSES.include?(status)
        if pt.snapshot.blank?
          Rails.logger.warn("[Mcp::ListProjectsAtRiskTool] skipping '#{pt.name}' (id=#{pt.id}): no snapshot")
          next nil
        end

        # Risk = the tracker's own targets, via the model's own predicates
        # (single source of truth with considered_successful?). Only the
        # budget comparison lives here — no model predicate exists for it.
        reasons = []
        reasons << 'margin_below_target' unless pt.target_profit_margin_satisfied?
        reasons << 'free_hours_above_target' unless pt.target_free_hours_ratio_satisfied?
        reasons << 'over_budget' if pt.budget_high_end.present? && pt.spend > pt.budget_high_end.to_f

        {
          name: pt.name,
          work_status: status,
          spend: pt.spend.round(2),
          budget_low_end: pt.budget_low_end&.to_f,
          budget_high_end: pt.budget_high_end&.to_f,
          profit_margin: pt.profit_margin.round(1),
          target_profit_margin: pt.target_profit_margin.to_f,
          free_hours_percent: (pt.free_hours_ratio * 100).round(1),
          target_free_hours_percent: pt.target_free_hours_percent.to_f,
          likely_complete: pt.likely_complete?,
          considered_successful: pt.considered_successful?,
          at_risk: reasons.any?,
          risk_reasons: reasons,
          url: pt.external_link,
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::ListProjectsAtRiskTool] skipping tracker id=#{pt.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e)
        nil
      end

      rows = rows.select { |r| r[:at_risk] } if only_at_risk
      rows = rows.sort_by { |r| [-r[:risk_reasons].length, r[:name].to_s] }

      Responses.ok({ count: rows.length, projects: rows })
    end
  end
end
```

Append `Mcp::ListProjectsAtRiskTool,` to `TOOLS` in `app/services/mcp/server.rb`.

- [ ] **Step 5: Run unit tests to verify they pass**

Run: `bin/rails test test/services/mcp/projects_at_risk_tool_test.rb`
Expected: PASS (7 tests).

- [ ] **Step 6: Update the integration tool-name array**

In `test/integration/mcp_endpoint_test.rb`, the sorted array assertion becomes:

```ruby
    assert_equal %w[get_ar_aging get_document list_documents list_open_admin_tasks list_overdue_invoices list_projects_at_risk list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
```

Add a round-trip test (mirror the existing `list_open_admin_tasks` round-trip in the same file for envelope/headers):

```ruby
  test "tools/call round-trip for list_projects_at_risk returns a valid payload" do
    post "/api/mcp",
      headers: api_key_headers,
      params: {
        jsonrpc: "2.0", id: 11, method: "tools/call",
        params: { name: "list_projects_at_risk", arguments: {} },
      }.to_json
    assert_response :success
    text = JSON.parse(response.body).dig("result", "content", 0, "text")
    payload = JSON.parse(text)
    assert payload.key?("count")
    assert payload.key?("projects")
  end
```

Run: `bin/rails test test/integration/mcp_endpoint_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/services/mcp/list_projects_at_risk_tool.rb app/services/mcp/server.rb \
        test/services/mcp/projects_at_risk_tool_test.rb test/integration/mcp_endpoint_test.rb
git commit -m "Add list_projects_at_risk MCP tool (tracker-target risk judgments)"
```

---

### Task 2: `get_studio_health` tool

**Files:**
- Create: `app/services/mcp/get_studio_health_tool.rb`
- Create: `test/services/mcp/studio_health_tool_test.rb`
- Modify: `app/services/mcp/server.rb` (TOOLS array, 8 entries after Task 1)
- Modify: `test/integration/mcp_endpoint_test.rb` (array gains `get_studio_health`; sorted: `%w[get_ar_aging get_document get_studio_health list_documents list_open_admin_tasks list_overdue_invoices list_projects_at_risk list_sources search]`) + one round-trip test.

**Interfaces:**
- Consumes: `Studio` — `#name`, `#mini_name`, `#snapshot` (jsonb: gradation string keys → array of period entries, each `{ 'label', 'period_starts_at', 'period_ends_at', 'cash' => { 'datapoints', 'okrs' }, 'accrual' => {...}, 'utilization' => <per-person map — MUST NOT be emitted> }`; also top-level `started_at`/`finished_at` strings — ignore). `Mcp::Responses.ok/.error`.
- Produces: the `get_studio_health` MCP tool. Payload: `{ studios: [{ studio, mini_name, gradation, accounting_method, periods: [{ label, period_starts_at, period_ends_at, datapoints, okrs }] }] }` — `datapoints`/`okrs` passed through verbatim.

- [ ] **Step 1: Write the failing tests**

Create `test/services/mcp/studio_health_tool_test.rb`:

```ruby
require 'test_helper'

class Mcp::StudioHealthToolTest < ActiveSupport::TestCase
  def period_entry(label, income:, okr_health: 'healthy')
    {
      'label' => label,
      'period_starts_at' => '01/01/2026',
      'period_ends_at' => '01/31/2026',
      'cash' => {
        'datapoints' => { 'income' => { 'value' => income, 'unit' => 'usd' },
                          'lead_count' => { 'value' => 3, 'unit' => 'count' } },
        'okrs' => { 'Profit Margin' => { 'health' => okr_health, 'target' => 30 } },
      },
      'accrual' => {
        'datapoints' => { 'income' => { 'value' => income + 1, 'unit' => 'usd' } },
        'okrs' => {},
      },
      'utilization' => { 'someone@sanctuary.computer' => { 'billable' => 120 } },
    }
  end

  def studio!(name:, mini_name:, periods: 2)
    Studio.create!(
      name: name, mini_name: mini_name,
      snapshot: { 'month' => (1..periods).map { |i| period_entry("2026-%02d" % i, income: i * 1000) } }
    )
  end

  def payload_for(resp)
    JSON.parse(resp.content.first[:text])
  end

  test 'passes the chosen accounting subtree through verbatim, excluding per-person utilization' do
    studio!(name: 'Sanctuary Test', mini_name: 'sanc')
    payload = payload_for(Mcp::GetStudioHealthTool.call(studio: 'sanc', server_context: {}))
    s = payload['studios'].first
    assert_equal 'Sanctuary Test', s['studio']
    assert_equal 'month', s['gradation']
    assert_equal 'cash', s['accounting_method']
    period = s['periods'].last
    assert_equal({ 'value' => 2000, 'unit' => 'usd' }, period['datapoints']['income'])
    assert_equal 'healthy', period['okrs']['Profit Margin']['health']
    assert_nil period['utilization'], 'per-person utilization must never be emitted'
    refute s['periods'].first.key?('utilization')
  end

  test 'accrual accounting_method selects the accrual subtree' do
    studio!(name: 'Accrual Studio', mini_name: 'accr')
    payload = payload_for(Mcp::GetStudioHealthTool.call(studio: 'accr', accounting_method: 'accrual', server_context: {}))
    assert_equal 2001, payload['studios'].first['periods'].last['datapoints']['income']['value']
  end

  test 'periods param takes the most recent N' do
    studio!(name: 'Many Periods', mini_name: 'many', periods: 10)
    payload = payload_for(Mcp::GetStudioHealthTool.call(studio: 'many', periods: 3, server_context: {}))
    labels = payload['studios'].first['periods'].map { |p| p['label'] }
    assert_equal %w[2026-08 2026-09 2026-10], labels
  end

  test 'unknown studio errors listing valid studios; invalid gradation and accounting_method error' do
    studio!(name: 'Only Studio', mini_name: 'only')
    err = payload_for(Mcp::GetStudioHealthTool.call(studio: 'nope', server_context: {}))
    assert_includes err['error'], "Unknown studio 'nope'"
    assert_includes err['error'], 'Only Studio'
    err = payload_for(Mcp::GetStudioHealthTool.call(gradation: 'weekly', server_context: {}))
    assert_includes err['error'], "Invalid gradation 'weekly'"
    err = payload_for(Mcp::GetStudioHealthTool.call(accounting_method: 'both', server_context: {}))
    assert_includes err['error'], "Invalid accounting_method 'both'"
  end

  test 'listing all skips snapshotless studios with a warning; explicit request errors' do
    studio!(name: 'Has Snapshot', mini_name: 'has')
    Studio.create!(name: 'No Snapshot', mini_name: 'none')
    Rails.logger.expects(:warn).with { |msg| msg.include?('No Snapshot') }.at_least_once
    payload = payload_for(Mcp::GetStudioHealthTool.call(server_context: {}))
    assert_equal ['Has Snapshot'], payload['studios'].map { |s| s['studio'] }
    err = payload_for(Mcp::GetStudioHealthTool.call(studio: 'none', server_context: {}))
    assert_includes err['error'], 'no generated snapshot'
  end
end
```

NOTE: if `Studio.create!` requires more attributes (check validations/DB constraints if it fails), add the minimal ones — do not change the model. If existing Studio fixtures/records exist in the test DB, scope assertions by the created names (they already are).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/mcp/studio_health_tool_test.rb`
Expected: FAIL — `NameError: uninitialized constant Mcp::GetStudioHealthTool`.

- [ ] **Step 3: Implement the tool**

Create `app/services/mcp/get_studio_health_tool.rb`:

```ruby
module Mcp
  class GetStudioHealthTool < MCP::Tool
    tool_name 'get_studio_health'
    description 'Per-studio health rollups from the nightly Studio snapshot: financial datapoints ' \
                '(income, cogs, net operating income, profit margin), utilization hours, lead counts, ' \
                'satisfaction scores, and OKR health per period. Pure read of the persisted rollup — ' \
                'figures always match Stacks\' own reporting. Never regenerates, never calls live APIs.'
    input_schema(
      properties: {
        studio: { type: 'string', description: 'Optional studio name or mini_name (case-insensitive). Default: all studios with a snapshot.' },
        gradation: { type: 'string', description: 'month (default), quarter, year, trailing_3_months, trailing_4_months, trailing_6_months, trailing_12_months' },
        accounting_method: { type: 'string', description: 'cash (default) or accrual' },
        periods: { type: 'integer', description: 'Most recent N periods (default 6, clamped 1..24)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    GRADATIONS = %w[month quarter year trailing_3_months trailing_4_months trailing_6_months trailing_12_months].freeze
    ACCOUNTING_METHODS = %w[cash accrual].freeze

    def self.call(studio: nil, gradation: 'month', accounting_method: 'cash', periods: 6, server_context:)
      gradation = gradation.to_s
      unless GRADATIONS.include?(gradation)
        return Responses.error("Invalid gradation '#{gradation}'. Valid gradations: #{GRADATIONS.join(', ')}")
      end
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end
      recent = periods.to_i.clamp(1, 24)

      all_studios = Studio.all.to_a
      requested =
        if studio.present?
          key = studio.to_s.strip
          match = all_studios.find { |s| s.name.casecmp?(key) || s.mini_name.to_s.casecmp?(key) }
          unless match
            valid = all_studios.map { |s| "#{s.name} (#{s.mini_name})" }.sort.join(', ')
            return Responses.error("Unknown studio '#{studio}'. Valid studios: #{valid}")
          end
          if match.snapshot.blank? || match.snapshot[gradation].blank?
            return Responses.error("Studio '#{match.name}' has no generated snapshot for gradation '#{gradation}' yet.")
          end
          [match]
        else
          all_studios
        end

      studios_payload = requested.filter_map do |s|
        entries = s.snapshot.presence && s.snapshot[gradation]
        if entries.blank?
          Rails.logger.warn("[Mcp::GetStudioHealthTool] skipping studio '#{s.name}': no snapshot data for '#{gradation}'") if studio.blank?
          next nil
        end

        # Pass label/dates + the chosen accounting subtree (datapoints + okrs)
        # through VERBATIM — re-mapping invites drift from the canonical
        # computed shape. The period-level 'utilization' key is deliberately
        # excluded: it is a per-person email → hours map (get_capacity's
        # future surface), not a studio rollup.
        {
          studio: s.name,
          mini_name: s.mini_name,
          gradation: gradation,
          accounting_method: method,
          periods: Array(entries).last(recent).map do |entry|
            {
              label: entry['label'],
              period_starts_at: entry['period_starts_at'],
              period_ends_at: entry['period_ends_at'],
              datapoints: entry.dig(method, 'datapoints'),
              okrs: entry.dig(method, 'okrs'),
            }
          end,
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::GetStudioHealthTool] skipping studio '#{s.name}': #{e.class}: #{e.message}")
        Sentry.capture_exception(e)
        nil
      end

      Responses.ok({ studios: studios_payload })
    end
  end
end
```

Append `Mcp::GetStudioHealthTool,` to `TOOLS` in `app/services/mcp/server.rb`.

- [ ] **Step 4: Run unit tests to verify they pass**

Run: `bin/rails test test/services/mcp/studio_health_tool_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Update the integration tool-name array + round-trip**

Sorted array becomes:

```ruby
    assert_equal %w[get_ar_aging get_document get_studio_health list_documents list_open_admin_tasks list_overdue_invoices list_projects_at_risk list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
```

Round-trip test (empty test DB has no studios — a valid empty payload):

```ruby
  test "tools/call round-trip for get_studio_health returns a valid payload" do
    post "/api/mcp",
      headers: api_key_headers,
      params: {
        jsonrpc: "2.0", id: 12, method: "tools/call",
        params: { name: "get_studio_health", arguments: { gradation: "month" } },
      }.to_json
    assert_response :success
    text = JSON.parse(response.body).dig("result", "content", 0, "text")
    payload = JSON.parse(text)
    assert payload.key?("studios")
  end
```

Run: `bin/rails test test/services/mcp/studio_health_tool_test.rb test/integration/mcp_endpoint_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/mcp/get_studio_health_tool.rb app/services/mcp/server.rb \
        test/services/mcp/studio_health_tool_test.rb test/integration/mcp_endpoint_test.rb
git commit -m "Add get_studio_health MCP tool (verbatim snapshot rollup pass-through)"
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
git add -A && git commit -m "Fix test fallout from business-tools MCP slice"
```
