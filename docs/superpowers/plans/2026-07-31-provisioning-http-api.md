# Provisioning HTTP API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-CRUD HTTP API (auth: `X-Api-Key`) that lets an agent create Forecast projects, add/remove rates, create project trackers (with MSA/SOW links), and create recurring assignments — so it can stand up a project end-to-end. MCP tools are a later PR.

**Architecture:** Thin `Api::*` controllers (inherit `ApiController`, `check_private_api_key!`) call new write methods on `Stacks::Forecast` (which also reflect into the local `ForecastProject` mirror) and a `ProjectTracker.provision!` class method and plain `RecurringAssignment` CRUD. The "ensure/find-or-create" logic lives in the calling agent, not the server.

**Tech Stack:** Rails 6.1, Postgres, HTTParty (Forecast client), Minitest + Mocha. Forecast writes stubbed at the class-method level; controller tests stub `Stacks::Forecast.new`.

## Global Constraints

- Auth: every new controller inherits `ApiController`, calls `before_action :check_private_api_key!` and `skip_before_action :verify_authenticity_token` (per `Api::McpController`). Routes go inside the existing `namespace :api` (`config/routes.rb:16`).
- Forecast write body envelope is `{ project: {...} }`, `Content-Type: application/json` (via existing `write_headers`). Verified live: `POST /projects`, `PUT /projects/:id` (partial), both return `{ "project": {...} }`.
- Every Forecast write reflects into the local `ForecastProject` mirror in-request via `upsert_all(unique_by: :forecast_id)`, using the same column mapping as `sync_projects!` (`forecast_id,name,code,notes,start_date,end_date,harvest_id,archived,client_id,tags,updated_at,updated_by_id,data`).
- Rates are Forecast **tags** ending in `p/h` and there can be **multiple**; operations add/remove ONE tag and never clobber others. Normalize numeric rate → bare tag: `450 → "450p/h"`, `99.75 → "99.75p/h"` (strip trailing `.0`), tolerate a `$` prefix in input.
- `ForecastProject`/`ForecastClient`/`ForecastAssignment` use `self.primary_key = "forecast_id"`. The tracker↔project join stores `forecast_id` in `forecast_project_id`.
- `Stacks::Forecast.new` needs Forecast credentials absent in test; unit tests build it with `Stacks::Forecast.allocate` + `instance_variable_set(:@headers, {})`; controller tests stub `Stacks::Forecast.stubs(:new).returns(fake)`.
- Commit after every task; end commit messages with the Co-Authored-By trailer.

---

### Task 1: `Stacks::Forecast` project create/update + local mirror upsert

**Files:**
- Modify: `lib/stacks/forecast.rb`
- Test: `test/lib/stacks/forecast_test.rb`

**Interfaces:**
- Produces:
  - `Stacks::Forecast#create_project(client_id:, name:, code:, tags: [], notes: "")` → parsed `"project"` Hash (incl. `"id"`); upserts the local mirror. Raises on non-2xx.
  - `Stacks::Forecast#update_project(forecast_id, attrs)` → parsed `"project"` Hash (partial PUT); upserts the local mirror. Raises on non-2xx.
  - private `#upsert_project_locally!(api_project)`.

- [ ] **Step 1: Write failing tests**

Add to `test/lib/stacks/forecast_test.rb` (reuse the existing `build_forecast_client` helper if present; else define one that `allocate`s + sets `@headers`):

```ruby
test "create_project POSTs the project envelope, returns it, and upserts the local mirror" do
  fc = build_forecast_client
  response = mock("resp"); response.stubs(:success?).returns(true)
  response.stubs(:parsed_response).returns({ "project" => {
    "id" => 777, "name" => "Qualitate Retainer", "code" => "QUAL-1", "client_id" => 42,
    "tags" => ["450p/h"], "archived" => false, "updated_at" => "2026-07-31T00:00:00Z",
  } })
  posted = {}
  Stacks::Forecast.expects(:post).once.with do |path, opts|
    posted[:path] = path; posted[:body] = JSON.parse(opts[:body]); true
  end.returns(response)

  result = fc.create_project(client_id: 42, name: "Qualitate Retainer", code: "QUAL-1", tags: ["450p/h"])

  assert_equal 777, result["id"]
  assert_equal "/projects", posted[:path]
  assert_equal 42, posted[:body]["project"]["client_id"]
  assert_equal ["450p/h"], posted[:body]["project"]["tags"]
  fp = ForecastProject.find_by(forecast_id: 777)
  assert_equal "QUAL-1", fp.code
  assert_equal ["450p/h"], fp.tags
end

test "update_project PUTs partial attrs and re-upserts the mirror" do
  fc = build_forecast_client
  response = mock("resp"); response.stubs(:success?).returns(true)
  response.stubs(:parsed_response).returns({ "project" => {
    "id" => 777, "name" => "Q", "code" => "QUAL-1", "client_id" => 42, "tags" => ["450p/h","300p/h"],
  } })
  Stacks::Forecast.expects(:put).once.with do |path, opts|
    path == "/projects/777" && JSON.parse(opts[:body])["project"]["tags"] == ["450p/h","300p/h"]
  end.returns(response)

  fc.update_project(777, tags: ["450p/h", "300p/h"])
  assert_equal ["450p/h","300p/h"], ForecastProject.find_by(forecast_id: 777).tags
end
```

- [ ] **Step 2: Run to verify red** — `bin/rails test test/lib/stacks/forecast_test.rb` → FAIL (`create_project` undefined).

- [ ] **Step 3: Implement** — in `lib/stacks/forecast.rb`, add public methods (near `create_assignment`):

```ruby
def create_project(client_id:, name:, code:, tags: [], notes: "")
  body = { project: { client_id: client_id, name: name, code: code, tags: tags, notes: notes.to_s } }
  response = self.class.post("/projects", headers: write_headers, body: JSON.dump(body))
  raise "Forecast create_project failed: #{response.code} #{response.body}" unless response.success?
  project = response.parsed_response["project"]
  upsert_project_locally!(project)
  project
end

def update_project(forecast_id, attrs)
  body = { project: attrs }
  response = self.class.put("/projects/#{forecast_id}", headers: write_headers, body: JSON.dump(body))
  raise "Forecast update_project failed: #{response.code} #{response.body}" unless response.success?
  project = response.parsed_response["project"]
  upsert_project_locally!(project)
  project
end
```

and in the `private` section:

```ruby
def upsert_project_locally!(c)
  ForecastProject.upsert_all([{
    forecast_id: c["id"], name: c["name"], code: c["code"], notes: c["notes"],
    start_date: c["start_date"], end_date: c["end_date"], harvest_id: c["harvest_id"],
    archived: c["archived"], client_id: c["client_id"], tags: c["tags"],
    updated_at: c["updated_at"], updated_by_id: c["updated_by_id"], data: c,
  }], unique_by: :forecast_id)
end
```

- [ ] **Step 4: Run to verify green** — `bin/rails test test/lib/stacks/forecast_test.rb` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/forecast.rb test/lib/stacks/forecast_test.rb
git commit -m "feat(forecast): create_project/update_project with local mirror upsert"
```

---

### Task 2: Rate add/remove on `Stacks::Forecast`

**Files:**
- Modify: `lib/stacks/forecast.rb`
- Test: `test/lib/stacks/forecast_test.rb`

**Interfaces:**
- Consumes: `#update_project` (Task 1), local `ForecastProject` mirror for current tags.
- Produces:
  - `Stacks::Forecast.rate_tag(rate)` (class method) → normalized `"450p/h"` string.
  - `#add_project_rate!(forecast_id, rate)` → updated `"project"` Hash. Idempotent (no dup tag), preserves other rates.
  - `#remove_project_rate!(forecast_id, rate)` → updated `"project"` Hash.

- [ ] **Step 1: Write failing tests**

```ruby
test "rate_tag normalizes numbers and $ prefixes" do
  assert_equal "450p/h", Stacks::Forecast.rate_tag(450)
  assert_equal "450p/h", Stacks::Forecast.rate_tag("$450p/h")
  assert_equal "99.75p/h", Stacks::Forecast.rate_tag(99.75)
end

test "add_project_rate! appends the tag without clobbering others and is idempotent" do
  ForecastProject.new(forecast_id: 900, code: "C", name: "N", client_id: 1, tags: ["300p/h"]).save!(validate: false)
  fc = build_forecast_client
  # update_project is exercised for real against the mirror; stub only the HTTP PUT it calls.
  resp = mock("r"); resp.stubs(:success?).returns(true)
  resp.stubs(:parsed_response).returns({ "project" => { "id" => 900, "tags" => ["300p/h","450p/h"], "code"=>"C","name"=>"N","client_id"=>1 } })
  Stacks::Forecast.stubs(:put).returns(resp)

  fc.add_project_rate!(900, 450)
  assert_equal ["300p/h","450p/h"], ForecastProject.find_by(forecast_id: 900).tags

  # idempotent: adding again sends no new tag / no crash
  fc.add_project_rate!(900, 450)
  assert_equal ["300p/h","450p/h"], ForecastProject.find_by(forecast_id: 900).tags.uniq
end

test "remove_project_rate! drops just that rate" do
  ForecastProject.new(forecast_id: 901, code: "C", name: "N", client_id: 1, tags: ["300p/h","450p/h"]).save!(validate: false)
  fc = build_forecast_client
  resp = mock("r"); resp.stubs(:success?).returns(true)
  resp.stubs(:parsed_response).returns({ "project" => { "id" => 901, "tags" => ["300p/h"], "code"=>"C","name"=>"N","client_id"=>1 } })
  Stacks::Forecast.stubs(:put).returns(resp)

  fc.remove_project_rate!(901, 450)
  assert_equal ["300p/h"], ForecastProject.find_by(forecast_id: 901).tags
end
```

- [ ] **Step 2: Run to verify red.**

- [ ] **Step 3: Implement** — add to `lib/stacks/forecast.rb`:

```ruby
def self.rate_tag(rate)
  n = rate.to_s.delete("$").to_f            # "$450p/h" -> 450.0, 99.75 -> 99.75
  s = format("%g", n)                        # 450.0 -> "450", 99.75 -> "99.75"
  "#{s}p/h"
end

def add_project_rate!(forecast_id, rate)
  tag = self.class.rate_tag(rate)
  current = local_tags(forecast_id)
  return refetchable_project(forecast_id) if current.include?(tag)
  update_project(forecast_id, tags: current + [tag])
end

def remove_project_rate!(forecast_id, rate)
  tag = self.class.rate_tag(rate)
  update_project(forecast_id, tags: local_tags(forecast_id) - [tag])
end
```

private helpers:

```ruby
def local_tags(forecast_id)
  fp = ForecastProject.find_by(forecast_id: forecast_id)
  raise "Unknown Forecast project #{forecast_id}" if fp.nil?
  Array(fp.tags)
end

def refetchable_project(forecast_id)
  ForecastProject.find_by(forecast_id: forecast_id).data || {}
end
```

- [ ] **Step 4: Run to verify green.**

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/forecast.rb test/lib/stacks/forecast_test.rb
git commit -m "feat(forecast): add/remove project rate tags (multi-rate safe)"
```

---

### Task 3: `ProjectTracker.provision!`

**Files:**
- Modify: `app/models/project_tracker.rb`
- Test: `test/models/project_tracker_provision_test.rb`

**Interfaces:**
- Produces: `ProjectTracker.provision!(name:, forecast_project_ids:, msa_url: nil, sow_url: nil, budget_low_end: nil, budget_high_end: nil)` → `[tracker, warnings]` (warnings is an Array<String>). Runs in a transaction; raises `ActiveRecord::RecordInvalid` on validation failure.

Placeholder fallback: a missing `msa_url`/`sow_url` becomes `https://todo.example.com/msa` (or `/sow`) and appends a warning.

- [ ] **Step 1: Write failing tests**

`test/models/project_tracker_provision_test.rb`:

```ruby
require "test_helper"

class ProjectTrackerProvisionTest < ActiveSupport::TestCase
  def forecast_project(forecast_id, code)
    ForecastProject.new(forecast_id: forecast_id, code: code, name: "P#{forecast_id}", client_id: 1).save!(validate: false)
    forecast_id
  end

  test "provisions a tracker with MSA/SOW links and attached forecast projects" do
    fp = forecast_project(1001, "QUAL-1")
    tracker, warnings = ProjectTracker.provision!(
      name: "Qualitate Retainer", forecast_project_ids: [fp],
      msa_url: "https://example.com/msa", sow_url: "https://example.com/sow",
    )
    assert tracker.persisted?
    assert_equal "https://example.com/msa", tracker.project_tracker_links.find { |l| l.link_type == "msa" }.url
    assert_equal "https://example.com/sow", tracker.project_tracker_links.find { |l| l.link_type == "sow" }.url
    assert_equal [1001], tracker.forecast_projects.map(&:forecast_id)
    assert_empty warnings
  end

  test "falls back to placeholder links with a warning when urls are omitted" do
    fp = forecast_project(1002, "QUAL-2")
    tracker, warnings = ProjectTracker.provision!(name: "T2", forecast_project_ids: [fp])
    assert tracker.persisted?
    assert tracker.project_tracker_links.find { |l| l.link_type == "msa" }.url.include?("todo")
    assert warnings.any? { |w| w.downcase.include?("msa") }
    assert warnings.any? { |w| w.downcase.include?("sow") }
  end

  test "raises when an attached forecast project has no code" do
    ForecastProject.new(forecast_id: 1003, code: nil, name: "NoCode", client_id: 1).save!(validate: false)
    assert_raises(ActiveRecord::RecordInvalid) do
      ProjectTracker.provision!(name: "T3", forecast_project_ids: [1003],
        msa_url: "https://e.com/m", sow_url: "https://e.com/s")
    end
  end
end
```

- [ ] **Step 2: Run to verify red.**

- [ ] **Step 3: Implement** — add to `app/models/project_tracker.rb`:

```ruby
def self.provision!(name:, forecast_project_ids:, msa_url: nil, sow_url: nil, budget_low_end: nil, budget_high_end: nil)
  warnings = []
  msa = msa_url.presence || (warnings << "MSA link is a placeholder — replace it in Forecast/admin." && "https://todo.example.com/msa")
  sow = sow_url.presence || (warnings << "SOW link is a placeholder — replace it in Forecast/admin." && "https://todo.example.com/sow")

  tracker = transaction do
    pt = new(name: name, budget_low_end: budget_low_end, budget_high_end: budget_high_end)
    pt.project_tracker_links.build(name: "MSA", url: msa, link_type: :msa)
    pt.project_tracker_links.build(name: "SOW", url: sow, link_type: :sow)
    Array(forecast_project_ids).each do |fid|
      pt.project_tracker_forecast_projects.build(forecast_project_id: fid)
    end
    pt.save!
    pt
  end
  [tracker, warnings]
end
```

Note: `(warnings << "…") && "url"` — `Array#<<` returns the array (truthy), so the `&&` yields the placeholder URL while recording the warning. Keep the comment so a reader isn't surprised.

- [ ] **Step 4: Run to verify green.**

- [ ] **Step 5: Commit**

```bash
git add app/models/project_tracker.rb test/models/project_tracker_provision_test.rb
git commit -m "feat(project-tracker): provision! class method (links + attach + warnings)"
```

---

### Task 4: `Api::ForecastProjectsController` (create + rates)

**Files:**
- Create: `app/controllers/api/forecast_projects_controller.rb`
- Modify: `config/routes.rb` (inside `namespace :api`)
- Test: `test/integration/api/forecast_projects_test.rb`

**Interfaces:**
- Consumes: `Stacks::Forecast#create_project`, `#add_project_rate!`, `#remove_project_rate!`, `.rate_tag`.
- Routes:
  - `POST   /api/forecast_projects` → `create`
  - `POST   /api/forecast_projects/:forecast_id/rates` → `add_rate`
  - `DELETE /api/forecast_projects/:forecast_id/rates/:rate` → `remove_rate`

- [ ] **Step 1: Add routes** — inside `namespace :api do` in `config/routes.rb`:

```ruby
resources :forecast_projects, only: [:create]
post   "forecast_projects/:forecast_id/rates",       to: "forecast_projects#add_rate"
delete "forecast_projects/:forecast_id/rates/:rate", to: "forecast_projects#remove_rate"
```

- [ ] **Step 2: Write failing integration test**

`test/integration/api/forecast_projects_test.rb`:

```ruby
require "test_helper"

class Api::ForecastProjectsTest < ActionDispatch::IntegrationTest
  def key; Stacks::Utils.config[:stacks][:private_api_key]; end
  def auth; { "X-Api-Key" => key, "Content-Type" => "application/json" }; end

  test "403 without a valid key" do
    post "/api/forecast_projects", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "create delegates to Stacks::Forecast#create_project and returns the project" do
    fake = mock("forecast")
    fake.expects(:create_project).with(client_id: 42, name: "Q", code: "QUAL-1", tags: ["450p/h"], notes: "").returns({ "id" => 777, "tags" => ["450p/h"] })
    Stacks::Forecast.stubs(:new).returns(fake)

    post "/api/forecast_projects",
      params: { client_id: 42, name: "Q", code: "QUAL-1", rates: [450] }.to_json, headers: auth
    assert_response :success
    assert_equal 777, JSON.parse(response.body)["forecast_id"]
  end

  test "add_rate delegates to add_project_rate!" do
    fake = mock("forecast"); fake.expects(:add_project_rate!).with(777, 450).returns({ "id" => 777, "tags" => ["450p/h"] })
    Stacks::Forecast.stubs(:new).returns(fake)
    post "/api/forecast_projects/777/rates", params: { rate: 450 }.to_json, headers: auth
    assert_response :success
  end

  test "remove_rate delegates to remove_project_rate!" do
    fake = mock("forecast"); fake.expects(:remove_project_rate!).with(777, "450").returns({ "id" => 777, "tags" => [] })
    Stacks::Forecast.stubs(:new).returns(fake)
    delete "/api/forecast_projects/777/rates/450", headers: auth
    assert_response :success
  end
end
```

- [ ] **Step 3: Run to verify red.**

- [ ] **Step 4: Implement controller**

`app/controllers/api/forecast_projects_controller.rb`:

```ruby
class Api::ForecastProjectsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    tags = Array(params[:rates]).map { |r| Stacks::Forecast.rate_tag(r) }
    project = Stacks::Forecast.new.create_project(
      client_id: params.require(:client_id), name: params.require(:name),
      code: params.require(:code), tags: tags, notes: params[:notes].to_s,
    )
    render json: project_json(project)
  rescue => e
    render_error(e)
  end

  def add_rate
    project = Stacks::Forecast.new.add_project_rate!(params[:forecast_id].to_i, params.require(:rate))
    render json: project_json(project)
  rescue => e
    render_error(e)
  end

  def remove_rate
    project = Stacks::Forecast.new.remove_project_rate!(params[:forecast_id].to_i, params[:rate])
    render json: project_json(project)
  rescue => e
    render_error(e)
  end

  private

  def project_json(p)
    { forecast_id: p["id"], name: p["name"], code: p["code"], client_id: p["client_id"],
      tags: p["tags"], rates: Array(p["tags"]).select { |t| t.to_s.end_with?("p/h") }.map(&:to_f) }
  end

  def render_error(e)
    Rails.logger.warn("[Api::ForecastProjects] #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
```

- [ ] **Step 5: Run to verify green** — `bin/rails test test/integration/api/forecast_projects_test.rb`.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/api/forecast_projects_controller.rb config/routes.rb test/integration/api/forecast_projects_test.rb
git commit -m "feat(api): forecast_projects create + add/remove rate endpoints"
```

---

### Task 5: `Api::ProjectTrackersController` (create)

**Files:**
- Create: `app/controllers/api/project_trackers_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/integration/api/project_trackers_test.rb`

**Interfaces:**
- Consumes: `ProjectTracker.provision!` (Task 3).
- Route: `POST /api/project_trackers` → `create`.

- [ ] **Step 1: Add route** — inside `namespace :api`: `resources :project_trackers, only: [:create]`.

- [ ] **Step 2: Write failing integration test**

`test/integration/api/project_trackers_test.rb`:

```ruby
require "test_helper"

class Api::ProjectTrackersTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  test "403 without key" do
    post "/api/project_trackers", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "creates a tracker with links + attached projects" do
    ForecastProject.new(forecast_id: 2001, code: "QUAL-1", name: "P", client_id: 1).save!(validate: false)
    post "/api/project_trackers", headers: auth, params: {
      name: "Qualitate Retainer", forecast_project_ids: [2001],
      msa_url: "https://e.com/m", sow_url: "https://e.com/s",
    }.to_json
    assert_response :success
    body = JSON.parse(response.body)
    pt = ProjectTracker.find(body["id"])
    assert_equal [2001], pt.forecast_projects.map(&:forecast_id)
    assert_empty body["warnings"]
  end

  test "returns a warning when links are omitted" do
    ForecastProject.new(forecast_id: 2002, code: "QUAL-2", name: "P", client_id: 1).save!(validate: false)
    post "/api/project_trackers", headers: auth, params: { name: "T", forecast_project_ids: [2002] }.to_json
    assert_response :success
    assert JSON.parse(response.body)["warnings"].any?
  end
end
```

- [ ] **Step 3: Run to verify red.**

- [ ] **Step 4: Implement controller**

`app/controllers/api/project_trackers_controller.rb`:

```ruby
class Api::ProjectTrackersController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    tracker, warnings = ProjectTracker.provision!(
      name: params.require(:name),
      forecast_project_ids: Array(params[:forecast_project_ids]).map(&:to_i),
      msa_url: params[:msa_url], sow_url: params[:sow_url],
      budget_low_end: params[:budget_low_end], budget_high_end: params[:budget_high_end],
    )
    render json: {
      id: tracker.id, name: tracker.name,
      forecast_project_ids: tracker.forecast_projects.map(&:forecast_id),
      link_ids: tracker.project_tracker_links.map(&:id), warnings: warnings,
    }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue => e
    Rails.logger.warn("[Api::ProjectTrackers] #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
```

- [ ] **Step 5: Run to verify green.**

- [ ] **Step 6: Commit**

```bash
git add app/controllers/api/project_trackers_controller.rb config/routes.rb test/integration/api/project_trackers_test.rb
git commit -m "feat(api): project_trackers create endpoint (links + attach + warnings)"
```

---

### Task 6: `Api::RecurringAssignmentsController` (create)

**Files:**
- Create: `app/controllers/api/recurring_assignments_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/integration/api/recurring_assignments_test.rb`

**Interfaces:**
- Consumes: `RecurringAssignment` (from PR #157) + its `allocation_in_hours=` accessor.
- Route: `POST /api/recurring_assignments` → `create`. Defaults: `allocation_hours` → 8, `weekdays` → `[1,2,3,4,5]`, `starts_on` → today.

- [ ] **Step 1: Add route** — inside `namespace :api`: `resources :recurring_assignments, only: [:create]`.

- [ ] **Step 2: Write failing integration test**

`test/integration/api/recurring_assignments_test.rb`:

```ruby
require "test_helper"

class Api::RecurringAssignmentsTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key], "Content-Type" => "application/json" }; end

  test "403 without key" do
    post "/api/recurring_assignments", params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "creates a rule applying 8h/Mon-Fri/today defaults" do
    post "/api/recurring_assignments", headers: auth,
      params: { forecast_person_id: 324711, forecast_project_id: 3033811 }.to_json
    assert_response :success
    ra = RecurringAssignment.find(JSON.parse(response.body)["id"])
    assert_equal 28_800, ra.allocation
    assert_equal [1,2,3,4,5], ra.weekdays
    assert_equal Date.today, ra.starts_on
  end

  test "honors explicit hours/weekdays/dates" do
    post "/api/recurring_assignments", headers: auth, params: {
      forecast_person_id: 1, forecast_project_id: 2, allocation_hours: 4,
      weekdays: [1], starts_on: "2026-08-03", ends_on: "2026-08-31",
    }.to_json
    assert_response :success
    ra = RecurringAssignment.find(JSON.parse(response.body)["id"])
    assert_equal 14_400, ra.allocation
    assert_equal [1], ra.weekdays
  end
end
```

- [ ] **Step 3: Run to verify red.**

- [ ] **Step 4: Implement controller**

`app/controllers/api/recurring_assignments_controller.rb`:

```ruby
class Api::RecurringAssignmentsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def create
    ra = RecurringAssignment.new(
      forecast_person_id: params.require(:forecast_person_id),
      forecast_project_id: params.require(:forecast_project_id),
      weekdays: (params[:weekdays].presence || [1, 2, 3, 4, 5]).map(&:to_i),
      starts_on: params[:starts_on].presence || Date.today,
      ends_on: params[:ends_on].presence,
      notes: params[:notes].to_s,
      active_on_days_off: ActiveModel::Type::Boolean.new.cast(params[:active_on_days_off]),
    )
    ra.allocation_in_hours = params[:allocation_hours].presence || 8
    ra.save!
    render json: recurring_json(ra)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue => e
    Rails.logger.warn("[Api::RecurringAssignments] #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def recurring_json(ra)
    { id: ra.id, forecast_person_id: ra.forecast_person_id, forecast_project_id: ra.forecast_project_id,
      allocation: ra.allocation, allocation_hours: ra.allocation_in_hours, weekdays: ra.weekdays,
      starts_on: ra.starts_on, ends_on: ra.ends_on }
  end
end
```

- [ ] **Step 5: Run to verify green.**

- [ ] **Step 6: Commit**

```bash
git add app/controllers/api/recurring_assignments_controller.rb config/routes.rb test/integration/api/recurring_assignments_test.rb
git commit -m "feat(api): recurring_assignments create endpoint (8h/Mon-Fri defaults)"
```

---

### Task 7: Read resolvers (clients by name + their projects; people by email)

**Files:**
- Create: `app/controllers/api/forecast_clients_controller.rb`
- Create: `app/controllers/api/forecast_people_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/integration/api/resolvers_test.rb`

**Interfaces:**
- Routes:
  - `GET /api/forecast_clients?name=` → `forecast_clients#index`
  - `GET /api/forecast_clients/:forecast_client_id/forecast_projects` → `forecast_clients#projects`
  - `GET /api/forecast_people?email=` → `forecast_people#index`

- [ ] **Step 1: Add routes** — inside `namespace :api`:

```ruby
get "forecast_clients", to: "forecast_clients#index"
get "forecast_clients/:forecast_client_id/forecast_projects", to: "forecast_clients#projects"
get "forecast_people", to: "forecast_people#index"
```

- [ ] **Step 2: Write failing integration test**

`test/integration/api/resolvers_test.rb`:

```ruby
require "test_helper"

class Api::ResolversTest < ActionDispatch::IntegrationTest
  def auth; { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }; end

  test "forecast_clients index matches by name case-insensitively" do
    ForecastClient.new(forecast_id: 42, name: "Qualitate").save!(validate: false)
    get "/api/forecast_clients", params: { name: "qualitate" }, headers: auth
    assert_response :success
    assert_equal 42, JSON.parse(response.body).first["forecast_id"]
  end

  test "client projects lists rates parsed from tags" do
    ForecastClient.new(forecast_id: 43, name: "Acme").save!(validate: false)
    ForecastProject.new(forecast_id: 5001, client_id: 43, name: "P", code: "A-1", tags: ["450p/h","300p/h"]).save!(validate: false)
    get "/api/forecast_clients/43/forecast_projects", headers: auth
    assert_response :success
    row = JSON.parse(response.body).first
    assert_equal [450.0, 300.0], row["rates"]
  end

  test "forecast_people index matches by email" do
    # insert! (not save!) — ForecastPerson#after_create builds a Contributor + ledgers cascade.
    ForecastPerson.insert!({ forecast_id: 324711, email: "hugh@sanctuary.computer" })
    get "/api/forecast_people", params: { email: "hugh@sanctuary.computer" }, headers: auth
    assert_response :success
    assert_equal 324711, JSON.parse(response.body).first["forecast_id"]
  end
end
```

- [ ] **Step 3: Run to verify red.**

- [ ] **Step 4: Implement controllers**

`app/controllers/api/forecast_clients_controller.rb`:

```ruby
class Api::ForecastClientsController < ApiController
  before_action :check_private_api_key!

  def index
    clients = ForecastClient.where("lower(name) = ?", params[:name].to_s.strip.downcase)
    render json: clients.map { |c| { forecast_id: c.forecast_id, name: c.name } }
  end

  def projects
    projects = ForecastProject.where(client_id: params[:forecast_client_id])
    # ForecastProject has NO tracker association — reach it through the join model
    # (keyed on forecast_id), built once as a map to avoid N+1.
    tracker_by_fp = ProjectTrackerForecastProject
      .where(forecast_project_id: projects.map(&:forecast_id))
      .pluck(:forecast_project_id, :project_tracker_id).to_h
    render json: projects.map { |p|
      rates = Array(p.tags).select { |t| t.to_s.end_with?("p/h") }.map(&:to_f)
      { forecast_id: p.forecast_id, name: p.name, code: p.code, rates: rates,
        hourly_rate: p.hourly_rate, archived: p.archived,
        project_tracker_id: tracker_by_fp[p.forecast_id] }
    }
  end
end
```

`app/controllers/api/forecast_people_controller.rb`:

```ruby
class Api::ForecastPeopleController < ApiController
  before_action :check_private_api_key!

  def index
    people = ForecastPerson.where("lower(email) = ?", params[:email].to_s.strip.downcase)
    render json: people.map { |p| { forecast_id: p.forecast_id, email: p.email, name: p.name } }
  end
end
```

Note: confirm `ForecastProject` has a `has_one :project_tracker_forecast_project` (or reach the tracker via `project_tracker_forecast_projects.first`). If the singular association doesn't exist, use `ForecastProject#project_tracker_forecast_projects.first&.project_tracker_id` or add a `has_one`. Verify against `app/models/forecast_project.rb` during implementation and adjust the one line accordingly.

- [ ] **Step 5: Run to verify green.**

- [ ] **Step 6: Commit**

```bash
git add app/controllers/api/forecast_clients_controller.rb app/controllers/api/forecast_people_controller.rb config/routes.rb test/integration/api/resolvers_test.rb
git commit -m "feat(api): read resolvers for clients/projects/people"
```

---

## Self-Review

**Spec coverage:**
- Forecast project create/update + immediate mirror → Task 1.
- Multi-rate add/remove → Task 2.
- Tracker create (links + attach + placeholder warning) → Task 3 + Task 5.
- Recurring assignment CRUD (8h/Mon–Fri defaults) → Task 6.
- Read resolvers (client-by-name, client projects+rates, person-by-email) → Task 7.
- Auth (X-Api-Key), routes under `namespace :api`, thin controllers → Tasks 4–7.
- Out of scope (MCP tools) → not in this plan (phase 2), as specified.

**Placeholder scan:** none — all steps carry real code. Task 7 flags one association to verify (`project_tracker_forecast_project` singular) and how to adjust — that's a verification instruction, not a code placeholder.

**Type consistency:** `create_project(client_id:, name:, code:, tags:, notes:)`, `add_project_rate!(forecast_id, rate)`, `remove_project_rate!`, `rate_tag`, `provision!(name:, forecast_project_ids:, msa_url:, sow_url:, budget_low_end:, budget_high_end:)` → `[tracker, warnings]`, `allocation_in_hours=` are used identically across tasks and match the models shipped in PR #157.
