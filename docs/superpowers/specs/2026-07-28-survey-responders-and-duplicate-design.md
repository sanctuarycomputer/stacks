# Studio Survey: duplication fix + accurate responders

**Date:** 2026-07-28
**Scope:** `Survey` (Studio Surveys) only. `ProjectSatisfactionSurvey` is explicitly out of scope.

## Problem

Three related issues on Studio Surveys:

1. **Duplication is broken.** The "Duplicate" action exists and is visible to admins, but
   `Survey.clone_from` copies free-text questions into the wrong association
   (`new_survey.survey_questions << n` instead of `survey_free_text_questions`), raising
   `ActiveRecord::AssociationTypeMismatch` for any survey that has free-text questions.
   Verified against production data (survey #1 has 3 free-text questions → raises).

2. **Expected responders miss elevated-service contributors.** `Survey#expected_responders`
   returns only each studio's `core_members_active_on(today)` — full-time (`five_day`/`four_day`)
   members. Contributors who provided "elevated service" (heavy involvement) are not treated as
   expected responders even though they should weigh in.

3. **The results page hides most actual responders.** The responders table is driven by
   `expected_responder_status`, which is `core_members_active_on(Date.today)`. That filter is
   both **type-restricted** (excludes `variable_hours`) and **evaluated as of today**. So for a
   closed 2024 survey with 25 real respondents, the page shows only the 2 people who are still
   currently-active full-time members. Anyone who actually responded but isn't a currently-active
   core member is invisible.

## Definitions

**Elevated service (per contributor, per month).** Already defined in
`Contributor#all_items_grouped_by_month` / `Contributor#elevated_service_for_month`:
via the convenience predicate (`include_salary: false`) it reduces to

> total recorded hours ≥ **120** **OR** total income (ContributorPayout + Trueup) ≥ **$9000**

for that month. "Provided escalated service for the past 3 months straight" = this is true for
**each of the 3 completed calendar months** before the survey's reference date.

**Reference date.** `Survey#reference_date = opens_at&.to_date || Date.today`. All "as of" logic
(membership activity, the 3-month window) anchors to this so a closed survey reflects the cohort
that was actually surveyed, not today's.

**3 completed months.** The 3 full calendar months strictly before `reference_date.beginning_of_month`.
E.g. reference date in July 2026 → April, May, June 2026. Computed with
`Stacks::Period.for_gradation(:month, reference_date.beginning_of_month - 3.months, reference_date.beginning_of_month - 1.day)`.

**Studio membership (for the elevated-service scope).**
- **garden3d studio → everyone**: all `AdminUser`s who have a `Contributor` (i.e. a `forecast_person`).
- **Other studios**: `AdminUser`s with a `studio_membership` for that studio active on `reference_date`.

## Design

### 1. Fix `Survey.clone_from`

Change the free-text-question copy loop to push into the correct association:

```ruby
prev_survey.survey_free_text_questions.each do |q|
  n = q.dup
  n.survey = new_survey
  new_survey.survey_free_text_questions << n   # was: new_survey.survey_questions << n
end
```

No other behavior changes.

### 2. Elevated-service threshold: one source of truth

Extract the threshold into a single shared predicate so the per-month path and the new bulk path
cannot diverge:

```ruby
# Contributor
ELEVATED_SERVICE_MIN_HOURS  = 120
ELEVATED_SERVICE_MIN_INCOME = 9_000

def self.elevated_service?(total_hours:, total_income:)
  total_hours >= ELEVATED_SERVICE_MIN_HOURS || total_income >= ELEVATED_SERVICE_MIN_INCOME
end
```

`all_items_grouped_by_month` is refactored to call `Contributor.elevated_service?` for the
`elevated_service:` field (preserving the existing `ftp.present? ||` short-circuit in the
`include_salary: true` path). This keeps existing behavior identical (covered by a parity test).

### 3. Bulk elevated-service set (performance-critical)

Naive per-contributor computation is ~75ms × 173 contributors ≈ **13s** on a g3d survey — unacceptable.
Instead, a class method computes the qualifying set in a bounded number of queries independent of
headcount:

```ruby
# Contributor
# Returns the Set of admin_user_ids whose contributor met elevated service
# in EVERY one of `periods` (each a Stacks::Period month), restricted to `forecast_person_ids`.
def self.elevated_service_admin_user_ids(periods, forecast_person_ids)
```

Mechanism (all bounded to the 3-month window and the candidate `forecast_person_ids`):
- **Income per (forecast_person, month):** one grouped query over `ContributorPayout`
  (joined to `invoice_tracker → invoice_pass`, bucketed by `start_of_month`) plus `Trueup`,
  summed by person and month.
- **Hours per (forecast_person, month):** load `ForecastAssignment`s overlapping the window for the
  candidate people in one query; sum `allocation_during_range_in_hours(month_start, month_end)`
  per (person, month) in Ruby (same primitive `recorded_allocation_during_range_in_hours_from_assignments`
  uses).
- For each candidate, qualify iff `Contributor.elevated_service?(hours, income)` is true for **all**
  periods. Map `forecast_person` → `admin_user` via email.

**Correctness anchor:** a parity test asserts, for a sample of contributors, that the bulk result
agrees with `Contributor#elevated_service_for_month` month-by-month.

### 4. Expected responders vs. the results table (keep them separate)

`expected_responders` must remain **expected-only** — it drives the "(N expected)" count
(`surveys.rb:123`), the respond-button / to-do logic (`surveys.rb:107`, `all_surveys.rb:26`,
`admin_user.rb:184`, `_show.html.erb:22,32`). The union with actual responders is a **display
concern for the results table only** and gets its own method. Mixing them would inflate the expected
count and mis-drive the to-do logic.

```ruby
def reference_date
  opens_at&.to_date || Date.today
end

# EXPECTED ONLY — core members active on reference_date + elevated-service members, per studio.
# { studio => { admin_user => SurveyResponder_or_nil } }
def expected_responder_status
  # per survey.studios: core_members_active_on(reference_date) ∪ elevated-service members of
  # that studio, each mapped to SurveyResponder.find_by(survey:, admin_user:)
end

def expected_responders           # flat expected set (unchanged semantics)
  expected_responder_status.values.flat_map(&:keys).uniq
end

# UNION for the results table = expected_responder_status PLUS a synthetic "Other respondents"
# group holding every SurveyResponder whose admin_user is not already in an expected studio group.
# { group => { admin_user => SurveyResponder_or_nil } }, group is a Studio or the "Other" marker.
def responder_status
end
```

Elevated-service members per studio come from **one** bulk call per survey:
`Contributor.elevated_service_admin_user_ids(periods, candidate_forecast_person_ids)`, where
`candidate_forecast_person_ids` is the union across the survey's studios of each studio's membership
(g3d → everyone). The result is then intersected with each studio's membership to place people in the
right studio group. Membership activity is evaluated as of `reference_date`. `core_members_active_on`
already takes a date argument — Survey passes `reference_date` instead of `Date.today`.

### 5. Show view (`app/views/admin/surveys/_show.html.erb`, `app/admin/surveys.rb`)

- `surveys.rb` show block passes `responder_status: resource.responder_status` to the partial
  (in addition to the existing keys). The responders **table** iterates `responder_status` instead of
  `expected_responder_status`.
- The group heading renders a display name tolerant of the non-Studio "Other respondents" marker:
  `group.respond_to?(:name) ? group.name : group.to_s`.
- The "(N expected)" count and respond-button logic keep using `expected_responders` — unchanged.

## Testing

- **clone_from**: cloning a survey WITH free-text questions succeeds and the clone carries the
  questions, free-text questions, and studios (fails today with `AssociationTypeMismatch`).
- **elevated_service? / parity**: shared predicate at the boundaries (119/120 hrs, 8999/9000 income);
  parity between the bulk set and `elevated_service_for_month` on sample data.
- **bulk set / "3 months straight"**: qualifies only when all 3 completed months meet the threshold;
  a gap in any month disqualifies; window anchored to `reference_date`.
- **expected_responders**: includes core members + elevated-service members, deduplicated; g3d scope =
  everyone, other studios scoped to membership as of `reference_date`. An actual respondent who was
  NOT expected does **not** appear in `expected_responders` (so "(N expected)" is not inflated).
- **responder_status (union)**: an actual `SurveyResponder` who is not a current core member still
  appears — in a studio group if a member there, else in "Other respondents"; expected-but-didn't-
  respond people still show with "No".

## Out of scope

- `ProjectSatisfactionSurvey` responder logic.
- Any change to how responses are collected or scored.
- Caching/snapshotting the elevated-service set (bulk queries are fast enough; revisit only if a
  survey page is still slow).
