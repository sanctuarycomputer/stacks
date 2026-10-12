# Meeting Matcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stacks matches each recent Google Meet meeting to the project tracker(s) it was about, with a confidence and a reason, and tells Stacksbot the result over MCP.

**Architecture:** A nightly matcher modelled on the weekly ship sweep makes one cheap model call per meeting. The match belongs to the `Meeting` (which owns the transcript and the Gemini notes documents), stored in a link table with a scan record beside it. A person can correct a match on a new admin page, and a corrected meeting is never rematched.

**Tech Stack:** Rails 6.1, ActiveAdmin 2.9 (Arbre), Minitest + Mocha, `Stacks::AI.extract` (Anthropic, fast model), Postgres.

**Spec:** `docs/superpowers/specs/2026-10-12-project-log-design.md` Part 3a (on branch `feat/project-sources`; the relevant text is repeated here, so this plan stands alone).

## Global Constraints

- Work in `/Users/hhff/Documents/Code/stacks/.claude/worktrees/meeting-matcher` on branch `feat/meeting-matcher`.
- Run tests only against the isolated database: prefix every test command with
  `DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test`. Never use `stacks_test`
  or `stacks_development`. Never edit `config/database.yml`.
- `db/schema.rb` is hand-edited (pgvector is left out on purpose). Never commit the output of
  `db:migrate` or `db:schema:dump`. Add the two tables by hand in alphabetical position, add their
  foreign keys with the others at the bottom, and bump the version. If a command rewrites
  `schema.rb`, `git checkout` it and redo the hand edit.
- Tests never call a model: stub `Stacks::AI.extract` and `Stacks::AI.configured?`, as
  `test/lib/stacks/weekly_ships/sweep_test.rb` does.
- Text from a document that is not corpus-eligible is never put in a prompt, an MCP response or the
  admin page.
- The rationale is never returned over MCP.
- No production access. Do not push, merge or open a PR; the coordinator does that.
- Match the surrounding code's comment density and style. No em dashes in user-facing copy.
- Commit after each task with a conventional message ending in the line
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Read first (patterns to copy)

- `lib/stacks/weekly_ships/sweep.rb` and `test/lib/stacks/weekly_ships/sweep_test.rb`: the matcher.
- `lib/stacks/weekly_ships/grader.rb` (`enabled?`, `run!(dry_run:, limit:)`): the switch and dry run.
- `app/models/weekly_ship.rb` (`via_sweep`, the human-lock callbacks) and `app/models/ship_scan.rb`.
- `app/admin/ship_scans.rb` and `app/admin/weekly_ships.rb`: the review page and link CRUD.
- `app/models/document.rb` (`corpus_eligible`, `source_record`), `app/models/meeting.rb`.
- `lib/tasks/etl.rake` (`match_weekly_ships`, `sync_all`, `grade_weekly_ships_preview`) and
  `test/lib/tasks/etl_rake_test.rb`.
- `app/services/mcp/list_documents_tool.rb`, `get_document_tool.rb` and their tests under
  `test/services/mcp/`.

## File Structure

| File | Change |
|---|---|
| `db/migrate/20261012180000_create_meeting_project_matches.rb` | Create. Two tables. |
| `db/schema.rb` | Hand-edit. |
| `app/models/meeting_project_tracker.rb` | Create. The link, with the human lock. |
| `app/models/meeting_project_scan.rb` | Create. One per meeting. |
| `app/models/meeting.rb` | Associations, `eligible_documents`, `eligible_content_hash`. |
| `app/models/project_tracker.rb` | `has_many :meeting_project_trackers`, `matcher_people_names`. |
| `lib/stacks/meetings/project_matcher.rb` | Create. The matcher. |
| `lib/tasks/etl.rake` | `match_meetings`, `match_meetings_preview`, added to `sync_all`. |
| `app/services/mcp/list_documents_tool.rb`, `get_document_tool.rb` | `project_tracker_ids`. |
| `app/admin/meeting_project_scans.rb` | Create. "Meeting Matches" page. |
| `app/admin/meeting_project_trackers.rb` | Create. Menu-less link CRUD. |
| `config/initializers/admin_authorization.rb` or wherever `AdminAuthorization` lives | Only if the two new resources need an entry to be readable by leads; follow how `ShipScan`/`WeeklyShip` are handled. |
| `test/models/meeting_project_match_test.rb` | Create. |
| `test/lib/stacks/meetings/project_matcher_test.rb` | Create. |
| `test/integration/admin_meeting_matches_test.rb` | Create. |

---

### Task 1: Tables and models

**Produces:**
- `MeetingProjectTracker(meeting_id, project_tracker_id, matched_by enum {llm: 0, human: 1}, confidence float, rationale text)`, unique on `[meeting_id, project_tracker_id]`; `attr_accessor :via_matcher`.
- `MeetingProjectScan(meeting_id unique, outcome enum {linked: 0, no_match: 1}, scanned_hash string, scanned_at datetime null: false, human_locked boolean default false null: false)`.
- `Meeting#project_trackers`, `#meeting_project_trackers`, `#meeting_project_scan`, `#eligible_documents`, `#eligible_content_hash`.

- [ ] **Step 1: Test database** (once)

```bash
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails db:create db:schema:load
git status --short db/schema.rb   # must print nothing
```

- [ ] **Step 2: Migration**

```ruby
# db/migrate/20261012180000_create_meeting_project_matches.rb
# Which project tracker(s) a Google Meet meeting was about, decided nightly by
# Stacks::Meetings::ProjectMatcher and correctable by a person. Keyed on the
# meeting: its transcript and its Gemini notes are two documents of one Meeting.
class CreateMeetingProjectMatches < ActiveRecord::Migration[6.1]
  def change
    create_table :meeting_project_trackers do |t|
      t.references :meeting, null: false, foreign_key: true
      t.references :project_tracker, null: false, foreign_key: true
      t.integer :matched_by, null: false, default: 0
      t.float :confidence
      t.text :rationale
      t.timestamps
      t.index [:meeting_id, :project_tracker_id], unique: true, name: "index_meeting_project_trackers_on_meeting_and_tracker"
    end

    create_table :meeting_project_scans do |t|
      t.references :meeting, null: false, foreign_key: true, index: { unique: true }
      t.integer :outcome, null: false
      t.string :scanned_hash
      t.datetime :scanned_at, null: false
      t.boolean :human_locked, null: false, default: false
      t.timestamps
    end
  end
end
```

- [ ] **Step 3: Hand-edit `db/schema.rb`** to match exactly what that migration creates (copy the style of the neighbouring `create_table` blocks and `add_foreign_key` lines), and set the version to `2026_10_12_180000` unless the file's version is already higher (then use a timestamp above it for both). Reload and verify:

```bash
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails db:schema:load
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails runner 'puts ActiveRecord::Base.connection.tables.grep(/meeting_project/).sort.inspect'
```
Expected: `["meeting_project_scans", "meeting_project_trackers"]`.

- [ ] **Step 4: Failing tests** in `test/models/meeting_project_match_test.rb`. Helpers (adapt the document helper from `test/lib/stacks/weekly_ships/grader_test.rb`; a Meet document needs `source: :meet` or `:gemini_notes` and `source_record: meeting`):

```ruby
  def meeting!(title: "Harvey weekly sync", started_at: 2.days.ago)
    Meeting.create!(title: title, started_at: started_at, meet_source: :meet_api)
  end

  def doc!(meeting, source: :meet, content_hash: SecureRandom.hex(8), chunks: ["We reviewed the Harvey staging build."], speaker: "Sam Lead")
    d = Document.create!(source: source, external_id: SecureRandom.hex(6), title: meeting.title,
                         occurred_at: meeting.started_at, content_hash: content_hash, source_record: meeting)
    chunks.each_with_index { |c, i| d.chunks.create!(position: i, content: c, speaker_name: speaker, source: source, occurred_at: meeting.started_at) }
    d
  end

  def exclude!(doc)
    doc.update_columns(excluded: Document.excludeds[:manually_excluded])
  end

  def tracker!(name)
    ProjectTracker.new(name: name).tap { |t| t.save!(validate: false) }
  end
```

Check `Meeting`'s and `Document`'s required columns and default exclusion state in `db/schema.rb` and the Document model: a new document may default to excluded (the connector is default-deny). If so, set `excluded: :not_excluded` in `doc!` so helpers produce eligible documents.

Tests:
  1. `meeting.eligible_documents` returns only corpus-eligible documents.
  2. `eligible_content_hash` is nil with no eligible document; changes when an eligible document's `content_hash` changes; changes when one of two documents is excluded; does not depend on document order.
  3. A link is unique per meeting and tracker.
  4. A link saved without `via_matcher` gets `matched_by: "human"` and creates or updates the meeting's scan with `human_locked: true, outcome: "linked"`.
  5. A link saved with `via_matcher = true` keeps `matched_by: "llm"` and does not lock.
  6. Destroying a link by hand (no `via_matcher`) locks the scan; outcome is `linked` if another link remains, else `no_match`.
  7. Destroying a meeting or a tracker removes its links (and the meeting's scan) without raising.

- [ ] **Step 5: Implement**

```ruby
# app/models/meeting_project_tracker.rb
# One project tracker a meeting was about. Made by the nightly matcher
# (Stacks::Meetings::ProjectMatcher) or by a person; any change a person
# makes locks the meeting's scan, so the matcher leaves it alone from then on.
class MeetingProjectTracker < ApplicationRecord
  belongs_to :meeting
  belongs_to :project_tracker

  enum matched_by: { llm: 0, human: 1 }

  # Set by the matcher on its own writes; anything else is a person.
  attr_accessor :via_matcher

  validates :project_tracker_id, uniqueness: { scope: :meeting_id }

  before_validation { self.matched_by = :human unless via_matcher || persisted? }

  after_save    :human_lock_scan!, unless: :via_matcher
  after_destroy :human_lock_scan!, unless: -> { via_matcher || destroyed_by_association }

  private

  def human_lock_scan!
    return if meeting.nil?
    scan = MeetingProjectScan.find_or_initialize_by(meeting: meeting)
    outcome = meeting.meeting_project_trackers.where.not(id: destroyed? ? id : nil).exists? ? :linked : :no_match
    scan.update!(outcome: outcome, human_locked: true, scanned_at: Time.zone.now,
                 scanned_hash: meeting.eligible_content_hash)
  end
end
```

Verify the `where.not(id: nil)` branch behaves as intended in a test (after a save the link itself counts; after a destroy it must not); rewrite it as two explicit branches if clearer.

```ruby
# app/models/meeting_project_scan.rb
# Bookkeeping for the meeting matcher: one row per examined meeting. Keyed on
# a hash of the meeting's corpus-eligible documents, so a meeting is matched
# again only when what the matcher may read has changed. human_locked scans
# are never touched by the matcher.
class MeetingProjectScan < ApplicationRecord
  belongs_to :meeting
  enum outcome: { linked: 0, no_match: 1 }
  validates :outcome, :scanned_at, presence: true
end
```

`app/models/meeting.rb` additions:

```ruby
  has_many :meeting_project_trackers, dependent: :destroy
  has_many :project_trackers, through: :meeting_project_trackers
  has_one :meeting_project_scan, dependent: :destroy

  # The documents of this meeting the corpus may read (transcript and/or notes).
  def eligible_documents
    documents.corpus_eligible
  end

  # What the matcher was allowed to read, as one value: nil when nothing is.
  def eligible_content_hash
    parts = eligible_documents.order(:id).pluck(:id, :content_hash)
    return nil if parts.empty?
    Digest::SHA256.hexdigest(parts.map { |id, hash| "#{id}:#{hash}" }.join("|"))
  end
```

`app/models/project_tracker.rb`: `has_many :meeting_project_trackers, dependent: :destroy` beside `has_many :weekly_ships`.

- [ ] **Step 6: Run; pass. Commit** `feat(meetings): tables and models for matching a meeting to project trackers`.

---

### Task 2: The matcher

**Files:** `lib/stacks/meetings/project_matcher.rb`, `app/models/project_tracker.rb`, `test/lib/stacks/meetings/project_matcher_test.rb`.

**Produces:**
- `Stacks::Meetings::ProjectMatcher.enabled?` → `ENV["MEETING_MATCHING"].to_s.strip.downcase == "on"`
- `Stacks::Meetings::ProjectMatcher.run!(dry_run: false, limit: MAX_PER_RUN)` → stats Hash (`:scanned`, `:linked`, `:no_match`, `:errored`, `:removed`, `:skipped_disabled`, `:skipped_no_key`, `:input_tokens`, `:output_tokens`, and `:results` on a dry run)
- Constants: `WINDOW = 14.days`, `CONFIDENCE_THRESHOLD = 0.6`, `BODY_CHARS = 2_000`, `MAX_PER_RUN = 60`, `RECENT_PEOPLE = 60.days`
- `ProjectTracker#matcher_people_names` → Array of Strings

- [ ] **Step 1: Failing tests.** Setup stubs `Stacks::AI.configured?` → true and `ProjectMatcher.enabled?` → true. A model answer is `Stacks::AI::Result.new({ "tracker_ids" => [id], "confidence" => 0.9, "rationale" => "Title names the client." }, 1000, 100)` (check `Stacks::AI::Result`'s shape in `lib/stacks/ai.rb`).
  1. A meeting 2 days old with one eligible document is matched once: one `MeetingProjectTracker` with `matched_by: "llm"`, confidence 0.9, the rationale; scan `linked` with `scanned_hash == meeting.eligible_content_hash`.
  2. A second `run!` makes no model call (`Stacks::AI.expects(:extract).never`).
  3. Confidence 0.59 → no link, scan `no_match`. Empty `tracker_ids` → `no_match`.
  4. A tracker id the model invents (not a candidate) is ignored; if none of the ids are valid the outcome is `no_match`.
  5. A meeting with a transcript and notes (two eligible documents) costs one call and gets one set of links.
  6. The prompt contains the meeting title, a participant name (`meeting.participants.create!(name: "Nima Client")`), a chunk speaker name, and the eligible document's text; it does not contain the text of an excluded sibling document. Capture the prompt with `Stacks::AI.expects(:extract).with { |args| @prompt = args[:prompt]; true }.returns(...)`.
  7. A meeting whose only documents are excluded is never sent (`extract` never called) and gets no scan.
  8. A meeting older than `WINDOW` is not sent.
  9. Content change: after a `linked` scan, changing the document's `content_hash` causes one new call; links the model no longer returns are removed when they were `llm`, and the scan is refreshed.
  10. Exclusion: a matched meeting whose only eligible document is then excluded has its `llm` links and its scan removed on the next run, with no model call, and `stats[:removed] == 1`.
  11. A human-locked scan is never rematched, even after a content change; a human link is never removed.
  12. Kickoff retry: a `no_match` scan is retried when a `ProjectTracker` was created after `scanned_at`; not retried otherwise.
  13. Candidate trackers are those with `work_completed_at: nil`; a completed tracker's id is not in the prompt.
  14. The prompt lists, per candidate tracker, its name and the names from `matcher_people_names` (stub that method to return `["Sam Lead"]` and assert the name appears on the tracker's line).
  15. `Stacks::AI::Error` on one meeting counts `errored`, writes no scan (retried next night), and the run continues to the next meeting.
  16. Off: with `enabled?` false, `run!` returns `{ skipped_disabled: 1, errored: 0 }` and calls nothing; `run!(dry_run: true)` still calls the model, writes no link and no scan, and returns `results` with `{ meeting_id:, title:, tracker_ids:, confidence:, rationale: }`.
  17. No AI key: `{ skipped_no_key: n }`, no error.
  18. `limit:` caps the number of model calls; newest meetings first.

- [ ] **Step 2: Implement `ProjectTracker#matcher_people_names`.** People a meeting about this project would plausibly include: current project and account leads, and everyone with Forecast hours on the tracker's projects in the last 60 days. Read `ProjectTracker#all_contributors` and `#current_project_leads` / `#current_account_leads` for how people are reached, then write the narrowest query that returns display names (no rates, no hours). Unit-test it with one lead and one stubbed or built recent assignment; if building Forecast fixtures is heavy, test the lead half directly and the assignment half with a stub at the association boundary, and say so in your report. Return unique, non-blank names.

- [ ] **Step 3: Implement the matcher.**

```ruby
# lib/stacks/meetings/project_matcher.rb
module Stacks
  module Meetings
    # Nightly matcher connecting Google Meet meetings to the ProjectTracker(s)
    # they were about, so what Stacksbot observes in a transcript can be filed
    # under the right project. Modelled on Stacks::WeeklyShips::Sweep: one
    # cheap model call per meeting, a scan row so a meeting is matched once,
    # human_locked scans untouchable. The match belongs to the Meeting; its
    # transcript and Gemini notes are two documents of the same row.
    class ProjectMatcher
      CONFIDENCE_THRESHOLD = 0.6
      WINDOW = 14.days          # only recent meetings; no silent backfill
      BODY_CHARS = 2_000
      MAX_PER_RUN = 60          # cost guard: about 7 new meetings a night today
      RECENT_PEOPLE = 60.days

      SCHEMA = {
        "type" => "object",
        "properties" => {
          "tracker_ids" => { "type" => "array", "items" => { "type" => "integer" } },
          "confidence" => { "type" => "number" },
          "rationale" => { "type" => "string" }
        },
        "required" => %w[tracker_ids confidence rationale],
        "additionalProperties" => false
      }.freeze

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You match an internal Google Meet meeting to the client project(s) it was about.

        Rules:
        - Most meetings are internal (standups, one-off chats, company meetings, hiring,
          sales calls about work not yet won) and match NO project. Returning an empty
          list is the normal, correct answer for those.
        - Match only when the meeting is clearly a working or client meeting about a
          specific candidate project: the title or the conversation names the client
          or the project, or the people present are that project's team and the talk
          is about that project's work.
        - Studio names (Sanctuary Computer, XXIX, Manhattan Hydraulics, Index, garden3d)
          are ours, not a client. Never match on them alone.
        - People are matched by name only. One shared person is weak evidence: the same
          people work on several projects.
        - A meeting may be about more than one candidate project.
        - Only include tracker ids you are genuinely confident about; confidence is
          your overall 0-1 confidence in the ids you returned.
        - rationale is one short sentence naming the evidence. Do not quote the
          conversation.
      PROMPT

      # Off until a human turns it on (heroku config:set MEETING_MATCHING=on), the
      # same trust gate as the weekly ship grader. The dry-run preview ignores it.
      def self.enabled?
        ENV["MEETING_MATCHING"].to_s.strip.downcase == "on"
      end

      def self.run!(dry_run: false, limit: MAX_PER_RUN)
        return { skipped_disabled: 1, errored: 0 } unless dry_run || enabled?
        new(dry_run: dry_run, limit: limit).run!
      end

      def initialize(dry_run:, limit:)
        @dry_run = dry_run
        @limit = limit
      end

      def run!
        stats = Hash.new(0)
        stats[:results] = [] if @dry_run
        meetings = candidates
        unless Stacks::AI.configured?
          stats[:skipped_no_key] = meetings.size
          return stats
        end
        remove_unreadable!(stats) unless @dry_run
        trackers = candidate_trackers
        meetings.each { |meeting| process(meeting, trackers, stats) }
        Rails.logger.info("[meetings:match] #{stats.except(:results).inspect}")
        stats
      end
      # … private methods described below
    end
  end
end
```

Private methods, each small:

- `recent_meetings`: `Meeting.where(started_at: WINDOW.ago..).order(started_at: :desc)`. If `started_at` can be nil for Drive-sourced meetings (check the ETL), fall back to the newest eligible document's `occurred_at`; decide from the data model and test whichever you implement.
- `candidates`: recent meetings that have at least one eligible document, minus those whose scan is `human_locked`, keeping a meeting when it has no scan, or its `scanned_hash != eligible_content_hash`, or its scan is `no_match` and `ProjectTracker.where("created_at > ?", scan.scanned_at).exists?`. Return an Array capped at `@limit`. Avoid a query per meeting where reasonable (preload scans and eligible documents), but correctness first: the set is about 100 rows.
- `remove_unreadable!(stats)`: for scans not human-locked whose meeting now has no eligible document, destroy the meeting's `llm` links (set `via_matcher = true` on each before `destroy` so it does not lock) and the scan; `stats[:removed] += 1`. Not limited to the window.
- `candidate_trackers`: `ProjectTracker.where(work_completed_at: nil).includes(:forecast_projects)` → `{ id:, names: ([pt.name] + forecast project names).compact.uniq, client: pt.derived_client&.name, people: pt.matcher_people_names }`.
- `prompt_for(meeting, trackers)`:

```ruby
        docs = meeting.eligible_documents.order(:id).to_a
        people = (meeting.participants.pluck(:name) +
                  Chunk.where(document_id: docs.map(&:id)).distinct.pluck(:speaker_name)).compact.map(&:strip).reject(&:blank?).uniq
        opening = docs.map { |d| d.chunks.order(:position).limit(5).pluck(:content).join("\n") }.join("\n")[0, BODY_CHARS]
        <<~PROMPT
          Meeting title: #{meeting.title.presence || docs.first&.title}
          Held: #{meeting.started_at&.to_date}
          People present or speaking: #{people.join(", ").presence || "unknown"}

          Opening of the meeting (truncated):
          #{opening}

          Candidate project trackers:
          #{trackers.map { |t| "- id #{t[:id]}: #{t[:names].join(" / ")}#{" (client: #{t[:client]})" if t[:client].present?}#{" (team: #{t[:people].join(", ")})" if t[:people].any?}" }.join("\n")}
        PROMPT
```

  Never read `meeting.segments` here: segments are the transcript's text and exist even when the transcript document is excluded. Chunks of eligible documents are the only body source.
- `process(meeting, trackers, stats)`: `stats[:scanned] += 1`; call `Stacks::AI.extract(system: SYSTEM_PROMPT, prompt:, schema: SCHEMA)`; add tokens; `ids = data["tracker_ids"].uniq & trackers.map { |t| t[:id] }`; `matched = ids.any? && data["confidence"].to_f >= CONFIDENCE_THRESHOLD`. On a dry run push the result and return. Otherwise in one transaction: when matched, `find_or_initialize_by(meeting:, project_tracker_id:)` for each id, set `via_matcher = true`, leave a `human` link's `matched_by` alone, assign confidence and rationale, save; then destroy the meeting's `llm` links whose tracker is not in `ids` (with `via_matcher = true`); when not matched, destroy all its `llm` links the same way. Then `record_scan!(meeting, matched || meeting.meeting_project_trackers.exists? ? :linked : :no_match)`. Rescue `Stacks::AI::Error, ActiveRecord::ActiveRecordError` → log, `stats[:errored] += 1`, no scan.
- `record_scan!(meeting, outcome)`: `find_or_initialize_by(meeting:)`, return if `human_locked?`, `update!(outcome:, scanned_at: Time.zone.now, scanned_hash: meeting.eligible_content_hash)`.

- [ ] **Step 4: Run the matcher tests and Task 1's; all pass. Commit** `feat(meetings): nightly matcher linking Meet meetings to project trackers`.

---

### Task 3: Rake tasks and the nightly run

**Files:** `lib/tasks/etl.rake`, `test/lib/tasks/etl_rake_test.rb`.

- [ ] **Step 1: Failing rake tests**, following the `match_weekly_ships` and `grade_weekly_ships_preview` tests in the same file:
  1. `stacks:etl:match_meetings` creates a `SystemTask` named `stacks:etl:match_meetings`, calls `Stacks::Meetings::ProjectMatcher.run!` and marks success; with `errored: 2` in the stats it marks an error whose message includes `2 meetings failed to match`; when `run!` raises it marks an error.
  2. `stacks:etl:match_meetings_preview[3]` calls `run!(dry_run: true, limit: 3)`, creates no `SystemTask`, and prints a line per result and a totals line ending `(nothing saved)`.
  3. `sync_all` invokes `stacks:etl:match_meetings` after `stacks:etl:match_weekly_ships` (assert on the task-name list the way the existing `sync_all` test does; if there is none, assert the array literal contains both names in that order by invoking with all tasks stubbed).

- [ ] **Step 2: Implement** beside `match_weekly_ships`:

```ruby
    # Links recent Meet meetings to the project tracker(s) they were about
    # (Stacks::Meetings::ProjectMatcher: one cheap model call per meeting).
    desc "Match recent Google Meet meetings to project trackers"
    task match_meetings: :environment do
      system_task = SystemTask.create!(name: "stacks:etl:match_meetings")
      begin
        stats = Stacks::Meetings::ProjectMatcher.run!
        if stats[:errored].to_i.positive?
          system_task.mark_as_error(StandardError.new("#{stats[:errored]} meetings failed to match: #{stats.inspect}"))
        else
          system_task.mark_as_success
        end
      rescue => e
        system_task.mark_as_error(e)
      end
    end

    # Preview matches for unmatched recent meetings without writing anything.
    #   rake "stacks:etl:match_meetings_preview[10]"
    desc 'Preview meeting-to-tracker matches without saving them ([limit], default 10)'
    task :match_meetings_preview, [:limit] => :environment do |_t, args|
      stats = Stacks::Meetings::ProjectMatcher.run!(dry_run: true, limit: (args[:limit] || 10).to_i)
      names = ProjectTracker.where(id: Array(stats[:results]).flat_map { |r| r[:tracker_ids] }).pluck(:id, :name).to_h
      Array(stats[:results]).each do |r|
        matched = r[:tracker_ids].map { |id| names[id] || "tracker #{id}" }.join(", ").presence || "no project"
        puts "#{r[:title]} (meeting #{r[:meeting_id]}) -> #{matched} [#{r[:confidence]}] #{r[:rationale]}"
      end
      puts "scanned #{stats[:scanned]}, errored #{stats[:errored]}, tokens in #{stats[:input_tokens]} / out #{stats[:output_tokens]} (nothing saved)"
    end
```

Add `stacks:etl:match_meetings` to the end of the `sync_all` list and update its `desc`/comment to mention it. On a dry run `results[:tracker_ids]` must already be filtered to valid candidates at or above the threshold (empty otherwise); make Task 2's dry-run result follow that and adjust its test if needed.

- [ ] **Step 3: Run; pass. Commit** `feat(meetings): nightly and preview rake tasks for the meeting matcher`.

---

### Task 4: MCP

**Files:** `app/services/mcp/list_documents_tool.rb`, `app/services/mcp/get_document_tool.rb`, their tests.

**Produces:** each document in both tools' output gains `project_tracker_ids: [Integer]` (empty array when none or when the document is not a meeting's).

- [ ] **Step 1: Failing tests** in the existing test files for these tools:
  1. A meeting's eligible transcript document returns the meeting's tracker ids, sorted.
  2. The eligible notes document of the same meeting returns the same ids.
  3. A `google_groups` document returns `[]`.
  4. The response contains no `rationale` and no `confidence` key anywhere (assert on the serialised JSON string).
  5. `list_documents` adds no query per document: preload, and assert with a query counter if the file already has one; otherwise assert correctness for two meetings in one call.
  6. Update each tool's `description` to mention `project_tracker_ids`, and assert the description includes it.

- [ ] **Step 2: Implement.** In `get_document`: `project_tracker_ids: is_meeting ? meeting.meeting_project_trackers.pluck(:project_tracker_id).sort : []`. In `list_documents`: read the tool, preload `source_record` polymorphically only if it already does; otherwise collect the page's meeting ids and run one `MeetingProjectTracker.where(meeting_id: ids).pluck(:meeting_id, :project_tracker_id)` grouped into a hash. Both tools already return only corpus-eligible documents; keep it that way.

- [ ] **Step 3: Run `test/services/mcp`; pass. Commit** `feat(mcp): documents say which project trackers their meeting was matched to`.

---

### Task 5: The Meeting Matches page

**Files:** `app/admin/meeting_project_scans.rb`, `app/admin/meeting_project_trackers.rb`, the authorization adapter if needed, `test/integration/admin_meeting_matches_test.rb`.

Model it closely on `app/admin/ship_scans.rb` + `app/admin/weekly_ships.rb` (read both fully first, and how `AdminAuthorization` treats `ShipScan` and `WeeklyShip`; give the two new classes the same treatment so admins and leads can use the page and a project-scoped lead grantee cannot).

- `ActiveAdmin.register MeetingProjectScan`, `menu label: "Meeting Matches", parent: <the same parent ship_scans uses>`, `actions :index`.
- `scoped_collection`: only scans whose meeting has at least one corpus-eligible document (`joins(meeting: :documents).merge(Document.corpus_eligible).distinct`), with `includes(meeting: { meeting_project_trackers: :project_tracker })`. Newest meeting first.
- Scopes: "Needs Review" (default): not `human_locked` and (`no_match`, or `linked` with any link's confidence under 0.8). "Linked". "No Match". "All".
- Columns: "Meeting" (title, falling back to "Meeting, <date>"; linked to the eligible document's `url` in a new tab when present), "Held" (date), "Projects" (each linked tracker as a link to its admin page, with the confidence as a whole percent and a "×" link that destroys the link via `admin_meeting_project_tracker_path(link)`, `method: :delete`, with a confirm), "Why" (the rationale of the first link, or blank), "Decided by" ("Stacks (automatic)" or "A person" when `human_locked`), and an "Add a project" link to `new_admin_meeting_project_tracker_path(meeting_id: scan.meeting_id)`.
- `ActiveAdmin.register MeetingProjectTracker`, `menu false`, `actions :new, :create, :destroy`, `permit_params :meeting_id, :project_tracker_id`. The form shows the meeting (read-only title; hidden `meeting_id` pre-filled from params) and a select of trackers with `work_completed_at: nil` ordered by name. After create or destroy, redirect to `admin_meeting_project_scans_path` (override `smart_resource_url`/`smart_collection_url` as `weekly_ships.rb` does). Saving through this form does not set `via_matcher`, so the model locks the scan.
- All model-written text goes through Arbre helpers, which escape it. Use Arbre `a(...)`, not block-form `link_to`. A link inside a table cell needs `style: "font-size: inherit;"` only if the surrounding ship pages do it; copy what they do.

- [ ] **Step 1: Failing integration tests** (sign in an admin as `test/integration/admin_weekly_ship_coaching_test.rb` does):
  1. The index responds 200 and lists a matched meeting's title, tracker name, "90%" and the rationale.
  2. "Needs Review" (the default) lists a `no_match` meeting and a 0.7 match, and not a 0.95 match or a human-locked one; "All" lists every one.
  3. A scan whose meeting has no eligible document is not listed under any scope, and its rationale text is absent from the response.
  4. POST create with a meeting and a tracker makes a `human` link, locks the scan, and redirects to the index.
  5. DELETE of a link removes it and locks the scan as `no_match`.
  6. A model-written rationale containing `<script>` is escaped in the response.
  7. A project-scoped lead grantee (see `scoped_grantee!` in `admin_weekly_ship_coaching_test.rb`) cannot open the index or create a link (not a 200).
  8. A lead (not admin) can open the index. Find how an existing test makes a lead (`can_act_as_lead?`) and follow it.

- [ ] **Step 2: Implement, run, pass.**

- [ ] **Step 3: Full affected run**

```bash
DATABASE_URL=postgres://localhost/stacks_test_meetingmatch RAILS_ENV=test bin/rails test test/models test/lib/stacks test/lib/tasks test/services/mcp test/integration
```
Report the totals line. If anything outside this plan's files fails, check whether it also fails on `origin/main` before touching it, and report it rather than fixing unrelated failures.

- [ ] **Step 4: Commit** `feat(meetings): a Meeting Matches page to review and correct matches`.

---

## Amendments after the plan review (these override anything above)

0. **Never read, decrypt or print credentials.** Do not open `config/credentials.yml.enc`, `config/master.key`, or print any value from `Stacks::Utils.config` or `ENV`.
1. **People are matched by name or email, and the tracker side must return real names.** `AdminUser#name`, `#display_name`, `ForecastPerson#name` and `#display_name` all return the email. Replace `ProjectTracker#matcher_people_names` with `ProjectTracker#matcher_people` returning unique strings of the form `"First Last <email>"` built from `forecast_people.first_name`, `last_name`, `email` (drop the name part when both are blank):
   - Leads: `project_lead_periods` and `account_lead_periods` that are current → `admin_user.forecast_person`.
   - Recent team: `ForecastPerson.joins(:forecast_assignments).where(forecast_assignments: { project_id: forecast_projects.map(&:forecast_id) }).where("forecast_assignments.end_date >= ? AND forecast_assignments.start_date <= ?", 60.days.ago.to_date, Date.today).distinct`.
   Verify the association and column names against the models before relying on them, and return `[]` rather than raising when a tracker has no Forecast projects.
   On the meeting side, the people line is the union of `meeting.participants` names, the eligible documents' chunk `speaker_name`s, and `DocumentContact.where(document_id: docs.map(&:id)).pluck(:name, :email)` rendered as `"Name <email>"` (eligible documents only; most notes documents carry people only there). Reword the system prompt rule to "People are matched by name or email." Tests 6 and 14 assert on these strings.
2. **Title comes from the eligible document.** Use `docs.first.title.presence || meeting.title` in the prompt and on the admin page; `meeting.title` is overwritten by whichever document was ingested last and can come from an excluded one. Order `docs` with `gemini_notes` first, then by id.
3. **Body budget per document.** Take the first five chunks of each eligible document and cut each document's text to `BODY_CHARS` (2,000) separately, notes first, then join. Update the test that asserts prompt content accordingly.
4. **Network errors.** `process` rescues `StandardError` (not only `Stacks::AI::Error` and ActiveRecord errors): timeouts and socket errors are not wrapped by the provider. Log class and message, count `errored`, write no scan.
5. **A person can lock a meeting mid-run.** At the top of the write transaction in `process`: `return if MeetingProjectScan.lock.find_by(meeting: meeting)&.human_locked?`.
6. **The ETL destroys Meeting rows.** `absorb_standalone_notes_meeting!` in `lib/stacks/etl/meet/meet_api_source.rb` (about lines 246-252) re-homes a standalone notes meeting's documents onto the surviving meeting, then calls `standalone.destroy`. Add a step to Task 1: before that destroy, move the standalone's `meeting_project_trackers` to the survivor (skip any tracker the survivor already has; `update_all`, no callbacks) and, when the survivor has no scan, move the scan too (keeping `human_locked`); when both have scans, keep the survivor's but set `human_locked` true if either was. Put the logic in a small `Meeting#absorb_project_matches_from!(other)` method, call it from the ETL just before the destroy, and unit-test the method (links moved, duplicate skipped, lock preserved). Read the ETL method first and keep its transaction semantics.
7. **Deploys land before migrations.** Guard every read of the new tables on paths that run in production before the migration: in both MCP tools, return `project_tracker_ids: []` unless `MeetingProjectTracker.table_exists?` (memoise the check per call, as `WeeklyShip#grade` guards its column); and make `Meeting`'s and `ProjectTracker`'s new `dependent: :destroy` associations safe the same way if a destroy would otherwise raise `UndefinedTable` (a small guard method is fine; say what you did). Add a test that stubs `table_exists?` to false and asserts the MCP tools still answer.
8. **The "Add a project" form must not expose private meetings.** In `MeetingProjectTracker`: `validate :meeting_must_be_readable, unless: :via_matcher` adding `errors.add(:meeting, "has no document in the Stacks corpus")` when `meeting.eligible_documents.none?`. In the admin `new` and `create` actions, redirect to `admin_meeting_project_scans_path` with an alert, without rendering any meeting title, when the meeting is missing or has no eligible document. Test both (a meeting whose only document is excluded: GET new does not contain its title; POST create makes no link).
9. **The index query.** Do not use `distinct`. Use
   `super.joins(:meeting).where(meeting_id: Meeting.joins(:documents).merge(Document.corpus_eligible).select(:id)).includes(meeting: { meeting_project_trackers: :project_tracker })`
   and set `config.sort_order = "meetings.started_at_desc"` (verify ActiveAdmin accepts a joined-table sort key here; if it does not, define a sortable column on "Held" with `sortable: "meetings.started_at"` and make it the default sort). "Needs Review" is
   `where(human_locked: false).where("meeting_project_scans.outcome = 1 OR EXISTS (SELECT 1 FROM meeting_project_trackers l WHERE l.meeting_id = meeting_project_scans.meeting_id AND l.confidence < 0.8)")`.
10. **A rationale never outlives the text it came from.** The "Why" column shows the rationale only when `scan.scanned_hash == scan.meeting.eligible_content_hash`; otherwise it shows nothing. `human_lock_scan!` sets `scanned_hash` only when it creates the scan, never when it updates one. Test: match a two-document meeting, exclude one document, and assert the rationale is absent from the page before any rerun.
11. **Test mechanics.**
    - A new Document defaults to eligible (`excluded` default 0); ignore the plan's caution about default-deny.
    - `list_documents` tests live in `test/services/mcp/tools_test.rb`.
    - Every rake test must `reenable` the task it invokes; the `sync_all` test must also reenable `match_weekly_ships`. Stub `Stacks::Meetings::ProjectMatcher.run!` in the existing `sync_all` test (`test/lib/tasks/etl_rake_test.rb:30`).
    - Rake error-path tests must stub `Stacks::Notifications.stubs(:report_exception).returns(stub(record: nil))` (see `test/lib/tasks/daily_enterprise_tasks_rake_test.rb:24`): `SystemTask#mark_as_error` otherwise posts to a real Twist thread.
    - Make a lead with `PermissionGrant.create!(admin_user:, permission: "lead", granted_by:)` (`test/integration/admin_api_tokens_test.rb:16`).
    - The new-link form's Cancel link must point at `admin_meeting_project_scans_path` (the resource has no index route).
12. **Authorization needs no change.** Admins and leads pass `AdminAuthorization`'s blanket grant and a scoped grantee falls through to false, exactly as for `ShipScan` and `WeeklyShip`. The menu parent is `"project_trackers"`. Do not edit the adapter.
13. **Hand-off note for the coordinator** (do not act on it): this PR has a migration; it is run on production before the PR is merged, and `MEETING_MATCHING` stays off until a dry-run preview has been read.

---

## Reworked to mirror the weekly ship matcher (2026-10-12)

After review the owner decided the two matchers should behave the same and that a tracker simply has many meetings. This section supersedes the tasks and amendments above wherever they differ.

- **Data.** `ProjectTracker has_and_belongs_to_many :meetings` (and the reverse) through the pure join table `meetings_project_trackers`: no join model, no `matched_by`, nothing stored per link. `MeetingScan` (`meeting_scans`, one per meeting) is the sibling of `ShipScan`: `outcome` (`linked`, `no_match`, `out_of_scope`), `confidence`, `rationale`, `scanned_hash`, `scanned_at`, `human_locked`. The model's one answer about a meeting lives on the scan. `MeetingProjectTracker` and `MeetingProjectScan` are gone; migration `20261012180000` now creates the two new tables.
- **A person's changes.** `Meeting#link_project!(tracker)` and `#unlink_project!(tracker)` add or remove the tracker and lock the scan (`human_locked`, outcome from what is left, `scanned_hash` only on a new scan). `link_project!` raises `ActiveRecord::RecordInvalid` for a meeting with no corpus-eligible document. The sweep writes the join directly.
- **Sweep.** `Stacks::Meetings::Sweep` (`lib/stacks/meetings/sweep.rb`) replaces `ProjectMatcher` and follows `Stacks::WeeklyShips::Sweep`: no environment switch (it runs whenever the nightly task runs), no per-run cap, `BACKFILL_WINDOW = 90.days`. A candidate is any meeting with an eligible document and either no scan, or an unlocked scan whose hash differs from the current eligible content. A candidate held more than 90 days ago gets an `out_of_scope` scan and no model call.
- **Links are only added.** A rescan adds the valid trackers returned at confidence 0.6 or more and leaves existing ones alone. There is no kickoff retry of `no_match` scans. The outcome is `linked` when the meeting has any tracker, else `no_match`; the clamped confidence and the 300-character reason go on the scan.
- **Kept on purpose:** the match is keyed on the Meeting, candidates are open trackers that are not `internal_client?`, the prompt carries each tracker's client and team, the system prompt rules, every privacy protection (eligible documents only, eligible title, hash from the loaded documents, per-meeting rescue, a mid-run lock wins), and the cleanup of an unlocked scan and its links once a meeting has no eligible document at all (the one time the sweep removes links).
- **ETL absorb.** Trackers move to the survivor; the surviving scan (its own, or the other's when it had none) loses `rationale`, `confidence` and `scanned_hash`, keeps a lock from either side, and takes its outcome from the survivor's trackers.
- **Destroy paths.** The join rows go with either side. A scan left with no trackers by a tracker's destroy becomes `no_match` and keeps its lock. No `table_exists?` guards there (the migration runs before the deploy); the MCP tools keep one, asked on every call.
- **MCP.** `list_documents` and `get_document` still return sorted `project_tracker_ids`, never the reason or the confidence.
- **Admin.** One page, `ActiveAdmin.register MeetingScan` ("Meeting Matches"), index only, with `add_project` (GET form, POST) and `remove_project` (DELETE) member actions that call the two model methods. Confidence and "Why" come from the scan. `out_of_scope` scans appear only under "All". The member actions authorize explicitly, because ActiveAdmin only authorizes a member action that loads `resource`.
- **Rake.** `stacks:etl:match_meetings` (last in `sync_all`) and `stacks:etl:match_meetings_preview[limit]`; the limit applies to the preview only.
- **Hand-off.** Run the migration on production before this deploys. There is no switch to turn on: the first nightly run after the deploy sends every readable meeting from the last 90 days to the model, so read a preview first.

