# Studio Survey: duplicate fix + accurate responders — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix Studio Survey duplication, add elevated-service contributors to expected responders, and make the results table show the union of expected + actual responders as of the survey's reference date.

**Architecture:** Small model-level changes on `Survey`, `Contributor`, `Studio`, plus the ActiveAdmin show view. Elevated service is computed in bulk (a few aggregate queries) to stay fast when the garden3d studio expands to "everyone."

**Tech Stack:** Rails 6.1, ActiveAdmin, Minitest, Postgres.

## Global Constraints

- Scope is `Survey` (Studio Surveys) only. Do NOT touch `ProjectSatisfactionSurvey`.
- Elevated-service threshold, verbatim: **total hours ≥ 120 OR total income (ContributorPayout + Trueup) ≥ 9000** in a month.
- "3 months straight" = the **3 completed calendar months** strictly before `reference_date.beginning_of_month`.
- `reference_date = opens_at&.to_date || Date.today`.
- garden3d membership = **everyone** (all AdminUsers who have a `forecast_person`); other studios = `studio_membership` active on `reference_date`.
- Run tests with `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` in the env (macOS fork-safety).
- Keep `expected_responders` semantics = expected-only (drives "(N expected)" + to-do). The union is a display-only concern (`responder_status`).

---

### Task 1: Fix `Survey.clone_from` free-text association bug

**Files:**
- Modify: `app/models/survey.rb` (the `self.clone_from` method, free-text-questions loop)
- Test: `test/models/survey_test.rb`

**Interfaces:**
- Produces: `Survey.clone_from(prev_survey)` returns a saved clone carrying survey_questions, survey_free_text_questions, and survey_studios.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/survey_test.rb  (create if missing; class ProjectTrackerTest-style header)
require "test_helper"

class SurveyTest < ActiveSupport::TestCase
  test "clone_from copies free-text questions into the correct association" do
    studio = Studio.create!(name: "S1", mini_name: "s1")
    survey = Survey.create!(title: "Original", opens_at: Date.today)
    survey.survey_questions.create!(prompt: "Q1")
    survey.survey_free_text_questions.create!(prompt: "FT1")
    survey.survey_studios.create!(studio: studio)

    clone = Survey.clone_from(survey)

    assert_equal 1, clone.survey_questions.count
    assert_equal 1, clone.survey_free_text_questions.count
    assert_equal 1, clone.survey_studios.count
    assert_equal "Cloned from: Original", clone.title
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test test/models/survey_test.rb -n "/clone_from copies free-text/"`
Expected: FAIL with `ActiveRecord::AssociationTypeMismatch: SurveyQuestion expected, got SurveyFreeTextQuestion`.

- [ ] **Step 3: Fix the association in `clone_from`**

In `app/models/survey.rb`, the free-text loop currently reads `new_survey.survey_questions << n`. Change it:

```ruby
      prev_survey.survey_free_text_questions.each do |sq|
        n = sq.dup
        n.survey = new_survey
        new_survey.survey_free_text_questions << n
      end
```

- [ ] **Step 4: Run test, verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/survey.rb test/models/survey_test.rb
git commit -m "fix(survey): clone_from copies free-text questions to correct association"
```

---

### Task 2: Shared elevated-service threshold predicate

**Files:**
- Modify: `app/models/contributor.rb` (add constants + `self.elevated_service?`; refactor the `elevated_service:` line in `all_items_grouped_by_month`)
- Test: `test/models/contributor_test.rb`

**Interfaces:**
- Produces: `Contributor::ELEVATED_SERVICE_MIN_HOURS = 120`, `Contributor::ELEVATED_SERVICE_MIN_INCOME = 9_000`, `Contributor.elevated_service?(total_hours:, total_income:) -> Boolean`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/contributor_test.rb (create if missing)
require "test_helper"

class ContributorTest < ActiveSupport::TestCase
  test "elevated_service? thresholds on hours and income" do
    assert_not Contributor.elevated_service?(total_hours: 119, total_income: 8_999)
    assert     Contributor.elevated_service?(total_hours: 120, total_income: 0)
    assert     Contributor.elevated_service?(total_hours: 0,   total_income: 9_000)
    assert_not Contributor.elevated_service?(total_hours: 0,   total_income: 8_999.99)
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test test/models/contributor_test.rb -n "/elevated_service. thresholds/"`
Expected: FAIL with `NoMethodError: undefined method 'elevated_service?'`.

- [ ] **Step 3: Add constants + predicate, refactor the existing line**

Add near the top of `class Contributor`:

```ruby
  ELEVATED_SERVICE_MIN_HOURS  = 120
  ELEVATED_SERVICE_MIN_INCOME = 9_000

  def self.elevated_service?(total_hours:, total_income:)
    total_hours >= ELEVATED_SERVICE_MIN_HOURS || total_income >= ELEVATED_SERVICE_MIN_INCOME
  end
```

Then in `all_items_grouped_by_month`, replace the `elevated_service:` value:

```ruby
        elevated_service: ftp.present? || Contributor.elevated_service?(
          total_hours: total_hours,
          total_income: partial_salary + total_income
        )
```

- [ ] **Step 4: Run tests, verify pass**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test test/models/contributor_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/contributor.rb test/models/contributor_test.rb
git commit -m "refactor(contributor): extract elevated_service? threshold predicate"
```

---

### Task 3: `Studio#members_active_on(date)`

**Files:**
- Modify: `app/models/studio.rb`
- Test: `test/models/studio_test.rb`

**Interfaces:**
- Produces: `Studio#members_active_on(date) -> ActiveRecord::Relation<AdminUser>`. garden3d → all AdminUsers with a `forecast_person`; other studios → AdminUsers with a `studio_membership` for this studio active on `date` (regardless of full-time status).

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/studio_test.rb (create if missing)
require "test_helper"

class StudioTest < ActiveSupport::TestCase
  test "members_active_on returns studio members active on the date" do
    studio = Studio.create!(name: "Alpha", mini_name: "alpha")
    au = AdminUser.create!(email: "m@sanctuary.computer", password: "password12345", password_confirmation: "password12345")
    StudioMembership.create!(studio: studio, admin_user: au, started_at: Date.new(2026, 1, 1), ended_at: nil)

    assert_includes studio.members_active_on(Date.new(2026, 6, 1)), au
    assert_not_includes studio.members_active_on(Date.new(2025, 1, 1)), au # before membership
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test test/models/studio_test.rb -n "/members_active_on/"`
Expected: FAIL with `NoMethodError: undefined method 'members_active_on'`.

- [ ] **Step 3: Implement**

```ruby
  # In app/models/studio.rb
  def members_active_on(date)
    if is_garden3d?
      AdminUser.joins(:forecast_person).distinct
    else
      AdminUser
        .joins(:studio_memberships)
        .where(
          "studio_memberships.started_at <= :d AND " \
          "coalesce(studio_memberships.ended_at, 'infinity') >= :d AND " \
          "studio_memberships.studio_id = :sid",
          d: date, sid: id
        ).distinct
    end
  end
```

- [ ] **Step 4: Run test, verify pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/studio.rb test/models/studio_test.rb
git commit -m "feat(studio): members_active_on (g3d = everyone)"
```

---

### Task 4: Bulk `Contributor.elevated_service_admin_user_ids(periods, forecast_person_ids)`

**Files:**
- Modify: `app/models/contributor.rb`
- Test: `test/models/contributor_test.rb`

**Interfaces:**
- Consumes: `Contributor.elevated_service?` (Task 2); `Stacks::Period` (has `.starts_at`, `.ends_at`).
- Produces: `Contributor.elevated_service_admin_user_ids(periods, forecast_person_ids) -> Set<Integer>` — admin_user ids whose contributor met elevated service in EVERY period, restricted to the given forecast_person_ids (which are `forecast_people.forecast_id` values).

- [ ] **Step 1: Write the failing tests**

```ruby
# add to test/models/contributor_test.rb
  test "elevated_service_admin_user_ids requires all periods to qualify" do
    au = AdminUser.create!(email: "heavy@sanctuary.computer", password: "password12345", password_confirmation: "password12345")
    fp = ForecastPerson.create!(forecast_id: 55_501, email: au.email, first_name: "H", last_name: "Y")
    Contributor.create!(forecast_person: fp)

    periods = Stacks::Period.for_gradation(:month, Date.new(2026, 4, 1), Date.new(2026, 6, 30))
    assert_equal 3, periods.size

    # $9000 income in each of the 3 months -> qualifies via income
    periods.each do |p|
      ip = InvoicePass.create!(start_of_month: p.starts_at)
      it = InvoiceTracker.create!(invoice_pass: ip)
      ContributorPayout.create!(invoice_tracker: it, forecast_person_id: fp.forecast_id, amount: 9_000)
    end

    ids = Contributor.elevated_service_admin_user_ids(periods, [fp.forecast_id])
    assert_includes ids, au.id
  end

  test "elevated_service_admin_user_ids excludes a contributor with a gap month" do
    au = AdminUser.create!(email: "gap@sanctuary.computer", password: "password12345", password_confirmation: "password12345")
    fp = ForecastPerson.create!(forecast_id: 55_502, email: au.email, first_name: "G", last_name: "P")
    Contributor.create!(forecast_person: fp)

    periods = Stacks::Period.for_gradation(:month, Date.new(2026, 4, 1), Date.new(2026, 6, 30))
    # Only 2 of 3 months have income; middle month has none.
    [periods[0], periods[2]].each do |p|
      ip = InvoicePass.create!(start_of_month: p.starts_at)
      it = InvoiceTracker.create!(invoice_pass: ip)
      ContributorPayout.create!(invoice_tracker: it, forecast_person_id: fp.forecast_id, amount: 9_000)
    end

    ids = Contributor.elevated_service_admin_user_ids(periods, [fp.forecast_id])
    assert_not_includes ids, au.id
  end
```

Note: adjust `ForecastPerson`/`InvoicePass`/`InvoiceTracker` required attributes to whatever the models validate (use `.new(...).save!(validate: false)` if a required association is unrelated to this logic, as elsewhere in the suite).

- [ ] **Step 2: Run tests, verify they fail**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test test/models/contributor_test.rb -n "/elevated_service_admin_user_ids/"`
Expected: FAIL with `NoMethodError`.

- [ ] **Step 3: Implement the bulk method**

```ruby
  # In app/models/contributor.rb
  # periods: Array<Stacks::Period> (months). forecast_person_ids: Array<Integer> (forecast_people.forecast_id).
  def self.elevated_service_admin_user_ids(periods, forecast_person_ids)
    fp_ids = Array(forecast_person_ids).uniq
    return Set.new if fp_ids.empty? || periods.blank?

    span_start = periods.map(&:starts_at).min
    span_end   = periods.map(&:ends_at).max

    # Income per [forecast_person_id, month-start-date]
    income = Hash.new(0)
    [
      ContributorPayout.joins(invoice_tracker: :invoice_pass)
        .where(forecast_person_id: fp_ids)
        .where("invoice_passes.start_of_month BETWEEN ? AND ?", span_start, span_end)
        .group(:forecast_person_id, "invoice_passes.start_of_month").sum(:amount),
      Trueup.joins(:invoice_pass)
        .where(forecast_person_id: fp_ids)
        .where("invoice_passes.start_of_month BETWEEN ? AND ?", span_start, span_end)
        .group(:forecast_person_id, "invoice_passes.start_of_month").sum(:amount),
    ].each do |grouped|
      grouped.each { |(fp_id, month), amt| income[[fp_id, month.to_date]] += amt }
    end

    # Hours per [forecast_person_id, period] — load overlapping assignments once, compute in Ruby.
    assignments_by_fp = ForecastAssignment
      .includes(:forecast_project)
      .where(person_id: fp_ids)
      .where("end_date >= ? AND start_date <= ?", span_start, span_end)
      .group_by(&:person_id)

    qualifying_fp_ids = fp_ids.select do |fp_id|
      periods.all? do |p|
        hours = (assignments_by_fp[fp_id] || []).sum { |fa| fa.allocation_during_range_in_hours(p.starts_at, p.ends_at) }
        inc   = income[[fp_id, p.starts_at.to_date]]
        elevated_service?(total_hours: hours, total_income: inc)
      end
    end

    ForecastPerson.where(forecast_id: qualifying_fp_ids)
      .joins(:admin_user).pluck("admin_users.id").to_set
  end
```

- [ ] **Step 4: Run tests, verify pass**

Run: same as Step 2. Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add app/models/contributor.rb test/models/contributor_test.rb
git commit -m "feat(contributor): bulk elevated_service_admin_user_ids over N months"
```

---

### Task 5: `Survey#reference_date`, `#elevated_service_periods`, `#expected_responder_status`, `#expected_responders`

**Files:**
- Modify: `app/models/survey.rb`
- Test: `test/models/survey_test.rb`

**Interfaces:**
- Consumes: `Studio#members_active_on` (Task 3), `Studio#core_members_active_on` (existing), `Contributor.elevated_service_admin_user_ids` (Task 4).
- Produces:
  - `Survey#reference_date -> Date`
  - `Survey#elevated_service_periods -> Array<Stacks::Period>` (3 completed months before reference_date)
  - `Survey#expected_responder_status -> { Studio => { AdminUser => SurveyResponder|nil } }` (core members on reference_date + elevated-service members, per studio)
  - `Survey#expected_responders -> Array<AdminUser>`

- [ ] **Step 1: Write the failing test**

```ruby
# add to test/models/survey_test.rb
  test "expected_responder_status includes elevated-service members as of reference date" do
    studio = Studio.create!(name: "Beta", mini_name: "beta")
    survey = Survey.create!(title: "B", opens_at: Date.new(2026, 7, 1)) # reference_date -> months Apr,May,Jun 2026
    survey.survey_studios.create!(studio: studio)

    au = AdminUser.create!(email: "elev@sanctuary.computer", password: "password12345", password_confirmation: "password12345")
    StudioMembership.create!(studio: studio, admin_user: au, started_at: Date.new(2026, 1, 1))
    fp = ForecastPerson.create!(forecast_id: 55_601, email: au.email, first_name: "E", last_name: "L")
    Contributor.create!(forecast_person: fp)
    survey.elevated_service_periods.each do |p|
      ip = InvoicePass.create!(start_of_month: p.starts_at)
      it = InvoiceTracker.create!(invoice_pass: ip)
      ContributorPayout.create!(invoice_tracker: it, forecast_person_id: fp.forecast_id, amount: 9_000)
    end

    assert_equal 3, survey.elevated_service_periods.size
    assert_includes survey.expected_responders, au
    assert survey.expected_responder_status[studio].key?(au)
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test test/models/survey_test.rb -n "/expected_responder_status includes elevated/"`
Expected: FAIL (`reference_date`/`elevated_service_periods` undefined, or au not included).

- [ ] **Step 3: Implement in `app/models/survey.rb`**

Replace the existing `expected_responders` and `expected_responder_status` with:

```ruby
  def reference_date
    opens_at&.to_date || Date.today
  end

  def elevated_service_periods
    ref = reference_date.beginning_of_month
    Stacks::Period.for_gradation(:month, ref - 3.months, ref - 1.day)
  end

  def expected_responders
    expected_responder_status.values.flat_map(&:keys).uniq
  end

  # Memoized: called repeatedly per survey (index rows call expected_responders twice),
  # and the elevated-service bulk is the expensive part.
  def expected_responder_status
    @expected_responder_status ||= begin
      ref = reference_date
      # One bulk elevated-service computation for the whole survey.
      candidate_fp_ids = studios.flat_map { |s|
        s.members_active_on(ref).joins(:forecast_person).pluck("forecast_people.forecast_id")
      }.uniq
      elevated_ids = Contributor.elevated_service_admin_user_ids(elevated_service_periods, candidate_fp_ids)

      studios.each_with_object({}) do |studio, acc|
        core = studio.core_members_active_on(ref).to_a
        elevated = studio.members_active_on(ref).where(id: elevated_ids.to_a).to_a
        members = (core + elevated).uniq
        acc[studio] = members.each_with_object({}) do |admin_user, h|
          h[admin_user] = SurveyResponder.find_by(survey: self, admin_user: admin_user)
        end
      end
    end
  end
```

- [ ] **Step 4: Run test, verify pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Run the whole survey + contributor + studio test files (regression)**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test test/models/survey_test.rb test/models/contributor_test.rb test/models/studio_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/models/survey.rb test/models/survey_test.rb
git commit -m "feat(survey): expected responders include elevated-service members as of reference date"
```

---

### Task 6: `Survey#responder_status` (union with actual responders)

**Files:**
- Modify: `app/models/survey.rb`
- Test: `test/models/survey_test.rb`

**Interfaces:**
- Consumes: `Survey#expected_responder_status` (Task 5).
- Produces: `Survey#responder_status -> { (Studio|:other) => { AdminUser => SurveyResponder|nil } }`. Same as `expected_responder_status` plus an `:other` group with every `SurveyResponder`'s admin_user not already present in an expected studio group. Use the symbol-like marker object `Survey::OTHER_RESPONDENTS` (a small struct responding to `#name`) so the view can render a heading.

- [ ] **Step 1: Write the failing test**

```ruby
# add to test/models/survey_test.rb
  test "responder_status adds actual respondents not in the expected set under Other" do
    studio = Studio.create!(name: "Gamma", mini_name: "gamma")
    survey = Survey.create!(title: "G", opens_at: Date.new(2026, 7, 1))
    survey.survey_studios.create!(studio: studio)

    outsider = AdminUser.create!(email: "outsider@sanctuary.computer", password: "password12345", password_confirmation: "password12345")
    SurveyResponder.create!(survey: survey, admin_user: outsider)

    status = survey.responder_status
    other_key = status.keys.find { |k| k == Survey::OTHER_RESPONDENTS }
    assert other_key, "expected an Other respondents group"
    assert status[other_key].key?(outsider)
    assert_not survey.expected_responders.include?(outsider) # not inflated
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test test/models/survey_test.rb -n "/responder_status adds actual/"`
Expected: FAIL (`responder_status`/`OTHER_RESPONDENTS` undefined).

- [ ] **Step 3: Implement**

```ruby
  # In app/models/survey.rb
  OTHER_RESPONDENTS = Struct.new(:name).new("Other respondents").freeze

  def responder_status
    status = expected_responder_status
    already = status.values.flat_map(&:keys).to_set

    others = SurveyResponder.where(survey: self).includes(:admin_user).each_with_object({}) do |responder, h|
      au = responder.admin_user
      next if au.nil? || already.include?(au)
      h[au] = responder
    end

    others.empty? ? status : status.merge(OTHER_RESPONDENTS => others)
  end
```

- [ ] **Step 4: Run test, verify pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/survey.rb test/models/survey_test.rb
git commit -m "feat(survey): responder_status unions actual respondents under Other group"
```

---

### Task 7: Show view + admin wiring render the union

**Files:**
- Modify: `app/admin/surveys.rb` (show block render args)
- Modify: `app/views/admin/surveys/_show.html.erb` (responders table source + group heading)

**Interfaces:**
- Consumes: `Survey#responder_status` (Task 6), `Survey#expected_responders` (Task 5).

- [ ] **Step 1: Pass `responder_status` to the partial**

In `app/admin/surveys.rb` show block:

```ruby
  show do
    render 'show', {
      survey_responder: SurveyResponder.find_by(survey: survey, admin_user: current_admin_user),
      expected_responder_status: resource.expected_responder_status,
      responder_status: resource.responder_status,
      results: resource.results
    }
  end
```

- [ ] **Step 2: Point the responders table at `responder_status` and tolerate the Other group**

In `app/views/admin/surveys/_show.html.erb`, change the responders loop (currently `expected_responder_status.each do |studio, studio_expected_responder_status|`) to iterate `responder_status`, and render the heading via a display name:

```erb
<% responder_status.each do |group, group_status| %>
  <div class="title_bar" id="title_bar" style="padding: 80px 0px 20px 0px;">
    <div id="titlebar_left">
      <h2 id="page_title">
        <%= group.respond_to?(:name) ? group.name : group.to_s %>
      </h2>
    </div>
  </div>
  ... (unchanged table body, iterating group_status) ...
<% end %>
```

Leave the `(N expected)` count and respond-button logic using `expected_responders` unchanged.

- [ ] **Step 3: Smoke-test the show page renders (manual/boot check)**

Boot check: the ActiveAdmin menu/view loads without error.
Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails runner 'ActiveAdmin.application.namespaces[:admin].fetch_menu(:default); puts "boot ok"'`
Expected: `boot ok`.

Then verify against real data (dev DB has the restored production surveys):
Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails runner 's = Survey.find(1); puts "responder groups: #{s.responder_status.size}"; puts "responders shown: #{s.responder_status.values.sum(&:size)}"; puts "actual responders: #{SurveyResponder.where(survey_id: s.id).count}"'`
Expected: "responders shown" ≥ "actual responders" (25 for survey #1) — proving the union now surfaces everyone who responded.

- [ ] **Step 4: Commit**

```bash
git add app/admin/surveys.rb app/views/admin/surveys/_show.html.erb
git commit -m "feat(survey): results page shows union of expected + actual responders"
```

---

### Task 8: Full suite regression + finish

- [ ] **Step 1: Run the related model tests + any survey/admin tests**

Run: `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test test/models/survey_test.rb test/models/contributor_test.rb test/models/studio_test.rb`
Expected: all PASS, pristine output.

- [ ] **Step 2: Open a PR** (handled by the finishing-a-development-branch flow).
