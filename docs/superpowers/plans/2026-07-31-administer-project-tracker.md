# Administer a Project Tracker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add MCP tools to administer an existing project tracker and its sub-objects — update the tracker (name/budgets/MSA+SOW links), remove a workstream rate, mark/unmark work complete, set the account/project lead, and pause/resume/destroy a recurring assignment — plus a `find_admin_user` lookup and enriched tracker reads.

**Architecture:** Same seam as PR #160 — new/changed **model methods** on `ProjectTracker` do the work; thin `MCP::Tool` wrappers on the existing `Mcp::Server` (read) / `Mcp::WriteServer` (write) validate inputs and call them. Forecast stays hidden; ids are native. Audit-logging lives in the agent skill, not the tools (tools return `{before, after, …}`).

**Tech Stack:** Rails 6.1, `mcp` gem 0.22, Minitest + Mocha.

## Global Constraints

- **No `forecast_*` in any tool name, input property, or response key.** Native ids: tracker = `ProjectTracker#id`, workstream = `ProjectTrackerForecastProject#id`, recurring assignment = `RecurringAssignment#id`, admin user = `AdminUser#id`.
- **House write-tool pattern** (from `app/services/mcp/ensure_workstream_tool.rb` — read it as the template): validate EVERYTHING first → `Mcp::WriteGuard.check!` **only on the real mutate path** (a no-op does not burn a slot) → model method → `Mcp::Responses.ok({ before:, after:, … })`. Rescue order: `rescue ArgumentError, WriteGuard::CapExceeded => e` (surface `e.message`) → `rescue ActiveRecord::RecordNotFound` (clean "not found") → `rescue ActiveRecord::RecordInvalid => e` (surface `e.record.errors.full_messages.join('; ')`) → `rescue StandardError => e` (`Rails.logger.warn("[Mcp::<Tool>] …")` + `Sentry.capture_exception(e) if defined?(Sentry)` + generic message).
- **Read-tool pattern** (from `app/services/mcp/find_contributor_tool.rb`): `annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)`; rescue `StandardError` → log + Sentry + generic.
- **`self.call(...)` always ends with `server_context:`.**
- **Test file:** append to `test/services/mcp/provisioning_tools_test.rb`. Reuse its helpers `payload(resp)`, `make_contributor`, `make_tracker_with_workstream(tracker_name:, client_name:, code:, rate_tags: [], project_name: nil)`. Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb`.
- **Fixture caveats (from #160):** `ProjectTracker.create!(name:)` fails the `has_msa_and_sow_links` validation — build trackers with `ProjectTracker.new(...).save!(validate: false)` OR via `make_tracker_with_workstream`. `ForecastPerson after_create` auto-creates a Contributor (no manual `Contributor.insert!`). `ForecastProject`/`ForecastClient` use `self.primary_key = "forecast_id"`.
- **AdminUser fixture:** `AdminUser.create!(email: "a#{SecureRandom.hex(3)}@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])`.

## File Structure

- `app/models/project_tracker.rb` — add `update_details!`, `mark_work_completed!`, `set_role_assignee!` (Tasks 3, 5, 6).
- `app/services/mcp/provisioning_serializers.rb` — enrich `tracker_json` (Task 2).
- `app/services/mcp/find_admin_user_tool.rb` — read tool (Task 1).
- `app/services/mcp/update_project_tracker_tool.rb` — write tool (Task 3).
- `app/services/mcp/remove_workstream_rate_tool.rb` — write tool (Task 4).
- `app/services/mcp/set_project_tracker_work_completed_at_tool.rb` — write tool (Task 5).
- `app/services/mcp/set_project_tracker_role_assignee_tool.rb` — write tool (Task 6).
- `app/services/mcp/manage_recurring_assignment_tool.rb` — write tool (Task 7).
- `app/services/mcp/server.rb` — register `FindAdminUserTool` (Task 1).
- `app/services/mcp/write_server.rb` — register the 5 new write tools (Tasks 3–7).
- `test/services/mcp/provisioning_tools_test.rb` — unit tests (Tasks 1–7).
- `test/integration/mcp_endpoint_test.rb` / `mcp_write_endpoint_test.rb` — pins + happy-paths (Task 8).

---

### Task 1: `find_admin_user` read tool

**Files:** Create `app/services/mcp/find_admin_user_tool.rb`; modify `app/services/mcp/server.rb`; test in `test/services/mcp/provisioning_tools_test.rb`.

**Interfaces:** Produces `Mcp::FindAdminUserTool.call(email:, server_context:)` → JSON array `[{ id, name, email }]`.

- [ ] **Step 1: Write the failing test** (append to the test file)

```ruby
  # ---- find_admin_user -----------------------------------------------------
  def make_admin(email:)
    AdminUser.create!(email: email, password: "password123", password_confirmation: "password123", roles: ["admin"])
  end

  test "find_admin_user matches by case-insensitive email" do
    a = make_admin(email: "lead@sanctuary.computer")
    resp = Mcp::FindAdminUserTool.call(email: "LEAD@Sanctuary.Computer", server_context: {})
    rows = payload(resp)
    assert_equal [a.id], rows.map { |r| r["id"] }
    assert_equal "lead@sanctuary.computer", rows.first["email"]
  end

  test "find_admin_user returns empty array when no match" do
    assert_equal [], payload(Mcp::FindAdminUserTool.call(email: "nobody@example.com", server_context: {}))
  end
```

- [ ] **Step 2: Run it — expect FAIL** (`NameError: …FindAdminUserTool`). `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/find_admin_user/"`

- [ ] **Step 3: Implement** `app/services/mcp/find_admin_user_tool.rb` (mirror `find_contributor_tool.rb`):

```ruby
module Mcp
  class FindAdminUserTool < MCP::Tool
    tool_name 'find_admin_user'
    description 'READ: find garden3d staff (AdminUser) by email (exact, case-insensitive). ' \
                'Returns [{id, name, email}]. Use the id as admin_user for project-tracker ' \
                'lead roles (account_lead / project_lead) — distinct from find_contributor, ' \
                'which resolves assignees.'
    input_schema(properties: { email: { type: 'string' } }, required: %w[email])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(email:, server_context:)
      rows = AdminUser.where("lower(email) = ?", email.to_s.strip.downcase).map do |a|
        { id: a.id, name: a.display_name, email: a.email }
      end
      Responses.ok(rows)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::FindAdminUserTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("find_admin_user failed; the error was logged")
    end
  end
end
```

- [ ] **Step 4: Register** — add `Mcp::FindAdminUserTool,` to `TOOLS` in `app/services/mcp/server.rb`.

- [ ] **Step 5: Run — expect PASS** (2 tests).

- [ ] **Step 6: Commit** `feat(mcp): find_admin_user read tool`.

---

### Task 2: enrich `tracker_json`

**Files:** Modify `app/services/mcp/provisioning_serializers.rb`; test in the test file.

**Interfaces:** `Mcp::ProvisioningSerializers.tracker_json(tracker)` gains keys: `budget_low_end`, `budget_high_end`, `work_completed_at`, `completed`, `msa_url`, `sow_url`, `account_lead`, `project_lead`. Existing keys (`id, name, client, workstreams`) unchanged.

- [ ] **Step 1: Write the failing test**

```ruby
  # ---- tracker_json enrichment (via list_project_trackers) ------------------
  test "list_project_trackers surfaces budgets, completion, links, and leads" do
    tracker, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL", rate_tags: ["450p/h"])
    tracker.update_columns(budget_low_end: 1000, budget_high_end: 2000, work_completed_at: nil)
    tracker.project_tracker_links.create!(name: "MSA", url: "https://x.test/msa", link_type: :msa)
    tracker.project_tracker_links.create!(name: "SOW", url: "https://x.test/sow", link_type: :sow)
    admin = make_admin(email: "acct@sanctuary.computer")
    tracker.account_lead_periods.create!(admin_user: admin, started_at: Date.today.beginning_of_month, ended_at: nil)

    row = payload(Mcp::ListProjectTrackersTool.call(name: "qualitate", server_context: {})).first
    assert_equal 1000, row["budget_low_end"]
    assert_equal 2000, row["budget_high_end"]
    assert_equal false, row["completed"]
    assert_nil row["work_completed_at"]
    assert_equal "https://x.test/msa", row["msa_url"]
    assert_equal "https://x.test/sow", row["sow_url"]
    assert_equal "acct@sanctuary.computer", row["account_lead"]["email"]
    assert_nil row["project_lead"]
  end
```

- [ ] **Step 2: Run — expect FAIL** (keys missing / nil).

- [ ] **Step 3: Implement** — replace `tracker_json` in `provisioning_serializers.rb` with:

```ruby
    def tracker_json(tracker)
      {
        id: tracker.id,
        name: tracker.name,
        client: tracker.derived_client&.name,
        budget_low_end: tracker.budget_low_end,
        budget_high_end: tracker.budget_high_end,
        work_completed_at: tracker.work_completed_at,
        completed: tracker.work_completed_at.present?,
        msa_url: link_url(tracker, :msa),
        sow_url: link_url(tracker, :sow),
        account_lead: lead_json(tracker.account_lead_periods),
        project_lead: lead_json(tracker.project_lead_periods),
        workstreams: tracker.project_tracker_forecast_projects.map { |ws| workstream_json(ws) },
      }
    end

    def link_url(tracker, type)
      tracker.project_tracker_links.find { |l| l.link_type == type.to_s }&.url
    end

    # Current lead = the open period (ended_at nil); if several, the latest-started.
    def lead_json(periods)
      period = periods.select { |p| p.ended_at.nil? }.max_by { |p| p.started_at || Date.new(0) }
      return nil if period.nil?
      au = period.admin_user
      { name: au&.display_name, email: au&.email }
    end
```

(`workstream_json` is unchanged. `module_function` already applies, so the two new helpers are module functions too.)

- [ ] **Step 4: Run — expect PASS**, and re-run the whole file to confirm #160's list tests still pass (enrichment is additive).

- [ ] **Step 5: Commit** `feat(mcp): enrich tracker_json with budgets, completion, links, leads`.

---

### Task 3: `update_project_tracker`

**Files:** Modify `app/models/project_tracker.rb` (add `update_details!`); create `app/services/mcp/update_project_tracker_tool.rb`; modify `write_server.rb`; test.

**Interfaces:**
- `ProjectTracker#update_details!(name: nil, budget_low_end: nil, budget_high_end: nil, msa_url: nil, sow_url: nil)` → self (raises `ActiveRecord::RecordInvalid` on validation failure). Only non-nil args change.
- `Mcp::UpdateProjectTrackerTool.call(project_tracker_id:, name: nil, budget_low_end: nil, budget_high_end: nil, msa_url: nil, sow_url: nil, server_context:)` → `{ before, after }`.

- [ ] **Step 1: Write the failing tests**

```ruby
  # ---- update_project_tracker ---------------------------------------------
  test "update_project_tracker replaces the MSA link and updates budgets" do
    tracker, _ws, _fp, _c = make_tracker_with_workstream(tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")
    tracker.project_tracker_links.create!(name: "MSA", url: "https://old.test/msa", link_type: :msa)
    tracker.project_tracker_links.create!(name: "SOW", url: "https://old.test/sow", link_type: :sow)

    resp = Mcp::UpdateProjectTrackerTool.call(
      project_tracker_id: tracker.id, msa_url: "https://new.test/msa",
      budget_low_end: 500, budget_high_end: 900, server_context: {})
    after = payload(resp)["after"]
    assert_equal "https://new.test/msa", after["msa_url"]
    assert_equal 500, after["budget_low_end"]
    assert_equal 900, after["budget_high_end"]
    assert_equal "https://old.test/sow", after["sow_url"], "unspecified fields unchanged"
  end

  test "update_project_tracker builds an SOW link when none exists" do
    tracker = ProjectTracker.new(name: "Bare").tap { |t| t.save!(validate: false) }
    resp = Mcp::UpdateProjectTrackerTool.call(project_tracker_id: tracker.id, sow_url: "https://x.test/sow", server_context: {})
    assert_equal "https://x.test/sow", payload(resp)["after"]["sow_url"]
  end

  test "update_project_tracker surfaces budget validation" do
    tracker, = make_tracker_with_workstream(tracker_name: "Q", client_name: "Q Inc", code: "QUAL")
    tracker.project_tracker_links.create!(name: "MSA", url: "https://x/msa", link_type: :msa)
    tracker.project_tracker_links.create!(name: "SOW", url: "https://x/sow", link_type: :sow)
    resp = Mcp::UpdateProjectTrackerTool.call(project_tracker_id: tracker.id, budget_low_end: 900, budget_high_end: 100, server_context: {})
    assert_match(/budget/i, payload(resp)["error"])
  end
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement the model method** — add to `app/models/project_tracker.rb` (near `add_workstream!`):

```ruby
  def update_details!(name: nil, budget_low_end: nil, budget_high_end: nil, msa_url: nil, sow_url: nil)
    self.name = name if name.present?
    self.budget_low_end = budget_low_end unless budget_low_end.nil?
    self.budget_high_end = budget_high_end unless budget_high_end.nil?
    upsert_link!(:msa, "MSA", msa_url) unless msa_url.nil?
    upsert_link!(:sow, "SOW", sow_url) unless sow_url.nil?
    save!
    self
  end

  private def upsert_link!(type, label, url)
    link = project_tracker_links.find { |l| l.link_type == type.to_s } ||
           project_tracker_links.build(name: label, link_type: type)
    link.url = url
  end
```

- [ ] **Step 4: Implement the tool** `app/services/mcp/update_project_tracker_tool.rb` (mirror `ensure_project_tracker_tool.rb`'s structure):

```ruby
module Mcp
  class UpdateProjectTrackerTool < MCP::Tool
    tool_name 'update_project_tracker'
    description 'WRITE: update an existing project tracker — set name, budgets, and/or ' \
                'replace the MSA/SOW links (only provided fields change). Use this to fix the ' \
                'placeholder MSA/SOW links left by ensure_project_tracker. Returns {before, after}.'
    input_schema(
      properties: {
        project_tracker_id: { type: 'integer' },
        name: { type: 'string' },
        budget_low_end: { type: 'integer' },
        budget_high_end: { type: 'integer' },
        msa_url: { type: 'string' },
        sow_url: { type: 'string' },
      },
      required: %w[project_tracker_id]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(project_tracker_id:, name: nil, budget_low_end: nil, budget_high_end: nil,
                  msa_url: nil, sow_url: nil, server_context:)
      ptid = WriteValidation.integer!("project_tracker_id", project_tracker_id)
      tracker = ProjectTracker.find(ptid)
      before = ProvisioningSerializers.tracker_json(tracker)
      WriteGuard.check!
      tracker.update_details!(name: name, budget_low_end: budget_low_end,
                              budget_high_end: budget_high_end, msa_url: msa_url, sow_url: sow_url)
      Responses.ok({ before: before, after: ProvisioningSerializers.tracker_json(tracker.reload) })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("project_tracker #{project_tracker_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::UpdateProjectTrackerTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("update_project_tracker failed; the error was logged")
    end
  end
end
```

- [ ] **Step 5: Register** `Mcp::UpdateProjectTrackerTool,` in `write_server.rb` `TOOLS`.
- [ ] **Step 6: Run — expect PASS** (3 tests).
- [ ] **Step 7: Commit** `feat(mcp): update_project_tracker (name/budgets/MSA+SOW links)`.

---

### Task 4: `remove_workstream_rate`

**Files:** Create `app/services/mcp/remove_workstream_rate_tool.rb`; modify `write_server.rb`; test.

**Interfaces:** `Mcp::RemoveWorkstreamRateTool.call(workstream_id:, rate:, server_context:)` → `{ before, after, removed }`.

- [ ] **Step 1: Write the failing tests**

```ruby
  # ---- remove_workstream_rate ---------------------------------------------
  test "remove_workstream_rate removes a present rate" do
    _t, ws, fp, _c = make_tracker_with_workstream(tracker_name: "Q", client_name: "Q Inc", code: "QUAL", rate_tags: ["450p/h", "300p/h"])
    Stacks::Forecast.any_instance.expects(:remove_project_rate!).with(fp.forecast_id, "450p/h").returns(true)
    resp = Mcp::RemoveWorkstreamRateTool.call(workstream_id: ws.id, rate: "450p/h", server_context: {})
    assert_equal true, payload(resp)["removed"]
  end

  test "remove_workstream_rate is a no-op when the rate is absent (no cap, no API)" do
    _t, ws, _fp, _c = make_tracker_with_workstream(tracker_name: "Q", client_name: "Q Inc", code: "QUAL", rate_tags: ["300p/h"])
    Stacks::Forecast.any_instance.expects(:remove_project_rate!).never
    Mcp::WriteGuard.expects(:check!).never
    resp = Mcp::RemoveWorkstreamRateTool.call(workstream_id: ws.id, rate: "450p/h", server_context: {})
    assert_equal false, payload(resp)["removed"]
  end

  test "remove_workstream_rate reports a missing workstream" do
    resp = Mcp::RemoveWorkstreamRateTool.call(workstream_id: 999999, rate: "450p/h", server_context: {})
    assert_match(/not found/i, payload(resp)["error"])
  end
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement** `app/services/mcp/remove_workstream_rate_tool.rb`:

```ruby
module Mcp
  class RemoveWorkstreamRateTool < MCP::Tool
    tool_name 'remove_workstream_rate'
    description 'WRITE: remove a p/h rate from a workstream (idempotent — removing an absent ' \
                'rate is a no-op). rate is a string like "450p/h". Returns {before, after, removed}.'
    input_schema(
      properties: {
        workstream_id: { type: 'integer' },
        rate: { type: 'string', description: 'rate as a string, e.g. "450p/h"' },
      },
      required: %w[workstream_id rate]
    )
    annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true)

    def self.call(workstream_id:, rate:, server_context:)
      wid = WriteValidation.integer!("workstream_id", workstream_id)
      ws = ProjectTrackerForecastProject.find(wid)
      tag = Stacks::Forecast.rate_tag(rate)
      present = Array(ws.forecast_project&.tags).include?(tag)
      unless present
        json = ProvisioningSerializers.workstream_json(ws)
        return Responses.ok({ before: json, after: json, removed: false })
      end
      before = ProvisioningSerializers.workstream_json(ws)
      WriteGuard.check!
      Stacks::Forecast.new.remove_project_rate!(ws.forecast_project_id, rate)
      Responses.ok({ before: before, after: ProvisioningSerializers.workstream_json(ws.reload), removed: true })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("workstream #{workstream_id} not found")
    rescue StandardError => e
      Rails.logger.warn("[Mcp::RemoveWorkstreamRateTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("remove_workstream_rate failed; the error was logged")
    end
  end
end
```

- [ ] **Step 4: Register** in `write_server.rb`. **Step 5: Run — expect PASS.** **Step 6: Commit** `feat(mcp): remove_workstream_rate`.

---

### Task 5: `set_project_tracker_work_completed_at`

**Files:** Modify `app/models/project_tracker.rb` (add `mark_work_completed!`); create tool; modify `write_server.rb`; test.

**Interfaces:** `ProjectTracker#mark_work_completed!(at:)` → self. `Mcp::SetProjectTrackerWorkCompletedAtTool.call(project_tracker_id:, completed_at: :__unset__, server_context:)` → `{ before, after }`. Omitted `completed_at` marks today; explicit null/blank unmarks.

- [ ] **Step 1: Write the failing tests**

```ruby
  # ---- set_project_tracker_work_completed_at ------------------------------
  test "work_completed_at defaults to today when omitted, and unmarks on null" do
    tracker = ProjectTracker.new(name: "Done Co").tap { |t| t.save!(validate: false) }
    mark = Mcp::SetProjectTrackerWorkCompletedAtTool.call(project_tracker_id: tracker.id, server_context: {})
    assert_equal true, payload(mark)["after"]["completed"]
    assert_equal Date.today.to_s, tracker.reload.work_completed_at.to_date.to_s

    unmark = Mcp::SetProjectTrackerWorkCompletedAtTool.call(project_tracker_id: tracker.id, completed_at: nil, server_context: {})
    assert_equal false, payload(unmark)["after"]["completed"]
    assert_nil tracker.reload.work_completed_at
  end

  test "work_completed_at accepts an explicit date" do
    tracker = ProjectTracker.new(name: "Back Co").tap { |t| t.save!(validate: false) }
    Mcp::SetProjectTrackerWorkCompletedAtTool.call(project_tracker_id: tracker.id, completed_at: "2026-06-30", server_context: {})
    assert_equal "2026-06-30", tracker.reload.work_completed_at.to_date.to_s
  end
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement the model method** (add to `project_tracker.rb`):

```ruby
  def mark_work_completed!(at:)
    update!(work_completed_at: at)
    self
  end
```

- [ ] **Step 4: Implement the tool** `app/services/mcp/set_project_tracker_work_completed_at_tool.rb`:

```ruby
module Mcp
  class SetProjectTrackerWorkCompletedAtTool < MCP::Tool
    tool_name 'set_project_tracker_work_completed_at'
    description 'WRITE: mark a project tracker\'s work complete by setting work_completed_at. ' \
                'Omit completed_at to mark complete as of today; pass an ISO date/datetime to ' \
                'backdate; pass null to UNMARK (clear it). Returns {before, after}.'
    input_schema(
      properties: {
        project_tracker_id: { type: 'integer' },
        completed_at: { type: 'string', description: 'ISO date/datetime; omit = today; null = unmark' },
      },
      required: %w[project_tracker_id]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    UNSET = :__unset__

    def self.call(project_tracker_id:, completed_at: UNSET, server_context:)
      ptid = WriteValidation.integer!("project_tracker_id", project_tracker_id)
      at =
        if completed_at == UNSET
          Date.today
        elsif completed_at.nil? || completed_at.to_s.strip.empty?
          nil
        else
          WriteValidation.date!("completed_at", completed_at)
        end
      tracker = ProjectTracker.find(ptid)
      before = { work_completed_at: tracker.work_completed_at, completed: tracker.work_completed_at.present? }
      WriteGuard.check!
      tracker.mark_work_completed!(at: at)
      after = { work_completed_at: tracker.work_completed_at, completed: tracker.work_completed_at.present? }
      Responses.ok({ before: before, after: after })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("project_tracker #{project_tracker_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::SetProjectTrackerWorkCompletedAtTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("set_project_tracker_work_completed_at failed; the error was logged")
    end
  end
end
```

Note: `WriteValidation.date!` accepts `YYYY-MM-DD`; a datetime string would be rejected — that's acceptable (dates are the norm here). Keep `completed_at` date-only.

- [ ] **Step 5: Register. Step 6: Run — expect PASS. Step 7: Commit** `feat(mcp): set_project_tracker_work_completed_at (mark/unmark complete)`.

---

### Task 6: `set_project_tracker_role_assignee`

**Files:** Modify `app/models/project_tracker.rb` (add `set_role_assignee!`); create tool; modify `write_server.rb`; test.

**Interfaces:** `ProjectTracker#set_role_assignee!(role:, admin_user:, starts_on:)` → the current period. `Mcp::SetProjectTrackerRoleAssigneeTool.call(project_tracker_id:, role:, admin_user_email:, starts_on: nil, server_context:)` → `{ before, after }`.

- [ ] **Step 1: Write the failing tests**

```ruby
  # ---- set_project_tracker_role_assignee ----------------------------------
  test "role assignee: first-time set creates a period for the right role" do
    tracker = ProjectTracker.new(name: "Lead Co").tap { |t| t.save!(validate: false) }
    admin = make_admin(email: "acct@sanctuary.computer")
    resp = Mcp::SetProjectTrackerRoleAssigneeTool.call(
      project_tracker_id: tracker.id, role: "account_lead", admin_user_email: "acct@sanctuary.computer", server_context: {})
    assert_equal "acct@sanctuary.computer", payload(resp)["after"]["assignee"]["email"]
    assert_equal admin.id, tracker.account_lead_periods.where(ended_at: nil).first.admin_user_id
    assert_empty tracker.project_lead_periods
  end

  test "role assignee: reassign across months ends the prior period at end of prior month" do
    tracker = ProjectTracker.new(name: "Lead Co").tap { |t| t.save!(validate: false) }
    old = make_admin(email: "old@sanctuary.computer")
    new = make_admin(email: "new@sanctuary.computer")
    tracker.account_lead_periods.create!(admin_user: old, started_at: (Date.today.beginning_of_month - 1.month), ended_at: nil)

    Mcp::SetProjectTrackerRoleAssigneeTool.call(
      project_tracker_id: tracker.id, role: "account_lead", admin_user_email: "new@sanctuary.computer", server_context: {})
    prior = tracker.account_lead_periods.find_by(admin_user: old)
    assert_equal (Date.today.beginning_of_month - 1.day), prior.ended_at
    assert_equal new.id, tracker.account_lead_periods.where(ended_at: nil).first.admin_user_id
  end

  test "role assignee: no-op when already the current lead (no cap)" do
    tracker = ProjectTracker.new(name: "Lead Co").tap { |t| t.save!(validate: false) }
    admin = make_admin(email: "acct@sanctuary.computer")
    tracker.account_lead_periods.create!(admin_user: admin, started_at: Date.today.beginning_of_month, ended_at: nil)
    Mcp::WriteGuard.expects(:check!).never
    resp = Mcp::SetProjectTrackerRoleAssigneeTool.call(
      project_tracker_id: tracker.id, role: "account_lead", admin_user_email: "acct@sanctuary.computer", server_context: {})
    assert_equal "acct@sanctuary.computer", payload(resp)["after"]["assignee"]["email"]
    assert_equal 1, tracker.account_lead_periods.count
  end

  test "role assignee: same-month swap raises a clear error" do
    tracker = ProjectTracker.new(name: "Lead Co").tap { |t| t.save!(validate: false) }
    a = make_admin(email: "a@sanctuary.computer")
    make_admin(email: "b@sanctuary.computer")
    tracker.account_lead_periods.create!(admin_user: a, started_at: Date.today.beginning_of_month, ended_at: nil)
    resp = Mcp::SetProjectTrackerRoleAssigneeTool.call(
      project_tracker_id: tracker.id, role: "account_lead", admin_user_email: "b@sanctuary.computer", server_context: {})
    assert_match(/same-month|admin UI/i, payload(resp)["error"])
  end

  test "role assignee: unknown admin email and bad role are surfaced" do
    tracker = ProjectTracker.new(name: "Lead Co").tap { |t| t.save!(validate: false) }
    r1 = Mcp::SetProjectTrackerRoleAssigneeTool.call(project_tracker_id: tracker.id, role: "account_lead", admin_user_email: "nobody@example.com", server_context: {})
    assert_match(/admin.*not found/i, payload(r1)["error"])
    r2 = Mcp::SetProjectTrackerRoleAssigneeTool.call(project_tracker_id: tracker.id, role: "cto", admin_user_email: "x@example.com", server_context: {})
    assert_match(/role must be/i, payload(r2)["error"])
  end
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement the model method** (add to `project_tracker.rb`):

```ruby
  ROLE_PERIOD_ASSOCIATIONS = { "account_lead" => :account_lead_periods, "project_lead" => :project_lead_periods }.freeze

  # Assign a lead role via a full-month, non-overlapping period. Ends the current open
  # period at the end of the prior month and starts a new one at `starts_on` (first of a
  # month). No-op if `admin_user` is already the open lead. Raises on a same-month swap.
  def set_role_assignee!(role:, admin_user:, starts_on: Date.today.beginning_of_month)
    assoc = ROLE_PERIOD_ASSOCIATIONS[role.to_s]
    raise ArgumentError, "role must be one of #{ROLE_PERIOD_ASSOCIATIONS.keys.join(', ')}" if assoc.nil?
    raise ArgumentError, "starts_on must be the first day of a month" unless starts_on == starts_on.beginning_of_month

    periods = public_send(assoc)
    current = periods.detect { |p| p.ended_at.nil? }
    return current if current&.admin_user_id == admin_user.id

    if current
      raise ArgumentError, "a #{role} already starts this month; resolve same-month lead changes in the admin UI" if current.started_at && current.started_at >= starts_on
      current.update!(ended_at: starts_on.prev_day)
    end
    periods.create!(admin_user: admin_user, started_at: starts_on, ended_at: nil)
  end
```

- [ ] **Step 4: Implement the tool** `app/services/mcp/set_project_tracker_role_assignee_tool.rb`:

```ruby
module Mcp
  class SetProjectTrackerRoleAssigneeTool < MCP::Tool
    tool_name 'set_project_tracker_role_assignee'
    description 'WRITE: set the account_lead or project_lead of a project tracker (assignee is ' \
                'an AdminUser — use find_admin_user). Lead changes take effect at month ' \
                'boundaries: the prior lead ends at the end of the prior month and the new lead ' \
                'starts on the first of starts_on\'s month (default this month). No-op if already ' \
                'the lead. A same-month swap is refused (resolve in the admin UI). Returns {before, after}.'
    input_schema(
      properties: {
        project_tracker_id: { type: 'integer' },
        role: { type: 'string', description: '"account_lead" or "project_lead"' },
        admin_user_email: { type: 'string' },
        starts_on: { type: 'string', description: 'YYYY-MM-DD, must be the first of a month; default this month' },
      },
      required: %w[project_tracker_id role admin_user_email]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(project_tracker_id:, role:, admin_user_email:, starts_on: nil, server_context:)
      ptid = WriteValidation.integer!("project_tracker_id", project_tracker_id)
      raise ArgumentError, "role must be one of account_lead, project_lead" unless %w[account_lead project_lead].include?(role.to_s)
      start_date = starts_on.present? ? WriteValidation.date!("starts_on", starts_on) : Date.today.beginning_of_month

      tracker = ProjectTracker.find(ptid)
      admin = AdminUser.where("lower(email) = ?", admin_user_email.to_s.strip.downcase).first
      raise ArgumentError, "admin user #{admin_user_email} not found" if admin.nil?

      before = lead_snapshot(tracker, role)
      current = tracker.public_send(ProjectTracker::ROLE_PERIOD_ASSOCIATIONS[role.to_s]).detect { |p| p.ended_at.nil? }
      WriteGuard.check! unless current&.admin_user_id == admin.id
      tracker.set_role_assignee!(role: role, admin_user: admin, starts_on: start_date)
      Responses.ok({ before: before, after: lead_snapshot(tracker.reload, role) })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("project_tracker #{project_tracker_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::SetProjectTrackerRoleAssigneeTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("set_project_tracker_role_assignee failed; the error was logged")
    end

    def self.lead_snapshot(tracker, role)
      period = tracker.public_send(ProjectTracker::ROLE_PERIOD_ASSOCIATIONS[role.to_s]).detect { |p| p.ended_at.nil? }
      au = period&.admin_user
      { role: role.to_s, assignee: au && { name: au.display_name, email: au.email } }
    end
  end
end
```

- [ ] **Step 5: Register. Step 6: Run — expect PASS** (5 tests). **Step 7: Commit** `feat(mcp): set_project_tracker_role_assignee (monthly lead handoff)`.

---

### Task 7: `manage_recurring_assignment`

**Files:** Create `app/services/mcp/manage_recurring_assignment_tool.rb`; modify `write_server.rb`; test.

**Interfaces:** `Mcp::ManageRecurringAssignmentTool.call(recurring_assignment_id:, action:, server_context:)` → `{ before, after, action }`. `action` ∈ `pause|resume|destroy`.

- [ ] **Step 1: Write the failing tests**

```ruby
  # ---- manage_recurring_assignment ----------------------------------------
  def make_recurring(person_fid: 555, project_fid: 777)
    RecurringAssignment.create!(forecast_person_id: person_fid, forecast_project_id: project_fid,
                                allocation: 8 * 3600, weekdays: [1, 2, 3, 4, 5], starts_on: Date.today)
  end

  test "manage_recurring_assignment pauses and resumes" do
    ra = make_recurring
    paused = Mcp::ManageRecurringAssignmentTool.call(recurring_assignment_id: ra.id, action: "pause", server_context: {})
    assert_not_nil payload(paused)["after"]["paused_at"]
    assert_not_nil ra.reload.paused_at
    resumed = Mcp::ManageRecurringAssignmentTool.call(recurring_assignment_id: ra.id, action: "resume", server_context: {})
    assert_nil payload(resumed)["after"]["paused_at"]
    assert_nil ra.reload.paused_at
  end

  test "manage_recurring_assignment destroy removes the rule and does NOT delete Forecast assignments" do
    ra = make_recurring
    Stacks::Forecast.any_instance.expects(:delete_assignment).never
    resp = Mcp::ManageRecurringAssignmentTool.call(recurring_assignment_id: ra.id, action: "destroy", server_context: {})
    assert_equal false, payload(resp)["after"]["exists"]
    assert_nil RecurringAssignment.find_by(id: ra.id)
  end

  test "manage_recurring_assignment rejects a bad action and a missing id" do
    ra = make_recurring
    assert_match(/action must be/i, payload(Mcp::ManageRecurringAssignmentTool.call(recurring_assignment_id: ra.id, action: "frobnicate", server_context: {}))["error"])
    assert_match(/not found/i, payload(Mcp::ManageRecurringAssignmentTool.call(recurring_assignment_id: 999999, action: "pause", server_context: {}))["error"])
  end
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement** `app/services/mcp/manage_recurring_assignment_tool.rb`:

```ruby
module Mcp
  class ManageRecurringAssignmentTool < MCP::Tool
    tool_name 'manage_recurring_assignment'
    description 'WRITE: change a recurring assignment\'s lifecycle. action = "pause" (stop ' \
                'materializing), "resume", or "destroy" (delete the rule; already-materialized ' \
                'Forecast assignments are LEFT INTACT). Returns {before, after, action}.'
    input_schema(
      properties: {
        recurring_assignment_id: { type: 'integer' },
        action: { type: 'string', description: '"pause" | "resume" | "destroy"' },
      },
      required: %w[recurring_assignment_id action]
    )
    annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true)

    ACTIONS = %w[pause resume destroy].freeze

    def self.call(recurring_assignment_id:, action:, server_context:)
      rid = WriteValidation.integer!("recurring_assignment_id", recurring_assignment_id)
      raise ArgumentError, "action must be one of #{ACTIONS.join(', ')}" unless ACTIONS.include?(action.to_s)
      ra = RecurringAssignment.find(rid)
      before = { paused_at: ra.paused_at, exists: true }
      WriteGuard.check!
      case action.to_s
      when "pause"   then ra.update!(paused_at: Time.current)
      when "resume"  then ra.update!(paused_at: nil)
      when "destroy" then ra.destroy!
      end
      after = ra.destroyed? ? { paused_at: nil, exists: false } : { paused_at: ra.paused_at, exists: true }
      Responses.ok({ before: before, after: after, action: action.to_s })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("recurring_assignment #{recurring_assignment_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ManageRecurringAssignmentTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("manage_recurring_assignment failed; the error was logged")
    end
  end
end
```

- [ ] **Step 4: Register. Step 5: Run — expect PASS.** **Step 6: Run the whole unit file** `bin/rails test test/services/mcp/provisioning_tools_test.rb` (all Tasks 1–7 green). **Step 7: Commit** `feat(mcp): manage_recurring_assignment (pause/resume/destroy)`.

---

### Task 8: integration — pin surfaces + happy-paths

**Files:** Modify `test/integration/mcp_write_endpoint_test.rb` and `test/integration/mcp_endpoint_test.rb`.

- [ ] **Step 1: Update the pinned write-surface list.** In `mcp_write_endpoint_test.rb`, set `WRITE_TOOLS` to the full alphabetically-sorted 13-tool set (the test compares against `.sort`):

```ruby
  WRITE_TOOLS = %w[
    archive_project create_assignment create_placeholder create_recurring_assignment
    create_tentative_project delete_assignment ensure_project_tracker ensure_workstream
    manage_recurring_assignment remove_workstream_rate set_project_tracker_role_assignee
    set_project_tracker_work_completed_at update_project_tracker
  ].freeze
```

- [ ] **Step 2: Run** `bin/rails test test/integration/mcp_write_endpoint_test.rb -n "/exposes exactly/"` — expect PASS (live surface equals the list; if not, a tool isn't registered in `write_server.rb`).

- [ ] **Step 3: Add read-surface pin + happy-path.** In `mcp_endpoint_test.rb`, if it pins the read-tool list, add `find_admin_user`. Then append (mirror the file's existing helper style — reuse its `tools_list`/`call_tool` if present):

```ruby
  test "find_admin_user is exposed on the read surface and matches" do
    AdminUser.create!(email: "lead@sanctuary.computer", password: "password123", password_confirmation: "password123", roles: ["admin"])
    assert_includes tools_list("/api/mcp"), "find_admin_user"
    result = call_tool("find_admin_user", { "email" => "lead@sanctuary.computer" })
    assert_equal "lead@sanctuary.computer", result.first["email"]
  end
```

- [ ] **Step 4: Add a write happy-path** in `mcp_write_endpoint_test.rb`:

```ruby
  test "update_project_tracker over the write endpoint replaces a link" do
    tracker = ProjectTracker.new(name: "Endpoint Admin Co").tap { |t| t.save!(validate: false) }
    tracker.project_tracker_links.create!(name: "MSA", url: "https://old/msa", link_type: :msa)
    tracker.project_tracker_links.create!(name: "SOW", url: "https://old/sow", link_type: :sow)
    out = call_tool("update_project_tracker", { "project_tracker_id" => tracker.id, "msa_url" => "https://new/msa" })
    assert_equal "https://new/msa", out["after"]["msa_url"]
  end
```

- [ ] **Step 5: Run both integration files** — expect 0 failures.
- [ ] **Step 6: Run the full MCP suite** `bin/rails test test/services/mcp/ test/integration/mcp_endpoint_test.rb test/integration/mcp_write_endpoint_test.rb` — expect 0 failures.
- [ ] **Step 7: Commit** `test(mcp): pin admin tools on both surfaces + endpoint happy-paths`.

---

## Self-Review (completed during authoring)

**Spec coverage:** find_admin_user (T1) ✓; tracker_json enrichment — budgets/completion/links/leads (T2) ✓ [note: `work_status` dropped from the multi-row read for cost/safety; `work_completed_at` + `completed` bool exposed instead]; update_project_tracker + `update_details!` (T3) ✓; remove_workstream_rate (T4) ✓; set_project_tracker_work_completed_at + `mark_work_completed!`, omitted-vs-null (T5) ✓; set_project_tracker_role_assignee + `set_role_assignee!` monthly handoff, same-month raise, role validation (T6) ✓; manage_recurring_assignment pause/resume/destroy-leaves-Forecast (T7) ✓; integration pins + happy-paths (T8) ✓.

**Placeholder scan:** none — every step has literal code.

**Type consistency:** `ProjectTracker::ROLE_PERIOD_ASSOCIATIONS` defined in T6 model method, referenced by the T6 tool. `ProvisioningSerializers.tracker_json`/`workstream_json` (T2) consumed by T3/T4. `WriteValidation.integer!`/`date!`, `WriteGuard.check!`/`CapExceeded`, `Stacks::Forecast.rate_tag`/`#remove_project_rate!`, `Responses.ok/error` — all match verified source. Model methods `update_details!`/`mark_work_completed!`/`set_role_assignee!` defined in T3/T5/T6 and called only by their own tools.
