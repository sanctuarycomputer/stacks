# Contributor Projections Implementation Plan (Part 3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Project each contributor's earnings per ledger and month for the current month plus three, from the local Runn mirror, priced with the same rules the payout builder and pay-cycle generator use; show it on the contributor page and roll it up on the payables page.

**Architecture:** `ContributorProjections::Build` loads the mirror and pricing inputs once, **resolves** each Runn assignment to a (contributor, tracker, workstream, month) key with summed hours, then **prices** each key into `Line` structs (ids only, cache-safe). `Result` provides the per-ledger / per-contributor / per-enterprise month rollups. Two ERB surfaces render it. No writes, no HTTP.

**Tech Stack:** Rails 6.1, ActiveAdmin, minitest + mocha. Depends on Parts 1 and 2 being merged into this branch (billing model, Runn mirror).

**Spec:** `docs/superpowers/specs/2026-09-08-contributor-payment-projections-design.md` (Part 3).

## Global Constraints

- Work ONLY in the worktree `/Users/hhff/Documents/Code/stacks/.claude/worktrees/feat+contributor-payment-projections`. Never `cd` to `/Users/hhff/Documents/Code/stacks`. Before every commit run `git rev-parse --abbrev-ref HEAD`; if it does not print `worktree-feat+contributor-payment-projections`, STOP and report BLOCKED.
- Horizon = current month + 3 following months (`MONTHS_AHEAD = 3`). Every month-keyed hash is keyed by the month's `starts_at` `Date`, never by a `Stacks::Period`. `Stacks::Period` is not modified.
- Bill rate = `forecast_project.hourly_rate`. The Runn role's `standard_rate` only selects the workstream. Override = `forecast_project.hourly_rate_override_for_email_address(email)` on the chosen workstream only.
- Lead resolution: `p.period_started_at <= month_end && (p.ended_at.nil? || p.ended_at >= month_start)`.
- Salaried gate: `ftp = admin_user.full_time_period_at(month_end); ftp.nil? || ftp.variable_hours?` — payees with no admin user pass.
- Zero-amount lines are never emitted. Surplus is computed only when an IC line with amount > 0 exists for the key (the real builder only creates surplus chunks from persisted IC entries).
- `runn_synced_at` is read via `System.first`, never `System.instance`. Stale = nil or older than 2 days.
- `Date.today` throughout.
- Run targeted test files during the tasks; the full suite (`bin/rails test`, ~100 min) runs once in the final task.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8
  ```

---

## File map

| File | Responsibility |
|---|---|
| `app/services/contributor_projections.rb` (create) | Namespace constants + `runn_synced_at` helper |
| `app/services/contributor_projections/horizon.rb` (create) | `Horizon` struct |
| `app/services/contributor_projections/line.rb` (create) | `Line` struct |
| `app/services/contributor_projections/result.rb` (create) | `Result` struct + rollups |
| `app/services/contributor_projections/build.rb` (create) | The engine |
| `test/services/contributor_projections/horizon_test.rb` (create) | Horizon math |
| `test/services/contributor_projections/build_test.rb` (create) | Pricing rules |
| `test/services/contributor_projections/result_test.rb` (create) | Rollups |
| `app/models/contributor.rb` (modify, `all_items_grouped_by_month`) | `min_ends_at:` floor |
| `app/models/ledger.rb` (modify, `items_grouped_by_month`) | `min_ends_at:` floor |
| `test/models/ledger_test.rb`, `test/models/contributor_test.rb` (modify) | floor tests |
| `app/admin/contributors.rb` (modify, `show`) | build projection, pass locals |
| `app/views/admin/contributors/_show.html.erb` (modify) | projected row, pill, rows |
| `app/admin/money.rb` (modify, `payable_qbo_bills`) | cached projection |
| `app/views/admin/money/payable_qbo_bills.html.erb` (modify) | Projected Payables card + by-contributor table |
| `app/assets/stylesheets/active_admin.scss` (modify) | `.pill.projected`, `.pill.tentative` |

---

### Task 1: Horizon, Line, and namespace helpers

**Files:**
- Create: `app/services/contributor_projections.rb`, `app/services/contributor_projections/horizon.rb`, `app/services/contributor_projections/line.rb`
- Test: `test/services/contributor_projections/horizon_test.rb`

**Interfaces:**
- Produces:
  - `ContributorProjections::MONTHS_AHEAD = 3`, `ContributorProjections::STALE_AFTER_DAYS = 2`, `ContributorProjections::KIND_ORDER`, `ContributorProjections::HOURS_KINDS`, `ContributorProjections.runn_synced_at` → `DateTime|nil`, `ContributorProjections.stale?(as_of, today: Date.today)` → Boolean.
  - `ContributorProjections::Horizon` (Struct, keyword_init: `starts_at`, `ends_at`, `months`) with `Horizon.current(today = Date.today)` and `#month_keys` → `[Date]`. `months` are `Stacks::Period` instances.
  - `ContributorProjections::Line` (Struct, keyword_init) with members `kind, ledger_id, enterprise_id, contributor_id, project_tracker_id, project_tracker_name, hours, rate, amount, description, tentative, rate_mismatch, month`. `ContributorProjections::KIND_ORDER`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/contributor_projections/horizon_test.rb
require "test_helper"

class ContributorProjections::HorizonTest < ActiveSupport::TestCase
  test "current covers this month plus MONTHS_AHEAD following months" do
    h = ContributorProjections::Horizon.current(Date.new(2026, 9, 8))
    assert_equal Date.new(2026, 9, 1), h.starts_at
    assert_equal Date.new(2026, 12, 31), h.ends_at
    assert_equal 4, h.months.size
    assert_equal [Date.new(2026, 9, 1), Date.new(2026, 10, 1), Date.new(2026, 11, 1), Date.new(2026, 12, 1)], h.month_keys
    assert_equal "September, 2026", h.months.first.label
    assert_equal Date.new(2026, 9, 30), h.months.first.ends_at
    assert_equal :month, h.months.first.gradation
  end

  test "current crosses a year boundary" do
    h = ContributorProjections::Horizon.current(Date.new(2026, 11, 20))
    assert_equal [Date.new(2026, 11, 1), Date.new(2026, 12, 1), Date.new(2027, 1, 1), Date.new(2027, 2, 1)], h.month_keys
    assert_equal Date.new(2027, 2, 28), h.ends_at
  end

  test "stale? is true for nil and for anything older than STALE_AFTER_DAYS" do
    today = Date.new(2026, 9, 8)
    assert ContributorProjections.stale?(nil, today: today)
    assert ContributorProjections.stale?(DateTime.new(2026, 9, 5, 12), today: today)
    assert_not ContributorProjections.stale?(DateTime.new(2026, 9, 6, 12), today: today)
    assert_not ContributorProjections.stale?(DateTime.new(2026, 9, 8, 1), today: today)
  end

  test "runn_synced_at reads through System.first" do
    s = System.first || System.create!(settings: {})
    s.update!(runn_synced_at: DateTime.new(2026, 9, 7, 3))
    assert_equal DateTime.new(2026, 9, 7, 3).to_i, ContributorProjections.runn_synced_at.to_i
  end

  test "Line is keyword-initialized with every member" do
    l = ContributorProjections::Line.new(kind: :individual_contributor, ledger_id: 1, enterprise_id: 2, contributor_id: 3,
                                         project_tracker_id: 4, project_tracker_name: "T", hours: 10.0, rate: 200.0, amount: 1080.0,
                                         description: "d", tentative: false, rate_mismatch: false, month: Date.new(2026, 9, 1))
    assert_equal 1080.0, l.amount
    assert_equal Date.new(2026, 9, 1), l.month
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/contributor_projections/horizon_test.rb`
Expected: FAIL with `NameError: uninitialized constant ContributorProjections`.

- [ ] **Step 3: Write the files**

```ruby
# app/services/contributor_projections.rb
# Forward-looking contributor earnings, priced from the local Runn mirror
# with the same rules the invoice pass and pay cycles apply. See
# docs/superpowers/specs/2026-09-08-contributor-payment-projections-design.md.
module ContributorProjections
  MONTHS_AHEAD = 3
  STALE_AFTER_DAYS = 2

  KIND_ORDER = %i[
    individual_contributor pay_stub account_lead project_lead
    account_lead_surplus project_lead_surplus commission recurring_adjustment
  ].freeze

  # Line kinds whose `hours` are the payee's own worked hours (a constant
  # inside a `Struct.new do` block lands on this module anyway, so define it
  # here explicitly).
  HOURS_KINDS = %i[individual_contributor pay_stub].freeze

  # System.first, NOT System.instance: instance is memoized for the life of
  # the process, so a web worker would never see a newer sync stamp.
  def self.runn_synced_at
    System.first&.runn_synced_at
  end

  def self.stale?(as_of, today: Date.today)
    as_of.nil? || as_of.to_date < today - STALE_AFTER_DAYS
  end
end
```

```ruby
# app/services/contributor_projections/horizon.rb
module ContributorProjections
  # The months a projection covers: the current month plus MONTHS_AHEAD.
  # `months` are Stacks::Period instances for display; key hashes by
  # `month_keys` (each period's starts_at Date), never by the Period itself.
  Horizon = Struct.new(:starts_at, :ends_at, :months, keyword_init: true) do
    def self.current(today = Date.today)
      months = (0..MONTHS_AHEAD).map do |i|
        first = today.beginning_of_month + i.months
        Stacks::Period.new(first.strftime("%B, %Y"), first, first.end_of_month, :month)
      end
      new(starts_at: months.first.starts_at, ends_at: months.last.ends_at, months: months)
    end

    def month_keys
      months.map(&:starts_at)
    end
  end
end
```

```ruby
# app/services/contributor_projections/line.rb
module ContributorProjections
  # One projected ledger line. Ids and names only (no AR objects) so a Result
  # marshals small into Rails.cache. `month` is the month's starts_at Date.
  Line = Struct.new(
    :kind, :ledger_id, :enterprise_id, :contributor_id,
    :project_tracker_id, :project_tracker_name,
    :hours, :rate, :amount, :description,
    :tentative, :rate_mismatch, :month,
    keyword_init: true
  )
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/contributor_projections/horizon_test.rb`
Expected: `5 runs, 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/services/contributor_projections.rb app/services/contributor_projections/horizon.rb app/services/contributor_projections/line.rb test/services/contributor_projections/horizon_test.rb
git commit -m "feat: ContributorProjections namespace, Horizon, and Line

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 2: `Result` rollups

**Files:**
- Create: `app/services/contributor_projections/result.rb`
- Test: `test/services/contributor_projections/result_test.rb`

**Interfaces:**
- Consumes: `Horizon`, `Line`, `KIND_ORDER` (Task 1).
- Produces: `ContributorProjections::Result` (Struct, keyword_init: `horizon`, `lines`, `skipped` (Hash reason→count), `skipped_details` (Hash reason→[String]), `as_of`) with:
  - `#by_ledger_month` → `{ ledger_id => { Date => [Line] } }`
  - `#by_contributor_month(contributor, ledger: nil)` → `{ Date => summary }` for every horizon month
  - `#by_enterprise_month` → `{ enterprise_id => { Date => summary } }`
  - `#totals_by_month(enterprise_id: nil)` → `{ Date => summary }`
  - `#by_contributor_totals(enterprise_id: nil)` → `{ contributor_id => { Date => summary } }`
  - `#contributors` → `{ id => Contributor }` (lazy query)
  - `#stale?(today = Date.today)`, `#skipped_total`
  - where `summary = { lines: [Line], amount:, confirmed_amount:, tentative_amount:, hours: }` (amounts rounded to cents; `hours` sums IC and pay-stub hours only).

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/contributor_projections/result_test.rb
require "test_helper"

class ContributorProjections::ResultTest < ActiveSupport::TestCase
  SEP = Date.new(2026, 9, 1)
  OCT = Date.new(2026, 10, 1)

  def line(kind:, ledger_id:, enterprise_id:, contributor_id:, amount:, month:, hours: nil, tentative: false)
    ContributorProjections::Line.new(kind: kind, ledger_id: ledger_id, enterprise_id: enterprise_id, contributor_id: contributor_id,
                                     project_tracker_id: 1, project_tracker_name: "T", hours: hours, rate: 200.0, amount: amount,
                                     description: "d", tentative: tentative, rate_mismatch: false, month: month)
  end

  def result(lines)
    ContributorProjections::Result.new(
      horizon: ContributorProjections::Horizon.current(Date.new(2026, 9, 8)),
      lines: lines, skipped: { unmapped_person: 2 }, skipped_details: { unmapped_person: %w[a b] }, as_of: DateTime.new(2026, 9, 8, 3),
    )
  end

  def lines
    [
      line(kind: :individual_contributor, ledger_id: 10, enterprise_id: 1, contributor_id: 100, amount: 1000.0, hours: 5.0, month: SEP),
      line(kind: :account_lead, ledger_id: 11, enterprise_id: 1, contributor_id: 101, amount: 80.0, hours: 5.0, month: SEP),
      line(kind: :individual_contributor, ledger_id: 10, enterprise_id: 1, contributor_id: 100, amount: 500.0, hours: 2.5, month: OCT, tentative: true),
      line(kind: :pay_stub, ledger_id: 20, enterprise_id: 2, contributor_id: 100, amount: 300.0, hours: 3.0, month: SEP),
      line(kind: :recurring_adjustment, ledger_id: 10, enterprise_id: 1, contributor_id: 100, amount: -50.0, month: SEP),
    ]
  end

  test "by_contributor_month sums across ledgers and fills every horizon month" do
    r = result(lines)
    c = Contributor.new; c.stubs(:id).returns(100)
    by = r.by_contributor_month(c)
    assert_equal r.horizon.month_keys, by.keys
    assert_in_delta 1250.0, by[SEP][:amount], 0.001          # 1000 + 300 - 50
    assert_in_delta 1250.0, by[SEP][:confirmed_amount], 0.001
    assert_in_delta 8.0, by[SEP][:hours], 0.001              # IC 5 + pay stub 3; adjustment has no hours
    assert_in_delta 500.0, by[OCT][:amount], 0.001
    assert_in_delta 500.0, by[OCT][:tentative_amount], 0.001
    assert_in_delta 0.0, by[OCT][:confirmed_amount], 0.001
    assert_equal 0.0, by[Date.new(2026, 11, 1)][:amount]
    assert_equal [], by[Date.new(2026, 11, 1)][:lines]
  end

  test "by_contributor_month scoped to one ledger" do
    r = result(lines)
    c = Contributor.new; c.stubs(:id).returns(100)
    l = Ledger.new; l.stubs(:id).returns(20)
    assert_in_delta 300.0, r.by_contributor_month(c, ledger: l)[SEP][:amount], 0.001
  end

  test "lines within a month are ordered confirmed first, then tracker, then KIND_ORDER" do
    r = result(lines)
    c = Contributor.new; c.stubs(:id).returns(100)
    kinds = r.by_contributor_month(c)[SEP][:lines].map(&:kind)
    assert_equal %i[individual_contributor pay_stub recurring_adjustment], kinds
  end

  test "by_enterprise_month and totals_by_month" do
    r = result(lines)
    by = r.by_enterprise_month
    assert_in_delta 1030.0, by[1][SEP][:amount], 0.001        # 1000 + 80 - 50
    assert_in_delta 300.0, by[2][SEP][:amount], 0.001
    assert_in_delta 1330.0, r.totals_by_month[SEP][:amount], 0.001
    assert_in_delta 1030.0, r.totals_by_month(enterprise_id: 1)[SEP][:amount], 0.001
    assert_in_delta 500.0, r.totals_by_month[OCT][:tentative_amount], 0.001
  end

  test "by_contributor_totals scoped by enterprise" do
    r = result(lines)
    all = r.by_contributor_totals
    assert_in_delta 1250.0, all[100][SEP][:amount], 0.001
    assert_in_delta 80.0, all[101][SEP][:amount], 0.001
    scoped = r.by_contributor_totals(enterprise_id: 2)
    assert_equal [100], scoped.keys
    assert_in_delta 300.0, scoped[100][SEP][:amount], 0.001
  end

  test "by_ledger_month groups raw lines" do
    r = result(lines)
    assert_equal 2, r.by_ledger_month[10][SEP].size
    assert_equal 1, r.by_ledger_month[20][SEP].size
  end

  test "stale? and skipped_total" do
    r = result(lines)
    assert_not r.stale?(Date.new(2026, 9, 9))
    assert r.stale?(Date.new(2026, 9, 12))
    assert_equal 2, r.skipped_total
  end

  test "contributors resolves the referenced ids" do
    fp = ForecastPerson.create!(forecast_id: 990_001, email: "res@example.com", data: {})
    real = fp.contributor
    r = result([line(kind: :pay_stub, ledger_id: 1, enterprise_id: 1, contributor_id: real.id, amount: 1.0, hours: 1.0, month: SEP)])
    assert_equal real, r.contributors[real.id]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/contributor_projections/result_test.rb`
Expected: FAIL with `NameError: uninitialized constant ContributorProjections::Result`.

- [ ] **Step 3: Write `Result`**

```ruby
# app/services/contributor_projections/result.rb
module ContributorProjections
  Result = Struct.new(:horizon, :lines, :skipped, :skipped_details, :as_of, keyword_init: true) do
    # { ledger_id => { Date => [Line] } }
    def by_ledger_month
      lines.group_by(&:ledger_id).transform_values { |ls| ls.group_by(&:month) }
    end

    # { Date => summary } for every horizon month, across the contributor's
    # ledgers or just one of them.
    def by_contributor_month(contributor, ledger: nil)
      subset = lines.select { |l| l.contributor_id == contributor.id && (ledger.nil? || l.ledger_id == ledger.id) }
      month_index(subset)
    end

    # { enterprise_id => { Date => summary } }
    def by_enterprise_month
      lines.group_by(&:enterprise_id).transform_values { |ls| month_index(ls) }
    end

    # { Date => summary }, optionally for one enterprise.
    def totals_by_month(enterprise_id: nil)
      month_index(scope_to_enterprise(enterprise_id))
    end

    # { contributor_id => { Date => summary } }, optionally for one enterprise.
    def by_contributor_totals(enterprise_id: nil)
      scope_to_enterprise(enterprise_id).group_by(&:contributor_id).transform_values { |ls| month_index(ls) }
    end

    # Lazy, once per Result: the views need names and links.
    def contributors
      @contributors ||= Contributor.where(id: lines.map(&:contributor_id).uniq).includes(:forecast_person).index_by(&:id)
    end

    def stale?(today = Date.today)
      ContributorProjections.stale?(as_of, today: today)
    end

    def skipped_total
      (skipped || {}).values.sum
    end

    private

    def scope_to_enterprise(enterprise_id)
      enterprise_id ? lines.select { |l| l.enterprise_id == enterprise_id } : lines
    end

    def month_index(ls)
      horizon.month_keys.index_with { |m| summarize(ls.select { |l| l.month == m }) }
    end

    def summarize(ls)
      sorted = ls.sort_by { |l| [l.tentative ? 1 : 0, l.project_tracker_name.to_s, KIND_ORDER.index(l.kind) || 99] }
      {
        lines: sorted,
        amount: ls.sum(&:amount).round(2),
        confirmed_amount: ls.reject(&:tentative).sum(&:amount).round(2),
        tentative_amount: ls.select(&:tentative).sum(&:amount).round(2),
        hours: ls.select { |l| HOURS_KINDS.include?(l.kind) }.sum { |l| l.hours.to_f }.round(2),
      }
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/contributor_projections/result_test.rb`
Expected: `8 runs, 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/services/contributor_projections/result.rb test/services/contributor_projections/result_test.rb
git commit -m "feat: ContributorProjections::Result month rollups

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 3: `Build` — the engine

**Files:**
- Create: `app/services/contributor_projections/build.rb`
- Test: `test/services/contributor_projections/build_test.rb`

**Interfaces:**
- Consumes: Part 1 (`ProjectTracker#billing_rules`, `Rules#ic_share/account_lead_share/project_lead_share/surplus_lead_share/surplus_threshold`), Part 2 (`RunnAssignment.plannable.overlapping`, `#hours_between`, `RunnPerson#email`, `RunnRole#standard_rate`, `RunnProject#is_confirmed/is_archived/is_template`), `ForecastProject#hourly_rate`, `#hourly_rate_override_for_email_address`, `#has_no_explicit_hourly_rate?`, `ForecastClient#is_internal?`, `#enterprise`, `#billing_enterprise`, `AccountLeadPeriod/ProjectLeadPeriod#period_started_at/ended_at/admin_user`, `AdminUser#full_time_period_at`, `FullTimePeriod#variable_hours?`, `PerHourCommission`/`PercentageCommission#rate/#contributor`, `RecurringLedgerAdjustment#advance`, `Ledger`.
- Produces: `ContributorProjections::Build.call(horizon: Horizon.current, contributor: nil)` → `Result`; `ContributorProjections::Build.cached_all(horizon: Horizon.current)` → `Result` (Rails.cache, 1 hour, keyed on today + `runn_synced_at`).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/contributor_projections/build_test.rb
require "test_helper"

# Every test builds its own rows. Horizon is pinned to Sep–Dec 2026.
# Sep 7–11 2026 is Mon–Fri: a 480 min/day assignment = 40 hours.
class ContributorProjections::BuildTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 9, 8)
  SEP = Date.new(2026, 9, 1)
  OCT = Date.new(2026, 10, 1)

  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.sanctuary
    @seq = 800_000 + rand(100_000)
  end

  def nid
    @seq += 1
  end

  def horizon
    ContributorProjections::Horizon.current(TODAY)
  end

  def build(contributor: nil)
    ContributorProjections::Build.call(horizon: horizon, contributor: contributor)
  end

  # --- builders --------------------------------------------------------

  def person!(email, admin: false, ftp: nil)
    fp = ForecastPerson.create!(forecast_id: nid, email: email, data: {})
    if admin || ftp
      au = AdminUser.create!(email: email, password: "password123", password_confirmation: "password123")
      if ftp
        FullTimePeriod.create!(admin_user: au, started_at: Date.new(2025, 1, 1), ended_at: ftp == :ended ? Date.new(2026, 6, 30) : nil,
                               contributor_type: ftp == :ended ? :five_day : ftp)
      end
    end
    fp.reload
  end

  def runn_person!(email)
    RunnPerson.create!(runn_id: nid, first_name: "R", last_name: "P", email: email)
  end

  def runn_role!(rate)
    RunnRole.create!(runn_id: nid, name: "$#{rate}.00 p/h", standard_rate: rate, default_hour_cost: 0)
  end

  def client!(internal_to: nil)
    fc = ForecastClient.create!(forecast_id: nid, name: "Client #{@seq}")
    EnterpriseForecastClient.create!(enterprise: internal_to, forecast_client_id: fc.forecast_id) if internal_to
    fc
  end

  def workstream!(client, rate: 200, notes: nil, tags: nil, archived: false)
    ForecastProject.create!(forecast_id: nid, client_id: client.forecast_id, name: "WS #{@seq}", code: "WS-#{@seq}",
                            tags: tags || ["#{rate}p/h"], notes: notes, archived: archived)
  end

  def tracker!(workstreams, model: "new_deal_v1", confirmed: true, archived: false)
    rp = RunnProject.create!(runn_id: nid, name: "RP #{@seq}", is_confirmed: confirmed, is_archived: archived, is_template: false)
    pt = ProjectTracker.new(name: "Tracker #{@seq}", billing_model: model, runn_project_id: rp.runn_id)
    pt.save!(validate: false)
    workstreams.each { |ws| ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: ws) }
    pt
  end

  def assign!(runn_person, tracker, role, start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 11), minutes: 480, billable: true, placeholder: false, non_working_day: false)
    RunnAssignment.create!(runn_id: nid, person_id: runn_person.runn_id, project_id: tracker.runn_project_id, role_id: role.runn_id,
                           start_date: start_date, end_date: end_date, minutes_per_day: minutes, is_billable: billable,
                           is_placeholder: placeholder, is_non_working_day: non_working_day)
  end

  def lead!(klass, tracker, admin_user, started_at: nil, ended_at: nil)
    klass.create!(project_tracker: tracker, admin_user: admin_user, started_at: started_at, ended_at: ended_at)
  end

  def lines_for(result, forecast_person, kind: nil, month: SEP)
    result.lines.select do |l|
      l.contributor_id == forecast_person.contributor.id &&
        (month.nil? || l.month == month) &&
        (kind.nil? || l.kind == kind)
    end
  end

  def amount_for(result, forecast_person, kind:, month: SEP)
    lines_for(result, forecast_person, kind: kind, month: month).sum(&:amount)
  end

  # A standard external setup: IC + AL + PL on one v1 tracker, 40h at $200.
  def standard_setup(model: "new_deal_v1", notes: nil)
    @ic = person!("ic-#{@seq}@example.com")
    @al = person!("al-#{@seq}@example.com", admin: true)
    @pl = person!("pl-#{@seq}@example.com", admin: true)
    @client = client!
    @ws = workstream!(@client, rate: 200, notes: notes)
    @pt = tracker!([@ws], model: model)
    lead!(AccountLeadPeriod, @pt, @al.admin_user, started_at: Date.new(2026, 8, 1))
    lead!(ProjectLeadPeriod, @pt, @pl.admin_user, started_at: Date.new(2026, 8, 1))
    @role = runn_role!(200)
    @rp_ic = runn_person!(@ic.email)
    assign!(@rp_ic, @pt, @role)
  end

  # --- pricing ---------------------------------------------------------

  test "external client on new_deal_v1: IC 57%, AL 8%, PL 5%, no surplus" do
    standard_setup
    r = build
    assert_in_delta 4560.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 8000 * 0.57
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01               # 8000 * 0.08
    assert_in_delta 400.0, amount_for(r, @pl, kind: :project_lead), 0.01               # 8000 * 0.05
    assert_empty r.lines.select { |l| l.kind.to_s.end_with?("surplus") }
    ic = lines_for(r, @ic, kind: :individual_contributor).first
    assert_equal "- 40.0 hrs * $200.00 p/h * 57.0% = $4,560.00", ic.description
    assert_equal @pt.id, ic.project_tracker_id
    assert_equal @sanctuary.id, ic.enterprise_id
    assert_equal Ledger.find_by!(enterprise: @sanctuary, contributor: @ic.contributor).id, ic.ledger_id
    assert_equal 40.0, ic.hours
    assert_not ic.tentative
    assert_not ic.rate_mismatch
  end

  test "external client on new_deal_v2: IC 54%, surplus zero" do
    standard_setup(model: "new_deal_v2")
    r = build
    assert_in_delta 4320.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 8000 * 0.54
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01
    assert_empty r.lines.select { |l| l.kind.to_s.end_with?("surplus") }
  end

  test "override below the ceiling on v2 yields surplus split 15% to each lead" do
    standard_setup(model: "new_deal_v2", notes: "ic-#{@seq}@example.com:80p/h")
    r = build
    assert_in_delta 3200.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 40 * 80
    # margin = (8000 - 3200) / 8000 = 0.60; surplus = (0.60 - 0.46) * 8000 = 1120; 15% = 168
    assert_in_delta 168.0, amount_for(r, @al, kind: :account_lead_surplus), 0.01
    assert_in_delta 168.0, amount_for(r, @pl, kind: :project_lead_surplus), 0.01
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01, "AL 8% unchanged by the override"
  end

  test "a 0p/h override emits no IC line and no surplus" do
    standard_setup(notes: "ic-#{@seq}@example.com:0p/h")
    r = build
    assert_empty lines_for(r, @ic)
    assert_empty r.lines.select { |l| l.kind.to_s.end_with?("surplus") }
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01
  end

  test "commissions come off the top before the split and land on the recipient's ledger" do
    standard_setup
    rec = person!("rec-#{@seq}@example.com")
    PerHourCommission.create!(project_tracker: @pt, contributor: rec.contributor, rate: 10)       # 40 * 10 = 400
    PercentageCommission.create!(project_tracker: @pt, contributor: rec.contributor, rate: 0.05)  # 8000 * 0.05 = 400
    r = build
    assert_in_delta 800.0, amount_for(r, rec, kind: :commission), 0.01
    # working = 8000 - 800 = 7200
    assert_in_delta 4104.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 7200 * 0.57
    assert_in_delta 576.0, amount_for(r, @al, kind: :account_lead), 0.01              # 7200 * 0.08
  end

  test "internal client prices a single pay_stub line on that enterprise's ledger with no splits" do
    internal = Enterprise.find_or_create_by!(name: "Internal Ent #{@seq}")
    ic = person!("int-#{@seq}@example.com")
    al = person!("intal-#{@seq}@example.com", admin: true)
    client = client!(internal_to: internal)
    ws = workstream!(client, rate: 100)
    pt = tracker!([ws])
    lead!(AccountLeadPeriod, pt, al.admin_user, started_at: Date.new(2026, 8, 1))
    PerHourCommission.create!(project_tracker: pt, contributor: al.contributor, rate: 10)
    assign!(runn_person!(ic.email), pt, runn_role!(100))
    r = build
    stub = lines_for(r, ic, kind: :pay_stub).first
    assert_in_delta 4000.0, stub.amount, 0.01                      # 40 * 100
    assert_equal Ledger.find_by!(enterprise: internal, contributor: ic.contributor).id, stub.ledger_id
    assert_empty lines_for(r, al), "no AL share and no commission on internal work"
  end

  test "internal client with no explicit rate and no override is skipped under no_explicit_rate" do
    internal = Enterprise.find_or_create_by!(name: "Internal Ent #{@seq}")
    ic = person!("int2-#{@seq}@example.com")
    client = client!(internal_to: internal)
    ws = workstream!(client, tags: [])
    pt = tracker!([ws])
    assign!(runn_person!(ic.email), pt, runn_role!(175))
    r = build
    assert_empty lines_for(r, ic)
    assert_equal 1, r.skipped[:no_explicit_rate]
  end

  # --- payees and leads -------------------------------------------------

  test "salaried lead gets no line but still reduces the IC share" do
    @ic = person!("ic-#{@seq}@example.com")
    @al = person!("al-#{@seq}@example.com", ftp: :five_day)
    @client = client!
    @ws = workstream!(@client, rate: 200)
    @pt = tracker!([@ws])
    lead!(AccountLeadPeriod, @pt, @al.admin_user, started_at: Date.new(2026, 8, 1))
    assign!(runn_person!(@ic.email), @pt, runn_role!(200))
    r = build
    assert_empty lines_for(r, @al)
    assert_in_delta 4960.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 8000 * (1 - 0.30 - 0.08)
  end

  test "variable_hours payee and ex-employee payee are both paid" do
    v = person!("v-#{@seq}@example.com", ftp: :variable_hours)
    x = person!("x-#{@seq}@example.com", ftp: :ended)
    client = client!
    ws = workstream!(client, rate: 200)
    pt = tracker!([ws])
    role = runn_role!(200)
    assign!(runn_person!(v.email), pt, role)
    assign!(runn_person!(x.email), pt, role)
    r = build
    assert_in_delta 5600.0, amount_for(r, v, kind: :individual_contributor), 0.01     # 8000 * 0.70 (no leads)
    assert_in_delta 5600.0, amount_for(r, x, kind: :individual_contributor), 0.01
  end

  test "open-ended lead period with nil started_at resolves in a future month; an ended one does not" do
    @ic = person!("ic-#{@seq}@example.com")
    open_lead = person!("open-#{@seq}@example.com", admin: true)
    ended_lead = person!("ended-#{@seq}@example.com", admin: true)
    @client = client!
    @ws = workstream!(@client, rate: 200)
    @pt = tracker!([@ws])
    # period_started_at falls back to the tracker's first recorded assignment
    # (read from the snapshot) when started_at is nil — pin it so the test
    # does not depend on the real calendar date.
    @pt.update_column(:snapshot, { "first_forecast_assignment_start_date" => "2026-01-05" })
    lead!(AccountLeadPeriod, @pt, open_lead.admin_user, started_at: nil, ended_at: nil)
    lead!(ProjectLeadPeriod, @pt, ended_lead.admin_user, started_at: Date.new(2026, 1, 1), ended_at: Date.new(2026, 8, 31))
    assign!(runn_person!(@ic.email), @pt, runn_role!(200), start_date: Date.new(2026, 10, 5), end_date: Date.new(2026, 10, 9))
    r = build
    assert_in_delta 640.0, amount_for(r, open_lead, kind: :account_lead, month: OCT), 0.01
    assert_empty lines_for(r, ended_lead, month: OCT)
    assert_in_delta 4960.0, amount_for(r, @ic, kind: :individual_contributor, month: OCT), 0.01  # no PL → 62%
  end

  # --- resolve --------------------------------------------------------

  test "two assignments for one person on one workstream in one month are priced once" do
    standard_setup(model: "new_deal_v2", notes: "ic-#{@seq}@example.com:80.005p/h")
    assign!(@rp_ic, @pt, @role, start_date: Date.new(2026, 9, 14), end_date: Date.new(2026, 9, 18))
    r = build
    ic_lines = lines_for(r, @ic, kind: :individual_contributor)
    assert_equal 1, ic_lines.size
    assert_equal 80.0, ic_lines.first.hours
    assert_in_delta 6400.4, ic_lines.first.amount, 0.001   # 80 * 80.005 rounded once
    assert_equal 1, lines_for(r, @al, kind: :account_lead_surplus).size
  end

  test "hours split across months, weekends excluded, non-working-day counts every day" do
    standard_setup
    RunnAssignment.delete_all
    assign!(@rp_ic, @pt, @role, start_date: Date.new(2026, 9, 28), end_date: Date.new(2026, 10, 2))   # Mon–Fri across the boundary
    assign!(@rp_ic, @pt, @role, start_date: Date.new(2026, 9, 12), end_date: Date.new(2026, 9, 13), minutes: 60, non_working_day: true)  # Sat–Sun
    r = build
    assert_equal 26.0, lines_for(r, @ic, kind: :individual_contributor).first.hours          # 3 days * 8h + 2 days * 1h
    assert_equal 16.0, lines_for(r, @ic, kind: :individual_contributor, month: OCT).first.hours
  end

  test "assignments beyond the horizon are clipped and past months are never emitted" do
    standard_setup
    RunnAssignment.delete_all
    assign!(@rp_ic, @pt, @role, start_date: Date.new(2026, 8, 24), end_date: Date.new(2027, 1, 8))
    r = build
    assert_equal horizon.month_keys.sort, lines_for(r, @ic, kind: :individual_contributor, month: nil).map(&:month).sort.uniq
  end

  test "tentative Runn projects flag their lines" do
    @ic = person!("ic-#{@seq}@example.com")
    client = client!
    ws = workstream!(client, rate: 200)
    pt = tracker!([ws], confirmed: false)
    assign!(runn_person!(@ic.email), pt, runn_role!(200))
    r = build
    assert lines_for(r, @ic, kind: :individual_contributor).first.tentative
    assert_in_delta 5600.0, r.totals_by_month[SEP][:tentative_amount], 0.01
  end

  test "role rate matching no workstream falls back to the first unarchived workstream and flags rate_mismatch" do
    @ic = person!("ic-#{@seq}@example.com")
    client = client!
    archived = workstream!(client, rate: 150, archived: true)
    live = workstream!(client, rate: 225)
    pt = tracker!([archived, live])
    assign!(runn_person!(@ic.email), pt, runn_role!(999))
    r = build
    ic = lines_for(r, @ic, kind: :individual_contributor).first
    assert ic.rate_mismatch
    assert_equal 225.0, ic.rate
    assert_in_delta 40 * 225 * 0.70, ic.amount, 0.01
    assert_equal 1, r.skipped[:role_rate_mismatch]
  end

  test "role rate selects the matching workstream on a multi-rate tracker" do
    @ic = person!("ic-#{@seq}@example.com")
    client = client!
    ws150 = workstream!(client, rate: 150)
    ws225 = workstream!(client, rate: 225, notes: "#{@ic.email}:100p/h")   # @seq has moved on since person!; use the real email
    pt = tracker!([ws150, ws225])
    assign!(runn_person!(@ic.email), pt, runn_role!(225))
    r = build
    ic = lines_for(r, @ic, kind: :individual_contributor).first
    assert_not ic.rate_mismatch
    assert_equal 100.0, ic.rate, "override read from the matched workstream"
    assert_in_delta 4000.0, ic.amount, 0.01
  end

  test "unmapped person, placeholder, unmapped project, non-billable, archived project, no workstream are skipped" do
    client = client!
    ws = workstream!(client, rate: 200)
    pt = tracker!([ws])
    role = runn_role!(200)
    stranger = runn_person!("stranger-#{@seq}@example.com")
    assign!(stranger, pt, role)                                             # unmapped_person
    ic = person!("ic-#{@seq}@example.com")
    rp_ic = runn_person!(ic.email)
    assign!(rp_ic, pt, role, placeholder: true)                             # unmapped_person (placeholder)
    assign!(rp_ic, pt, role, billable: false)                               # non_billable
    orphan_rp = RunnProject.create!(runn_id: nid, name: "Orphan", is_confirmed: true, is_archived: false, is_template: false)
    RunnAssignment.create!(runn_id: nid, person_id: rp_ic.runn_id, project_id: orphan_rp.runn_id, role_id: role.runn_id,
                           start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 11), minutes_per_day: 480)   # unmapped_project
    archived_pt = tracker!([workstream!(client, rate: 200)], archived: true)  # own workstream: a workstream may link to one tracker only
    assign!(rp_ic, archived_pt, role)                                       # silent
    bare_pt = tracker!([])
    assign!(rp_ic, bare_pt, role)                                           # no_forecast_project

    r = build
    assert_empty r.lines
    assert_equal 2, r.skipped[:unmapped_person]
    assert_equal 1, r.skipped[:non_billable]
    assert_equal 1, r.skipped[:unmapped_project]
    assert_equal 1, r.skipped[:no_forecast_project]
    assert_nil r.skipped[:archived]
    assert_includes r.skipped_details[:unmapped_project], "Orphan"
  end

  test "a workstream linked to two trackers is skipped as ambiguous_tracker" do
    ic = person!("ic-#{@seq}@example.com")
    client = client!
    ws = workstream!(client, rate: 200)
    pt = tracker!([ws])
    other = ProjectTracker.new(name: "Other #{@seq}"); other.save!(validate: false)
    ProjectTrackerForecastProject.new(project_tracker: other, forecast_project: ws).save!(validate: false)
    assign!(runn_person!(ic.email), pt, runn_role!(200))
    r = build
    assert_empty r.lines
    assert_equal 1, r.skipped[:ambiguous_tracker]
  end

  test "missing ledger is counted and the line dropped" do
    standard_setup
    Ledger.where(enterprise: @sanctuary, contributor: @ic.contributor).delete_all
    r = build
    assert_empty lines_for(r, @ic)
    assert_equal 1, r.skipped[:no_ledger]
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01, "other payees unaffected"
  end

  # --- recurring adjustments ---------------------------------------------

  test "recurring ledger adjustments are projected by cadence inside the horizon" do
    ic = person!("rla-#{@seq}@example.com")
    ledger = Ledger.find_by!(enterprise: @sanctuary, contributor: ic.contributor)
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 25, description: "Monthly stipend", cadence: "monthly", next_due_on: Date.new(2026, 9, 15))
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 10, description: "Twice", cadence: "twice_monthly", next_due_on: Date.new(2026, 8, 15))
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 100, description: "Quarterly", cadence: "quarterly", next_due_on: Date.new(2026, 10, 1))
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 999, description: "Paused", cadence: "monthly", next_due_on: Date.new(2026, 9, 1), paused_at: Time.current)
    r = build
    by = r.by_contributor_month(ic.contributor)
    assert_in_delta 25 + 20, by[SEP][:amount], 0.01          # monthly + two twice_monthly (Sep 1, Sep 15); Aug 15 is before the horizon
    assert_in_delta 25 + 20 + 100, by[OCT][:amount], 0.01
    assert_in_delta 25 + 20, by[Date.new(2026, 11, 1)][:amount], 0.01
    assert_in_delta 25 + 20, by[Date.new(2026, 12, 1)][:amount], 0.01
    assert_equal :recurring_adjustment, by[SEP][:lines].first.kind
  end

  # --- filtering and caching ------------------------------------------------

  test "contributor: keeps only that contributor's lines, including lead lines earned from others' hours" do
    standard_setup
    r = build(contributor: @al.contributor)
    assert_equal [@al.contributor.id], r.lines.map(&:contributor_id).uniq
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01
  end

  test "as_of comes from System and cached_all memoizes per sync stamp" do
    standard_setup
    s = System.first || System.create!(settings: {})
    s.update!(runn_synced_at: DateTime.new(2026, 9, 8, 2))
    assert_equal DateTime.new(2026, 9, 8, 2).to_i, build.as_of.to_i
    # memory_store marshals entries; a Result must survive that (no default-proc hashes, no AR objects)
    assert_nothing_raised { ActiveSupport::Cache::MemoryStore.new.write("probe", build) }

    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    ContributorProjections::Build.expects(:call).once.returns(:first)
    assert_equal :first, ContributorProjections::Build.cached_all(horizon: horizon)
    assert_equal :first, ContributorProjections::Build.cached_all(horizon: horizon)
    System.first.update!(runn_synced_at: DateTime.new(2026, 9, 9, 2))
    ContributorProjections::Build.expects(:call).once.returns(:second)
    assert_equal :second, ContributorProjections::Build.cached_all(horizon: horizon)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/contributor_projections/build_test.rb`
Expected: FAIL with `NameError: uninitialized constant ContributorProjections::Build`.

- [ ] **Step 3: Write `Build`**

```ruby
# app/services/contributor_projections/build.rb
module ContributorProjections
  # Prices the forward plan in the local Runn mirror into projected ledger
  # lines, per (contributor, tracker, workstream, month), with the same
  # rules InvoiceTracker#make_contributor_payouts! and PayCycles::GenerateStubs
  # apply. Pure: no writes, no HTTP. Data problems never raise — they land
  # in Result#skipped with a reason.
  class Build
    Key = Struct.new(:contributor, :tracker, :forecast_project, :month)

    def self.call(horizon: Horizon.current, contributor: nil)
      new(horizon: horizon, contributor: contributor).call
    end

    # Payables page only. Keyed on today + the sync stamp so a fresh mirror
    # busts it; 1h TTL bounds staleness inside a day.
    def self.cached_all(horizon: Horizon.current)
      key = ["contributor_projections", Date.today, ContributorProjections.runn_synced_at&.to_i]
      Rails.cache.fetch(key, expires_in: 1.hour) { call(horizon: horizon) }
    end

    def initialize(horizon:, contributor: nil)
      @horizon = horizon
      @only_contributor_id = contributor&.id
      @lines = []
      @skipped = Hash.new { |h, k| h[k] = [] }
    end

    def call
      load!
      hours_by_key, flags_by_key = resolve
      hours_by_key.each do |key, hours|
        price_key(key, hours, **flags_by_key[key])
      end
      project_recurring_adjustments
      lines = @only_contributor_id ? @lines.select { |l| l.contributor_id == @only_contributor_id } : @lines
      Result.new(
        horizon: @horizon,
        lines: lines,
        skipped: @skipped.transform_values(&:size),
        # Hash[] drops the default proc; a Hash with one cannot be Marshal'd,
        # and memory_store marshals every entry (cached_all would silently
        # fail forever).
        skipped_details: Hash[@skipped],
        as_of: ContributorProjections.runn_synced_at,
      )
    end

    private

    # ------------------------------------------------------------------ load

    def load!
      @assignments = RunnAssignment.plannable
        .overlapping(@horizon.starts_at, @horizon.ends_at)
        .includes(:runn_project, :runn_role, :runn_person)
        .to_a

      project_ids = @assignments.map(&:project_id).compact.uniq
      @trackers_by_runn_id = ProjectTracker
        .where(runn_project_id: project_ids)
        .includes(
          forecast_projects: { forecast_client: :enterprise },
          account_lead_periods: { admin_user: :full_time_periods },
          project_lead_periods: { admin_user: :full_time_periods },
          commissions: { contributor: { forecast_person: { admin_user: :full_time_periods } } },
        )
        .index_by(&:runn_project_id)

      # Two Forecast people can share an email; prefer the one with an
      # AdminUser, then the unarchived one (matches recent_actuals' tie-break).
      @contributors_by_email = {}
      Contributor.includes(forecast_person: { admin_user: :full_time_periods }).each do |c|
        fp = c.forecast_person
        next if fp.nil?
        email = fp.email.to_s.strip.downcase
        next if email.blank?
        existing = @contributors_by_email[email]
        @contributors_by_email[email] = c if existing.nil? || better_match?(c, existing)
      end

      @ledgers = Ledger.includes(:enterprise).index_by { |l| [l.enterprise_id, l.contributor_id] }
      @adjustments = RecurringLedgerAdjustment.active.includes(:ledger).to_a
      @tracker_count_by_workstream = ProjectTrackerForecastProject.group(:forecast_project_id).count
    end

    def better_match?(candidate, existing)
      c_admin = candidate.forecast_person.admin_user.present?
      e_admin = existing.forecast_person.admin_user.present?
      return c_admin if c_admin != e_admin
      !candidate.forecast_person.archived && existing.forecast_person.archived == true
    end

    # --------------------------------------------------------------- resolve

    # Sum hours into (contributor, tracker, workstream, month) keys. The real
    # builder prices one invoice line per (person, workstream) with the month's
    # summed hours and rounds once; pricing per assignment would round twice.
    def resolve
      hours_by_key = Hash.new(0.0)
      flags_by_key = Hash.new { |h, k| h[k] = { tentative: false, rate_mismatch: false } }

      @assignments.each do |a|
        if a.is_placeholder
          skip!(:unmapped_person, "placeholder assignment #{a.runn_id}")
          next
        end
        contributor = @contributors_by_email[a.runn_person&.email.to_s.strip.downcase]
        if contributor.nil?
          skip!(:unmapped_person, a.runn_person&.email.presence || "runn person #{a.person_id}")
          next
        end

        rp = a.runn_project
        next if rp.nil? || rp.is_archived || rp.is_template

        tracker = @trackers_by_runn_id[a.project_id]
        if tracker.nil?
          skip!(:unmapped_project, rp.name)
          next
        end
        unless a.is_billable
          skip!(:non_billable, "#{rp.name} / #{contributor.display_name}")
          next
        end

        workstream, mismatch = workstream_for(tracker, a)
        if workstream.nil?
          skip!(:no_forecast_project, tracker.name)
          next
        end
        if @tracker_count_by_workstream[workstream.forecast_id].to_i > 1
          skip!(:ambiguous_tracker, workstream.name)
          next
        end

        @horizon.months.each do |month|
          hours = a.hours_between(month.starts_at, month.ends_at)
          next if hours <= 0
          key = Key.new(contributor, tracker, workstream, month.starts_at)
          hours_by_key[key] += hours
          flags_by_key[key][:tentative] ||= (rp.is_confirmed == false)
          flags_by_key[key][:rate_mismatch] ||= mismatch
        end
      end

      [hours_by_key, flags_by_key]
    end

    # The Runn role's standard_rate is only a selector: pick the workstream
    # whose p/h tag equals it. It is never used as a price.
    def workstream_for(tracker, assignment)
      workstreams = tracker.forecast_projects.to_a
      return [nil, false] if workstreams.empty?

      rate = assignment.runn_role&.standard_rate
      match = rate.nil? ? nil : workstreams.find { |ws| ws.hourly_rate.to_f == rate.to_f }
      return [match, false] if match

      skip!(:role_rate_mismatch, "#{tracker.name}: Runn role rate #{rate.inspect} matches no workstream")
      [workstreams.find { |ws| !ws.archived } || workstreams.first, true]
    end

    # ----------------------------------------------------------------- price

    def price_key(key, hours, tentative:, rate_mismatch:)
      ws = key.forecast_project
      client = ws.forecast_client
      if client.nil?
        skip!(:no_forecast_project, ws.name)
        return
      end

      email = key.contributor.forecast_person.email
      override = ws.hourly_rate_override_for_email_address(email)
      bill_rate = ws.hourly_rate.to_f
      month_end = key.month.end_of_month
      base = {
        project_tracker_id: key.tracker.id, project_tracker_name: key.tracker.name,
        month: key.month, tentative: tentative, rate_mismatch: rate_mismatch,
      }

      if client.is_internal?
        price_internal(key, hours, ws, client, override, bill_rate, month_end, base)
      else
        price_external(key, hours, ws, client, override, bill_rate, month_end, base)
      end
    end

    # Mirrors PayCycles::GenerateStubs: hours × (override || tag rate), no
    # splits, no commissions; a workstream with neither an explicit tag nor
    # an override is what GenerateStubs raises MissingRateError on.
    def price_internal(key, hours, ws, client, override, bill_rate, month_end, base)
      if override.nil? && ws.has_no_explicit_hourly_rate?
        skip!(:no_explicit_rate, "#{ws.name} / #{key.contributor.display_name}")
        return
      end
      rate = override.nil? ? bill_rate : override.to_f
      amount = (hours * rate).round(2)
      emit(key.contributor, client.enterprise, month_end, base.merge(
        kind: :pay_stub, hours: hours, rate: rate, amount: amount,
        description: "- #{fmt(hours)} hrs * #{n2c(rate)} p/h = #{n2c(amount)}",
      ))
    end

    # Mirrors InvoiceTracker#make_contributor_payouts!: commissions off the
    # top, AL and PL shares, IC remainder (or override), surplus to the leads.
    def price_external(key, hours, ws, client, override, bill_rate, month_end, base)
      tracker = key.tracker
      enterprise = client.billing_enterprise
      rules = tracker.billing_rules

      working_amount = hours * bill_rate
      commission_total = 0.0
      tracker.commissions.each do |commission|
        deduction =
          case commission
          when PerHourCommission then (hours * commission.rate.to_f).round(2)
          when PercentageCommission then (working_amount * commission.rate.to_f).round(2)
          else 0.0
          end
        next if deduction <= 0
        commission_total += deduction
        label = commission.is_a?(PerHourCommission) ? "#{n2c(commission.rate)} p/h commission" : "#{pct(commission.rate)} commission"
        emit(commission.contributor, enterprise, month_end, base.merge(
          kind: :commission, hours: hours, rate: commission.rate.to_f, amount: deduction,
          description: "- #{fmt(hours)} hrs * #{n2c(bill_rate)} p/h * #{label} = #{n2c(deduction)}",
        ))
      end
      working_amount -= commission_total

      # The real builder resolves each lead to a ForecastPerson and treats the
      # lead as present only then (invoice_tracker.rb:444/465): a lead with no
      # Forecast identity neither gets a line nor reduces the IC share.
      account_lead = lead_for_month(tracker.account_lead_periods, key.month)
      project_lead = lead_for_month(tracker.project_lead_periods, key.month)
      al_contributor = account_lead && contributor_for_admin(account_lead)
      pl_contributor = project_lead && contributor_for_admin(project_lead)
      hours_x_rate = "#{fmt(hours)} hrs * #{n2c(bill_rate)} p/h"
      basis = commission_total > 0 ? "(#{hours_x_rate}) - #{n2c(commission_total)} commission = #{n2c(working_amount)}" : hours_x_rate

      if al_contributor
        amount = (working_amount * rules.account_lead_share).round(2).to_f
        emit(al_contributor, enterprise, month_end, base.merge(
          kind: :account_lead, hours: hours, rate: bill_rate, amount: amount,
          description: "- #{basis} * #{pct(rules.account_lead_share)} = #{n2c(amount)}",
        ))
      end
      if pl_contributor
        amount = (working_amount * rules.project_lead_share).round(2).to_f
        emit(pl_contributor, enterprise, month_end, base.merge(
          kind: :project_lead, hours: hours, rate: bill_rate, amount: amount,
          description: "- #{basis} * #{pct(rules.project_lead_share)} = #{n2c(amount)}",
        ))
      end

      if override.nil?
        share = rules.ic_share(account_lead: al_contributor.present?, project_lead: pl_contributor.present?)
        ic_amount = (working_amount * share).round(2).to_f
        ic_rate = bill_rate
        ic_description = "- #{basis} * #{pct(share)} = #{n2c(ic_amount)}"
      else
        ic_amount = (hours * override.to_f).round(2)
        ic_rate = override.to_f
        ic_description = "- #{fmt(hours)} hrs * #{n2c(override)} p/h = #{n2c(ic_amount)}"
      end
      emit(key.contributor, enterprise, month_end, base.merge(
        kind: :individual_contributor, hours: hours, rate: ic_rate, amount: ic_amount, description: ic_description,
      ))

      # The real builder only computes surplus from persisted IC entries, and
      # a zero IC amount never persists — so no surplus when the IC line is 0.
      return unless ic_amount > 0 && working_amount > 0
      margin = (working_amount - ic_amount) / working_amount
      surplus = ((margin - rules.surplus_threshold) * working_amount).round(2).to_f
      return unless surplus > 0
      lead_share = (surplus * rules.surplus_lead_share).round(2).to_f
      surplus_description = "- #{n2c(surplus)} surplus * #{pct(rules.surplus_lead_share)} = #{n2c(lead_share)}"
      if al_contributor
        emit(al_contributor, enterprise, month_end, base.merge(
          kind: :account_lead_surplus, hours: nil, rate: nil, amount: lead_share, description: surplus_description,
        ))
      end
      if pl_contributor
        emit(pl_contributor, enterprise, month_end, base.merge(
          kind: :project_lead_surplus, hours: nil, rate: nil, amount: lead_share, description: surplus_description,
        ))
      end
    end

    # A lead period with no explicit end is treated as continuing. The
    # models' period_started_at falls back to the tracker's first recorded
    # assignment when started_at is nil (most rows in production).
    def lead_for_month(periods, month_start)
      month_end = month_start.end_of_month
      periods.find { |p| p.period_started_at <= month_end && (p.ended_at.nil? || p.ended_at >= month_start) }&.admin_user
    end

    def contributor_for_admin(admin_user)
      @contributors_by_email[admin_user.email.to_s.strip.downcase]
    end

    # Same test as InvoiceTracker#make_contributor_payouts! (:532) and
    # PayCycles::GenerateStubs#salaried_skip?: only a covering full-time
    # period that is NOT variable_hours excludes a payee.
    def paid_on_ledger?(admin_user, date)
      return true if admin_user.nil?
      ftp = admin_user.full_time_period_at(date)
      ftp.nil? || ftp.variable_hours?
    end

    def emit(contributor, enterprise, month_end, attrs)
      return if contributor.nil? || enterprise.nil?
      return if attrs[:amount].to_f == 0
      return unless paid_on_ledger?(contributor.forecast_person&.admin_user, month_end)

      ledger = @ledgers[[enterprise.id, contributor.id]]
      if ledger.nil?
        skip!(:no_ledger, "#{contributor.display_name} / #{enterprise.name}")
        return
      end
      @lines << Line.new(attrs.merge(ledger_id: ledger.id, enterprise_id: enterprise.id, contributor_id: contributor.id))
    end

    # ------------------------------------------------- recurring adjustments

    def project_recurring_adjustments
      @adjustments.each do |rla|
        due = rla.next_due_on
        while due <= @horizon.ends_at
          if due >= @horizon.starts_at
            @lines << Line.new(
              kind: :recurring_adjustment,
              ledger_id: rla.ledger_id, enterprise_id: rla.ledger.enterprise_id, contributor_id: rla.ledger.contributor_id,
              project_tracker_id: nil, project_tracker_name: rla.description,
              hours: nil, rate: nil, amount: rla.amount.to_f.round(2),
              description: "- #{rla.description} (#{rla.cadence.humanize.downcase}, due #{due.strftime('%b %-d')})",
              tentative: false, rate_mismatch: false, month: due.beginning_of_month,
            )
          end
          due = rla.advance(due)
        end
      end
    end

    # --------------------------------------------------------------- helpers

    def skip!(reason, detail)
      @skipped[reason] << detail.to_s
    end

    # Float#to_s gives "40.0" / "12.5" / "26.25" — the same shape the payout
    # builder's description lines use.
    def fmt(hours)
      hours.to_f.round(2).to_s
    end

    def pct(share)
      "#{(share.to_f * 100).round(2)}%"
    end

    def n2c(*args)
      ActionController::Base.helpers.number_to_currency(*args)
    end
  end
end
```

- [ ] **Step 4: Run tests until green**

Run: `bin/rails test test/services/contributor_projections/build_test.rb`
Expected: `22 runs, 0 failures, 0 errors`. Likely first-run failures and their fixes:
- If `ProjectTracker#commissions` includes soft-deleted rows, add `.where(deleted_at: nil)` — it should not (`acts_as_paranoid` default scope).
- If `ForecastPerson#archived` is nil on new rows, `better_match?` already treats nil as unarchived.

- [ ] **Step 5: Live smoke against the dev database**

If `bin/rails runner 'puts RunnAssignment.count'` prints `0`, populate the mirror first with `bin/rails runner 'Stacks::Runn.new(max_retries: 0).sync_all!'` (read-only against Runn, writes only the local dev DB).

Run: `bin/rails runner 'r = ContributorProjections::Build.call; puts r.lines.size; puts r.skipped.inspect; t = r.totals_by_month; t.each { |m, s| puts "#{m}: #{s[:amount]} (tentative #{s[:tentative_amount]})" }; puts r.by_contributor_totals.size'`
Expected: a few hundred lines, a skipped hash with small counts (unmapped_project ≈ 3, unmapped_person ≈ 1), four month totals in the tens of thousands of dollars descending toward December, and roughly 30–40 contributors. If a `NoMethodError` or `nil` comparison surfaces here that the tests did not catch, it is production data shape; add a guard and a test reproducing it.

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/services/contributor_projections/build.rb test/services/contributor_projections/build_test.rb
git commit -m "feat: ContributorProjections::Build prices the Runn forward plan per ledger and month

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 4: `min_ends_at:` floor on the two grouping methods

**Files:**
- Modify: `app/models/contributor.rb` (`all_items_grouped_by_month`, ~:377-415)
- Modify: `app/models/ledger.rb` (`items_grouped_by_month`, ~:128-138)
- Test: `test/models/ledger_test.rb` (append to `LedgerTest`), `test/models/contributor_test.rb` (append)

**Interfaces:**
- Produces: `Contributor#all_items_grouped_by_month(include_salary = true, override_ledger_starts_at = nil, override_ledger_ends_at = nil, min_ends_at: nil)` and `Ledger#items_grouped_by_month(override_starts_at = nil, override_ends_at = nil, min_ends_at: nil)`. `min_ends_at` is a floor applied after the default/override logic; the positional override keeps its replace semantics (PeriodicReport passes it as a cap).

- [ ] **Step 1: Write the failing tests**

Append inside `class LedgerTest` in `test/models/ledger_test.rb` (before its closing `end`):

```ruby
  test "items_grouped_by_month min_ends_at extends the range but never shortens it" do
    @ledger = Ledger.find_by!(enterprise: @enterprise, contributor: @contributor)   # LedgerTest's setup defines only @enterprise/@contributor
    far = Date.today + 8.months
    months = @ledger.items_grouped_by_month(min_ends_at: far)[:by_month].keys
    assert_equal far.beginning_of_month >> -1, months.first.starts_at, "for_gradation stops one month before `through`, so +1 month lands on the floor"
    default_months = @ledger.items_grouped_by_month[:by_month].keys
    floored_low = @ledger.items_grouped_by_month(min_ends_at: Date.today - 12.months)[:by_month].keys
    assert_equal default_months.map(&:starts_at), floored_low.map(&:starts_at)
  end
```

Append a new test class at the end of `test/models/contributor_test.rb`:

```ruby
class ContributorGroupingFloorTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    fp = ForecastPerson.create!(forecast_id: 995_001, email: "floor@example.com", data: {})
    @contributor = fp.contributor
  end

  test "all_items_grouped_by_month min_ends_at extends the range" do
    far = Date.today + 8.months
    months = @contributor.all_items_grouped_by_month(min_ends_at: far)[:by_month].keys
    assert_equal (far.beginning_of_month >> -1), months.first.starts_at
  end

  test "all_items_grouped_by_month positional override still caps the range" do
    cap = Date.today.beginning_of_month + 1.day
    months = @contributor.all_items_grouped_by_month(false, nil, cap)[:by_month].keys
    assert months.first.starts_at < Date.today.beginning_of_month
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/ledger_test.rb test/models/contributor_test.rb`
Expected: the new tests error with a `NoMethodError` from inside `Stacks::Period.for_gradation` (both methods take only optional positionals today, so `min_ends_at:` is swallowed as a positional Hash rather than rejected as an unknown keyword).

- [ ] **Step 3: Add the floor**

In `app/models/contributor.rb` change the signature line
`def all_items_grouped_by_month(include_salary = true, override_ledger_starts_at = nil, override_ledger_ends_at = nil)`
to
`def all_items_grouped_by_month(include_salary = true, override_ledger_starts_at = nil, override_ledger_ends_at = nil, min_ends_at: nil)`

and directly after the `end` that closes the `if override_ledger_ends_at.present? ... else ... end + 2.months` block (the line ending `end + 2.months` followed by `end`), insert:

```ruby
    # A floor, not a replacement: the contributor page needs the projection
    # horizon rendered even when no real item is dated that far out, while
    # PeriodicReport keeps passing the positional override as a cap.
    ledger_ends_at = [ledger_ends_at.to_date, min_ends_at.to_date].max if min_ends_at.present?
```

In `app/models/ledger.rb` change
`def items_grouped_by_month(override_starts_at = nil, override_ends_at = nil)`
to
`def items_grouped_by_month(override_starts_at = nil, override_ends_at = nil, min_ends_at: nil)`
and after the `ledger_ends_at = if ... end` expression insert:

```ruby
    ledger_ends_at = [ledger_ends_at.to_date, min_ends_at.to_date].max if min_ends_at.present?
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/models/ledger_test.rb test/models/contributor_test.rb test/models/periodic_report_test.rb`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/models/contributor.rb app/models/ledger.rb test/models/ledger_test.rb test/models/contributor_test.rb
git commit -m "feat: min_ends_at floor on the ledger month grouping methods

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 5: Contributor page

**Files:**
- Modify: `app/admin/contributors.rb` (`show do` block, ~:257-309)
- Modify: `app/views/admin/contributors/_show.html.erb` (balance table ~:18-37; month header pill ~:46-55; items table ~:80-297)
- Modify: `app/assets/stylesheets/active_admin.scss` (after the `&.pay_stub { ... }` block inside `.pill, .status_tag`, ~:1049-1053)

**Interfaces:**
- Consumes: `ContributorProjections::Build.call(contributor:)`, `Result#by_contributor_month`, `#horizon`, `#as_of`, `ContributorProjections.stale?`, `Contributor#all_items_grouped_by_month(min_ends_at:)`, `Ledger#items_grouped_by_month(min_ends_at:)`.
- Produces: new partial locals `projected_by_month:` (`{ Date => summary }`) and `projection_as_of:` (`DateTime|nil`), `projection_months:` (Integer).

- [ ] **Step 1: Controller changes**

In `app/admin/contributors.rb`, inside `show do`, replace

```ruby
    items_result =
      if view_mode == :all
        resource.all_items_grouped_by_month
      else
        current_ledger.items_grouped_by_month
      end
```
with
```ruby
    # Projected earnings from the Runn mirror. A failure here must not take
    # the ledger down with it — render the real items and an empty projection.
    projection =
      begin
        ContributorProjections::Build.call(contributor: resource)
      rescue => e
        Rails.logger.error("[admin contributors] projection failed for contributor ##{resource.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end
    horizon = projection&.horizon || ContributorProjections::Horizon.current
    # for_gradation stops one month short of `through`, hence + 1.month.
    floor = horizon.ends_at + 1.month

    items_result =
      if view_mode == :all
        resource.all_items_grouped_by_month(min_ends_at: floor)
      else
        current_ledger.items_grouped_by_month(min_ends_at: floor)
      end

    projected_by_month =
      if projection.nil?
        {}
      elsif view_mode == :ledger && current_ledger
        projection.by_contributor_month(resource, ledger: current_ledger)
      else
        projection.by_contributor_month(resource)
      end
```

and add three locals to the `render(partial: "show", locals: { ... })` call:

```ruby
      projected_by_month: projected_by_month,
      projection_as_of: projection&.as_of,
      projection_months: horizon.months.size,
```

- [ ] **Step 2: Balance table row**

In `_show.html.erb`, inside the Balance/Unsettled `<table>` after the `Unsettled` `<tr class="odd">...</tr>`, add:

```erb
    <% projected_total = projected_by_month.values.sum { |m| m[:amount] } %>
    <tr class="even">
      <td class="col">
        <strong>Projected</strong> <span style="opacity: 0.6;">(next <%= projection_months %> months)</span>
      </td>
      <td class="col text-right">
        <%= number_to_currency(projected_total) %>
        <% if ContributorProjections.stale?(projection_as_of) %>
          <span class="pill at_risk" style="margin-left: 6px;">Runn sync stale</span>
        <% else %>
          <span style="opacity: 0.6;">as of <%= time_ago_in_words(projection_as_of) %> ago</span>
        <% end %>
      </td>
    </tr>
```

- [ ] **Step 3: Month header pill**

Directly inside the `new_deal_ledger_items[:by_month].each do |period, metadata|` loop, before `<div class="title_bar" ...>`, add:

```erb
  <% projected = projected_by_month[period.starts_at] %>
  <%# by_contributor_month returns a summary for EVERY horizon month, so test for lines, not presence %>
  <% projected_month = projected.present? && projected[:lines].any? && period.starts_at >= Date.today.beginning_of_month %>
```

Then in the `view_mode == :all` header pill, replace

```erb
              <strong><%= metadata[:total_hours] %>hrs, </strong><span><%= number_to_currency(metadata[:total_income]) %><%= metadata[:partial_salary] > 0 ? " + #{number_to_currency(metadata[:partial_salary])} partial salary" : "" %></span>
```
with
```erb
              <strong><%= projected_month ? projected[:hours] : metadata[:total_hours] %>hrs, </strong><span><%= number_to_currency(metadata[:total_income]) %><%= metadata[:partial_salary] > 0 ? " + #{number_to_currency(metadata[:partial_salary])} partial salary" : "" %></span>
              <% if projected_month && projected[:amount] != 0 %>
                <span> · projected <%= number_to_currency(projected[:amount]) %></span>
              <% end %>
```

- [ ] **Step 4: Projected rows**

Inside the items `<tbody>`, directly after the `<% end %>` that closes `metadata[:items].each_with_index do |li, index|`, add:

```erb
        <% if projected_month %>
          <% projected[:lines].each_with_index do |line, pindex| %>
            <tr class="<%= (metadata[:items].size + pindex).even? ? "even" : "odd" %>" style="font-style: italic; opacity: 0.85;">
              <td class="col"><%= period.starts_at.strftime("%B %Y") %></td>
              <td class="col">
                <span class="pill projected">Projected</span>
                <% if line.tentative %>
                  <span class="pill tentative" style="margin-left: 4px;">Tentative</span>
                <% end %>
                <% if line.rate_mismatch %>
                  <span class="pill at_risk" style="margin-left: 4px;" title="The Runn role's rate matched no workstream on this tracker; priced at the first workstream's rate.">Rate?</span>
                <% end %>
              </td>
              <td class="col">
                <% if line.project_tracker_id %>
                  <%= link_to "#{line.project_tracker_name} ↗", admin_project_tracker_path(line.project_tracker_id) %>
                <% else %>
                  <%= line.project_tracker_name %>
                <% end %>
                <span style="opacity: 0.6;"><%= line.kind.to_s.humanize %></span>
              </td>
              <td class="col">
                <%= line.amount.negative? ? "-" : "+" %> <%= number_to_currency(line.amount.abs) %>
              </td>
              <td class="col text-right"><code style="font-style: normal;"><%= line.description %></code></td>
            </tr>
          <% end %>
        <% end %>
```

Also: the `<% if view_mode == :all && metadata[:fulltime] %>` branch renders an FYI box instead of the table for fully salaried months; projections for such a person are never emitted, so no change is needed there.

- [ ] **Step 5: Pill styles**

In `app/assets/stylesheets/active_admin.scss`, directly after the block

```scss
  &.pay_stub
  {
    background-color: $color-blue;
    color: white;
  }
```
add
```scss
  &.projected
  {
    background-color: #e8eefc;
    color: #2b4a9b;
  }
  &.tentative
  {
    background-color: #f4ecd8;
    color: #7a5a12;
  }
```

- [ ] **Step 6: Smoke in the dev server**

Run `bin/rails s` and open `/admin/contributors/<id>` for a contributor with forward Runn assignments (find one with
`bin/rails runner 'r = ContributorProjections::Build.call; puts r.by_contributor_totals.keys.first(5).inspect'`), on both the All tab and an enterprise tab. Confirm: the Projected row in the balance table, the header pill's `· projected $…`, italic projected rows under the current and next three months, the tracker link works, and a contributor with no projections shows `$0.00` and no rows. Check `bin/rails runner 'puts Rails.application.assets["active_admin.css"].to_s.include?(".pill.projected")'` prints `true`.

- [ ] **Step 7: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/admin/contributors.rb app/views/admin/contributors/_show.html.erb app/assets/stylesheets/active_admin.scss
git commit -m "feat: projected earnings on the contributor ledger page

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 6: Payables page roll-up

**Files:**
- Modify: `app/admin/money.rb` (`payable_qbo_bills` page_action, after `@pending_task_counts_by_contributor`)
- Modify: `app/views/admin/money/payable_qbo_bills.html.erb` (after the summary card's closing `</table>`, before `<% if @rows.empty? %>`)

**Interfaces:**
- Consumes: `ContributorProjections::Build.cached_all`, `Result#horizon`, `#totals_by_month(enterprise_id:)`, `#by_contributor_totals(enterprise_id:)`, `#contributors`, `#skipped`, `#skipped_total`, `#stale?`, `#as_of`.
- Produces: `@projection` (`Result|nil`), `@projection_enterprise_id` (`Integer|nil`).

- [ ] **Step 1: Controller**

In `app/admin/money.rb`, after the `@pending_task_counts_by_contributor = ...` block and before `render "admin/money/payable_qbo_bills"`, add:

```ruby
    # Projected payables per month from the Runn mirror. Cached for an hour
    # per sync stamp; a failure renders a placeholder, never a 500.
    @projection =
      begin
        ContributorProjections::Build.cached_all
      rescue => e
        Rails.logger.error("[payables] projection failed: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end
    @projection_enterprise_id = @active_qa&.enterprise&.id
```

- [ ] **Step 2: View**

In `payable_qbo_bills.html.erb`, after the `</table>` that closes the summary card (the table with "Total Payable" / "Total Unsettled") and before `<% if @rows.empty? %>`, insert:

```erb
  <%# Projected payables — from the Runn forward plan, priced per ledger and
      month by ContributorProjections::Build. Scoped to the selected tab. %>
  <div style="margin: 24px 0 8px 0;">
    <h3 style="margin-bottom: 8px;">Projected Payables</h3>
    <% if @projection.nil? %>
      <p><em>Projection unavailable — see logs.</em></p>
    <% else %>
      <% totals = @projection.totals_by_month(enterprise_id: @projection_enterprise_id) %>
      <% months = @projection.horizon.months %>
      <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
        <thead>
          <tr>
            <th class="col">Month</th>
            <th class="col text-right">Confirmed</th>
            <th class="col text-right">Tentative</th>
            <th class="col text-right">Projected</th>
          </tr>
        </thead>
        <tbody>
          <% months.each_with_index do |month, i| %>
            <% t = totals[month.starts_at] %>
            <tr class="<%= i.even? ? "even" : "odd" %>">
              <td class="col"><%= month.starts_at.strftime("%B %Y") %></td>
              <td class="col text-right"><%= number_to_currency(t[:confirmed_amount]) %></td>
              <td class="col text-right" style="opacity: 0.6;"><%= t[:tentative_amount] == 0 ? "—" : number_to_currency(t[:tentative_amount]) %></td>
              <td class="col text-right"><strong><%= number_to_currency(t[:amount]) %></strong></td>
            </tr>
          <% end %>
          <tr class="<%= months.size.even? ? "even" : "odd" %>">
            <td class="col"><strong>Horizon total</strong></td>
            <td class="col text-right"><%= number_to_currency(totals.values.sum { |t| t[:confirmed_amount] }) %></td>
            <td class="col text-right" style="opacity: 0.6;"><%= number_to_currency(totals.values.sum { |t| t[:tentative_amount] }) %></td>
            <td class="col text-right"><strong><%= number_to_currency(totals.values.sum { |t| t[:amount] }) %></strong></td>
          </tr>
        </tbody>
      </table>

      <p style="margin: 8px 0 0 0; opacity: 0.7; font-size: 13px;">
        <% if @projection.stale? %>
          <span class="pill at_risk" style="margin-right: 6px;">Runn sync stale</span>
        <% end %>
        Projected from Runn as of <%= @projection.as_of ? "#{time_ago_in_words(@projection.as_of)} ago" : "never" %>
        · <%= @projection.skipped_total %> assignment<%= "s" if @projection.skipped_total != 1 %> skipped
        (<%= @projection.skipped.fetch(:unmapped_person, 0) %> unmapped people,
         <%= @projection.skipped.fetch(:unmapped_project, 0) %> unmapped projects,
         <%= @projection.skipped.fetch(:role_rate_mismatch, 0) %> rate mismatches)
      </p>

      <% by_contributor = @projection.by_contributor_totals(enterprise_id: @projection_enterprise_id) %>
      <% if by_contributor.any? %>
        <details style="margin-top: 12px;">
          <summary style="cursor: pointer;">By contributor (<%= by_contributor.size %>)</summary>
          <table border="0" cellspacing="0" cellpadding="0" class="index_table index" style="margin-top: 8px;">
            <thead>
              <tr>
                <th class="col">Contributor</th>
                <% months.each do |month| %>
                  <th class="col text-right"><%= month.starts_at.strftime("%b %Y") %></th>
                <% end %>
                <th class="col text-right">Total</th>
              </tr>
            </thead>
            <tbody>
              <% rows = by_contributor.map { |cid, by_month| [cid, by_month, by_month.values.sum { |m| m[:amount] }] }.sort_by { |_, _, total| -total } %>
              <% rows.each_with_index do |(cid, by_month, total), i| %>
                <% contributor = @projection.contributors[cid] %>
                <tr class="<%= i.even? ? "even" : "odd" %>">
                  <td class="col">
                    <% if contributor %>
                      <%= link_to "#{contributor.display_name} ↗", admin_contributor_path(contributor) %>
                    <% else %>
                      Contributor #<%= cid %>
                    <% end %>
                  </td>
                  <% months.each do |month| %>
                    <% m = by_month[month.starts_at] %>
                    <td class="col text-right">
                      <%= number_to_currency(m[:amount]) %>
                      <% if m[:tentative_amount] != 0 %>
                        <span style="opacity: 0.6; font-size: 12px;">(<%= number_to_currency(m[:tentative_amount]) %> tentative)</span>
                      <% end %>
                    </td>
                  <% end %>
                  <td class="col text-right"><strong><%= number_to_currency(total) %></strong></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </details>
      <% end %>
    <% end %>
  </div>
```

- [ ] **Step 3: Smoke in the dev server**

Open `/admin/money/payable_qbo_bills` as an admin: All tab and each enterprise tab. Confirm the card renders four months plus a total, the notice line shows an "as of" time, the By contributor table expands and its names link to contributor pages, and the enterprise tabs change the numbers. Then run `bin/rails runner 'System.first.update!(runn_synced_at: 5.days.ago)'`, reload, and confirm the `Runn sync stale` pill appears; restore with `bin/rails runner 'Stacks::Runn.new(max_retries: 0).sync_all!'`.

- [ ] **Step 4: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add app/admin/money.rb app/views/admin/money/payable_qbo_bills.html.erb
git commit -m "feat: projected payables card and by-contributor roll-up on the payables page

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KZrmMpds6LxhyLryi3YBE8"
```

---

### Task 7: Full-suite verification

- [ ] **Step 1: Run the full suite in the background**

Run: `bin/rails test 2>&1 | tail -15` (allow ~100 minutes; use a background task).
Expected: `0 failures, 0 errors` (2 pre-existing skips). Baseline before this work: 1219 runs, 0 failures, 0 errors, 2 skips.

- [ ] **Step 2: Grep for leftovers**

Run:
```bash
grep -rn "System.instance.runn_synced_at" app lib
grep -rn "0\.57\|0\.43\|\* 0\.08\|\* 0\.05\|\* 0\.15" app/models/invoice_tracker.rb app/models/contributor_payout.rb
```
Expected: no output from either.

No commit for this task.
