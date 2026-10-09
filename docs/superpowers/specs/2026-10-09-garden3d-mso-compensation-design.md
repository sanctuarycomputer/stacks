# garden3d MSO Compensation — Design

**Date:** 2026-10-09
**Status:** Approved design, revised after three adversarial reviews. One item
awaiting Paul's ratification (§8.1).
**Branch:** `worktree-garden3d-mso`

## 1. Purpose

garden3d operates an MSO whose executives are compensated from the management fee
garden3d charges the operating companies. This design covers what Stacks needs to
run that compensation monthly:

1. Per-entity invoice passes, so garden3d issues its own invoices (§5)
2. Monthly management-fee invoices and the fee-income basis (§6)
3. The MSO roster and the Top-N Sanctuary benchmark (§7)
4. Tier multipliers and the aggregate cap (§8)
5. A true-up on the garden3d ledger (§9)

## 2. Source documents

| Source | Role |
| --- | --- |
| [MSO Compensation Plan](https://app.notion.com/p/garden3d/Garden3d-MSO-Compensation-Plan-3e3131fea2c780adbabbdc8551c23b5d) | What executives agree to. Authoritative on tiers, cap %, pro rata allocation. |
| [MSO – Stacks](https://app.notion.com/p/garden3d/MSO-Stacks-3f4131fea2c7809f8ec4c4e5cdbc4334) (Paul) | Intended mechanics. Authoritative on the true-up and Top-N configurability. |
| `g3d - MSO 2026-2027 - Scenario Modeling.xlsx` | Scenario model. Confirms current-month benchmark, no smoothing. |

### 2.1 Conflicts resolved

| Topic | Sources said | Decision |
| --- | --- | --- |
| Top N | Plan: 5. Paul: configurable, 3 now → 5 in 2027 | Configurable, default **3**. Historical correctness via snapshot (§9.6), not a schedule table. |
| Cap basis | Plan/Paul/workbook: Sanctuary fee only | **55% of garden3d's management fee income from MSO payers** (§6.3). |
| Fee source | Paul: read the QBO invoice amount | **garden3d's P&L `4100 Management Fee Income`**, accrual. Invoice totals are not the fee — future invoices carry loan repayment lines. |
| Smoothing | Workbook's superseded sheet used trailing-3-month | **Current month only.** The live sheet states "There is no 3-month smoothing." |
| Per-person reduction limit | Workbook models 15% / $50k with residual | **Out of scope.** |
| Compensation routing | Paul: route *all* MSO comp to garden3d | **Overridden.** Sanctuary payouts stay on the Sanctuary ledger; only the true-up lands on garden3d. |
| What the cap measures | Nobody addressed it | **Delivered compensation, with reallocation** (§8.1). Needs ratification. |

### 2.2 Document amendments required (non-code)

1. "55% of the Sanctuary management fee" → the basis is garden3d's management fee
   income from all MSO payers.
2. "Sanctuary's five highest-earning contributors" → Top N is configurable,
   starting at 3.
3. The plan should state what happens when an executive's own earnings exceed
   their capped MSO compensation (§8.1) — it is currently silent.

## 3. Verified facts

Confirmed against production on 2026-10-09. Do not re-derive by guessing.

**garden3d QBO realm `9130355602868216`**

| Thing | Value |
| --- | --- |
| Income account | `Management Fee Income`, id **5**. P&L row label `"4100 Management Fee Income"`. |
| Service item | `Managerial Services`, id **2** → account 5. |
| Also posts to 5 | `Services`, id 1 (QBO default). Drafts must pin item 2. |
| Customers | Sanctuary Computer Inc (**2**), Index Space LLC (**5**), Kevin Duncan Wall (55), Sample Customer (1). |
| Absent | **USB Club LLC** — no customer record. |
| Terms | `Net 15`, id **2**, `due_days` 15 — matches `DEFAULT_PAYMENT_TERM`. No customer has `sales_term_ref` set. |

**Internal `ForecastClient` records exist for every enterprise:** Sanctuary
Computer (607830), Index Space LLC (1466083), USB Club (1858301), garden3d
(1151929). Note these names differ from both the `Enterprise` names and the QBO
customer names — see §6.2.

**QBO account ids:** 1 = Index Space, 2 = Sanctuary, 35 = garden3d, 68 = USB Club.

**Management fee actuals** (garden3d income == Sanctuary expense, accrual):
2026-06 $130,000 · 2026-07 $170,000 · 2026-08 $140,000. 100% currently from
Sanctuary. The jsonb value is a **String**, not a number.

**garden3d ledgers:** all 188 are `qbo_bound`. `hugh@` (contributor 3, ledger
404) and `paul@` (contributor 120, ledger 458) are `qbo_bound` with
`payment_methods ["qbo"]`.

**Invoice pass data:** 64 passes, 1,165 trackers. 57 Sanctuary-only; exactly 7
mixed (2025-06-01 … 2025-12-01), each with precisely one garden3d tracker
(`forecast_client_id` 1151929, `qbo_account_id` 35).

### 3.1 Trap: `find_row` returns 0.0 on a label miss

`QboProfitAndLossReport#find_row` exact-matches and falls back to `[nil, 0]` —
**in both the block and non-block branches**:

```ruby
(data[accounting_method]["rows"].find { |r| r[0] == label } || [nil, 0])[1].to_f
```

garden3d's row is `"4100 Management Fee Income"`. Verified: querying
`"Management Fee Income"` returns `0.0` for 2026-06/07/08, where the real values
are 130000/170000/140000.

Consequences, all mandatory:

- `find_row` **cannot be used at all** — it cannot distinguish a real `$0` from a
  miss, and its `.to_f` destroys the BigDecimal guarantee
- `Mso::ManagementFeeIncome` reads `data[method]["rows"]` directly, matches on
  `/\A4100\b/`, converts the String with `BigDecimal(str)`, and **raises**
  `RowMissing` when absent
- A silent miss would otherwise mean a $0 cap and nobody paid, with no error

### 3.2 Trap: a $0 invoice reads as `:paid`

`QboInvoice#status` tests `balance == 0` before `balance == total`. Since drafts
are written at **$0.00** (§6.2), an unedited draft that Finance sends is
immediately `:paid`. The payment gate must treat a zero-total invoice as
**not collected** (§6.4).

### 3.3 Trap: `all_items_with_deleted` includes soft-deleted rows

`Ledger#items_grouped_by_month` sums over `all_items_with_deleted` deliberately,
so the admin page can render strikethroughs. Verified live: contributor 595
(`office@breannaurquhart.com`), April 2026 Sanctuary ledger — `with_deleted`
$10,300.00 vs live **$0.00**, one soft-deleted payout.

The benchmark and the netting must read **non-deleted rows only**. The display
path keeps its own with-deleted set. One extraction cannot serve both (§7.2).

### 3.4 Trap: `ActsAsPeriod` does not reject future-dated overlaps

`period_ended_at` is `ended_at || Date.today`, so two open-ended periods both
collapse to today and `overlaps?` is false in both directions. A promotion row
(chief open-ended + principal from a future date, open-ended) validates cleanly,
and both are then returned for any later month — producing two `Line`s for one
person and dragging every other executive's pro rata down. See §7.1.

## 4. Architecture

```
S0  Per-entity invoice passes  (prerequisite PR, merged and verified first)

S1  garden3d's management fee          S2  Roster + benchmark
    :management_fee trackers           MsoRolePeriod
    Mso::ManagementFeeInvoices         Mso::Benchmark
    Mso::ManagementFeeIncome           Ledger::QualifyingIncome
                    \                 /
                     v               v
             S3  Mso::Compensation   (pure: no DB, no QBO, no clock)
                            |
                            v
             S4  MsoTrueup + Mso::MonthlyRun (orchestrator)
```

### 4.1 Seam contracts

Changing a signature requires updating this spec.

| Contract | Owner | Signature |
| --- | --- | --- |
| Fee income | S1 | `Mso::ManagementFeeIncome.for_month(date) -> BigDecimal`. Raises `RowMissing`. |
| Variance check | S1 | `Mso::ManagementFeeIncome.reconcile(date) -> { account_total:, payer_total:, variance: }` |
| Draft trackers | S1 | `Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass:) -> [InvoiceTracker]`. No QBO writes. |
| Push one draft | S1 | `Mso::ManagementFeeInvoices.push_invoice!(invoice_tracker:) -> QboInvoice`. The `make_invoice!` dispatch target. |
| Payment gate | S1 | `InvoicePass#management_fee_collected? -> Boolean` (§6.4) |
| Benchmark | S2 | `Mso::Benchmark.for_month(date) -> Mso::Benchmark::Result` (§7.3) |
| Roster | S2 | `MsoRolePeriod.active_during(date) -> relation`; rows respond to `#tier_multiplier -> BigDecimal` |
| Qualifying income | S2 | `Ledger::QualifyingIncome.for(ledger:, month:, excluding: []) -> BigDecimal` (§7.2) |
| Compensation | S3 | `Mso::Compensation.call(benchmark_average:, lines:, fee_income:, cap_percentage:) -> Mso::Compensation::Result` (§8) |
| Orchestration | S4 | `Mso::MonthlyRun.call(invoice_pass:) -> MsoSnapshot` (§9.5) |

## 5. Subsystem 0 — Per-entity invoice passes

### 5.1 Model

A pass belongs to the **issuing** enterprise, not the client's. A tracker lands on
the pass of its `qbo_account`'s enterprise. This is the only coherent axis:

- `clients_served` must **not** be scoped by enterprise. External clients have no
  `enterprise_forecast_client`, so scoping that way would strip the entire
  external book off Sanctuary's pass.
- Issuer-based routing matches what the backfill already does with the 7 garden3d
  trackers, and fixes the cross-billing case the comment at
  `invoice_tracker.rb:11-16` complains about.

### 5.2 Schema

```ruby
# Step 1 — nullable
add_reference :invoice_passes, :enterprise, null: true, foreign_key: true
add_column :invoice_trackers, :source, :integer, null: false, default: 0

# Step 2 — backfill (§5.3)

# Step 3 — constrain, only after backfill
change_column_null :invoice_passes, :enterprise_id, false
remove_index :invoice_passes, name: "index_invoice_passes_on_start_of_month"
add_index :invoice_passes, [:enterprise_id, :start_of_month], unique: true
change_column_null :invoice_passes, :start_of_month, false   # closes the NULL-dup hole
```

`InvoiceTracker` gains `enum source: { forecast: 0, management_fee: 1 }`. The enum
belongs to **S0**, since S0 ships first.

### 5.3 Backfill

1. Resolve each pass's enterprise as the modal `qbo_account`'s enterprise
   (Sanctuary for passes with no trackers).
2. For every **other** distinct `qbo_account_id` on that pass, find or create that
   enterprise's pass for the same `start_of_month` and move those trackers.
   Generalised over `qbo_account_id` — not hardcoded to garden3d or to the 7
   known dates, since production may have gained passes or Index/USB trackers.
3. Assert zero null `enterprise_id` rows, then apply the constraints.

`down` re-merges all non-Sanctuary passes for a month into the Sanctuary pass and
drops the created passes. Neither `InvoicePass` nor `InvoiceTracker` has
validations, callbacks or `acts_as_paranoid`, so the backfill is safe;
`Trueup.invoice_pass_id` is unaffected because existing pass ids stay Sanctuary's.

`db/schema.rb` is hand-curated — reflect these changes deliberately.

### 5.4 Call sites that must be updated

The original spec claimed two files. The real set, each a distinct production
failure:

| Site | Breakage |
| --- | --- |
| `lib/stacks/automator.rb:145-153` | `InvoicePass.create!` with no enterprise → `RecordInvalid`. It runs at `lib/tasks/stacks.rake:588` inside the **single** `begin/rescue` of `stacks:daily_tasks`, so everything after it stops: Runn sync, QBO sync, Deel sync, salary windows, every tracker/studio snapshot, notifications, task-cache warm. **Highest-severity item in S0.** Must pass Sanctuary explicitly, and `find_by` must become enterprise-scoped. |
| `lib/stacks/system.rb:79` | `.where(start_of_month:).first` unordered → may pick garden3d's pass, raising `NoMethodError` on nil `max_by`, or writing Hugh a **duplicate** founder true-up (`Trueup` has no uniqueness validation). Must scope to Sanctuary. |
| `app/models/periodic_report.rb:58-63` | Unions every enterprise's trackers → `#surplus` silently widens company-wide. Must scope to Sanctuary. |
| `app/services/mcp/get_invoice_passes_tool.rb:35-39` | Emits duplicate `month` keys. Must scope or group by enterprise. |
| `app/models/admin_authorization.rb:94-95` | `return true if subject.is_a?(InvoicePass)` grants leads-in-training read on **any** pass, including garden3d's. See §10. |
| `app/admin/invoice_trackers.rb:101` | Tracker moves rewrite `/admin/invoice_passes/:id/invoice_trackers/:id` URLs used in Twist notifications. |
| ~20 `test/` call sites | `InvoicePass.create!(start_of_month:)` without an enterprise. e.g. `test/models/invoice_pass_test.rb:8`, `test/models/qbo_records_scoping_test.rb:180,188`, `test/integration/admin_permission_grants_test.rb:104,114`. |

`lib/stacks/client_revenue.rb` is **safe** — `build_rows` drops internal clients
at line 98, and a management-fee tracker's client is internal by construction.

`make_trackers!` needs no internal-client carve-out: it only ever creates
`:forecast` trackers, which take the enum default.

### 5.5 Risk

This refactors live financial machinery. It ships as its own PR, merged and
verified against a real month, before any MSO work lands on it.

## 6. Subsystem 1 — Management fee invoices and fee income

### 6.1 Payers

```ruby
add_column :enterprises, :management_fee_payer, :boolean, null: false, default: false
add_column :enterprises, :g3d_qbo_customer_id, :string
```

Set `management_fee_payer` for Sanctuary, Index Space and USB Club. Validate that
garden3d is never flagged — it cannot invoice itself.

### 6.2 Customer resolution — by stored id, never by name

Name matching is provably broken. The three naming systems disagree:

| Enterprise | ForecastClient | QBO customer |
| --- | --- | --- |
| `Sanctuary Computer Inc` | `Sanctuary Computer` | `Sanctuary Computer Inc` (2) |
| `Index Space, LLC` | `Index Space LLC` | `Index Space LLC` (5) |
| `USB Club, LLC` | `USB Club` | *absent* |

Matching on any one string misses at least one payer and creates a **duplicate
customer** that Finance then invoices for real. Also, `fetch_all_customers` wraps
`Quickbooks::Service::Customer#all`, which returns **active customers only**, so
"including inactive" is not available without new code.

Therefore: `enterprises.g3d_qbo_customer_id` is seeded in the migration with the
verified ids (Sanctuary → `"2"`, Index Space → `"5"`). A customer is created
**only** when the column is blank, and the resulting id is persisted immediately.
USB Club is the only creation on first run.

### 6.3 Fee income

`Mso::ManagementFeeIncome.for_month(date) -> BigDecimal`

- garden3d's `QboProfitAndLossReport` for the month, **accrual**
- Reads `data["accrual"]["rows"]` directly; matches `/\A4100\b/`; `BigDecimal(str)`
- Raises `RowMissing` when no row matches — never returns `0.0` for a miss
- **Never force-refreshes.** `find_or_fetch_for_range(..., force = true, qa)` calls
  `existing.delete_all` then two live QBO fetches, destroying the cached row that
  the dashboard, `Enterprise#generate_snapshot!` and two MCP tools read.
  `app/services/mcp/get_enterprise_health_tool.rb:101` warns against exactly
  this. Fetch only when no persisted row exists for the month; §9.6's snapshot
  provides the correctness guarantee instead.

**Payer restriction.** The cap basis is account 4100, but account 4100 is a
*account*, not a payer set — garden3d has a non-MSO customer (Kevin Duncan Wall),
and the QBO default item `Services` also posts to account 5. A $30,000 non-MSO
advisory fee would silently raise the cap by $16,500 of executive compensation.

`Mso::ManagementFeeIncome.reconcile(date)` therefore compares the 4100 total
against the sum of the month's management-fee invoice totals. `Mso::MonthlyRun`
**raises on a non-zero variance**, surfacing it for a human rather than quietly
funding compensation from unrelated revenue.

`app/models/qbo_profit_and_loss_report.rb` is owned by **S1** for this work.

### 6.4 Payment gate

`InvoicePass#management_fee_collected?` is true only when, for every
`management_fee_payer` enterprise, the pass has exactly one `:management_fee`
tracker **and** that tracker's invoice is either genuinely collected or
deliberately waived.

Both naive forms fail:

- "every tracker is `:paid`" — `InvoiceTracker#status` returns `:impossible` for a
  blueprint-less tracker with an invoice (`invoice_tracker.rb:128-140`), so it can
  never be `:paid`. The gate reads `tracker.qbo_invoice&.status` directly, or
  `InvoiceTracker#status` gains a `:management_fee` branch (S0 owns that method).
- counting trackers created rather than payers owed — a generation failure on
  payer 3 leaves two trackers, both paid, and the gate passes with USB Club never
  invoiced, understating the cap.

A **zero-total** invoice counts as not collected (§3.2). A payer legitimately not
charged this month is recorded as waived on the tracker, so the gate can
distinguish "nothing owed" from "not yet invoiced".

Knock-on: `InvoicePass#statuses` and `Mcp::GetInvoicePassesTool.entity_block`
must not render management-fee trackers as `impossible` pills.

### 6.5 Draft generation

For each payer: find or create an `InvoiceTracker` with `source: :management_fee`,
`forecast_client` = the payer's internal client, `qbo_account` = garden3d's
(idempotent on the existing `[forecast_client_id, invoice_pass_id]` index). Then
one QBO line: description `"Management fee"`, amount **$0.00**, `item_ref` =
`Managerial Services` (id 2, resolved by name, failing loudly if absent),
`txn_date` = end of the pass month, term `Net 15`.

Finance edits the amount in QBO and sends. Stacks never writes the amount.

`make_invoice!` dispatches to `push_invoice!` when `source == :management_fee`;
its internal-client `raise` (`invoice_tracker.rb:738`) applies only to
`:forecast`. Note `make_invoice!` does `return if configuration_errors.any?` — a
**silent no-op**. `push_invoice!` must raise rather than return quietly.
Blueprint, `configuration_errors` and the payout pipeline skip
`:management_fee` trackers.

## 7. Subsystem 2 — Roster and benchmark

### 7.1 `MsoRolePeriod`

```ruby
create_table :mso_role_periods do |t|
  t.references :contributor, null: false, foreign_key: true
  t.integer :tier,       null: false
  t.string  :title,      null: false
  t.date    :started_at, null: false        # §3.4
  t.date    :ended_at
  t.timestamps
end
```

```ruby
class MsoRolePeriod < ApplicationRecord
  include ActsAsPeriod
  include BustsTaskCache
  belongs_to :contributor
  enum tier: { head: 0, svp: 1, chief: 2, principal: 3 }
  MULTIPLIERS = { "head" => BigDecimal("0.70"), "svp" => BigDecimal("0.85"),
                  "chief" => BigDecimal("1.00"), "principal" => BigDecimal("1.15") }.freeze
  validates :started_at, presence: true
  validates :title, presence: true
  validate :full_months_only

  def tier_multiplier = MULTIPLIERS.fetch(tier)
  def sibling_periods = contributor.mso_role_periods

  # MUST override: ActsAsPeriod's `ended_at || Date.today` makes two
  # open-ended periods non-overlapping (§3.4).
  def period_ended_at = ended_at || Date.new(9999, 12, 31)
end
```

- `started_at null: false` **and** a presence validation. `MsoRolePeriod` does not
  override `period_started_at`, so a nil would raise `NoMethodError` inside
  `does_not_overlap` (`ProjectLeadPeriod` only survives nulls because it *does*
  override). A nil start would also make the executive active for every month in
  history.
- `period_ended_at` returns a far-future sentinel so future-dated promotions are
  correctly rejected as overlapping.
- `full_months_only` copied from `ProjectLeadPeriod`: `started_at` the 1st,
  `ended_at` the last day of a month.
- `active_during(date)` is **new raw SQL** — `ActsAsPeriod` has no such scope, and
  building on `period_ended_at` would reintroduce the `Date.today` collapse.

`Mso::Compensation` additionally asserts **one line per contributor** (§8).

### 7.2 Qualifying income

`Ledger::QualifyingIncome.for(ledger:, month:, excluding: []) -> BigDecimal`

```ruby
KLASSES = [ContributorPayout, Trueup, PayStub, MsoTrueup].freeze
```

- **Non-deleted rows only** (§3.3). This is *not* an extraction of
  `items_grouped_by_month`'s sum, which reads `all_items_with_deleted` by design.
  The display path keeps its own with-deleted sum.
- `month:` takes a `Date`; rows bucket on `effective_on_for_display`, matching the
  display path. Verified safe: `ContributorPayout` returns the pass's
  `start_of_month` and `Trueup` returns `start_of_month.end_of_month` — different
  days, same bucket.
- `excluding:` matches on `[class, id]` pairs.
- Returns `BigDecimal` from `BigDecimal(amount.to_s)`, never `to_f`.
- `items_grouped_by_month` **keeps its existing Float sum unchanged.** The two
  paths want different row sets, so there is no shared extraction and no
  regression lock demanding bit-identical figures. A test asserts the two differ
  exactly by soft-deleted rows for a fixture ledger.

### 7.3 Benchmark

`Mso::Benchmark.for_month(date) -> Result`

```ruby
Result = Struct.new(:average, :configured_n, :counted, :members, :small_sample,
                    keyword_init: true)
# average      BigDecimal
# configured_n Integer — the setting
# counted      Integer — how many were actually averaged
# members      [{ contributor_id:, amount: }]
# small_sample Boolean — counted < configured_n
```

Pool construction, in order:

1. All contributors — **not** "contributors with a Sanctuary ledger", which is
   vacuous since `Ledger.ensure_all!` creates every (enterprise, contributor)
   pair.
2. Require an `admin_user` behind the contributor (`forecast_person.admin_user`).
   Commission-only payouts to outside entities auto-accept with no `admin_user`
   (`invoice_tracker.rb:567-579`) and are plain `ContributorPayout`s. Verified:
   contributor 628 (`enquiries@aufi.com`) held a **$21,024.90** referral
   commission at #3 in May 2026, worth +$1,359.90 on the top-3 average and
   ~$41.6k/yr of overpayment across a 2.55-multiplier roster.
3. Exclude any contributor with an `MsoRolePeriod` overlapping the month —
   **and** any contributor who has *ever* held one, so a departed executive's
   Sanctuary earnings cannot set their former peers' benchmark.
4. Score by `Ledger::QualifyingIncome` on the Sanctuary ledger for the month;
   drop zero and negative.
5. Top N by income; average. If fewer than N qualify, average over what exists
   and set `small_sample`. Never divide by N.

Top N is `System.first.mso_top_n` (Storext Integer, default 3) read through
`mso_top_n_clamped`, which coerces to Integer and clamps to `[1, ..]` — mirroring
`ghost_sweep_write_budget_clamped`, which exists because Storext returns Strings
for Integer attributes. Read via `System.first`, not the memoized
`System.instance`. `app/models/system.rb` is owned by **S2**.

Current month only. No smoothing.

## 8. Subsystem 3 — Compensation calculator

Pure: no database, no QBO, no `Date.today`. Fully determined by its arguments.

```ruby
Line   = Struct.new(:key, :multiplier, :already_earned, keyword_init: true)
Output = Struct.new(:key, :calculated, :final, :reduction, :trueup, keyword_init: true)
Result = Struct.new(:outputs, :cap, :delivered, :over_cap_by, keyword_init: true)
```

`cap_percentage` is a **BigDecimal fraction** (`0.55`), not a percentage integer —
passing `55` yields a cap 100× too large and no relative test would catch it.
Sourced from `Mso::Compensation::DEFAULT_CAP_PERCENTAGE`.

```
calculated_i = benchmark_average * multiplier_i
cap          = cap_percentage * fee_income
```

### 8.1 What the cap measures — awaiting ratification

An executive's MSO compensation is their tier target; the true-up is only the
payment mechanism, and compensation they already earned is part of that target.
So capping `Σ calculated` is wrong in both directions at once:

- When `already_earned_i > final_i`, the executive keeps the excess (there is no
  clawback), so **delivered** compensation exceeds the cap
- The cap room pro-rata'd to that executive is then wasted, needlessly cutting
  everyone else

Worked from live data — garden3d's September 2026 pay stubs as the roster,
benchmark $25,942.59 (Sanctuary's April 2026 top 3), fee income $90,000, cap
$49,500:

| Exec | calculated | naive final | earned | true-up | delivered |
| --- | --- | --- | --- | --- | --- |
| chief | 25,942.59 | 19,411.76 | 32,606.00 | 0.00 | 32,606.00 |
| svp | 22,051.20 | 16,500.00 | 12,047.50 | 4,452.50 | 16,500.00 |
| head | 18,159.81 | 13,588.24 | 9,000.00 | 4,588.24 | 13,588.24 |
| | 66,153.60 | 49,500.00 | | 9,040.74 | **62,694.24 = 69.7%** |

$13,194.24 over a "hard" cap, while SVP and Head are cut by $10,122.77/month
(~$121k/yr) and $30,336 of cap room goes unspent.

**Decision (to ratify): cap delivered compensation, reallocating freed room.**

```
1. final_i = calculated_i
2. Fix every line where already_earned_i >= final_i: delivered_i = already_earned_i,
   trueup_i = 0. These consume already_earned_i of cap.
3. Distribute (cap - Σ fixed delivered) across unfixed lines pro rata by
   multiplier, bounded above by calculated_i.
4. Repeat 2-3 until the fixed set stops growing (bounded by line count).
5. delivered = Σ delivered_i. If delivered > cap (Σ earned alone exceeds it),
   every trueup is 0 and `over_cap_by` records the unrecoverable excess for
   human escalation.
```

This is the only internally consistent reading. It changes what executives are
paid, so it needs Paul's sign-off; it is implemented behind
`Mso::Compensation::CAP_BASIS` so the alternative (cap `Σ calculated`) is a
one-line change.

### 8.2 Rounding

Largest-remainder (Hare), **applied in every branch**:

- Round each `final_i` down to cents, then distribute the remaining cents by
  descending fractional part
- The original "allocate the remainder to the largest line" was wrong twice: in
  the uncapped branch it would inflate the top earner until the total hit the cap,
  and it biases the same highest-tier executive every month
- The uncapped branch still needs correction — with `benchmark_average`
  18,333.6666…, finals round to a total one cent above a cap of exactly
  52,250.95, so `Σ final <= cap` fails while `total > cap` is false

### 8.3 Boundaries

`fee_income == 0` → cap 0 → all finals and true-ups 0. Empty `lines` → empty
result. `benchmark_average == 0` → all zeros. The `total > 0` guard sits beside
`total > cap`, so no division by zero.

## 9. Subsystem 4 — True-up and orchestration

### 9.1 Schema

```ruby
create_table :mso_trueups do |t|
  t.references :ledger,       null: false, foreign_key: true
  t.references :invoice_pass, null: false, foreign_key: true
  t.references :mso_snapshot, null: false, foreign_key: true
  t.decimal :amount, null: false
  t.text    :description, null: false
  t.datetime :accepted_at
  t.string  :qbo_bill_id
  t.datetime :deleted_at
  t.timestamps
  t.index [:ledger_id, :invoice_pass_id], unique: true, where: "deleted_at IS NULL"
end
```

The unique index is **partial on `deleted_at IS NULL`** — `acts_as_paranoid` plus
a total index would let one soft-deleted row block regeneration for that month
forever. Generation restores a soft-deleted row rather than inserting.

`accepted_at` is required and is **not** inherited: `Trueup` has no such column,
and `LedgerItem` defines only `payable?`.

### 9.2 Required methods

`SyncsAsQboBill` and the ledger views demand more than `bill_doc_number_code`:

| Method | Why |
| --- | --- |
| `bill_txn_date` | `SyncsAsQboBill` contract, consumed at lines 145-147 |
| `bill_description` | contract; also `Qbo::BillRouter#single_line` |
| `bill_doc_number_code` | `"MT"` — verified free against the `case` at `qbo_account.rb:252-275` |
| `effective_on_for_display` | consumed **unguarded** at `ledger.rb:144`; omit it and the ledger view raises |
| `accepted?` | §9.4 |
| `before_destroy :detach_and_destroy_qbo_bill` | as `PayStub`/`Reimbursement`; without it a destroyed row orphans its QBO bill |

Do **not** copy `Trueup#payable?`, which is hardcoded `true` — that would make
true-ups payable before acceptance.

### 9.3 Amount

```
trueup_i = Mso::Compensation output for this executive
already_earned_i = Σ Ledger::QualifyingIncome across ALL of the executive's
                   ledgers for the month, excluding this MsoTrueup
```

`excluding: [self]` is sufficient — an `MsoTrueup` lives on exactly one ledger,
and the partial unique index plus `[enterprise_id, start_of_month]` guarantee one
per executive per month, so no prior month's can leak in. Without it the true-up
nets against itself and converges to zero, since `MsoTrueup` is in `KLASSES`.

Floors at `$0` — no clawback. The admin surface shows the uncapped figures when
this happens.

### 9.4 Payability

```ruby
def payable?
  accepted? &&
    invoice_pass.management_fee_collected? &&
    mso_snapshot.all_expected_trueups_accepted?
end
```

`all?` over **rows that exist** is unsafe: a generation that fails partway creates
two of three true-ups, both accept, `all?` is true for 2 of 2, and both pay at
amounts computed for a two-person roster — permanently over cap once the third
lands (worked example: $63,366.34 against a $56,000 cap). The gate therefore
asserts one accepted true-up per `MsoRolePeriod` the snapshot recorded as active.

No counterpart to `allow_early_contributor_payouts_on` ships now; Finance will
likely ask for one.

### 9.5 Orchestration

`Mso::MonthlyRun.call(invoice_pass:) -> MsoSnapshot`, wrapped in a transaction:

1. Refuse unless the **Sanctuary pass for the same month is complete** and its
   contributor payouts are all accepted. `ContributorPayout#amount` is mutated by
   re-runs of `make_contributor_payouts!` (`invoice_tracker.rb:530-544`) and
   surplus chunks land only after the QBO invoice exists. Running before that
   freezes a too-high true-up: a chief true-up computed at $25,942.59 against $0
   earned, when $5,620 of Sanctuary payouts arrive a week later, **overpays
   $5,620 permanently**.
2. `Mso::ManagementFeeIncome.reconcile` — raise on variance (§6.3).
3. Read fee income once, before the loop, so `RowMissing` leaves no partial state.
4. Benchmark, roster, `Mso::Compensation`.
5. Write one `MsoSnapshot` and one `MsoTrueup` per active role period.

**Idempotency is by recomputation, not find-or-create.** Re-running updates
amounts for any true-up not yet paid, and refuses to alter one whose QBO bill has
payments. Find-or-create idempotency is what makes findings 2 and 6 permanent.

Note the QBO writes in §6.5 are not transactional with the database; invoice
pushes stay outside this transaction.

### 9.6 Snapshot

A dedicated `mso_snapshots` row — **not** jsonb on the pass. `InvoicePass` is
unconditionally readable by leads-in-training
(`admin_authorization.rb:94-95`), so storing fee income, benchmark, cap and every
executive's figures there would publish the whole compensation picture.

Columns: `invoice_pass_id`, `fee_income`, `benchmark_average`, `configured_n`,
`counted`, `cap_percentage`, `cap`, `delivered`, `over_cap_by`, `superseded_at`,
`superseded_by_id`, timestamps. Per-line figures live on the `MsoTrueup` rows
(`calculated`, `reduction`, `final`).

A recompute **supersedes** rather than mutates: the prior snapshot is stamped
`superseded_at` and the new one links back. Write-once primacy is what locks in a
stale overpayment; a loud supersede chain keeps the audit trail without freezing
an error.

### 9.7 Registration points

Seven, not four. Each is a distinct production bug.

| # | Edit | Failure if skipped |
| --- | --- | --- |
| 1 | `Money::PayableQboBills::HOST_KLASSES` | never appears as payable |
| 2 | detach list in `QboAccount#sync_all_bills!` (`qbo_account.rb:239-244`) | deleted remote bill leaves a dangling `qbo_bill_id`; "Sync to QBO" duplicates |
| 3 | `when "MT"` arm in `cleanup_orphaned_qbo_objects!` (`qbo_account.rb:252-275`) | falls to `klass = nil` and the last-defence path. The requirement is the `when` arm, not merely a unique code. |
| 4 | **`Qbo::BillRouter#concept_lines`** (`bill_router.rb:122-133`) | falls to `else → :subcontractor`; garden3d's `subcontractor_by_studio` is `{}` and `:subcontractor` is `FALLBACKABLE`, so it resolves to `subcontractor_default "6100" # Platform Infrastructure` **without raising**. Executive compensation posts to Platform Infrastructure silently. |
| 5 | `Money::QboBillSummary::PRELOADS` | §9.4's `payable?` hits `invoice_pass` and the snapshot per row — an N+1 on a page with documented 4s renders |
| 6 | `ledger_item_path` case in `app/views/admin/money/payable_qbo_bills.html.erb:21-29` | `case` has no `else`; an `MsoTrueup` row yields a nil path |
| 7 | `Ledger` `has_many :mso_trueups` + `visible_items` + `all_items_with_deleted`; `Contributor`'s seven `*_with_deleted` readers, `preload_for_ledger_view!` and `aggregated_new_deal_balance`; the four `is_a?(Trueup)` branches in `app/views/admin/contributors/_show.html.erb` | the true-up never affects `balance`/`unsettled` and never renders |

Point 7 spans files assigned to S2 and S0. See §13.

## 10. Authorization and privacy

`AdminAuthorization#authorized?` has a blanket
`return true if (user.is_admin? || user.can_act_as_lead?)` at line 84. Two
mechanisms that cancel each other out are not acceptable:

- A guard covering only `[:create, :update, :destroy]` lets `:read` fall through
  to line 84, so **every full lead reads executive compensation**
- Adding `MsoTrueup` to `OWN_LEDGER_ITEM_CLASSES` does nothing for leads, because
  that list is consulted at lines 114-127, **below** line 84
- Worse, `OWN_LEDGER_ITEM_CLASSES` grants `[:index, :new, :create]` to any user
  with a contributor record, and `scope_collection` returns the **unnarrowed**
  collection when `scoped_ids` is empty — so every contributor in Stacks could
  list every executive's true-up amounts, and a `:create` grant would let one
  write themselves a $50,000 true-up, accept it (`all?` over a one-row set is
  true) and have it paid

Required, as **one combined guard above line 84**:

```ruby
if subject.is_a?(MsoTrueup) || subject == MsoTrueup ||
   subject.is_a?(MsoRolePeriod) || subject == MsoRolePeriod ||
   subject.is_a?(MsoSnapshot) || subject == MsoSnapshot
  return true if user.is_admin?
  return own_mso_trueup?(subject, action)   # :read + acceptance toggle only
  # everything else, including :index, :new and :create → false
end
```

Plus:

- Explicit `scope_collection` branches for `MsoTrueup`, `MsoRolePeriod` and
  `MsoSnapshot` — the `case` falls through to `else → collection` for unknown
  models
- `actions :index, :show` pinned on the admin resources (how `app/admin/trueups.rb`
  and `pay_stubs.rb` are safe today), with `MsoTrueup` **not** in
  `OWN_LEDGER_ITEM_CLASSES`
- An `InvoicePass` enterprise check above line 84, since
  `return true if subject.is_a?(InvoicePass)` currently grants read on garden3d's
  pass to leads-in-training
- Permitted params stripped server-side for non-admins — hiding an ActiveAdmin
  input enforces nothing

**MCP leak.** `Mcp::ListPayableBillsTool` emits `vendor`, `doc_number`, `total`
and `remaining_balance` per bill (`list_payable_bills_tool.rb:65-73`) with no MSO
exclusion; `doc_number` would read `Stacks_<id>_MT`. It must exclude `MsoTrueup`
rows. `Stacks::PeopleCostAccounts` does **not** cover this — its regexes gate the
spend side only, and management fee *income* still flows through
`find_rows(..., ["Total Income"])`.

**Correction to the previous revision:** `test/integration/privacy_wall_test.rb`
tests `Document.corpus_eligible` and MCP tools; its only controller assertion
(line 127) checks that no API controller touches **corpus** data. It cannot see
ActiveAdmin resources and knows nothing about compensation. No existing test
protects these surfaces — §12's authorization tests are new work.

## 11. Edge cases

| Case | Behaviour |
| --- | --- |
| P&L row missing | Raise `RowMissing`. Never $0. |
| Fee income genuinely $0 | Cap 0 → no true-ups. |
| 4100 contains non-MSO fees | `reconcile` variance → raise. |
| Fewer than N earners | Average over available; `small_sample`. |
| Non-contributor in the pool | Excluded — no `admin_user`. |
| Former executive in the pool | Excluded — ever held a role. |
| Executive out-earns target | True-up $0, no clawback, `over_cap_by` recorded. |
| Σ earned alone exceeds cap | All true-ups 0; `over_cap_by` escalated. |
| Future-dated promotion | Rejected as overlapping (§3.4). |
| Nil `started_at` | Rejected by `null: false` + validation. |
| Two lines for one contributor | `Mso::Compensation` asserts one per contributor. |
| USB Club has no QBO customer | Created once; id persisted. |
| garden3d flagged as payer | Rejected by validation. |
| Payer not charged this month | Marked waived; gate distinguishes from not-invoiced. |
| $0 invoice sent | Not collected (§3.2). |
| Partial generation | Transactional; gate asserts one per active role period. |
| Sanctuary pass incomplete | Run refused (§9.5). |
| Payout amount changes after the run | Recompute supersedes; paid rows refused. |
| Soft-deleted payout | Excluded from qualifying income (§3.3). |
| Soft-deleted true-up | Partial unique index allows regeneration; restored, not duplicated. |
| Non-`qbo_bound` garden3d ledger | Precondition: all 188 are `qbo_bound` today. A `legacy` ledger makes a true-up invisible on the Money page — assert and surface. |
| Rounding | Largest-remainder in every branch; `Σ final <= cap` always. |

## 12. Testing

Each test must fail before its implementation exists.

**S0** — backfill assigns the modal enterprise and splits mixed passes
generically over `qbo_account_id`, not the 7 known dates; reversible;
`[enterprise, start_of_month]` uniqueness; existing 1,165 trackers read as
`:forecast`; **`Stacks::Automator#attempt_invoicing_for_previous_month` succeeds
and targets Sanctuary** (the `daily_tasks` blast radius); `sync_founder_trueups!`
writes exactly one founder true-up with two passes present; `PeriodicReport`
surplus unchanged; `clients_served` unchanged (not enterprise-scoped).

Migrations never run in the test suite — `db/schema.rb` is hand-curated and the
test DB is schema-loaded. Backfill tests instantiate the migration class
explicitly against a pre-constraint fixture state.

**S1** — `RowMissing` on an absent row **and** a separate test proving a genuine
$0 is distinguished from a miss; prefix match survives a label rename; no
force-refresh (assert `find_or_fetch_for_range` is not called with `force: true`
when a row exists); `reconcile` raises on variance; customer resolved by stored
id, created only when blank, id persisted; draft carries item 2 and $0;
generation idempotent; `management_fee_collected?` false when a payer has no
tracker, false for a $0 sent invoice, true when waived; garden3d rejected as
payer; `push_invoice!` raises rather than no-ops on `configuration_errors`.

**S2** — `full_months_only` rejects mid-month on both ends; nil `started_at`
rejected; **two open-ended periods rejected** (§3.4); `active_during` returns a
future-dated period only for its own months; non-`admin_user` contributors
excluded (regression on contributor 628's $21,024.90); former executives
excluded; soft-deleted payouts excluded (regression on contributor 595's
$10,300); `small_sample`; `mso_top_n` as a String coerced and clamped;
`items_grouped_by_month` unchanged.

**S3** — pro rata arithmetic; the §8.1 reallocation reaches the worked figures;
`Σ delivered <= cap` in every branch including after rounding; largest-remainder
distribution; uncapped branch leaves each line at its own rounded value;
`over_cap_by` when earned alone exceeds the cap; `cap_percentage` of `0.55`
yields `0.55 * fee_income`; zero fee income; empty lines; zero benchmark; purity
(no DB, no clock).

**S4** — netting excludes self (fails if `excluding:` is dropped); netting spans
multiple ledgers; floors at zero; `payable?` false until collected; `payable?`
false until **every expected** true-up is accepted, not merely every existing
one; present in `PayableQboBills`; `"MT"` round-trips through
`cleanup_orphaned_qbo_objects!`; **`Qbo::BillRouter` maps `MsoTrueup` to the
intended GL account, not `6100`**; `ledger_item_path` resolves; appears in
`Ledger#balance`; run refused when the Sanctuary pass is incomplete; recompute
supersedes and refuses paid rows; one true-up per role period; soft-deleted
true-up regenerates.

**Authorization** — a full lead cannot `:read` any MSO subject; a plain
contributor cannot `:index` `MsoTrueup`; a contributor cannot `:create` one; an
executive can `:read` and accept their own but not another's, and cannot
`:update`/`:destroy` their own; leads-in-training cannot read garden3d's
`InvoicePass`; `Mcp::ListPayableBillsTool` omits `MsoTrueup`.

Local constraints: run with
`--exclude "sync_meet runs the connector inside a SystemTask"` (live Google call,
can hang for over an hour); no concurrent suite runs against the shared test DB.

## 13. Build sequencing and ownership

| Stage | Work | Depends on |
| --- | --- | --- |
| 1 | S0 — per-entity passes (own PR, merged and verified) | — |
| 2 | S1, S2, S3 in parallel | S0 (S3 on pinned signatures only) |
| 3 | S4 | S1, S2, S3 |

S4 depends on **S2** as well as S1 and S3 — it consumes
`Ledger::QualifyingIncome`, `MsoRolePeriod.active_during` and
`Mso::Benchmark.for_month`.

| Subsystem | Files |
| --- | --- |
| S0 | `app/models/invoice_pass.rb`, `app/models/invoice_tracker.rb` (enum + `status` branch), `app/admin/invoice_passes.rb`, `app/admin/invoice_trackers.rb`, `lib/stacks/automator.rb`, `lib/stacks/system.rb`, `app/models/periodic_report.rb`, `app/services/mcp/get_invoice_passes_tool.rb`, pass/tracker migrations, affected tests |
| S1 | `app/services/mso/management_fee_invoices.rb`, `app/services/mso/management_fee_income.rb`, `app/models/qbo_profit_and_loss_report.rb`, `app/models/enterprise.rb`, `app/models/invoice_tracker.rb` (`make_invoice!` dispatch only), its migrations |
| S2 | `app/models/mso_role_period.rb`, `app/services/mso/benchmark.rb`, `app/models/ledger/qualifying_income.rb`, `app/models/system.rb`, `app/models/contributor.rb`, **sole owner of `app/models/ledger.rb`**, its migration |
| S3 | `app/services/mso/compensation.rb` only |
| S4 | `app/models/mso_trueup.rb`, `app/models/mso_snapshot.rb`, `app/services/mso/monthly_run.rb`, `app/services/money/payable_qbo_bills.rb`, `app/services/money/qbo_bill_summary.rb`, `app/services/qbo/bill_router.rb`, `app/models/qbo_account.rb`, `app/models/admin_authorization.rb`, `app/services/mcp/list_payable_bills_tool.rb`, `app/views/admin/money/payable_qbo_bills.html.erb`, admin surfaces, its migrations |

**Shared-file protocol.** Three files are touched by more than one subsystem.
S2 and S0 land the registrations for S4 up front, against the pinned names, so S4
never edits another agent's file:

| File | Owner | Lands up front for S4 |
| --- | --- | --- |
| `app/models/ledger.rb` | S2 | `has_many :mso_trueups`, entries in `visible_items` and `all_items_with_deleted` |
| `app/models/contributor.rb` | S2 | `mso_trueups_with_deleted`, `preload_for_ledger_view!`, `aggregated_new_deal_balance` branches |
| `app/models/invoice_pass.rb` | S0 | `has_many :mso_trueups`, `has_one :mso_snapshot`, `management_fee_collected?` |
| `app/models/invoice_tracker.rb` | S0 enum + `status`; S1 `make_invoice!` dispatch | sequenced, not concurrent |

`app/views/admin/contributors/_show.html.erb`'s four `is_a?(Trueup)` branches go
to S4, which owns no other view.

## 14. Out of scope

- Per-person cap reduction limits and residual tracking
- Routing contributor payouts away from Sanctuary
- An early-release escape hatch equivalent to `allow_early_contributor_payouts_on`
- Forecasting and scenario modelling — the workbook stays the planning tool
- Profit share in the benchmark
- Trailing-month smoothing
- Automatic month-end triggering; passes stay admin-created
