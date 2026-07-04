# list_open_admin_tasks MCP Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the Stacks TaskBuilder attention queue as a read-only MCP tool, `list_open_admin_tasks`, with dollar amounts redacted from display strings.

**Architecture:** A `redact_amounts:` keyword on `StacksTask#subject_display_name` (model stays the single source of display truth; admin dashboard behavior unchanged), then a thin presenter tool over `Stacks::TaskBuilder#tasks` / `#tasks_for`, registered on the existing `/api/mcp` surface with the shared `Mcp::Responses` envelope.

**Tech Stack:** Rails, `mcp` Ruby gem, Minitest + mocha.

**Spec:** `docs/superpowers/specs/2026-07-04-mcp-admin-tasks-design.md`

## Global Constraints

- `/api/mcp` is read-only: `annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)` on the tool.
- Response envelope: `Mcp::Responses.ok(payload)` / `Mcp::Responses.error(message)` (exists at `app/services/mcp/responses.rb`).
- Dollar amounts never appear in the MCP payload: the tool always calls `subject_display_name(redact_amounts: true)`.
- A task whose payload mapping raises is skipped with a `Rails.logger.warn`, never fails the list.
- Unknown `owner` email → error payload listing valid admin emails.
- Default behavior of `subject_display_name` (no keyword) is byte-identical to today — the admin dashboard must not change.
- No schema changes, no new gems, no cache changes.
- Tests: `bin/rails test <path>`; mocha available. AdminUser is a Devise model: `AdminUser.create!(email: ..., password: "password123", password_confirmation: "password123", roles: ["admin"])`.

---

### Task 1: `StacksTask#subject_display_name(redact_amounts:)` + missing requires

**Files:**
- Modify: `app/models/stacks_task.rb:90-109` (subject_display_name)
- Modify: `lib/stacks/task_builder.rb:1-11` (require_relative list)
- Create: `test/models/stacks_task_test.rb`

**Interfaces:**
- Consumes: `RecurringLedgerAdjustment` (belongs_to :ledger; validates amount, cadence in `%w[monthly twice_monthly quarterly]`, next_due_on), `Ledger` (belongs_to :enterprise, :contributor), `Contributor` (belongs_to :forecast_person via forecast_person_id → ForecastPerson.forecast_id), `Reimbursement#display_name` (embeds free-text description), fixtures `enterprises(:sanctuary)`.
- Produces: `StacksTask#subject_display_name(redact_amounts: false) → String` — Task 2 calls it with `redact_amounts: true`.

- [ ] **Step 1: Write the failing tests**

Create `test/models/stacks_task_test.rb`:

```ruby
require 'test_helper'

class StacksTaskTest < ActiveSupport::TestCase
  setup do
    @admin = AdminUser.create!(email: "st#{SecureRandom.hex(2)}@example.com",
                               password: 'password123', password_confirmation: 'password123',
                               roles: ['admin'])
  end

  def recurring_adjustment!
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                email: "rla#{SecureRandom.hex(2)}@example.com", data: {})
    contributor = Contributor.create!(forecast_person: fp)
    ledger = Ledger.create!(enterprise: enterprises(:sanctuary), contributor: contributor)
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 250.0, cadence: 'monthly',
                                      next_due_on: Date.today + 7)
  end

  test 'subject_display_name for RecurringLedgerAdjustment includes the amount by default' do
    task = StacksTask.new(type: :auto_paused_recurring_on_qbo_bound,
                          subject: recurring_adjustment!, owners: [@admin])
    assert_includes task.subject_display_name, '$250.00'
    assert_includes task.subject_display_name, 'monthly'
  end

  test 'subject_display_name redacts the amount when redact_amounts is true' do
    task = StacksTask.new(type: :auto_paused_recurring_on_qbo_bound,
                          subject: recurring_adjustment!, owners: [@admin])
    redacted = task.subject_display_name(redact_amounts: true)
    refute_includes redacted, '$'
    assert_includes redacted, 'monthly'
    assert_includes redacted, 'recurring adjustment'
    assert_includes redacted, enterprises(:sanctuary).name
  end

  test 'subject_display_name for Reimbursement is generic when redacted' do
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                email: "rb#{SecureRandom.hex(2)}@example.com", data: {})
    contributor = Contributor.create!(forecast_person: fp)
    ledger = Ledger.create!(enterprise: enterprises(:sanctuary), contributor: contributor)
    reimbursement = Reimbursement.create!(ledger: ledger, description: 'Team dinner $840',
                                          amount: 840.0)
    task = StacksTask.new(type: :pending_acceptance, subject: reimbursement, owners: [@admin])
    assert_equal "Reimbursement ##{reimbursement.id}", task.subject_display_name(redact_amounts: true)
    assert_includes task.subject_display_name, 'Team dinner' # default unchanged
  end

  test 'redact_amounts leaves non-monetary subjects untouched' do
    task = StacksTask.new(type: :missing_skill_tree, subject: @admin, owners: [@admin])
    assert_equal task.subject_display_name, task.subject_display_name(redact_amounts: true)
    assert_equal @admin.email, task.subject_display_name
  end
end
```

NOTE: if `Reimbursement.create!` fails validation, check `app/models/reimbursement.rb` for
required fields and add the minimal missing attributes (its `display_name` reads
`contributor.forecast_person.email`, `created_at`, and `description` — the associations above
supply those). Do not change the model.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/stacks_task_test.rb`
Expected: FAIL — `ArgumentError: wrong number of arguments` / `unknown keyword: :redact_amounts` on the redaction tests (the default-behavior assertions may already pass).

- [ ] **Step 3: Implement the keyword**

In `app/models/stacks_task.rb`, change the `subject_display_name` signature and the two
monetary branches (leave every other branch exactly as-is):

```ruby
  # Display name shown in the Subject column — chosen per-class so each subject
  # reads as something a person can recognize (project name, lead title, contributor
  # email, etc.) rather than a generic Object#to_s.
  #
  # redact_amounts: true omits dollar amounts (and free-text that can embed
  # them) for surfaces outside the admin dashboard — the MCP read layer must
  # expose task existence, not comp-adjacent figures.
  def subject_display_name(redact_amounts: false)
```

Reimbursement branch:

```ruby
    when Reimbursement
      if redact_amounts
        "Reimbursement ##{subject.id}"
      else
        (subject.try(:display_name).presence || "Reimbursement ##{subject.id}").truncate(50)
      end
```

RecurringLedgerAdjustment branch:

```ruby
    when RecurringLedgerAdjustment
      base = "#{subject.ledger.contributor.forecast_person&.email || "Contributor ##{subject.ledger.contributor_id}"} on #{subject.ledger.enterprise.name}"
      if redact_amounts
        "#{base} — #{subject.cadence} recurring adjustment"
      else
        "#{base} — #{subject.cadence} $#{format("%.2f", subject.amount)}"
      end
```

In `lib/stacks/task_builder.rb`, add the two missing requires after the existing
`require_relative "task_builder/discoveries/missing_qbo_vendors"` line (the classes are in
`DISCOVERY_CLASSES` but were never required — they currently load only if something else
gets there first):

```ruby
require_relative "task_builder/discoveries/legacy_ledgers_pending_qbo_migration"
require_relative "task_builder/discoveries/auto_paused_recurring_ledger_adjustments"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/stacks_task_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/models/stacks_task.rb lib/stacks/task_builder.rb test/models/stacks_task_test.rb
git commit -m "Add redact_amounts to StacksTask display names; require missing discoveries"
```

---

### Task 2: `list_open_admin_tasks` tool

**Files:**
- Create: `app/services/mcp/list_open_admin_tasks_tool.rb`
- Create: `test/services/mcp/admin_tasks_tool_test.rb`
- Modify: `app/services/mcp/server.rb` (TOOLS array, currently 6 entries)
- Modify: `test/integration/mcp_endpoint_test.rb:48` (tool-name array) + add one `tools/call` round-trip test

**Interfaces:**
- Consumes (from Task 1): `StacksTask#subject_display_name(redact_amounts: true)`. Also `Stacks::TaskBuilder#tasks → Array<StacksTask>`, `#tasks_for(admin_user) → Array<StacksTask>`, `StacksTask#type/#humanized_type/#subject_class_key/#subject_url/#subject_url_external?/#owners`, `Mcp::Responses.ok/.error`.
- Produces: the `list_open_admin_tasks` MCP tool. Payload:
  `{ count:, tasks: [{ type, task, subject_class, subject, url, url_external, owners: [emails] }] }`,
  sorted by `[subject_class, type, subject]`.

- [ ] **Step 1: Write the failing tests**

Create `test/services/mcp/admin_tasks_tool_test.rb`:

```ruby
require 'test_helper'

class Mcp::AdminTasksToolTest < ActiveSupport::TestCase
  setup do
    @admin = AdminUser.create!(email: "at#{SecureRandom.hex(2)}@example.com",
                               password: 'password123', password_confirmation: 'password123',
                               roles: ['admin'])
    @other = AdminUser.create!(email: "ot#{SecureRandom.hex(2)}@example.com",
                               password: 'password123', password_confirmation: 'password123',
                               roles: ['admin'])
  end

  def task_for(admin, type: :missing_skill_tree)
    StacksTask.new(type: type, subject: admin, owners: [admin])
  end

  def payload_for(resp)
    JSON.parse(resp.content.first[:text])
  end

  test 'returns mapped, sorted tasks with owner emails' do
    Stacks::TaskBuilder.any_instance.stubs(:tasks).returns(
      [task_for(@other, type: :no_full_time_periods_set), task_for(@admin)]
    )
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(server_context: {}))
    assert_equal 2, payload['count']
    row = payload['tasks'].find { |t| t['type'] == 'missing_skill_tree' }
    assert_equal 'Admin user needs skill tree set', row['task']
    assert_equal 'admin_users', row['subject_class']
    assert_equal @admin.email, row['subject']
    assert_equal false, row['url_external']
    assert_match %r{/admin/admin_users/#{@admin.id}}, row['url']
    assert_equal [@admin.email], row['owners']
    types = payload['tasks'].map { |t| t['type'] }
    assert_equal types.sort, types, 'tasks sorted within subject_class by type'
  end

  test 'owner param filters via tasks_for with case-insensitive email' do
    Stacks::TaskBuilder.any_instance.expects(:tasks_for).with(@admin).returns([task_for(@admin)])
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(owner: @admin.email.upcase, server_context: {}))
    assert_equal 1, payload['count']
  end

  test 'unknown owner returns an error payload listing valid emails' do
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(owner: 'nobody@nowhere.dev', server_context: {}))
    assert_includes payload['error'], "Unknown owner 'nobody@nowhere.dev'"
    assert_includes payload['error'], @admin.email
  end

  test 'a task whose mapping raises is skipped with a warning, not fatal' do
    Stacks::TaskBuilder.any_instance.stubs(:tasks).returns([task_for(@admin)])
    StacksTask.any_instance.stubs(:subject_url).raises(RuntimeError, 'boom')
    Rails.logger.expects(:warn).with { |msg| msg.include?('skipping task') }
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['tasks']
  end

  test 'empty queue returns a valid empty payload' do
    Stacks::TaskBuilder.any_instance.stubs(:tasks).returns([])
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['tasks']
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/mcp/admin_tasks_tool_test.rb`
Expected: FAIL — `NameError: uninitialized constant Mcp::ListOpenAdminTasksTool`.

- [ ] **Step 3: Implement the tool and register it**

Create `app/services/mcp/list_open_admin_tasks_tool.rb`:

```ruby
module Mcp
  class ListOpenAdminTasksTool < MCP::Tool
    tool_name 'list_open_admin_tasks'
    description 'Stacks system-administration tasks needing attention (data hygiene, approvals, ' \
                'sync debt) from the owner-routed TaskBuilder queue (24h cache). Distinct from ' \
                'Notion Tasks, which are day-to-day work tasks. Relative urls are paths on the ' \
                'Stacks admin host; url_external true means an absolute Forecast/Notion link. ' \
                'Dollar amounts are redacted from display strings.'
    input_schema(
      properties: {
        owner: { type: 'string', description: 'Optional AdminUser email filter (case-insensitive)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(owner: nil, server_context:)
      builder = Stacks::TaskBuilder.new
      tasks =
        if owner.present?
          admin = AdminUser.find_by('LOWER(email) = ?', owner.to_s.strip.downcase)
          unless admin
            valid = AdminUser.order(:email).pluck(:email)
            return Responses.error("Unknown owner '#{owner}'. Valid owners: #{valid.join(', ')}")
          end
          builder.tasks_for(admin)
        else
          builder.tasks
        end

      rows = tasks.filter_map do |t|
        {
          type: t.type,
          task: t.humanized_type,
          subject_class: t.subject_class_key,
          subject: t.subject_display_name(redact_amounts: true),
          url: t.subject_url,
          url_external: t.subject_url_external?,
          owners: t.owners.map(&:email),
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::ListOpenAdminTasksTool] skipping task #{t.type}: #{e.class}: #{e.message}")
        nil
      end
      rows = rows.sort_by { |r| [r[:subject_class], r[:type].to_s, r[:subject].to_s] }

      Responses.ok({ count: rows.length, tasks: rows })
    end
  end
end
```

Append to `TOOLS` in `app/services/mcp/server.rb`:

```ruby
      Mcp::ListOpenAdminTasksTool,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/mcp/admin_tasks_tool_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Update the integration test**

In `test/integration/mcp_endpoint_test.rb` (~line 48):

```ruby
    assert_equal %w[get_ar_aging get_document list_documents list_open_admin_tasks list_overdue_invoices list_sources search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
```

Add a round-trip test (mirror the existing `get_ar_aging` `tools/call` test in the same file
for headers / api-key setup / JSON-RPC envelope). Stub the queue so the test exercises
dispatch and envelope, not the discovery sweep over an empty DB:

```ruby
  test "tools/call round-trip for list_open_admin_tasks returns a valid payload" do
    Stacks::TaskBuilder.any_instance.stubs(:tasks).returns([])
    post "/api/mcp",
      headers: api_key_headers,
      params: {
        jsonrpc: "2.0", id: 9, method: "tools/call",
        params: { name: "list_open_admin_tasks", arguments: {} },
      }.to_json
    assert_response :success
    text = JSON.parse(response.body).dig("result", "content", 0, "text")
    payload = JSON.parse(text)
    assert_equal 0, payload["count"]
    assert_equal [], payload["tasks"]
  end
```

(If mocha `any_instance` stubbing does not take effect through the integration stack, run the
real sweep instead and assert only `payload.key?("count") && payload.key?("tasks")` — note
which variant you shipped in your report.)

Run: `bin/rails test test/integration/mcp_endpoint_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/mcp/list_open_admin_tasks_tool.rb app/services/mcp/server.rb \
        test/services/mcp/admin_tasks_tool_test.rb test/integration/mcp_endpoint_test.rb
git commit -m "Add list_open_admin_tasks MCP tool (TaskBuilder queue, amounts redacted)"
```

---

### Task 3: Full-suite verification

**Files:** none new — fix only branch-caused fallout.

**Interfaces:**
- Consumes: everything from Tasks 1–2.
- Produces: a green suite (modulo the known pre-existing `AdminUserTest` date-boundary flake, which fails identically on `main` — report it, don't fix it).

- [ ] **Step 1: Run the MCP + models suites**

Run: `bin/rails test test/services/mcp test/models/stacks_task_test.rb test/integration/mcp_endpoint_test.rb`
Expected: PASS.

- [ ] **Step 2: Run the full suite**

Run: `bin/rails test`
Expected: no new failures relative to `main`. The pre-existing `AdminUserTest` salary-window
date flake may appear — classify, do not fix.

- [ ] **Step 3: Commit (only if fixes were needed)**

```bash
git add -A && git commit -m "Fix test fallout from list_open_admin_tasks"
```
