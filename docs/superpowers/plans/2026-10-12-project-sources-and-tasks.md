# Project Sources and Admin Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project tracker names its Twist channel and its Notion project, and Stacks raises an admin task when either is missing or when the Stacksbot account cannot see the channel.

**Architecture:** The Twist channel stays a `project_tracker_links` row with a strict, tidied URL. The Notion project is a new id column filled from a dropdown of synced Notion Projects pages. A daily job asks Twist which channels the Stacksbot account belongs to and stores the answer on each tracker. Two computed task types read those fields.

**Tech Stack:** Rails 6.1, ActiveAdmin 2.9 (Arbre), Minitest + Mocha, HTTParty, Postgres.

**Spec:** `docs/superpowers/specs/2026-10-12-project-log-design.md`, Parts 1 and 2.

## Global Constraints

- Work in `/Users/hhff/Documents/Code/stacks/.claude/worktrees/project-log` on branch `feat/project-sources`.
- Run tests only against the isolated database: prefix every test command with
  `DATABASE_URL=postgres://localhost/stacks_test_projectlog RAILS_ENV=test`. Never use `stacks_test` or
  `stacks_development`; other sessions are using them. Never edit `config/database.yml`.
- `db/schema.rb` is hand-edited. Never commit the output of `db:migrate` or `db:schema:dump`. Add the
  new columns to `schema.rb` by hand, in alphabetical position inside the table, and bump the version
  at the top to the new migration's timestamp. If a command rewrites `schema.rb`, `git checkout` it
  and redo the hand edit.
- Stored Twist channel shape: `https://twist.com/a/<workspace>/ch/<id>/`. `<workspace>` is
  `Stacks::Utils.config[:twist][:workspace_id]` (the Integer 133876 in production), never a literal
  in app code. Tests stub the config.
- Notion page ids are dashed, as `notion_pages.notion_id` stores them.
- No model calls. No production access. Do not push, merge or open a PR; the coordinator does that.
- Match the surrounding code's comment density and style. No em dashes in user-facing copy.
- Commit after each task with a conventional message ending in the line
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## File Structure

| File | Change |
|---|---|
| `db/migrate/20261012170000_add_project_sources_to_project_trackers.rb` | Create. Three columns. |
| `db/schema.rb` | Hand-edit: three columns, version. |
| `app/models/project_tracker_link.rb` | Tidy and validate Twist URLs; bust the task cache; clear the access answer. |
| `app/models/project_tracker.rb` | One-Twist-link rule, `twist_channel_id`, Notion project readers, access sync. |
| `lib/stacks/twist.rb` | `get_channels`. |
| `lib/stacks/notion.rb` | Add `PROJECTS` to `DATABASE_IDS`. |
| `lib/stacks/notion/project.rb` | Create. Wrapper for a Projects page: title, stage, live?, label. |
| `app/models/notion_page.rb` | `projects` scope and `as_project`. |
| `app/admin/project_trackers.rb` | Dropdown input, permit param, hint on the link URL. |
| `app/services/mcp/provisioning_serializers.rb` | `twist_channel_id`, `notion_project_id`. |
| `app/services/mcp/update_project_tracker_tool.rb` | Description of `twist_channel_url`. |
| `lib/tasks/stacks.rake` | `stacks:sync_twist_channel_access`; called at the end of `stacks:sync_notion`. |
| `lib/stacks/task_builder/discoveries/project_trackers.rb` | Two task types. |
| `app/models/stacks_task.rb` | Two labels. |
| `test/models/project_tracker_sources_test.rb` | Create. Tasks 2, 3, 4. |
| `test/lib/stacks/notion/project_test.rb` | Create. Task 3. |
| `test/lib/stacks/task_builder/discoveries/project_tracker_sources_test.rb` | Create. Task 5. |
| existing tests using `https://twist.com/a/1/ch/…` | Update (Task 2). |

---

### Task 1: Columns

**Files:** Create the migration; modify `db/schema.rb`.

**Produces:** `project_trackers.notion_project_id` (string, null), `twist_channel_accessible` (boolean, null), `twist_channel_checked_at` (datetime, null).

- [ ] **Step 1: Create the test database** (once)

```bash
DATABASE_URL=postgres://localhost/stacks_test_projectlog RAILS_ENV=test bin/rails db:create db:schema:load
git status --short db/schema.rb   # must print nothing; if it prints, git checkout db/schema.rb
```

- [ ] **Step 2: Write the migration**

```ruby
# db/migrate/20261012170000_add_project_sources_to_project_trackers.rb
# Where a project's conversation lives, for the project log:
# the Notion Projects page it belongs to, and whether the Stacksbot Twist
# account can see the tracker's Twist channel (nil = not checked yet).
class AddProjectSourcesToProjectTrackers < ActiveRecord::Migration[6.1]
  def change
    add_column :project_trackers, :notion_project_id, :string
    add_column :project_trackers, :twist_channel_accessible, :boolean
    add_column :project_trackers, :twist_channel_checked_at, :datetime
    add_index :project_trackers, :notion_project_id
  end
end
```

- [ ] **Step 3: Hand-edit `db/schema.rb`**: add the three `t.` lines inside `create_table "project_trackers"` in alphabetical position, the `t.index ["notion_project_id"], name: "index_project_trackers_on_notion_project_id"` line with the table's other indexes, and set `ActiveRecord::Schema.define(version: 2026_10_12_170000)`. Check the existing version first: if it is already higher, keep the higher one and rename the migration to a timestamp above it.

- [ ] **Step 4: Load and verify**

```bash
DATABASE_URL=postgres://localhost/stacks_test_projectlog RAILS_ENV=test bin/rails db:schema:load
DATABASE_URL=postgres://localhost/stacks_test_projectlog RAILS_ENV=test bin/rails runner 'puts ProjectTracker.column_names.grep(/notion_project_id|twist_channel/).sort.inspect'
git diff --stat db/schema.rb   # only the lines you added
```
Expected: `["notion_project_id", "twist_channel_accessible", "twist_channel_checked_at"]`.

- [ ] **Step 5: Commit** `feat(project-trackers): columns for the Notion project and Twist channel access`.

---

### Task 2: One tidy Twist channel link per tracker

**Files:** `app/models/project_tracker_link.rb`, `app/models/project_tracker.rb`, `app/admin/project_trackers.rb` (hint only), `app/services/mcp/update_project_tracker_tool.rb` (description only), `test/models/project_tracker_sources_test.rb`, and the existing tests listed in Step 5.

**Produces:**
- `ProjectTrackerLink.twist_channel_url(id)` → `"https://twist.com/a/<workspace>/ch/<id>/"`
- `ProjectTrackerLink::TWIST_CHANNEL_SHAPE` (the message text shown to people)
- `ProjectTracker#twist_channel_id` → Integer or nil
- Changing, adding or destroying a `twist_channel` link sets the tracker's `twist_channel_accessible` and `twist_channel_checked_at` to nil.

- [ ] **Step 1: Write failing tests** in `test/models/project_tracker_sources_test.rb`. Build trackers the way `test/models/project_tracker_monthly_budget_test.rb` does (read it first for the helper that makes a valid tracker with MSA and SOW links). Stub the workspace with `Stacks::Utils.stubs(:config).returns(twist: { workspace_id: 133876, token: "x" })`, merged over whatever keys the code under test reads; if other config keys are needed, wrap the real config: `real = Stacks::Utils.config; Stacks::Utils.stubs(:config).returns(real.merge(twist: {...}))`.

Tests, each its own `test "..."`:
  1. `"https://twist.com/a/133876/ch/794756/"` saves unchanged and `twist_channel_id == 794756`.
  2. `"https://twist.com/a/133876/ch/794756"` (no slash) is saved as the canonical URL.
  3. A thread URL `"https://twist.com/a/133876/ch/355509/t/6877281/"` is saved as `".../ch/355509/"`.
  4. A comment URL `"https://twist.com/a/133876/ch/355509/t/6877281/c/9/"` and a URL with a query string are cut back the same way.
  5. Wrong workspace `"https://twist.com/a/1/ch/2/"` is invalid; the error on the link's `url` is `"must be a Twist channel in our workspace, like https://twist.com/a/133876/ch/794756/"`.
  6. `"https://example.com/a/133876/ch/2/"`, `"http://twist.com/a/133876/ch/2/"` (not https), `"https://twist.com/a/133876/ch/abc/"` and `"https://twist.com/a/133876/"` are each invalid.
  7. A link of another type (`sow`) with a twist-looking or any https URL is untouched by the tidy step.
  8. A tracker with two `twist_channel` links is invalid: base error `"A project can have only one Twist channel link."`
  9. Replacing in one save works: `tracker.update!(project_tracker_links_attributes: [{ id: old.id, _destroy: "1" }, { name: "Twist Channel", link_type: "twist_channel", url: new_url }])` succeeds and leaves one link.
  10. `tracker.twist_channel_id` is nil with no Twist link.
  11. Given `tracker.update_columns(twist_channel_accessible: false, twist_channel_checked_at: Time.zone.now)`: changing the link's URL, destroying the link, and adding a link each reset both columns to nil (three assertions, reload the tracker each time).
  12. Editing a non-Twist link leaves the two columns as they were.
  13. `ProjectTrackerLink` includes `BustsTaskCache`: `Stacks::TaskBuilder.expects(:clear_cache!).at_least_once` around a link `update!`.

- [ ] **Step 2: Run, expect failures**

```bash
DATABASE_URL=postgres://localhost/stacks_test_projectlog RAILS_ENV=test bin/rails test test/models/project_tracker_sources_test.rb
```

- [ ] **Step 3: Implement in `app/models/project_tracker_link.rb`**

```ruby
  include BustsTaskCache

  # The one shape a Twist channel link is stored in. People paste what the
  # browser shows (a thread, a comment, no trailing slash), so the link is cut
  # back to its channel before it is checked.
  TWIST_CHANNEL_PATH = %r{\A/a/(\d+)/ch/(\d+)(?:/.*)?\z}

  def self.twist_workspace_id
    Stacks::Utils.config[:twist][:workspace_id].to_s
  end

  def self.twist_channel_url(channel_id)
    "https://twist.com/a/#{twist_workspace_id}/ch/#{channel_id}/"
  end

  def self.twist_channel_shape
    "must be a Twist channel in our workspace, like #{twist_channel_url(794756)}"
  end

  before_validation :tidy_twist_channel_url, if: :twist_channel?
  validate :url_is_our_twist_channel, if: :twist_channel?
  after_commit :forget_twist_channel_access, if: :twist_channel?

  # The channel id, or nil when this is not a well-formed channel link.
  def twist_channel_id
    return nil unless twist_channel?
    m = url.to_s.match(%r{\Ahttps://twist\.com/a/#{Regexp.escape(self.class.twist_workspace_id)}/ch/(\d+)/\z})
    m && m[1].to_i
  end
```

and privately:

```ruby
  def tidy_twist_channel_url
    parsed = URI.parse(url.to_s) rescue nil
    return unless parsed.is_a?(URI::HTTPS) && parsed.host == "twist.com" && parsed.userinfo.nil?
    m = parsed.path.to_s.match(TWIST_CHANNEL_PATH)
    return unless m && m[1] == self.class.twist_workspace_id
    self.url = self.class.twist_channel_url(m[2])
  end

  def url_is_our_twist_channel
    errors.add(:url, self.class.twist_channel_shape) if twist_channel_id.nil?
  end

  # The stored answer was about the old link. (update_columns: no callbacks,
  # no validations; the tracker may be mid-destroy.)
  def forget_twist_channel_access
    return unless destroyed? || saved_change_to_url? || saved_change_to_link_type? || saved_change_to_id?
    ProjectTracker.where(id: project_tracker_id).update_all(twist_channel_accessible: nil, twist_channel_checked_at: nil)
  end
```

Keep `TWIST_CHANNEL_SHAPE` out: the message depends on config, so it is the class method `twist_channel_shape` (update the Produces line in your head; later tasks use the method). The existing `url_is_plain_http` validation stays and still runs.

A link that changes type away from `twist_channel` must also forget the answer: make the `after_commit` condition `-> { twist_channel? || saved_change_to_link_type? }`.

- [ ] **Step 4: Implement in `app/models/project_tracker.rb`**

Add near the other validations:

```ruby
  validate :at_most_one_twist_channel_link
```

and, with the other link helpers:

```ruby
  # The id of this project's Twist channel, from its twist_channel link.
  def twist_channel_id
    project_tracker_links.find(&:twist_channel?)&.twist_channel_id
  end

  # Checked on the tracker, over links not marked for removal, so replacing
  # the link in one form submit is not refused.
  private def at_most_one_twist_channel_link
    live = project_tracker_links.reject(&:marked_for_destruction?).select(&:twist_channel?)
    errors.add(:base, "A project can have only one Twist channel link.") if live.size > 1
  end
```

In `app/admin/project_trackers.rb`, give the link URL input a hint: `hint: "For a Twist channel, paste the channel's link, like #{ProjectTrackerLink.twist_channel_url(794756)}"`, wrapped so a missing Twist config in test does not raise at load (compute it inside the `form do |f|` block, not at file load). In `app/services/mcp/update_project_tracker_tool.rb`, extend the `twist_channel_url` description with: `Must be the channel's link in our Twist workspace (https://twist.com/a/<workspace>/ch/<id>/); a thread link is cut back to its channel.`

- [ ] **Step 5: Fix the existing tests that use the old fake URLs.** `grep -rn "twist.com/a/" test/` and update every site (the review found `test/models/project_tracker_monthly_budget_test.rb` lines 74, 79, 111, 218 and `test/services/mcp/weekly_ship_tools_test.rb` lines 163, 224, 233) to `https://twist.com/a/133876/ch/<n>/`, stubbing the workspace config in those tests' setup if the test config has a different workspace id. First check what the test config holds: `DATABASE_URL=… RAILS_ENV=test bin/rails runner 'p Stacks::Utils.config[:twist]'`. If it already says 133876, no stub is needed anywhere and the new test file should not stub either.

- [ ] **Step 6: Run the new file and the two touched files; all pass.**

```bash
DATABASE_URL=postgres://localhost/stacks_test_projectlog RAILS_ENV=test bin/rails test test/models/project_tracker_sources_test.rb test/models/project_tracker_monthly_budget_test.rb test/services/mcp
```

- [ ] **Step 7: Commit** `feat(project-trackers): one tidy Twist channel link per tracker`.

---

### Task 3: The Notion project

**Files:** `lib/stacks/notion.rb`, `lib/stacks/notion/project.rb` (create), `app/models/notion_page.rb`, `app/models/project_tracker.rb`, `app/admin/project_trackers.rb`, `app/services/mcp/provisioning_serializers.rb`, `test/lib/stacks/notion/project_test.rb` (create), `test/models/project_tracker_sources_test.rb`.

**Produces:**
- `Stacks::Notion::DATABASE_IDS[:PROJECTS] == "713b28db4f8a45c68126e9723c65349e"`
- `NotionPage.projects` (scope), `NotionPage#as_project`
- `Stacks::Notion::Project`: `#title`, `#stage`, `#live?(now = Time.zone.now)`, `#label`, `.options_for(tracker)`
- `ProjectTracker#notion_project` → `Stacks::Notion::Project` or nil; `ProjectTracker#notion_project_linked?`

- [ ] **Step 1: Read the patterns.** `lib/stacks/notion/lead.rb`, `lib/stacks/notion/base.rb`, `app/models/notion_page.rb`, `test/lib/stacks/notion/lead_test.rb`. A stored page is the raw Notion API page object in `notion_pages.data`; a select property looks like `{"type"=>"select","select"=>{"name"=>"Active"}}`, a checkbox like `{"type"=>"checkbox","checkbox"=>true}`, and the page's own `"last_edited_time"` is a top-level ISO string. `notion_pages` is soft-deleted (`with_deleted`, `deleted_at`).

- [ ] **Step 2: Failing tests** in `test/lib/stacks/notion/project_test.rb`. Helper:

```ruby
  PROJECTS_PARENT = Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:PROJECTS])

  def page!(title:, stage:, duplicated: false, edited: Time.zone.now, deleted: false)
    np = NotionPage.create!(
      notion_id: SecureRandom.uuid, notion_parent_type: "database_id", notion_parent_id: PROJECTS_PARENT,
      page_title: title,
      data: { "last_edited_time" => edited.iso8601,
              "properties" => { "Stage" => { "type" => "select", "select" => stage && { "name" => stage } },
                                "🔴 Duplicated" => { "type" => "checkbox", "checkbox" => duplicated } } }
    )
    np.destroy if deleted
    np
  end
```

(Check `NotionPage`'s required columns in `db/schema.rb` and adjust the helper if `create!` needs more.) Tests:
  1. `live?` is true for each of the eleven stages: Active, Ongoing/Maintenance, Upcoming/Legal Review, On Hold, Paused, Project Capsule Needed, Introduction, Pre-proposal Questions Needed, Proposal Needed, Proposal Sent, Following Up.
  2. `live?` is false for `"Passed"`, for a nil stage, and for `"Completed"` edited 91 days ago; true for `"Completed"` edited 89 days ago.
  3. A page ticked Duplicated is not live whatever its stage.
  4. `label` is `"Harvey · Active"`; with no stage, `"Harvey"`.
  5. `Project.options_for(tracker)` returns `[label, notion_id]` pairs for live pages only, sorted by label, case-insensitively.
  6. A tracker whose `notion_project_id` points at a non-live page (stage Passed) gets that page added to its options.
  7. A tracker whose page was removed (`deleted: true`) gets an extra option `["<title> (removed from Notion)", id]`; a tracker whose id matches no row at all gets `["Unknown page (removed from Notion)", id]`.
  8. A Lead page (different parent) never appears.

In `test/models/project_tracker_sources_test.rb` add:
  9. `notion_project_linked?` is false when the id is blank, false when the page was removed, true when the page exists (any stage).
  10. `notion_project` returns a `Stacks::Notion::Project` whose `title` is the page's.
  11. The MCP serializer (`Mcp::ProvisioningSerializers`, read it for its entry method) includes `twist_channel_id: 794756` and `notion_project_id: "<dashed id>"`, and nil for both on a bare tracker.

- [ ] **Step 3: Implement.**

`lib/stacks/notion.rb`: add `PROJECTS: "713b28db4f8a45c68126e9723c65349e"` to `DATABASE_IDS` with a comment: `# Projects: a tracker picks its page from these (app/admin/project_trackers.rb).` The nightly `stacks:sync_notion` iterates `DATABASE_IDS.values`, so nothing else is needed for the sync.

`app/models/notion_page.rb`: mirror the `lead` scope/`as_lead` pair with `scope :projects` and `def as_project`.

`lib/stacks/notion/project.rb`:

```ruby
# Wraps a NotionPage row from the Notion Projects database. A project tracker
# names one of these as its project (project_trackers.notion_project_id), and
# that is how Stacksbot's observations find their way to a tracker.
class Stacks::Notion::Project < Stacks::Notion::Base
  # Stages that are live work or live pipeline. Copied from Stacksbot's
  # LIVE_STAGES (scripts/entities/registry.mjs) so the two agree on which
  # projects exist; change them together.
  LIVE_STAGES = [
    "Active", "Ongoing/Maintenance", "Upcoming/Legal Review", "On Hold", "Paused",
    "Project Capsule Needed", "Introduction", "Pre-proposal Questions Needed",
    "Proposal Needed", "Proposal Sent", "Following Up",
  ].freeze
  RECENTLY_COMPLETED = 90.days

  def title
    notion_page.page_title.presence || "Untitled"
  end

  def stage
    notion_page.data.dig("properties", "Stage", "select", "name")
  end

  def duplicated?
    notion_page.data.dig("properties", "🔴 Duplicated", "checkbox") == true
  end

  def live?(now = Time.zone.now)
    return false if duplicated?
    return true if LIVE_STAGES.include?(stage)
    edited = Time.zone.parse(notion_page.data["last_edited_time"].to_s) rescue nil
    stage == "Completed" && edited.present? && edited >= now - RECENTLY_COMPLETED
  end

  # Titles repeat among live projects, so the stage is part of the label.
  def label
    [title, stage].compact.join(" · ")
  end

  # [label, notion_id] pairs for the tracker form: every live project, plus
  # whatever this tracker already points at, so saving the form never drops it.
  def self.options_for(tracker)
    options = NotionPage.projects.map(&:as_project).select(&:live?).map { |p| [p.label, p.notion_id] }
    current = tracker.notion_project_id.presence
    if current && options.none? { |(_, id)| id == current }
      page = NotionPage.with_deleted.projects.find_by(notion_id: current)
      options << if page.nil?
        ["Unknown page (removed from Notion)", current]
      elsif page.deleted?
        ["#{page.as_project.title} (removed from Notion)", current]
      else
        [page.as_project.label, current]
      end
    end
    options.sort_by { |(label, _)| label.downcase }
  end
end
```

Confirm how `Stacks::Notion::Base` exposes `notion_id` (it delegates unknown methods to the page) and that `NotionPage.with_deleted.projects` composes; adjust to what the code supports.

`app/models/project_tracker.rb`:

```ruby
  # The Notion Projects page this tracker belongs to, or nil when none is
  # chosen or the page has since been removed from Notion.
  def notion_project
    return nil if notion_project_id.blank?
    NotionPage.projects.find_by(notion_id: notion_project_id)&.as_project
  end

  def notion_project_linked?
    notion_project.present?
  end
```

`app/admin/project_trackers.rb`: add `:notion_project_id` to `permit_params`; in the form, directly above the `f.has_many :project_tracker_links` block:

```ruby
        f.input :notion_project_id,
          as: :select,
          label: "Notion Project",
          collection: Stacks::Notion::Project.options_for(f.object),
          include_blank: "No Notion project",
          hint: "This project's page in the Notion Projects database. Stacksbot files what it sees about a project under that page."
```

Place it inside the same `f.inputs` block as the neighbouring fields so it renders with them (read the form's structure first).

`app/services/mcp/provisioning_serializers.rb`: add after `links:`:

```ruby
        # The project's Twist channel and Notion Projects page, by id, so
        # Stacksbot attributes what it sees by place instead of by name.
        twist_channel_id: tracker.twist_channel_id,
        notion_project_id: tracker.notion_project_id.presence,
```

- [ ] **Step 4: An admin form test.** In `test/integration/` find the existing project tracker admin test (`admin_project_tracker_show_test.rb` or the nearest that signs in an admin and GETs a tracker page) and add to a new file `test/integration/admin_project_tracker_sources_test.rb`: GET `edit_admin_project_tracker_path(tracker)` → 200, the select `#project_tracker_notion_project_id` lists a live page's label and not a Passed page's; PATCH with `project_tracker: { notion_project_id: page.notion_id }` saves it. The PATCH must also satisfy the tracker's own validations (MSA and SOW links exist on the fixture tracker).

- [ ] **Step 5: Run** the three test files plus `test/lib/stacks/notion`; all pass. **Commit** `feat(project-trackers): choose the project's Notion page from a dropdown`.

---

### Task 4: Can the Stacksbot account see the channel?

**Files:** `lib/stacks/twist.rb`, `app/models/project_tracker.rb`, `lib/tasks/stacks.rake`, `test/models/project_tracker_sources_test.rb`, `test/lib/tasks/` (a rake test beside `etl_rake_test.rb`, following its pattern).

**Produces:**
- `Stacks::Twist#get_channels` → HTTParty response for `GET /channels/get?workspace_id=<workspace>`; a 200 body is an Array of channel hashes with integer `"id"`.
- `ProjectTracker.sync_twist_channel_access!(twist: Stacks::Twist.new, now: Time.zone.now)` → `{ checked: n, accessible: n, inaccessible: n }`; raises `Stacks::Twist::Error` (define it: `class Error < StandardError; end` inside `Stacks::Twist`) when the response is not a 200 Array.
- Rake `stacks:sync_twist_channel_access`.

- [ ] **Step 1: Failing tests.** Use a fake: `fake = stub(get_channels: stub(code: 200, parsed_response: [{ "id" => 794756 }, { "id" => 11 }]))`.
  1. A tracker with channel 794756 gets `twist_channel_accessible == true` and `twist_channel_checked_at` set; a tracker with channel 5 gets `false`; a tracker with no Twist link is untouched (both nil). The return value is `{ checked: 2, accessible: 1, inaccessible: 1 }`.
  2. Completed trackers (`work_completed_at` set) are skipped.
  3. A 500, or a 200 whose body is a Hash (Twist's error shape), raises `Stacks::Twist::Error` and changes no tracker (a tracker previously `true` stays `true` with its old timestamp).
  4. Writing the answer does not run tracker validations or bust nothing it should not: use `update_columns`, and assert a tracker that is otherwise invalid (no MSA link) is still updated.
  5. Rake test: `Rake::Task['stacks:sync_twist_channel_access']` creates a `SystemTask` named `stacks:sync_twist_channel_access`, marks success on a clean run and error when `sync_twist_channel_access!` raises. Follow `test/lib/tasks/etl_rake_test.rb` exactly for how rake tasks are loaded and re-enabled.
  6. After the answers are written, the task cache is cleared once: `Stacks::TaskBuilder.expects(:clear_cache!).once`.

- [ ] **Step 2: Implement.**

`lib/stacks/twist.rb`:

```ruby
  class Error < StandardError; end

  # Every channel the token's account (Stacksbot) belongs to.
  def get_channels
    self.class.get("/channels/get", {
      headers: @headers,
      query: { workspace_id: Stacks::Utils.config[:twist][:workspace_id] }
    })
  end
```

`app/models/project_tracker.rb`:

```ruby
  # Stacks's Twist token is the Stacksbot account, so the channels it belongs
  # to are the channels Stacksbot can read. Records, per open tracker with a
  # Twist link, whether its channel is one of them. A failed call changes
  # nothing: an old answer is better than a wrong one.
  def self.sync_twist_channel_access!(twist: Stacks::Twist.new, now: Time.zone.now)
    response = twist.get_channels
    unless response.code == 200 && response.parsed_response.is_a?(Array)
      raise Stacks::Twist::Error, "Twist channels/get failed (#{response.code})"
    end
    member_ids = response.parsed_response.map { |c| c["id"].to_i }.to_set
    stats = { checked: 0, accessible: 0, inaccessible: 0 }
    where(work_completed_at: nil).includes(:project_tracker_links).find_each do |tracker|
      channel_id = tracker.twist_channel_id
      next if channel_id.nil?
      accessible = member_ids.include?(channel_id)
      tracker.update_columns(twist_channel_accessible: accessible, twist_channel_checked_at: now)
      stats[:checked] += 1
      stats[accessible ? :accessible : :inaccessible] += 1
    end
    Stacks::TaskBuilder.clear_cache!
    stats
  end
```

`lib/tasks/stacks.rake`, beside `sync_notion`, following its `SystemTask` pattern exactly (read it):

```ruby
  desc "Record which project Twist channels the Stacksbot account can see"
  task :sync_twist_channel_access => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_twist_channel_access")
    begin
      stats = ProjectTracker.sync_twist_channel_access!
      Rails.logger.info("[sync_twist_channel_access] #{stats.inspect}")
      system_task.mark_as_success
    rescue => e
      system_task.mark_as_error(e)
    end
  end
```

And at the very end of the `sync_notion` task body, after its own success/error handling, so the daily schedule that already runs `sync_notion` also runs the check without a scheduler change:

```ruby
    # Rides on this daily task so no scheduler entry is needed.
    Rake::Task["stacks:sync_twist_channel_access"].invoke
```

Read `sync_notion` first: place the invoke where an error inside `sync_notion` does not skip it and where its own error cannot change `sync_notion`'s recorded outcome (it has its own SystemTask and rescue).

- [ ] **Step 3: Run; all pass. Commit** `feat(project-trackers): record whether Stacksbot can see each project's Twist channel`.

---

### Task 5: The two admin tasks

**Files:** `lib/stacks/task_builder/discoveries/project_trackers.rb`, `app/models/stacks_task.rb`, `test/lib/stacks/task_builder/discoveries/project_tracker_sources_test.rb` (create).

**Consumes:** `ProjectTracker#twist_channel_id`, `#notion_project_linked?`, `twist_channel_accessible`, `ProjectTracker.in_progress`, `#internal_client?`.

**Produces:** task types `:project_sources_not_linked` and `:stacksbot_not_in_twist_channel`.

- [ ] **Step 1: Read** `lib/stacks/task_builder/discoveries/project_trackers.rb`, `lib/stacks/task_builder/discoveries/base.rb`, `app/models/stacks_task.rb` (including `subject_url` and any per-type branches), and an existing discovery test under `test/lib/stacks/task_builder/discoveries/` for how trackers, leads and the builder are set up.

- [ ] **Step 2: Failing tests.** `ProjectTracker.in_progress` depends on snapshot data; do not build that state by hand. Stub the membership: the discovery will call a single private method `in_progress_ids` (returns a Set of ids); in tests stub it with `Stacks::TaskBuilder::Discoveries::ProjectTrackers.any_instance.stubs(:in_progress_ids).returns(Set[tracker.id])`. Add one unstubbed test that asserts `in_progress_ids` equals `ProjectTracker.in_progress.pluck(:id).to_set`.
  1. An in-progress tracker with neither link raises exactly one `:project_sources_not_linked` task (not two).
  2. With a Twist link but no Notion project: still one task. With a Notion project but no Twist link: one task. With both: none.
  3. A tracker whose Notion page was removed (soft-deleted NotionPage) raises the task again.
  4. Not raised when the tracker is not in `in_progress_ids`, when `work_completed_at` is set, or when `internal_client?` is true (stub `internal_client?`).
  5. Owners are the current project leads; with none, the task falls to admins (assert through the same route the existing tests use for `:no_project_lead_set`).
  6. `:stacksbot_not_in_twist_channel` is raised only when `twist_channel_accessible == false` and the tracker has a Twist link; not when nil, not when true. Its owners are admins (empty owners → Base falls back).
  7. Same exemptions as 4 for the second task.
  8. Labels: `StacksTask::HUMANIZED_TYPES[:project_sources_not_linked] == "Project tracker needs its Twist channel and Notion project linked"` and `[:stacksbot_not_in_twist_channel] == "Stacksbot needs inviting to this project's Twist channel"`.
  9. Both tasks' `subject_url` is the tracker's admin path (whatever existing tracker tasks return).

- [ ] **Step 3: Implement.** In `issues_for(pt)`, inside the `pt.work_completed_at.nil?` branch:

```ruby
            # The project log reads what Stacksbot sees in the project's Twist
            # channel and files it under the project's Notion page. Asked only
            # of live client work: a dormant tracker has nothing to watch.
            if in_progress_ids.include?(pt.id) && !pt.internal_client?
              out << :project_sources_not_linked if pt.twist_channel_id.nil? || !notion_project_ids.include?(pt.notion_project_id)
              out << :stacksbot_not_in_twist_channel if pt.twist_channel_id.present? && pt.twist_channel_accessible == false
            end
```

with private memoised helpers so the discovery stays free of per-tracker queries:

```ruby
        def in_progress_ids
          @in_progress_ids ||= ProjectTracker.in_progress.pluck(:id).to_set
        end

        # Ids of Notion Projects pages that still exist (the sync soft-deletes
        # a page removed from Notion).
        def notion_project_ids
          @notion_project_ids ||= NotionPage.projects.pluck(:notion_id).to_set
        end
```

Add `:project_tracker_links` to the discovery's `includes`. In `owners_for`: `:project_sources_not_linked` → `pt.current_project_leads`; `:stacksbot_not_in_twist_channel` → `[]` with the comment `# Admins manage Twist membership.` Add the two labels to `HUMANIZED_TYPES` under `# ProjectTracker issues`.

Note `notion_project_ids.include?(nil)` is false, which is the wanted answer for a blank id.

- [ ] **Step 4: Run the whole affected set; all pass.**

```bash
DATABASE_URL=postgres://localhost/stacks_test_projectlog RAILS_ENV=test bin/rails test test/models test/lib/stacks test/lib/tasks test/services/mcp test/integration
```
Report the totals line. If anything outside this plan's files fails, check whether it also fails on `origin/main` before touching it, and report it rather than fixing unrelated failures.

- [ ] **Step 5: Commit** `feat(tasks): ask for a project's Twist channel and Notion project, and for Stacksbot's invite`.

---

## Amendments after the plan review (these override anything above)

0. **Never read, decrypt or print credentials.** Do not open `config/credentials.yml.enc`, `config/master.key`, or print any value from `Stacks::Utils.config` or `ENV`. If you need to know whether a config key exists, the facts are here: in the test environment `Stacks::Utils.config[:twist][:workspace_id]` is the Integer `133876` and a token is present.
1. **No config stubs.** Because the test config already has workspace `133876`, do not stub `Stacks::Utils.config` anywhere (a bare stub would drop every other key). Ignore the stub instructions in Task 2 Steps 1 and 5.
2. **Task 2 callbacks.** Declare `before_validation :tidy_twist_channel_url` *below* the existing strip `before_validation`, so a padded URL is stripped first. The final callback line is
   `after_commit :forget_twist_channel_access, if: -> { twist_channel? || saved_change_to_link_type? }`.
   There is no `TWIST_CHANNEL_SHAPE` constant; the message comes from the class method `twist_channel_shape`.
3. **Task 2 existing tests.** Also update `test/services/mcp/weekly_ship_tools_test.rb` around line 175 (it asserts the exact links array) and `test/models/project_tracker_monthly_budget_test.rb` lines 111-112 (the strip test now expects the canonical URL with a trailing slash).
4. **Notion property names are confirmed** against a live page (2026-10-12): `Stage` is a `select` (values seen include Active, Completed, Upcoming/Legal Review, Ongoing/Maintenance, Proposal Sent, Introduction, Lost/Stale, Passed, Pre-proposal Questions Needed, Proposal Needed, Following Up, and none), `🔴 Duplicated` is a `checkbox`, the page object has a top-level `last_edited_time`, and the title property is named `reactor` (use `page_title`, which the sync fills). Other stage-like properties exist on old rows (`Stage (New)`, `Status`); ignore them.
5. **Soft delete gem** is `acts_as_paranoid`, not paranoia. `with_deleted`, `deleted?` and a soft `destroy` all work as the plan uses them.
6. **Task 3 Step 4** has no fixture tracker to lean on. Build the tracker in the test with the `tracker!` and `with_links!` helpers copied from `test/models/project_tracker_monthly_budget_test.rb:4-14`. No existing test renders the tracker edit form, so expect to fix render surprises; if the edit page cannot be made to render in test for reasons unrelated to this change, test the PATCH only and report it.
7. **Task 4 rake tests must not touch Twist.** `SystemTask#mark_as_error` posts to a real Twist thread through `Stacks::Notifications.report_exception`, and the default `Stacks::Twist.new` would call the real API. In the rake tests stub `ProjectTracker.stubs(:sync_twist_channel_access!)` (returning stats, or raising) and `Stacks::Notifications.stubs(:report_exception).returns(stub(record: nil))`, following `test/lib/tasks/daily_enterprise_tasks_rake_test.rb:24`. Model tests pass a fake `twist:`; none may construct a real client call.
8. **Task 4 placement.** In `lib/tasks/stacks.rake`, `sync_notion` is known to run daily in production (its SystemTask rows show a run every day at 20:30 UTC). Put two lines after the `end` that closes its `begin/rescue` (about line 427), in this order:
   `Stacks::TaskBuilder.clear_cache!` (the sync soft-deletes pages without callbacks, so a removed Notion page would otherwise not re-raise its task for up to 24 hours), then `Rake::Task["stacks:sync_twist_channel_access"].invoke`. Wrap the `clear_cache!` in `rescue => e` with a log line so a cache failure cannot stop the Twist check. Add a rake test that `sync_notion` (with `Stacks::Notion` stubbed so no network call happens) invokes the Twist task; remember to `reenable` both tasks in tests.
9. **Task 5 preloads.** Use `{ forecast_projects: :forecast_client }` in the discovery's `includes` (replacing the bare `:forecast_projects`), plus `:project_tracker_links`, because `internal_client?` reads each project's client.
10. **Task 5 label.** The second label is `"Stacksbot needs inviting to this project's Twist channel"` (the subject-first pattern the other labels use). Update the spec's Part 2 table to say the same.
11. **Hand-off note for the coordinator** (do not act on it): this PR has a migration; it is run on production before the PR is merged.
