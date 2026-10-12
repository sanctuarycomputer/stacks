# Project Log Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each project tracker gets a log at `/admin/project_trackers/:id/log` of what Stacksbot observed about it, so risk can be read off Stacks without asking anyone.

**Architecture:** A filtered Notion sync copies Stacksbot's Observations and Problems rows into the existing `notion_pages` table and never deletes a row it did not see. A tracker finds its rows through an indexed `project_ids` array on `notion_pages`, matched against its `notion_project_ids`. A plain Ruby object (`Stacks::ProjectLog`) filters and orders the stored rows for three views, and an ActiveAdmin page and a tracker-page module draw them. Stacks makes no judgement and never writes to Notion.

**Tech Stack:** Rails 6.1, ActiveAdmin 2.9 (Arbre + ERB partials), Minitest + Mocha, Net::HTTP, Postgres (GIN index), acts_as_paranoid, Storext.

**Spec:** `docs/superpowers/specs/2026-10-12-project-log-design.md`, Parts 4 and 5.

## Global Constraints

- Work in `/Users/hhff/Documents/Code/stacks/.claude/worktrees/meeting-matcher` on branch `feat/project-log-page`.
- Prefix every Rails command with `DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test`. Never use `stacks_test` or `stacks_development`. Never edit `config/database.yml`.
- Never read, decrypt or print credentials. Do not open `config/credentials.yml.enc` or `config/master.key`. Never print a value from `Stacks::Utils.config` or `ENV`. Error messages built in this work carry a status code and Notion's `message`, never headers.
- No test touches the network. Sync tests use the `FakeNotion` client in `test/support/notion_log_fixtures.rb`. Tests never call `Stacks::Notion.new`.
- Every rake test stubs `Stacks::Notifications.report_exception`. The test environment holds a real Twist token and `SystemTask#mark_as_error` (`app/models/system_task.rb:27-30`) posts to a real thread.
- `db/schema.rb` is hand-edited. Never commit the output of `db:migrate` or `db:schema:dump`. If a command rewrites it, `git checkout db/schema.rb` and redo the hand edit.
- Stacks never writes to Notion. No model calls. No rule in Stacks decides what an observation means; the one interim display mapping is `Stacks::Notion::Observation::INTERIM_VALENCE_BY_TYPE`.
- `stacks:sync_notion` and `Stacks::Notion#sync_database` must never be pointed at the Observations or Problems databases: `sync_database` deletes every row under a database that it did not see (`lib/stacks/notion.rb:144-151`).
- Stored Notion rows are external data. No reader may raise on a nil or an unexpected shape.
- Model-written text is escaped (ERB default). Never call `raw` or `html_safe` on a value from `notion_pages.data`. A URL from Notion is linked only when it starts with `http://` or `https://`.
- No em dashes in user-facing copy. Match the surrounding comment density.
- Do not push, merge or open a PR. Commit after each task with the message given, ending in the line `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## File Structure

| File | Change |
|---|---|
| `db/migrate/20261013100000_add_log_columns_to_notion_pages.rb` | Create. `project_ids`, `occurred_at`, `synced_at`, two indexes. |
| `db/schema.rb` | Hand-edit: three columns, two indexes, version. |
| `lib/stacks/notion/props.rb` | Create. Safe readers over a raw Notion page hash. |
| `lib/stacks/notion/observation.rb` | Create. Wrapper for an Observations row. |
| `lib/stacks/notion/problem.rb` | Create. Wrapper for a Problems row. |
| `lib/stacks/notion.rb` | `FILTERED_DATABASES`, guard in `sync_database`, `normalize_page!`, `Error`, `query_database_filtered`, `fetch_page`, retry. |
| `lib/stacks/notion/filtered_sync.rb` | Create. The filtered sync: window, upsert, by-id passes, dry run. |
| `app/models/notion_page.rb` | `observations` and `problems` scopes, `as_observation`, `as_problem`. |
| `app/models/system.rb` | `notion_filtered_sync_marks` setting. |
| `app/models/project_tracker.rb` | `#observations`, `#problems`. |
| `lib/stacks/project_log.rb` | Create. Views, filters, escalated flag, paging, empty reasons, summary. |
| `lib/tasks/stacks.rake` | `stacks:sync_notion_log`, `stacks:preview_notion_log_sync`, the ride on `sync_notion`. |
| `app/models/admin_authorization.rb` | A project-scoped lead grantee may open the Log page. |
| `app/admin/log.rb` | Create. The page. |
| `app/views/admin/log/_show.html.erb`, `_row.html.erb`, `_empty.html.erb`, `_module.html.erb` | Create. |
| `app/admin/project_trackers.rb` | Render the module above the Weekly Ships panel. |
| `test/support/notion_log_fixtures.rb` | Create. Row builders and `FakeNotion`. |
| `test/models/notion_page_log_columns_test.rb`, `test/lib/stacks/notion/props_test.rb`, `observation_test.rb`, `problem_test.rb`, `client_test.rb`, `filtered_sync_test.rb`, `test/lib/tasks/sync_notion_log_rake_test.rb`, `test/models/project_tracker_log_test.rb`, `test/lib/stacks/project_log_test.rb`, `test/integration/admin_project_log_test.rb` | Create. |
| `test/lib/tasks/twist_channel_access_rake_test.rb`, `test/models/admin_authorization_test.rb` | Modify. |

## Decisions

**1. The filtered sync.** A new class, `Stacks::Notion::FilteredSync`, driven by two new client methods beside `sync_database`.

- *Window.* `since` is the start time of the last successful run less a one-day overlap, never less than three days back and never more than 90. With no successful run it is 90 days. The high-water mark is stored per database in `System` settings as `notion_filtered_sync_marks` (`{"OBSERVATIONS" => iso8601, "PROBLEMS" => iso8601}`), the same place `runn_synced_at` lives (`app/models/system.rb:24-26`, written at `lib/stacks/runn.rb:74`). `SystemTask` cannot hold it: rows older than a week are deleted (`app/models/system_task.rb:14-16`). The mark is the run's start time and is written only after the last page, because results come newest edit first and a run that dies midway would otherwise leave a hole below the newest row.
- *Two query shapes.* The first run (no mark) sends the verified filter: relation not empty and edited since. Every later run drops the relation clause and asks for every row edited since. A later run inserts a row only when it has a project and updates a row only when Stacks already holds it. This is how a row that lost its Project leaves the log with no extra call: it comes back as an edit with an empty relation, its `project_ids` becomes `[]`, and no tracker matches it. At today's volume the unfiltered three-day window is about 275 rows, three calls. The timestamp-only filter has the same shape as the verified one but has not been run against production, so the preview task can force it (Task 7) and the client raises on any non-200.
- *Never deletes unseen rows.* There is no sweep. `FilteredSync` soft-deletes one row at a time and only on evidence about that row.
- *Dismissed.* An edit like any other: the row is updated in place and the views filter on its status.
- *Trashed.* The spec says trashed rows are "requested explicitly for the window". Notion's database query cannot return a trashed page, so that is not buildable. Instead each run rechecks by id (`GET /v1/pages/:id`) up to 200 stored rows it did not see, least recently checked first: every stored Problem, and Observations from the last 90 days. `archived` or `in_trash` true, or a 404, soft-deletes the row. With 1,000 rows in scope a trashed row leaves the log within five days. A 404 is trusted only because the same run has just queried the database successfully, so lost access cannot be mistaken for a deletion. A page restored in Notion comes back as an edit and is recovered, as `sync_database` does (`lib/stacks/notion.rb:129-130`).
- *Relation over 25.* A truncated `Projects`, `Project` or `Problems` relation is stored as sent (the first 25) and counted in the run's stats as `truncated_relations`. No extra call. An observation with more than 25 projects or problems is not expected; the count makes it visible if it happens.
- *Problems with no Project.* "Escalated" needs the Problem an observation was folded into, and a Problem inherits a Project only when all its observations agree. So after both queries, a Problem that a stored observation names and Stacks does not hold is fetched by id, at most 100 a run, and stored with an empty `project_ids`. It appears under no tracker's open problems and is kept fresh by the later unfiltered runs.
- *Parent id.* Rows are stamped with the dashed id of the database that was queried, not with `parent.database_id` from the response, so the `NotionPage` scopes cannot miss them.

**2. Lookup by project.** An array column, `notion_pages.project_ids` (`character varying[]`, default `{}`, not null), with a GIN index, filled at sync. A tracker asks `project_ids && ARRAY[...]::varchar[]`. An expression index on the jsonb was rejected: Observations name the relation `Projects` and Problems name it `Project`, so one expression cannot cover both and every query would have to repeat it exactly. Two more columns ride the same migration: `occurred_at` (the date a row sorts and windows by, so "last 30 days" and paging are SQL) and `synced_at` (when the sync last saw or checked the row, which orders the recheck). A btree index on `(notion_parent_id, occurred_at)` is added too: `notion_pages` has no index on `notion_parent_id` today, so every existing scope (`app/models/notion_page.rb:4-31`) scans the table, which stops being free once it grows by thousands of rows a month. All of it is additive and safe under the old code: the old `sync_database` writes an explicit column list (`lib/stacks/notion.rb:132-137`).

**3. Wrappers.** `Stacks::Notion::Observation` and `Stacks::Notion::Problem` read through a new module, `Stacks::Notion::Props`, that works on a raw hash and returns nil or `[]` for anything missing or misshapen. They do not use `Base#get_prop_value`, which raises when `properties` is nil (`lib/stacks/notion/base.rb:22`). A select value outside its known set (the stray `Decision` salience, say) reads as nil where the page compares it, and as its literal text where the page only prints it.

**4. Where it runs.** Its own task, `stacks:sync_notion_log`, with its own `SystemTask`, invoked at the end of the daily `stacks:sync_notion` after the Twist check (`lib/tasks/stacks.rake:436-437`). Daily is the recommendation: the log is read to spot risk across weeks, and a row arriving the next morning costs nothing. Hourly would cost about four Notion calls a run plus the recheck and needs a Heroku Scheduler entry; the task is safe to schedule that way later because it is idempotent and holds an advisory lock. The ride starts only after one run has been made by hand (see 8).

**5. The page.** `ActiveAdmin.register_page "Log"` with `belongs_to :project_tracker`, as `app/admin/project_cost_explorer.rb:1-9` does. Two checks: ActiveAdmin's own page check (`ActiveAdmin::PageController#authorize_access!`), then `authorize! :read, tracker` in a `before_action`. The adapter refuses every page but two to a project-scoped grantee (`app/models/admin_authorization.rb:158-162`), so it gains one line that lets a user with a scoped grant through the page gate; the tracker check then narrows it to their own trackers. `view`, `source`, `valence` and `page` are whitelisted and anything else is ignored. A registered page runs no Ransack, so there is no `q` or `order` to drop as `app/admin/meeting_scans.rb:35-38` does; any format but HTML raises `ActionController::UnknownFormat`. Highlights and Everything read 200 stored rows a page by offset, newest first; the gate and the chips are applied in Ruby to the rows read, so a filtered page can show fewer than 200. Needs attention reads at most 500 rows from the last 30 days and says so if it hits the cap.

**6. Escalated.** `Stacks::ProjectLog.escalated?(observation, problems)`: the observation is Negative and either its salience is High or one of its problems is Open with severity High or Critical. The problems for a page of rows are loaded in one query (the ids in the rows' `Problems` relations) plus the tracker's own problems, then indexed both by id and by each Problem's `Source Observations`, so a link held on either side counts. No per-row query.

**7. The tracker-page module.** Rendered from the show block directly above the Weekly Ships panel (`app/admin/project_trackers.rb:501`), from `Stacks::ProjectLog.summary(tracker)`: the same bounded queries as Needs attention (500 rows, 200 problems). Anyone who can open the show page can read the tracker, so the link is always shown.

**8. Rollout.** The migration is applied on production first, while the old code is live. The sync adds retry with backoff for its own two calls (429 honours `Retry-After`; 5xx and timeouts back off 1, 2, 4, 8 seconds; five attempts); the existing whole-database sync is left as it is. The first run is about ten query calls and at most 100 page fetches, made one at a time, well under Notion's three a second. `stacks:preview_notion_log_sync` runs the same queries and prints the counts without writing. The nightly ride does nothing until `notion_filtered_sync_marks` holds a mark, so the first real run is always the one the coordinator makes by hand after reading the preview.

**Interim rule (to be removed).** Valence does not exist in Notion yet. Until it does, an observation with no valence whose Type is `Risk` is shown as Negative and one whose Type is `Win` is shown as Positive. This is a display mapping of a field Stacksbot wrote. It lives in one constant, `Stacks::Notion::Observation::INTERIM_VALENCE_BY_TYPE`; replacing its value with `{}.freeze` removes the rule. A stored valence always wins. The page says when it is in use.

**Other choices.**
- Source chips group the `Source` select for display: Twist; Meet (`Meet`, `Google Meet`, `Gemini Notes`); Mail (`Google Groups`, `google_groups`, `Gmail`); Notion (any value starting `Notion`); Other.
- An open Problem is one whose status is not `Resolved` or `Dismissed`. A blank or unknown status counts as open: a risk page should fail visible.
- The module's "latest three rows" are the first three rows of Needs attention.
- The property name is assumed to be `Valence`. If Stacksbot names it otherwise, change `Stacks::Notion::Observation::VALENCE_PROPERTY`.

---

### Task 1: Columns and indexes on `notion_pages`

**Files:** Create `db/migrate/20261013100000_add_log_columns_to_notion_pages.rb`, `test/models/notion_page_log_columns_test.rb`. Modify `db/schema.rb`.

**Consumes:** nothing. **Produces:** `notion_pages.project_ids` (string array, default `[]`, not null), `occurred_at` (datetime, null), `synced_at` (datetime, null); indexes `index_notion_pages_on_project_ids` (GIN) and `index_notion_pages_on_parent_and_occurred_at`.

- [ ] **Step 1: Write the failing test** `test/models/notion_page_log_columns_test.rb`:

```ruby
require 'test_helper'

class NotionPageLogColumnsTest < ActiveSupport::TestCase
  test "a page starts with no projects and no dates" do
    np = NotionPage.create!(notion_id: SecureRandom.uuid, data: {}).reload
    assert_equal [], np.project_ids
    assert_nil np.occurred_at
    assert_nil np.synced_at
  end

  test "a page is found by any one of its projects" do
    a, b, c = Array.new(3) { SecureRandom.uuid }
    hit = NotionPage.create!(notion_id: SecureRandom.uuid, data: {}, project_ids: [a, b])
    NotionPage.create!(notion_id: SecureRandom.uuid, data: {}, project_ids: [c])
    found = NotionPage.where("project_ids && ARRAY[?]::varchar[]", [b, SecureRandom.uuid])
    assert_equal [hit.id], found.pluck(:id)
  end

  test "the project list has a GIN index and the parent has a btree with the date" do
    indexes = ActiveRecord::Base.connection.indexes(:notion_pages).index_by(&:name)
    assert_equal :gin, indexes.fetch("index_notion_pages_on_project_ids").using
    assert_equal %w[notion_parent_id occurred_at], indexes.fetch("index_notion_pages_on_parent_and_occurred_at").columns
  end
end
```

- [ ] **Step 2: Run it, expect failure** (`unknown attribute 'project_ids'`):

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/models/notion_page_log_columns_test.rb
```

- [ ] **Step 3: Write the migration.** Check `ActiveRecord::Schema.define(version: ...)` in `db/schema.rb` first (it is `2026_10_13_090000` today, `db/schema.rb:13`); if it is higher than `2026_10_13_100000`, rename the migration to a timestamp above it.

```ruby
# What the project log needs to find and order Stacksbot's rows without
# scanning notion_pages: the Notion project ids a row is filed under, the date
# it sorts by, and when the filtered sync last saw it.
#
# This runs on production while the code before it is live. That code writes
# an explicit column list (Stacks::Notion#sync_database), so new columns with
# defaults are invisible to it. Indexes are built concurrently. Safe to run
# twice. If a concurrent build is interrupted it leaves an INVALID index: drop
# that index by name and run this again.
class AddLogColumnsToNotionPages < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  PROJECTS_INDEX = "index_notion_pages_on_project_ids".freeze
  PARENT_INDEX = "index_notion_pages_on_parent_and_occurred_at".freeze

  def up
    unless column_exists?(:notion_pages, :project_ids)
      add_column :notion_pages, :project_ids, :string, array: true, default: [], null: false
    end
    add_column :notion_pages, :occurred_at, :datetime unless column_exists?(:notion_pages, :occurred_at)
    add_column :notion_pages, :synced_at, :datetime unless column_exists?(:notion_pages, :synced_at)

    unless index_name_exists?(:notion_pages, PROJECTS_INDEX)
      add_index :notion_pages, :project_ids, using: :gin, algorithm: :concurrently, name: PROJECTS_INDEX
    end
    unless index_name_exists?(:notion_pages, PARENT_INDEX)
      add_index :notion_pages, [:notion_parent_id, :occurred_at], algorithm: :concurrently, name: PARENT_INDEX
    end
  end

  def down
    remove_index :notion_pages, name: PARENT_INDEX, algorithm: :concurrently if index_name_exists?(:notion_pages, PARENT_INDEX)
    remove_index :notion_pages, name: PROJECTS_INDEX, algorithm: :concurrently if index_name_exists?(:notion_pages, PROJECTS_INDEX)
    remove_column :notion_pages, :synced_at if column_exists?(:notion_pages, :synced_at)
    remove_column :notion_pages, :occurred_at if column_exists?(:notion_pages, :occurred_at)
    remove_column :notion_pages, :project_ids if column_exists?(:notion_pages, :project_ids)
  end
end
```

- [ ] **Step 4: Hand-edit `db/schema.rb`.** Set the version to `2026_10_13_100000`. Make the `notion_pages` block (`db/schema.rb:702-711`) read:

```ruby
  create_table "notion_pages", force: :cascade do |t|
    t.string "notion_id", null: false
    t.string "notion_parent_type"
    t.string "notion_parent_id"
    t.jsonb "data", default: {}, null: false
    t.string "page_title", default: "", null: false
    t.datetime "deleted_at"
    t.string "project_ids", default: [], null: false, array: true
    t.datetime "occurred_at"
    t.datetime "synced_at"
    t.index ["deleted_at"], name: "index_notion_pages_on_deleted_at"
    t.index ["notion_id"], name: "index_notion_pages_on_notion_id", unique: true
    t.index ["notion_parent_id", "occurred_at"], name: "index_notion_pages_on_parent_and_occurred_at"
    t.index ["project_ids"], name: "index_notion_pages_on_project_ids", using: :gin
  end
```

- [ ] **Step 5: Load the schema into the isolated database and confirm the file is untouched.**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails db:schema:load
git diff --stat db/schema.rb   # only the lines added by hand
```

- [ ] **Step 6: Run the test, expect 3 runs, 0 failures.**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/models/notion_page_log_columns_test.rb
```

- [ ] **Step 7: Commit.** `feat(notion): columns and indexes on notion_pages for the project log`

---

### Task 2: Safe readers for a raw Notion page (`Stacks::Notion::Props`)

**Files:** Create `lib/stacks/notion/props.rb`, `test/lib/stacks/notion/props_test.rb`.

**Consumes:** nothing. **Produces:** module functions, each taking `data` (anything) and a property name, none of which can raise:

| Function | Returns |
|---|---|
| `Props.top(data, key)` | the top-level value, or nil when `data` is not a Hash |
| `Props.select(data, name)` | String (stripped) or nil |
| `Props.text(data, name, type = "rich_text")` | String, `""` when empty; fragments joined |
| `Props.url(data, name)` | String starting `http://` or `https://`, or nil |
| `Props.http_url(value)` | the same test on a bare value |
| `Props.time(data, name)` | `ActiveSupport::TimeWithZone` from the date's `start`, or nil |
| `Props.parse_time(value)` | `ActiveSupport::TimeWithZone` or nil |
| `Props.relation_ids(data, name)` | Array of String ids, deduplicated, `[]` when none |
| `Props.relation_truncated?(data, name)` | true only when the property's `has_more` is true |
| `Props.number(data, name)` | Numeric or nil |
| `Props.people_names(data, name)` | Array of String |

- [ ] **Step 1: Write the failing tests** `test/lib/stacks/notion/props_test.rb`:

```ruby
require 'test_helper'

class StacksNotionPropsTest < ActiveSupport::TestCase
  P = Stacks::Notion::Props

  def page(props)
    { "properties" => props }
  end

  test "every reader returns its empty value for data that is not a page" do
    [nil, "text", 7, [], {}, { "properties" => nil }, { "properties" => [] }, page("Salience" => "High"),
     page("Salience" => { "type" => "select", "select" => "High" })].each do |data|
      assert_nil P.select(data, "Salience")
      assert_equal "", P.text(data, "Salience")
      assert_nil P.url(data, "Salience")
      assert_nil P.time(data, "Salience")
      assert_equal [], P.relation_ids(data, "Salience")
      assert_not P.relation_truncated?(data, "Salience")
      assert_nil P.number(data, "Salience")
      assert_equal [], P.people_names(data, "Salience")
    end
  end

  test "select reads the option name, trimmed, and nil for an empty select" do
    assert_equal "High", P.select(page("Salience" => { "type" => "select", "select" => { "name" => " High " } }), "Salience")
    assert_nil P.select(page("Salience" => { "type" => "select", "select" => nil }), "Salience")
    assert_nil P.select(page("Salience" => { "type" => "select", "select" => { "name" => "" } }), "Salience")
  end

  test "text joins the fragments of a rich text or a title" do
    rich = { "type" => "rich_text", "rich_text" => [{ "plain_text" => "Client " }, { "plain_text" => "is unhappy" }, "junk", nil] }
    assert_equal "Client is unhappy", P.text(page("Observation" => rich), "Observation")
    title = { "type" => "title", "title" => [{ "plain_text" => "Slip" }] }
    assert_equal "Slip", P.text(page("Name" => title), "Name", "title")
    assert_equal "", P.text(page("Name" => { "type" => "title", "title" => [] }), "Name", "title")
  end

  test "url accepts http and https only" do
    ok = page("Source Ref" => { "type" => "url", "url" => "https://twist.com/a/133876/ch/1/t/2/" })
    assert_equal "https://twist.com/a/133876/ch/1/t/2/", P.url(ok, "Source Ref")
    ["javascript:alert(1)", "data:text/html,x", " https://x.test", "ftp://x.test", "", nil, 5].each do |bad|
      assert_nil P.url(page("Source Ref" => { "type" => "url", "url" => bad }), "Source Ref"), bad.inspect
    end
  end

  test "time reads a date's start, as a day or a moment, and nil for anything unreadable" do
    day = page("Observed At" => { "type" => "date", "date" => { "start" => "2026-10-01" } })
    assert_equal Time.zone.parse("2026-10-01"), P.time(day, "Observed At")
    moment = page("Observed At" => { "type" => "date", "date" => { "start" => "2026-10-01T14:30:00.000-04:00" } })
    assert_equal Time.utc(2026, 10, 1, 18, 30), P.time(moment, "Observed At").utc
    ["not a date", "2026-13-45", "", nil, 5].each do |bad|
      assert_nil P.time(page("Observed At" => { "type" => "date", "date" => { "start" => bad } }), "Observed At"), bad.inspect
    end
    assert_nil P.time(page("Observed At" => { "type" => "date", "date" => nil }), "Observed At")
  end

  test "relation_ids keeps string ids once each, and says when Notion cut the list" do
    rel = { "type" => "relation", "relation" => [{ "id" => "a" }, { "id" => "a" }, { "id" => "b" }, { "id" => nil }, "x"], "has_more" => true }
    assert_equal %w[a b], P.relation_ids(page("Projects" => rel), "Projects")
    assert P.relation_truncated?(page("Projects" => rel), "Projects")
    assert_not P.relation_truncated?(page("Projects" => rel.merge("has_more" => false)), "Projects")
  end

  test "number and people_names" do
    assert_equal 4, P.number(page("Occurrences" => { "type" => "number", "number" => 4 }), "Occurrences")
    assert_nil P.number(page("Occurrences" => { "type" => "number", "number" => "4" }), "Occurrences")
    people = { "type" => "people", "people" => [{ "name" => "Sam Lead" }, { "name" => nil }, { "id" => "u" }] }
    assert_equal ["Sam Lead"], P.people_names(page("Owner" => people), "Owner")
  end

  test "top reads a top-level key" do
    assert_equal "x", P.top({ "url" => "x" }, "url")
    assert_nil P.top(nil, "url")
  end
end
```

- [ ] **Step 2: Run, expect failure** (`uninitialized constant Stacks::Notion::Props`):

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/stacks/notion/props_test.rb
```

- [ ] **Step 3: Implement** `lib/stacks/notion/props.rb`:

```ruby
# Reads properties off a raw Notion page hash (what the API returns and what
# notion_pages.data stores). The rows are written by Stacksbot and edited by
# people, so every reader here returns an empty value for anything missing or
# misshapen and none of them raises.
module Stacks::Notion::Props
  module_function

  def top(data, key)
    data.is_a?(Hash) ? data[key] : nil
  end

  # The value under the property's own type key, or nil.
  def value(data, name, type)
    props = top(data, "properties")
    prop = props.is_a?(Hash) ? props[name] : nil
    prop.is_a?(Hash) ? prop[type] : nil
  end

  def select(data, name)
    v = value(data, name, "select")
    name_of = v.is_a?(Hash) ? v["name"] : nil
    name_of.is_a?(String) ? name_of.strip.presence : nil
  end

  def text(data, name, type = "rich_text")
    v = value(data, name, type)
    return "" unless v.is_a?(Array)
    v.map { |f| f.is_a?(Hash) && f["plain_text"].is_a?(String) ? f["plain_text"] : "" }.join.strip
  end

  def url(data, name)
    http_url(value(data, name, "url"))
  end

  # Only a web address is ever linked: a stored "javascript:" would run.
  def http_url(v)
    v.is_a?(String) && v.match?(%r{\Ahttps?://\S+\z}i) ? v : nil
  end

  def time(data, name)
    v = value(data, name, "date")
    parse_time(v.is_a?(Hash) ? v["start"] : nil)
  end

  def parse_time(v)
    return nil unless v.is_a?(String) && v.present?
    Time.zone.parse(v)
  rescue ArgumentError
    nil
  end

  def relation_ids(data, name)
    v = value(data, name, "relation")
    return [] unless v.is_a?(Array)
    v.filter_map { |r| r["id"] if r.is_a?(Hash) && r["id"].is_a?(String) && r["id"].present? }.uniq
  end

  # Notion sends the first 25 of a longer relation and sets has_more.
  def relation_truncated?(data, name)
    props = top(data, "properties")
    prop = props.is_a?(Hash) ? props[name] : nil
    prop.is_a?(Hash) && prop["has_more"] == true
  end

  def number(data, name)
    v = value(data, name, "number")
    v.is_a?(Numeric) ? v : nil
  end

  def people_names(data, name)
    v = value(data, name, "people")
    return [] unless v.is_a?(Array)
    v.filter_map { |p| p["name"].strip.presence if p.is_a?(Hash) && p["name"].is_a?(String) }
  end
end
```

- [ ] **Step 4: Run, expect 8 runs, 0 failures** (same command as Step 2).
- [ ] **Step 5: Commit.** `feat(notion): safe property readers for stored Notion rows`

---

### Task 3: The two databases, the wrappers, the scopes, and the fixtures

**Files:** Modify `lib/stacks/notion.rb`, `app/models/notion_page.rb`. Create `lib/stacks/notion/observation.rb`, `lib/stacks/notion/problem.rb`, `test/support/notion_log_fixtures.rb`, `test/lib/stacks/notion/observation_test.rb`, `test/lib/stacks/notion/problem_test.rb`.

**Consumes:** `Stacks::Notion::Props` (Task 2), the columns (Task 1).

**Produces:**
- `Stacks::Notion::FILTERED_DATABASES` = `{ OBSERVATIONS: { id: "390131fea2c7808bb216c38b46c3ba55", project_property: "Projects" }, PROBLEMS: { id: "18d6276a12aa4e0a957f013a69d5bb9a", project_property: "Project" } }`
- `Stacks::Notion.filtered_parent_id(key)` → dashed String.
- `Stacks::Notion#sync_database(id)` raises `ArgumentError` for either filtered database.
- `NotionPage.observations`, `NotionPage.problems` (relations); `NotionPage#as_observation`, `#as_problem`.
- `Stacks::Notion::Observation`: class methods `project_ids_in(data)` → `[String]`, `problem_ids_in(data)` → `[String]`, `occurred_at_in(data)` → Time or nil. Instance readers: `title` String; `text` String; `source` String or nil; `source_group` one of `"twist" "meet" "mail" "notion" "other"`; `source_url` String or nil; `notion_url` String; `observed_at` Time or nil; `salience` `"High"`, `"Medium"`, `"Low"` or nil; `type` String or nil; `status` String or nil; `dismissed?`; `stored_valence` and `valence` `"Positive"`, `"Neutral"`, `"Negative"` or nil; `valence_inferred?`; `negative?`; `project_ids`; `problem_ids`.
- `Stacks::Notion::Problem`: class methods `project_ids_in(data)`, `occurred_at_in(data)`. Instance readers: `title`; `kind`; `severity` (`"Critical"`, `"High"`, `"Medium"`, `"Low"` or nil); `severity_rank` Integer 0..4; `status`; `open?`; `unowned?`; `escalating?`; `owner_names` `[String]`; `occurrences` Integer or nil; `last_seen_at`, `first_seen_at` Time or nil; `project_ids`; `source_observation_ids`; `notion_url`.
- Test helpers in `NotionLogFixtures`: `observation_data`, `problem_data`, `observation!`, `problem!`, `project_page!`, `log_tracker!`, and class `NotionLogFixtures::FakeNotion`.

- [ ] **Step 1: Write the fixtures** `test/support/notion_log_fixtures.rb` (loaded by `test/test_helper.rb:4`). Rows are built the way `test/lib/stacks/notion/project_test.rb:7-17` builds a Projects page.

```ruby
# Builders for Stacksbot's Observations and Problems rows as Notion sends
# them, and a stand-in Notion client, so no test of the project log reaches
# the network.
module NotionLogFixtures
  def nl_select(name)
    { "type" => "select", "select" => name && { "name" => name } }
  end

  def nl_relation(ids, has_more: false)
    { "type" => "relation", "relation" => ids.map { |id| { "id" => id } }, "has_more" => has_more }
  end

  def nl_text(type, value)
    { "type" => type, type => value.nil? ? [] : [{ "type" => "text", "plain_text" => value }] }
  end

  def nl_date(time)
    { "type" => "date", "date" => time && { "start" => time.iso8601 } }
  end

  # valence: nil with valence_property: false is today's Notion (no such
  # property); valence: nil with valence_property: true is an empty select.
  def observation_data(id: SecureRandom.uuid, name: "Observation", text: "Seen.", source: "Twist",
                       source_ref: "https://twist.com/a/133876/ch/1/t/2/", observed_at: Time.zone.now,
                       salience: "Medium", type: "FYI", status: "New", valence: nil, valence_property: true,
                       project_ids: [], problem_ids: [], edited: Time.zone.now, archived: false)
    props = {
      "Name" => nl_text("title", name), "Observation" => nl_text("rich_text", text),
      "Source" => nl_select(source), "Source Ref" => { "type" => "url", "url" => source_ref },
      "Observed At" => nl_date(observed_at), "Salience" => nl_select(salience), "Type" => nl_select(type),
      "Status" => nl_select(status), "Projects" => nl_relation(project_ids), "Problems" => nl_relation(problem_ids),
    }
    props["Valence"] = nl_select(valence) if valence_property || valence
    { "object" => "page", "id" => id, "url" => "https://www.notion.so/#{id.delete('-')}",
      "created_time" => (observed_at || edited).utc.iso8601, "last_edited_time" => edited.utc.iso8601,
      "archived" => archived,
      "parent" => { "type" => "database_id", "database_id" => Stacks::Notion.filtered_parent_id(:OBSERVATIONS) },
      "properties" => props }
  end

  def problem_data(id: SecureRandom.uuid, name: "Problem", kind: "delivery", severity: "High", status: "Open",
                   owner: nil, occurrences: 1, last_seen: Time.zone.now, project_ids: [],
                   source_observation_ids: [], edited: Time.zone.now, archived: false)
    { "object" => "page", "id" => id, "url" => "https://www.notion.so/#{id.delete('-')}",
      "created_time" => (last_seen || edited).utc.iso8601, "last_edited_time" => edited.utc.iso8601,
      "archived" => archived,
      "parent" => { "type" => "database_id", "database_id" => Stacks::Notion.filtered_parent_id(:PROBLEMS) },
      "properties" => {
        "Problem" => nl_text("title", name), "Kind" => nl_select(kind), "Severity" => nl_select(severity),
        "Status" => nl_select(status),
        "Owner" => { "type" => "people", "people" => owner ? [{ "name" => owner }] : [] },
        "Occurrences" => { "type" => "number", "number" => occurrences }, "Last Seen" => nl_date(last_seen),
        "Project" => nl_relation(project_ids), "Source Observations" => nl_relation(source_observation_ids),
      } }
  end

  def store_log_row!(data, key, wrapper, synced_at: Time.zone.now)
    NotionPage.create!(
      notion_id: data["id"], notion_parent_type: "database_id",
      notion_parent_id: Stacks::Notion.filtered_parent_id(key),
      page_title: Stacks::Notion::Props.text(data, key == :OBSERVATIONS ? "Name" : "Problem", "title"),
      data: data, project_ids: wrapper.project_ids_in(data), occurred_at: wrapper.occurred_at_in(data),
      synced_at: synced_at
    )
  end

  def observation!(synced_at: Time.zone.now, **attrs)
    store_log_row!(observation_data(**attrs), :OBSERVATIONS, Stacks::Notion::Observation, synced_at: synced_at)
  end

  def problem!(synced_at: Time.zone.now, **attrs)
    store_log_row!(problem_data(**attrs), :PROBLEMS, Stacks::Notion::Problem, synced_at: synced_at)
  end

  def project_page!(title: "Harvey")
    NotionPage.create!(
      notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:PROJECTS]), page_title: title,
      data: { "last_edited_time" => Time.zone.now.iso8601,
              "properties" => { "Stage" => { "type" => "select", "select" => { "name" => "Active" } } } }
    )
  end

  # A tracker filed under one new Notion project. Returns [tracker, project id].
  def log_tracker!(name: "Log Tracker #{SecureRandom.hex(2)}", project: project_page!)
    pt = ProjectTracker.new(name: name, notion_project_ids: project ? [project.notion_id] : [])
    pt.save!(validate: false)
    [pt, project&.notion_id]
  end

  # Answers the two calls the filtered sync makes. pages: database id =>
  # an array of result pages (each an array of rows). by_id: page id => row.
  # It does not apply the filter: tests assert on the filter it was sent.
  class FakeNotion
    attr_reader :queries, :fetched

    def initialize(pages: {}, by_id: {}, fail_on_page: nil)
      @pages = pages
      @by_id = by_id
      @fail_on_page = fail_on_page
      @queries = []
      @fetched = []
    end

    def query_database_filtered(database_id, filter:, sorts: nil, start_cursor: nil, page_size: 100)
      @queries << { database_id: database_id, filter: filter, sorts: sorts, start_cursor: start_cursor, page_size: page_size }
      batches = @pages.fetch(database_id, [[]])
      i = start_cursor.to_i
      raise Stacks::Notion::Error.new("Notion query failed (500)", status: 500) if @fail_on_page == i
      more = i + 1 < batches.size
      { "results" => batches[i].map(&:deep_dup), "next_cursor" => (more ? (i + 1).to_s : nil), "has_more" => more }
    end

    def fetch_page(page_id)
      @fetched << page_id
      body = @by_id[page_id]
      body ? { status: 200, body: body.deep_dup } : { status: 404, body: { "code" => "object_not_found" } }
    end
  end
end
```

(`FakeNotion` references `Stacks::Notion::Error`, which Task 4 adds. It is only raised when `fail_on_page` is set, which no test before Task 5 does.)

- [ ] **Step 2: Write the failing wrapper tests.**

`test/lib/stacks/notion/observation_test.rb`:

```ruby
require 'test_helper'

class StacksNotionObservationTest < ActiveSupport::TestCase
  include NotionLogFixtures

  def obs(**attrs)
    NotionPage.new(notion_id: "n-1", page_title: "Stored title", data: observation_data(**attrs)).as_observation
  end

  test "the two databases are not part of the whole-database sync" do
    filtered = Stacks::Notion::FILTERED_DATABASES.values.map { |d| d[:id] }
    assert_equal %w[390131fea2c7808bb216c38b46c3ba55 18d6276a12aa4e0a957f013a69d5bb9a], filtered
    assert_empty filtered & Stacks::Notion::DATABASE_IDS.values
    assert_equal "390131fe-a2c7-808b-b216-c38b46c3ba55", Stacks::Notion.filtered_parent_id(:OBSERVATIONS)
  end

  test "sync_database refuses a filtered database, dashed or not, before any call" do
    client = Stacks::Notion.allocate
    client.expects(:query_database).never
    ["390131fea2c7808bb216c38b46c3ba55", "18d6276a-12aa-4e0a-957f-013a69d5bb9a"].each do |id|
      assert_raises(ArgumentError) { client.sync_database(id) }
    end
  end

  test "it reads every field the log shows" do
    at = Time.zone.parse("2026-10-01T15:00:00Z")
    o = obs(name: "Client unhappy with pace", text: "Asked twice for a date.", source: "Twist",
            source_ref: "https://twist.com/a/133876/ch/9/t/8/", observed_at: at, salience: "High", type: "Risk",
            status: "Triaged", valence: "Negative", project_ids: %w[p1 p2], problem_ids: %w[pr1])
    assert_equal "Client unhappy with pace", o.title
    assert_equal "Asked twice for a date.", o.text
    assert_equal "Twist", o.source
    assert_equal "twist", o.source_group
    assert_equal "https://twist.com/a/133876/ch/9/t/8/", o.source_url
    assert_equal at, o.observed_at
    assert_equal "High", o.salience
    assert_equal "Risk", o.type
    assert_equal "Triaged", o.status
    assert_equal "Negative", o.valence
    assert_not o.valence_inferred?
    assert o.negative?
    assert_not o.dismissed?
    assert_equal %w[p1 p2], o.project_ids
    assert_equal %w[pr1], o.problem_ids
    assert_match %r{\Ahttps://www\.notion\.so/}, o.notion_url
  end

  test "a row with no properties at all reads as empty and never raises" do
    [nil, {}, { "properties" => nil }, { "properties" => "x" }].each do |data|
      o = NotionPage.new(notion_id: "ab-cd", page_title: "", data: data).as_observation
      assert_equal "Untitled", o.title
      assert_equal "", o.text
      assert_nil o.source
      assert_equal "other", o.source_group
      assert_nil o.source_url
      assert_nil o.observed_at
      assert_nil o.salience
      assert_nil o.type
      assert_nil o.status
      assert_nil o.valence
      assert_not o.negative?
      assert_not o.dismissed?
      assert_equal [], o.project_ids
      assert_equal [], o.problem_ids
      assert_equal "https://www.notion.so/garden3d/abcd", o.notion_url
    end
  end

  test "the title falls back to the stored page title" do
    assert_equal "Stored title", obs(name: nil).title
  end

  test "a stray salience or valence reads as none; a stray type is kept as text" do
    assert_nil obs(salience: "Decision").salience
    assert_nil obs(valence: "Ugly").valence
    assert_equal "business", obs(type: "business").type
  end

  test "sources group for the chips" do
    { "Twist" => "twist", "Meet" => "meet", "Google Meet" => "meet", "Gemini Notes" => "meet",
      "Google Groups" => "mail", "google_groups" => "mail", "Gmail" => "mail", "Notion" => "notion",
      "Notion (Milestones)" => "notion", "Stacks/BI" => "other", "Sentry" => "other", nil => "other" }.each do |source, group|
      assert_equal group, obs(source: source).source_group, source.inspect
    end
  end

  test "interim: with no valence, a Risk shows as Negative and a Win as Positive" do
    risk = obs(type: "Risk", valence: nil, valence_property: false)
    assert_equal "Negative", risk.valence
    assert risk.valence_inferred?
    assert_nil risk.stored_valence
    win = obs(type: "Win", valence: nil)
    assert_equal "Positive", win.valence
    assert win.valence_inferred?
    assert_nil obs(type: "FYI", valence: nil).valence
    assert_nil obs(type: "Decision", valence: nil).valence
  end

  test "interim: a stored valence always wins over the type" do
    o = obs(type: "Risk", valence: "Neutral")
    assert_equal "Neutral", o.valence
    assert_not o.valence_inferred?
    assert_not o.negative?
  end

  test "interim: the rule is one constant" do
    assert_equal({ "Risk" => "Negative", "Win" => "Positive" }, Stacks::Notion::Observation::INTERIM_VALENCE_BY_TYPE)
    Stacks::Notion::Observation.stub_const(:INTERIM_VALENCE_BY_TYPE, {}.freeze) do
      assert_nil obs(type: "Risk", valence: nil).valence
    end
  end

  test "the date falls back to when the row was created" do
    data = observation_data(observed_at: nil, edited: Time.zone.parse("2026-09-01T00:00:00Z"))
    assert_equal Time.zone.parse("2026-09-01T00:00:00Z"), Stacks::Notion::Observation.occurred_at_in(data)
    assert_nil Stacks::Notion::Observation.occurred_at_in(nil)
  end

  test "a source link that is not a web address is not offered" do
    assert_nil obs(source_ref: "javascript:alert(1)").source_url
  end
end
```

`stub_const` is not in Minitest. Add this to `test/support/notion_log_fixtures.rb`, outside the module:

```ruby
class Module
  # Swap a constant for the length of a block (tests only).
  def stub_const(name, value)
    original = const_get(name)
    silence_warnings { const_set(name, value) }
    yield
  ensure
    silence_warnings { const_set(name, original) }
  end
end
```

`test/lib/stacks/notion/problem_test.rb`:

```ruby
require 'test_helper'

class StacksNotionProblemTest < ActiveSupport::TestCase
  include NotionLogFixtures

  def prob(**attrs)
    NotionPage.new(notion_id: "n-2", page_title: "Stored", data: problem_data(**attrs)).as_problem
  end

  test "it reads every field the log shows" do
    seen = Time.zone.parse("2026-10-05T12:00:00Z")
    p = prob(name: "Timeline slipping", kind: "delivery", severity: "Critical", status: "Open", owner: "Sam Lead",
             occurrences: 4, last_seen: seen, project_ids: %w[p1], source_observation_ids: %w[o1 o2])
    assert_equal "Timeline slipping", p.title
    assert_equal "delivery", p.kind
    assert_equal "Critical", p.severity
    assert_equal 0, p.severity_rank
    assert_equal "Open", p.status
    assert p.open?
    assert p.unowned?
    assert p.escalating?
    assert_equal ["Sam Lead"], p.owner_names
    assert_equal 4, p.occurrences
    assert_equal seen, p.last_seen_at
    assert_equal %w[p1], p.project_ids
    assert_equal %w[o1 o2], p.source_observation_ids
  end

  test "escalating means Open and High or Critical, nothing else" do
    table = { %w[Open Critical] => true, %w[Open High] => true, %w[Open Medium] => false, %w[Open Low] => false,
              %w[Owned Critical] => false, %w[Mitigating High] => false, %w[Resolved Critical] => false,
              %w[Dismissed High] => false, ["Open", nil] => false, [nil, "High"] => false }
    table.each do |(status, severity), expected|
      assert_equal expected, prob(status: status, severity: severity).escalating?, [status, severity].inspect
    end
  end

  test "open means not Resolved and not Dismissed; a blank or odd status stays visible" do
    { "Open" => true, "Owned" => true, "Mitigating" => true, "Resolved" => false, "Dismissed" => false,
      nil => true, "Parked" => true }.each do |status, expected|
      assert_equal expected, prob(status: status).open?, status.inspect
    end
  end

  test "severity ranks Critical first and an unknown one last" do
    assert_equal [0, 1, 2, 3, 4], ["Critical", "High", "Medium", "Low", "Huge"].map { |s| prob(severity: s).severity_rank }
    assert_nil prob(severity: "Huge").severity
  end

  test "the owner falls back to the Owner Name text" do
    data = problem_data(owner: nil)
    data["properties"]["Owner Name"] = nl_text("rich_text", "Alex PM")
    assert_equal ["Alex PM"], NotionPage.new(notion_id: "n", data: data).as_problem.owner_names
  end

  test "a row with no properties reads as empty and never raises" do
    [nil, {}, { "properties" => [] }].each do |data|
      p = NotionPage.new(notion_id: "ab-cd", page_title: "", data: data).as_problem
      assert_equal "Untitled", p.title
      assert_nil p.severity
      assert_equal 4, p.severity_rank
      assert p.open?
      assert_not p.escalating?
      assert_equal [], p.owner_names
      assert_nil p.occurrences
      assert_nil p.last_seen_at
      assert_equal [], p.project_ids
      assert_equal [], p.source_observation_ids
    end
  end

  test "scopes hold each database's rows and nothing else" do
    o = observation!
    p = problem!
    lead = NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                              notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]), data: {})
    assert_equal [o.id], NotionPage.observations.pluck(:id)
    assert_equal [p.id], NotionPage.problems.pluck(:id)
    assert_not_includes NotionPage.observations.pluck(:id) + NotionPage.problems.pluck(:id), lead.id
    assert_kind_of Stacks::Notion::Observation, o.as_observation
    assert_kind_of Stacks::Notion::Problem, p.as_problem
  end
end
```

- [ ] **Step 3: Run both, expect failure** (`uninitialized constant ... FILTERED_DATABASES`):

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/stacks/notion/observation_test.rb test/lib/stacks/notion/problem_test.rb
```

- [ ] **Step 4: `lib/stacks/notion.rb`.** After `DATABASE_IDS` (line 13) add:

```ruby
  # Stacksbot's tables, read by the filtered sync (Stacks::Notion::FilteredSync)
  # for the project log. They are NOT in DATABASE_IDS and must never be:
  # sync_database deletes every row under a database that it did not see, and
  # these are only ever read in part.
  FILTERED_DATABASES = {
    OBSERVATIONS: { id: "390131fea2c7808bb216c38b46c3ba55", project_property: "Projects" },
    PROBLEMS: { id: "18d6276a12aa4e0a957f013a69d5bb9a", project_property: "Project" },
  }.freeze

  # notion_pages.notion_parent_id of a filtered database's rows.
  def self.filtered_parent_id(key)
    Stacks::Utils.dashify_uuid(FILTERED_DATABASES.fetch(key)[:id])
  end
```

and make the first lines of `sync_database` (line 100):

```ruby
  def sync_database(database_id)
    if FILTERED_DATABASES.values.any? { |d| d[:id] == database_id.to_s.delete("-") }
      raise ArgumentError, "#{database_id} is read by the filtered sync only: a whole-database sync would delete its rows"
    end
    database_entries_touched = []
```

- [ ] **Step 5: `app/models/notion_page.rb`.** After `as_project` (line 35) add:

```ruby
  # Stacksbot's Observations and Problems, synced in part by
  # Stacks::Notion::FilteredSync for the project log.
  scope :observations, -> {
    where(notion_parent_type: "database_id", notion_parent_id: Stacks::Notion.filtered_parent_id(:OBSERVATIONS))
  }

  def as_observation
    Stacks::Notion::Observation.new(self)
  end

  scope :problems, -> {
    where(notion_parent_type: "database_id", notion_parent_id: Stacks::Notion.filtered_parent_id(:PROBLEMS))
  }

  def as_problem
    Stacks::Notion::Problem.new(self)
  end
```

- [ ] **Step 6: `lib/stacks/notion/observation.rb`.**

```ruby
# Wraps a NotionPage row from Stacksbot's Observations database. Every field
# was written by Stacksbot or edited by a person, so every reader goes through
# Stacks::Notion::Props and none of them raises.
class Stacks::Notion::Observation < Stacks::Notion::Base
  P = Stacks::Notion::Props

  VALENCE_PROPERTY = "Valence".freeze
  VALENCES = %w[Positive Neutral Negative].freeze
  SALIENCES = %w[High Medium Low].freeze
  DISMISSED = "Dismissed".freeze

  # INTERIM, until Stacksbot writes Valence (spec Part 3): a row with no
  # valence shows the valence its Type implies. A stored valence always wins.
  # To remove the rule, replace this value with {}.freeze.
  INTERIM_VALENCE_BY_TYPE = { "Risk" => "Negative", "Win" => "Positive" }.freeze

  # How the Source select groups for the log's chips. Display only.
  SOURCE_GROUPS = {
    "twist" => ["twist"],
    "meet" => ["meet", "google meet", "gemini notes"],
    "mail" => ["google groups", "google_groups", "gmail"],
  }.freeze
  SOURCE_GROUP_LABELS = {
    "twist" => "Twist", "meet" => "Meet", "mail" => "Mail", "notion" => "Notion", "other" => "Other",
  }.freeze

  def self.project_ids_in(data)
    P.relation_ids(data, "Projects")
  end

  def self.problem_ids_in(data)
    P.relation_ids(data, "Problems")
  end

  # The date a row sorts by: when it was observed, else when it was created.
  def self.occurred_at_in(data)
    P.time(data, "Observed At") || P.parse_time(P.top(data, "created_time"))
  end

  def title
    P.text(notion_page.data, "Name", "title").presence || notion_page.page_title.presence || "Untitled"
  end

  def text
    P.text(notion_page.data, "Observation")
  end

  def source
    P.select(notion_page.data, "Source")
  end

  def source_group
    name = source.to_s.downcase
    return "notion" if name.start_with?("notion")
    SOURCE_GROUPS.each { |group, names| return group if names.include?(name) }
    "other"
  end

  def source_url
    P.url(notion_page.data, "Source Ref")
  end

  def notion_url
    P.http_url(P.top(notion_page.data, "url")) || notion_page.notion_link
  end

  def observed_at
    notion_page.occurred_at || self.class.occurred_at_in(notion_page.data)
  end

  def salience
    value = P.select(notion_page.data, "Salience")
    SALIENCES.include?(value) ? value : nil
  end

  def type
    P.select(notion_page.data, "Type")
  end

  def status
    P.select(notion_page.data, "Status")
  end

  def dismissed?
    status == DISMISSED
  end

  def stored_valence
    value = P.select(notion_page.data, VALENCE_PROPERTY)
    VALENCES.include?(value) ? value : nil
  end

  def valence
    stored_valence || INTERIM_VALENCE_BY_TYPE[type]
  end

  def valence_inferred?
    stored_valence.nil? && valence.present?
  end

  def negative?
    valence == "Negative"
  end

  def project_ids
    self.class.project_ids_in(notion_page.data)
  end

  def problem_ids
    self.class.problem_ids_in(notion_page.data)
  end
end
```

- [ ] **Step 7: `lib/stacks/notion/problem.rb`.**

```ruby
# Wraps a NotionPage row from Stacksbot's Problems database. See
# Stacks::Notion::Observation: same rules, nothing here raises.
class Stacks::Notion::Problem < Stacks::Notion::Base
  P = Stacks::Notion::Props

  SEVERITIES = %w[Critical High Medium Low].freeze # worst first
  CLOSED_STATUSES = %w[Resolved Dismissed].freeze
  UNOWNED_STATUS = "Open".freeze
  ESCALATING_SEVERITIES = %w[Critical High].freeze

  def self.project_ids_in(data)
    P.relation_ids(data, "Project")
  end

  def self.occurred_at_in(data)
    P.time(data, "Last Seen") || P.time(data, "First Seen") || P.parse_time(P.top(data, "created_time"))
  end

  def title
    P.text(notion_page.data, "Problem", "title").presence || notion_page.page_title.presence || "Untitled"
  end

  def kind
    P.select(notion_page.data, "Kind")
  end

  def severity
    value = P.select(notion_page.data, "Severity")
    SEVERITIES.include?(value) ? value : nil
  end

  def severity_rank
    SEVERITIES.index(severity) || SEVERITIES.size
  end

  def status
    P.select(notion_page.data, "Status")
  end

  # A blank or unknown status counts as open: better shown than hidden.
  def open?
    !CLOSED_STATUSES.include?(status)
  end

  # Nobody owns it yet.
  def unowned?
    status == UNOWNED_STATUS
  end

  def escalating?
    unowned? && ESCALATING_SEVERITIES.include?(severity)
  end

  def owner_names
    names = P.people_names(notion_page.data, "Owner")
    names.any? ? names : [P.text(notion_page.data, "Owner Name").presence].compact
  end

  def occurrences
    value = P.number(notion_page.data, "Occurrences")
    value&.to_i
  end

  def last_seen_at
    P.time(notion_page.data, "Last Seen")
  end

  def first_seen_at
    P.time(notion_page.data, "First Seen")
  end

  def project_ids
    self.class.project_ids_in(notion_page.data)
  end

  def source_observation_ids
    P.relation_ids(notion_page.data, "Source Observations")
  end

  def notion_url
    P.http_url(P.top(notion_page.data, "url")) || notion_page.notion_link
  end
end
```

- [ ] **Step 8: Run, expect 0 failures**, then the existing Notion tests to confirm nothing moved:

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/stacks/notion
```

- [ ] **Step 9: Commit.** `feat(notion): Observation and Problem wrappers, scopes, and a guard on the whole-database sync`

---

### Task 4: Client calls for the filtered sync, with retry

**Files:** Modify `lib/stacks/notion.rb`. Create `test/lib/stacks/notion/client_test.rb`.

**Consumes:** nothing new.

**Produces:**
- `Stacks::Notion::Error < StandardError` with `status` (Integer) and `code` (String or nil).
- `Stacks::Notion.normalize_page!(row)` → the page title String; strips `icon`, `cover` and each file's `file` in place. `sync_database` now calls it; its behaviour does not change.
- `Stacks::Notion#query_database_filtered(database_id, filter:, sorts: nil, start_cursor: nil, page_size: 100)` → parsed Hash (`"results"`, `"next_cursor"`, `"has_more"`); raises `Error` on anything but 200 after retries.
- `Stacks::Notion#fetch_page(page_id)` → `{ status: 200 | 404, body: Hash }`; raises `Error` on anything else after retries.
- `Stacks::Notion#sleeper=` (a callable taking seconds) for tests.
- Private seams `post_json(path, body)` and `get_json(path)`, each returning `[status Integer, retry_after String or nil, parsed Hash]`. Tests stub these two; nothing else touches the wire.

- [ ] **Step 1: Write the failing tests** `test/lib/stacks/notion/client_test.rb`. The client is built with `allocate` so `initialize` (which reads the token) never runs.

```ruby
require 'test_helper'

class StacksNotionClientTest < ActiveSupport::TestCase
  DB = "390131fea2c7808bb216c38b46c3ba55".freeze
  FILTER = { and: [{ property: "Projects", relation: { is_not_empty: true } }] }.freeze

  setup do
    @client = Stacks::Notion.allocate
    @slept = []
    @client.sleeper = ->(seconds) { @slept << seconds }
  end

  test "normalize_page! strips what changes on every read and returns the title" do
    row = { "icon" => { "x" => 1 }, "cover" => { "y" => 2 },
            "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => "Hello" }, { "plain_text" => " there" }] },
                              "Docs" => { "type" => "files", "files" => [{ "name" => "a.pdf", "type" => "file", "file" => { "url" => "s3" } }] } } }
    assert_equal "Hello", Stacks::Notion.normalize_page!(row), "the first fragment, as sync_database has always stored it"
    assert_not row.key?("icon")
    assert_not row.key?("cover")
    assert_equal [{ "name" => "a.pdf", "type" => "file" }], row["properties"]["Docs"]["files"]
  end

  test "normalize_page! returns an empty title for a row with no title or no properties" do
    assert_equal "", Stacks::Notion.normalize_page!({ "properties" => { "Name" => { "type" => "title", "title" => [] } } })
    assert_equal "", Stacks::Notion.normalize_page!({ "properties" => nil })
    assert_equal "", Stacks::Notion.normalize_page!({})
  end

  test "a filtered query posts the filter, sort, cursor and page size and returns the body" do
    sorts = [{ timestamp: "last_edited_time", direction: "descending" }]
    @client.expects(:post_json).once.with(
      "/databases/#{DB}/query", { page_size: 100, filter: FILTER, sorts: sorts, start_cursor: "c1" }
    ).returns([200, nil, { "results" => [{ "id" => "a" }], "next_cursor" => nil }])
    out = @client.query_database_filtered(DB, filter: FILTER, sorts: sorts, start_cursor: "c1")
    assert_equal [{ "id" => "a" }], out["results"]
    assert_empty @slept
  end

  test "the first page sends no cursor" do
    @client.expects(:post_json).with("/databases/#{DB}/query", { page_size: 50, filter: FILTER }).returns([200, nil, {}])
    @client.query_database_filtered(DB, filter: FILTER, page_size: 50)
  end

  test "a 429 waits as long as Notion asks, then tries again" do
    @client.stubs(:post_json).returns([429, "7", { "code" => "rate_limited" }]).then.returns([200, nil, { "results" => [] }])
    assert_equal({ "results" => [] }, @client.query_database_filtered(DB, filter: FILTER))
    assert_equal [7.0], @slept
  end

  test "a 5xx backs off 1, 2, 4, 8 seconds and then raises with the status and Notion's message" do
    @client.stubs(:post_json).returns([502, nil, { "code" => "bad_gateway", "message" => "upstream" }])
    error = assert_raises(Stacks::Notion::Error) { @client.query_database_filtered(DB, filter: FILTER) }
    assert_equal [1, 2, 4, 8], @slept
    assert_equal 502, error.status
    assert_equal "bad_gateway", error.code
    assert_match(/502/, error.message)
    assert_match(/upstream/, error.message)
  end

  test "a wait is never longer than 30 seconds" do
    @client.stubs(:post_json).returns([429, "600", {}]).then.returns([200, nil, {}])
    @client.query_database_filtered(DB, filter: FILTER)
    assert_equal [30], @slept
  end

  test "a 400 is not retried: the filter is wrong and will stay wrong" do
    @client.expects(:post_json).once.returns([400, nil, { "code" => "validation_error", "message" => "bad filter" }])
    error = assert_raises(Stacks::Notion::Error) { @client.query_database_filtered(DB, filter: FILTER) }
    assert_equal 400, error.status
    assert_empty @slept
  end

  test "a timeout is retried like a 5xx" do
    @client.stubs(:post_json).raises(Net::ReadTimeout).then.returns([200, nil, { "results" => [] }])
    assert_equal({ "results" => [] }, @client.query_database_filtered(DB, filter: FILTER))
    assert_equal [1], @slept
  end

  test "fetch_page returns the page, and a 404 as an answer, not an error" do
    @client.stubs(:get_json).with("/pages/abc").returns([200, nil, { "id" => "abc" }])
    assert_equal({ status: 200, body: { "id" => "abc" } }, @client.fetch_page("abc"))
    @client.stubs(:get_json).with("/pages/gone").returns([404, nil, { "code" => "object_not_found" }])
    assert_equal 404, @client.fetch_page("gone")[:status]
    assert_empty @slept
  end

  test "fetch_page raises on a 403 and retries a 429" do
    @client.stubs(:get_json).returns([403, nil, { "code" => "restricted_resource" }])
    assert_equal 403, assert_raises(Stacks::Notion::Error) { @client.fetch_page("abc") }.status
    @client.stubs(:get_json).returns([429, nil, {}]).then.returns([200, nil, { "id" => "abc" }])
    assert_equal 200, @client.fetch_page("abc")[:status]
    assert_equal [1], @slept
  end
end
```

- [ ] **Step 2: Run, expect failure:**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/stacks/notion/client_test.rb
```

- [ ] **Step 3: Implement in `lib/stacks/notion.rb`.** Below `filtered_parent_id`:

```ruby
  class Error < StandardError
    attr_reader :status, :code

    def initialize(message, status: nil, code: nil)
      super(message)
      @status = status
      @code = code
    end
  end

  RETRY_ATTEMPTS = 5
  MAX_RETRY_WAIT = 30 # seconds

  attr_writer :sleeper

  # Strips what changes on every read (icons, covers and file properties
  # carry hourly-expiring S3 URLs), so a stored page diffs clean against a
  # fresh one. File properties keep "name" and "type" so superpowers_pdf?
  # (array presence) still works. Returns the page title: the first fragment
  # of the title property.
  def self.normalize_page!(r)
    r.delete("icon")
    r.delete("cover")
    props = r["properties"]
    return "" unless props.is_a?(Hash)
    props.each_value do |prop|
      next unless prop.is_a?(Hash) && prop["type"] == "files"
      Array(prop["files"]).each { |f| f.delete("file") if f.is_a?(Hash) }
    end
    title = props.values.find { |v| v.is_a?(Hash) && v["type"] == "title" }
    fragments = title && title["title"]
    first = fragments.is_a?(Array) ? fragments.first : nil
    (first.is_a?(Hash) && first["plain_text"].is_a?(String) ? first["plain_text"] : nil) || ""
  end
```

In `sync_database`, replace lines 106-116 (the `page_title =` line through the files loop) with one line, leaving everything after `notion_id = r.dig("id")` as it is:

```ruby
        page_title = self.class.normalize_page!(r)
```

After `query_database_all` add:

```ruby
  # One page of a database query with a filter. Raises Stacks::Notion::Error
  # on anything but a 200, so a rejected filter is never read as "no rows".
  def query_database_filtered(database_id, filter:, sorts: nil, start_cursor: nil, page_size: 100)
    body = { page_size: page_size, filter: filter }
    body[:sorts] = sorts if sorts.present?
    body[:start_cursor] = start_cursor if start_cursor.present?
    _status, parsed = with_retry("query of database #{database_id}") { post_json("/databases/#{database_id}/query", body) }
    parsed
  end

  # One page by id. A 404 is an answer (the page is gone), not an error.
  def fetch_page(page_id)
    status, parsed = with_retry("fetch of page #{page_id}", allow: [404]) { get_json("/pages/#{page_id}") }
    { status: status, body: parsed }
  end
```

and at the bottom of the class:

```ruby
  private

  # Runs the block (which returns [status, retry_after, parsed]) until it
  # answers 200 or a status in `allow`. A 429 waits as long as Notion asks; a
  # 5xx or a timeout backs off 1, 2, 4, 8 seconds. Anything else raises now.
  def with_retry(what, allow: [])
    attempt = 0
    loop do
      attempt += 1
      status, retry_after, parsed =
        begin
          yield
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, EOFError => e
          [0, nil, { "message" => e.class.name }]
        end
      return [status, parsed] if status == 200 || allow.include?(status)

      if (status == 0 || status == 429 || status >= 500) && attempt < RETRY_ATTEMPTS
        wait = retry_after.to_f > 0 ? retry_after.to_f : 2**(attempt - 1)
        (@sleeper || ->(seconds) { sleep(seconds) }).call([wait, MAX_RETRY_WAIT].min)
        next
      end
      detail = parsed.is_a?(Hash) ? parsed : {}
      raise Error.new("Notion #{what} failed (#{status}): #{detail["message"]}", status: status, code: detail["code"])
    end
  end

  def post_json(path, body)
    uri = URI("#{self.class.base_uri}#{path}")
    req = Net::HTTP::Post.new(uri.path, @headers)
    req.body = body.to_json
    send_json(uri, req)
  end

  def get_json(path)
    uri = URI("#{self.class.base_uri}#{path}")
    send_json(uri, Net::HTTP::Get.new(uri.path, @headers))
  end

  def send_json(uri, req)
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    https.open_timeout = 10
    https.read_timeout = 60
    response = https.request(req)
    parsed = begin
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      {}
    end
    [response.code.to_i, response["Retry-After"], parsed]
  end
```

`private` goes after `sync_database`, the last public method. The test for a 30-second cap asserts `[30]`: `[600.0, 30].min` is `30`.

- [ ] **Step 4: Run the client tests and the whole Notion folder, expect 0 failures:**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/stacks/notion test/lib/tasks/twist_channel_access_rake_test.rb
```

- [ ] **Step 5: Commit.** `feat(notion): filtered query and page fetch with retry, and one place that strips volatile fields`

---

### Task 5: The filtered sync of one database

**Files:** Create `lib/stacks/notion/filtered_sync.rb`, `test/lib/stacks/notion/filtered_sync_test.rb`. Modify `app/models/system.rb`.

**Consumes:** `FILTERED_DATABASES`, `filtered_parent_id`, `normalize_page!`, `Error`, the wrappers' `project_ids_in` and `occurred_at_in`, the client contract (`query_database_filtered`).

**Produces:**
- `System#notion_filtered_sync_marks` (Hash, default `{}`).
- `Stacks::Notion::FilteredSync.new(client:, now: Time.zone.now)`.
- `FilteredSync.marks` → Hash; `FilteredSync.last_synced_at(key)` → Time or nil.
- `#window_for(key, mode: nil)` → `[since Time, mode Symbol]`, mode `:backfill` or `:incremental`.
- `#sync(key, dry_run: false, mode: nil)` → stats Hash with keys `database`, `mode`, `since`, `dry_run`, `calls`, `seen`, `created`, `updated`, `unchanged`, `skipped_without_project`, `trashed`, `truncated_relations`.
- `#upsert(row, key, stored, stats, dry_run:, keep_without_project: false)` (used again by Task 6).

- [ ] **Step 1: Write the failing tests** `test/lib/stacks/notion/filtered_sync_test.rb`:

```ruby
require 'test_helper'

class StacksNotionFilteredSyncTest < ActiveSupport::TestCase
  include NotionLogFixtures

  OBS = Stacks::Notion::FILTERED_DATABASES[:OBSERVATIONS][:id]
  PROB = Stacks::Notion::FILTERED_DATABASES[:PROBLEMS][:id]
  NOW = Time.utc(2026, 10, 13, 5, 0, 0)

  setup do
    System.delete_all
    System.create!(settings: {})
  end

  def sync_with(client, now: NOW)
    Stacks::Notion::FilteredSync.new(client: client, now: now)
  end

  def mark!(key, time)
    System.first.update!(notion_filtered_sync_marks: Stacks::Notion::FilteredSync.marks.merge(key.to_s => time.utc.iso8601))
  end

  test "the first run asks for 90 days of rows that have a project, newest edit first" do
    client = FakeNotion.new
    stats = sync_with(client).sync(:OBSERVATIONS)
    q = client.queries.first
    assert_equal OBS, q[:database_id]
    assert_equal({ and: [{ property: "Projects", relation: { is_not_empty: true } },
                         { timestamp: "last_edited_time", last_edited_time: { on_or_after: "2026-07-15T05:00:00Z" } }] }, q[:filter])
    assert_equal [{ timestamp: "last_edited_time", direction: "descending" }], q[:sorts]
    assert_equal "backfill", stats[:mode]
  end

  test "Problems are asked for by their Project property" do
    client = FakeNotion.new
    sync_with(client).sync(:PROBLEMS)
    assert_equal({ property: "Project", relation: { is_not_empty: true } }, client.queries.first[:filter][:and].first)
    assert_equal PROB, client.queries.first[:database_id]
  end

  test "a later run asks for every row edited since the last run less a day, and never under 3 days" do
    { 6.hours => "2026-10-10T05:00:00Z", 10.days => "2026-10-02T05:00:00Z", 200.days => "2026-07-15T05:00:00Z" }.each do |ago, since|
      mark!(:OBSERVATIONS, NOW - ago)
      client = FakeNotion.new
      stats = sync_with(client).sync(:OBSERVATIONS)
      assert_equal({ and: [{ timestamp: "last_edited_time", last_edited_time: { on_or_after: since } }] },
                   client.queries.first[:filter], "last run #{ago.inspect} ago")
      assert_equal "incremental", stats[:mode]
    end
  end

  test "rows land in notion_pages with their projects, their date and the queried database as parent" do
    at = Time.utc(2026, 10, 1, 12)
    row = observation_data(name: "Client unhappy", observed_at: at, project_ids: %w[p1 p2])
    row["parent"] = { "type" => "database_id", "database_id" => "some-other-spelling" }
    row["icon"] = { "type" => "emoji", "emoji" => "👀" }
    stats = sync_with(FakeNotion.new(pages: { OBS => [[row]] })).sync(:OBSERVATIONS)
    page = NotionPage.find_by!(notion_id: row["id"])
    assert_equal "database_id", page.notion_parent_type
    assert_equal Stacks::Notion.filtered_parent_id(:OBSERVATIONS), page.notion_parent_id
    assert_equal "Client unhappy", page.page_title
    assert_equal %w[p1 p2], page.project_ids
    assert_equal at, page.occurred_at
    assert_equal NOW, page.synced_at
    assert_not page.data.key?("icon"), "the icon is stripped as the whole-database sync strips it"
    assert_equal 1, stats[:created]
    assert_equal 1, stats[:seen]
    assert_equal [page.id], NotionPage.observations.pluck(:id)
  end

  test "it follows the cursor to the last page" do
    a, b, c = Array.new(3) { observation_data(project_ids: %w[p1]) }
    client = FakeNotion.new(pages: { OBS => [[a, b], [c]] })
    stats = sync_with(client).sync(:OBSERVATIONS)
    assert_equal [nil, "1"], client.queries.map { |q| q[:start_cursor] }
    assert_equal 2, stats[:calls]
    assert_equal 3, NotionPage.observations.count
  end

  test "it never deletes a row it did not see" do
    unseen = observation!(project_ids: %w[p1])
    lead = NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                              notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]), data: {})
    seen = observation_data(project_ids: %w[p1])
    sync_with(FakeNotion.new(pages: { OBS => [[seen]] })).sync(:OBSERVATIONS)
    assert NotionPage.exists?(unseen.id), "an unseen observation is kept"
    assert NotionPage.exists?(lead.id), "another database's row is untouched"
    assert_nil unseen.reload.deleted_at
    assert_equal 2, NotionPage.observations.count
  end

  test "a second identical run rewrites nothing and only moves synced_at" do
    row = observation_data(project_ids: %w[p1])
    sync_with(FakeNotion.new(pages: { OBS => [[row]] })).sync(:OBSERVATIONS)
    later = NOW + 1.day
    stats = sync_with(FakeNotion.new(pages: { OBS => [[row]] }), now: later).sync(:OBSERVATIONS)
    assert_equal 0, stats[:created]
    assert_equal 0, stats[:updated]
    assert_equal 1, stats[:unchanged]
    assert_equal later, NotionPage.find_by!(notion_id: row["id"]).synced_at
  end

  test "a row dismissed in Notion is updated in place" do
    id = SecureRandom.uuid
    sync_with(FakeNotion.new(pages: { OBS => [[observation_data(id: id, status: "New", project_ids: %w[p1])]] })).sync(:OBSERVATIONS)
    stats = sync_with(FakeNotion.new(pages: { OBS => [[observation_data(id: id, status: "Dismissed", project_ids: %w[p1])]] }),
                      now: NOW + 1.day).sync(:OBSERVATIONS)
    assert_equal 1, stats[:updated]
    assert NotionPage.find_by!(notion_id: id).as_observation.dismissed?
    assert_equal 1, NotionPage.observations.count
  end

  test "a stored row that lost its project is kept and leaves every tracker" do
    tracker, project_id = log_tracker!
    stored = observation!(project_ids: [project_id])
    mark!(:OBSERVATIONS, NOW - 1.day)
    edited = observation_data(id: stored.notion_id, project_ids: [])
    stats = sync_with(FakeNotion.new(pages: { OBS => [[edited]] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:updated]
    assert_equal [], stored.reload.project_ids
    assert_nil stored.deleted_at
    assert_empty NotionPage.where("project_ids && ARRAY[?]::varchar[]", tracker.notion_project_ids)
  end

  test "a row with no project that Stacks does not hold is not stored" do
    mark!(:OBSERVATIONS, NOW - 1.day)
    stats = sync_with(FakeNotion.new(pages: { OBS => [[observation_data(project_ids: [])]] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:skipped_without_project]
    assert_equal 0, NotionPage.observations.count
  end

  test "a row trashed in Stacks and then seen again comes back" do
    stored = observation!(project_ids: %w[p1])
    stored.destroy
    assert stored.reload.deleted?
    sync_with(FakeNotion.new(pages: { OBS => [[observation_data(id: stored.notion_id, project_ids: %w[p1])]] })).sync(:OBSERVATIONS)
    assert_not NotionPage.with_deleted.find(stored.id).deleted?
  end

  test "a row the query returns as archived is soft-deleted, and never created" do
    stored = observation!(project_ids: %w[p1])
    rows = [observation_data(id: stored.notion_id, project_ids: %w[p1], archived: true),
            observation_data(project_ids: %w[p1], archived: true)]
    stats = sync_with(FakeNotion.new(pages: { OBS => [rows] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:trashed]
    assert NotionPage.with_deleted.find(stored.id).deleted?
    assert_equal 0, NotionPage.observations.count
  end

  test "a relation Notion cut at 25 is stored as sent and counted" do
    row = observation_data(project_ids: %w[p1])
    row["properties"]["Projects"]["has_more"] = true
    stats = sync_with(FakeNotion.new(pages: { OBS => [[row]] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:truncated_relations]
    assert_equal %w[p1], NotionPage.find_by!(notion_id: row["id"]).project_ids
  end

  test "results that are not pages with an id are skipped" do
    rows = [nil, "x", {}, { "id" => nil }, observation_data(project_ids: %w[p1])]
    stats = sync_with(FakeNotion.new(pages: { OBS => [rows] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:seen]
    assert_equal 1, NotionPage.observations.count
  end

  test "the mark is the run's start time, written after the last page" do
    sync_with(FakeNotion.new(pages: { OBS => [[observation_data(project_ids: %w[p1])]] })).sync(:OBSERVATIONS)
    assert_equal NOW, Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
    assert_nil Stacks::Notion::FilteredSync.last_synced_at(:PROBLEMS), "each database has its own mark"
  end

  test "a run that fails on a later page keeps what it stored and writes no mark" do
    a = observation_data(project_ids: %w[p1])
    client = FakeNotion.new(pages: { OBS => [[a], [observation_data(project_ids: %w[p1])]] }, fail_on_page: 1)
    assert_raises(Stacks::Notion::Error) { sync_with(client).sync(:OBSERVATIONS) }
    assert NotionPage.exists?(notion_id: a["id"])
    assert_nil Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
  end

  test "a dry run writes nothing and counts what it would do" do
    stored = observation!(status: "New", project_ids: %w[p1], synced_at: NOW - 2.days)
    rows = [observation_data(id: stored.notion_id, status: "Dismissed", project_ids: %w[p1]),
            observation_data(project_ids: %w[p1]), observation_data(project_ids: %w[p2])]
    stats = sync_with(FakeNotion.new(pages: { OBS => [rows] })).sync(:OBSERVATIONS, dry_run: true)
    assert_equal({ created: 2, updated: 1, seen: 3 }, stats.slice(:created, :updated, :seen))
    assert stats[:dry_run]
    assert_equal 1, NotionPage.observations.count
    assert_equal "New", stored.reload.as_observation.status
    assert_equal NOW - 2.days, stored.synced_at
    assert_nil Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
  end

  test "a dry run can be made in the later runs' shape before there is a mark" do
    client = FakeNotion.new
    stats = sync_with(client).sync(:OBSERVATIONS, dry_run: true, mode: :incremental)
    assert_equal({ and: [{ timestamp: "last_edited_time", last_edited_time: { on_or_after: "2026-10-10T05:00:00Z" } }] },
                 client.queries.first[:filter])
    assert_equal "incremental", stats[:mode]
  end

  test "a mark that cannot be read counts as no mark" do
    System.first.update!(notion_filtered_sync_marks: { "OBSERVATIONS" => "garbage" })
    assert_nil Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
    assert_equal :backfill, sync_with(FakeNotion.new).window_for(:OBSERVATIONS).last
  end
end
```

- [ ] **Step 2: Run, expect failure:**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/stacks/notion/filtered_sync_test.rb
```

- [ ] **Step 3: `app/models/system.rb`.** Inside `store_attributes :settings`, after `runn_synced_at` (line 26):

```ruby
    # When each filtered Notion database (Stacks::Notion::FILTERED_DATABASES)
    # last synced to the end: {"OBSERVATIONS" => iso8601, "PROBLEMS" => iso8601}.
    # The next run reads from here less an overlap. Read via System.first.
    notion_filtered_sync_marks Hash, default: {}
```

- [ ] **Step 4: `lib/stacks/notion/filtered_sync.rb`.**

```ruby
# Syncs part of a large Notion database into notion_pages: the rows edited in
# a window, upserted one by one. It NEVER deletes a row it did not see (the
# whole-database sync, Stacks::Notion#sync_database, does, which is why these
# databases must never go through it).
#
# The first run reads 90 days of rows that have a project. Every later run
# reads every row edited since the last run, stores a new row only when it has
# a project, and updates a row only when Stacks already holds it. That second
# rule is how a row whose project was removed leaves the log.
class Stacks::Notion::FilteredSync
  FIRST_RUN_WINDOW = 90.days
  MIN_WINDOW = 3.days
  OVERLAP = 1.day
  MAX_CALLS = 500 # a runaway cursor stops here: 50,000 rows in one run is not real
  SORTS = [{ timestamp: "last_edited_time", direction: "descending" }].freeze
  WRAPPERS = { OBSERVATIONS: Stacks::Notion::Observation, PROBLEMS: Stacks::Notion::Problem }.freeze

  def self.marks
    raw = System.first&.notion_filtered_sync_marks
    raw.is_a?(Hash) ? raw : {}
  end

  # The start time of the last run of this database that reached the end.
  def self.last_synced_at(key)
    Stacks::Notion::Props.parse_time(marks[key.to_s])
  end

  def initialize(client:, now: Time.zone.now)
    @client = client
    @now = now
  end

  # [since, mode]. mode is forced only by a dry run that wants to try the
  # later runs' query before there is a mark.
  def window_for(key, mode: nil)
    mark = self.class.last_synced_at(key)
    floor = @now - FIRST_RUN_WINDOW
    return [floor, :backfill] if mode == :backfill || (mode.nil? && mark.nil?)
    return [@now - MIN_WINDOW, :incremental] if mark.nil?
    [[[mark - OVERLAP, @now - MIN_WINDOW].min, floor].max, :incremental]
  end

  def sync(key, dry_run: false, mode: nil)
    config = Stacks::Notion::FILTERED_DATABASES.fetch(key)
    since, mode = window_for(key, mode: mode)
    stats = { database: key.to_s, mode: mode.to_s, since: since.utc.iso8601, dry_run: dry_run, calls: 0, seen: 0,
              created: 0, updated: 0, unchanged: 0, skipped_without_project: 0, trashed: 0, truncated_relations: 0 }
    cursor = nil
    loop do
      raise Stacks::Notion::Error.new("Notion sync of #{key} did not end after #{MAX_CALLS} calls") if stats[:calls] >= MAX_CALLS
      response = @client.query_database_filtered(config[:id], filter: filter_for(config, since, mode), sorts: SORTS, start_cursor: cursor)
      stats[:calls] += 1
      results = response.is_a?(Hash) && response["results"].is_a?(Array) ? response["results"] : []
      upsert_all(results.select { |r| r.is_a?(Hash) && r["id"].is_a?(String) && r["id"].present? }, key, stats, dry_run)
      cursor = response.is_a?(Hash) ? response["next_cursor"] : nil
      break if cursor.blank?
    end
    write_mark(key) unless dry_run
    stats
  end

  # Stores one row. `stored` is the NotionPage Stacks holds for it (deleted or
  # not), or nil. Never deletes anything but this row, and only when Notion
  # says this row is in the trash.
  def upsert(r, key, stored, stats, dry_run:, keep_without_project: false)
    config = Stacks::Notion::FILTERED_DATABASES.fetch(key)
    wrapper = WRAPPERS.fetch(key)

    if r["archived"] == true || r["in_trash"] == true
      return if stored.nil? || stored.deleted?
      stats[:trashed] += 1
      stored.destroy unless dry_run
      return
    end

    project_ids = wrapper.project_ids_in(r)
    stats[:truncated_relations] += 1 if Stacks::Notion::Props.relation_truncated?(r, config[:project_property])
    if stored.nil? && project_ids.empty? && !keep_without_project
      stats[:skipped_without_project] += 1
      return
    end

    parent_id = Stacks::Notion.filtered_parent_id(key)
    title = Stacks::Notion.normalize_page!(r)
    attrs = { notion_parent_type: "database_id", notion_parent_id: parent_id, data: r, page_title: title,
              project_ids: project_ids, occurred_at: wrapper.occurred_at_in(r) || @now, synced_at: @now }

    if stored.nil?
      stats[:created] += 1
      NotionPage.create!(attrs.merge(notion_id: r["id"])) unless dry_run
    elsif stored.deleted? || stored.project_ids != project_ids || stored.notion_parent_id != parent_id ||
          Hashdiff.diff(r, stored.data).any?
      stats[:updated] += 1
      return if dry_run
      stored.recover! if stored.deleted?
      stored.update!(attrs)
    else
      stats[:unchanged] += 1
      @unchanged_ids << stored.id unless dry_run
    end
  end

  private

  def filter_for(config, since, mode)
    clauses = []
    clauses << { property: config[:project_property], relation: { is_not_empty: true } } if mode == :backfill
    clauses << { timestamp: "last_edited_time", last_edited_time: { on_or_after: since.utc.iso8601 } }
    { and: clauses }
  end

  def upsert_all(results, key, stats, dry_run)
    stored = NotionPage.with_deleted.where(notion_id: results.map { |r| r["id"] }).index_by(&:notion_id)
    @unchanged_ids = []
    results.each do |r|
      stats[:seen] += 1
      upsert(r, key, stored[r["id"]], stats, dry_run: dry_run)
    end
    # Unchanged rows are not rewritten; one statement records that they were seen.
    NotionPage.where(id: @unchanged_ids).update_all(synced_at: @now) if @unchanged_ids.any?
  end

  def write_mark(key)
    system = System.first || System.create!(settings: {})
    system.update!(notion_filtered_sync_marks: self.class.marks.merge(key.to_s => @now.utc.iso8601))
  end
end
```

Notes for the implementer:
- `upsert` is public because Task 6 calls it outside `upsert_all`; it relies on `@unchanged_ids` being an Array, so Task 6 sets it before calling.
- `stored.recover!` is what `sync_database` already calls (`lib/stacks/notion.rb:130`).
- The first-run test expects `2026-07-15T05:00:00Z`: 90 days before `2026-10-13T05:00:00Z`.

- [ ] **Step 5: Run, expect 0 failures** (same command as Step 2).
- [ ] **Step 6: Commit.** `feat(notion): filtered sync that upserts a window of a large database and never deletes`

---

### Task 6: By-id passes and the whole run

**Files:** Modify `lib/stacks/notion/filtered_sync.rb`, `test/lib/stacks/notion/filtered_sync_test.rb`.

**Consumes:** Task 5's `sync` and `upsert`; the client's `fetch_page`.

**Produces:**
- `#fetch_missing_problems(dry_run: false)` → `{ named:, missing:, fetched:, stored:, gone:, foreign:, over_limit: }`.
- `#recheck(dry_run: false)` → `{ candidates:, checked:, gone:, trashed:, updated:, unchanged: }`.
- `#run_all(dry_run: false, mode: nil)` → `{ observations:, problems:, missing_problems:, recheck: }`, or `{ skipped: "another run holds the lock" }`.
- `FilteredSync.run!(dry_run: false, mode: nil, client: Stacks::Notion.new, now: Time.zone.now)` → the same Hash. This is the only entry point the rake tasks use, and the one rake tests stub.
- Constants `MISSING_PROBLEM_LIMIT = 100`, `RECHECK_LIMIT = 200`, `RECHECK_WINDOW = 90.days`, `ADVISORY_LOCK_KEY = 84_217_297` (the keys in use are 84_217_295 at `lib/stacks/forecast.rb:14` and 84_217_296 at `lib/stacks/runn.rb:44`).

- [ ] **Step 1: Add the failing tests** to `test/lib/stacks/notion/filtered_sync_test.rb`:

```ruby
  test "a problem an observation names is fetched by id when Stacks does not hold it" do
    problem = problem_data(name: "Timeline slipping", project_ids: [])
    observation!(project_ids: %w[p1], problem_ids: [problem["id"]])
    client = FakeNotion.new(by_id: { problem["id"] => problem })
    stats = sync_with(client).fetch_missing_problems
    assert_equal [problem["id"]], client.fetched
    assert_equal({ named: 1, missing: 1, fetched: 1, stored: 1, gone: 0, foreign: 0, over_limit: 0 }, stats)
    page = NotionPage.problems.find_by!(notion_id: problem["id"])
    assert_equal [], page.project_ids, "it is under no tracker; it is here so the observation can be judged"
    assert_equal "Timeline slipping", page.as_problem.title
  end

  test "a problem Stacks already holds, deleted or not, is not fetched again" do
    held = problem!(project_ids: %w[p1])
    trashed = problem!(project_ids: %w[p1])
    trashed.destroy
    observation!(project_ids: %w[p1], problem_ids: [held.notion_id, trashed.notion_id])
    client = FakeNotion.new
    assert_equal 0, sync_with(client).fetch_missing_problems[:missing]
    assert_empty client.fetched
  end

  test "problems named only by rows with no project, or by rows older than 90 days, are not fetched" do
    observation!(project_ids: [], problem_ids: [SecureRandom.uuid])
    observation!(project_ids: %w[p1], problem_ids: [SecureRandom.uuid], observed_at: NOW - 91.days)
    client = FakeNotion.new
    assert_equal 0, sync_with(client).fetch_missing_problems[:named]
    assert_empty client.fetched
  end

  test "a named page from another database is not stored, and one Notion no longer has is skipped" do
    foreign = problem_data
    foreign["parent"]["database_id"] = SecureRandom.uuid
    gone = SecureRandom.uuid
    observation!(project_ids: %w[p1], problem_ids: [foreign["id"], gone])
    stats = sync_with(FakeNotion.new(by_id: { foreign["id"] => foreign })).fetch_missing_problems
    assert_equal({ foreign: 1, gone: 1, stored: 0 }, stats.slice(:foreign, :gone, :stored))
    assert_equal 0, NotionPage.problems.count
  end

  test "at most 100 problems are fetched in a run, and the rest are counted" do
    ids = Array.new(103) { SecureRandom.uuid }
    observation!(project_ids: %w[p1], problem_ids: ids.first(25))
    ids.drop(25).each_slice(25) { |slice| observation!(project_ids: %w[p1], problem_ids: slice) }
    client = FakeNotion.new
    stats = sync_with(client).fetch_missing_problems
    assert_equal 100, client.fetched.size
    assert_equal 3, stats[:over_limit]
  end

  test "recheck soft-deletes a row Notion has trashed, and one Notion no longer has" do
    trashed = observation!(project_ids: %w[p1], synced_at: NOW - 3.days)
    gone = problem!(project_ids: %w[p1], synced_at: NOW - 2.days)
    live = observation!(project_ids: %w[p1], synced_at: NOW - 1.day)
    client = FakeNotion.new(by_id: {
      trashed.notion_id => observation_data(id: trashed.notion_id, project_ids: %w[p1], archived: true),
      live.notion_id => live.data,
    })
    stats = sync_with(client).recheck
    assert_equal [trashed.notion_id, gone.notion_id, live.notion_id], client.fetched, "least recently checked first"
    assert_equal({ candidates: 3, checked: 3, gone: 1, trashed: 1, updated: 0, unchanged: 1 }, stats)
    assert NotionPage.with_deleted.find(trashed.id).deleted?
    assert NotionPage.with_deleted.find(gone.id).deleted?
    assert_nil live.reload.deleted_at
    assert_equal NOW, live.synced_at
  end

  test "recheck picks up a change the queries missed, and a row that lost its project stays stored" do
    stored = observation!(status: "New", project_ids: %w[p1], synced_at: NOW - 1.day)
    client = FakeNotion.new(by_id: { stored.notion_id => observation_data(id: stored.notion_id, status: "Dismissed", project_ids: []) })
    stats = sync_with(client).recheck
    assert_equal 1, stats[:updated]
    assert_equal [], stored.reload.project_ids
    assert stored.as_observation.dismissed?
    assert_nil stored.deleted_at
  end

  test "recheck leaves alone a row this run already saw, an old observation, and other databases" do
    observation!(project_ids: %w[p1], synced_at: NOW)
    observation!(project_ids: %w[p1], synced_at: NOW - 5.days, observed_at: NOW - 91.days)
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]), data: {})
    old_problem = problem!(project_ids: %w[p1], synced_at: NOW - 5.days, last_seen: NOW - 200.days)
    client = FakeNotion.new(by_id: { old_problem.notion_id => old_problem.data })
    sync_with(client).recheck
    assert_equal [old_problem.notion_id], client.fetched, "every stored problem is rechecked, whatever its age"
  end

  test "recheck takes at most 200 rows" do
    rows = Array.new(203) { |i| observation!(project_ids: %w[p1], synced_at: NOW - (i + 1).hours) }
    client = FakeNotion.new(by_id: rows.to_h { |r| [r.notion_id, r.data] })
    stats = sync_with(client).recheck
    assert_equal 200, client.fetched.size
    assert_equal 203, stats[:candidates]
    assert_equal 200, stats[:checked]
    assert_equal rows.last.notion_id, client.fetched.first
  end

  test "a dry run makes no by-id call and says how many it would make" do
    observation!(project_ids: %w[p1], problem_ids: [SecureRandom.uuid], synced_at: NOW - 1.day)
    client = FakeNotion.new
    sync = sync_with(client)
    assert_equal({ named: 1, missing: 1, fetched: 0 }, sync.fetch_missing_problems(dry_run: true).slice(:named, :missing, :fetched))
    assert_equal({ candidates: 1, checked: 0 }, sync.recheck(dry_run: true).slice(:candidates, :checked))
    assert_empty client.fetched
  end

  test "run_all syncs observations, then problems, then fetches and rechecks" do
    problem = problem_data(project_ids: [])
    obs = observation_data(project_ids: %w[p1], problem_ids: [problem["id"]])
    client = FakeNotion.new(pages: { OBS => [[obs]], PROB => [[problem_data(project_ids: %w[p1])]] },
                            by_id: { problem["id"] => problem })
    out = sync_with(client).run_all
    assert_equal [OBS, PROB], client.queries.map { |q| q[:database_id] }
    assert_equal 1, out[:observations][:created]
    assert_equal 1, out[:problems][:created]
    assert_equal 1, out[:missing_problems][:stored]
    assert_equal 0, out[:recheck][:candidates], "everything was seen by this run"
    assert_equal 2, NotionPage.problems.count
  end

  test "a dry run of everything counts problems named by rows it has not stored" do
    problem_id = SecureRandom.uuid
    client = FakeNotion.new(pages: { OBS => [[observation_data(project_ids: %w[p1], problem_ids: [problem_id])]] })
    out = sync_with(client).run_all(dry_run: true)
    assert_equal 1, out[:missing_problems][:missing]
    assert_equal 0, NotionPage.count
    assert_empty client.fetched
  end

  test "run! does nothing while another run holds the lock" do
    other = ActiveRecord::Base.connection_pool.checkout
    begin
      other.execute("SELECT pg_advisory_lock(#{Stacks::Notion::FilteredSync::ADVISORY_LOCK_KEY})")
      client = FakeNotion.new
      out = Stacks::Notion::FilteredSync.run!(client: client, now: NOW)
      assert_equal({ skipped: "another run holds the lock" }, out)
      assert_empty client.queries
    ensure
      other.execute("SELECT pg_advisory_unlock(#{Stacks::Notion::FilteredSync::ADVISORY_LOCK_KEY})")
      ActiveRecord::Base.connection_pool.checkin(other)
    end
  end

  test "run! releases the lock when the sync raises" do
    client = FakeNotion.new(fail_on_page: 0)
    assert_raises(Stacks::Notion::Error) { Stacks::Notion::FilteredSync.run!(client: client, now: NOW) }
    assert_not Stacks::Notion::FilteredSync.run!(client: FakeNotion.new, now: NOW).key?(:skipped),
               "a run after a failed one is not skipped"
  end
```

- [ ] **Step 2: Run, expect the new tests to fail:**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/stacks/notion/filtered_sync_test.rb
```

- [ ] **Step 3: Implement.** In `lib/stacks/notion/filtered_sync.rb` add the constants under `MAX_CALLS`:

```ruby
  MISSING_PROBLEM_LIMIT = 100 # page fetches a run, for problems an observation names
  RECHECK_LIMIT = 200         # page fetches a run, to notice rows trashed in Notion
  RECHECK_WINDOW = 90.days
  ADVISORY_LOCK_KEY = 84_217_297
```

the class method under `last_synced_at`:

```ruby
  # The one entry point for the rake tasks. Two runs at once would race on the
  # unique notion_id index, so the second does nothing.
  def self.run!(dry_run: false, mode: nil, client: Stacks::Notion.new, now: Time.zone.now)
    conn = ActiveRecord::Base.connection
    return { skipped: "another run holds the lock" } unless conn.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    begin
      new(client: client, now: now).run_all(dry_run: dry_run, mode: mode)
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
    end
  end
```

In `initialize` add `@unchanged_ids = []` and `@named_problem_ids = []`. Keep the reset at the top of `upsert_all`: each batch starts empty. In `upsert`, directly after the `skipped_without_project` guard, remember the problems an observation with a project names (so a dry run, which stores nothing, can still count them):

```ruby
    @named_problem_ids.concat(Stacks::Notion::Observation.problem_ids_in(r)) if key == :OBSERVATIONS && project_ids.any?
```

and add the public methods after `sync`:

```ruby
  def run_all(dry_run: false, mode: nil)
    {
      observations: sync(:OBSERVATIONS, dry_run: dry_run, mode: mode),
      problems: sync(:PROBLEMS, dry_run: dry_run, mode: mode),
      missing_problems: fetch_missing_problems(dry_run: dry_run),
      recheck: recheck(dry_run: dry_run),
    }
  end

  # "Escalated" needs the Problem an observation was folded into, and a
  # Problem has a Project only when all its observations agree, so the queries
  # above miss some. Fetch those by id. They are stored under no project.
  def fetch_missing_problems(dry_run: false)
    named = (@named_problem_ids + stored_named_problem_ids).uniq
    missing = named - NotionPage.with_deleted.where(notion_id: named).pluck(:notion_id)
    stats = { named: named.size, missing: missing.size, fetched: 0, stored: 0, gone: 0, foreign: 0,
              over_limit: [missing.size - MISSING_PROBLEM_LIMIT, 0].max }
    return stats if dry_run

    problems_db = Stacks::Notion::FILTERED_DATABASES[:PROBLEMS][:id]
    counts = Hash.new(0)
    @unchanged_ids = []
    missing.first(MISSING_PROBLEM_LIMIT).each do |id|
      result = @client.fetch_page(id)
      stats[:fetched] += 1
      body = result[:body]
      if result[:status] == 404 || !body.is_a?(Hash) || !body["id"].is_a?(String)
        stats[:gone] += 1
      elsif body.dig("parent", "database_id").to_s.delete("-") != problems_db
        stats[:foreign] += 1
      else
        upsert(body, :PROBLEMS, nil, counts, dry_run: false, keep_without_project: true)
      end
    end
    stats[:stored] = counts[:created]
    stats
  end

  # A database query never returns a trashed page, so trash is noticed here:
  # each run asks Notion, by id, about the rows it has gone longest without
  # seeing. Every stored Problem is in scope; Observations for 90 days.
  def recheck(dry_run: false)
    observations = Stacks::Notion.filtered_parent_id(:OBSERVATIONS)
    problems = Stacks::Notion.filtered_parent_id(:PROBLEMS)
    scope = NotionPage
      .where(notion_parent_type: "database_id", notion_parent_id: [observations, problems])
      .where("notion_pages.synced_at IS NULL OR notion_pages.synced_at < ?", @now)
      .where("notion_pages.notion_parent_id = ? OR notion_pages.occurred_at >= ?", problems, @now - RECHECK_WINDOW)
    stats = { candidates: scope.count, checked: 0, gone: 0, trashed: 0, updated: 0, unchanged: 0 }
    return stats if dry_run

    counts = Hash.new(0)
    @unchanged_ids = []
    scope.order(Arel.sql("notion_pages.synced_at ASC NULLS FIRST, notion_pages.id ASC")).limit(RECHECK_LIMIT).each do |page|
      result = @client.fetch_page(page.notion_id)
      stats[:checked] += 1
      body = result[:body]
      if result[:status] == 404
        # Trusted because this run has just queried the same database: the
        # integration can read it, so a missing page is a deleted page.
        page.destroy
        stats[:gone] += 1
      elsif body.is_a?(Hash) && body["id"] == page.notion_id
        key = page.notion_parent_id == observations ? :OBSERVATIONS : :PROBLEMS
        upsert(body, key, page, counts, dry_run: false, keep_without_project: true)
      end
    end
    NotionPage.where(id: @unchanged_ids).update_all(synced_at: @now) if @unchanged_ids.any?
    stats.merge(trashed: counts[:trashed], updated: counts[:updated], unchanged: counts[:unchanged])
  end
```

and the private helper:

```ruby
  # Problem ids named by stored observations that have a project. Read as
  # jsonb paths, so the rows themselves are not loaded.
  def stored_named_problem_ids
    NotionPage.observations
      .where("cardinality(notion_pages.project_ids) > 0")
      .where("notion_pages.occurred_at >= ?", @now - RECHECK_WINDOW)
      .pluck(Arel.sql("notion_pages.data #> '{properties,Problems,relation}'"))
      .flat_map do |relation|
        relation = (JSON.parse(relation) rescue nil) if relation.is_a?(String)
        relation.is_a?(Array) ? relation.filter_map { |r| r["id"] if r.is_a?(Hash) && r["id"].is_a?(String) } : []
      end
  end
```

Notes for the implementer:
- `upsert` counts into whatever Hash it is given; the by-id passes give it `Hash.new(0)` and copy the counts they report. `upsert` reads `stats[:trashed]`, `[:created]`, `[:updated]`, `[:unchanged]`, `[:truncated_relations]`, `[:skipped_without_project]`, all of which a `Hash.new(0)` answers.
- In `run_all` the recheck finds nothing on a first run: every row was stamped `synced_at = @now` moments earlier and the scope asks for `synced_at < @now`.
- A named problem that Notion no longer has is asked about again every night (it is never stored). That is at most 100 calls and is accepted.

- [ ] **Step 4: Run, expect 0 failures** (same command as Step 2).
- [ ] **Step 5: Commit.** `feat(notion): fetch named problems and recheck stored rows by id, behind one locked run`

---

### Task 7: Rake tasks, and the ride on the daily Notion sync

**Files:** Modify `lib/tasks/stacks.rake`, `test/lib/tasks/twist_channel_access_rake_test.rb`. Create `test/lib/tasks/sync_notion_log_rake_test.rb`.

**Consumes:** `Stacks::Notion::FilteredSync.run!` and `.marks`.

**Produces:** `rake stacks:sync_notion_log` (a `SystemTask` named `stacks:sync_notion_log`); `rake "stacks:preview_notion_log_sync[mode]"` (prints JSON, writes nothing, records no `SystemTask`; `mode` is blank, `backfill` or `incremental`); `stacks:sync_notion` invokes `stacks:sync_notion_log` after the Twist check once a first run has been made by hand.

- [ ] **Step 1: Protect the existing rake test first.** `test/lib/tasks/twist_channel_access_rake_test.rb:15` stubs `Stacks::Notion.new` with a stand-in that only answers `sync_database`. Once `sync_notion` rides the new task, an unstubbed run there would fail and `mark_as_error` would post to the real Twist thread. In its `setup` block add:

```ruby
    Rake::Task['stacks:sync_notion_log'].reenable
    Stacks::Notion::FilteredSync.stubs(:marks).returns({})
    Stacks::Notion::FilteredSync.stubs(:run!).returns({})
```

- [ ] **Step 2: Write the failing tests** `test/lib/tasks/sync_notion_log_rake_test.rb`, built as `test/lib/tasks/twist_channel_access_rake_test.rb` is:

```ruby
require 'test_helper'
require 'rake'

# The filtered Notion sync for the project log, and its ride on the daily
# Notion sync. Nothing here may reach Notion or Twist: the sync, the Notion
# client, the Twist check and the error notifier are all stubbed.
class SyncNotionLogRakeTest < ActiveSupport::TestCase
  STATS = { observations: { created: 3 }, problems: { created: 1 } }.freeze

  setup do
    Stacks::Application.load_tasks if Rake::Task.tasks.empty?
    %w[stacks:sync_notion stacks:sync_notion_log stacks:preview_notion_log_sync stacks:sync_twist_channel_access].each do |name|
      Rake::Task[name].reenable
    end
    Stacks::Notion.stubs(:new).returns(stub(sync_database: nil))
    ProjectTracker.stubs(:sync_twist_channel_access!).returns({ checked: 0, accessible: 0, inaccessible: 0 })
    Stacks::TaskBuilder.stubs(:clear_cache!)
  end

  def last_task(name)
    SystemTask.where(name: name).last
  end

  test "sync_notion_log records a successful SystemTask on a clean run" do
    Stacks::Notion::FilteredSync.expects(:run!).once.with.returns(STATS)
    Stacks::Notifications.expects(:report_exception).never
    assert_difference -> { SystemTask.where(name: "stacks:sync_notion_log").count }, 1 do
      Rake::Task["stacks:sync_notion_log"].invoke
    end
    task = last_task("stacks:sync_notion_log")
    assert task.settled_at.present?
    assert_nil task.notification_id
  end

  test "sync_notion_log records an error when the sync raises" do
    error = Stacks::Notion::Error.new("Notion query of database x failed (400): bad filter", status: 400)
    Stacks::Notion::FilteredSync.stubs(:run!).raises(error)
    Stacks::Notifications.expects(:report_exception).once.with(error).returns(stub(record: nil))
    Rake::Task["stacks:sync_notion_log"].invoke
    assert last_task("stacks:sync_notion_log").settled_at.present?
  end

  test "a run skipped because another holds the lock is a success, not an error" do
    Stacks::Notion::FilteredSync.stubs(:run!).returns({ skipped: "another run holds the lock" })
    Stacks::Notifications.expects(:report_exception).never
    Rake::Task["stacks:sync_notion_log"].invoke
    assert_nil last_task("stacks:sync_notion_log").notification_id
  end

  test "the preview is a dry run, prints the counts and records no SystemTask" do
    Stacks::Notion::FilteredSync.expects(:run!).once.with(dry_run: true, mode: nil).returns(STATS)
    Stacks::Notifications.expects(:report_exception).never
    out, = capture_io do
      assert_no_difference -> { SystemTask.count } do
        Rake::Task["stacks:preview_notion_log_sync"].invoke
      end
    end
    assert_equal 3, JSON.parse(out).dig("observations", "created")
  end

  test "the preview can be made in the later runs' shape, and refuses any other word" do
    Stacks::Notion::FilteredSync.expects(:run!).once.with(dry_run: true, mode: :incremental).returns(STATS)
    capture_io { Rake::Task["stacks:preview_notion_log_sync"].invoke("incremental") }
    Rake::Task["stacks:preview_notion_log_sync"].reenable
    Stacks::Notion::FilteredSync.expects(:run!).never
    assert_raises(ArgumentError) { capture_io { Rake::Task["stacks:preview_notion_log_sync"].invoke("everything") } }
  end

  test "the daily Notion sync does not start the log sync until a first run has been made by hand" do
    Stacks::Notion::FilteredSync.stubs(:marks).returns({})
    Stacks::Notion::FilteredSync.expects(:run!).never
    Stacks::Notifications.expects(:report_exception).never
    Rake::Task["stacks:sync_notion"].invoke
    assert_nil last_task("stacks:sync_notion_log")
    assert last_task("stacks:sync_twist_channel_access").settled_at.present?
  end

  test "once there is a mark, the daily Notion sync runs the log sync after the Twist check" do
    Stacks::Notion::FilteredSync.stubs(:marks).returns({ "OBSERVATIONS" => "2026-10-12T05:00:00Z" })
    seq = sequence("after the Notion sync")
    ProjectTracker.expects(:sync_twist_channel_access!).once.in_sequence(seq).returns({})
    Stacks::Notion::FilteredSync.expects(:run!).once.in_sequence(seq).returns(STATS)
    Stacks::Notifications.expects(:report_exception).never
    Rake::Task["stacks:sync_notion"].invoke
    assert last_task("stacks:sync_notion_log").settled_at.present?
  end

  test "the log sync still runs when the Twist check fails, and its own failure is its own task's" do
    Stacks::Notion::FilteredSync.stubs(:marks).returns({ "OBSERVATIONS" => "2026-10-12T05:00:00Z" })
    twist_error = Stacks::Twist::Error.new("Twist channels/get failed (500)")
    ProjectTracker.stubs(:sync_twist_channel_access!).raises(twist_error)
    notion_error = Stacks::Notion::Error.new("Notion query failed (502)", status: 502)
    Stacks::Notion::FilteredSync.expects(:run!).once.raises(notion_error)
    Stacks::Notifications.expects(:report_exception).with(twist_error).once.returns(stub(record: nil))
    Stacks::Notifications.expects(:report_exception).with(notion_error).once.returns(stub(record: nil))
    Rake::Task["stacks:sync_notion"].invoke
    assert_nil last_task("stacks:sync_notion").notification_id, "the whole-database sync itself succeeded"
    assert last_task("stacks:sync_notion_log").settled_at.present?
  end

  test "reading the mark cannot break the daily Notion sync" do
    Stacks::Notion::FilteredSync.stubs(:marks).raises(RuntimeError, "settings unreadable")
    Stacks::Notion::FilteredSync.expects(:run!).never
    Stacks::Notifications.expects(:report_exception).never
    Rake::Task["stacks:sync_notion"].invoke
    assert last_task("stacks:sync_notion").settled_at.present?
  end
end
```

- [ ] **Step 3: Run, expect failure** (`Don't know how to build task 'stacks:sync_notion_log'`):

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/tasks/sync_notion_log_rake_test.rb
```

- [ ] **Step 4: Implement in `lib/tasks/stacks.rake`.** Replace lines 436-437 (the comment and the Twist `invoke`) with:

```ruby
    # Both ride on this daily task so no scheduler entry is needed. Each
    # records its own SystemTask and rescues its own errors.
    Rake::Task["stacks:sync_twist_channel_access"].invoke
    # The project log's sync joins the ride only once a first run has been
    # made by hand (rake stacks:sync_notion_log, after reading the preview),
    # so the first, 90-day run is never a surprise at night.
    log_sync_started = begin
      Stacks::Notion::FilteredSync.marks.any?
    rescue => e
      Rails.logger.error("[sync_notion] could not read the log sync's mark: #{e.class}: #{e.message}")
      false
    end
    Rake::Task["stacks:sync_notion_log"].invoke if log_sync_started
```

(the task's closing `end` on line 438 stays) and after the `sync_twist_channel_access` task (line 450) add:

```ruby
  # Stacksbot's Observations and Problems, for the project log
  # (/admin/project_trackers/:id/log). Reads the rows edited since the last
  # run, upserts them into notion_pages and never deletes a row it did not
  # see. NOT the whole-database sync above, which must never be pointed at
  # these two databases.
  desc "Sync Stacksbot's Observations and Problems from Notion for the project log"
  task :sync_notion_log => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_notion_log")
    begin
      stats = Stacks::Notion::FilteredSync.run!
      Rails.logger.info("[sync_notion_log] #{stats.to_json}")
      system_task.mark_as_success
    rescue => e
      system_task.mark_as_error(e)
    end
  end

  # Runs the same queries and prints what a real run would create, update and
  # fetch. Writes nothing and records no SystemTask.
  #   rake stacks:preview_notion_log_sync                  the next real run
  #   rake "stacks:preview_notion_log_sync[incremental]"   the later runs' query, before there is a mark
  desc "Count what stacks:sync_notion_log would pull, without writing ([backfill] or [incremental] to force a shape)"
  task :preview_notion_log_sync, [:mode] => :environment do |_t, args|
    mode = args[:mode].presence
    raise ArgumentError, "mode must be backfill or incremental" unless [nil, "backfill", "incremental"].include?(mode)
    stats = Stacks::Notion::FilteredSync.run!(dry_run: true, mode: mode&.to_sym)
    puts JSON.pretty_generate(stats)
  end
```

The clean-run test expects `run!` with no arguments (`.with`), so the task must call `Stacks::Notion::FilteredSync.run!` bare.

- [ ] **Step 5: Run both rake test files, expect 0 failures:**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/tasks/sync_notion_log_rake_test.rb test/lib/tasks/twist_channel_access_rake_test.rb
```

- [ ] **Step 6: Commit.** `feat(rake): stacks:sync_notion_log and its preview, riding the daily Notion sync after a first manual run`

---

### Task 8: A tracker finds its rows

**Files:** Modify `app/models/project_tracker.rb`. Create `test/models/project_tracker_log_test.rb`.

**Consumes:** `NotionPage.observations`, `.problems`, `project_ids`.

**Produces:** `ProjectTracker#observations` and `#problems`, each an `ActiveRecord::Relation` of `NotionPage` (callers map `&:as_observation` or `&:as_problem`); `NotionPage.none` when the tracker names no project.

- [ ] **Step 1: Write the failing test** `test/models/project_tracker_log_test.rb`:

```ruby
require 'test_helper'

class ProjectTrackerLogTest < ActiveSupport::TestCase
  include NotionLogFixtures

  test "a tracker's observations and problems are the rows filed under any of its Notion projects" do
    tracker, project_id = log_tracker!
    second = project_page!(title: "Harvey Phase 2").notion_id
    tracker.update_columns(notion_project_ids: [project_id, second])
    mine = observation!(project_ids: [project_id])
    also_mine = observation!(project_ids: [SecureRandom.uuid, second])
    observation!(project_ids: [SecureRandom.uuid])
    observation!(project_ids: [])
    my_problem = problem!(project_ids: [second])
    problem!(project_ids: [SecureRandom.uuid])

    assert_equal [mine.id, also_mine.id].sort, tracker.observations.pluck(:id).sort
    assert_equal [my_problem.id], tracker.problems.pluck(:id)
  end

  test "two trackers that share a project both see its rows" do
    tracker, project_id = log_tracker!
    other = ProjectTracker.new(name: "Sibling", notion_project_ids: [project_id])
    other.save!(validate: false)
    row = observation!(project_ids: [project_id])
    assert_equal [row.id], tracker.observations.pluck(:id)
    assert_equal [row.id], other.observations.pluck(:id)
  end

  test "a tracker with no Notion project has none, without a query that matches everything" do
    tracker, = log_tracker!(project: nil)
    observation!(project_ids: [])
    assert_equal 0, tracker.observations.count
    assert_equal 0, tracker.problems.count
  end

  test "a row trashed by the sync is not returned" do
    tracker, project_id = log_tracker!
    observation!(project_ids: [project_id]).destroy
    assert_equal 0, tracker.observations.count
  end

  test "the relations can be ordered and limited" do
    tracker, project_id = log_tracker!
    old = observation!(project_ids: [project_id], observed_at: 3.days.ago)
    new = observation!(project_ids: [project_id], observed_at: 1.day.ago)
    assert_equal [new.id, old.id], tracker.observations.order(occurred_at: :desc).limit(5).pluck(:id)
  end
end
```

- [ ] **Step 2: Run, expect failure** (`undefined method 'observations'`):

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/models/project_tracker_log_test.rb
```

- [ ] **Step 3: Implement.** In `app/models/project_tracker.rb`, after `notion_project_linked?` (line 474):

```ruby
  # What Stacksbot filed under any of this tracker's Notion projects, as
  # relations of NotionPage (wrap a row with as_observation / as_problem).
  # The rows are synced by Stacks::Notion::FilteredSync and found through the
  # GIN index on notion_pages.project_ids. This is the only way an observation
  # reaches a tracker.
  def observations
    notion_log_rows(NotionPage.observations)
  end

  def problems
    notion_log_rows(NotionPage.problems)
  end

  private def notion_log_rows(scope)
    ids = Array(notion_project_ids).select(&:present?)
    return NotionPage.none if ids.empty?
    scope.where("notion_pages.project_ids && ARRAY[?]::varchar[]", ids)
  end
```

- [ ] **Step 4: Run, expect 5 runs, 0 failures** (same command as Step 2).
- [ ] **Step 5: Commit.** `feat(project-tracker): observations and problems by Notion project`

---

### Task 9: The log's rows for a view (`Stacks::ProjectLog`)

**Files:** Create `lib/stacks/project_log.rb`, `test/lib/stacks/project_log_test.rb`.

**Consumes:** `ProjectTracker#observations`, `#problems`, `#notion_project_linked?` (`app/models/project_tracker.rb:472`); the wrappers; `FilteredSync.last_synced_at`.

**Produces:**
- `Stacks::ProjectLog.new(tracker, view: nil, source: nil, valence: nil, page: nil, now: Time.zone.now)`. Each parameter is whitelisted; anything else falls back to its default.
- Readers: `view` (`"attention"`, `"highlights"` or `"everything"`), `source` (a key of `Observation::SOURCE_GROUP_LABELS` or nil), `valence` (`"positive"`, `"neutral"`, `"negative"` or nil), `page` (Integer, 1..999; always 1 for `attention`).
- `#empty_reason` → `:no_notion_project`, `:never_synced`, `:nothing_seen` or nil.
- `#problems` → `[Stacks::Notion::Problem]`, open ones, worst first (only for `attention`, else `[]`).
- `#rows` → `[Stacks::ProjectLog::Row]`; `Row` is `Struct.new(:observation, :problems, :escalated, keyword_init: true)`.
- `#weeks` → `[[Date (the Monday), [Row]]]`, newest week first.
- `#older_page`, `#newer_page` → Integer or nil; `#capped?`; `#filtered?`; `#interim_in_use?`; `#last_synced_at`.
- `ProjectLog.escalated?(observation, problems)` → Boolean.
- `ProjectLog.pill_for(row)` → `[css_class String, label String, grey Boolean]`.
- `ProjectLog.summary(tracker, now: Time.zone.now)` → `{ empty_reason:, open_problems:, negatives:, escalated:, latest: [Row], capped: }`.
- Constants `VIEWS`, `VIEW_LABELS`, `VALENCE_PARAMS`, `ATTENTION_WINDOW = 30.days`, `ATTENTION_LIMIT = 500`, `PROBLEM_LIMIT = 200`, `PER_PAGE = 200`.

- [ ] **Step 1: Write the failing tests** `test/lib/stacks/project_log_test.rb`:

```ruby
require 'test_helper'

class StacksProjectLogTest < ActiveSupport::TestCase
  include NotionLogFixtures

  NOW = Time.zone.parse("2026-10-13T12:00:00Z")

  setup do
    System.delete_all
    System.create!(settings: { "notion_filtered_sync_marks" => { "OBSERVATIONS" => "2026-10-13T05:00:00Z" } })
    @tracker, @project = log_tracker!
  end

  def log(**params)
    Stacks::ProjectLog.new(@tracker, now: NOW, **params)
  end

  def obs!(**attrs)
    observation!(**{ project_ids: [@project], observed_at: NOW - 1.day }.merge(attrs))
  end

  def titles(log)
    log.rows.map { |r| r.observation.title }
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "parameters are whitelisted and anything else falls back" do
    l = log(view: "highlights", source: "meet", valence: "negative", page: "3")
    assert_equal ["highlights", "meet", "negative", 3], [l.view, l.source, l.valence, l.page]
    [nil, "", "all", "Attention", ["highlights"], { "a" => 1 }, 7].each do |bad|
      l = log(view: bad, source: bad, valence: bad, page: bad)
      assert_equal ["attention", nil, nil, 1], [l.view, l.source, l.valence, l.page], bad.inspect
    end
    %w[0 -1 1.5 1e3 abc 1000 01].each { |bad| assert_equal 1, log(view: "everything", page: bad).page, bad }
    assert_equal 1, log(view: "attention", page: "4").page, "Needs attention has one page"
  end

  test "needs attention: negative observations of the last 30 days that are not dismissed" do
    obs!(name: "recent negative", valence: "Negative")
    obs!(name: "old negative", valence: "Negative", observed_at: NOW - 31.days)
    obs!(name: "dismissed negative", valence: "Negative", status: "Dismissed")
    obs!(name: "positive", valence: "Positive")
    obs!(name: "neutral", valence: "Neutral")
    obs!(name: "unmarked", valence: nil, type: "FYI")
    observation!(name: "another project", valence: "Negative", project_ids: [SecureRandom.uuid], observed_at: NOW - 1.day)
    assert_equal ["recent negative"], titles(log)
  end

  test "needs attention: escalated rows first, then newest first" do
    obs!(name: "plain new", valence: "Negative", salience: "Low", observed_at: NOW - 1.day)
    obs!(name: "escalated old", valence: "Negative", salience: "High", observed_at: NOW - 9.days)
    obs!(name: "plain old", valence: "Negative", salience: "Medium", observed_at: NOW - 5.days)
    obs!(name: "escalated new", valence: "Negative", salience: "High", observed_at: NOW - 2.days)
    assert_equal ["escalated new", "escalated old", "plain new", "plain old"], titles(log)
    assert_equal [true, true, false, false], log.rows.map(&:escalated)
  end

  test "needs attention: open problems for the project, worst first, then most recently seen" do
    problem!(name: "medium", severity: "Medium", status: "Owned", project_ids: [@project], last_seen: NOW - 1.day)
    problem!(name: "critical old", severity: "Critical", status: "Open", project_ids: [@project], last_seen: NOW - 9.days)
    problem!(name: "critical new", severity: "Critical", status: "Mitigating", project_ids: [@project], last_seen: NOW - 2.days)
    problem!(name: "resolved", severity: "Critical", status: "Resolved", project_ids: [@project])
    problem!(name: "dismissed", severity: "High", status: "Dismissed", project_ids: [@project])
    problem!(name: "elsewhere", severity: "Critical", status: "Open", project_ids: [SecureRandom.uuid])
    assert_equal ["critical new", "critical old", "medium"], log.problems.map(&:title)
    assert_equal [], log(view: "everything").problems
  end

  test "escalated: Negative and High salience, or folded into an unowned High or Critical problem" do
    owned = problem!(severity: "Critical", status: "Owned", project_ids: [])
    unowned = problem!(severity: "High", status: "Open", project_ids: [])
    minor = problem!(severity: "Medium", status: "Open", project_ids: [])
    obs!(name: "high salience", valence: "Negative", salience: "High")
    obs!(name: "unowned problem", valence: "Negative", salience: "Low", problem_ids: [unowned.notion_id])
    obs!(name: "owned problem", valence: "Negative", salience: "Low", problem_ids: [owned.notion_id])
    obs!(name: "minor problem", valence: "Negative", salience: "Medium", problem_ids: [minor.notion_id])
    obs!(name: "unknown problem", valence: "Negative", salience: "Low", problem_ids: [SecureRandom.uuid])
    by_title = log.rows.index_by { |r| r.observation.title }
    assert_equal({ "high salience" => true, "unowned problem" => true, "owned problem" => false,
                   "minor problem" => false, "unknown problem" => false }, by_title.transform_values(&:escalated))
    assert_equal [unowned.notion_id], by_title["unowned problem"].problems.map(&:notion_id)
    assert_equal [], by_title["unknown problem"].problems
  end

  test "escalated: a positive or neutral row is never escalated, whatever its salience or problem" do
    unowned = problem!(severity: "Critical", status: "Open", project_ids: [])
    obs!(name: "positive", valence: "Positive", salience: "High", problem_ids: [unowned.notion_id])
    obs!(name: "neutral", valence: "Neutral", salience: "High")
    assert_equal [false, false], log(view: "everything").rows.map(&:escalated)
  end

  test "escalated: a link held only on the problem's side counts" do
    row = obs!(name: "linked from the problem", valence: "Negative", salience: "Low")
    problem!(severity: "Critical", status: "Open", project_ids: [@project], source_observation_ids: [row.notion_id])
    assert log.rows.first.escalated
    assert_equal 1, log.rows.first.problems.size
  end

  test "escalated is computed with the same number of queries for 2 rows as for 8" do
    make = lambda do |n|
      n.times { obs!(valence: "Negative", problem_ids: [problem!(severity: "High", status: "Open", project_ids: []).notion_id]) }
    end
    read = -> { l = log; l.rows.size; l.problems.size }
    make.(2)
    few = count_queries { read.call }
    make.(6)
    many = count_queries { read.call }
    assert_equal few, many
    assert_operator few, :<=, 3
  end

  test "highlights: every row with a valence that is not dismissed, newest first, any age" do
    obs!(name: "old positive", valence: "Positive", observed_at: NOW - 80.days)
    obs!(name: "neutral", valence: "Neutral", observed_at: NOW - 3.days)
    obs!(name: "negative", valence: "Negative", observed_at: NOW - 1.day)
    obs!(name: "dismissed", valence: "Positive", status: "Dismissed")
    obs!(name: "unmarked", valence: nil, type: "FYI")
    assert_equal ["negative", "neutral", "old positive"], titles(log(view: "highlights"))
  end

  test "highlights group by week, Monday first" do
    obs!(name: "tue", valence: "Positive", observed_at: Time.zone.parse("2026-10-13T09:00:00Z"))
    obs!(name: "mon", valence: "Positive", observed_at: Time.zone.parse("2026-10-12T09:00:00Z"))
    obs!(name: "sun before", valence: "Positive", observed_at: Time.zone.parse("2026-10-11T09:00:00Z"))
    weeks = log(view: "highlights").weeks
    assert_equal [Date.new(2026, 10, 12), Date.new(2026, 10, 5)], weeks.map(&:first)
    assert_equal [%w[tue mon], ["sun before"]], weeks.map { |(_, rows)| rows.map { |r| r.observation.title } }
  end

  test "everything: every synced row for the project, dismissed and unmarked included" do
    obs!(name: "dismissed", valence: "Negative", status: "Dismissed", observed_at: NOW - 2.days)
    obs!(name: "unmarked", valence: nil, type: "FYI", observed_at: NOW - 1.day)
    obs!(name: "ancient", valence: nil, type: "Lead", observed_at: NOW - 300.days)
    assert_equal %w[unmarked dismissed ancient], titles(log(view: "everything"))
  end

  test "interim: before Valence exists the page still has something to show" do
    obs!(name: "a risk", valence: nil, valence_property: false, type: "Risk", salience: "High")
    obs!(name: "a win", valence: nil, valence_property: false, type: "Win")
    obs!(name: "an fyi", valence: nil, valence_property: false, type: "FYI")
    assert_equal ["a risk"], titles(log)
    assert log.rows.first.escalated, "an inferred Negative of High salience is escalated like any other"
    assert log.interim_in_use?
    assert_equal ["a risk", "a win"].sort, titles(log(view: "highlights")).sort
    assert_equal 3, log(view: "everything").rows.size
    assert_equal ["a win"], titles(log(view: "everything", valence: "positive"))
  end

  test "interim_in_use? is false once the rows shown carry a valence" do
    obs!(valence: "Negative", type: "Risk")
    assert_not log.interim_in_use?
  end

  test "chips filter by source group and by valence, with any view" do
    obs!(name: "twist neg", source: "Twist", valence: "Negative")
    obs!(name: "meet neg", source: "Gemini Notes", valence: "Negative")
    obs!(name: "mail pos", source: "google_groups", valence: "Positive")
    obs!(name: "notion neutral", source: "Notion (Tasks)", valence: "Neutral")
    obs!(name: "sentry none", source: "Sentry", valence: nil, type: "Bug")
    assert_equal ["meet neg"], titles(log(source: "meet"))
    assert_equal ["mail pos"], titles(log(view: "highlights", source: "mail"))
    assert_equal ["notion neutral"], titles(log(view: "everything", valence: "neutral"))
    assert_equal ["sentry none"], titles(log(view: "everything", source: "other"))
    assert_equal [], titles(log(view: "everything", source: "twist", valence: "positive"))
    assert log(source: "meet").filtered?
    assert_not log.filtered?
  end

  test "everything and highlights read 200 stored rows a page" do
    203.times { |i| obs!(name: "row #{i}", valence: "Positive", observed_at: NOW - (i + 1).minutes) }
    first = log(view: "everything")
    assert_equal 200, first.rows.size
    assert_equal "row 0", first.rows.first.observation.title
    assert_equal 2, first.older_page
    assert_nil first.newer_page
    second = log(view: "everything", page: "2")
    assert_equal ["row 200", "row 201", "row 202"], titles(second)
    assert_nil second.older_page
    assert_equal 1, second.newer_page
    assert_equal 200, log(view: "highlights").rows.size
    assert_empty log(view: "everything", page: "9").rows
  end

  test "needs attention reads at most 500 rows and says when it hit the cap" do
    assert_not log.capped?
    Stacks::ProjectLog.stub_const(:ATTENTION_LIMIT, 3) do
      5.times { |i| obs!(name: "neg #{i}", valence: "Negative", observed_at: NOW - (i + 1).hours) }
      l = log
      assert_equal 3, l.rows.size
      assert l.capped?
      assert_nil l.older_page
    end
  end

  test "empty_reason says why there is nothing, most basic cause first" do
    assert_equal :nothing_seen, log.empty_reason
    obs!(valence: nil, type: "FYI")
    assert_nil log.empty_reason, "a project with rows is never 'empty', even when this view shows none"
    assert_empty log.rows

    System.first.update!(notion_filtered_sync_marks: {})
    assert_equal :never_synced, log.empty_reason

    no_project, = log_tracker!(project: nil)
    assert_equal :no_notion_project, Stacks::ProjectLog.new(no_project, now: NOW).empty_reason

    removed, id = log_tracker!
    NotionPage.find_by!(notion_id: id).destroy
    assert_equal :no_notion_project, Stacks::ProjectLog.new(removed, now: NOW).empty_reason
  end

  test "a project with only a problem is not empty" do
    problem!(project_ids: [@project])
    assert_nil log.empty_reason
  end

  test "rows with broken data are shown, not raised on" do
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Notion.filtered_parent_id(:OBSERVATIONS),
                       data: { "properties" => "nonsense" }, project_ids: [@project], occurred_at: NOW - 1.day)
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Notion.filtered_parent_id(:PROBLEMS),
                       data: {}, project_ids: [@project], occurred_at: nil)
    everything = log(view: "everything")
    assert_equal ["Untitled"], titles(everything)
    assert_equal [false], everything.rows.map(&:escalated)
    assert_equal ["Untitled"], log.problems.map(&:title)
    assert_equal [], log(view: "highlights").weeks
  end

  test "pill_for: red when escalated, orange negative, green positive, grey neutral or unmarked" do
    make = ->(valence, escalated) do
      o = NotionPage.new(notion_id: "x", data: observation_data(valence: valence, type: "FYI")).as_observation
      Stacks::ProjectLog::Row.new(observation: o, problems: [], escalated: escalated)
    end
    assert_equal ["pill error", "Escalated", false], Stacks::ProjectLog.pill_for(make.("Negative", true))
    assert_equal ["pill at_risk", "Negative", false], Stacks::ProjectLog.pill_for(make.("Negative", false))
    assert_equal ["pill exceptional", "Positive", false], Stacks::ProjectLog.pill_for(make.("Positive", false))
    assert_equal ["pill", "Neutral", true], Stacks::ProjectLog.pill_for(make.("Neutral", false))
    assert_equal ["pill", "Not marked", true], Stacks::ProjectLog.pill_for(make.(nil, false))
  end

  test "summary counts what Needs attention shows and takes its first three rows" do
    problem!(severity: "High", status: "Open", project_ids: [@project])
    problem!(severity: "Low", status: "Resolved", project_ids: [@project])
    obs!(name: "n1", valence: "Negative", salience: "Low", observed_at: NOW - 1.day)
    obs!(name: "n2", valence: "Negative", salience: "High", observed_at: NOW - 2.days)
    obs!(name: "n3", valence: "Negative", salience: "Low", observed_at: NOW - 3.days)
    obs!(name: "n4", valence: "Negative", salience: "Low", observed_at: NOW - 4.days)
    obs!(name: "old", valence: "Negative", observed_at: NOW - 40.days)
    obs!(name: "win", valence: "Positive")
    s = Stacks::ProjectLog.summary(@tracker, now: NOW)
    assert_nil s[:empty_reason]
    assert_equal 1, s[:open_problems]
    assert_equal 4, s[:negatives]
    assert_equal 1, s[:escalated]
    assert_equal %w[n2 n1 n3], s[:latest].map { |r| r.observation.title }
    assert_not s[:capped]
  end

  test "summary for a tracker with nothing gives the reason and zeroes" do
    s = Stacks::ProjectLog.summary(@tracker, now: NOW)
    assert_equal :nothing_seen, s[:empty_reason]
    assert_equal [0, 0, 0, []], s.values_at(:open_problems, :negatives, :escalated, :latest)
  end
end
```

- [ ] **Step 2: Run, expect failure:**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/lib/stacks/project_log_test.rb
```

- [ ] **Step 3: Implement** `lib/stacks/project_log.rb`:

```ruby
# What the project log (/admin/project_trackers/:id/log) shows for one
# tracker and one view. It filters and orders rows the filtered Notion sync
# stored; every judgement in them (which project, valence, salience, what was
# folded into a Problem) was made by Stacksbot. Nothing here decides what an
# observation means, calls a model or writes anywhere.
class Stacks::ProjectLog
  VIEWS = %w[attention highlights everything].freeze
  VIEW_LABELS = {
    "attention" => "Needs attention", "highlights" => "Highlights", "everything" => "Everything",
  }.freeze
  VALENCE_PARAMS = { "positive" => "Positive", "neutral" => "Neutral", "negative" => "Negative" }.freeze
  SOURCE_PARAMS = Stacks::Notion::Observation::SOURCE_GROUP_LABELS.keys.freeze

  ATTENTION_WINDOW = 30.days
  ATTENTION_LIMIT = 500 # stored rows read for Needs attention
  PROBLEM_LIMIT = 200   # a tracker's problems read, newest first
  PER_PAGE = 200        # stored rows read per page of Highlights and Everything

  Row = Struct.new(:observation, :problems, :escalated, keyword_init: true)

  attr_reader :tracker, :view, :source, :valence, :page

  def initialize(tracker, view: nil, source: nil, valence: nil, page: nil, now: Time.zone.now)
    @tracker = tracker
    @now = now
    @view = VIEWS.include?(view) ? view : "attention"
    @source = SOURCE_PARAMS.include?(source) ? source : nil
    @valence = valence.is_a?(String) && VALENCE_PARAMS.key?(valence) ? valence : nil
    @page = page.is_a?(String) && page.match?(/\A[1-9]\d{0,2}\z/) && @view != "attention" ? page.to_i : 1
  end

  # A Negative observation that is High salience, or that was folded into a
  # Problem nobody owns of severity High or Critical. Derived, never stored.
  def self.escalated?(observation, problems)
    observation.negative? && (observation.salience == "High" || problems.any?(&:escalating?))
  end

  # [css class, label, grey?]. A bare .pill has no background, so the two
  # grey ones are coloured by the view.
  def self.pill_for(row)
    return ["pill error", "Escalated", false] if row.escalated
    case row.observation.valence
    when "Negative" then ["pill at_risk", "Negative", false]
    when "Positive" then ["pill exceptional", "Positive", false]
    when "Neutral" then ["pill", "Neutral", true]
    else ["pill", "Not marked", true]
    end
  end

  # For the module on the tracker page: the counts and first rows of Needs attention.
  def self.summary(tracker, now: Time.zone.now)
    log = new(tracker, now: now)
    reason = log.empty_reason
    return { empty_reason: reason, open_problems: 0, negatives: 0, escalated: 0, latest: [], capped: false } if reason
    { empty_reason: nil, open_problems: log.problems.size, negatives: log.rows.size,
      escalated: log.rows.count(&:escalated), latest: log.rows.first(3), capped: log.capped? }
  end

  # Why the whole log is empty, most basic cause first; nil when the project
  # has any row at all (a view that shows none of them says so itself).
  def empty_reason
    return @empty_reason if defined?(@empty_reason)
    @empty_reason =
      if !tracker.notion_project_linked? then :no_notion_project
      elsif last_synced_at.nil? then :never_synced
      elsif !tracker.observations.exists? && !tracker.problems.exists? then :nothing_seen
      end
  end

  def last_synced_at
    return @last_synced_at if defined?(@last_synced_at)
    @last_synced_at = Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
  end

  # Open problems for the project, worst first, then most recently seen.
  def problems
    return [] unless view == "attention"
    @problems ||= tracker_problems.select(&:open?).sort_by { |p| [p.severity_rank, -(p.last_seen_at || Time.zone.at(0)).to_i] }
  end

  def rows
    @rows ||= begin
      list = stored_rows.map(&:as_observation)
      list = list.select { |o| o.negative? && !o.dismissed? } if view == "attention"
      list = list.select { |o| o.valence.present? && !o.dismissed? } if view == "highlights"
      list = list.select { |o| o.source_group == source } if source
      list = list.select { |o| o.valence == VALENCE_PARAMS[valence] } if valence
      built = build_rows(list)
      # sort_by is not stable, so the position keeps newest-first within each half.
      view == "attention" ? built.each_with_index.sort_by { |row, i| [row.escalated ? 0 : 1, i] }.map(&:first) : built
    end
  end

  # [[Monday, rows]], newest week first. Rows with no date are left out.
  def weeks
    rows.select { |r| r.observation.observed_at }
        .group_by { |r| r.observation.observed_at.to_date.beginning_of_week }
        .to_a
  end

  def older_page
    stored_rows
    @more && view != "attention" ? page + 1 : nil
  end

  def newer_page
    page > 1 ? page - 1 : nil
  end

  # Needs attention read its limit and there were more.
  def capped?
    stored_rows
    @more && view == "attention"
  end

  def filtered?
    source.present? || valence.present?
  end

  # Some row shown takes its valence from its Type (Observation::INTERIM_VALENCE_BY_TYPE).
  def interim_in_use?
    rows.any? { |r| r.observation.valence_inferred? }
  end

  private

  # The stored rows this view reads, newest first, before any filter. One query.
  def stored_rows
    @stored_rows ||= begin
      base = tracker.observations.order(Arel.sql("notion_pages.occurred_at DESC NULLS LAST, notion_pages.id DESC"))
      limit = view == "attention" ? ATTENTION_LIMIT : PER_PAGE
      base = view == "attention" ? base.where("notion_pages.occurred_at >= ?", @now - ATTENTION_WINDOW) : base.offset((page - 1) * limit)
      found = base.limit(limit + 1).to_a
      @more = found.size > limit
      found.first(limit)
    end
  end

  def tracker_problems
    @tracker_problems ||= tracker.problems
      .order(Arel.sql("notion_pages.occurred_at DESC NULLS LAST, notion_pages.id DESC"))
      .limit(PROBLEM_LIMIT).map(&:as_problem)
  end

  # Each observation with the problems it was folded into, from one query for
  # the whole list. A link counts whichever side holds it: the observation's
  # Problems relation or the problem's Source Observations.
  def build_rows(list)
    ids = list.flat_map(&:problem_ids).uniq
    named = ids.empty? ? [] : NotionPage.problems.where(notion_id: ids).map(&:as_problem)
    known = (named + tracker_problems).uniq(&:notion_id)
    by_id = known.index_by(&:notion_id)
    by_observation = {}
    known.each { |p| p.source_observation_ids.each { |oid| (by_observation[oid] ||= []) << p } }

    list.map do |o|
      problems = (o.problem_ids.filter_map { |id| by_id[id] } + by_observation.fetch(o.notion_id, [])).uniq(&:notion_id)
      Row.new(observation: o, problems: problems, escalated: self.class.escalated?(o, problems))
    end
  end
end
```

Notes for the implementer:
- `@more` is set inside `stored_rows`; `older_page` and `capped?` call it first so they are right whatever order the view asks in.
- `ATTENTION_LIMIT` is read at call time (`Stacks::ProjectLog::ATTENTION_LIMIT` through the lexical constant), so the `stub_const` test works. Do not copy it into a local at class-body time.
- The 2-vs-8 query test allows three queries: stored rows, the tracker's problems, the named problems.

- [ ] **Step 4: Run, expect 0 failures** (same command as Step 2).
- [ ] **Step 5: Commit.** `feat(project-log): the three views, chips, paging and the derived escalated flag`

---

### Task 10: A project-scoped lead grantee may open the Log page

**Files:** Modify `app/models/admin_authorization.rb`, `test/models/admin_authorization_test.rb`.

**Consumes:** nothing. **Produces:** `AdminAuthorization#authorized?(:read, <ActiveAdmin::Page named "Log">)` is true for a user with at least one project-scoped lead grant. (Admins and leads already pass at `app/models/admin_authorization.rb:88`.) The page itself checks the tracker (Task 11).

- [ ] **Step 1: Add the failing test** to `test/models/admin_authorization_test.rb`, using its own helpers (`auth_for`, `make_user`, `make_project_tracker`, lines 4-16):

```ruby
  test "a project-scoped grantee passes the Log page's gate, and no other page's" do
    namespace = ActiveAdmin.application.namespace(:admin)
    log_page = ActiveAdmin::Page.new(namespace, "Log", {})
    other_page = ActiveAdmin::Page.new(namespace, "Project Cost Explorer", {})

    scoped = make_user("scoped-log@sanctuary.computer")
    PermissionGrant.create!(admin_user: scoped, permission: "lead", subject: make_project_tracker("Granted"))
    assert auth_for(scoped).authorized?(:read, log_page)
    refute auth_for(scoped).authorized?(:update, log_page)
    refute auth_for(scoped).authorized?(:read, other_page)

    nobody = make_user("nobody-log@sanctuary.computer")
    refute auth_for(nobody).authorized?(:read, log_page)

    lead = make_user("lead-log@sanctuary.computer")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    assert auth_for(lead).authorized?(:read, log_page)
  end
```

- [ ] **Step 2: Run, expect this test to fail on its first assertion:**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/models/admin_authorization_test.rb
```

- [ ] **Step 3: Implement.** In `app/models/admin_authorization.rb`, inside `if scoped_ids.any?` (after line 101):

```ruby
        # The project log (app/admin/log.rb) is nested under a tracker. This
        # only opens the page's own gate; the page then checks the tracker
        # itself, which the line above limits to the granted ones.
        return true if subject.is_a?(ActiveAdmin::Page) && subject.name == "Log"
```

- [ ] **Step 4: Run, expect 0 failures** (same command as Step 2).
- [ ] **Step 5: Commit.** `feat(auth): a project-scoped lead grantee may open the project log's page gate`

---

### Task 11: The log page

**Files:** Create `app/admin/log.rb`, `app/views/admin/log/_show.html.erb`, `app/views/admin/log/_row.html.erb`, `app/views/admin/log/_empty.html.erb`, `test/integration/admin_project_log_test.rb`.

**Consumes:** `Stacks::ProjectLog` (Task 9); the adapter line (Task 10); the dashboard-module classes (`app/assets/stylesheets/_generic_dashboard_modules.scss`); the pill classes `exceptional`, `at_risk`, `error` (`app/assets/stylesheets/active_admin.scss:1083-1170`).

**Produces:** `GET /admin/project_trackers/:project_tracker_id/log` (`admin_project_tracker_log_path(tracker, view:, source:, valence:, page:)`), HTML only. Partials `admin/log/row` (locals `row`) and `admin/log/empty` (locals `tracker`, `reason`), both reused by Task 12. Row elements carry `id="log_row_<notion id>"`; problem rows `id="log_problem_<notion id>"`.

- [ ] **Step 1: Write the failing tests** `test/integration/admin_project_log_test.rb`, set up as `test/integration/admin_weekly_ship_coaching_test.rb:15-23` and `:72-79` are:

```ruby
require 'test_helper'

# The project log: what Stacksbot filed under a tracker's Notion projects,
# read from notion_pages. Nothing here reaches Notion.
class AdminProjectLogTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include NotionLogFixtures

  setup do
    System.delete_all
    System.create!(settings: { "notion_filtered_sync_marks" => { "OBSERVATIONS" => 2.hours.ago.utc.iso8601 } })
    @admin = AdminUser.create!(email: "logadmin#{SecureRandom.hex(4)}@sanctuary.computer",
                               password: 'password12345', password_confirmation: 'password12345', roles: ['admin'])
    sign_in @admin
    @tracker, @project = log_tracker!(name: "Harvey Build")
  end

  def obs!(**attrs)
    observation!(**{ project_ids: [@project], observed_at: 1.day.ago }.merge(attrs))
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def row_for(notion_page)
    page.at_css("#log_row_#{notion_page.notion_id}")
  end

  def module_titled(title)
    page.css(".dashboard-module").find { |m| m.at_css(".module-header p")&.text&.strip == title }
  end

  def scoped_grantee!(tracker = @tracker)
    trainee = AdminUser.create!(email: "trainee#{SecureRandom.hex(4)}@sanctuary.computer",
                                password: 'password12345', password_confirmation: 'password12345')
    PermissionGrant.create!(admin_user: trainee, permission: "lead", subject: tracker, granted_by: @admin)
    trainee
  end

  test "the default view is Needs attention: open problems, then negative rows with the escalated ones red" do
    problem = problem!(name: "Timeline slipping", severity: "Critical", status: "Open", owner: nil,
                       occurrences: 4, project_ids: [@project])
    escalated = obs!(name: "Client asked twice for a date", text: "No answer in the channel.", valence: "Negative",
                     salience: "High", source: "Twist", problem_ids: [problem.notion_id])
    plain = obs!(name: "Design review ran long", valence: "Negative", salience: "Low", observed_at: 2.hours.ago)
    win = obs!(name: "Launch praised", valence: "Positive")

    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_equal "Needs attention", page.at_css(".log-tab.current")&.text&.strip
    problems = module_titled("Open problems")
    assert problems, "expected the Open problems module"
    assert_includes problems.text, "Timeline slipping"
    assert_includes problems.text, "Critical"
    assert_includes problems.text, "Nobody owns it yet"
    assert_includes problems.text, "Seen 4 times"

    ids = page.css("tr[id^='log_row_']").map { |tr| tr["id"] }
    assert_equal ["log_row_#{escalated.notion_id}", "log_row_#{plain.notion_id}"], ids, "escalated first; the win is not here"
    assert_equal "pill error", row_for(escalated).at_css(".pill")["class"]
    assert_equal "Escalated", row_for(escalated).at_css(".pill").text.strip
    assert_equal "pill at_risk", row_for(plain).at_css(".pill")["class"]
    assert_includes row_for(escalated).text, "No answer in the channel."
    assert_includes row_for(escalated).text, "Twist"
    assert_includes row_for(escalated).text, "Folded into"
    assert_includes row_for(escalated).text, "Timeline slipping"
    assert_equal "https://twist.com/a/133876/ch/1/t/2/", row_for(escalated).at_css("a.log-source")["href"]
    assert_nil row_for(win)
  end

  test "Highlights groups gated rows by week and Everything shows dismissed and unmarked rows too" do
    this_week = obs!(name: "Launch praised", valence: "Positive", observed_at: Time.zone.now.beginning_of_week + 1.hour)
    last_week = obs!(name: "Scope agreed", valence: "Neutral", observed_at: Time.zone.now.beginning_of_week - 2.days)
    dismissed = obs!(name: "False alarm", valence: "Negative", status: "Dismissed")
    unmarked = obs!(name: "Routine note", valence: nil, type: "FYI")

    get admin_project_tracker_log_path(@tracker, view: "highlights")
    assert_response :success
    assert_equal 2, page.css(".log-week").size
    assert_match(/\AWeek of /, page.css(".log-week").first.text.strip)
    assert row_for(this_week)
    assert row_for(last_week)
    assert_nil row_for(dismissed)
    assert_nil row_for(unmarked)
    assert_equal "pill exceptional", row_for(this_week).at_css(".pill")["class"]
    assert_match(/background-color/, row_for(last_week).at_css(".pill")["style"], "neutral is grey")

    get admin_project_tracker_log_path(@tracker, view: "everything")
    [this_week, last_week, dismissed, unmarked].each { |r| assert row_for(r), "#{r.page_title} is under Everything" }
    assert_includes row_for(dismissed).text, "Dismissed"
    assert_equal "Not marked", row_for(unmarked).at_css(".pill").text.strip
  end

  test "chips filter, combine with a view, and keep the view in their links" do
    twist = obs!(name: "From Twist", source: "Twist", valence: "Negative")
    meet = obs!(name: "From a meeting", source: "Google Meet", valence: "Negative")
    get admin_project_tracker_log_path(@tracker, view: "everything", source: "meet")
    assert_response :success
    assert row_for(meet)
    assert_nil row_for(twist)
    chip = page.css("a.log-chip").find { |a| a.text.strip == "Twist" }
    assert_equal admin_project_tracker_log_path(@tracker, view: "everything", source: "twist"), chip["href"]
    assert_equal "Meet", page.at_css("a.log-chip.current").text.strip
    tab = page.css("a.log-tab").find { |a| a.text.strip == "Highlights" }
    assert_equal admin_project_tracker_log_path(@tracker, view: "highlights", source: "meet"), tab["href"]

    get admin_project_tracker_log_path(@tracker, view: "everything", source: "meet", valence: "positive")
    assert_nil row_for(meet)
    assert_includes response.body, "No rows match these filters"
  end

  test "parameters outside the whitelist are ignored, never an error and never echoed" do
    row = obs!(name: "Something negative", valence: "Negative")
    get admin_project_tracker_log_path(@tracker), params: {
      view: "<script>x</script>", source: ["twist"], valence: { a: 1 }, page: "-4",
      q: { "page_title_cont" => "zzz" }, order: "page_title_desc", scope: "all"
    }
    assert_response :success
    assert row_for(row), "an unknown view is Needs attention, and q and order do nothing"
    assert_not_includes response.body, "<script>x</script>"
  end

  test "the page has no CSV, JSON or XML form" do
    obs!(name: "QUOTED-FROM-A-CHANNEL", valence: "Negative")
    %w[csv json xml].each do |format|
      begin
        get admin_project_tracker_log_path(@tracker, format: format)
      rescue ActionController::UnknownFormat, ActionController::RoutingError
        next
      end
      assert_not_equal 200, response.status, "#{format} should not be served"
      assert_not_includes response.body, "QUOTED-FROM-A-CHANNEL"
    end
  end

  test "model-written text is escaped and only a web address is linked" do
    row = obs!(name: "<script>alert('n')</script> name", text: "<img src=x onerror=alert(1)> text",
               source_ref: "javascript:alert(1)", valence: "Negative")
    problem!(name: "<b>bold problem</b>", project_ids: [@project])
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_not_includes response.body, "<script>alert('n')"
    assert_not_includes response.body, "<img src=x"
    assert_not_includes response.body, "<b>bold problem</b>"
    assert_includes row_for(row).text, "<script>alert('n')</script> name"
    assert_nil row_for(row).at_css("a.log-source"), "a javascript: address is not a link"
    assert_empty page.css("a[href^='javascript']")
  end

  test "before Valence exists the page shows risks as negative and says the rule is interim" do
    risk = obs!(name: "Budget at risk", valence: nil, valence_property: false, type: "Risk")
    obs!(name: "Plain note", valence: nil, valence_property: false, type: "FYI")
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_equal "pill at_risk", row_for(risk).at_css(".pill")["class"]
    assert_includes response.body, "Stacksbot has not marked these rows yet"
    get admin_project_tracker_log_path(@tracker, view: "everything")
    assert_equal 2, page.css("tr[id^='log_row_']").size
  end

  test "no Notion project chosen: says so and links to the tracker's edit form" do
    bare, = log_tracker!(name: "Unlinked", project: nil)
    get admin_project_tracker_log_path(bare)
    assert_response :success
    assert_includes response.body, "no Notion project chosen"
    assert page.at_css("a[href='#{edit_admin_project_tracker_path(bare)}']")
    assert_empty page.css(".log-tab"), "no tabs over an empty log"
  end

  test "nothing synced yet: says the sync has not run" do
    System.first.update!(notion_filtered_sync_marks: {})
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "has not synced Stacksbot's observations yet"
  end

  test "nothing seen: says so, and names a missing or unreadable Twist channel" do
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "has not filed anything under this project yet"
    assert_includes response.body, "no Twist channel linked"

    @tracker.update_columns(twist_channels_inaccessible: [355509])
    ProjectTracker.any_instance.stubs(:twist_channel_ids).returns([355509])
    get admin_project_tracker_log_path(@tracker)
    assert_includes response.body, "Stacksbot is not in 1 of this project's Twist channels"
  end

  test "rows exist but none needs attention: says so and points at Everything" do
    obs!(name: "Routine note", valence: nil, type: "FYI")
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "Nothing needs attention"
    assert page.at_css("a[href='#{admin_project_tracker_log_path(@tracker, view: "everything")}']")
  end

  test "Everything is paged" do
    Stacks::ProjectLog.stub_const(:PER_PAGE, 2) do
      rows = Array.new(3) { |i| obs!(name: "Row #{i}", valence: nil, type: "FYI", observed_at: (i + 1).hours.ago) }
      get admin_project_tracker_log_path(@tracker, view: "everything")
      assert_equal 2, page.css("tr[id^='log_row_']").size
      older = page.at_css("a.log-older")
      assert_equal admin_project_tracker_log_path(@tracker, view: "everything", page: 2), older["href"]
      assert_nil page.at_css("a.log-newer")
      get older["href"]
      assert_equal ["log_row_#{rows.last.notion_id}"], page.css("tr[id^='log_row_']").map { |tr| tr["id"] }
      assert page.at_css("a.log-newer")
      assert_nil page.at_css("a.log-older")
    end
  end

  test "a row with broken stored data is drawn, not a 500" do
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Notion.filtered_parent_id(:OBSERVATIONS),
                       data: { "properties" => [] }, project_ids: [@project], occurred_at: 1.day.ago)
    get admin_project_tracker_log_path(@tracker, view: "everything")
    assert_response :success
    assert_includes response.body, "Untitled"
    assert_includes response.body, "Unknown source"
  end

  test "a lead can open the log" do
    lead = AdminUser.create!(email: "lead#{SecureRandom.hex(4)}@sanctuary.computer",
                             password: 'password12345', password_confirmation: 'password12345')
    PermissionGrant.create!(admin_user: lead, permission: "lead", granted_by: @admin)
    obs!(name: "Client unhappy", valence: "Negative")
    sign_out @admin
    sign_in lead
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "Client unhappy"
  end

  test "a project-scoped lead grantee can open the log of their tracker and no other" do
    other, other_project = log_tracker!(name: "Acme Phase 2")
    obs!(name: "Mine to read", valence: "Negative")
    observation!(name: "NOT-MINE-TO-READ", valence: "Negative", project_ids: [other_project], observed_at: 1.day.ago)
    trainee = scoped_grantee!
    sign_out @admin
    sign_in trainee

    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "Mine to read"
    assert_not_includes response.body, "NOT-MINE-TO-READ"

    get admin_project_tracker_log_path(other)
    assert_not_equal 200, response.status
    assert_not_includes response.body, "NOT-MINE-TO-READ"
    assert_not_includes response.body, "Acme Phase 2"
  end

  test "a scoped grantee gets no edit link in an empty state" do
    bare, = log_tracker!(name: "Unlinked", project: nil)
    trainee = scoped_grantee!(bare)
    sign_out @admin
    sign_in trainee
    get admin_project_tracker_log_path(bare)
    assert_response :success
    assert_includes response.body, "no Notion project chosen"
    assert_nil page.at_css("a[href='#{edit_admin_project_tracker_path(bare)}']")
  end

  test "someone with no access to trackers cannot open a log" do
    nobody = AdminUser.create!(email: "nobody#{SecureRandom.hex(4)}@sanctuary.computer",
                               password: 'password12345', password_confirmation: 'password12345')
    obs!(name: "NOT-FOR-EVERYONE", valence: "Negative")
    sign_out @admin
    sign_in nobody
    get admin_project_tracker_log_path(@tracker)
    assert_not_equal 200, response.status
    assert_not_includes response.body, "NOT-FOR-EVERYONE"
  end

  test "a signed-out visitor is sent to sign in" do
    sign_out @admin
    get admin_project_tracker_log_path(@tracker)
    assert_response :redirect
  end
end
```

- [ ] **Step 2: Run, expect failure** (`undefined method 'admin_project_tracker_log_path'`):

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/integration/admin_project_log_test.rb
```

- [ ] **Step 3: `app/admin/log.rb`.**

```ruby
# The project log: what Stacksbot has seen about a project, at
# /admin/project_trackers/:id/log. Stacks only filters and draws rows the
# filtered Notion sync stored (Stacks::ProjectLog); every judgement in them is
# Stacksbot's. Read-only: triage stays in Notion.
#
# Who may read it: whoever may read the tracker. ActiveAdmin checks the page
# itself first (AdminAuthorization lets admins, leads and anyone holding a
# project-scoped lead grant through), then load_and_authorize_tracker checks
# this tracker, which is what limits a grantee to their own.
ActiveAdmin.register_page "Log" do
  belongs_to :project_tracker
  menu false

  controller do
    before_action :refuse_other_formats
    before_action :load_and_authorize_tracker

    # The content block is Arbre and does not see controller ivars, so the
    # two things it needs are helpers (as in app/admin/project_trackers.rb).
    helper_method :log_tracker, :project_log

    def log_tracker
      @log_tracker
    end

    # Only these four parameters are read, and each is whitelisted inside
    # Stacks::ProjectLog. A registered page runs no Ransack, so ?q and ?order
    # do nothing here.
    def project_log
      @project_log ||= Stacks::ProjectLog.new(
        @log_tracker, view: params[:view], source: params[:source], valence: params[:valence], page: params[:page]
      )
    end

    private

    # HTML only: there is no CSV, JSON or XML form of the log.
    def refuse_other_formats
      raise ActionController::UnknownFormat unless request.format&.html?
    end

    def load_and_authorize_tracker
      @log_tracker = ProjectTracker.find(params[:project_tracker_id])
      authorize! :read, @log_tracker
    end
  end

  content title: "Project Log" do
    render(partial: "show", locals: { tracker: log_tracker, log: project_log })
  end
end
```

- [ ] **Step 4: `app/views/admin/log/_empty.html.erb`** (locals `tracker`, `reason`):

```erb
<%# Why a project's log is empty, and where to fix it. Used by the log page and
    by the module on the tracker page. %>
<% can_edit = authorized?(:update, tracker) %>
<% if reason == :no_notion_project %>
  <p style="margin-bottom: 6px;">This project has no Notion project chosen, so nothing Stacksbot sees can be filed under it.</p>
  <% if can_edit %>
    <%= link_to "Choose its Notion project →", edit_admin_project_tracker_path(tracker) %>
  <% else %>
    <p>Ask a project lead or an admin to choose one.</p>
  <% end %>
<% elsif reason == :never_synced %>
  <p>Stacks has not synced Stacksbot's observations yet. The sync runs every night, so check back tomorrow.</p>
<% elsif reason == :nothing_seen %>
  <p style="margin-bottom: 6px;">Stacksbot has not filed anything under this project yet.</p>
  <% unreadable = Array(tracker.twist_channels_inaccessible).size %>
  <% if tracker.twist_channel_ids.empty? %>
    <p style="margin-bottom: 6px;">It has no Twist channel linked, and the channel is where most of what Stacksbot sees comes from.</p>
    <%= link_to "Link its Twist channel →", edit_admin_project_tracker_path(tracker) if can_edit %>
  <% elsif unreadable > 0 %>
    <p>Stacksbot is not in <%= unreadable %> of this project's Twist channels. Invite the Stacksbot account to <%= unreadable == 1 ? "it" : "them" %> in Twist and it will start reading.</p>
  <% else %>
    <p>Its Twist channel and Notion project are linked, so this fills in as Stacksbot reads them.</p>
  <% end %>
<% end %>
```

- [ ] **Step 5: `app/views/admin/log/_row.html.erb`** (local `row`, a `Stacks::ProjectLog::Row`):

```erb
<%# One observation. Everything printed here was written by a model or a
    person in Notion: it is escaped by ERB, and never passed through raw. %>
<% o = row.observation %>
<% pill_class, pill_label, grey = Stacks::ProjectLog.pill_for(row) %>
<tr id="log_row_<%= o.notion_id %>">
  <td class="col" style="white-space: nowrap; width: 1%; vertical-align: top;">
    <%# A bare .pill has no background, so the grey is set here. %>
    <span class="<%= pill_class %>" <% if grey %>style="background-color: #cfd3d7;"<% end %>
          <% if o.valence_inferred? %>title="Stacksbot has not marked this row yet. Shown as <%= o.valence %> because its type is <%= o.type %>."<% end %>><%= pill_label %></span>
  </td>
  <td class="col" style="vertical-align: top;">
    <strong><%= o.title %></strong>
    <% if o.dismissed? %><span style="font-size: 13px; color: #5E6469;"> · Dismissed</span><% end %>
    <% if o.text.present? %>
      <div style="margin-top: 4px;"><%= o.text %></div>
    <% end %>
    <% row.problems.each do |problem| %>
      <div style="margin-top: 4px; font-size: 13px; color: #5E6469;">
        Folded into <%= link_to problem.title, problem.notion_url, target: "_blank", rel: "noopener" %>
        (<%= [problem.severity, problem.status].compact.join(", ").presence || "no severity yet" %>)
      </div>
    <% end %>
  </td>
  <td class="col" style="white-space: nowrap; vertical-align: top;">
    <%= o.source || "Unknown source" %>
    <div style="font-size: 13px; color: #5E6469;"><%= o.observed_at ? o.observed_at.strftime("%b %-d, %Y") : "No date" %></div>
  </td>
  <td class="col text-right" style="white-space: nowrap; vertical-align: top;">
    <% if o.source_url %>
      <%= link_to "Source ↗", o.source_url, target: "_blank", rel: "noopener", class: "log-source" %><br>
    <% end %>
    <%= link_to "In Notion ↗", o.notion_url, target: "_blank", rel: "noopener" %>
  </td>
</tr>
```

`o.notion_url` is either a stored `http(s)` address or `NotionPage#notion_link` (`app/models/notion_page.rb:37-39`), so it is always safe to link.

- [ ] **Step 6: `app/views/admin/log/_show.html.erb`** (locals `tracker`, `log`). The modules are the Project Tracker page's, as `app/views/admin/weekly_ships/_show.html.erb:6-32` and `:66-99` use them.

```erb
<%# The project log, in the same modules as the Project Tracker page. Locals
    come from the content block in app/admin/log.rb. %>
<% reason = log.empty_reason %>
<% link_for = ->(changes) {
     admin_project_tracker_log_path(tracker, { view: (log.view unless log.view == "attention"), source: log.source, valence: log.valence }.merge(changes).compact)
   } %>

<div class="dashboard-modules table index_table index">
  <div class="dashboard-module">
    <div class="module-header">
      <p>What Stacksbot has seen</p>
      <%= link_to "#{tracker.name} →", admin_project_tracker_path(tracker) %>
    </div>
    <div class="module-body">
      <% if reason %>
        <%= render "admin/log/empty", tracker: tracker, reason: reason %>
      <% else %>
        <p style="margin-bottom: 12px;">
          <% Stacks::ProjectLog::VIEW_LABELS.each do |view, label| %>
            <%= link_to label, link_for.({ view: (view unless view == "attention") }),
                  class: "log-tab#{' current' if log.view == view}",
                  style: "margin-right: 16px;#{' font-weight: 700; text-decoration: none;' if log.view == view}" %>
          <% end %>
        </p>
        <p style="font-size: 13px; margin-bottom: 6px;">
          Source:
          <%= link_to "All", link_for.({ source: nil }), class: "log-chip#{' current' if log.source.nil?}",
                style: "margin-right: 8px;#{' font-weight: 700;' if log.source.nil?}" %>
          <% Stacks::Notion::Observation::SOURCE_GROUP_LABELS.each do |key, label| %>
            <%= link_to label, link_for.({ source: key }), class: "log-chip#{' current' if log.source == key}",
                  style: "margin-right: 8px;#{' font-weight: 700;' if log.source == key}" %>
          <% end %>
        </p>
        <p style="font-size: 13px; margin-bottom: 6px;">
          Valence:
          <%= link_to "All", link_for.({ valence: nil }), class: "log-chip#{' current' if log.valence.nil?}",
                style: "margin-right: 8px;#{' font-weight: 700;' if log.valence.nil?}" %>
          <% Stacks::ProjectLog::VALENCE_PARAMS.each do |key, label| %>
            <%= link_to label, link_for.({ valence: key }), class: "log-chip#{' current' if log.valence == key}",
                  style: "margin-right: 8px;#{' font-weight: 700;' if log.valence == key}" %>
          <% end %>
        </p>
        <p style="font-size: 13px; color: #5E6469;">
          Stacksbot writes these rows in Notion, and Stacks only shows them. Triage happens in Notion.
          <% if log.last_synced_at %>Last synced <%= time_ago_in_words(log.last_synced_at) %> ago.<% end %>
        </p>
      <% end %>
    </div>
  </div>
</div>

<% unless reason %>
  <% if log.interim_in_use? %>
    <div class="dashboard-modules table index_table index">
      <div class="dashboard-module">
        <div class="module-body">
          <p style="font-size: 13px;">Stacksbot has not marked these rows yet. Until it does, a row whose type is Risk is shown as Negative and one whose type is Win as Positive. Hover a pill to see which rows that applies to.</p>
        </div>
      </div>
    </div>
  <% end %>

  <% if log.view == "attention" && log.problems.any? %>
    <div class="dashboard-modules table index_table index">
      <div class="dashboard-module">
        <div class="module-header">
          <p>Open problems</p>
          <p><%= log.problems.size %></p>
        </div>
        <div class="module-body">
          <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
            <tbody>
              <% log.problems.each do |problem| %>
                <tr id="log_problem_<%= problem.notion_id %>">
                  <td class="col" style="white-space: nowrap; width: 1%; vertical-align: top;">
                    <% if problem.escalating? %>
                      <span class="pill error"><%= problem.severity %></span>
                    <% elsif problem.severity %>
                      <span class="pill at_risk"><%= problem.severity %></span>
                    <% else %>
                      <span class="pill" style="background-color: #cfd3d7;">No severity</span>
                    <% end %>
                  </td>
                  <td class="col" style="vertical-align: top;">
                    <strong><%= problem.title %></strong>
                    <div style="font-size: 13px; color: #5E6469;">
                      <%= problem.unowned? ? "Nobody owns it yet" : [problem.status, problem.owner_names.to_sentence.presence].compact.join(", ").presence || "No status" %>
                      <% if problem.occurrences && problem.occurrences > 1 %> · Seen <%= problem.occurrences %> times<% end %>
                      <% if problem.last_seen_at %> · Last seen <%= problem.last_seen_at.strftime("%b %-d, %Y") %><% end %>
                    </div>
                  </td>
                  <td class="col text-right" style="white-space: nowrap; vertical-align: top;">
                    <%= link_to "In Notion ↗", problem.notion_url, target: "_blank", rel: "noopener" %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  <% end %>

  <div class="dashboard-modules table index_table index">
    <div class="dashboard-module">
      <div class="module-header">
        <p><%= log.view == "attention" ? "Negative in the last #{Stacks::ProjectLog::ATTENTION_WINDOW.in_days.to_i} days" : Stacks::ProjectLog::VIEW_LABELS[log.view] %></p>
        <p><%= log.rows.size %></p>
      </div>
      <div class="module-body">
        <% if log.rows.empty? %>
          <% if log.filtered? %>
            <p style="margin-bottom: 6px;">No rows match these filters<%= " on this page" if log.page > 1 || log.older_page %>.</p>
            <%= link_to "Clear the filters →", link_for.({ source: nil, valence: nil }) %>
          <% elsif log.view == "attention" %>
            <p style="margin-bottom: 6px;">Nothing needs attention: <%= log.problems.any? ? "no" : "no open problems and no" %> negative observations in the last <%= Stacks::ProjectLog::ATTENTION_WINDOW.in_days.to_i %> days.</p>
            <%= link_to "See everything Stacksbot has seen →", link_for.({ view: "everything" }) %>
          <% elsif log.view == "highlights" %>
            <p style="margin-bottom: 6px;">Stacksbot has not marked anything here as worth a Project Lead's attention.</p>
            <%= link_to "See everything Stacksbot has seen →", link_for.({ view: "everything" }) %>
          <% else %>
            <p>There is nothing on this page.</p>
          <% end %>
        <% elsif log.view == "highlights" %>
          <% log.weeks.each do |(monday, rows)| %>
            <p class="log-week" style="font-size: 13px; font-weight: 700; color: #5E6469; margin: 12px 0 6px;">Week of <%= monday.strftime("%B %-d, %Y") %></p>
            <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
              <tbody><%= render partial: "admin/log/row", collection: rows, as: :row %></tbody>
            </table>
          <% end %>
        <% else %>
          <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
            <tbody><%= render partial: "admin/log/row", collection: log.rows, as: :row %></tbody>
          </table>
        <% end %>

        <% if log.capped? %>
          <p style="font-size: 13px; margin-top: 12px;">Showing the newest <%= Stacks::ProjectLog::ATTENTION_LIMIT %> rows of the last <%= Stacks::ProjectLog::ATTENTION_WINDOW.in_days.to_i %> days. The rest are under Everything.</p>
        <% end %>
        <% if log.newer_page || log.older_page %>
          <p style="margin-top: 12px;">
            <%= link_to "← Newer", link_for.({ page: (log.newer_page unless log.newer_page == 1) }), class: "log-newer", style: "margin-right: 16px;" if log.newer_page %>
            <%= link_to "Older →", link_for.({ page: log.older_page }), class: "log-older" if log.older_page %>
          </p>
        <% end %>
      </div>
    </div>
  </div>
<% end %>
```

Notes for the implementer:
- `link_for` drops nil values with `compact`, so the default view and an unset chip leave no parameter behind. The tests compare `href`s against `admin_project_tracker_log_path(@tracker, view: ..., source: ...)`; Rails orders query parameters alphabetically in both, so they match.
- A row in Highlights with no date is left out of `weeks` (Task 9). Every synced row has `occurred_at`, so this only affects hand-made rows.
- The `rows.empty?` text for a later page of Highlights reads "There is nothing on this page" only under Everything; under Highlights the copy above covers it. That is intended: a page of 200 stored rows may hold no gated row, and the "Older →" link still shows.

- [ ] **Step 7: Run, expect 0 failures.** Then run the neighbours that share the adapter and the tracker pages:

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/integration/admin_project_log_test.rb test/models/admin_authorization_test.rb test/integration/admin_weekly_ship_coaching_test.rb test/integration/admin_meeting_matches_test.rb
```

If "someone with no access" or the grantee's refusal returns 200, the cause is the order of the two checks: `authorize_access!` belongs to `ActiveAdmin::PageController` and runs before the `before_action`s declared in `controller do`. Do not skip it.

- [ ] **Step 8: Commit.** `feat(admin): the project log page at /admin/project_trackers/:id/log`

---

### Task 12: The module on the tracker page

**Files:** Create `app/views/admin/log/_module.html.erb`. Modify `app/admin/project_trackers.rb`, `test/integration/admin_project_log_test.rb`.

**Consumes:** `Stacks::ProjectLog.summary` (Task 9); `admin/log/_row`, `admin/log/_empty` (Task 11).

**Produces:** a `.dashboard-modules` block with `id="project_log_module"` on `/admin/project_trackers/:id`, directly above the Weekly Ships panel.

- [ ] **Step 1: Add the failing tests** to `test/integration/admin_project_log_test.rb`:

```ruby
  def log_module
    page.at_css("#project_log_module")
  end

  test "the tracker page has a module with the counts, the first three rows and a way in" do
    problem!(name: "Timeline slipping", severity: "High", status: "Open", project_ids: [@project])
    problem!(name: "Closed out", severity: "High", status: "Resolved", project_ids: [@project])
    rows = [obs!(name: "n1", valence: "Negative", salience: "High", observed_at: 1.hour.ago),
            obs!(name: "n2", valence: "Negative", salience: "Low", observed_at: 2.hours.ago),
            obs!(name: "n3", valence: "Negative", salience: "Low", observed_at: 3.hours.ago),
            obs!(name: "n4", valence: "Negative", salience: "Low", observed_at: 4.hours.ago)]
    obs!(name: "a win", valence: "Positive")
    obs!(name: "old news", valence: "Negative", observed_at: 40.days.ago)

    get admin_project_tracker_path(@tracker)
    assert_response :success
    assert log_module, "expected the log module on the tracker page"
    facts = log_module.css(".factoid").map { |f| f.text.squish }
    assert_equal ["1 Open problems", "4 Negative in the last 30 days, 1 escalated"], facts
    assert_equal rows.first(3).map { |r| "log_row_#{r.notion_id}" }, log_module.css("tr[id^='log_row_']").map { |tr| tr["id"] }
    assert_equal admin_project_tracker_log_path(@tracker), log_module.css("a").find { |a| a.text.strip == "Open the log →" }["href"]
    ships = page.css(".panel").find { |panel| panel.at_css("h3")&.text&.strip == "Weekly Ships" }
    assert_equal(-1, log_module <=> ships, "the module sits above the Weekly Ships panel")
  end

  test "the module on a tracker with no Notion project says why, and the page still renders" do
    bare, = log_tracker!(name: "Unlinked", project: nil)
    get admin_project_tracker_path(bare)
    assert_response :success
    assert_includes log_module.text, "no Notion project chosen"
    assert_empty log_module.css(".factoid")
    assert log_module.css("a").any? { |a| a["href"] == admin_project_tracker_log_path(bare) }
  end

  test "the module is useful before Valence exists" do
    obs!(name: "Budget at risk", valence: nil, valence_property: false, type: "Risk")
    get admin_project_tracker_path(@tracker)
    assert_response :success
    assert_equal "1 Negative in the last 30 days, 0 escalated", log_module.css(".factoid").last.text.squish
  end

  test "the module with rows but nothing needing attention shows zeroes, not an error" do
    obs!(name: "Routine note", valence: nil, type: "FYI")
    get admin_project_tracker_path(@tracker)
    assert_response :success
    assert_equal ["0 Open problems", "0 Negative in the last 30 days, 0 escalated"], log_module.css(".factoid").map { |f| f.text.squish }
    assert_empty log_module.css("tr[id^='log_row_']")
  end

  test "a scoped grantee sees the module on their tracker" do
    obs!(name: "Mine to read", valence: "Negative")
    trainee = scoped_grantee!
    sign_out @admin
    sign_in trainee
    get admin_project_tracker_path(@tracker)
    assert_response :success
    assert_includes log_module.text, "Mine to read"
  end

  test "the module adds the same number of queries for 1 row as for 6" do
    count = lambda do
      n = 0
      counter = ->(*, payload) { n += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { Stacks::ProjectLog.summary(@tracker) }
      n
    end
    obs!(valence: "Negative")
    one = count.call
    5.times { obs!(valence: "Negative", problem_ids: [problem!(project_ids: []).notion_id]) }
    assert_equal one + 1, count.call, "one more query at most: the problems the rows name"
    assert_operator one, :<=, 7
  end
```

- [ ] **Step 2: Run, expect the new tests to fail** (`log_module` is nil):

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/integration/admin_project_log_test.rb
```

- [ ] **Step 3: `app/views/admin/log/_module.html.erb`** (locals `tracker`, `summary`):

```erb
<%# The project log's module on the Project Tracker page: the counts and first
    rows of its "Needs attention" view (Stacks::ProjectLog.summary). %>
<div class="dashboard-modules table index_table index" id="project_log_module">
  <div class="dashboard-module">
    <div class="module-header">
      <p>What Stacksbot has seen</p>
      <%= link_to "Open the log →", admin_project_tracker_log_path(tracker) %>
    </div>
    <% if summary[:empty_reason] %>
      <div class="module-body">
        <%= render "admin/log/empty", tracker: tracker, reason: summary[:empty_reason] %>
      </div>
    <% else %>
      <%# height: the factoid body is sized for a module with no header. %>
      <div class="module-body factoid-parent" style="flex-direction: row; justify-content: space-around; height: auto; padding: 30px 20px;">
        <div class="factoid">
          <h2 class="<%= "color-red" if summary[:open_problems] > 0 %>"><%= summary[:open_problems] %></h2>
          <p>Open problems</p>
        </div>
        <div class="factoid">
          <h2 class="<%= "color-orange" if summary[:negatives] > 0 %>"><%= summary[:negatives] %><%= "+" if summary[:capped] %></h2>
          <p>Negative in the last <%= Stacks::ProjectLog::ATTENTION_WINDOW.in_days.to_i %> days, <%= summary[:escalated] %> escalated</p>
        </div>
      </div>
    <% end %>
  </div>

  <% if summary[:latest].any? %>
    <div class="dashboard-module">
      <div class="module-header">
        <p>Needs attention</p>
      </div>
      <div class="module-body">
        <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
          <tbody><%= render partial: "admin/log/row", collection: summary[:latest], as: :row %></tbody>
        </table>
      </div>
    </div>
  <% end %>
</div>
```

`color-red` and `color-orange` are the classes the tracker page already uses (`app/views/admin/project_trackers/_show.html.erb:392-398`).

- [ ] **Step 4: Render it.** In `app/admin/project_trackers.rb`, between the `render(partial: 'show', ...)` call (lines 497-499) and `panel "Weekly Ships" do` (line 501):

```ruby
    # What Stacksbot has filed under this project's Notion projects: counts,
    # the first rows, and the way into the log (app/admin/log.rb). Anyone who
    # can open this page can read the tracker, which is the log's own rule.
    render(partial: "admin/log/module", locals: { tracker: resource, summary: Stacks::ProjectLog.summary(resource) })
```

- [ ] **Step 5: Run the log tests and every test that renders the tracker page, expect 0 failures:**

```
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/integration/admin_project_log_test.rb test/integration/admin_weekly_ship_coaching_test.rb
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/integration test/models test/lib/stacks test/lib/tasks
```

A tracker-page test elsewhere that has no `System` row still passes: `FilteredSync.marks` reads `System.first&.` and the module then shows "has not synced".

- [ ] **Step 6: Commit.** `feat(admin): the project log module on the tracker page`

---

## Rollout

The coordinator does these; no task above touches production.

1. **Migration first, old code live.** Run `20261013100000_add_log_columns_to_notion_pages` on production before the PR merges. It is additive: three columns with defaults and two indexes built concurrently on a table of about 1,500 rows. The old `sync_database` writes an explicit column list and never sees them.
2. **Merge and deploy.** Nothing changes for anyone yet except that every tracker page gains the module, which reads "Stacks has not synced Stacksbot's observations yet." The nightly `stacks:sync_notion` does not start the log sync, because there is no mark.
3. **Preview.** `rake stacks:preview_notion_log_sync` prints what the first run would do: `observations.created` (expected about 800 today, more once Stacksbot attributes by channel), `problems.created` (about 24), `missing_problems.missing`, `truncated_relations` (expected 0), and `calls`. Then `rake "stacks:preview_notion_log_sync[incremental]"` proves the later runs' query (timestamp only, not yet run against production) returns 200 and shows a three-day `seen` of about 275. A rejected filter raises with Notion's status and message; nothing is written either way.
4. **First real run, by hand.** `rake stacks:sync_notion_log`. About ten query calls and at most 100 page fetches, one at a time. It writes the marks, and from that night the daily sync carries it.
5. **Check.** Open the log of a tracker that has a Notion project and attributed observations. Until Stacksbot writes Valence, expect Needs attention to hold rows of type Risk and the page to say the rule is interim.
6. **When Valence is live in Notion:** set `INTERIM_VALENCE_BY_TYPE` to `{}.freeze`, delete the three "interim" tests and the page's interim notice, and confirm the property is named `Valence`.

Tasks 1 to 8 change nothing a person can see and can merge ahead of Tasks 9 to 12 if a smaller first PR is wanted.

## Known limits

- A row trashed in Notion can stay in the log for up to five days at 1,000 rows in scope (200 rechecks a night). Raise `RECHECK_LIMIT` if that proves too slow; each recheck is one Notion call.
- The first-run query keeps the relation filter, so a mark that is lost (someone clears the setting) causes a 90-day backfill that will not notice rows which lost their Project in the gap. The recheck catches them within its cycle.
- `System` settings are one jsonb column written whole (Storext), so a mark written at the same moment as another setting could lose one of the two writes. `runn_synced_at` has the same exposure today.
- Offset paging over rows that arrive while someone pages can repeat or skip a row at a page edge.
- The Notion client's other calls (`sync_database`, `get_page`, the write helpers) still have no retry. Only the two new calls do.
