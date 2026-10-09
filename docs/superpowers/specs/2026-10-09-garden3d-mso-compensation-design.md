# garden3d MSO Compensation — Design

**Date:** 2026-10-09
**Status:** Approved design, pending implementation
**Branch:** `worktree-garden3d-mso`

## 1. Purpose

garden3d operates an MSO (management services organization) whose executives are
compensated from the management fee garden3d charges the operating companies.
This design covers everything Stacks needs to run that compensation monthly:

1. garden3d issuing monthly management-fee invoices to the operating companies
2. Reading the month's management fee income as the cap basis
3. Computing the Top-N Sanctuary contributor benchmark
4. Applying tier multipliers and the aggregate cap
5. Paying each executive a true-up on the garden3d ledger

## 2. Source documents

| Source | Role |
| --- | --- |
| [MSO Compensation Plan](https://app.notion.com/p/garden3d/Garden3d-MSO-Compensation-Plan-3e3131fea2c780adbabbdc8551c23b5d) | The plan executives agree to. Authoritative on tiers, cap %, pro rata allocation. |
| [MSO – Stacks](https://app.notion.com/p/garden3d/MSO-Stacks-3f4131fea2c7809f8ec4c4e5cdbc4334) (Paul) | Intended Stacks mechanics. Authoritative on the true-up concept and Top-N configurability. |
| `g3d - MSO 2026-2027 - Scenario Modeling.xlsx` | Scenario model. Confirms current-month benchmark, no smoothing. |

### 2.1 Conflicts resolved

| Topic | Sources said | Decision |
| --- | --- | --- |
| Top N | Plan: 5. Paul: configurable, 3 now → 5 in 2027 | Configurable setting, default **3**. Historical correctness via per-pass snapshot, not a schedule table. |
| Cap basis | Plan/Paul/workbook: Sanctuary fee only | **55% of garden3d's total management fee income** (all payers), read from one P&L row. |
| Fee source | Paul: read the QBO invoice amount | **garden3d's P&L `4100 Management Fee Income`**, accrual. Invoice totals are not the fee — future invoices will carry loan repayment lines. |
| Smoothing | Workbook's superseded sheet used trailing-3-month | **Current month only.** The live sheet states "There is no 3-month smoothing." |
| Per-person cap reduction limit | Workbook models 15% / $50k with residual | **Out of scope.** Pro rata only, matching the signed plan. |
| Compensation routing | Paul: route *all* MSO member comp to garden3d | **Overridden.** Sanctuary project payouts stay on the Sanctuary ledger; only the true-up lands on garden3d. |

### 2.2 Document amendments required (non-code)

Two statements in the MSO Compensation Plan no longer match the agreed build and
should be amended before executives rely on them:

1. "55% of the Sanctuary management fee received by Garden3d" → the cap basis is
   garden3d's total management fee income across all payers.
2. "Sanctuary's five highest-earning contributors" → Top N is configurable and
   starts at 3.

## 3. Verified facts

Confirmed live against production data on 2026-10-09. Implementations must not
re-derive these by guessing.

**garden3d QBO realm `9130355602868216`**

| Thing | Value |
| --- | --- |
| Income account | `Management Fee Income`, id **5**, Income / ServiceFeeIncome / Revenue. P&L row label `"4100 Management Fee Income"`. |
| Service item to use | `Managerial Services`, id **2** → income account 5. |
| Other item posting to 5 | `Services`, id 1 (the default item). Accounting is identical, but drafts must pin item 2. |
| Customers present | Sanctuary Computer Inc (2), Index Space LLC (5), Kevin Duncan Wall (55), Sample Customer (1). |
| Customer absent | **USB Club LLC** — no customer record exists. |
| Sales terms | No customer has `sales_term_ref` set. |

**Internal `ForecastClient` records exist for every enterprise**

| Enterprise | ForecastClient | `forecast_id` |
| --- | --- | --- |
| Sanctuary Computer Inc | Sanctuary Computer | 607830 |
| Index Space, LLC | Index Space LLC | 1466083 |
| USB Club, LLC | USB Club | 1858301 |
| garden3d, LLC | garden3d | 1151929 |

**QBO account ids:** 1 = Index Space, 2 = Sanctuary, 35 = garden3d, 68 = USB Club.

**Management fee actuals** (garden3d income == payer expense, both accrual):

| Month | garden3d `4100 Management Fee Income` | Sanctuary `8300 Management Fee Expense` |
| --- | --- | --- |
| 2026-06 | $130,000 | $130,000 |
| 2026-07 | $170,000 | $170,000 |
| 2026-08 | $140,000 | $140,000 |

100% of garden3d's management fee income currently comes from Sanctuary, so the
"total" and "Sanctuary only" cap bases are numerically identical today.

**Invoice pass migration data:** 64 `InvoicePass` rows, 1,165 `InvoiceTracker`
rows. 57 passes contain only Sanctuary (`qbo_account_id` 2) trackers. Exactly 7
passes are mixed — 2025-06-01 through 2025-12-01 — and each contains precisely
**one** garden3d tracker (`forecast_client_id` 1151929, `qbo_account_id` 35).

### 3.1 Critical trap: `find_row` returns 0.0 on a label miss

`QboProfitAndLossReport#find_row` does an exact string match and falls back to
`[nil, 0]`:

```ruby
(data[accounting_method]["rows"].find { |r| r[0] == label } || [nil, 0])[1].to_f
```

garden3d's row is labelled `"4100 Management Fee Income"`, not
`"Management Fee Income"`. Verified behaviour:

| Month | `"Management Fee Income"` | `"4100 Management Fee Income"` |
| --- | --- | --- |
| 2026-06 | `0.0` | `130000.0` |
| 2026-07 | `0.0` | `170000.0` |
| 2026-08 | `0.0` | `140000.0` |

A naive lookup yields a $0 cap, which silently zeroes every executive's true-up
with no error raised anywhere. `Mso::ManagementFeeIncome` **must raise** when the
row is absent rather than return zero. This is a correctness requirement, not a
style preference, and it must have a dedicated regression test.

## 4. Architecture

Five units. Subsystem 0 is a prerequisite refactor shipped separately. Subsystem 3
is a pure function so it can be built and tested without the others existing.

```
S0  Per-entity invoice passes  (prerequisite PR, merged first)
      invoice_passes.enterprise_id · invoice_trackers.source

S1  garden3d's management fee          S2  Roster + benchmark
    InvoiceTracker source:             MsoRolePeriod
      :management_fee on g3d's pass    Mso::Benchmark.for_month
    Mso::ManagementFeeInvoices         Ledger qualifying-income extraction
    Mso::ManagementFeeIncome
                    \                 /
                     v               v
             S3  Mso::Compensation   (pure: no DB, no QBO)
                            |
                            v
             S4  MsoTrueup  (garden3d ledger, QBO bill, acceptance)
```

### 4.1 Seam contracts

Pinned so each agent builds against signatures, never another subsystem's
internals. Changing a signature requires updating this spec.

| Contract | Owner | Signature |
| --- | --- | --- |
| Fee income | S1 | `Mso::ManagementFeeIncome.for_month(date) -> BigDecimal`. Raises `Mso::ManagementFeeIncome::RowMissing` if the account row is absent. |
| Paid gate | S1 | `InvoicePass#management_fee_invoices_all_paid? -> Boolean`. True only when at least one `:management_fee` tracker exists and every one is `:paid`. |
| Benchmark | S2 | `Mso::Benchmark.for_month(date) -> Result(average:, top_n:, members:, sample_size:, small_sample:)` |
| Roster | S2 | `MsoRolePeriod.active_during(date) -> relation`; each row responds to `#tier_multiplier -> BigDecimal` |
| Qualifying income | S2 | `Ledger::QualifyingIncome.for(ledger:, month:, excluding: []) -> BigDecimal` |
| Compensation | S3 | `Mso::Compensation.call(benchmark_average:, role_periods:, fee_income:, cap_percentage:) -> [Line]` where `Line = (role_period, calculated, reduction, final)` |

## 5. Subsystem 0 — Per-entity invoice passes

### 5.1 Rationale

`InvoicePass` is globally unique on `start_of_month`, so garden3d's invoices ride
on Sanctuary's pass. Ledgers are already per-enterprise; passes should be too.
This is a prerequisite because management-fee invoices need a garden3d pass to
live on.

### 5.2 Schema

```ruby
# invoice_passes
add_reference :invoice_passes, :enterprise, null: false, foreign_key: true
remove_index  :invoice_passes, [:start_of_month]                  # was unique
add_index     :invoice_passes, [:enterprise_id, :start_of_month], unique: true

# invoice_trackers
add_column :invoice_trackers, :source, :integer, null: false, default: 0
```

`InvoiceTracker` gains `enum source: { forecast: 0, management_fee: 1 }`.

### 5.3 Backfill

Within the same migration, in this order:

1. Assign `enterprise_id` = Sanctuary to every existing pass.
2. For each of the 7 mixed passes, create a garden3d pass with the same
   `start_of_month` and move its garden3d trackers (`qbo_account_id` 35) onto it.
3. Only then add the `null: false` constraint and the unique index.

The migration must derive "mixed" dynamically (group trackers by
`qbo_account_id`), not from the hardcoded 7 dates — production may have gained
passes since this spec was written. It must assert zero passes with a null
`enterprise_id` before applying the constraint, and must be reversible.

`db/schema.rb` is hand-curated in this repo; the migration's schema changes must
be reflected there deliberately.

### 5.4 Behaviour changes

- `InvoicePass belongs_to :enterprise`
- `InvoicePass#clients_served` scopes to the pass's enterprise's clients rather
  than all clients served company-wide
- `InvoicePass#make_trackers!` defaults each tracker's `qbo_account` to the
  **pass's own enterprise's** QBO account, removing the Sanctuary fallback
- `make_trackers!` continues to reject internal clients, but only for
  `source: :forecast`
- Admin index groups/filters passes by enterprise

### 5.5 Risk

This refactors live financial machinery. It ships as its own PR, merged and
verified against a real month before any MSO work builds on it, so an invoicing
schema change stays revertable independently of a compensation feature.

## 6. Subsystem 1 — Management fee invoices and fee income

### 6.1 Invoiceable enterprises

```ruby
add_column :enterprises, :management_fee_payer, :boolean, null: false, default: false
```

Set true for Sanctuary, Index Space and USB Club. garden3d must never be flagged —
it cannot invoice itself. Add a model validation rejecting that.

### 6.2 Draft generation

`Mso::ManagementFeeInvoices.generate!(invoice_pass:)` — for a garden3d pass, for
each `management_fee_payer` enterprise:

1. Find or create an `InvoiceTracker` with `source: :management_fee`,
   `forecast_client` = the payer's internal `ForecastClient`, `qbo_account` =
   garden3d's. The existing unique index on
   `[forecast_client_id, invoice_pass_id]` makes this idempotent.
2. Resolve the garden3d QBO customer for that enterprise: match an existing
   customer by exact `display_name` (case-insensitive, **including inactive
   customers**), else create one. Persist the resolved customer id on the tracker
   so later months never re-match by name.
3. Build a `Quickbooks::Model::Invoice` with a single line: description
   `"Management fee"`, amount **$0.00**, `item_ref` = `Managerial Services` (id 2,
   resolved by name via `fetch_all_items`, failing loudly if absent).
4. `txn_date` = end of the pass month. Sales term = `DEFAULT_PAYMENT_TERM`.

Finance then edits the amount in QBO and sends it. Stacks never writes the amount.

`InvoiceTracker#make_invoice!` dispatches to this service when
`source == :management_fee`; its existing internal-client guard applies only to
`:forecast`. Blueprint construction, `configuration_errors` and the contributor
payout pipeline all skip `:management_fee` trackers.

### 6.3 Fee income reader

`Mso::ManagementFeeIncome.for_month(date) -> BigDecimal`

Reads garden3d's `QboProfitAndLossReport` for the month, **accrual** basis, and
returns the `4100 Management Fee Income` row. Accrual because recognition is on
send, and because accrual is already the structural default for finance reads.

Requirements:

- Match the row by account-number prefix (`/\A4100\b/`) rather than exact label,
  so a label rename doesn't silently zero it
- Raise `RowMissing` when no row matches — **never** return `0.0` for a miss
- Distinguish a genuine `$0` (row present, value zero) from a missing row
- Refresh the report before reading, since the P&L moves after month end

### 6.4 Why invoices still matter

The cap basis comes from the P&L, not the invoices. The invoices exist for the
monthly ritual and to gate payment: `MsoTrueup` is not payable until every
management-fee invoice for the month is paid.

## 7. Subsystem 2 — Roster and benchmark

### 7.1 `MsoRolePeriod`

```ruby
class MsoRolePeriod < ApplicationRecord
  include ActsAsPeriod     # overlap rejection + ended_at > started_at
  include BustsTaskCache
  belongs_to :contributor
  enum tier: { head: 0, svp: 1, chief: 2, principal: 3 }
  validates :title, presence: true
  validate :full_months_only
  def sibling_periods = contributor.mso_role_periods
end
```

```ruby
create_table :mso_role_periods do |t|
  t.references :contributor, null: false, foreign_key: true
  t.integer :tier, null: false
  t.string  :title, null: false
  t.date    :started_at
  t.date    :ended_at
  t.timestamps
end
```

`full_months_only` is copied verbatim from `ProjectLeadPeriod` — `started_at` must
be the first day of a month, `ended_at` the last. `ActsAsPeriod` supplies overlap
rejection via `sibling_periods`, so one contributor cannot hold two tiers at once.

Multipliers: head 0.70, svp 0.85, chief 1.00, principal 1.15. Defined as
`BigDecimal` constants on the model, not floats.

`MsoRolePeriod.active_during(date)` returns periods overlapping the given month,
treating a nil `ended_at` as open-ended.

### 7.2 Qualifying income

Extract the existing rule from `Ledger#items_grouped_by_month` into
`Ledger::QualifyingIncome` so the ledger UI and the benchmark cannot drift:

```ruby
KLASSES = [ContributorPayout, Trueup, PayStub].freeze
```

`Ledger#items_grouped_by_month` must then consume the extracted module rather
than keeping its own inline sum. Reimbursements, contributor adjustments, profit
shares and Deel invoice adjustments remain excluded, matching the plan's
"expense reimbursements, accounting adjustments and other non-compensation
payments are excluded".

`excluding:` takes host records to omit — used by S4 so an `MsoTrueup` never nets
against itself.

### 7.3 Benchmark

`Mso::Benchmark.for_month(date)`:

1. Top N comes from `System.first.mso_top_n` (Storext Integer, default 3), read
   through a coerced accessor — Storext can return a `String` for an Integer
   attribute, which would break comparisons
2. Candidate pool: contributors with a **Sanctuary** ledger, excluding any
   contributor with an `MsoRolePeriod` overlapping the month
3. Score each by `Ledger::QualifyingIncome` for that month on their Sanctuary
   ledger; drop zero and negative earners
4. Take the top N by income, average them
5. If fewer than N candidates have income, average over what exists and set
   `small_sample: true`. Never divide by N when the pool is smaller.

Current month only. No smoothing.

## 8. Subsystem 3 — Compensation calculator

`Mso::Compensation.call(benchmark_average:, role_periods:, fee_income:, cap_percentage:)`

Pure: no database, no QBO, no `Date.today`. Entirely determined by its arguments.

```
calculated_i = benchmark_average * multiplier_i
cap          = cap_percentage * fee_income
total        = Σ calculated_i

if total > cap && total > 0
  factor_i = cap / total
  final_i  = calculated_i * factor_i
  reduction_i = calculated_i - final_i
else
  final_i = calculated_i, reduction_i = 0
end
```

Returns one `Line` per role period. Requirements:

- All arithmetic in `BigDecimal`. Round each `final` to cents **and** ensure
  `Σ final` does not exceed the cap after rounding — allocate any rounding
  remainder to the largest line rather than letting the total drift above the cap
- `fee_income == 0` → cap is 0 → every `final` is 0 (Paul's natural gate)
- Empty `role_periods` → empty result, no division by zero
- `benchmark_average == 0` → all zeros, no reduction

## 9. Subsystem 4 — MSO true-up

### 9.1 Model

```ruby
class MsoTrueup < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill
  belongs_to :invoice_pass        # garden3d's pass for the month
  validates :amount, presence: true
  validates :description, presence: true
end
```

Lives on the executive's **garden3d** ledger. One row per executive per month;
unique on `[ledger_id, invoice_pass_id]`.

### 9.2 Amount

```
final_i            = Mso::Compensation line for this executive
already_earned_i   = Σ Ledger::QualifyingIncome across ALL of the executive's
                     ledgers for the month, excluding this MsoTrueup
amount_i           = max(0, final_i - already_earned_i)
```

Netting spans every enterprise ledger, per Paul's intent that MSO compensation is
total target compensation. Because `Trueup` is in `QualifyingIncome::KLASSES` and
`MsoTrueup` will be too, the `excluding:` guard is mandatory — without it the
true-up nets against itself and converges to zero.

A negative result floors at `$0` — no clawback. The admin page surfaces when this
happens, with the uncapped figures, so an executive out-earning their tier target
is visible rather than silent.

### 9.3 Payability

```ruby
def payable?
  accepted? &&
    invoice_pass.management_fee_invoices_all_paid? &&
    invoice_pass.mso_trueups.all?(&:accepted?)
end
```

Mirrors `ContributorPayout#payable?`. Recognition of gross income happens on
send; payment waits for cash plus unanimous acceptance.

### 9.4 Registration points

Adding a `SyncsAsQboBill` host requires four edits that are easy to miss, each of
which causes a distinct production bug if skipped:

1. `Money::PayableQboBills::HOST_KLASSES` — otherwise it never appears as payable
2. The detach list in `QboAccount#sync_all_bills!` — otherwise a deleted remote
   bill leaves a dangling `qbo_bill_id` and "Sync to QBO" duplicates the bill
3. `AdminAuthorization` — see §10
4. `bill_doc_number_code` — `"MT"`. Existing codes: CP, TU, CA, PS, SB, RB.
   Must be unique or `cleanup_orphaned_qbo_objects!` misroutes the class lookup.

### 9.5 Snapshot

The pass records what it used — fee income, benchmark average, Top N, cap
percentage, and each line's calculated/reduction/final. Stored as jsonb on the
pass or a dedicated row. The P&L keeps moving after month end; without a snapshot
reopening a closed month silently restates what was paid.

## 10. Authorization and privacy

`AdminAuthorization#authorized?` contains a blanket
`return true if user.is_admin? || user.can_act_as_lead?`. Every MSO subject must
be guarded **above** that line, as `ApiToken` and `ProjectCapsule#sign_off`
already are. Otherwise any project lead — including leads-in-training with
project-scoped grants — can read and edit executive compensation.

- `MsoRolePeriod`, `MsoTrueup`, management-fee trackers: admin-only for
  `:create`, `:update`, `:destroy`
- An executive may `:read` and toggle acceptance on **their own** `MsoTrueup`,
  mirroring `OWN_LEDGER_ITEM_CLASSES`; `:update` and `:destroy` stay denied
- `MsoTrueup` is added to `OWN_LEDGER_ITEM_CLASSES`

Hiding an ActiveAdmin input enforces nothing — permitted params must be stripped
server-side for any non-admin.

Compensation figures must not leak into the corpus or MCP read surfaces.
`Stacks::PeopleCostAccounts` already matches `/management fee/i` and
`/intercompany/i`, so the financial outlook's spend categories exclude these
accounts. The privacy tripwire tests cover controller read paths; new admin
controllers must satisfy them.

## 11. Edge cases

| Case | Behaviour |
| --- | --- |
| Fee income row missing from P&L | Raise. Never treat as $0. |
| Fee income genuinely $0 | Cap $0 → all finals $0 → no true-ups generated. |
| Fewer than N earners | Average over available; flag `small_sample`. |
| Executive out-earns their tier target | True-up $0, no clawback, surfaced in admin. |
| Executive holds no role that month | Not in the pool, no true-up. |
| USB Club has no QBO customer | Created automatically on first draft. |
| garden3d flagged as a payer | Rejected by validation. |
| Rounding | `Σ final` must never exceed the cap; remainder to the largest line. |
| Re-running generation for a month | Idempotent — no duplicate trackers or true-ups. |
| Closed month recomputed | Snapshot governs; live recomputation never silently restates. |

## 12. Testing

Each subsystem's tests must fail before its implementation exists.

**S0** — migration backfill assigns Sanctuary to single-enterprise passes and
splits mixed ones; a pass cannot duplicate `[enterprise, start_of_month]`;
`clients_served` is enterprise-scoped; `make_trackers!` derives `qbo_account`
from the pass's enterprise; migration is reversible.

**S1** — `RowMissing` raised for an absent row, **and a separate test proving a
genuine $0 is distinguished from a miss** (this is the trap in §3.1); prefix
matching survives a label rename; draft carries item 2 and a $0 amount; customer
match is case-insensitive and finds inactive customers; customer created only on
a genuine miss; generation is idempotent; `all_paid?` is false when no
management-fee tracker exists.

**S2** — `full_months_only` rejects mid-month dates on both ends; overlapping
periods for one contributor rejected; MSO executives excluded from the pool;
`small_sample` set when the pool is short; Storext `mso_top_n` returning a String
is coerced; the extracted `QualifyingIncome` returns the same figures as the
previous inline `total_income` for a fixture ledger (regression lock).

**S3** — pro rata reduction arithmetic; `Σ final <= cap` including after
rounding; zero fee income; empty roster; zero benchmark; purity (no DB calls).

**S4** — netting excludes self (a test that fails if `excluding:` is dropped);
netting spans multiple ledgers; floor at zero; `payable?` false until all
invoices paid; `payable?` false until all peers accept; present in
`PayableQboBills`; doc number code `MT` round-trips through
`cleanup_orphaned_qbo_objects!`.

**Authorization** — a project lead (including a lead-in-training with scoped
grants) cannot read or write any MSO subject; an executive can read and accept
their own true-up but not another's, and cannot update or destroy their own.

Known local test constraints: run with
`--exclude "sync_meet runs the connector inside a SystemTask"` (live Google call,
can hang for over an hour), and avoid concurrent suite runs against the shared
test database.

## 13. Build sequencing

| Stage | Work | Depends on |
| --- | --- | --- |
| 1 | S0 — per-entity invoice passes | — |
| 2 | S1, S2, S3 in parallel | S0 merged (S3 only on pinned signatures) |
| 3 | S4 | S1, S3 |

File ownership, so agents never collide:

| Subsystem | Files |
| --- | --- |
| S0 | `app/models/invoice_pass.rb`, `app/admin/invoice_passes.rb`, pass/tracker migrations |
| S1 | `app/services/mso/management_fee_invoices.rb`, `app/services/mso/management_fee_income.rb`, `app/models/invoice_tracker.rb` (dispatch only), `app/models/enterprise.rb`, its migrations |
| S2 | `app/models/mso_role_period.rb`, `app/services/mso/benchmark.rb`, `app/models/ledger/qualifying_income.rb`, **sole owner of `app/models/ledger.rb`**, `app/models/contributor.rb`, its migration |
| S3 | `app/services/mso/compensation.rb` only |
| S4 | `app/models/mso_trueup.rb`, `app/services/money/payable_qbo_bills.rb`, `app/models/qbo_account.rb`, `app/models/admin_authorization.rb`, admin surfaces, its migration |

## 14. Out of scope

- Per-person cap reduction limits and residual tracking (§2.1)
- Routing contributor payouts away from Sanctuary (§2.1)
- Forecasting or scenario modelling — the workbook stays the planning tool
- Profit share in the benchmark; it remains excluded
- Trailing-month smoothing
- Automatic month-end triggering; passes stay admin-created
