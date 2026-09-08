# Contributor Payment Projections — Design

**Date:** 2026-09-08
**Status:** Approved

## Goal

Project what each contributor will be paid for the current month and the
next three, from the forward plan in Runn, using the same payout rules the
real invoice pass and pay cycle apply. Show the projection on the
contributor's own ledger page (`/admin/contributors/:id`) and roll it up per
enterprise and month on the payables page (`/admin/money/payable_qbo_bills`),
so finance can set projected contributor cash-out against Runn's cash-in
forecast.

Three deliverables, each shippable on its own and built in this order:

1. **Billing model** — a `billing_model` enum on `ProjectTracker` that owns
   the payout split rules (treasury, lead shares, surplus), replacing the
   scattered `company_treasury_split` column and hardcoded percentages. This
   is the "Update Stacks mechanics" item from the *Charging What Our Work Is
   Worth* rate-card doc: new-rate-card trackers pay a 54% IC ceiling with
   33% to treasury.
2. **Runn mirror** — nightly local copies of Runn assignments, people, and
   roles alongside the existing `runn_projects` mirror, following the
   Forecast sync pattern.
3. **Projection engine and surfaces** — a pure-Ruby service over the mirror
   that prices each forward assignment per ledger and month, plus the two
   admin surfaces.

## Decisions (from the brainstorm)

- Audience is both the contributor and finance; the per-contributor
  projection is the primitive and the roll-up sums it.
- Fidelity mirrors the real payout math: commissions off the top, Account
  Lead 8%, Project Lead 5%, IC remainder after treasury (or a per-email
  override rate), surplus above the derived threshold, salaried gate.
- Runn is the only forward hours source. The local Forecast mirror stops at
  the end of the current month and `RecurringAssignment` rules are not in
  Runn's forward plan, so neither is used. Recurring Principal hours are
  expected to be entered in Runn as ordinary assignments.
- Principal hours pay zero through the existing per-email override
  mechanism (`hugh@sanctuary.computer:0p/h` in the Forecast project notes).
  No Principal concept is added to code. **Prerequisite for accuracy, not
  part of this work:** add that override to the Principal Forecast projects.
- Dollars bucket by the month the hours are worked, not by expected payment
  date.
- Horizon is the current month plus the next three months.
- Unconfirmed Runn projects are included and flagged tentative.
- The `/admin/dashboard` page and its redirect are untouched; the roll-up
  lives on the payables page.

---

## Part 1 — Billing model

### Behavior

- Every `ProjectTracker` has a `billing_model`, one of `new_deal_v1`
  (default) or `new_deal_v2`.
- The rule set for each model:

  | Model         | Treasury | Account Lead | Project Lead | Surplus lead share | IC ceiling | Surplus threshold |
  |---------------|---------:|-------------:|-------------:|-------------------:|-----------:|------------------:|
  | `new_deal_v1` |     0.30 |         0.08 |         0.05 |               0.15 |       0.57 |              0.43 |
  | `new_deal_v2` |     0.33 |         0.08 |         0.05 |               0.15 |       0.54 |              0.46 |

  IC ceiling = 1 − treasury − AL − PL. Surplus threshold = treasury + AL +
  PL. Both are derived, never stored.
- `ProjectTracker#company_treasury_split` keeps its name and return type
  (`BigDecimal`) but reads from the billing model. The column is dropped.
- `InvoiceTracker#make_contributor_payouts!` and
  `ContributorPayout#calculate_surplus` read the tracker's billing model
  instead of the literals `0.08`, `0.05`, `0.15`, `0.43`, `0.57`.
- The project tracker admin form shows a select for `billing_model` (admins
  only, where the decimal input was); the show page displays the model.

### Architecture

#### 1.1 `Stacks::BillingModel` (`lib/stacks/billing_model.rb`)

A frozen registry of value objects, keyed by model name:

```ruby
Stacks::BillingModel::Rules = Struct.new(
  :name, :treasury_share, :account_lead_share, :project_lead_share, :surplus_lead_share,
  keyword_init: true
) do
  def ic_ceiling         = 1 - treasury_share - account_lead_share - project_lead_share
  def surplus_threshold  = treasury_share + account_lead_share + project_lead_share
end

Stacks::BillingModel::ALL = {
  "new_deal_v1" => Rules.new(name: "new_deal_v1", treasury_share: BigDecimal("0.30"), account_lead_share: BigDecimal("0.08"), project_lead_share: BigDecimal("0.05"), surplus_lead_share: BigDecimal("0.15")),
  "new_deal_v2" => Rules.new(name: "new_deal_v2", treasury_share: BigDecimal("0.33"), account_lead_share: BigDecimal("0.08"), project_lead_share: BigDecimal("0.05"), surplus_lead_share: BigDecimal("0.15")),
}.freeze

Stacks::BillingModel.for(name) # => Rules, raises ArgumentError on unknown
Stacks::BillingModel::DEFAULT  # => "new_deal_v1"
```

Shares are `BigDecimal` so `1 - treasury_share` is exact; callers coerce
with `.to_f` when writing blueprint amounts (matching the existing coercion
comment at `invoice_tracker.rb:506-512`).

#### 1.2 Migration `AddBillingModelToProjectTrackers`

1. `add_column :project_trackers, :billing_model, :string, null: false, default: "new_deal_v1"`.
2. Backfill in SQL: `0.30 → new_deal_v1`, `0.33 → new_deal_v2`. Then
   `SELECT count(*)` of rows matching neither; raise
   `ActiveRecord::MigrationError` naming the ids if nonzero. (Today all 199
   trackers are `0.30`.)
3. `remove_check_constraint` and `remove_column :project_trackers, :company_treasury_split`.
4. `down` re-adds the column with default 0.3, restores the check
   constraint, backfills from the enum, and drops `billing_model`.

A string column (not integer) so the value reads correctly in SQL and admin
filters without a lookup table.

#### 1.3 `ProjectTracker`

```ruby
enum billing_model: { new_deal_v1: "new_deal_v1", new_deal_v2: "new_deal_v2" }, _default: "new_deal_v1"

def billing_rules
  Stacks::BillingModel.for(billing_model)
end

def company_treasury_split
  billing_rules.treasury_share
end
```

#### 1.4 `InvoiceTracker#make_contributor_payouts!`

At each of the three literals inside the per-line loop, read
`rules = pt.billing_rules` once per line and use
`rules.account_lead_share`, `rules.project_lead_share`, and
`1 - rules.treasury_share - (al ? rules.account_lead_share : 0) - (pl ? rules.project_lead_share : 0)`
(which equals `rules.ic_ceiling` when both leads are present). The
description lines render the percentage from the rule
(`"#{(share * 100).round(2)}%"`) instead of the literal `8%` / `5%`.

In the surplus block, `lead_share = (c[:surplus] * rules.surplus_lead_share).round(2)`
where `rules = c[:project_tracker].billing_rules`.

#### 1.5 `ContributorPayout#calculate_surplus`

The threshold and maximum become per-line:

```ruby
rules = project_tracker&.billing_rules || Stacks::BillingModel.for(Stacks::BillingModel::DEFAULT)
surplus = ((profit_margin - rules.surplus_threshold) * working_amount).round(2)
...
maximum: (rules.ic_ceiling * working_amount).to_f,
```

`project_tracker` is already resolved a few lines below in the existing
method; hoist that lookup above the surplus math.

#### 1.6 Admin (`app/admin/project_trackers.rb`)

- `permit_params` gains `:billing_model` and drops `:company_treasury_split`
  (the column no longer exists); the admin-only form block replaces
  the `company_treasury_split` input with
  `f.input :billing_model, as: :select, collection: Stacks::BillingModel::ALL.keys, include_blank: false, hint: "Which payout split rules apply to this project. new_deal_v2 is the 2026 rate card (33% treasury / 54% IC ceiling)."`.
- Show page: a `row :billing_model` in the attributes table, rendering as
  `"new_deal_v2 — 33% treasury, 54% IC ceiling"`.
- `app/admin/invoice_trackers.rb` is untouched (its own
  `company_treasury_split` column stays; see Out of scope).
- The invoice tracker partial's two literals ("cheaper than `57%`",
  "Maximum Payout (57%)") are replaced with the value from
  `invoice_tracker.project_trackers.map(&:billing_rules).map(&:ic_ceiling).max`,
  formatted as a percentage. When trackers on one invoice disagree, the
  highest ceiling is shown with a "(highest across trackers)" suffix.

---

## Part 2 — Runn mirror

### Behavior

- Nightly (inside the existing `Stacks::Runn#sync_all!`, already called by
  `stacks:daily_tasks` and `stacks:sync_runn`), fetch every Runn person,
  role, and assignment and upsert them locally. Projects continue to sync as
  today.
- Assignments absent from the fetch are deleted locally (chunked). People
  and roles are never deleted; Runn's `isArchived` is mirrored instead.
- Only rows whose Runn `updatedAt` changed are rewritten, using the
  Forecast sync's `upsert_changed!` approach.
- `sync_all!` takes a non-blocking Postgres advisory lock (its own key) and
  skips with a warning if another sync holds it.
- `System.instance.runn_synced_at` is set to `Time.current` only after all
  four syncs succeed in one run.

### Architecture

#### 2.1 Migrations

`CreateRunnPeople`:

```ruby
create_table :runn_people do |t|
  t.bigint  :runn_id, null: false
  t.string  :first_name
  t.string  :last_name
  t.string  :email
  t.boolean :is_archived, null: false, default: false
  t.datetime :created_at
  t.datetime :updated_at
  t.jsonb   :data
end
add_index :runn_people, :runn_id, unique: true
add_index :runn_people, "lower(email)"
```

`CreateRunnRoles`:

```ruby
create_table :runn_roles do |t|
  t.bigint  :runn_id, null: false
  t.string  :name
  t.decimal :standard_rate
  t.decimal :default_hour_cost
  t.boolean :is_archived, null: false, default: false
  t.datetime :created_at
  t.datetime :updated_at
  t.jsonb   :data
end
add_index :runn_roles, :runn_id, unique: true
```

`CreateRunnAssignments`:

```ruby
create_table :runn_assignments do |t|
  t.bigint  :runn_id, null: false
  t.bigint  :person_id
  t.bigint  :project_id
  t.bigint  :role_id
  t.date    :start_date, null: false
  t.date    :end_date, null: false
  t.integer :minutes_per_day, null: false, default: 0
  t.boolean :is_active, null: false, default: true
  t.boolean :is_billable, null: false, default: true
  t.boolean :is_placeholder, null: false, default: false
  t.boolean :is_template, null: false, default: false
  t.boolean :is_non_working_day, null: false, default: false
  t.text    :note
  t.datetime :created_at
  t.datetime :updated_at
  t.jsonb   :data
end
add_index :runn_assignments, :runn_id, unique: true
add_index :runn_assignments, :person_id
add_index :runn_assignments, :project_id
add_index :runn_assignments, [:start_date, :end_date], using: :gist, name: "idx_runn_assignments_on_daterange"
```

(GiST on two date columns needs `btree_gist`; `forecast_assignments` already
uses the same index shape, so the extension is present.)

`created_at` / `updated_at` hold Runn's own timestamps, as `runn_projects`
does; there is no Rails `t.timestamps`.

`AddRunnSyncedAtToSystems`: no migration. `System` uses `storext` over a
`settings` jsonb; add `runn_synced_at DateTime, default: nil` to its
`store_attributes` block.

#### 2.2 Models

```ruby
class RunnPerson < ApplicationRecord
  self.primary_key = "runn_id"
  has_many :runn_assignments, foreign_key: :person_id
  scope :active, -> { where(is_archived: false) }

  def contributor
    @contributor ||= begin
      e = email.to_s.strip.downcase
      e.present? ? Contributor.joins(:forecast_person).find_by("lower(forecast_people.email) = ?", e) : nil
    end
  end
end

class RunnRole < ApplicationRecord
  self.primary_key = "runn_id"
  has_many :runn_assignments, foreign_key: :role_id
end

class RunnAssignment < ApplicationRecord
  self.primary_key = "runn_id"
  belongs_to :runn_person,  foreign_key: :person_id,  primary_key: :runn_id, optional: true
  belongs_to :runn_project, foreign_key: :project_id, primary_key: :runn_id, optional: true
  belongs_to :runn_role,    foreign_key: :role_id,    primary_key: :runn_id, optional: true

  scope :overlapping, ->(from, to) { where("end_date >= ? AND start_date <= ?", from, to) }
  scope :plannable, -> { where(is_template: false, is_active: true) }

  # Days inside [from, to] ∩ [start_date, end_date]. Mon–Fri unless the
  # assignment is flagged as a non-working-day assignment, in which case
  # every calendar day counts (that is Runn's semantic for the flag).
  def working_days_between(from, to)
    a = [start_date, from].max
    b = [end_date, to].min
    return 0 if a > b
    return (b - a).to_i + 1 if is_non_working_day
    (a..b).count { |d| (1..5).cover?(d.wday) }
  end

  def hours_between(from, to)
    working_days_between(from, to) * minutes_per_day / 60.0
  end
end
```

`RunnProject` gains `has_many :runn_assignments, foreign_key: :project_id`.

`RunnPerson#contributor` is a per-instance lookup for ad-hoc use; the engine
does not call it per row — it builds one email→contributor hash (see 3.2).

#### 2.3 `Stacks::Runn` (`lib/stacks/runn.rb`)

```ruby
SYNC_ALL_ADVISORY_LOCK_KEY = 84_217_296  # Forecast uses 84_217_295

def sync_all!
  acquired = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{SYNC_ALL_ADVISORY_LOCK_KEY})")
  unless acquired
    Rails.logger.warn("Stacks::Runn#sync_all! skipped — another sync is already running")
    return
  end
  begin
    sync_projects!
    sync_people!
    sync_roles!
    seen = sync_assignments!
    prune_assignments_not_in!(seen)
    System.instance.update!(runn_synced_at: Time.current)
  ensure
    ActiveRecord::Base.connection.select_value("SELECT pg_advisory_unlock(#{SYNC_ALL_ADVISORY_LOCK_KEY})")
  end
end
```

- `sync_projects!` keeps its shape but (a) maps `c["updatedAt"]` (fixing the
  `"UpdatedAt"` typo that made the column always nil) and (b) goes through
  `upsert_changed!`.
- `sync_people!`, `sync_roles!`, `sync_assignments!` each call the existing
  `get_*` reader, map to rows (Runn's camelCase → columns above, raw payload
  in `data`, `createdAt`/`updatedAt` → `created_at`/`updated_at`), and
  return the seen `runn_id`s via `upsert_changed!`.
- `upsert_changed!(model, rows)` is a port of the Forecast method keyed on
  `:runn_id`: select rows that are new or whose stored `updated_at` differs
  from the incoming one, `upsert_all(changed, unique_by: :runn_id)`, return
  every seen id.
- `prune_assignments_not_in!(seen_ids)`:
  `RunnAssignment.where.not(runn_id: seen_ids).in_batches(of: 1000, &:delete_all)`.
  No-op when `seen_ids` is blank, so an empty fetch never wipes the table.
- The existing transaction wrapper around `sync_projects!` is dropped: the
  four syncs are independent upserts and a partial run must leave the
  earlier tables updated, as Forecast does.

`Stacks::Runn.new` (default `max_retries: 5`) is what the rake tasks use, so
a 429 during the nightly sync sleeps and retries as today.

---

## Part 3 — Projection engine and surfaces

### Behavior

For each ledger (enterprise × contributor) and each month in the horizon,
produce a list of projected lines and totals. A line has:

| Field         | Meaning |
|---------------|---------|
| `kind`        | one of `individual_contributor`, `account_lead`, `project_lead`, `account_lead_surplus`, `project_lead_surplus`, `commission`, `pay_stub`, `recurring_adjustment` |
| `project_tracker` | the tracker (nil for `recurring_adjustment`) |
| `hours`       | hours in the month for that assignment (nil for surplus, commission-percentage, adjustment) |
| `rate`        | the rate applied (bill rate, override rate, or commission rate) |
| `amount`      | rounded to cents |
| `description` | same phrasing as today's blueprint lines, e.g. `"- 12.0 hrs * $195.00 p/h * 54.0% = $1,263.60"` |
| `tentative`   | true when the Runn project is unconfirmed |

Pricing, per plannable `RunnAssignment` overlapping the horizon:

1. **Person.** Runn person → contributor by lowercased email. Placeholder
   assignments and unmatched people are skipped and counted under
   `skipped[:unmapped_person]`.
2. **Tracker.** Runn project → `ProjectTracker` by `runn_project_id`.
   Archived or template Runn projects are skipped silently. Live projects
   with no tracker are skipped and counted under `skipped[:unmapped_project]`
   with the project name.
3. **Forecast project and client.** Among the tracker's forecast projects,
   pick the one whose `hourly_rate` equals the Runn role's `standard_rate`;
   otherwise the first unarchived one; otherwise the first. If the tracker
   has none, the line is priced with the bill rate and no override, routed
   to `Enterprise.sanctuary`, and counted under `skipped[:no_forecast_project]`
   (it is still included, so the count is informational).
   The client is `forecast_project.forecast_client`.
4. **Rates.** Bill rate = the Runn role's `standard_rate` (falls back to the
   forecast project's `hourly_rate`, then `System.instance.default_hourly_rate`
   when the role is missing). Override = the per-email note override on the
   chosen forecast project; if none there, the first override found on any
   of the tracker's other forecast projects for that email.
5. **Hours.** `assignment.hours_between(month_start, month_end)` clipped to
   the horizon.
6. **Internal client** (`forecast_client.is_internal?`): one `pay_stub` line
   of `hours × (override || bill rate)` on the ledger for
   `forecast_client.enterprise`, no splits, no commissions. Salaried gate
   applies (7).
7. **External client:** on the ledger for `forecast_client.billing_enterprise`:
   - `working_amount = hours × bill_rate`.
   - **Commissions:** for each of the tracker's `commissions`, a `commission`
     line on the commission's contributor's ledger. `PerHourCommission`:
     `hours × rate`; `PercentageCommission`: `working_amount × rate`.
     `working_amount -= commission_total`.
   - **Leads** for the month: `account_lead_for_month` / `project_lead_for_month`
     reimplemented locally as "a lead period whose `period_started_at` is on
     or before the month end and whose `ended_at` is nil or on/after the
     month start". (The `ActsAsPeriod#period_ended_at` default of
     `Date.today` makes the existing helpers return nil for future months.)
   - `rules = tracker.billing_rules`. Account Lead line
     `working_amount × rules.account_lead_share`; Project Lead line
     `working_amount × rules.project_lead_share`, each on the lead's own
     contributor's ledger for the same enterprise.
   - **IC:** if override present, `hours × override`; else
     `working_amount × (1 − treasury − AL if present − PL if present)`.
   - **Surplus:** `margin = (working_amount − ic_amount) / working_amount`;
     `surplus = max(0, (margin − rules.surplus_threshold) × working_amount)`.
     If > 0 and the lead exists, `account_lead_surplus` / `project_lead_surplus`
     lines of `surplus × rules.surplus_lead_share` on each lead's ledger.
   - **Salaried gate:** any payee whose admin user has a full-time period
     covering the month end that is not `variable_hours` is dropped from
     output (their line is not emitted). Payees with no admin user or no
     full-time periods pass. The lead's presence still reduces the IC share
     regardless. This is the rule at `invoice_tracker.rb:532` and `:595`.
   - Zero-amount lines are not emitted (`next if amount == 0`, as the
     payout builder does) — this is how a `0p/h` override removes Principal
     hours.
8. **Recurring ledger adjustments:** for each `RecurringLedgerAdjustment.active`,
   start from `next_due_on` and step forward with `advance` while the date
   is on or before the horizon end. Emit a `recurring_adjustment` line of
   `amount` for each due date that falls inside the horizon; due dates
   before the horizon start (an overdue, not-yet-materialized row) are
   skipped, since the daily task will materialize them as real adjustments.

Totals per ledger-month: `amount` sum, plus `confirmed_amount` and
`tentative_amount`. Per contributor: sum over its ledgers. Per enterprise
per month: sum over ledgers of that enterprise. Global: `skipped` counts and
`as_of` (`System.instance.runn_synced_at`).

### Architecture

#### 3.1 `ContributorProjections::Horizon` (`app/services/contributor_projections/horizon.rb`)

```ruby
Horizon = Struct.new(:starts_at, :ends_at, :months) do
  MONTHS_AHEAD = 3
  def self.current(today = Date.today)
    starts_at = today.beginning_of_month
    ends_at = (today + MONTHS_AHEAD.months).end_of_month
    months = (0..MONTHS_AHEAD).map { |i| m = today + i.months; Stacks::Period.new(m.strftime("%B, %Y"), m.beginning_of_month, m.end_of_month, :month) }
    new(starts_at, ends_at, months)
  end
end
```

Months are `Stacks::Period` instances so the contributor page can key on
them exactly like `all_items_grouped_by_month` does. Two periods are equal
when their `starts_at` match; add `==`/`eql?`/`hash` on `Stacks::Period`
based on `[starts_at, ends_at]` so hash lookups across the two sources work
(today `Period` has no equality, so identical months from two builders are
distinct keys).

#### 3.2 `ContributorProjections::Build` (`app/services/contributor_projections/build.rb`)

```ruby
module ContributorProjections
  # Ids, not AR objects, so a Result marshals small into Rails.cache (3.3).
  Line = Struct.new(:kind, :ledger_id, :enterprise_id, :contributor_id, :project_tracker_id, :project_tracker_name,
                    :hours, :rate, :amount, :description, :tentative, :month, keyword_init: true)
  Result = Struct.new(:horizon, :lines, :skipped, :as_of, keyword_init: true) do
    def by_ledger_month                                  # { ledger_id => { Period => [Line] } }
    def by_contributor_month(contributor, ledger: nil)   # { Period => { lines:, amount:, confirmed_amount:, tentative_amount:, hours: } }, optionally one ledger
    def by_enterprise_month                              # { enterprise_id => { Period => { amount:, confirmed_amount:, tentative_amount: } } }
    def by_contributor_totals(enterprise_id: nil)        # { contributor_id => { Period => { amount:, tentative_amount: } } } for the roll-up table
    def contributors                                     # preloaded Contributor index for the views, keyed by id
  end

  class Build
    def self.call(horizon: Horizon.current, contributor: nil)
```

Steps inside `call`:

1. Load once: `RunnAssignment.plannable.overlapping(horizon.starts_at, horizon.ends_at).includes(:runn_project, :runn_role, :runn_person)`;
   `ProjectTracker.where(runn_project_id: project_ids).includes(:forecast_projects => :forecast_client, :account_lead_periods => :admin_user, :project_lead_periods => :admin_user, :commissions => {contributor: :forecast_person})`;
   `Contributor.includes(forecast_person: {admin_user: :full_time_periods})` indexed by lowercased email;
   `Ledger.includes(:enterprise)` indexed by `[enterprise_id, contributor_id]`;
   `RecurringLedgerAdjustment.active.includes(ledger: :enterprise)`.
   When `contributor:` is given, assignments are still loaded for all people
   (a lead or commission recipient earns from other people's hours), but
   only lines whose ledger belongs to that contributor are kept.
2. For each assignment × month, apply the pricing rules above, appending
   `Line`s. Ledger lookup: `find_or_create_for` is **not** called; a
   missing ledger (contributor created after the enterprise) resolves via
   `Ledger.ensure_for_contributor!` semantics — in practice both
   `after_create` hooks guarantee the row exists, so a miss is counted under
   `skipped[:no_ledger]` and the line dropped.
3. Recurring adjustments (rule 8).
4. Return `Result`.

No writes, no HTTP. Pure functions over loaded rows; the pricing of one
assignment-month is a private method `price_client_line(...)` that returns
an array of `Line`s and is unit-tested directly.

Lead resolution helper (private):

```ruby
def lead_for_month(periods, month)
  periods.find { |p| p.started_at <= month.ends_at && (p.ended_at.nil? || p.ended_at >= month.starts_at) }&.admin_user
end
```

Salaried gate helper:

```ruby
def variable_hours_on?(admin_user, date)
  return true if admin_user.nil? || admin_user.full_time_periods.empty?
  admin_user.full_time_period_at(date)&.variable_hours?
end
```

`full_time_period_at` already projects an open period forward.

#### 3.3 Caching

`ContributorProjections::Build.cached_all` wraps `call` with
`Rails.cache.fetch(["contributor_projections", Date.current, System.instance.runn_synced_at&.to_i], expires_in: 1.hour)`.
Only the payables page uses it. The contributor page calls `call(contributor:)`
directly; one contributor's slice is cheap.

`Result` is cache-safe because `Line` carries ids and names only. The
views resolve contributors through `Result#contributors`, a `{ id => Contributor }`
index loaded lazily on first access (so a cached `Result` re-queries once
per request, not per row).

#### 3.4 Contributor page

`app/admin/contributors.rb` `show`:

```ruby
projection = ContributorProjections::Build.call(contributor: resource)
horizon = projection.horizon
items_result =
  if view_mode == :all
    resource.all_items_grouped_by_month(true, nil, horizon.ends_at + 1.month)
  else
    current_ledger.items_grouped_by_month(nil, horizon.ends_at + 1.month)
  end
projected_by_month =
  view_mode == :all ? projection.by_contributor_month(resource)
                    : projection.by_contributor_month(resource, ledger: current_ledger)
```

Passing `ends_at + 1.month` is required because `Stacks::Period.for_gradation`
stops one month short of `through`. Because the override replaces the
computed default (max item date + 2 months), guard it:
`[default_end, horizon.ends_at + 1.month].max` — implement by letting both
grouping methods accept the override as a *floor* (`ledger_ends_at = [computed, override].max`
when given) rather than a replacement. Update the two call sites in the
methods accordingly; no other callers pass an end override today (verify
with grep during implementation).

Add locals `projected_by_month:` and `projection_as_of:` to the partial.

`app/views/admin/contributors/_show.html.erb`:

- Balance table: third row `Projected (next 4 months)` with
  `number_to_currency(projected_by_month.values.sum { |m| m[:amount] })` and a
  muted `as of <time_ago>` suffix; when `projection_as_of` is nil or older
  than 2 days, render `<span class="pill at_risk">Runn sync stale</span>`
  after the amount.
- Month header pill (`view_mode == :all` branch): when
  `projected_by_month[period]` exists and its amount > 0, append
  `· projected <amount>` inside the `split` span, and use its `hours` for the
  hours figure when the period is at or after the current month.
- Items table: after the real items for a month, render one `<tr>` per
  projected line: first cell `<span class="pill projected">Projected</span>`
  plus `<span class="pill tentative">Tentative</span>` when flagged; second
  cell the tracker name linked to `admin_project_tracker_path` (or the
  adjustment description); third the italic description; last the amount.
  Add `.pill.projected { background: #e8eefc; color: #2b4a9b; }` and
  `.pill.tentative { background: #f4ecd8; color: #7a5a12; }` to the admin
  stylesheet next to the existing pill styles.
- Past months (period ends before today's month) never show projected rows,
  because the engine never emits lines for them.

#### 3.5 Payables page

`app/admin/money.rb` `payable_qbo_bills`:

```ruby
@projection =
  begin
    ContributorProjections::Build.cached_all
  rescue => e
    Rails.logger.error("[payables] projection failed: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    nil
  end
@projection_scope_enterprise = @active_qa&.enterprise
```

`app/views/admin/money/payable_qbo_bills.html.erb`, directly under the
existing summary card:

- If `@projection` is nil: a one-line `<em>Projection unavailable — see logs.</em>`.
- Otherwise a `Projected Payables` table with one row per horizon month:
  month name, confirmed amount, tentative amount (muted, omitted when zero),
  total; a final `Horizon total` row. Amounts come from
  `@projection.by_enterprise_month` summed across all enterprises on the All
  tab, or the selected enterprise's entry on an enterprise tab.
- A notice line under the table:
  `Projected from Runn as of <time_ago> · <n> assignments skipped (<k> unmapped people, <m> unmapped projects)`.
  Stale (> 2 days or nil) → `<span class="pill at_risk">Runn sync stale</span>`
  prefix.
- A `<details>` block "By contributor" containing a table: contributor name
  (linked to `admin_contributor_path`), one column per horizon month, and a
  total column; rows sorted by total descending; scoped to the same
  enterprise filter. Tentative amounts are shown in the same cell as a muted
  `(+$x tentative)` suffix.

The pill vocabulary matches the rest of the page (`pill at_risk`).

### Error handling

- **Sync:** each `sync_*` raises on HTTP failure (`handle_response` already
  raises). The daily task's rescue reports it as a `SystemTask` error and
  the earlier tables in the run stay updated. `runn_synced_at` is not
  advanced, so both surfaces show the stale pill once two days pass.
- **Empty fetch:** `prune_assignments_not_in!` is a no-op for blank ids.
- **Engine:** data problems never raise; they land in `skipped`. Rate
  fallbacks are ordered role → forecast project → system default. A missing
  ledger drops the line and counts it.
- **Surfaces:** the payables page rescues the projection call and renders a
  placeholder. The contributor page does the same around `Build.call`, with
  `projected_by_month = {}` and `projection_as_of = nil` on failure so the
  ledger still renders.
- **Migration:** aborts on an unrecognized treasury split rather than
  guessing.

### Testing

Minitest with mocha, following the repo's fixture-light style (`test_helper`
builders such as `make_forecast_project!`, `make_project_tracker!`,
`make_admin_user!`).

- `test/lib/stacks/billing_model_test.rb`: both models' derived
  `ic_ceiling` / `surplus_threshold`; `for` raises on unknown.
- `test/models/project_tracker_test.rb` (new or extended): default model,
  `company_treasury_split` reads from the model, enum rejects unknown values.
- `test/models/contributor_payout_test.rb`: extend the existing
  `calculate_surplus` tests with a `new_deal_v2` tracker: threshold 0.46,
  maximum 0.54, and a 3-point surplus when the IC is paid at the v1 ceiling
  on a v2 tracker.
- `test/models/invoice_tracker_test.rb`: extend the existing payout build
  tests (or add one using the same stubbing pattern) so a v2 tracker yields
  a 54% IC line and unchanged 8% / 5% lead lines.
- `test/lib/stacks/runn_sync_test.rb`: stub `get_people` / `get_roles` /
  `get_assignments` / `get_projects` on the instance with hand-written
  payloads. Assert: rows land with mapped columns; a second run with the
  same `updatedAt` does not rewrite (spy on `upsert_all`); a changed
  `updatedAt` does; an assignment missing from the second fetch is deleted;
  people are not deleted when archived; `runn_synced_at` is set; when a
  sync raises, `runn_synced_at` is unchanged; the advisory lock skip path
  logs and returns.
- `test/models/runn_assignment_test.rb`: `working_days_between` over a
  weekend-spanning range, clipped to the window, and the non-working-day
  flag.
- `test/services/contributor_projections/build_test.rb`, each test building
  its own rows:
  - external client, both leads present, v1: IC 57%, AL 8%, PL 5%, no surplus;
  - same on v2: IC 54%, surplus 0;
  - v2 with an override below the ceiling: surplus > 0, 15% to each lead;
  - override of 0 emits no IC line;
  - per-hour and percentage commissions deducted before the split, with a
    `commission` line on the recipient's ledger;
  - internal client: single `pay_stub` line on the enterprise ledger;
  - salaried lead: no lead line, IC share still reduced;
  - open-ended lead period resolves in a future month;
  - assignment spanning two months and the horizon edge: hours split
    correctly; weekends excluded; `is_non_working_day` counts all days;
  - tentative project flags lines;
  - unmapped person / project / no-ledger counted in `skipped`;
  - recurring adjustment (monthly, twice_monthly, quarterly) emits the right
    number of lines in the right months;
  - `contributor:` filter keeps only that contributor's ledger lines,
    including lead lines earned from other people's hours;
  - `Result#by_enterprise_month` and `#by_contributor_totals` sums.
- `test/lib/stacks/period_test.rb`: equality and hash semantics.
- View tests: the repo has no admin-page test precedent, so the two ERB
  changes are covered by a controller-less render check only where cheap:
  a `test/services/contributor_projections/result_test.rb` for the
  aggregation helpers the views call, and a manual smoke check against the
  dev database (production restore) for both pages before the PR is opened.

Full-suite run time is ~100 minutes locally; run targeted files during
implementation and the full suite once before opening the PR.

## Out of scope

- `invoice_trackers.company_treasury_split` and the 70% cap validation in
  `ContributorPayout#contributor_payouts_within_seventy_percent`. An invoice
  can span trackers on different billing models; making the cap per-tracker
  is separate work. Until then the cap uses the invoice-level column as
  today.
- Shifting projected dollars to expected payment dates.
- Extrapolating `RecurringAssignment` rules into the projection.
- Runn leave / time-off (`get_leave_for_person` stays unwired).
- Mirroring Runn clients, phases, or rate cards.
- Replacing the live `Resourcing::RunnPersonResolver` with the mirror.
- An MCP tool or HTTP endpoint for projections.
- Any change to `/admin/dashboard` or its redirect.
- Salary projections for full-timers (never on the ledger today).
- Adding the `0p/h` Principal overrides to Forecast project notes
  (operational prerequisite, done in Forecast, not in code).
