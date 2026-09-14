# Provisioning MCP Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the #158 generic provisioning surface (contributors, project trackers, workstreams, rates, recurring assignments) as MCP tools so an agent can satisfy prompts like *"Ensure the Qualitate project has a $450p/h workstream, and set up a weekly recurring assignment for hugh@…"*.

**Architecture:** Thin `MCP::Tool` wrappers over already-tested service methods (`ProjectTracker.provision!`, `#add_workstream!`, `Stacks::Forecast#add_project_rate!`, `RecurringAssignment`). Two read tools register on the read-only `Mcp::Server`; three write tools register on `Mcp::WriteServer`. The MCP layer adds only input validation and idempotent find-or-create glue — no new business logic. Forecast stays hidden: every id crossing the boundary is native (`Contributor#id`, `ProjectTracker#id`, `ProjectTrackerForecastProject#id`).

**Tech Stack:** Ruby on Rails 6.1, the `mcp` gem (`MCP::Tool`/`MCP::Server`), Minitest + Mocha (no WebMock/VCR).

## Global Constraints

- **No `forecast_*` in any tool name, input property, or response field.** Ids are native: contributor = `Contributor#id`, tracker = `ProjectTracker#id`, workstream = `ProjectTrackerForecastProject#id`.
- **House tool pattern (from `app/services/mcp/create_assignment_tool.rb`):** validate EVERYTHING first → `Mcp::WriteGuard.check!` **only on the actual mutate path** → call the service → `Mcp::Responses.ok(payload)`. Rescue order: `rescue ArgumentError, WriteGuard::CapExceeded => e` (surface `e.message`) → `rescue ActiveRecord::RecordNotFound` / `RecordInvalid` (surface a clean message) → `rescue StandardError => e` (`Rails.logger.warn("[Mcp::<Tool>] #{e.class}: #{e.message}")` + `Sentry.capture_exception(e) if defined?(Sentry)` + generic `"<tool> failed; the error was logged"`).
- **`self.call(...)` always takes a trailing `server_context:` keyword** (the gem passes it).
- **Response envelope for write tools:** `Responses.ok({ before:, after:, created: })`; `created` is a boolean.
- **Every tool file lives in `app/services/mcp/`, one class per file, `module Mcp`.** Register in the relevant server's `TOOLS` array.
- **Rate format:** a number or a `"Np/h"` string (e.g. `450`, `"$450p/h"`, `99.75`). Normalize via `Stacks::Forecast.rate_tag(rate)`.
- **Run a single test:** `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/pattern/"`. Run the file: `bin/rails test test/services/mcp/provisioning_tools_test.rb`.

---

## File Structure

- `app/services/mcp/find_contributor_tool.rb` — read tool (Task 1)
- `app/services/mcp/provisioning_serializers.rb` — shared `tracker_json` / `workstream_json` (Task 2)
- `app/services/mcp/list_project_trackers_tool.rb` — read tool (Task 2)
- `app/services/mcp/ensure_project_tracker_tool.rb` — write tool (Task 3)
- `app/services/mcp/ensure_workstream_tool.rb` — write tool (Task 4)
- `app/services/mcp/create_recurring_assignment_tool.rb` — write tool (Task 5)
- `app/services/mcp/server.rb` — register 2 read tools (Tasks 1–2)
- `app/services/mcp/write_server.rb` — register 3 write tools + tighten comment (Tasks 3–5)
- `test/services/mcp/provisioning_tools_test.rb` — unit tests (Tasks 1–5)
- `test/integration/mcp_endpoint_test.rb` / `test/integration/mcp_write_endpoint_test.rb` — surface + happy-path (Task 6)

Data fixtures the tests need (Contributor/ForecastPerson/ForecastProject/ProjectTracker) follow the #158 test conventions: `Contributor` is created via `Contributor.insert!` with explicit `created_at`/`updated_at` (Rails 6.1 `insert!` does NOT auto-populate them and they are NOT NULL); `ForecastPerson`/`ForecastProject`/`ForecastClient` use `self.primary_key = "forecast_id"` so set `forecast_id` explicitly.

---

### Task 1: `find_contributor` read tool

**Files:**
- Create: `app/services/mcp/find_contributor_tool.rb`
- Modify: `app/services/mcp/server.rb` (add to `TOOLS`)
- Test: `test/services/mcp/provisioning_tools_test.rb` (create)

**Interfaces:**
- Produces: `Mcp::FindContributorTool.call(email:, server_context:)` → `Responses` wrapping a JSON array `[{ id, name, email }]`.

- [ ] **Step 1: Write the failing test**

Create `test/services/mcp/provisioning_tools_test.rb`:

```ruby
require 'test_helper'

class Mcp::ProvisioningToolsTest < ActiveSupport::TestCase
  # ---- helpers -------------------------------------------------------------
  def make_contributor(email:, name: "Test Human")
    fp = ForecastPerson.create!(forecast_id: rand(1_000_000..9_999_999), first_name: name.split.first,
                                last_name: name.split.last, email: email, archived: false,
                                roles: [], updated_at: Time.current)
    # Contributor.insert! does not auto-set timestamps on Rails 6.1 (NOT NULL)
    Contributor.insert!({ forecast_person_id: fp.forecast_id, created_at: Time.current, updated_at: Time.current })
    [Contributor.find_by(forecast_person_id: fp.forecast_id), fp]
  end

  def payload(resp)
    JSON.parse(resp.content.first[:text])
  end

  # ---- find_contributor ----------------------------------------------------
  test "find_contributor returns matching contributors by case-insensitive email" do
    c, _fp = make_contributor(email: "hugh@sanctuary.computer", name: "Hugh Person")
    resp = Mcp::FindContributorTool.call(email: "HUGH@Sanctuary.Computer", server_context: {})
    rows = payload(resp)
    assert_equal [c.id], rows.map { |r| r["id"] }
    assert_equal "hugh@sanctuary.computer", rows.first["email"]
  end

  test "find_contributor returns empty array when no match" do
    resp = Mcp::FindContributorTool.call(email: "nobody@example.com", server_context: {})
    assert_equal [], payload(resp)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/find_contributor/"`
Expected: FAIL — `NameError: uninitialized constant Mcp::FindContributorTool`.

(If `ForecastPerson.create!` raises on an unexpected required column, inspect the schema with `bin/rails runner "puts ForecastPerson.columns.reject(&:null).map(&:name)"` and add the missing NOT-NULL columns to `make_contributor` — do not weaken the assertions.)

- [ ] **Step 3: Write minimal implementation**

Create `app/services/mcp/find_contributor_tool.rb`:

```ruby
module Mcp
  class FindContributorTool < MCP::Tool
    tool_name 'find_contributor'
    description 'READ: find contributors by email (exact, case-insensitive). Returns ' \
                '[{id, name, email}]. Use the returned id as contributor_id for ' \
                'create_recurring_assignment.'
    input_schema(
      properties: { email: { type: 'string' } },
      required: %w[email]
    )
    annotations(read_only_hint: true)

    def self.call(email:, server_context:)
      fp_ids = ForecastPerson.where("lower(email) = ?", email.to_s.strip.downcase).select(:forecast_id)
      rows = Contributor.where(forecast_person_id: fp_ids).map do |c|
        { id: c.id, name: c.display_name, email: c.forecast_person&.email }
      end
      Responses.ok(rows)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::FindContributorTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("find_contributor failed; the error was logged")
    end
  end
end
```

- [ ] **Step 4: Register the tool**

In `app/services/mcp/server.rb`, add `Mcp::FindContributorTool,` to the `TOOLS` array (after `Mcp::GetResourcingProjectionsTool,`).

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/find_contributor/"`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add app/services/mcp/find_contributor_tool.rb app/services/mcp/server.rb test/services/mcp/provisioning_tools_test.rb
git commit -m "feat(mcp): find_contributor read tool"
```

---

### Task 2: shared serializers + `list_project_trackers` read tool

**Files:**
- Create: `app/services/mcp/provisioning_serializers.rb`
- Create: `app/services/mcp/list_project_trackers_tool.rb`
- Modify: `app/services/mcp/server.rb` (add to `TOOLS`)
- Test: `test/services/mcp/provisioning_tools_test.rb` (append)

**Interfaces:**
- Produces: `Mcp::ProvisioningSerializers.tracker_json(tracker)` → `{ id, name, client, workstreams: [workstream_json...] }`; `Mcp::ProvisioningSerializers.workstream_json(ptfp)` → `{ id, project_tracker_id, name, code, client, rates: [Float] }`.
- Produces: `Mcp::ListProjectTrackersTool.call(name: nil, client: nil, server_context:)` → JSON array of `tracker_json`.
- Consumes (test data): `ProjectTracker`, `ProjectTrackerForecastProject`, `ForecastProject` (pk `forecast_id`), `ForecastClient` (pk `forecast_id`).

- [ ] **Step 1: Write the failing test**

Append to `test/services/mcp/provisioning_tools_test.rb` (inside the class). Add this workstream helper near the top helpers first:

```ruby
  def make_tracker_with_workstream(tracker_name:, client_name:, code:, rate_tags: [], project_name: nil)
    client = ForecastClient.create!(forecast_id: rand(1_000_000..9_999_999), name: client_name,
                                    archived: false, updated_at: Time.current)
    fp = ForecastProject.create!(forecast_id: rand(1_000_000..9_999_999), name: (project_name || tracker_name),
                                 code: code, client_id: client.forecast_id, archived: false,
                                 tags: rate_tags, updated_at: Time.current)
    tracker = ProjectTracker.create!(name: tracker_name)
    ws = ProjectTrackerForecastProject.create!(project_tracker: tracker, forecast_project_id: fp.forecast_id)
    [tracker, ws, fp, client]
  end
```

Then the tests:

```ruby
  # ---- list_project_trackers ----------------------------------------------
  test "list_project_trackers returns trackers with nested workstreams and rates" do
    tracker, ws, _fp, _client = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Qualitate Inc", code: "QUAL", rate_tags: ["450p/h"])
    resp = Mcp::ListProjectTrackersTool.call(server_context: {})
    row = payload(resp).find { |t| t["id"] == tracker.id }
    assert_equal "Qualitate", row["name"]
    assert_equal "Qualitate Inc", row["client"]
    assert_equal [ws.id], row["workstreams"].map { |w| w["id"] }
    assert_equal [450.0], row["workstreams"].first["rates"]
  end

  test "list_project_trackers filters by case-insensitive name" do
    keep, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Qualitate Inc", code: "QUAL")
    make_tracker_with_workstream(tracker_name: "Other", client_name: "Other Inc", code: "OTHR")
    resp = Mcp::ListProjectTrackersTool.call(name: "qualitate", server_context: {})
    assert_equal [keep.id], payload(resp).map { |t| t["id"] }
  end

  test "list_project_trackers filters by case-insensitive client" do
    keep, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Qualitate Inc", code: "QUAL")
    make_tracker_with_workstream(tracker_name: "Other", client_name: "Other Inc", code: "OTHR")
    resp = Mcp::ListProjectTrackersTool.call(client: "qualitate inc", server_context: {})
    assert_equal [keep.id], payload(resp).map { |t| t["id"] }
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/list_project_trackers/"`
Expected: FAIL — `NameError: uninitialized constant Mcp::ListProjectTrackersTool`.

- [ ] **Step 3: Write the shared serializer**

Create `app/services/mcp/provisioning_serializers.rb`:

```ruby
module Mcp
  # Shared JSON shapes for the provisioning tools. Forecast stays hidden:
  # ids are native (ProjectTracker#id, ProjectTrackerForecastProject#id).
  module ProvisioningSerializers
    module_function

    def tracker_json(tracker)
      {
        id: tracker.id,
        name: tracker.name,
        client: tracker.derived_client&.name,
        workstreams: tracker.project_tracker_forecast_projects.map { |ws| workstream_json(ws) },
      }
    end

    def workstream_json(ws)
      fp = ws.forecast_project
      {
        id: ws.id,
        project_tracker_id: ws.project_tracker_id,
        name: fp&.name,
        code: fp&.code,
        client: fp&.forecast_client&.name,
        rates: Array(fp&.tags).select { |t| t.to_s.end_with?("p/h") }.map(&:to_f),
      }
    end
  end
end
```

- [ ] **Step 4: Write the tool**

Create `app/services/mcp/list_project_trackers_tool.rb`:

```ruby
module Mcp
  class ListProjectTrackersTool < MCP::Tool
    tool_name 'list_project_trackers'
    description 'READ: list project trackers, optionally filtered by name or client ' \
                '(both exact, case-insensitive). Each tracker includes its nested ' \
                'workstreams (id, name, code, rates). Use to find a tracker id or to ' \
                'inspect existing workstreams/rates before ensuring one.'
    input_schema(
      properties: {
        name: { type: 'string' },
        client: { type: 'string' },
      },
      required: []
    )
    annotations(read_only_hint: true)

    def self.call(name: nil, client: nil, server_context:)
      trackers = ProjectTracker.all
      if client.present?
        client_ids = ForecastClient.where("lower(name) = ?", client.strip.downcase).select(:forecast_id)
        fp_ids = ForecastProject.where(client_id: client_ids).select(:forecast_id)
        trackers = trackers.where(id: ProjectTrackerForecastProject.where(forecast_project_id: fp_ids).select(:project_tracker_id))
      end
      trackers = trackers.where("lower(name) = ?", name.strip.downcase) if name.present?
      Responses.ok(trackers.map { |t| ProvisioningSerializers.tracker_json(t) })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ListProjectTrackersTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("list_project_trackers failed; the error was logged")
    end
  end
end
```

- [ ] **Step 5: Register the tool**

In `app/services/mcp/server.rb`, add `Mcp::ListProjectTrackersTool,` to `TOOLS`.

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/list_project_trackers/"`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add app/services/mcp/provisioning_serializers.rb app/services/mcp/list_project_trackers_tool.rb app/services/mcp/server.rb test/services/mcp/provisioning_tools_test.rb
git commit -m "feat(mcp): list_project_trackers read tool + shared serializers"
```

---

### Task 3: `ensure_project_tracker` write tool

**Files:**
- Create: `app/services/mcp/ensure_project_tracker_tool.rb`
- Modify: `app/services/mcp/write_server.rb` (register + tighten comment)
- Test: `test/services/mcp/provisioning_tools_test.rb` (append)

**Interfaces:**
- Consumes: `ProjectTracker.provision!(name:, msa_url:, sow_url:, budget_low_end:, budget_high_end:)` → `[tracker, warnings]`; `Mcp::ProvisioningSerializers.tracker_json`.
- Produces: `Mcp::EnsureProjectTrackerTool.call(name:, msa_url: nil, sow_url: nil, budget_low_end: nil, budget_high_end: nil, server_context:)` → `{ before, after, created, warnings? }`.

- [ ] **Step 1: Write the failing test**

Append to `test/services/mcp/provisioning_tools_test.rb`:

```ruby
  # ---- ensure_project_tracker ---------------------------------------------
  test "ensure_project_tracker creates a bare tracker when none exists" do
    ProjectTracker.expects(:provision!).with(has_entries(name: "New Co")).returns([ProjectTracker.create!(name: "New Co"), ["placeholder MSA"]])
    resp = Mcp::EnsureProjectTrackerTool.call(name: "New Co", server_context: {})
    body = payload(resp)
    assert_equal true, body["created"]
    assert_equal "New Co", body["after"]["name"]
    assert_equal ["placeholder MSA"], body["warnings"]
  end

  test "ensure_project_tracker returns the existing tracker without provisioning" do
    tracker, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Qualitate Inc", code: "QUAL")
    ProjectTracker.expects(:provision!).never
    resp = Mcp::EnsureProjectTrackerTool.call(name: "qualitate", server_context: {})
    body = payload(resp)
    assert_equal false, body["created"]
    assert_equal tracker.id, body["after"]["id"]
  end

  test "ensure_project_tracker errors on an ambiguous name" do
    ProjectTracker.create!(name: "Dup")
    ProjectTracker.create!(name: "Dup")
    ProjectTracker.expects(:provision!).never
    resp = Mcp::EnsureProjectTrackerTool.call(name: "Dup", server_context: {})
    assert_match(/multiple project trackers/i, payload(resp)["error"])
  end

  test "ensure_project_tracker no-op does not consume a write-guard slot" do
    make_tracker_with_workstream(tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")
    Mcp::WriteGuard.expects(:check!).never
    Mcp::EnsureProjectTrackerTool.call(name: "Qualitate", server_context: {})
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/ensure_project_tracker/"`
Expected: FAIL — `NameError: uninitialized constant Mcp::EnsureProjectTrackerTool`.

- [ ] **Step 3: Write the tool**

Create `app/services/mcp/ensure_project_tracker_tool.rb`:

```ruby
module Mcp
  class EnsureProjectTrackerTool < MCP::Tool
    tool_name 'ensure_project_tracker'
    description 'WRITE: ensure a project tracker named <name> exists (idempotent). ' \
                'If none exists, creates a bare tracker with MSA/SOW links (missing ' \
                'links become placeholders and are reported in warnings). If exactly ' \
                'one exists, returns it unchanged. If more than one matches the name, ' \
                'errors — disambiguate with list_project_trackers. Returns ' \
                '{before, after, created, warnings}.'
    input_schema(
      properties: {
        name: { type: 'string' },
        msa_url: { type: 'string' },
        sow_url: { type: 'string' },
        budget_low_end: { type: 'integer' },
        budget_high_end: { type: 'integer' },
      },
      required: %w[name]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(name:, msa_url: nil, sow_url: nil, budget_low_end: nil, budget_high_end: nil, server_context:)
      clean = WriteValidation.short_string!("name", name.to_s.strip, 255)
      raise ArgumentError, "name must be non-empty" if clean.empty?

      matches = ProjectTracker.where("lower(name) = ?", clean.downcase).to_a
      if matches.length > 1
        raise ArgumentError, "multiple project trackers named '#{clean}'; disambiguate with list_project_trackers and use the specific id"
      elsif matches.length == 1
        json = ProvisioningSerializers.tracker_json(matches.first)
        return Responses.ok({ before: json, after: json, created: false })
      end

      WriteGuard.check!
      tracker, warnings = ProjectTracker.provision!(
        name: clean, msa_url: msa_url, sow_url: sow_url,
        budget_low_end: budget_low_end, budget_high_end: budget_high_end,
      )
      Responses.ok({ before: nil, after: ProvisioningSerializers.tracker_json(tracker), created: true, warnings: warnings })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::EnsureProjectTrackerTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("ensure_project_tracker failed; the error was logged")
    end
  end
end
```

- [ ] **Step 4: Register the tool + tighten the surface comment**

In `app/services/mcp/write_server.rb`:
1. Add `Mcp::EnsureProjectTrackerTool,` to `TOOLS`.
2. Change the class comment from:
   `# projection-plane tools exist here — actuals, rates, and money have no`
   `# tools, so no composition can reach them.`
   to:
   `# projection-plane and provisioning tools exist here. Actuals & billing`
   `# money (what a contributor is paid / a client is invoiced) have no tools,`
   `# so no composition can reach them; a project's p/h rate-card tag is`
   `# provisioning setup, not a money-actual.`

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/ensure_project_tracker/"`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add app/services/mcp/ensure_project_tracker_tool.rb app/services/mcp/write_server.rb test/services/mcp/provisioning_tools_test.rb
git commit -m "feat(mcp): ensure_project_tracker write tool; scope write-surface comment to actuals & billing money"
```

---

### Task 4: `ensure_workstream` write tool

**Files:**
- Create: `app/services/mcp/ensure_workstream_tool.rb`
- Modify: `app/services/mcp/write_server.rb` (register)
- Test: `test/services/mcp/provisioning_tools_test.rb` (append)

**Interfaces:**
- Consumes: `ProjectTracker#add_workstream!(name:, code:, rate:, client_name:)` → `ProjectTrackerForecastProject`; `Stacks::Forecast#add_project_rate!(forecast_id, rate)`; `Stacks::Forecast.rate_tag(rate)`; `Mcp::ProvisioningSerializers.workstream_json`.
- Produces: `Mcp::EnsureWorkstreamTool.call(project_tracker_id:, name:, code:, rate:, client_name: nil, server_context:)` → `{ before, after, created, rate_added }`.

- [ ] **Step 1: Write the failing test**

Append to `test/services/mcp/provisioning_tools_test.rb`:

```ruby
  # ---- ensure_workstream ---------------------------------------------------
  test "ensure_workstream creates a workstream when the code is absent" do
    tracker = ProjectTracker.create!(name: "Qualitate")
    fake_ws = ProjectTrackerForecastProject.new(id: 123, project_tracker: tracker, forecast_project_id: 999)
    ProjectTracker.any_instance.expects(:add_workstream!).with(
      name: "Qualitate", code: "QUAL", rate: "450p/h", client_name: "Qualitate Inc"
    ).returns(fake_ws)
    Mcp::ProvisioningSerializers.stubs(:workstream_json).with(fake_ws).returns({ id: 123, code: "QUAL" })

    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Qualitate", code: "QUAL",
      rate: "450p/h", client_name: "Qualitate Inc", server_context: {})
    body = payload(resp)
    assert_equal true, body["created"]
    assert_equal true, body["rate_added"]
  end

  test "ensure_workstream adds a missing rate to an existing workstream" do
    tracker, ws, fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL", rate_tags: ["300p/h"])
    Stacks::Forecast.any_instance.expects(:add_project_rate!).with(fp.forecast_id, "450p/h").returns(true)

    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Qualitate", code: "QUAL", rate: "450p/h", server_context: {})
    body = payload(resp)
    assert_equal false, body["created"]
    assert_equal true, body["rate_added"]
  end

  test "ensure_workstream is a no-op when the rate is already present (no cap, no API)" do
    tracker, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL", rate_tags: ["450p/h"])
    Stacks::Forecast.any_instance.expects(:add_project_rate!).never
    Mcp::WriteGuard.expects(:check!).never

    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Qualitate", code: "QUAL", rate: "450p/h", server_context: {})
    body = payload(resp)
    assert_equal false, body["created"]
    assert_equal false, body["rate_added"]
  end

  test "ensure_workstream surfaces the 'client required' validation for a first workstream" do
    tracker = ProjectTracker.create!(name: "Bare")
    # add_workstream! raises RecordInvalid when no client is derivable and none is given
    inv = ProjectTracker.new
    inv.errors.add(:base, "A client is required for the first workstream.")
    ProjectTracker.any_instance.expects(:add_workstream!).raises(ActiveRecord::RecordInvalid.new(inv))

    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Bare", code: "BARE", rate: "450p/h", server_context: {})
    assert_match(/client is required/i, payload(resp)["error"])
  end

  test "ensure_workstream rejects a non-positive rate before any work" do
    tracker = ProjectTracker.create!(name: "Qualitate")
    ProjectTracker.any_instance.expects(:add_workstream!).never
    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Q", code: "QUAL", rate: "0", server_context: {})
    assert_match(/rate must be a positive/i, payload(resp)["error"])
  end

  test "ensure_workstream reports a missing tracker cleanly" do
    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: 999_999, name: "Q", code: "QUAL", rate: "450p/h", server_context: {})
    assert_match(/not found/i, payload(resp)["error"])
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/ensure_workstream/"`
Expected: FAIL — `NameError: uninitialized constant Mcp::EnsureWorkstreamTool`.

- [ ] **Step 3: Write the tool**

Create `app/services/mcp/ensure_workstream_tool.rb`:

```ruby
module Mcp
  class EnsureWorkstreamTool < MCP::Tool
    tool_name 'ensure_workstream'
    description 'WRITE: ensure a workstream with the given code exists on a project ' \
                'tracker at the given rate (idempotent). If the code is absent, creates ' \
                'the workstream — a tracker\'s FIRST workstream also needs client_name. ' \
                'If the code is present, adds the rate only if missing. rate is a number ' \
                'or "Np/h" string (e.g. 450 or "450p/h"). Returns ' \
                '{before, after, created, rate_added}.'
    input_schema(
      properties: {
        project_tracker_id: { type: 'integer' },
        name: { type: 'string' },
        code: { type: 'string' },
        rate: { type: 'string', description: 'number or "Np/h", e.g. "450p/h"' },
        client_name: { type: 'string', description: 'required for a tracker\'s first workstream' },
      },
      required: %w[project_tracker_id name code rate]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(project_tracker_id:, name:, code:, rate:, client_name: nil, server_context:)
      ptid = WriteValidation.integer!("project_tracker_id", project_tracker_id)
      nm = WriteValidation.short_string!("name", name.to_s.strip, 255)
      cd = WriteValidation.short_string!("code", code.to_s.strip, 255)
      raise ArgumentError, "name must be non-empty" if nm.empty?
      raise ArgumentError, "code must be non-empty" if cd.empty?
      validate_rate!(rate)

      tracker = ProjectTracker.find(ptid)
      existing = tracker.project_tracker_forecast_projects.detect { |ws| ws.forecast_project&.code == cd }

      if existing
        tag = Stacks::Forecast.rate_tag(rate)
        already = Array(existing.forecast_project&.tags).include?(tag)
        if already
          json = ProvisioningSerializers.workstream_json(existing)
          return Responses.ok({ before: json, after: json, created: false, rate_added: false })
        end
        before = ProvisioningSerializers.workstream_json(existing)
        WriteGuard.check!
        Stacks::Forecast.new.add_project_rate!(existing.forecast_project_id, rate)
        return Responses.ok({ before: before, after: ProvisioningSerializers.workstream_json(existing.reload), created: false, rate_added: true })
      end

      WriteGuard.check!
      ws = tracker.add_workstream!(name: nm, code: cd, rate: rate, client_name: client_name)
      Responses.ok({ before: nil, after: ProvisioningSerializers.workstream_json(ws), created: true, rate_added: true })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("project_tracker #{project_tracker_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::EnsureWorkstreamTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("ensure_workstream failed; the error was logged")
    end

    def self.validate_rate!(rate)
      s = rate.to_s.delete("$").strip.sub(/p\/h\z/, "")
      f = begin
        Float(s)
      rescue ArgumentError, TypeError
        nil
      end
      raise ArgumentError, 'rate must be a positive number or "Np/h" string' if f.nil? || f <= 0
    end
  end
end
```

- [ ] **Step 4: Register the tool**

In `app/services/mcp/write_server.rb`, add `Mcp::EnsureWorkstreamTool,` to `TOOLS`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/ensure_workstream/"`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add app/services/mcp/ensure_workstream_tool.rb app/services/mcp/write_server.rb test/services/mcp/provisioning_tools_test.rb
git commit -m "feat(mcp): ensure_workstream write tool (idempotent rate add)"
```

---

### Task 5: `create_recurring_assignment` write tool

**Files:**
- Create: `app/services/mcp/create_recurring_assignment_tool.rb`
- Modify: `app/services/mcp/write_server.rb` (register)
- Test: `test/services/mcp/provisioning_tools_test.rb` (append)

**Interfaces:**
- Consumes: `Contributor#forecast_person_id`, `ProjectTrackerForecastProject#forecast_project_id`, `RecurringAssignment` (`allocation_in_hours=`, `active` scope, `weekdays`, `starts_on`, `ends_on`, `notes`, `active_on_days_off`).
- Produces: `Mcp::CreateRecurringAssignmentTool.call(contributor_id:, workstream_id:, allocation_hours: 8, weekdays: [1,2,3,4,5], starts_on: nil, ends_on: nil, notes: nil, active_on_days_off: false, server_context:)` → `{ before, after, created }`.

- [ ] **Step 1: Write the failing test**

Append to `test/services/mcp/provisioning_tools_test.rb`:

```ruby
  # ---- create_recurring_assignment ----------------------------------------
  test "create_recurring_assignment creates a rule with defaults (8h/Mon-Fri/today)" do
    c, fp = make_contributor(email: "hugh@sanctuary.computer")
    _t, ws, _proj, _cl = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")

    resp = Mcp::CreateRecurringAssignmentTool.call(
      contributor_id: c.id, workstream_id: ws.id, server_context: {})
    body = payload(resp)
    assert_equal true, body["created"]
    ra = RecurringAssignment.find(body["after"]["id"])
    assert_equal fp.forecast_id, ra.forecast_person_id
    assert_equal ws.forecast_project_id, ra.forecast_project_id
    assert_equal [1, 2, 3, 4, 5], ra.weekdays
    assert_equal 8.0, ra.allocation_in_hours
    assert_equal Date.today, ra.starts_on
  end

  test "create_recurring_assignment honors weekly cadence and overrides" do
    c, _fp = make_contributor(email: "hugh@sanctuary.computer")
    _t, ws, _proj, _cl = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")

    resp = Mcp::CreateRecurringAssignmentTool.call(
      contributor_id: c.id, workstream_id: ws.id, weekdays: [1], allocation_hours: 4,
      starts_on: "2026-08-03", server_context: {})
    ra = RecurringAssignment.find(payload(resp)["after"]["id"])
    assert_equal [1], ra.weekdays
    assert_equal 4.0, ra.allocation_in_hours
    assert_equal Date.new(2026, 8, 3), ra.starts_on
  end

  test "create_recurring_assignment returns the existing active rule instead of duplicating" do
    c, fp = make_contributor(email: "hugh@sanctuary.computer")
    _t, ws, _proj, _cl = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")
    existing = RecurringAssignment.create!(
      forecast_person_id: fp.forecast_id, forecast_project_id: ws.forecast_project_id,
      allocation: 8 * 3600, weekdays: [1, 2, 3, 4, 5], starts_on: Date.today)

    assert_no_difference -> { RecurringAssignment.count } do
      resp = Mcp::CreateRecurringAssignmentTool.call(
        contributor_id: c.id, workstream_id: ws.id, server_context: {})
      body = payload(resp)
      assert_equal false, body["created"]
      assert_equal existing.id, body["after"]["id"]
    end
  end

  test "create_recurring_assignment rejects an empty or out-of-range weekdays list" do
    c, _fp = make_contributor(email: "hugh@sanctuary.computer")
    _t, ws, _proj, _cl = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")
    resp = Mcp::CreateRecurringAssignmentTool.call(
      contributor_id: c.id, workstream_id: ws.id, weekdays: [9], server_context: {})
    assert_match(/weekdays/i, payload(resp)["error"])
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/create_recurring_assignment/"`
Expected: FAIL — `NameError: uninitialized constant Mcp::CreateRecurringAssignmentTool`.

- [ ] **Step 3: Write the tool**

Create `app/services/mcp/create_recurring_assignment_tool.rb`:

```ruby
module Mcp
  class CreateRecurringAssignmentTool < MCP::Tool
    tool_name 'create_recurring_assignment'
    description 'WRITE: create a recurring assignment for a contributor on a workstream ' \
                '(idempotent per contributor+workstream — if an ACTIVE rule already ' \
                'exists for that pair it is returned unchanged). Defaults: 8h/day, ' \
                'Mon-Fri, starts today, never ends. weekdays are 0=Sun..6=Sat (weekly = ' \
                'a single weekday, e.g. [1]). Returns {before, after, created}.'
    input_schema(
      properties: {
        contributor_id: { type: 'integer' },
        workstream_id: { type: 'integer' },
        allocation_hours: { type: 'number', description: 'default 8' },
        weekdays: { type: 'array', items: { type: 'integer' }, description: '0=Sun..6=Sat; default Mon-Fri' },
        starts_on: { type: 'string', description: 'YYYY-MM-DD; default today' },
        ends_on: { type: 'string', description: 'YYYY-MM-DD; omit = never ends' },
        notes: { type: 'string' },
        active_on_days_off: { type: 'boolean' },
      },
      required: %w[contributor_id workstream_id]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(contributor_id:, workstream_id:, allocation_hours: 8, weekdays: [1, 2, 3, 4, 5],
                  starts_on: nil, ends_on: nil, notes: nil, active_on_days_off: false, server_context:)
      cid = WriteValidation.integer!("contributor_id", contributor_id)
      wid = WriteValidation.integer!("workstream_id", workstream_id)
      days = Array(weekdays).map { |d| WriteValidation.integer!("weekdays", d) }
      raise ArgumentError, "weekdays must be a non-empty subset of 0..6" if days.empty? || days.any? { |d| !(0..6).cover?(d) }
      hours = begin
        Float(allocation_hours)
      rescue ArgumentError, TypeError
        nil
      end
      raise ArgumentError, "allocation_hours must be greater than 0" if hours.nil? || hours <= 0
      start_date = starts_on.present? ? WriteValidation.date!("starts_on", starts_on) : Date.today
      end_date = ends_on.present? ? WriteValidation.date!("ends_on", ends_on) : nil
      raise ArgumentError, "ends_on must be on or after starts_on" if end_date && end_date < start_date
      note = notes.nil? ? "" : WriteValidation.short_string!("notes", notes, 2000)

      contributor = Contributor.find(cid)
      workstream = ProjectTrackerForecastProject.find(wid)

      existing = RecurringAssignment.active.find_by(
        forecast_person_id: contributor.forecast_person_id,
        forecast_project_id: workstream.forecast_project_id,
      )
      if existing
        return Responses.ok({ before: ra_json(existing, contributor, workstream), after: ra_json(existing, contributor, workstream), created: false })
      end

      WriteGuard.check!
      ra = RecurringAssignment.new(
        forecast_person_id: contributor.forecast_person_id,
        forecast_project_id: workstream.forecast_project_id,
        weekdays: days,
        starts_on: start_date,
        ends_on: end_date,
        notes: note,
        active_on_days_off: active_on_days_off ? true : false,
      )
      ra.allocation_in_hours = hours
      ra.save!
      Responses.ok({ before: nil, after: ra_json(ra, contributor, workstream), created: true })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("contributor or workstream not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::CreateRecurringAssignmentTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("create_recurring_assignment failed; the error was logged")
    end

    def self.ra_json(ra, contributor, workstream)
      {
        id: ra.id, contributor_id: contributor.id, workstream_id: workstream.id,
        allocation_hours: ra.allocation_in_hours, weekdays: ra.weekdays,
        starts_on: ra.starts_on, ends_on: ra.ends_on,
      }
    end
  end
end
```

- [ ] **Step 4: Register the tool**

In `app/services/mcp/write_server.rb`, add `Mcp::CreateRecurringAssignmentTool,` to `TOOLS`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb -n "/create_recurring_assignment/"`
Expected: PASS (4 tests).

- [ ] **Step 6: Run the whole unit file**

Run: `bin/rails test test/services/mcp/provisioning_tools_test.rb`
Expected: PASS (all tests across Tasks 1–5, 0 failures).

- [ ] **Step 7: Commit**

```bash
git add app/services/mcp/create_recurring_assignment_tool.rb app/services/mcp/write_server.rb test/services/mcp/provisioning_tools_test.rb
git commit -m "feat(mcp): create_recurring_assignment write tool (idempotent per contributor+workstream)"
```

---

### Task 6: integration — surface registration + happy-path over the endpoints

**Files:**
- Modify: `test/integration/mcp_write_endpoint_test.rb` (update pinned `WRITE_TOOLS`; add happy-path)
- Modify: `test/integration/mcp_endpoint_test.rb` (add read-tool presence + happy-path)

**Interfaces:**
- Consumes: the JSON-RPC endpoints `/api/mcp` (read) and `/api/mcp/write` (write); the `call_tool` / `tools_list` helpers already defined in each integration test.

- [ ] **Step 1: Update the pinned write-surface list (this will currently FAIL)**

In `test/integration/mcp_write_endpoint_test.rb`, the constant `WRITE_TOOLS` and the test `"write surface exposes exactly the five write tools"` pin the OLD set. Update the constant to include the three new tools (keep it alphabetically sorted, since the test compares against `.sort`):

```ruby
  WRITE_TOOLS = %w[
    archive_project create_assignment create_placeholder create_recurring_assignment
    create_tentative_project delete_assignment ensure_project_tracker ensure_workstream
  ].freeze
```

Also rename the test so it no longer says "five" — change the test name string to `"write surface exposes exactly the provisioning + projection write tools"` (leave the body: `assert_equal WRITE_TOOLS, tools_list("/api/mcp/write").sort`).

- [ ] **Step 2: Run it to verify the surface matches**

Run: `bin/rails test test/integration/mcp_write_endpoint_test.rb -n "/exposes exactly/"`
Expected: PASS — the live write surface now equals the updated list. (If it fails, a tool is not registered in `write_server.rb`; fix the registration.)

- [ ] **Step 3: Add a write happy-path integration test**

Append inside the `McpWriteEndpointTest` class (the `setup` already clears the write-guard counter):

```ruby
  test "ensure_project_tracker over the write endpoint creates and is idempotent" do
    ProjectTracker.expects(:provision!).once.with(has_entries(name: "Endpoint Co"))
      .returns([ProjectTracker.create!(name: "Endpoint Co"), []])

    created = call_tool("ensure_project_tracker", { "name" => "Endpoint Co" })
    assert_equal true, created["created"]

    # second call finds the now-existing tracker; provision! is NOT called again
    found = call_tool("ensure_project_tracker", { "name" => "Endpoint Co" })
    assert_equal false, found["created"]
  end
```

- [ ] **Step 4: Add read-surface coverage**

Open `test/integration/mcp_endpoint_test.rb`, find how it lists tools (a `tools_list("/api/mcp")` helper or inline `tools/list` POST — reuse whichever exists). If the file pins an exact read-tool list, add `find_contributor` and `list_project_trackers` to it. Then append a happy-path test using the same helper style already in that file:

```ruby
  test "find_contributor is exposed on the read surface and returns matches" do
    fp = ForecastPerson.create!(forecast_id: 7_654_321, first_name: "Hugh", last_name: "Person",
                                email: "hugh@sanctuary.computer", archived: false, roles: [], updated_at: Time.current)
    Contributor.insert!({ forecast_person_id: fp.forecast_id, created_at: Time.current, updated_at: Time.current })

    names = tools_list("/api/mcp")
    assert_includes names, "find_contributor"
    assert_includes names, "list_project_trackers"

    result = call_tool("find_contributor", { "email" => "hugh@sanctuary.computer" })
    assert_equal "hugh@sanctuary.computer", result.first["email"]
  end
```

Note: `mcp_endpoint_test.rb` may name its helpers differently (e.g. no `call_tool`). If so, mirror the exact POST-and-parse style already present in that file rather than assuming these helper names. Do not add auth helpers that already exist.

- [ ] **Step 5: Run both integration files**

Run: `bin/rails test test/integration/mcp_write_endpoint_test.rb test/integration/mcp_endpoint_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 6: Run the full MCP suite**

Run: `bin/rails test test/services/mcp/ test/integration/mcp_endpoint_test.rb test/integration/mcp_write_endpoint_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add test/integration/mcp_write_endpoint_test.rb test/integration/mcp_endpoint_test.rb
git commit -m "test(mcp): pin provisioning tools on both surfaces + endpoint happy-paths"
```

---

## Self-Review (completed during authoring)

**Spec coverage:**
- find_contributor → Task 1 ✓
- list_project_trackers (nested workstreams, name/client filters, YAGNI no list_workstreams) → Task 2 ✓
- ensure_project_tracker (0→provision!, 1→found, >1→error, no-op no cap) → Task 3 ✓
- ensure_workstream (create / add-missing-rate / no-op / client-required / code-collision inherited / no-op no cap) → Task 4 ✓
- create_recurring_assignment (defaults, overrides, duplicate-active guard, weekday validation) → Task 5 ✓
- Boundary reframe (write_server comment) → Task 3 Step 4 ✓
- Registration on both surfaces → Tasks 1–5 ✓
- Two-tier rescue + validate-before-cap + cap-only-on-mutate → every write tool ✓
- Integration surface pin update (the pinned "five write tools" test) → Task 6 ✓

**Placeholder scan:** none — every step has literal code.

**Type consistency:** `ProvisioningSerializers.tracker_json`/`workstream_json` defined in Task 2, consumed by Tasks 2–4 with matching names. `Responses.ok`/`Responses.error`, `WriteValidation.integer!/short_string!/date!`, `WriteGuard.check!`/`CapExceeded`, `Stacks::Forecast.rate_tag`/`#add_project_rate!`, `ProjectTracker.provision!`/`#add_workstream!`, `RecurringAssignment#allocation_in_hours=`/`.active` — all match the verified source on `origin/main`.
