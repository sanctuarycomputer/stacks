# Recurring Forecast Assignments — Design

**Date:** 2026-07-30
**Status:** Approved (autonomous build; flagged decisions surfaced at PR review)

## Problem

Forecast (Harvest) has a native "repeat" feature, but its `repeated_assignment_set_id`
is server-owned and cannot be set through the write endpoints we have access to
(verified live: sending a value on `POST /assignments` returns `nil`; no repeat/expansion
param is honored). We want Stacks to own recurring scheduling as a first-class concept and
**materialize** each occurrence as an ordinary Forecast assignment via the (undocumented but
confirmed) `api.forecastapp.com` write API.

Hard requirement: **if a user deletes a materialized assignment directly in the Forecast UI,
the materialization job must not recreate it.**

## Ownership model

- **Stacks owns creation.** The rule generates concrete Forecast assignments.
- **Deletion in Forecast is an intentional opt-out.** A materialized occurrence that
  disappears from Forecast is *tombstoned* and never recreated.
- **v1 does not reconcile edits.** Editing a rule affects only occurrences not yet
  materialized; already-materialized assignments (and any manual hour edits made to them in
  Forecast) are left as-is. (Flagged: reconcile-on-drift is a deliberate future extension,
  not v1.)

## Data model

Two new **local** models (default bigint `id`; they reference Forecast mirror rows by
`forecast_id`, following the `Contributor → ForecastPerson` convention — model-level
`belongs_to` with `primary_key: "forecast_id"`, no DB FK to the pruned mirror tables).

### `RecurringAssignment` (the rule)

| column | type | notes |
|---|---|---|
| `forecast_person_id` | bigint, null: false | the assignee (v1: people only; placeholder is future) |
| `forecast_project_id` | bigint, null: false | target project |
| `allocation` | integer, null: false | seconds/day (Forecast native; admin enters hours) |
| `active_on_days_off` | boolean, null: false, default: false | |
| `notes` | text, null: false, default: "" | copied onto each Forecast assignment |
| `weekdays` | integer[], null: false, default: `[1,2,3,4,5]` | 0=Sun..6=Sat; which weekdays get an occurrence |
| `starts_on` | date, null: false | window start |
| `ends_on` | date, null: true | window end; null ⇒ open-ended (rolling horizon) |
| `paused_at` | datetime, null: true | `scope :active` = `where(paused_at: nil)` |
| timestamps | | |

Validations (mirroring `RecurringLedgerAdjustment`): presence of person/project/allocation/
starts_on; `allocation > 0`; `weekdays` non-empty and ⊆ 0..6; `ends_on >= starts_on` when
present.

Associations: `belongs_to :forecast_person`, `belongs_to :forecast_project`
(both `primary_key: "forecast_id"`), `has_many :recurring_assignment_occurrences, dependent: :destroy`.

### `RecurringAssignmentOccurrence` (one row per occurrence date)

| column | type | notes |
|---|---|---|
| `recurring_assignment_id` | references, null: false, FK | |
| `occurs_on` | date, null: false | the single day this assignment covers |
| `forecast_assignment_id` | bigint, null: true | id returned by Forecast `POST` |
| `status` | string, null: false, default: `"materialized"` | `materialized` \| `deleted` |
| timestamps | | |

Unique index on `[recurring_assignment_id, occurs_on]` (idempotency key). Index on
`forecast_assignment_id`.

## Forecast write API (net-new — `Stacks::Forecast` is currently read-only)

Add two methods (only what v1 uses), copying the `Stacks::Runn#create_assignment`
write/`handle_response` pattern (`self.class.post/delete(path, body: JSON.dump(...), headers: @headers)`):

- `create_assignment(project_id:, person_id:, start_date:, end_date:, allocation:, notes:, active_on_days_off:)` → `POST /assignments`, body wrapped `{ assignment: {...} }`, returns parsed `assignment` (incl. new `id`).
- `delete_assignment(forecast_id)` → `DELETE /assignments/:id` (204).

`Content-Type: application/json`. (`PUT`/update is deliberately omitted — no v1 caller;
it lands with the future reconcile-on-drift work.)

## Materialization

`RecurringAssignment#materialize!` — idempotent, safe to re-run, per-rule. Two ordered passes:

**Pass 1 — deletion detection (BEFORE creation):**
For each existing `status: "materialized"` occurrence, if its `forecast_assignment_id` is
**absent from the `ForecastAssignment` mirror**, set `status: "deleted"` (tombstone). Do not
recreate. This is the "deleted in the UI, don't recreate" mechanism.

> **Why no timestamp/race guard is needed:** `materialize!` is invoked *inline immediately
> after* `Stacks::Forecast#sync_all!` in `stacks:daily_tasks`, and detection runs before
> creation. Therefore every occurrence eligible for detection was created in a *prior* run
> and has been through ≥1 sync, so the mirror is authoritative for it. Occurrences created in
> the current run are made in Pass 2 (after detection) and so are never falsely tombstoned.
> If `sync_all!` raises, the `SystemTask` rescue skips `materialize!` entirely — so
> `materialize!` only ever runs against a freshly-synced mirror.

**Pass 2 — creation:**
Compute expected occurrence dates = days in `[starts_on, min(ends_on, today + HORIZON)]` whose
weekday ∈ `weekdays`. `HORIZON = 26.weeks` (open-ended rules extend each run). For each expected
date with **no** occurrence row (any status), `POST` a 1-day Forecast assignment
(`start_date == end_date == occurs_on`) and record the occurrence as `materialized` with the
returned `forecast_assignment_id`. Dates that already have an occurrence row — `materialized`
**or** `deleted` — are skipped (tombstones are permanent).

Per-occurrence work is wrapped so one Forecast API failure doesn't abort the rule
(`rescue` + `Sentry.capture_exception`, matching the `daily_enterprise_tasks` loop).

## Scheduling / wiring

Add, in `lib/tasks/stacks.rake` inside `stacks:daily_tasks`, **immediately after**
`Stacks::Forecast.new.sync_all!` (~line 511):

```ruby
RecurringAssignment.active.find_each do |ra|
  begin
    ra.materialize!
  rescue => e
    Sentry.capture_exception(e)
  end
end
```

No new Heroku Scheduler entry required (rides the existing daily sync → correct ordering for free).

## Rule lifecycle

- **Pause** (`paused_at`): rule skipped by `active` scope; existing Forecast assignments left intact.
- **Destroy:** before destroying the rule, delete **future** (`occurs_on >= Date.today`),
  non-tombstoned materialized occurrences from Forecast (`delete_assignment`), then destroy
  occurrences via `dependent: :destroy`. Past occurrences are left in Forecast for historical
  accuracy. (Flagged decision: future-only cleanup.)

## Admin UI (ActiveAdmin — primary internal UI)

`app/admin/recurring_assignments.rb`, modeled on `recurring_ledger_adjustments.rb`:

- `menu parent: "Team"`, `config.filters = false`, `actions :index,:new,:create,:edit,:update,:destroy`.
- **Form:** person `as: :select` (non-archived `ForecastPerson`), project `as: :select`
  (non-archived `ForecastProject`), allocation **entered in hours** (helper converts ⇄ seconds),
  `weekdays` as multi-select checkboxes (Mon–Sun), `starts_on`/`ends_on` datepickers,
  `active_on_days_off`, `notes`.
- **Index:** person, project, cadence summary (weekdays + window), allocation (hours),
  materialized / tombstoned occurrence counts, `status_tag` for paused.
- **Show:** rule details + occurrences table (date, status, link to the Forecast assignment).
- **`action_item :materialize_now` → `member_action`** calling `resource.materialize!`
  (with `notice`/`alert`), mirroring the RLA "materialize now" button.

## Testing (Minitest + Mocha; no WebMock/VCR)

Stub Forecast HTTP at the class method (`Stacks::Forecast.expects(:post)/:put/:delete`),
per `test/lib/stacks/runn_test.rb`.

- **`Stacks::Forecast` writes:** POST/PUT/DELETE hit right path + body envelope; parse response.
- **Model validations:** allocation, weekdays subset, date ordering.
- **Materialize — create:** new rule POSTs one assignment per expected weekday in horizon,
  records occurrences; second run is a no-op (no duplicate POST).
- **Materialize — tombstone:** a materialized occurrence whose `forecast_assignment_id` is
  absent from the `ForecastAssignment` mirror flips to `deleted`, no POST.
- **Materialize — no-recreate:** a `deleted` occurrence is never re-POSTed on subsequent runs
  (the core requirement).
- **Materialize — horizon:** open-ended rule stops at `today + 26.weeks`; extends next run.
- **Destroy cleanup:** destroying a rule DELETEs future materialized occurrences from Forecast,
  leaves past ones.

## Flagged decisions (for PR review)

1. **One Forecast assignment per occurrence day** (1:1 occurrence↔row↔tombstone). Simplest to
   reason about; trades row count (week-block batching is a future optimization).
2. **v1 = create + respect-delete only; no edit reconciliation.** Rule edits affect only
   future unmaterialized occurrences.
3. **People only** (no placeholder assignees) in v1.
4. **26-week rolling horizon** for open-ended rules.
5. **Destroy deletes future occurrences only** from Forecast; past left intact.
6. **Rides `daily_tasks`** (daily cadence) rather than a dedicated scheduler entry.
