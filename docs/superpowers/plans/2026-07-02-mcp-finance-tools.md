# MCP Finance Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two read-only MCP tools — `get_ar_aging` and `list_overdue_invoices` — to Stacks' `/api/mcp` surface, unblocking the Stacksbot Ops pre-read automation.

**Architecture:** Two tool classes following the existing one-file-per-tool pattern in `app/services/mcp/`, sharing a small `Mcp::QboReceivables` scoping module, registered in `Mcp::Server::TOOLS`. All reads come from already-synced `QboInvoice` jsonb rows; aging buckets and overdue status are computed at call time.

**Tech Stack:** Rails, `mcp` Ruby gem v0.22.0, Minitest + mocha, PostgreSQL jsonb.

**Spec:** `docs/superpowers/specs/2026-07-02-mcp-finance-tools-design.md`

## Global Constraints

- `/api/mcp` is read-only forever: every tool sets `annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)`.
- **A tool call must NEVER trigger a live QBO request.** `QboInvoice#data` lazily calls `sync!` when the stored jsonb is empty (`app/models/qbo_invoice.rb:50-54`), so every query must exclude unsynced rows **in SQL** before any model accessor touches `data`.
- No schema changes, no new syncs, no new gems, no new auth.
- Response convention (match the four existing tools): one content item, `MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])`.
- Late fees are a per-client human decision — expose `days_overdue` + `status`, never a policy flag.
- Malformed synced rows are skipped, never raise mid-report. Unknown `enterprise` param returns an error payload (not an exception) listing valid names.
- Tests run with `bin/rails test <path>`. mocha is available via `test/test_helper.rb`.

---

### Task 1: `Mcp::QboReceivables` + `get_ar_aging` tool

**Files:**
- Create: `app/services/mcp/qbo_receivables.rb`
- Create: `app/services/mcp/get_ar_aging_tool.rb`
- Create: `test/services/mcp/finance_tools_test.rb`
- Modify: `app/services/mcp/server.rb` (TOOLS array, currently 4 entries)
- Modify: `test/integration/mcp_endpoint_test.rb:48-49` (hard-coded sorted tool-name array)

**Interfaces:**
- Consumes: `QboInvoice` (accessors `#email_status`, `#balance`, `#total`, `#due_date`, `#customer_ref`, `#status`, `#display_name`, `#qbo_invoice_link`), `Enterprise.joins(:qbo_account)` (qbo_accounts has `enterprise_id`), fixtures `enterprises(:sanctuary)` ("Sanctuary Computer Inc") and `qbo_accounts(:one)`/`qbo_accounts(:two)` (both belong to sanctuary).
- Produces (Task 2 relies on these exact signatures):
  - `Mcp::QboReceivables.resolve_enterprises(name) → [enterprises_array, nil] | [nil, error_string]`
  - `Mcp::QboReceivables.receivables(enterprise) → Array<QboInvoice>` (synced + EmailSent + balance > 0)
  - `Mcp::QboReceivables.days_overdue(invoice, as_of) → Integer`
  - `Mcp::QboReceivables.bucket_key(days_overdue) → String` ("current" | "days_0_30" | "days_31_60" | "days_61_90" | "days_90_plus")
  - `Mcp::QboReceivables.error_response(message) → MCP::Tool::Response`

- [ ] **Step 1: Write the failing tests**

Create `test/services/mcp/finance_tools_test.rb`:

```ruby
require 'test_helper'

class Mcp::FinanceToolsTest < ActiveSupport::TestCase
  setup do
    @sanctuary = enterprises(:sanctuary)
    @account = qbo_accounts(:one)
  end

  # Minimal synced-invoice factory mirroring the jsonb shape QboInvoice
  # accessors read (see app/models/qbo_invoice.rb).
  def invoice!(doc:, due:, balance:, total: nil, customer: 'Acme Co',
               email_status: 'EmailSent', account: @account)
    QboInvoice.create!(
      qbo_account: account,
      qbo_id: "inv-#{doc}",
      data: {
        'doc_number' => doc,
        'email_status' => email_status,
        'due_date' => due.iso8601,
        'balance' => balance,
        'total' => total || balance,
        'customer_ref' => { 'name' => customer },
      }
    )
  end

  def payload_for(resp)
    JSON.parse(resp.content.first[:text])
  end

  # --- get_ar_aging ---

  test 'get_ar_aging buckets balances by days overdue with correct boundaries' do
    today = Date.today
    invoice!(doc: 'a', due: today, balance: 10.0)           # 0 days  -> current
    invoice!(doc: 'b', due: today - 30, balance: 20.0)      # 30 days -> days_0_30
    invoice!(doc: 'c', due: today - 31, balance: 40.0)      # 31 days -> days_31_60
    invoice!(doc: 'd', due: today - 90, balance: 80.0)      # 90 days -> days_61_90
    invoice!(doc: 'e', due: today - 91, balance: 160.0)     # 91 days -> days_90_plus

    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    ent = payload['enterprises'].find { |e| e['enterprise'] == @sanctuary.name }
    acme = ent['customers'].find { |c| c['customer'] == 'Acme Co' }

    assert_equal 10.0, acme['current']
    assert_equal 20.0, acme['days_0_30']
    assert_equal 40.0, acme['days_31_60']
    assert_equal 80.0, acme['days_61_90']
    assert_equal 160.0, acme['days_90_plus']
    assert_equal 310.0, acme['total']
    assert_equal 310.0, ent['total_ar']
    assert_equal 310.0, payload['total_ar']
    assert_equal Date.today.iso8601, payload['as_of']
  end

  test 'get_ar_aging sums outstanding balance, not invoice total' do
    invoice!(doc: 'p', due: Date.today - 10, balance: 500.0, total: 1000.0)
    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    acme = payload['enterprises'].first['customers'].first
    assert_equal 500.0, acme['days_0_30']
    assert_equal 500.0, acme['total']
  end

  test 'get_ar_aging excludes paid, unsent, and unsynced invoices — and never syncs' do
    invoice!(doc: 'live', due: Date.today - 5, balance: 100.0)
    invoice!(doc: 'paid', due: Date.today - 5, balance: 0.0, total: 300.0)
    invoice!(doc: 'draft', due: Date.today - 5, balance: 50.0, email_status: 'NotSet')
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-unsynced', data: nil)

    QboInvoice.any_instance.expects(:sync!).never
    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 100.0, payload['total_ar']
  end

  test 'get_ar_aging groups by enterprise and scopes by the enterprise param' do
    other = QboAccount.create!(enterprise: enterprises(:one), client_id: 'x',
                               client_secret: 'x', realm_id: 'realm-other')
    invoice!(doc: 's1', due: Date.today - 5, balance: 100.0)
    invoice!(doc: 'o1', due: Date.today - 5, balance: 999.0, account: other,
             customer: 'Other Client')

    all = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 1099.0, all['total_ar']
    assert_equal 2, all['enterprises'].length

    scoped = payload_for(Mcp::GetArAgingTool.call(
      enterprise: 'sanctuary computer inc', server_context: {}))
    assert_equal 100.0, scoped['total_ar']
    assert_equal [@sanctuary.name], scoped['enterprises'].map { |e| e['enterprise'] }
  end

  test 'get_ar_aging returns an error payload for an unknown enterprise' do
    payload = payload_for(Mcp::GetArAgingTool.call(enterprise: 'Nope Inc', server_context: {}))
    assert_includes payload['error'], "Unknown enterprise 'Nope Inc'"
    assert_includes payload['error'], @sanctuary.name
  end

  test 'get_ar_aging returns an empty report when there are no receivables' do
    payload = payload_for(Mcp::GetArAgingTool.call(server_context: {}))
    assert_equal 0, payload['total_ar']
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/mcp/finance_tools_test.rb`
Expected: FAIL — every test errors with `NameError: uninitialized constant Mcp::GetArAgingTool`.

- [ ] **Step 3: Implement the shared module and the tool**

Create `app/services/mcp/qbo_receivables.rb`:

```ruby
module Mcp
  # Shared read-only scoping for the AR tools. CRITICAL: QboInvoice#data
  # lazily re-fetches from the QBO API when the stored jsonb is empty, so
  # every query here must exclude unsynced rows in SQL — a tool call must
  # never trigger a live network request.
  module QboReceivables
    SYNCED_ROWS_SQL =
      "qbo_invoices.data IS NOT NULL AND qbo_invoices.data <> '{}'::jsonb " \
      "AND qbo_invoices.data->>'due_date' IS NOT NULL".freeze

    def self.resolve_enterprises(name)
      scope = Enterprise.joins(:qbo_account).distinct
      return [scope.to_a, nil] if name.blank?
      matches = scope.where('LOWER(enterprises.name) = ?', name.to_s.downcase).to_a
      return [matches, nil] if matches.any?
      valid = scope.pluck(:name).sort
      [nil, "Unknown enterprise '#{name}'. Valid enterprises: #{valid.join(', ')}"]
    end

    def self.receivables(enterprise)
      QboInvoice
        .joins(:qbo_account)
        .where(qbo_accounts: { enterprise_id: enterprise.id })
        .where(SYNCED_ROWS_SQL)
        .select { |inv| inv.email_status == 'EmailSent' && inv.balance.positive? }
    end

    def self.days_overdue(invoice, as_of = Date.today)
      (as_of - invoice.due_date).to_i
    end

    def self.bucket_key(days_overdue)
      return 'current' if days_overdue <= 0
      return 'days_0_30' if days_overdue <= 30
      return 'days_31_60' if days_overdue <= 60
      return 'days_61_90' if days_overdue <= 90
      'days_90_plus'
    end

    def self.error_response(message)
      MCP::Tool::Response.new([{ type: 'text', text: { error: message }.to_json }])
    end
  end
end
```

Create `app/services/mcp/get_ar_aging_tool.rb`:

```ruby
module Mcp
  class GetArAgingTool < MCP::Tool
    tool_name 'get_ar_aging'
    description 'AR aging buckets (current/0-30/31-60/61-90/90+ days overdue) per customer ' \
                'per enterprise, computed from already-synced QBO invoices. Never calls QBO live.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Optional enterprise name filter, e.g. "Sanctuary Computer Inc"' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    BUCKETS = %w[current days_0_30 days_31_60 days_61_90 days_90_plus].freeze

    def self.call(enterprise: nil, server_context:)
      enterprises, error = QboReceivables.resolve_enterprises(enterprise)
      return QboReceivables.error_response(error) if error

      as_of = Date.today
      enterprise_payloads = enterprises.map do |ent|
        customers = Hash.new { |h, k| h[k] = BUCKETS.index_with { 0.0 }.merge('total' => 0.0) }
        QboReceivables.receivables(ent).each do |inv|
          bucket = QboReceivables.bucket_key(QboReceivables.days_overdue(inv, as_of))
          row = customers[inv.customer_ref['name'] || 'Unknown']
          row[bucket] += inv.balance
          row['total'] += inv.balance
        rescue StandardError
          next # malformed synced row — skip it, never fail the whole report
        end
        rows = customers.map do |name, row|
          { 'customer' => name }.merge(row.transform_values { |v| v.round(2) })
        end
        {
          enterprise: ent.name,
          customers: rows.sort_by { |r| -r['total'] },
          total_ar: rows.sum { |r| r['total'] }.round(2),
        }
      end

      payload = {
        as_of: as_of.iso8601,
        enterprises: enterprise_payloads,
        total_ar: enterprise_payloads.sum { |e| e[:total_ar] }.round(2),
      }
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
```

Modify `app/services/mcp/server.rb` — add the tool to the registry:

```ruby
    TOOLS = [
      Mcp::SearchTool,
      Mcp::ListDocumentsTool,
      Mcp::ListSourcesTool,
      Mcp::GetDocumentTool,
      Mcp::GetArAgingTool,
    ].freeze
```

- [ ] **Step 4: Run the unit tests to verify they pass**

Run: `bin/rails test test/services/mcp/finance_tools_test.rb`
Expected: PASS (7 tests). If `QboAccount.create!` in the scoping test fails a validation, mirror the attributes used in `test/fixtures/qbo_accounts.yml` (`client_id`, `client_secret`, `realm_id`, `enterprise`) — those are the only fixture attributes.

- [ ] **Step 5: Update the integration test's hard-coded tool list**

In `test/integration/mcp_endpoint_test.rb` (~line 48), change:

```ruby
    assert_equal %w[get_document list_documents list_sources search], tool_names.sort,
      "Expected all four tools registered, got: #{tool_names.inspect}"
```

to:

```ruby
    assert_equal %w[get_ar_aging get_document list_documents list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
```

Run: `bin/rails test test/integration/mcp_endpoint_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/mcp/qbo_receivables.rb app/services/mcp/get_ar_aging_tool.rb \
        app/services/mcp/server.rb test/services/mcp/finance_tools_test.rb \
        test/integration/mcp_endpoint_test.rb
git commit -m "Add get_ar_aging MCP tool (AR buckets from synced QBO invoices)"
```

---

### Task 2: `list_overdue_invoices` tool

**Files:**
- Create: `app/services/mcp/list_overdue_invoices_tool.rb`
- Modify: `test/services/mcp/finance_tools_test.rb` (append tests; `invoice!`/`payload_for` helpers already exist there)
- Modify: `app/services/mcp/server.rb` (TOOLS array, 5 entries after Task 1)
- Modify: `test/integration/mcp_endpoint_test.rb` (tool-name array, 5 names after Task 1)

**Interfaces:**
- Consumes (from Task 1): `Mcp::QboReceivables.resolve_enterprises(name)`, `.receivables(enterprise)`, `.days_overdue(invoice, as_of)`, `.error_response(message)`; test helpers `invoice!(doc:, due:, balance:, total:, customer:, email_status:, account:)` and `payload_for(resp)` in `Mcp::FinanceToolsTest`.
- Produces: the `list_overdue_invoices` MCP tool. Payload: `{ as_of:, count:, invoices: [{ doc_number, customer, enterprise, total, balance, due_date, days_overdue, status, qbo_invoice_link, display_name }] }`, sorted most-overdue first.

- [ ] **Step 1: Write the failing tests**

Append inside `class Mcp::FinanceToolsTest` in `test/services/mcp/finance_tools_test.rb`:

```ruby
  # --- list_overdue_invoices ---

  test 'list_overdue_invoices returns overdue rows sorted most-overdue first' do
    invoice!(doc: '10', due: Date.today - 5, balance: 100.0)
    invoice!(doc: '11', due: Date.today - 45, balance: 200.0, customer: 'Beta LLC')
    invoice!(doc: '12', due: Date.today + 5, balance: 300.0)   # not overdue
    invoice!(doc: '13', due: Date.today - 20, balance: 150.0, total: 400.0) # partially paid overdue

    payload = payload_for(Mcp::ListOverdueInvoicesTool.call(server_context: {}))
    assert_equal 3, payload['count']
    assert_equal %w[11 13 10], payload['invoices'].map { |i| i['doc_number'] }

    top = payload['invoices'].first
    assert_equal 'Beta LLC', top['customer']
    assert_equal @sanctuary.name, top['enterprise']
    assert_equal 45, top['days_overdue']
    assert_equal 'unpaid_overdue', top['status']
    assert_equal (Date.today - 45).iso8601, top['due_date']
    assert_match %r{https://app\.qbo\.intuit\.com/app/invoice\?txnId=}, top['qbo_invoice_link']
    assert top['display_name'].present?

    partial = payload['invoices'].find { |i| i['doc_number'] == '13' }
    assert_equal 'partially_paid_overdue', partial['status']
    assert_equal 150.0, partial['balance']
    assert_equal 400.0, partial['total']
  end

  test 'list_overdue_invoices honors min_days_overdue' do
    invoice!(doc: '20', due: Date.today - 5, balance: 100.0)
    invoice!(doc: '21', due: Date.today - 40, balance: 200.0)

    payload = payload_for(Mcp::ListOverdueInvoicesTool.call(min_days_overdue: 30, server_context: {}))
    assert_equal %w[21], payload['invoices'].map { |i| i['doc_number'] }
  end

  test 'list_overdue_invoices scopes by enterprise and rejects unknown names' do
    other = QboAccount.create!(enterprise: enterprises(:one), client_id: 'x',
                               client_secret: 'x', realm_id: 'realm-other2')
    invoice!(doc: '30', due: Date.today - 5, balance: 100.0)
    invoice!(doc: '31', due: Date.today - 5, balance: 200.0, account: other)

    scoped = payload_for(Mcp::ListOverdueInvoicesTool.call(
      enterprise: @sanctuary.name, server_context: {}))
    assert_equal %w[30], scoped['invoices'].map { |i| i['doc_number'] }

    err = payload_for(Mcp::ListOverdueInvoicesTool.call(enterprise: 'Nope Inc', server_context: {}))
    assert_includes err['error'], "Unknown enterprise 'Nope Inc'"
  end

  test 'list_overdue_invoices skips unsynced rows without syncing' do
    QboInvoice.create!(qbo_account: @account, qbo_id: 'inv-unsynced-2', data: nil)
    QboInvoice.any_instance.expects(:sync!).never
    payload = payload_for(Mcp::ListOverdueInvoicesTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['invoices']
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/mcp/finance_tools_test.rb`
Expected: the 4 new tests FAIL with `NameError: uninitialized constant Mcp::ListOverdueInvoicesTool`; the 7 Task-1 tests still PASS.

- [ ] **Step 3: Implement the tool**

Create `app/services/mcp/list_overdue_invoices_tool.rb`:

```ruby
module Mcp
  class ListOverdueInvoicesTool < MCP::Tool
    tool_name 'list_overdue_invoices'
    description 'Overdue (unpaid or partially-paid) QBO invoices with days overdue, sorted ' \
                'most-overdue first, from already-synced rows. Never calls QBO live. Late fees ' \
                'are a per-client human decision — this tool exposes the data only.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Optional enterprise name filter, e.g. "Sanctuary Computer Inc"' },
        min_days_overdue: { type: 'integer', description: 'Only invoices at least this many days overdue (default 1)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    OVERDUE_STATUSES = %i[unpaid_overdue partially_paid_overdue].freeze

    def self.call(enterprise: nil, min_days_overdue: 1, server_context:)
      enterprises, error = QboReceivables.resolve_enterprises(enterprise)
      return QboReceivables.error_response(error) if error

      as_of = Date.today
      invoices = enterprises.flat_map do |ent|
        QboReceivables.receivables(ent).filter_map do |inv|
          next unless OVERDUE_STATUSES.include?(inv.status)
          days = QboReceivables.days_overdue(inv, as_of)
          next if days < min_days_overdue.to_i
          {
            doc_number: inv.data['doc_number'],
            customer: inv.customer_ref['name'],
            enterprise: ent.name,
            total: inv.total,
            balance: inv.balance,
            due_date: inv.due_date.iso8601,
            days_overdue: days,
            status: inv.status,
            qbo_invoice_link: inv.qbo_invoice_link,
            display_name: inv.display_name,
          }
        rescue StandardError
          nil # malformed synced row — skip it, never fail the whole report
        end
      end.sort_by { |row| -row[:days_overdue] }

      payload = { as_of: as_of.iso8601, count: invoices.length, invoices: invoices }
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
```

Modify `app/services/mcp/server.rb`:

```ruby
    TOOLS = [
      Mcp::SearchTool,
      Mcp::ListDocumentsTool,
      Mcp::ListSourcesTool,
      Mcp::GetDocumentTool,
      Mcp::GetArAgingTool,
      Mcp::ListOverdueInvoicesTool,
    ].freeze
```

Modify `test/integration/mcp_endpoint_test.rb` tool-name assertion:

```ruby
    assert_equal %w[get_ar_aging get_document list_documents list_overdue_invoices list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/mcp/finance_tools_test.rb test/integration/mcp_endpoint_test.rb`
Expected: PASS (11 unit tests + integration).

- [ ] **Step 5: Commit**

```bash
git add app/services/mcp/list_overdue_invoices_tool.rb app/services/mcp/server.rb \
        test/services/mcp/finance_tools_test.rb test/integration/mcp_endpoint_test.rb
git commit -m "Add list_overdue_invoices MCP tool (backs Ops pre-read late-fee review)"
```

---

### Task 3: Full-suite verification

**Files:**
- No new files. Fix any fallout the full suite surfaces (most likely: none — the change is additive).

**Interfaces:**
- Consumes: everything from Tasks 1–2.
- Produces: a green suite; the branch is ready for review/merge.

- [ ] **Step 1: Run the MCP-adjacent suites**

Run: `bin/rails test test/services/mcp test/integration/mcp_endpoint_test.rb`
Expected: PASS.

- [ ] **Step 2: Run the full test suite**

Run: `bin/rails test`
Expected: PASS with no new failures relative to `main` (if pre-existing failures exist on `main`, note them; do not fix unrelated failures).

- [ ] **Step 3: Commit any fixes (only if Step 1/2 required changes)**

```bash
git add -A && git commit -m "Fix test fallout from MCP finance tools"
```
