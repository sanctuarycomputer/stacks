# Provisioning API — Generic Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Rework the provisioning HTTP API (branch `feat/provisioning-http-api`) so it speaks generic Stacks-native terms — **contributors, project_trackers, workstreams, rates, recurring_assignments** — and never exposes Forecast. Also fix error handling to use the global handler (defining the missing `Stacks::Errors::Unexpected`).

**Architecture:** Forecast stays an internal implementation detail; controllers translate generic ids → Forecast ids at a thin seam (like `Api::V1::ProjectedAssignmentsController` + `Resourcing::RunnPersonResolver`). Internal models keep Forecast ids. A "workstream" is a `ProjectTrackerForecastProject` join row (native id) wrapping a `ForecastProject`. Client is find-or-created under the hood on the first workstream.

**Tech Stack:** Rails 6.1, Postgres, HTTParty, Minitest + Mocha. Forecast stubbed at the class-method level; controller tests stub `Stacks::Forecast.new`.

## Global Constraints

- **No `forecast_*` in any route, param, or response.** Generic surface only.
- Controllers inherit `ApiController`; write controllers add `skip_before_action :verify_authenticity_token` + `before_action :check_private_api_key!`; reads just the key check. Routes inside `namespace :api`.
- **No per-controller `rescue` blocks** — rely on the global `HandlesExceptions#handle_for_json` (RecordInvalid→422-details, ParameterMissing→422, else→`Stacks::Errors::Unexpected`→generic 500).
- Every Forecast write upserts the local mirror in-request (`upsert_all(unique_by: :forecast_id)`), mapping columns per the matching `sync_*!` method.
- Workstream identity = `ProjectTrackerForecastProject.id` (native). Contributor id = `Contributor.id` (native). `contributor.forecast_person_id` already equals the ForecastPerson `forecast_id`; the join's `forecast_project_id` already equals the ForecastProject `forecast_id`.
- Rates: numeric; add/remove one `…p/h` tag, multi-rate-safe; rate travels in body/query, never a path segment.
- `Stacks::Forecast.new` needs creds absent in test: unit tests use `Stacks::Forecast.allocate` + `instance_variable_set(:@headers, {})`; controller tests stub `Stacks::Forecast.stubs(:new).returns(fake)`.
- Commit after each task; Co-Authored-By trailer.

---

### Task 1: Define `Stacks::Errors::Unexpected` (fix the global handler) + drop bespoke rescues

**Files:**
- Modify: `lib/stacks/errors.rb`
- Modify: `app/controllers/api/forecast_projects_controller.rb`, `project_trackers_controller.rb`, `recurring_assignments_controller.rb` (remove their `rescue`/`render_error` — these are rewritten in later tasks, but strip the rescues now so error handling is global from here on)
- Test: `test/lib/stacks/errors_test.rb`

**Interfaces:**
- Produces: `Stacks::Errors::Unexpected.new(detail, exception=nil)` — `status :internal_server_error`, generic `detail` (never echoes `exception.message`), logs + Sentry-captures the exception.

- [ ] **Step 1: Write the failing test** — `test/lib/stacks/errors_test.rb`:

```ruby
require "test_helper"

class StacksErrorsTest < ActiveSupport::TestCase
  test "Unexpected is defined, renders a generic 500, and does not leak the underlying message" do
    err = Stacks::Errors::Unexpected.new("Unhandled exception", RuntimeError.new("SECRET upstream body"))
    assert_equal :internal_server_error, err.status
    body = err.as_json.to_json
    assert_includes body, "Unexpected Error"
    refute_includes body, "SECRET upstream body"
  end
end
```

- [ ] **Step 2: Run to verify red** — `bin/rails test test/lib/stacks/errors_test.rb` → FAIL (`uninitialized constant Stacks::Errors::Unexpected`).

- [ ] **Step 3: Implement** — in `lib/stacks/errors.rb`, before the final `end` that closes `module Stacks::Errors`, add:

```ruby
  # Raised by the API exception handler for genuinely-unexpected errors. Renders a
  # generic 500 that NEVER echoes the underlying exception's message (which may carry
  # upstream response bodies), while logging + Sentry-capturing the real exception.
  class Unexpected < Stacks::Errors::Base
    def initialize(detail, exception = nil)
      @detail = detail
      if exception
        Rails.logger.warn("[Stacks::Errors::Unexpected] #{exception.class}: #{exception.message}")
        Sentry.capture_exception(exception) if defined?(Sentry)
      end
    end

    def title; 'Unexpected Error'; end
    def detail; @detail; end
    def source; nil; end
    def status; :internal_server_error; end
  end
```

Then remove the bespoke error handling from the three existing controllers: delete the private `render_error` method and each `rescue => e ... end` (and the `rescue ActiveRecord::RecordInvalid`/`rescue ActionController::ParameterMissing` branches) so the actions simply run and let exceptions propagate to `ApiController`'s global handler. (These controllers are rewritten in Tasks 4–6; this just removes the now-redundant rescues.)

- [ ] **Step 4: Run to verify green** — `bin/rails test test/lib/stacks/errors_test.rb` and `bin/rails test test/integration/api/` (existing controller tests still pass — validation now flows through the global handler; if any asserted a bespoke message/status, update it to the global handler's shape: RecordInvalid/ParameterMissing → 422).

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/errors.rb app/controllers/api/*.rb test/lib/stacks/errors_test.rb
git commit -m "fix(errors): define Stacks::Errors::Unexpected; drop bespoke API rescues for the global handler"
```

---

### Task 2: `Stacks::Forecast#create_client` + `#find_or_create_client!`

**Files:**
- Modify: `lib/stacks/forecast.rb`
- Test: `test/lib/stacks/forecast_test.rb`

**Interfaces:**
- Produces:
  - `#create_client(name:)` → parsed `"client"` Hash (incl. `"id"`); upserts local `ForecastClient`. Raises on non-2xx.
  - `#find_or_create_client!(name)` → a local `ForecastClient` (existing case-insensitive match, else created).

- [ ] **Step 1: Write failing tests** (reuse `build_forecast_client`):

```ruby
test "create_client POSTs the envelope and upserts the local mirror" do
  fc = build_forecast_client
  resp = mock("r"); resp.stubs(:success?).returns(true)
  resp.stubs(:parsed_response).returns({ "client" => { "id" => 42, "name" => "Qualitate", "archived" => false } })
  posted = {}
  Stacks::Forecast.expects(:post).once.with { |path, opts| posted[:path]=path; posted[:body]=JSON.parse(opts[:body]); true }.returns(resp)

  result = fc.create_client(name: "Qualitate")
  assert_equal 42, result["id"]
  assert_equal "/clients", posted[:path]
  assert_equal "Qualitate", posted[:body]["client"]["name"]
  assert_equal "Qualitate", ForecastClient.find_by(forecast_id: 42).name
end

test "find_or_create_client! returns an existing client without POSTing" do
  ForecastClient.new(forecast_id: 7, name: "Acme").save!(validate: false)
  fc = build_forecast_client
  Stacks::Forecast.expects(:post).never
  assert_equal 7, fc.find_or_create_client!("acme").forecast_id
end

test "find_or_create_client! creates when absent" do
  fc = build_forecast_client
  resp = mock("r"); resp.stubs(:success?).returns(true)
  resp.stubs(:parsed_response).returns({ "client" => { "id" => 99, "name" => "NewCo" } })
  Stacks::Forecast.expects(:post).once.returns(resp)
  assert_equal 99, fc.find_or_create_client!("NewCo").forecast_id
end
```

- [ ] **Step 2: Run to verify red.**

- [ ] **Step 3: Implement** — add to `lib/stacks/forecast.rb`:

```ruby
def create_client(name:)
  body = { client: { name: name } }
  response = self.class.post("/clients", headers: write_headers, body: JSON.dump(body))
  raise "Forecast create_client failed: #{response.code} #{response.body}" unless response.success?
  client = response.parsed_response["client"]
  upsert_client_locally!(client)
  client
end

def find_or_create_client!(name)
  existing = ForecastClient.where("lower(name) = ?", name.to_s.strip.downcase).first
  return existing if existing
  created = create_client(name: name)
  ForecastClient.find_by(forecast_id: created["id"])
end
```

private:

```ruby
def upsert_client_locally!(c)
  ForecastClient.upsert_all([{
    forecast_id: c["id"], name: c["name"], harvest_id: c["harvest_id"],
    archived: c["archived"], updated_at: c["updated_at"], updated_by_id: c["updated_by_id"], data: c,
  }], unique_by: :forecast_id)
end
```

- [ ] **Step 4: Run to verify green.**

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/forecast.rb test/lib/stacks/forecast_test.rb
git commit -m "feat(forecast): create_client + find_or_create_client! with mirror upsert"
```

---

### Task 3: `ProjectTracker#add_workstream!` + make `provision!` workstream-optional

**Files:**
- Modify: `app/models/project_tracker.rb`
- Test: `test/models/project_tracker_workstream_test.rb`

**Interfaces:**
- Consumes: `Stacks::Forecast#find_or_create_client!`, `#create_project`, `.rate_tag`.
- Produces:
  - `provision!(name:, msa_url: nil, sow_url: nil, budget_low_end: nil, budget_high_end: nil)` — the `forecast_project_ids:` param is **removed** (a tracker is created bare; workstreams are added separately).
  - `#add_workstream!(name:, code:, rate: nil, client_name: nil, forecast_client: Stacks::Forecast.new)` → the created `ProjectTrackerForecastProject` (the workstream). Uses the tracker's existing client if it has one; else find-or-creates by `client_name` (raises `ArgumentError` if neither).
  - `#derived_client` → `forecast_projects.first&.forecast_client`.

- [ ] **Step 1: Write failing tests** — `test/models/project_tracker_workstream_test.rb`:

```ruby
require "test_helper"

class ProjectTrackerWorkstreamTest < ActiveSupport::TestCase
  def tracker
    ProjectTracker.provision!(name: "Qualitate", msa_url: "https://e.com/m", sow_url: "https://e.com/s").first
  end

  # A fake Stacks::Forecast whose create_project ALSO creates the local mirror row
  # (real create_project mirrors; the stub must too, so the join's belongs_to resolves).
  def fake_forecast(project_forecast_id:, client:)
    fc = Object.new
    fc.define_singleton_method(:find_or_create_client!) { |_name| client }
    fc.define_singleton_method(:create_project) do |client_id:, name:, code:, tags: [], notes: ""|
      ForecastProject.new(forecast_id: project_forecast_id, client_id: client_id, name: name, code: code, tags: tags).save!(validate: false)
      { "id" => project_forecast_id, "code" => code, "tags" => tags }
    end
    fc
  end

  test "first workstream find-or-creates the client and attaches a coded project" do
    client = ForecastClient.new(forecast_id: 42, name: "Qualitate").tap { |c| c.save!(validate: false) }
    t = tracker
    ws = t.add_workstream!(name: "Design", code: "QUAL-1", rate: 450, client_name: "Qualitate",
                           forecast_client: fake_forecast(project_forecast_id: 5001, client: client))
    assert_kind_of ProjectTrackerForecastProject, ws
    assert_equal 5001, ws.forecast_project_id
    assert_equal [5001], t.reload.forecast_projects.map(&:forecast_id)
    assert_equal ["450p/h"], ForecastProject.find_by(forecast_id: 5001).tags
  end

  test "subsequent workstream reuses the tracker's existing client" do
    client = ForecastClient.new(forecast_id: 42, name: "Qualitate").tap { |c| c.save!(validate: false) }
    t = tracker
    t.add_workstream!(name: "A", code: "QUAL-1", client_name: "Qualitate",
                      forecast_client: fake_forecast(project_forecast_id: 5001, client: client))
    # second add: no client_name; must reuse client 42 via derived_client
    fc2 = Object.new
    fc2.define_singleton_method(:create_project) do |client_id:, name:, code:, tags: [], notes: ""|
      raise "wrong client" unless client_id == 42
      ForecastProject.new(forecast_id: 5002, client_id: client_id, name: name, code: code, tags: tags).save!(validate: false)
      { "id" => 5002 }
    end
    ws2 = t.reload.add_workstream!(name: "B", code: "QUAL-2", forecast_client: fc2)
    assert_equal 5002, ws2.forecast_project_id
  end

  test "raises when the first workstream has no client to resolve" do
    t = tracker
    assert_raises(ArgumentError) { t.add_workstream!(name: "X", code: "C", forecast_client: Object.new) }
  end
end
```

- [ ] **Step 2: Run to verify red.**

- [ ] **Step 3: Implement** — edit `provision!` to drop `forecast_project_ids:` and its attach loop (delete lines 97–99 in the current method), then add:

```ruby
def derived_client
  forecast_projects.first&.forecast_client
end

# Adds a workstream (a rate-bearing schedulable strip) to this tracker. Resolves the
# client from the tracker's existing workstreams, else find-or-creates it by name (the
# first workstream establishes the tracker's client). Creates the underlying Forecast
# project (outside a txn, per the create-external-then-link convention) and links it.
def add_workstream!(name:, code:, rate: nil, client_name: nil, forecast_client: Stacks::Forecast.new)
  client = derived_client
  client ||= forecast_client.find_or_create_client!(client_name) if client_name.present?
  raise ArgumentError, "a client is required for the first workstream" if client.nil?

  tags = rate.present? ? [Stacks::Forecast.rate_tag(rate)] : []
  project = forecast_client.create_project(client_id: client.forecast_id, name: name, code: code, tags: tags)
  transaction { project_tracker_forecast_projects.create!(forecast_project_id: project["id"]) }
end
```

- [ ] **Step 4: Run to verify green** (also re-run `test/models/project_tracker_provision_test.rb` — update it to the new `provision!` signature: drop `forecast_project_ids:`; the "attached projects" assertions move conceptually to the workstream test, so simplify those provision tests to just assert tracker+links+warnings).

- [ ] **Step 5: Commit**

```bash
git add app/models/project_tracker.rb test/models/project_tracker_workstream_test.rb test/models/project_tracker_provision_test.rb
git commit -m "feat(project-tracker): add_workstream! (client find-or-create) + bare provision!"
```

---

### Task 4: Routes rework + remove Forecast-named controllers; `Api::ContributorsController` + `Api::ProjectTrackersController`

**Files:**
- Modify: `config/routes.rb`
- Delete: `app/controllers/api/forecast_projects_controller.rb`, `forecast_clients_controller.rb`, `forecast_people_controller.rb` and their tests `test/integration/api/forecast_projects_test.rb`, `resolvers_test.rb`
- Create: `app/controllers/api/contributors_controller.rb`, rewrite `app/controllers/api/project_trackers_controller.rb`
- Test: `test/integration/api/contributors_test.rb`, rewrite `test/integration/api/project_trackers_test.rb`

**Interfaces:**
- Routes (replace the old `forecast_*` routes inside `namespace :api`):

```ruby
resources :contributors, only: [:index]
resources :project_trackers, only: [:index, :create] do
  resources :workstreams, only: [:create] do
    member do
      post   "rates", to: "workstreams#add_rate"
      delete "rates", to: "workstreams#remove_rate"
    end
  end
end
resources :recurring_assignments, only: [:create]
```
(Delete the old `forecast_projects`, `forecast_clients`, `forecast_people` route lines.)

- [ ] **Step 1: Update routes** as above; delete the three `forecast_*` controllers + their two test files.

- [ ] **Step 2: Write failing tests** — `test/integration/api/contributors_test.rb`:

```ruby
require "test_helper"

class Api::ContributorsTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }; end

  test "403 without key" do
    get "/api/contributors", params: { email: "x@y.z" }
    assert_response :forbidden
  end

  test "resolves a contributor by email (native id, no forecast leakage)" do
    ForecastPerson.insert!({ forecast_id: 324711, email: "hugh@sanctuary.computer" })
    Contributor.insert!({ forecast_person_id: 324711 })
    get "/api/contributors", params: { email: "hugh@sanctuary.computer" }, headers: auth
    assert_response :success
    row = JSON.parse(response.body).first
    assert_equal Contributor.find_by(forecast_person_id: 324711).id, row["id"]
    assert_equal "hugh@sanctuary.computer", row["email"]
    refute row.key?("forecast_id")
    refute row.key?("forecast_person_id")
  end
end
```

Rewrite `test/integration/api/project_trackers_test.rb`:

```ruby
require "test_helper"

class Api::ProjectTrackersTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  test "403 without key" do
    post "/api/project_trackers", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "create makes a bare tracker with placeholder links + warnings, no forecast leakage" do
    post "/api/project_trackers", headers: auth, params: { name: "Qualitate" }.to_json
    assert_response :success
    body = JSON.parse(response.body)
    assert ProjectTracker.find(body["id"]).persisted?
    assert body["warnings"].any?
    refute body.to_s.include?("forecast")
  end

  test "index by client lists trackers with nested workstreams + rates" do
    ForecastClient.new(forecast_id: 42, name: "Qualitate").save!(validate: false)
    ForecastProject.new(forecast_id: 5001, client_id: 42, name: "P", code: "Q-1", tags: ["450p/h"]).save!(validate: false)
    t = ProjectTracker.provision!(name: "Qualitate", msa_url: "https://e.com/m", sow_url: "https://e.com/s").first
    t.project_tracker_forecast_projects.create!(forecast_project_id: 5001)
    get "/api/project_trackers", params: { client: "Qualitate" }, headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }
    assert_response :success
    row = JSON.parse(response.body).find { |r| r["id"] == t.id }
    assert_equal "Qualitate", row["client"]
    assert_equal [450.0], row["workstreams"].first["rates"]
  end
end
```

- [ ] **Step 3: Run to verify red.**

- [ ] **Step 4: Implement controllers.** `app/controllers/api/contributors_controller.rb`:

```ruby
class Api::ContributorsController < ApiController
  before_action :check_private_api_key!

  def index
    fp_ids = ForecastPerson.where("lower(email) = ?", params[:email].to_s.strip.downcase).select(:forecast_id)
    render json: Contributor.where(forecast_person_id: fp_ids).map { |c|
      { id: c.id, email: c.forecast_person&.email, name: c.display_name }
    }
  end
end
```

Rewrite `app/controllers/api/project_trackers_controller.rb`:

```ruby
class Api::ProjectTrackersController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def index
    trackers = ProjectTracker.all
    if params[:client].present?
      client_ids = ForecastClient.where("lower(name) = ?", params[:client].strip.downcase).select(:forecast_id)
      fp_ids = ForecastProject.where(client_id: client_ids).select(:forecast_id)
      trackers = trackers.where(id: ProjectTrackerForecastProject.where(forecast_project_id: fp_ids).select(:project_tracker_id))
    end
    trackers = trackers.where("lower(name) = ?", params[:name].strip.downcase) if params[:name].present?
    render json: trackers.map { |t| tracker_json(t) }
  end

  def create
    tracker, warnings = ProjectTracker.provision!(
      name: params.require(:name), msa_url: params[:msa_url], sow_url: params[:sow_url],
      budget_low_end: params[:budget_low_end], budget_high_end: params[:budget_high_end],
    )
    render json: tracker_json(tracker).merge(warnings: warnings)
  end

  private

  def tracker_json(t)
    { id: t.id, name: t.name, client: t.derived_client&.name,
      workstreams: t.project_tracker_forecast_projects.map { |ws|
        fp = ws.forecast_project
        { id: ws.id, name: fp&.name, code: fp&.code,
          rates: Array(fp&.tags).select { |x| x.to_s.end_with?("p/h") }.map(&:to_f) }
      } }
  end
end
```

- [ ] **Step 5: Run to verify green** — `bin/rails test test/integration/api/`.

- [ ] **Step 6: Commit**

```bash
git add -A app/controllers/api config/routes.rb test/integration/api
git commit -m "feat(api): generic contributors + project_trackers; remove forecast-named endpoints"
```

---

### Task 5: `Api::WorkstreamsController` (create + rates)

**Files:**
- Create: `app/controllers/api/workstreams_controller.rb`
- Test: `test/integration/api/workstreams_test.rb`

**Interfaces:**
- Consumes: `ProjectTracker#add_workstream!` (Task 3), `Stacks::Forecast#add_project_rate!`/`#remove_project_rate!`.
- Routes: from Task 4 — `POST /api/project_trackers/:project_tracker_id/workstreams`, `POST`/`DELETE /api/project_trackers/:project_tracker_id/workstreams/:id/rates`.

- [ ] **Step 1: Write failing test** — `test/integration/api/workstreams_test.rb`:

```ruby
require "test_helper"

class Api::WorkstreamsTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  def tracker
    ProjectTracker.provision!(name: "Q", msa_url: "https://e.com/m", sow_url: "https://e.com/s").first
  end

  test "403 without key" do
    post "/api/project_trackers/1/workstreams", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "create delegates to add_workstream! and returns a generic workstream" do
    t = tracker
    ws = t.project_tracker_forecast_projects.build # placeholder to stand in for return
    ForecastClient.new(forecast_id: 42, name: "Q").save!(validate: false)
    ForecastProject.new(forecast_id: 5001, client_id: 42, name: "Design", code: "Q-1", tags: ["450p/h"]).save!(validate: false)
    real_ws = t.project_tracker_forecast_projects.create!(forecast_project_id: 5001)
    ProjectTracker.any_instance.expects(:add_workstream!).returns(real_ws)

    post "/api/project_trackers/#{t.id}/workstreams", headers: auth,
      params: { name: "Design", code: "Q-1", rate: 450, client: "Q" }.to_json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal real_ws.id, body["id"]
    assert_equal [450.0], body["rates"]
    refute body.to_s.include?("forecast")
  end

  test "add_rate delegates to Stacks::Forecast#add_project_rate!" do
    t = tracker
    ForecastProject.new(forecast_id: 5002, client_id: 42, name: "P", code: "Q-2", tags: ["300p/h"]).save!(validate: false)
    ws = t.project_tracker_forecast_projects.create!(forecast_project_id: 5002)
    fake = mock("fc"); fake.expects(:add_project_rate!).with(5002, 450).returns(true)
    Stacks::Forecast.stubs(:new).returns(fake)

    post "/api/project_trackers/#{t.id}/workstreams/#{ws.id}/rates", params: { rate: 450 }.to_json, headers: auth
    assert_response :success
  end

  test "remove_rate handles decimals" do
    t = tracker
    ForecastProject.new(forecast_id: 5003, client_id: 42, name: "P", code: "Q-3", tags: ["99.75p/h"]).save!(validate: false)
    ws = t.project_tracker_forecast_projects.create!(forecast_project_id: 5003)
    fake = mock("fc"); fake.expects(:remove_project_rate!).with(5003, "99.75").returns(true)
    Stacks::Forecast.stubs(:new).returns(fake)

    delete "/api/project_trackers/#{t.id}/workstreams/#{ws.id}/rates", params: { rate: "99.75" }.to_json, headers: auth
    assert_response :success
  end
end
```

- [ ] **Step 2: Run to verify red.**

- [ ] **Step 3: Implement** — `app/controllers/api/workstreams_controller.rb`:

```ruby
class Api::WorkstreamsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    tracker = ProjectTracker.find(params[:project_tracker_id])
    ws = tracker.add_workstream!(
      name: params.require(:name), code: params.require(:code),
      rate: params[:rate], client_name: params[:client],
    )
    render json: workstream_json(ws)
  end

  def add_rate
    ws = ProjectTrackerForecastProject.find(params[:id])
    Stacks::Forecast.new.add_project_rate!(ws.forecast_project_id, params.require(:rate))
    render json: workstream_json(ws.reload)
  end

  def remove_rate
    ws = ProjectTrackerForecastProject.find(params[:id])
    Stacks::Forecast.new.remove_project_rate!(ws.forecast_project_id, params.require(:rate))
    render json: workstream_json(ws.reload)
  end

  private

  def workstream_json(ws)
    fp = ws.forecast_project
    { id: ws.id, project_tracker_id: ws.project_tracker_id, name: fp&.name, code: fp&.code,
      client: fp&.forecast_client&.name,
      rates: Array(fp&.tags).select { |x| x.to_s.end_with?("p/h") }.map(&:to_f) }
  end
end
```

- [ ] **Step 4: Run to verify green.**

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/workstreams_controller.rb test/integration/api/workstreams_test.rb
git commit -m "feat(api): workstreams endpoints (create + add/remove rate) under trackers"
```

---

### Task 6: Rework `Api::RecurringAssignmentsController` to `contributor_id` + `workstream_id`

**Files:**
- Rewrite: `app/controllers/api/recurring_assignments_controller.rb`
- Rewrite: `test/integration/api/recurring_assignments_test.rb`

**Interfaces:**
- Consumes: `Contributor` (native id → `forecast_person_id`), `ProjectTrackerForecastProject` (workstream id → `forecast_project_id`), `RecurringAssignment`.
- `POST /api/recurring_assignments` — `{ contributor_id, workstream_id, allocation_hours?, weekdays?, starts_on?, ends_on? }`.

- [ ] **Step 1: Rewrite the test** — `test/integration/api/recurring_assignments_test.rb`:

```ruby
require "test_helper"

class Api::RecurringAssignmentsTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  def setup_contributor_and_workstream
    ForecastPerson.insert!({ forecast_id: 324711, email: "hugh@sanctuary.computer" })
    Contributor.insert!({ forecast_person_id: 324711 })
    c = Contributor.find_by(forecast_person_id: 324711)
    ForecastProject.new(forecast_id: 5001, client_id: 42, name: "P", code: "Q-1").save!(validate: false)
    t = ProjectTracker.provision!(name: "Q", msa_url: "https://e.com/m", sow_url: "https://e.com/s").first
    ws = t.project_tracker_forecast_projects.create!(forecast_project_id: 5001)
    [c, ws]
  end

  test "403 without key" do
    post "/api/recurring_assignments", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "creates from contributor_id + workstream_id, translating to forecast ids, defaults applied" do
    c, ws = setup_contributor_and_workstream
    post "/api/recurring_assignments", headers: auth, params: { contributor_id: c.id, workstream_id: ws.id }.to_json
    assert_response :success
    body = JSON.parse(response.body)
    ra = RecurringAssignment.find(body["id"])
    assert_equal 324711, ra.forecast_person_id
    assert_equal 5001, ra.forecast_project_id
    assert_equal 28_800, ra.allocation
    assert_equal [1,2,3,4,5], ra.weekdays
    assert_equal Date.today, ra.starts_on
    # response is generic — no forecast ids
    assert_equal c.id, body["contributor_id"]
    assert_equal ws.id, body["workstream_id"]
    refute body.to_s.include?("forecast")
  end

  test "honors explicit hours/weekdays" do
    c, ws = setup_contributor_and_workstream
    post "/api/recurring_assignments", headers: auth,
      params: { contributor_id: c.id, workstream_id: ws.id, allocation_hours: 4, weekdays: [1] }.to_json
    ra = RecurringAssignment.find(JSON.parse(response.body)["id"])
    assert_equal 14_400, ra.allocation
    assert_equal [1], ra.weekdays
  end
end
```

- [ ] **Step 2: Run to verify red.**

- [ ] **Step 3: Rewrite the controller** — `app/controllers/api/recurring_assignments_controller.rb`:

```ruby
class Api::RecurringAssignmentsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    contributor = Contributor.find(params.require(:contributor_id))
    workstream = ProjectTrackerForecastProject.find(params.require(:workstream_id))
    ra = RecurringAssignment.new(
      forecast_person_id: contributor.forecast_person_id,
      forecast_project_id: workstream.forecast_project_id,
      weekdays: (params[:weekdays].presence || [1, 2, 3, 4, 5]).map(&:to_i),
      starts_on: params[:starts_on].presence || Date.today,
      ends_on: params[:ends_on].presence,
      notes: params[:notes].to_s,
      active_on_days_off: ActiveModel::Type::Boolean.new.cast(params[:active_on_days_off]) || false,
    )
    ra.allocation_in_hours = params[:allocation_hours].presence || 8
    ra.save!
    render json: {
      id: ra.id, contributor_id: contributor.id, workstream_id: workstream.id,
      allocation_hours: ra.allocation_in_hours, weekdays: ra.weekdays,
      starts_on: ra.starts_on, ends_on: ra.ends_on,
    }
  end
end
```

- [ ] **Step 4: Run to verify green** — `bin/rails test test/integration/api/ test/models test/lib/stacks`.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/recurring_assignments_controller.rb test/integration/api/recurring_assignments_test.rb
git commit -m "feat(api): recurring_assignments by contributor_id + workstream_id (forecast hidden)"
```

---

## Self-Review

**Spec coverage:** Unexpected + global error handling (T1); create_client/find_or_create (T2); add_workstream! + client find-or-create + bare provision! (T3); generic contributors + project_trackers, remove forecast_* (T4); workstreams create + rates (T5); recurring by contributor/workstream (T6). Generic surface (no forecast_*) enforced by explicit `refute … include?("forecast")` assertions across the controller tests.

**Placeholder scan:** none — real code throughout. Task 4 deletes old files (named explicitly).

**Type consistency:** `find_or_create_client!(name)→ForecastClient`, `add_workstream!(name:,code:,rate:,client_name:,forecast_client:)→ProjectTrackerForecastProject`, `provision!(name:,msa_url:,sow_url:,budget_low_end:,budget_high_end:)` (no `forecast_project_ids:`), workstream id = `ProjectTrackerForecastProject.id`, contributor id = `Contributor.id`, translations `contributor.forecast_person_id` / `ws.forecast_project_id` are used identically across tasks.
