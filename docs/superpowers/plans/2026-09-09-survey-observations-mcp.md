# Surveys over MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose studio-wide and project satisfaction surveys through two new read-only MCP tools (`list_surveys`, `get_survey_results`) with anonymous, aggregate-only payloads, so stacksbot can observe surveys as a source.

**Architecture:** One presenter (`Mcp::SurveyPresenter`) with two small adapters (`StudioAdapter` over `Survey`, `ProjectAdapter` over `ProjectSatisfactionSurvey`) normalizes both survey families into one shape; the two tools are thin wrappers that validate params and call the presenter. A single model addition, `Survey#expected_responder_ids`, lets the presenter count expected responders without ever touching responder rows. The Notion side (Sources row, Observe job, Source option, go-live doc) is authored after the PR is up.

**Tech Stack:** Rails 6.1 (Ruby 3.1.7, zeitwerk), `mcp` gem 0.22 (`MCP::Tool`), Minitest + mocha, Postgres.

**Spec:** `docs/superpowers/specs/2026-09-09-survey-observations-mcp-design.md`

## Global Constraints

- Work ONLY in the worktree `/Users/hhff/Documents/Code/stacks/.claude/worktrees/feat+survey-observations-mcp` on branch `worktree-feat+survey-observations-mcp`. Never `cd` to `/Users/hhff/Documents/Code/stacks`. Before every commit run `git rev-parse --abbrev-ref HEAD`; if it does not print `worktree-feat+survey-observations-mcp`, STOP and report BLOCKED.
- Run only targeted tests (`bin/rails test <file>`) during tasks. Never run the full suite in a task. If a test run exceeds ~2 minutes, check `ps -o pid,etime,command -ax | grep "[r]ails test"` for a second runner instead of waiting.
- Read-only MCP surface: register tools ONLY in `Mcp::Server::TOOLS` (`app/services/mcp/server.rb`), never in `Mcp::WriteServer`.
- The payload never contains a person's name or email, a responder row, or a per-response identifier. Free text only for closed surveys with ≥ `MIN_RESPONSES_FOR_TEXT` (3) responses, sorted alphabetically within each array.
- Scores are on the 0–5 `sentiment_to_score` scale (`0 / 1.25 / 2.5 / 3.75 / 5`), rounded to 2 dp.
- Tool errors go through `Mcp::Responses.error`; enumerate valid values in validation errors; clamp numeric params; whole-tool `rescue StandardError` → `Rails.logger.warn` + `Sentry.capture_exception` + `Responses.error("<tool_name> failed; the error was logged")`.
- Tests use `travel_to` for any test that depends on open/closed status (`Survey.open` and `#status` use `Date.today`).
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01SEDsb6YT6nSdDfjoNMKrnE
  ```

## File Structure

| File | Responsibility |
|---|---|
| `app/models/survey.rb` (modify) | Add `expected_responder_ids`; refactor `expected_responder_status` to share a private `expected_members_by_studio`. |
| `app/services/mcp/survey_presenter.rb` (create) | Kind-agnostic presenter: `find`, `list`, `summary`, `results`, shared aggregation helpers, constants. |
| `app/services/mcp/survey_presenter/studio_adapter.rb` (create) | `Survey`-specific queries (scope, preload, counts, answers, expected count, url). |
| `app/services/mcp/survey_presenter/project_adapter.rb` (create) | `ProjectSatisfactionSurvey`-specific queries with the same interface. |
| `app/services/mcp/list_surveys_tool.rb` (create) | `list_surveys` MCP tool. |
| `app/services/mcp/get_survey_results_tool.rb` (create) | `get_survey_results` MCP tool. |
| `app/services/mcp/server.rb` (modify) | Register both tools. |
| `test/models/survey_test.rb` (modify) | `expected_responder_ids` tests. |
| `test/support/survey_fixtures.rb` (create) | Shared builders for studio/project surveys used by all presenter/tool tests. |
| `test/services/mcp/survey_presenter_test.rb` (create) | Presenter unit tests. |
| `test/services/mcp/list_surveys_tool_test.rb` (create) | Tool tests. |
| `test/services/mcp/get_survey_results_tool_test.rb` (create) | Tool tests. |
| `test/integration/mcp_endpoint_test.rb` (modify) | Tool-name array + round-trips. |
| `docs/stacks-surveys-observations-golive.md` (create) | Go-live checklist for Part B. |

`test/test_helper.rb` already provides `mcp_payload(resp)`, `build_admin!`, `make_admin_user!(studio, started_at, ended_at = nil, email = ...)`, `make_forecast_project!`, `make_project_tracker!(forecast_projects)`. Check whether `test/support/` is auto-required: run `grep -n "support" test/test_helper.rb`. If nothing is found, Task 2 adds the require.

---

### Task 1: `Survey#expected_responder_ids`

**Files:**
- Modify: `app/models/survey.rb` (the `expected_responder_status` method, ~lines 80–98, and the end of the class)
- Test: `test/models/survey_test.rb`

**Interfaces:**
- Produces: `Survey#expected_responder_ids` → `Set<Integer>` of admin_user ids (memoized). `Survey#expected_responder_status` keeps its exact current return shape `{ Studio => { AdminUser => SurveyResponder|nil } }`.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/survey_test.rb` (inside the class, before the final `end`):

```ruby
  test "expected_responder_ids matches the keys of expected_responder_status" do
    studio = Studio.create!(name: "Gamma", mini_name: "gamma")
    survey = Survey.create!(title: "G", description: "d", opens_at: Date.new(2026, 7, 1))
    survey.survey_studios.create!(studio: studio)
    core = make_admin_user!(studio, Date.new(2026, 1, 1), nil, "core-gamma@sanctuary.computer")

    ids = survey.expected_responder_ids

    assert_kind_of Set, ids
    assert_includes ids, core.id
    assert_equal survey.expected_responder_status.values.flat_map(&:keys).map(&:id).to_set, ids
  end

  test "expected_responder_ids never queries survey_responders" do
    studio = Studio.create!(name: "Delta", mini_name: "delta")
    survey = Survey.create!(title: "D", description: "d", opens_at: Date.new(2026, 7, 1))
    survey.survey_studios.create!(studio: studio)
    make_admin_user!(studio, Date.new(2026, 1, 1), nil, "core-delta@sanctuary.computer")

    statements = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      survey.expected_responder_ids
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert statements.none? { |s| s.include?("survey_responders") },
           "expected no survey_responders SQL, got: #{statements.grep(/survey_responders/).inspect}"
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/survey_test.rb`
Expected: 2 failures/errors with `NoMethodError: undefined method 'expected_responder_ids'`.

- [ ] **Step 3: Implement**

In `app/models/survey.rb`, replace the whole `expected_responder_status` method (from the comment `# Memoized: called repeatedly per survey` through its closing `end`) with:

```ruby
  # Memoized Set of admin_user ids expected to respond: core members of each of the
  # survey's studios as of reference_date, plus elevated-service members. Deliberately
  # stops before touching survey_responders, so it is safe where responder identity
  # must stay out of scope (the MCP survey presenter).
  def expected_responder_ids
    @expected_responder_ids ||= expected_members_by_studio.values.flatten.map(&:id).to_set
  end

  # Memoized: called repeatedly per survey (index rows call expected_responders twice),
  # and the elevated-service bulk is the expensive part.
  def expected_responder_status
    @expected_responder_status ||= expected_members_by_studio.transform_values do |members|
      members.each_with_object({}) do |admin_user, h|
        h[admin_user] = SurveyResponder.find_by(survey: self, admin_user: admin_user)
      end
    end
  end
```

Then, at the very end of the class (after `self.clone_from`, before the final `end`), add:

```ruby
  private

  # { Studio => [AdminUser] } of expected members per studio. Memoized; runs the
  # elevated-service bulk computation once for the whole survey.
  def expected_members_by_studio
    @expected_members_by_studio ||= begin
      ref = reference_date
      # One bulk elevated-service computation for the whole survey.
      candidate_fp_ids = studios.flat_map { |s|
        s.members_active_on(ref).joins(:forecast_person).pluck("forecast_people.forecast_id")
      }.uniq
      elevated_ids = Contributor.elevated_service_admin_user_ids(elevated_service_periods, candidate_fp_ids)

      studios.each_with_object({}) do |studio, acc|
        core = studio.core_members_active_on(ref).to_a
        elevated = studio.members_active_on(ref).where(id: elevated_ids.to_a).to_a
        acc[studio] = (core + elevated).uniq
      end
    end
  end
```

- [ ] **Step 4: Run the model tests**

Run: `bin/rails test test/models/survey_test.rb`
Expected: all pass (the pre-existing `expected_responder_status` / `responder_status` tests included).

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/models/survey.rb test/models/survey_test.rb
git commit -m "feat: Survey#expected_responder_ids without touching responder rows

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEDsb6YT6nSdDfjoNMKrnE"
```

---

### Task 2: Test fixtures + presenter `find` / `summary`

**Files:**
- Create: `test/support/survey_fixtures.rb`
- Modify: `test/test_helper.rb` (only if `test/support` is not already required)
- Create: `app/services/mcp/survey_presenter.rb`
- Create: `app/services/mcp/survey_presenter/studio_adapter.rb`
- Create: `app/services/mcp/survey_presenter/project_adapter.rb`
- Test: `test/services/mcp/survey_presenter_test.rb`

**Interfaces:**
- Produces: `Mcp::SurveyPresenter.find(kind:, id:)` → presenter or nil; `#summary` → Hash with keys `kind id title status opened_at closed_at scope response_count overall_score url`; constants `KINDS`, `STATUSES`, `SMALL_SAMPLE_THRESHOLD`, `MIN_RESPONSES_FOR_TEXT`, `ADMIN_HOST`, `SENTIMENT_ORDER`, `SENTIMENT_SCORES`; class helpers `sentiment_name(value)`, `mean_of_question_averages(pairs)`.
- Adapter interface (both adapters): class methods `visible_scope(status)`, `find(id)`, `preload(scope)`, `response_counts(ids)`, `overall_scores(ids)`; instance methods `record`, `opened_at`, `scope`, `url`, `response_count`, `overall_score`, `expected_response_count`, `questions`, `free_text_questions`, `rating_answers`, `free_text_answers`.
- Test builders: `build_studio_survey!(...)`, `build_project_survey!(...)`, `sql_statements { }`.

- [ ] **Step 1: Check how test support files load**

`test/support/` does not exist yet and `test/test_helper.rb` does not require it (verified). Add
this line to `test/test_helper.rb` directly after `require "rails/test_help"`:

```ruby
Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |f| require f }
```

- [ ] **Step 2: Write the shared fixtures**

Create `test/support/survey_fixtures.rb`:

```ruby
# Builders for the two survey families, used by the MCP survey presenter/tool tests.
# Every builder is deterministic under travel_to; callers freeze time first.
module SurveyFixtures
  FROZEN_NOW = "2026-08-01 12:00:00".freeze
  CLOSED_AT = "2026-07-01 12:00:00".freeze

  # answers: array of hashes, one per response:
  #   { sentiment: :agree, context: "…", free_text: "…" }
  # Returns the Survey. One rating question + one free-text question.
  def build_studio_survey!(closed: true, answers: [], title: "Alpha Pulse", studio_name: "Alpha",
                           opens_at: Date.new(2026, 6, 1))
    studio = Studio.find_by(name: studio_name) ||
             Studio.create!(name: studio_name, mini_name: studio_name.downcase, snapshot: {})
    survey = Survey.create!(title: title, description: "How is it going?", opens_at: opens_at,
                            closed_at: closed ? Time.zone.parse(CLOSED_AT) : nil)
    survey.survey_studios.create!(studio: studio)
    question = survey.survey_questions.create!(prompt: "I feel supported")
    free_text = survey.survey_free_text_questions.create!(prompt: "What should we stop doing?")
    answers.each do |a|
      response = survey.survey_responses.create!
      SurveyQuestionResponse.create!(survey_response: response, survey_question: question,
                                     sentiment: a.fetch(:sentiment, :agree), context: a[:context])
      SurveyFreeTextQuestionResponse.create!(survey_response: response,
                                             survey_free_text_question: free_text,
                                             response: a[:free_text])
    end
    survey
  end

  # Same answer shape. Returns the ProjectSatisfactionSurvey. The tracker is named
  # "Healthcare.gov Project Tracker" by make_project_tracker!.
  def build_project_survey!(closed: true, answers: [], title: "Healthcare Retro")
    forecast_project = make_forecast_project![0]
    tracker = make_project_tracker!([forecast_project])
    capsule = ProjectCapsule.create!(project_tracker: tracker)
    survey = ProjectSatisfactionSurvey.create!(project_capsule: capsule, title: title,
                                               description: "Retro")
    question = survey.project_satisfaction_survey_questions.create!(prompt: "The budget was realistic")
    free_text = survey.project_satisfaction_survey_free_text_questions.create!(prompt: "What should we start doing?")
    answers.each do |a|
      response = survey.project_satisfaction_survey_responses.create!
      ProjectSatisfactionSurveyQuestionResponse.create!(
        project_satisfaction_survey_response: response,
        project_satisfaction_survey_question: question,
        sentiment: a.fetch(:sentiment, :agree), context: a[:context]
      )
      ProjectSatisfactionSurveyFreeTextQuestionResponse.create!(
        project_satisfaction_survey_response: response,
        project_satisfaction_survey_free_text_question: free_text,
        response: a[:free_text]
      )
    end
    # Close AFTER answers exist so the before_save sync persists a real score.
    survey.update!(closed_at: Time.zone.parse(CLOSED_AT)) if closed
    survey
  end

  # Collects every SQL statement executed inside the block.
  def sql_statements
    statements = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end
end
```

- [ ] **Step 3: Write the failing presenter tests (find + summary)**

Create `test/services/mcp/survey_presenter_test.rb`:

```ruby
require "test_helper"

class McpSurveyPresenterTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include SurveyFixtures

  setup { travel_to Time.zone.parse(SurveyFixtures::FROZEN_NOW) }
  teardown { travel_back }

  # ----- find + summary -----

  test "find returns a studio presenter with a closed summary" do
    survey = build_studio_survey!(answers: [{ sentiment: :agree }, { sentiment: :strongly_agree }])
    p = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id)

    s = p.summary
    assert_equal "studio", s[:kind]
    assert_equal survey.id, s[:id]
    assert_equal "Alpha Pulse", s[:title]
    assert_equal "closed", s[:status]
    assert_equal "2026-06-01", s[:opened_at]
    assert_equal Time.zone.parse(SurveyFixtures::CLOSED_AT).iso8601, s[:closed_at]
    assert_equal({ studios: [{ name: "Alpha", mini_name: "alpha" }] }, s[:scope])
    assert_equal 2, s[:response_count]
    assert_in_delta 4.38, s[:overall_score], 0.01 # mean of (3.75, 5) for the single question
    assert_equal "https://stacks.garden3d.net/admin/surveys/#{survey.id}", s[:url]
  end

  test "find returns a project presenter with tracker scope and persisted score" do
    survey = build_project_survey!(answers: [{ sentiment: :neutral }])
    p = Mcp::SurveyPresenter.find(kind: "project", id: survey.id)

    s = p.summary
    assert_equal "project", s[:kind]
    assert_equal "closed", s[:status]
    assert_equal survey.created_at.to_date.iso8601, s[:opened_at]
    tracker = survey.project_capsule.project_tracker
    assert_equal({ project_tracker_id: tracker.id, project: tracker.name }, s[:scope])
    assert_equal 1, s[:response_count]
    assert_in_delta 2.5, s[:overall_score], 0.01
    assert_equal "https://stacks.garden3d.net/admin/project_satisfaction_surveys/#{survey.id}", s[:url]
  end

  test "open surveys summarize with status open and nil overall_score" do
    survey = build_studio_survey!(closed: false, answers: [{ sentiment: :agree }])
    s = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).summary
    assert_equal "open", s[:status]
    assert_nil s[:closed_at]
    assert_nil s[:overall_score]
  end

  test "find returns nil for a draft studio survey, an unknown id, or the wrong kind" do
    draft = Survey.create!(title: "Draft", description: "d", opens_at: Date.new(2026, 9, 1))
    project = build_project_survey!
    assert_nil Mcp::SurveyPresenter.find(kind: "studio", id: draft.id)
    assert_nil Mcp::SurveyPresenter.find(kind: "studio", id: 999_999)
    assert_nil Mcp::SurveyPresenter.find(kind: "studio", id: project.id)
    assert_nil Mcp::SurveyPresenter.find(kind: "bogus", id: project.id)
  end
end
```

- [ ] **Step 4: Run to verify they fail**

Run: `bin/rails test test/services/mcp/survey_presenter_test.rb`
Expected: errors with `NameError: uninitialized constant Mcp::SurveyPresenter`.

- [ ] **Step 5: Write the adapters**

Create `app/services/mcp/survey_presenter/studio_adapter.rb`:

```ruby
module Mcp
  class SurveyPresenter
    # Survey (studio-wide) side of the presenter's adapter interface. Every query here is
    # aggregate-only: it never loads SurveyResponder rows or any AdminUser.
    class StudioAdapter
      attr_reader :record

      def initialize(record)
        @record = record
      end

      # Draft surveys (not yet open) are invisible to the MCP.
      def self.visible_scope(status)
        case status
        when 'open' then Survey.open
        when 'closed' then Survey.closed
        else Survey.where('closed_at IS NOT NULL OR opens_at <= ?', Time.zone.today)
        end
      end

      def self.find(id)
        survey = Survey.find_by(id: id)
        survey if survey && survey.status != :draft
      end

      def self.preload(scope)
        scope.includes(:studios)
      end

      # { survey_id => response count }
      def self.response_counts(ids)
        SurveyResponse.where(survey_id: ids).group(:survey_id).count
      end

      # { survey_id => overall score } — mean of per-question averages, one query for all ids.
      def self.overall_scores(ids)
        rows = SurveyQuestionResponse.joins(:survey_response)
                                     .where(survey_responses: { survey_id: ids })
                                     .pluck('survey_responses.survey_id', :survey_question_id, :sentiment)
        rows.group_by(&:first).transform_values do |survey_rows|
          SurveyPresenter.mean_of_question_averages(
            survey_rows.map { |(_, qid, s)| [qid, SurveyPresenter.sentiment_name(s)] }
          )
        end
      end

      def opened_at
        record.opens_at
      end

      def scope
        { studios: record.studios.map { |s| { name: s.name, mini_name: s.mini_name } } }
      end

      def url
        "#{ADMIN_HOST}/admin/surveys/#{record.id}"
      end

      def response_count
        record.survey_responses.count
      end

      def overall_score
        self.class.overall_scores([record.id])[record.id]
      end

      def expected_response_count
        record.expected_responder_ids.size
      end

      def questions
        record.survey_questions.order(:id).to_a
      end

      def free_text_questions
        record.survey_free_text_questions.order(:id).to_a
      end

      # [[question_id, sentiment_name_or_nil, context], ...]
      def rating_answers
        SurveyQuestionResponse.joins(:survey_response)
                              .where(survey_responses: { survey_id: record.id })
                              .order(:id)
                              .pluck(:survey_question_id, :sentiment, :context)
                              .map { |(qid, s, c)| [qid, SurveyPresenter.sentiment_name(s), c] }
      end

      # [[free_text_question_id, response], ...]
      def free_text_answers
        SurveyFreeTextQuestionResponse.joins(:survey_response)
                                      .where(survey_responses: { survey_id: record.id })
                                      .order(:id)
                                      .pluck(:survey_free_text_question_id, :response)
      end
    end
  end
end
```

Create `app/services/mcp/survey_presenter/project_adapter.rb`:

```ruby
module Mcp
  class SurveyPresenter
    # ProjectSatisfactionSurvey side of the presenter's adapter interface. Aggregate-only:
    # never loads responder rows or AdminUser identities.
    class ProjectAdapter
      attr_reader :record

      def initialize(record)
        @record = record
      end

      def self.visible_scope(status)
        case status
        when 'open' then ProjectSatisfactionSurvey.open
        when 'closed' then ProjectSatisfactionSurvey.closed
        else ProjectSatisfactionSurvey.all
        end
      end

      def self.find(id)
        ProjectSatisfactionSurvey.find_by(id: id)
      end

      def self.preload(scope)
        scope.includes(project_capsule: :project_tracker)
      end

      def self.response_counts(ids)
        ProjectSatisfactionSurveyResponse.where(project_satisfaction_survey_id: ids)
                                         .group(:project_satisfaction_survey_id).count
      end

      # The persisted `score` column (synced on close) is the number the admin page shows.
      def self.overall_scores(ids)
        ProjectSatisfactionSurvey.where(id: ids).pluck(:id, :score)
                                 .to_h { |id, score| [id, score&.to_f&.round(2)] }
      end

      def opened_at
        record.created_at.to_date
      end

      def scope
        tracker = record.project_capsule&.project_tracker
        { project_tracker_id: tracker&.id, project: tracker&.name }
      end

      def url
        "#{ADMIN_HOST}/admin/project_satisfaction_surveys/#{record.id}"
      end

      def response_count
        record.project_satisfaction_survey_responses.count
      end

      def overall_score
        record.score&.to_f&.round(2)
      end

      # all_contributors_with_roles filtered to AdminUser.active — no responder rows involved.
      def expected_response_count
        record.expected_responders.size
      end

      def questions
        record.project_satisfaction_survey_questions.order(:id).to_a
      end

      def free_text_questions
        record.project_satisfaction_survey_free_text_questions.order(:id).to_a
      end

      def rating_answers
        ProjectSatisfactionSurveyQuestionResponse
          .joins(:project_satisfaction_survey_response)
          .where(project_satisfaction_survey_responses: { project_satisfaction_survey_id: record.id })
          .order(:id)
          .pluck(:project_satisfaction_survey_question_id, :sentiment, :context)
          .map { |(qid, s, c)| [qid, SurveyPresenter.sentiment_name(s), c] }
      end

      def free_text_answers
        ProjectSatisfactionSurveyFreeTextQuestionResponse
          .joins(:project_satisfaction_survey_response)
          .where(project_satisfaction_survey_responses: { project_satisfaction_survey_id: record.id })
          .order(:id)
          .pluck(:project_satisfaction_survey_free_text_question_id, :response)
      end
    end
  end
end
```

- [ ] **Step 6: Write the presenter (find + summary only; `results` and `list` come in Tasks 3 and 4)**

Create `app/services/mcp/survey_presenter.rb`:

```ruby
module Mcp
  # Adapts both survey families (Survey = studio-wide, ProjectSatisfactionSurvey = per
  # project) into one ANONYMOUS, aggregate-only shape for the MCP tools. Responses are
  # structurally anonymous in Stacks (no link from an answer to a person); this class keeps
  # it that way: it never loads responder rows, names, or emails — only counts, scores,
  # and (for closed surveys with enough responses) the free text itself.
  class SurveyPresenter
    KINDS = %w[studio project].freeze
    STATUSES = %w[open closed].freeze
    SMALL_SAMPLE_THRESHOLD = 5
    MIN_RESPONSES_FOR_TEXT = 3
    ADMIN_HOST = 'https://stacks.garden3d.net'.freeze
    SENTIMENT_ORDER = %w[strongly_disagree disagree neutral agree strongly_agree].freeze
    # Same 0–5 scale as SurveyQuestionResponse.sentiment_to_score / the admin pages.
    SENTIMENT_SCORES = {
      'strongly_disagree' => 0.0, 'disagree' => 1.25, 'neutral' => 2.5, 'agree' => 3.75, 'strongly_agree' => 5.0
    }.freeze

    attr_reader :kind, :adapter

    def self.adapter_class(kind)
      case kind
      when 'studio' then StudioAdapter
      when 'project' then ProjectAdapter
      else raise ArgumentError, "unknown survey kind #{kind.inspect}"
      end
    end

    def self.find(kind:, id:)
      return nil unless KINDS.include?(kind)

      record = adapter_class(kind).find(id)
      record && new(kind, record)
    end

    # Enum values arrive as names from pluck (Rails casts enum columns), but an unmapped
    # stored 0 comes back nil, and a raw integer is possible on older adapters — normalize
    # to the enum name or nil. Both families share the same mapping.
    def self.sentiment_name(value)
      value.is_a?(Integer) ? SurveyQuestionResponse.sentiments.key(value) : value
    end

    # pairs: [[question_id, sentiment_name_or_nil], ...] → mean of the per-question
    # averages over valid answers, or nil when no question has a valid answer.
    def self.mean_of_question_averages(pairs)
      averages = pairs.group_by(&:first).values.filter_map do |rows|
        scores = rows.filter_map { |(_, s)| SENTIMENT_SCORES[s] }
        scores.empty? ? nil : scores.sum / scores.size
      end
      averages.empty? ? nil : (averages.sum / averages.size).round(2)
    end

    def initialize(kind, record, response_count: nil, overall_score: nil, overall_score_known: false)
      @kind = kind
      @adapter = self.class.adapter_class(kind).new(record)
      @response_count = response_count
      @overall_score = overall_score
      @overall_score_known = overall_score_known
    end

    def id
      adapter.record.id
    end

    def closed?
      adapter.record.closed_at.present?
    end

    def status
      closed? ? 'closed' : 'open'
    end

    def response_count
      @response_count ||= adapter.response_count
    end

    def overall_score
      return nil unless closed?

      unless @overall_score_known
        @overall_score = adapter.overall_score
        @overall_score_known = true
      end
      @overall_score
    end

    def summary
      {
        kind: kind,
        id: id,
        title: adapter.record.title,
        status: status,
        opened_at: adapter.opened_at&.iso8601,
        closed_at: adapter.record.closed_at&.iso8601,
        scope: adapter.scope,
        response_count: response_count,
        overall_score: overall_score,
        url: adapter.url,
      }
    end
  end
end
```

- [ ] **Step 7: Run the presenter tests**

Run: `bin/rails test test/services/mcp/survey_presenter_test.rb`
Expected: 4 runs, 0 failures. If `overall_score` for the studio case is off, check that `pluck(:sentiment)` returns enum names (`"agree"`); `sentiment_name` handles integers as a fallback.

- [ ] **Step 8: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add test/support/survey_fixtures.rb test/test_helper.rb app/services/mcp/survey_presenter.rb app/services/mcp/survey_presenter/ test/services/mcp/survey_presenter_test.rb
git commit -m "feat: Mcp::SurveyPresenter find + summary over both survey families

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEDsb6YT6nSdDfjoNMKrnE"
```


---

### Task 3: Presenter `results`

**Files:**
- Modify: `app/services/mcp/survey_presenter.rb`
- Test: `test/services/mcp/survey_presenter_test.rb`

**Interfaces:**
- Produces: `Mcp::SurveyPresenter#results` → summary keys plus `description`, `expected_response_count`, `response_rate`; for closed surveys also `small_sample`, `questions[]` (`prompt average response_count distribution contexts`), `free_text_questions[]` (`prompt responses`), and `free_text_withheld` when under 3 responses; for open surveys `results_withheld: "survey is open"`.

- [ ] **Step 1: Write the failing tests**

Append inside `McpSurveyPresenterTest` (before the final `end`):

```ruby
  # ----- results -----

  test "closed studio results carry averages, distributions, sorted contexts and free text" do
    survey = build_studio_survey!(answers: [
      { sentiment: :agree, context: "zebra context", free_text: "zebra answer" },
      { sentiment: :strongly_agree, context: "apple context", free_text: "apple answer" },
      { sentiment: :disagree, context: nil, free_text: "" },
    ])
    r = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results

    assert_equal "How is it going?", r[:description]
    assert_equal true, r[:small_sample] # 3 responses < 5
    assert_nil r[:free_text_withheld]
    q = r[:questions].first
    assert_equal "I feel supported", q[:prompt]
    assert_in_delta 3.33, q[:average], 0.01 # (3.75 + 5 + 1.25) / 3
    assert_equal 3, q[:response_count]
    assert_equal({ strongly_disagree: 0, disagree: 1, neutral: 0, agree: 1, strongly_agree: 1 }, q[:distribution])
    assert_equal ["apple context", "zebra context"], q[:contexts]
    ft = r[:free_text_questions].first
    assert_equal "What should we stop doing?", ft[:prompt]
    assert_equal ["apple answer", "zebra answer"], ft[:responses]
    assert_in_delta 3.33, r[:overall_score], 0.01
  end

  test "closed project results use the persisted score and report a float response rate" do
    survey = build_project_survey!(answers: [{ sentiment: :agree }, { sentiment: :agree }, { sentiment: :neutral }])
    lead = build_admin!(email_prefix: "lead")
    other = build_admin!(email_prefix: "other")
    tracker = survey.project_capsule.project_tracker
    AccountLeadPeriod.create!(project_tracker: tracker, admin_user: lead, started_at: Date.new(2026, 1, 1))
    ProjectLeadPeriod.create!(project_tracker: tracker, admin_user: other, started_at: Date.new(2026, 1, 1))
    ProjectLeadPeriod.create!(project_tracker: tracker, admin_user: build_admin!(email_prefix: "third"), started_at: Date.new(2026, 1, 1))
    ProjectLeadPeriod.create!(project_tracker: tracker, admin_user: build_admin!(email_prefix: "fourth"), started_at: Date.new(2026, 1, 1))

    r = nil
    statements = sql_statements { r = Mcp::SurveyPresenter.find(kind: "project", id: survey.id).results }
    assert_empty statements.grep(/survey_responders/), "responder tables must never be queried"

    assert_equal 4, r[:expected_response_count]
    assert_in_delta 0.75, r[:response_rate], 0.001
    assert_in_delta survey.reload.score.to_f, r[:overall_score], 0.01
    assert_equal true, r[:small_sample]
  end

  test "response_rate is nil when nobody is expected" do
    survey = build_project_survey!(answers: [{ sentiment: :agree }])
    r = Mcp::SurveyPresenter.find(kind: "project", id: survey.id).results
    assert_equal 0, r[:expected_response_count]
    assert_nil r[:response_rate]
  end

  test "studio expected_response_count counts core members and never queries responders" do
    survey = build_studio_survey!(answers: [{ sentiment: :agree }], studio_name: "Beta")
    studio = Studio.find_by!(name: "Beta")
    make_admin_user!(studio, Date.new(2026, 1, 1), nil, "core-beta@sanctuary.computer")

    statements = sql_statements do
      r = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results
      assert_equal 1, r[:expected_response_count]
    end
    offenders = statements.grep(/survey_responders/)
    assert_empty offenders, "responder tables must never be queried: #{offenders.inspect}"
  end

  test "free text is withheld under three responses but scores remain" do
    survey = build_studio_survey!(answers: [
      { sentiment: :agree, context: "c1", free_text: "f1" },
      { sentiment: :neutral, context: "c2", free_text: "f2" },
    ])
    r = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results

    assert_equal "fewer than 3 responses", r[:free_text_withheld]
    assert_equal [], r[:questions].first[:contexts]
    assert_equal [], r[:free_text_questions].first[:responses]
    assert_in_delta 3.13, r[:questions].first[:average], 0.01
    assert_equal 2, r[:questions].first[:response_count]
  end

  test "small_sample flips at five responses" do
    four = build_studio_survey!(title: "Four", answers: Array.new(4) { { sentiment: :agree } })
    five = build_studio_survey!(title: "Five", answers: Array.new(5) { { sentiment: :agree } })
    assert_equal true, Mcp::SurveyPresenter.find(kind: "studio", id: four.id).results[:small_sample]
    assert_equal false, Mcp::SurveyPresenter.find(kind: "studio", id: five.id).results[:small_sample]
  end

  test "a closed survey with no responses is safe" do
    survey = build_studio_survey!(answers: [])
    r = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results
    assert_nil r[:overall_score]
    assert_equal 1, r[:questions].size
    assert_nil r[:questions].first[:average]
    assert_equal 0, r[:questions].first[:response_count]
    assert_equal [], r[:free_text_questions].first[:responses]
  end

  test "an invalid stored sentiment of 0 is excluded from averages and distributions" do
    survey = build_studio_survey!(answers: [{ sentiment: :agree }, { sentiment: :agree }, { sentiment: :agree }])
    # update_column bypasses the enum cast (update_all(sentiment: 0) raises ArgumentError).
    survey.survey_responses.first.survey_question_responses.first.update_column(:sentiment, 0)

    q = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id).results[:questions].first
    assert_equal 2, q[:response_count]
    assert_in_delta 3.75, q[:average], 0.01
    assert_equal 2, q[:distribution][:agree]
  end

  test "open surveys withhold results entirely" do
    survey = build_project_survey!(closed: false, answers: [{ sentiment: :agree, context: "secret", free_text: "secret" }])
    r = Mcp::SurveyPresenter.find(kind: "project", id: survey.id).results

    assert_equal "survey is open", r[:results_withheld]
    assert_equal "Retro", r[:description]
    assert_equal 1, r[:response_count]
    refute r.key?(:questions)
    refute r.key?(:free_text_questions)
    refute r.key?(:small_sample)
    refute_includes r.to_json, "secret"
  end

  test "payloads never contain a responder's name or email" do
    survey = build_studio_survey!(answers: Array.new(3) { { sentiment: :agree, context: "fine", free_text: "fine" } })
    responder = AdminUser.create!(email: "very-distinctive-responder@sanctuary.computer",
                                  password: "password12345", password_confirmation: "password12345")
    SurveyResponder.create!(survey: survey, admin_user: responder)

    p = Mcp::SurveyPresenter.find(kind: "studio", id: survey.id)
    json = [p.summary, p.results].to_json
    refute_includes json, "very-distinctive-responder"
    refute_includes json, "@sanctuary.computer"
  end
```

(`AdminUser` has no name columns — `AdminUser#name` returns the email — so the email is the only identity to guard.)

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/services/mcp/survey_presenter_test.rb`
Expected: the new tests error with `NoMethodError: undefined method 'results'`; the Task 2 tests still pass.

- [ ] **Step 3: Implement `results`**

In `app/services/mcp/survey_presenter.rb`, add after `summary`:

```ruby
    def results
      expected = adapter.expected_response_count
      base = summary.merge(
        description: adapter.record.description,
        expected_response_count: expected,
        response_rate: expected.zero? ? nil : response_count.fdiv(expected).round(2),
      )
      return base.merge(results_withheld: 'survey is open') unless closed?

      text_allowed = response_count >= MIN_RESPONSES_FOR_TEXT
      payload = base.merge(
        small_sample: response_count < SMALL_SAMPLE_THRESHOLD,
        questions: question_results(text_allowed),
        free_text_questions: free_text_results(text_allowed),
      )
      payload[:free_text_withheld] = "fewer than #{MIN_RESPONSES_FOR_TEXT} responses" unless text_allowed
      payload
    end

    private

    # Text arrays are SORTED, never in insertion order: DB order would align index i of every
    # array to the same respondent, reconstructing one full questionnaire per index.
    def question_results(text_allowed)
      by_question = adapter.rating_answers.group_by(&:first)
      adapter.questions.map do |question|
        rows = by_question.fetch(question.id, [])
        valid = rows.map { |(_, sentiment, _)| sentiment }.select { |s| SENTIMENT_SCORES.key?(s) }
        {
          prompt: question.prompt,
          average: valid.empty? ? nil : (valid.sum { |s| SENTIMENT_SCORES[s] } / valid.size).round(2),
          response_count: valid.size,
          distribution: SENTIMENT_ORDER.each_with_object({}) { |s, h| h[s.to_sym] = valid.count(s) },
          contexts: text_allowed ? rows.map(&:last).select(&:present?).sort : [],
        }
      end
    end

    def free_text_results(text_allowed)
      by_question = adapter.free_text_answers.group_by(&:first)
      adapter.free_text_questions.map do |question|
        answers = by_question.fetch(question.id, []).map(&:last).select(&:present?)
        { prompt: question.prompt, responses: text_allowed ? answers.sort : [] }
      end
    end
```

- [ ] **Step 4: Run the presenter tests**

Run: `bin/rails test test/services/mcp/survey_presenter_test.rb`
Expected: all pass. If the project `expected_response_count` test yields 0, confirm `build_admin!` creates a current `FullTimePeriod` (it does by default) — `ProjectSatisfactionSurvey#expected_responders` filters by `AdminUser.active`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/services/mcp/survey_presenter.rb test/services/mcp/survey_presenter_test.rb
git commit -m "feat: anonymous aggregate survey results in Mcp::SurveyPresenter

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEDsb6YT6nSdDfjoNMKrnE"
```

---

### Task 4: Presenter `list`

**Files:**
- Modify: `app/services/mcp/survey_presenter.rb`
- Test: `test/services/mcp/survey_presenter_test.rb`

**Interfaces:**
- Produces: `Mcp::SurveyPresenter.list(kind: nil, status: nil, closed_range: nil, limit: 50, offset: 0)` → `Array<SurveyPresenter>` sorted newest first by `closed_at || opened_at`, drafts excluded, with `response_count` and `overall_score` pre-filled (no N+1).

- [ ] **Step 1: Write the failing tests**

Append inside `McpSurveyPresenterTest`:

```ruby
  # ----- list -----

  test "list merges both kinds newest first and excludes drafts" do
    older = build_studio_survey!(title: "Older", answers: [{ sentiment: :agree }])
    older.update!(closed_at: Time.zone.parse("2026-05-01 12:00:00"))
    newer = build_project_survey!(title: "Newer", answers: [{ sentiment: :agree }]) # closed 2026-07-01
    open_survey = build_studio_survey!(title: "Open", closed: false, opens_at: Date.new(2026, 7, 15))
    Survey.create!(title: "Draft", description: "d", opens_at: Date.new(2026, 9, 1))

    rows = Mcp::SurveyPresenter.list
    assert_equal ["Open", "Newer", "Older"], rows.map { |p| p.summary[:title] }
    assert_equal 1, rows[1].summary[:response_count]
    assert_in_delta 3.75, rows[1].summary[:overall_score], 0.01
  end

  test "list filters by kind and status" do
    build_studio_survey!(title: "Studio closed", answers: [{ sentiment: :agree }])
    build_studio_survey!(title: "Studio open", closed: false, opens_at: Date.new(2026, 7, 15))
    build_project_survey!(title: "Project closed")

    assert_equal ["Studio open", "Studio closed"], Mcp::SurveyPresenter.list(kind: "studio").map { |p| p.summary[:title] }
    assert_equal ["Project closed"], Mcp::SurveyPresenter.list(kind: "project").map { |p| p.summary[:title] }
    assert_equal ["Studio open"], Mcp::SurveyPresenter.list(status: "open").map { |p| p.summary[:title] }
    assert_equal ["Studio closed", "Project closed"].sort,
                 Mcp::SurveyPresenter.list(status: "closed").map { |p| p.summary[:title] }.sort
  end

  test "list applies a closed range (both bounds) and implies closed" do
    early = build_studio_survey!(title: "Early", answers: [])
    early.update!(closed_at: Time.zone.parse("2026-03-01 12:00:00"))
    build_studio_survey!(title: "Mid", answers: []) # 2026-07-01
    build_studio_survey!(title: "Open", closed: false, opens_at: Date.new(2026, 7, 15))

    range = Time.zone.parse("2026-06-01")..Time.zone.parse("2026-08-01")
    assert_equal ["Mid"], Mcp::SurveyPresenter.list(closed_range: range).map { |p| p.summary[:title] }
    after_only = (Time.zone.parse("2026-06-01")..)
    assert_equal ["Mid"], Mcp::SurveyPresenter.list(closed_range: after_only).map { |p| p.summary[:title] }
  end

  test "list paginates with offset and limit" do
    3.times { |i| build_project_survey!(title: "P#{i}") }
    page = Mcp::SurveyPresenter.list(limit: 2, offset: 2)
    assert_equal 1, page.size
    assert_equal 2, Mcp::SurveyPresenter.list(limit: 2).size
  end

  test "list stays at a bounded query count" do
    5.times { |i| build_project_survey!(title: "P#{i}", answers: [{ sentiment: :agree }]) }
    5.times { |i| build_studio_survey!(title: "S#{i}", studio_name: "St#{i}", answers: [{ sentiment: :agree }]) }

    statements = sql_statements { Mcp::SurveyPresenter.list.each(&:summary) }
    selects = statements.grep(/\ASELECT/i)
    assert_operator selects.size, :<=, 15, "expected a bounded query count, got #{selects.size}:\n#{selects.join("\n")}"
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/services/mcp/survey_presenter_test.rb -n /list/`
Expected: `NoMethodError: undefined method 'list' for Mcp::SurveyPresenter`.

- [ ] **Step 3: Implement `list`**

In `app/services/mcp/survey_presenter.rb`, add these class methods after `self.find`:

```ruby
    # kind: 'studio' | 'project' | nil (both); status: 'open' | 'closed' | nil (both);
    # closed_range: Range on closed_at (implies closed). Drafts are never returned.
    # Sorted newest first by (closed_at || opened_at); offset/limit applied after sorting.
    def self.list(kind: nil, status: nil, closed_range: nil, limit: 50, offset: 0)
      status = 'closed' if status.nil? && closed_range
      kinds = kind ? [kind] : KINDS
      rows = kinds.flat_map { |k| rows_for(k, status, closed_range) }
      rows.sort_by { |p| -p.sort_time.to_f }.drop(offset).first(limit)
    end

    # One preload + one grouped count + one grouped score query per kind (no N+1).
    def self.rows_for(kind, status, closed_range)
      klass = adapter_class(kind)
      scope = klass.visible_scope(status)
      scope = scope.where(closed_at: closed_range) if closed_range
      records = klass.preload(scope).to_a
      ids = records.map(&:id)
      counts = klass.response_counts(ids)
      scores = klass.overall_scores(ids)
      records.map do |record|
        new(kind, record, response_count: counts.fetch(record.id, 0),
                          overall_score: scores[record.id], overall_score_known: true)
      end
    end
```

And add this instance method after `status`:

```ruby
    # Normalized to Time: opened_at is a Date, closed_at a TimeWithZone.
    def sort_time
      adapter.record.closed_at || adapter.opened_at.in_time_zone
    end
```

- [ ] **Step 4: Run the presenter tests**

Run: `bin/rails test test/services/mcp/survey_presenter_test.rb`
Expected: all pass. If the query-count test fails, print the statements it lists and add the missing `includes` to the adapter's `preload`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/services/mcp/survey_presenter.rb test/services/mcp/survey_presenter_test.rb
git commit -m "feat: Mcp::SurveyPresenter.list with filters, sorting and bounded queries

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEDsb6YT6nSdDfjoNMKrnE"
```

---

### Task 5: `list_surveys` tool

**Files:**
- Create: `app/services/mcp/list_surveys_tool.rb`
- Test: `test/services/mcp/list_surveys_tool_test.rb`

**Interfaces:**
- Consumes: `Mcp::SurveyPresenter.list(...)`, `Mcp::SurveyPresenter::KINDS/STATUSES`, `Mcp::DateRange.parse`, `Mcp::Responses`.
- Produces: `Mcp::ListSurveysTool.call(kind: nil, status: nil, closed_after: nil, closed_before: nil, limit: 50, offset: 0, server_context:)` → array payload of `summary` hashes.

- [ ] **Step 1: Write the failing tests**

Create `test/services/mcp/list_surveys_tool_test.rb`:

```ruby
require "test_helper"

class McpListSurveysToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include SurveyFixtures

  setup { travel_to Time.zone.parse(SurveyFixtures::FROZEN_NOW) }
  teardown { travel_back }

  test "returns an array of survey summaries" do
    build_project_survey!(title: "P", answers: [{ sentiment: :agree }])
    payload = mcp_payload(Mcp::ListSurveysTool.call(server_context: {}))
    assert_kind_of Array, payload
    assert_equal "P", payload.first["title"]
    assert_equal "project", payload.first["kind"]
    assert_equal 1, payload.first["response_count"]
  end

  test "rejects unknown kind and status with the valid values" do
    err = mcp_payload(Mcp::ListSurveysTool.call(kind: "client", server_context: {}))
    assert_equal "Unknown kind 'client'. Valid kinds: studio, project", err["error"]
    err = mcp_payload(Mcp::ListSurveysTool.call(status: "draft", server_context: {}))
    assert_equal "Unknown status 'draft'. Valid statuses: open, closed", err["error"]
  end

  test "closed_after alone implies closed; combined with status open it errors" do
    build_studio_survey!(title: "Closed", answers: [])
    build_studio_survey!(title: "Open", closed: false, opens_at: Date.new(2026, 7, 15))

    payload = mcp_payload(Mcp::ListSurveysTool.call(closed_after: "2026-06-01", server_context: {}))
    assert_equal ["Closed"], payload.map { |r| r["title"] }

    err = mcp_payload(Mcp::ListSurveysTool.call(closed_after: "2026-06-01", status: "open", server_context: {}))
    assert_equal "closed_after/closed_before cannot be combined with status 'open'", err["error"]
  end

  test "clamps limit and offset" do
    3.times { |i| build_project_survey!(title: "P#{i}") }
    assert_equal 1, mcp_payload(Mcp::ListSurveysTool.call(limit: 0, server_context: {})).size
    assert_equal 3, mcp_payload(Mcp::ListSurveysTool.call(limit: 999, server_context: {})).size
    assert_equal 3, mcp_payload(Mcp::ListSurveysTool.call(offset: -5, server_context: {})).size
    assert_equal 200, Mcp::ListSurveysTool::MAX_LIMIT
    assert_equal 1, Mcp::ListSurveysTool::MIN_LIMIT
  end

  test "declares itself read-only" do
    assert_equal "list_surveys", Mcp::ListSurveysTool.tool_name
    assert Mcp::ListSurveysTool.annotations.read_only_hint
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/services/mcp/list_surveys_tool_test.rb`
Expected: `NameError: uninitialized constant Mcp::ListSurveysTool`.

- [ ] **Step 3: Implement the tool**

Create `app/services/mcp/list_surveys_tool.rb`:

```ruby
module Mcp
  class ListSurveysTool < MCP::Tool
    tool_name 'list_surveys'
    description 'READ: list studio-wide and project satisfaction surveys, newest first (closed ' \
                'surveys by closed_at, open ones by opened_at). Filter by kind (studio|project), ' \
                'status (open|closed), and a closed_at range. Survey responses are ANONYMOUS by ' \
                'design: this tool exposes counts only, never responders. Each row carries ' \
                'overall_score (0-5, closed surveys only) so trends across surveys of the same ' \
                'scope can be read without extra calls. Use get_survey_results for per-question ' \
                'scores and free text.'

    MIN_LIMIT = 1
    MAX_LIMIT = 200
    DEFAULT_LIMIT = 50

    input_schema(
      properties: {
        kind: { type: 'string', description: "Optional: #{SurveyPresenter::KINDS.join(' | ')}. Default both." },
        status: { type: 'string', description: "Optional: #{SurveyPresenter::STATUSES.join(' | ')}. Default both (drafts are never listed)." },
        closed_after: { type: 'string', description: 'ISO8601 lower bound on closed_at (inclusive). Implies status closed.' },
        closed_before: { type: 'string', description: 'ISO8601 upper bound on closed_at (inclusive). Implies status closed.' },
        limit: { type: 'integer', description: "Rows per page (default #{DEFAULT_LIMIT}, clamped #{MIN_LIMIT}..#{MAX_LIMIT})." },
        offset: { type: 'integer', description: 'Rows to skip after sorting, for pagination (default 0).' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(kind: nil, status: nil, closed_after: nil, closed_before: nil,
                  limit: DEFAULT_LIMIT, offset: 0, server_context:)
      kind = kind.presence
      status = status.presence
      if kind && !SurveyPresenter::KINDS.include?(kind)
        return Responses.error("Unknown kind '#{kind}'. Valid kinds: #{SurveyPresenter::KINDS.join(', ')}")
      end
      if status && !SurveyPresenter::STATUSES.include?(status)
        return Responses.error("Unknown status '#{status}'. Valid statuses: #{SurveyPresenter::STATUSES.join(', ')}")
      end

      range = Mcp::DateRange.parse(closed_after, closed_before)
      if range && status == 'open'
        return Responses.error("closed_after/closed_before cannot be combined with status 'open'")
      end

      limit = limit.to_i.clamp(MIN_LIMIT, MAX_LIMIT)
      offset = [offset.to_i, 0].max

      rows = SurveyPresenter.list(kind: kind, status: status, closed_range: range, limit: limit, offset: offset)
      Responses.ok(rows.map(&:summary))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ListSurveysTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('list_surveys failed; the error was logged')
    end
  end
end
```

- [ ] **Step 4: Run the tool tests**

Run: `bin/rails test test/services/mcp/list_surveys_tool_test.rb`
Expected: 5 runs, 0 failures. If `annotations.read_only_hint` is not how the gem exposes annotations, check another tool test (`grep -rn "annotations" test/services/mcp/`) and match; if none exists, replace that assertion with `assert_equal "list_surveys", Mcp::ListSurveysTool.tool_name` only.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/services/mcp/list_surveys_tool.rb test/services/mcp/list_surveys_tool_test.rb
git commit -m "feat: list_surveys MCP tool

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEDsb6YT6nSdDfjoNMKrnE"
```

---

### Task 6: `get_survey_results` tool

**Files:**
- Create: `app/services/mcp/get_survey_results_tool.rb`
- Test: `test/services/mcp/get_survey_results_tool_test.rb`

**Interfaces:**
- Consumes: `Mcp::SurveyPresenter.find(kind:, id:)`, `#results`.
- Produces: `Mcp::GetSurveyResultsTool.call(kind:, id:, server_context:)`.

- [ ] **Step 1: Write the failing tests**

Create `test/services/mcp/get_survey_results_tool_test.rb`:

```ruby
require "test_helper"

class McpGetSurveyResultsToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include SurveyFixtures

  setup { travel_to Time.zone.parse(SurveyFixtures::FROZEN_NOW) }
  teardown { travel_back }

  test "returns anonymous aggregate results with free text for a closed survey" do
    survey = build_project_survey!(answers: [
      { sentiment: :agree, context: "budget was tight", free_text: "more discovery" },
      { sentiment: :neutral, context: "ok", free_text: "less scope creep" },
      { sentiment: :agree, context: nil, free_text: "keep the rituals" },
    ])
    payload = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "project", id: survey.id, server_context: {}))

    assert_equal "closed", payload["status"]
    assert_equal 3, payload["response_count"]
    assert_equal ["budget was tight", "ok"], payload["questions"].first["contexts"]
    assert_equal ["keep the rituals", "less scope creep", "more discovery"], payload["free_text_questions"].first["responses"]
    assert_equal true, payload["small_sample"]
  end

  test "withholds results for an open survey" do
    survey = build_studio_survey!(closed: false, answers: [{ sentiment: :agree, free_text: "hidden" }])
    payload = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "studio", id: survey.id, server_context: {}))
    assert_equal "survey is open", payload["results_withheld"]
    refute_includes payload.to_json, "hidden"
  end

  test "errors for unknown kind, missing id, and an id of the other kind" do
    project = build_project_survey!
    err = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "client", id: project.id, server_context: {}))
    assert_equal "Unknown kind 'client'. Valid kinds: studio, project", err["error"]
    err = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "project", id: 999_999, server_context: {}))
    assert_equal "Survey not found", err["error"]
    err = mcp_payload(Mcp::GetSurveyResultsTool.call(kind: "studio", id: project.id, server_context: {}))
    assert_equal "Survey not found", err["error"]
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/services/mcp/get_survey_results_tool_test.rb`
Expected: `NameError: uninitialized constant Mcp::GetSurveyResultsTool`.

- [ ] **Step 3: Implement the tool**

Create `app/services/mcp/get_survey_results_tool.rb`:

```ruby
module Mcp
  class GetSurveyResultsTool < MCP::Tool
    tool_name 'get_survey_results'
    description 'READ: one survey with ANONYMOUS aggregate results. For a CLOSED survey: ' \
                'per-question averages (0-5), Likert distributions, the optional free-text ' \
                'context behind each score, and free-text answers (text arrays are sorted, and ' \
                'withheld entirely under 3 responses — see free_text_withheld). For an OPEN ' \
                'survey: metadata and response rate only (results_withheld). Responses cannot ' \
                'be tied to a person and must never be attributed, guessed at, or quoted ' \
                'verbatim into team-visible stores; small_sample flags surveys with fewer than ' \
                '5 responses. Never combine with contributor-listing tools for the same project ' \
                'or studio.'

    input_schema(
      properties: {
        kind: { type: 'string', description: SurveyPresenter::KINDS.join(' | ') },
        id: { type: 'integer', description: 'Survey id from list_surveys (ids are per kind).' },
      },
      required: %w[kind id]
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(kind:, id:, server_context:)
      kind = kind.to_s
      unless SurveyPresenter::KINDS.include?(kind)
        return Responses.error("Unknown kind '#{kind}'. Valid kinds: #{SurveyPresenter::KINDS.join(', ')}")
      end

      presenter = SurveyPresenter.find(kind: kind, id: id.to_i)
      return Responses.error('Survey not found') unless presenter

      Responses.ok(presenter.results)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetSurveyResultsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_survey_results failed; the error was logged')
    end
  end
end
```

- [ ] **Step 4: Run the tool tests**

Run: `bin/rails test test/services/mcp/get_survey_results_tool_test.rb`
Expected: 3 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/services/mcp/get_survey_results_tool.rb test/services/mcp/get_survey_results_tool_test.rb
git commit -m "feat: get_survey_results MCP tool

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEDsb6YT6nSdDfjoNMKrnE"
```

---

### Task 7: Register the tools + endpoint round-trips

**Files:**
- Modify: `app/services/mcp/server.rb` (the `TOOLS` array)
- Modify: `test/integration/mcp_endpoint_test.rb` (the `tools/list` test's sorted array, and new round-trip tests)

**Interfaces:**
- Consumes: `Mcp::ListSurveysTool`, `Mcp::GetSurveyResultsTool`, the existing `call_tool(name, arguments)` helper in the integration test.

- [ ] **Step 1: Update the tool-name assertion and add round-trips (failing)**

In `test/integration/mcp_endpoint_test.rb`, inside the test `"POST tools/list with valid key returns search tool"`, replace the `assert_equal %w[...]` literal with the same list plus the two new names, kept sorted:

```ruby
    assert_equal %w[explore_okr find_contributor get_ar_aging get_capacity get_client_revenue get_document get_enterprise_health get_executive_dashboard get_invoice_passes get_membership_stats get_okr_grid get_person_metrics get_project_burnup get_project_contributors get_project_cost_breakdown get_quarterly_report get_resourcing_projections get_studio_health get_survey_results list_documents list_open_admin_tasks list_overdue_invoices list_payable_bills list_project_trackers list_projects_at_risk list_sources list_surveys search], tool_names.sort,
      "Expected all registered tools, got: #{tool_names.inspect}"
```

Add `include SurveyFixtures` directly under `include ActiveSupport::Testing::TimeHelpers` at the top of the class, then add these tests at the end of the class:

```ruby
  test "tools/call round-trip for list_surveys and get_survey_results" do
    travel_to Time.zone.parse(SurveyFixtures::FROZEN_NOW)
    survey = build_project_survey!(answers: [
      { sentiment: :agree, context: "tight", free_text: "more discovery" },
      { sentiment: :agree, context: "fine", free_text: "keep retros" },
      { sentiment: :neutral, context: nil, free_text: "clearer scope" },
    ])

    rows = call_tool("list_surveys", { status: "closed", closed_after: "2026-06-01" })
    assert_equal [survey.id], rows.map { |r| r["id"] }
    assert_equal "project", rows.first["kind"]
    assert_equal 3, rows.first["response_count"]

    payload = call_tool("get_survey_results", { kind: "project", id: survey.id })
    assert_equal "closed", payload["status"]
    assert_equal ["clearer scope", "keep retros", "more discovery"], payload["free_text_questions"].first["responses"]
    refute_includes response.body, "@example.com"
  ensure
    travel_back
  end
```

- [ ] **Step 2: Run to verify the tools/list test fails**

Run: `bin/rails test test/integration/mcp_endpoint_test.rb`
Expected: the `tools/list` assertion fails (new names missing) and the round-trip fails with an unknown-tool error.

- [ ] **Step 3: Register the tools**

In `app/services/mcp/server.rb`, add the two constants to the end of the `TOOLS` array, after `Mcp::GetClientRevenueTool,`:

```ruby
      Mcp::ListSurveysTool,
      Mcp::GetSurveyResultsTool,
```

- [ ] **Step 4: Run the integration tests**

Run: `bin/rails test test/integration/mcp_endpoint_test.rb`
Expected: all pass.

- [ ] **Step 5: Run every test touched by this branch together**

Run: `bin/rails test test/models/survey_test.rb test/services/mcp/ test/integration/mcp_endpoint_test.rb`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/services/mcp/server.rb test/integration/mcp_endpoint_test.rb
git commit -m "feat: register list_surveys + get_survey_results on the read MCP server

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEDsb6YT6nSdDfjoNMKrnE"
```

---

### Task 8: Go-live checklist doc

**Files:**
- Create: `docs/stacks-surveys-observations-golive.md`

- [ ] **Step 1: Write the doc**

Create `docs/stacks-surveys-observations-golive.md`:

```markdown
# Stacks Surveys Observations — Go-Live Checklist

Contributor surveys (studio-wide `Survey` + `ProjectSatisfactionSurvey`) are authored as an
**observed** source in stacksbot. The stacks-side enabler is the pair of read-only MCP tools
`list_surveys` / `get_survey_results`. The Notion artifacts are authored **Draft / disabled** so
the rubric's behaviour is validated before the sensor writes to the team-facing Observations DB.

Spec: `docs/superpowers/specs/2026-09-09-survey-observations-mcp-design.md`.

## What's already done
- **stacks:** `list_surveys` (kind/status/closed-range filters, counts + overall_score only)
  and `get_survey_results` (anonymous aggregates; free text only for closed surveys with ≥3
  responses, arrays sorted; open surveys withhold results). No responder identity ever crosses
  the wire.
- **Notion Sources DB → "Stacks Surveys"** (slug `stacks-surveys`, Backing Tool `stacks MCP`,
  Cite Label `Stacks/Surveys`, **Status: Draft**): `## Fetch` (close summary + ≤3 themes per
  newly closed survey, gated on the `:closed` Source Key; stalled open surveys 14–90 days old),
  `## Privacy` (binding: paraphrase, never attribute, never call contributor-listing tools for a
  survey's project/studio, never set People), `## Search`, `## Cite`.
- **Notion Jobs DB → "Observe: Stacks Surveys"** (daily `0 7 * * *` ET, `Deliver To: none`,
  **Enabled: OFF**).
- **Observations DB:** `Source` select option `Stacks/Surveys` added.

## To go live (you, when ready)
1. **Deploy stacks** so the two tools are live, then confirm from the agent:
   `list_surveys(status: "closed", limit: 3)` returns rows and
   `get_survey_results(kind, id)` on one of them returns `questions` / `free_text_questions`
   with no names or emails anywhere in the payload.
2. **Flip the Sources row to Active** (needed for the reconciler to materialize the contract
   into `skills/sources/stacks-surveys.md`). Recall can then answer "how do contributors feel
   about X" over closed surveys.
3. **Dry run:** trigger the `observe` skill for source `stacks-surveys` with an explicit window
   that contains one known closed survey (e.g. "the last 90 days"). Verify:
   - exactly one row with Source Key `stacks:survey:<kind>:<id>:closed` plus ≤3
     `…:theme:<slug>` rows, `Source = Stacks/Surveys`, Observed At = the survey's closed_at,
     Source Ref opens the Stacks admin results page;
   - no verbatim quotes, no attribution, People relation empty, Entities blank;
   - a survey with fewer than 3 responses produced the `:closed` row only;
   - re-run immediately → **zero** new rows.
4. **Seed history (optional):** the automatic window is capped at 14 days. Trigger the skill
   once more with "the last 365 days" to observe every survey closed in the past year. The
   `:closed` gate keeps this idempotent.
5. **Enable the sensor:** `Observe: Stacks Surveys` → `Enabled = ✅`. Its New observations flow
   into the existing Observations Digest and the weekly Propose Challenges pass.
6. **Watch the first few digests.** Tune theme count, salience thresholds, or the stalled
   bounds in the Sources row's `## Fetch` — no code change.

## Known v1 limitations
- A survey that is reopened and re-closed keeps its original `:closed` key and is not
  re-observed.
- Themes are judged by the agent from free text; a survey with <3 responses yields no themes.
- Cross-survey synthesis is left to `propose-challenges` / the nightly distiller (by decision).
```

- [ ] **Step 2: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add docs/stacks-surveys-observations-golive.md
git commit -m "docs: go-live checklist for the Stacks Surveys observed source

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SEDsb6YT6nSdDfjoNMKrnE"
```

---

### Task 9 (controller session, not a subagent): Notion authoring — Part B

Done by the controlling session with the Notion MCP after the PR is open. Everything is Draft / disabled.

- [ ] **Step 1: Sources row.** Create a page in data source `collection://576eb9a8-8a01-4d1e-a00f-8efd361143b8` with properties `Name: Stacks Surveys`, `Slug: stacks-surveys`, `Backing Tool: stacks MCP`, `Cite Label: Stacks/Surveys`, `Status: Draft`, and the body from spec §B1 verbatim (the `## Fetch`, `## Privacy (binding)`, `## Source Key`, `## Source Ref`, `## Search`, `## Cite` sections).
- [ ] **Step 2: Job row.** Fetch the Jobs DB `329131fea2c78015ba3eed7476974b9b` to get its data source URL and property names, then create `Observe: Stacks Surveys` with `Cron: 0 7 \* \* \*`, `Timezone: America/New_York`, `Deliver To: none`, `Model: anthropic/claude-sonnet-5`, `Enabled` unchecked, body from spec §B2. After creation, edit the body to replace `<THIS PAGE'S NOTION ID>` with the new page's id (dashless, as `observe-window.mjs --job` expects — copy the format from the "Observe: Google Groups" job body).
- [ ] **Step 3: Source option.** Fetch the Observations DB `390131fea2c7808bb216c38b46c3ba55`; if `Source` has no `Stacks/Surveys` option, add it with `notion-update-data-source` (append to the existing options — never remove any).
- [ ] **Step 4:** Record the three URLs in the PR description.

---

### Task 10 (controller session): full suite + PR

- [ ] **Step 1:** Confirm no other `rails test` process is running: `ps -o pid,etime,command -ax | grep "[r]ails test"`.
- [ ] **Step 2:** Run the full suite, skipping the live-Google ETL rake test:
  `bin/rails test $(ls test/**/*_test.rb | grep -v etl_rake)` — expected ~1,330 runs, 0 failures (the `AdminUserTest` salary-window test is a known 20:00–24:00 ET false failure).
- [ ] **Step 3:** Push the branch and open the PR against `main` with the spec, plan, go-live doc, and the three Notion URLs linked; end the description with the attribution block.
- [ ] **Step 4:** Adversarial review of the PR diff by a fresh subagent; fix findings; re-run the touched tests; push.
