# garden3d MSO Compensation — Design

**Date:** 2026-10-09 (rev 3, 2026-10-12)
**Status:** Approved. One external dependency: Finance must create garden3d's MSO
compensation account (§6.6).
**Branch:** `worktree-garden3d-mso`

## 1. Purpose

garden3d operates an MSO whose executives are compensated from the management fee
garden3d charges the operating companies. Five units:

1. Per-entity invoice passes (§5) — prerequisite refactor
2. Management-fee invoices and the fee-income basis (§6)
3. The MSO roster and Top-N benchmark (§7)
4. Tier multipliers and the cap (§8)
5. A true-up on the garden3d ledger (§9)

## 2. Source documents and resolved conflicts

| Source | Role |
| --- | --- |
| [MSO Compensation Plan](https://app.notion.com/p/garden3d/Garden3d-MSO-Compensation-Plan-3e3131fea2c780adbabbdc8551c23b5d) | What executives agree to. Authoritative on tiers, cap %, pro rata. |
| [MSO – Stacks](https://app.notion.com/p/garden3d/MSO-Stacks-3f4131fea2c7809f8ec4c4e5cdbc4334) (Paul) | Intended mechanics. Authoritative on the true-up and Top-N configurability. |
| `g3d - MSO 2026-2027 - Scenario Modeling.xlsx` | Confirms current-month benchmark, no smoothing. |

| Topic | Sources said | Decision |
| --- | --- | --- |
| Top N | Plan: 5. Paul: configurable, 3 now → 5 in 2027 | Configurable, default **3**. History via snapshot (§9.6). |
| Cap basis | Plan/Paul/workbook: Sanctuary fee only | **55% of garden3d's management fee income from MSO payers** (§6.3). |
| Fee source | Paul: read the invoice amount | **garden3d's P&L `4100 Management Fee Income`**, accrual. Invoice totals will carry loan repayment lines. |
| Smoothing | Superseded sheet used trailing-3-month | **Current month only.** |
| Per-person reduction limit | Workbook models 15% / $50k | **Out of scope.** |
| Compensation routing | Paul: route all MSO comp to garden3d | **Overridden.** Sanctuary payouts stay on the Sanctuary ledger; only the true-up goes to garden3d. |
| **What the cap constrains** | Nobody addressed it | **`Σ calculated`. The cap is a ceiling, not a budget** (§8.1). |
| Unused cap | — | **Not distributed.** Retained as garden3d profit. |
| Elevated service | — | MSO true-ups **count** toward elevated service (§9.7 #9). |
| Payer not charged | — | **Inferred**, no waiver concept (§6.4). |

### 2.1 Document amendments required (non-code)

1. "55% of the Sanctuary management fee" → garden3d's management fee income from
   all MSO payers.
2. "Sanctuary's five highest-earning contributors" → Top N is configurable,
   starting at 3.
3. State that an executive whose own earnings exceed their capped MSO
   compensation receives no true-up and no clawback, and that compensation they
   earned as a contributor is paid by the operating company out of project
   economics — it is not MSO compensation and does not count against the cap.

## 3. Verified facts

Confirmed against production. Do not re-derive by guessing.

**garden3d QBO realm `9130355602868216`**

| Thing | Value |
| --- | --- |
| Income account | `Management Fee Income`, id **5**. P&L row `"4100 Management Fee Income"`. |
| Service item | `Managerial Services`, id **2** → account 5. |
| Also posts to 5 | `Services`, id 1 (QBO default). Drafts pin item 2. |
| Customers | Sanctuary Computer Inc (**2**), Index Space LLC (**5**), Kevin Duncan Wall (55), Sample Customer (1). |
| Absent | **USB Club LLC**. |
| Terms | `Net 15`, id **2**, `due_days` 15 — matches `DEFAULT_PAYMENT_TERM`. No customer has `sales_term_ref` set. |
| Compensation account | **None exists.** Every garden3d concept maps to `"6100"` Platform Infrastructure. See §6.6. |

**Internal `ForecastClient`s:** Sanctuary Computer (607830), Index Space LLC
(1466083), USB Club (1858301), garden3d (1151929). These names differ from both
the `Enterprise` names and the QBO customer names — see §6.2.

**QBO account ids:** 1 = Index Space, 2 = Sanctuary, 35 = garden3d, 68 = USB Club.

**Fee actuals** (garden3d income == Sanctuary expense, accrual): 2026-06
$130,000 · 2026-07 $170,000 · 2026-08 $140,000. 100% currently from Sanctuary.
The jsonb value is a **String**.

**garden3d ledgers:** all 188 `qbo_bound`. `hugh@` (contributor 3, ledger 404),
`paul@` (contributor 120, ledger 458) both `qbo_bound`, `payment_methods ["qbo"]`.

**Invoice passes:** 64 passes, 1,165 trackers. Tracker-set histogram
`{[2] => 57, [2,35] => 7}`. All 7 mixed passes (ids 438/471/504/537/570/603/636,
2025-06 … 2025-12) have modal `qbo_account` 2 (Sanctuary) against exactly one
garden3d tracker each. No pass has zero trackers; no null `qbo_account_id`; no
null `start_of_month`. The §5.3 modal-enterprise backfill produces **zero
mis-assignments**.

### 3.1 Trap: `find_row` returns 0.0 on a label miss

`QboProfitAndLossReport#find_row` exact-matches with a `|| [nil, 0]` fallback in
**both** the block and non-block branches, then `.to_f`. garden3d's row is
`"4100 Management Fee Income"`; querying `"Management Fee Income"` returns `0.0`
where the real values are 130000/170000/140000.

- `find_row` is **unusable here** — it cannot distinguish a real $0 from a miss,
  and `.to_f` destroys the BigDecimal guarantee
- `Mso::ManagementFeeIncome` reads `data["accrual"]["rows"]` directly, matches
  `/\A4100\b/`, converts with `BigDecimal(str)`, and **raises** `RowMissing`
- A silent miss means a $0 cap and nobody paid, with no error

### 3.2 Trap: a $0 invoice reads as `:paid`

`QboInvoice#status` tests `balance == 0` before `balance == total`. Drafts are
written at $0.00, so an unedited sent draft is immediately `:paid`. A zero-total
invoice counts as **not collected** (§6.4).

### 3.3 Trap: `all_items_with_deleted` includes soft-deleted rows

`Ledger#items_grouped_by_month` sums over `all_items_with_deleted` deliberately,
for strikethrough rendering. Verified: contributor 595, April 2026 Sanctuary
ledger — `with_deleted` $10,300.00 vs live **$0.00**.

`Ledger::QualifyingIncome` reads **non-deleted rows only**. The display path keeps
its own with-deleted sum. One extraction cannot serve both (§7.2).

### 3.4 Trap: `ActsAsPeriod` does not reject future-dated overlaps

`period_ended_at` is `ended_at || Date.today`, so two open-ended periods both
collapse to today and `overlaps?` is false both ways. A promotion row validates
cleanly and then yields two `Line`s for one person. `MsoRolePeriod` must override
`period_ended_at` (§7.1).

### 3.5 Trap: `Qbo::BillRouter` silently misroutes unregistered hosts

`#concept_lines` falls to `else → :subcontractor` for anything that isn't a
`PayStub`, `ProfitShare` or `ContributorPayout`. `:subcontractor` is in
`FALLBACKABLE_CONCEPTS`, and garden3d's `subcontractor_by_studio` is `{}`, so it
resolves to `subcontractor_default "6100"` **without raising**. See §6.6.

### 3.6 Trap: `Enterprise.garden3d` is thread-memoized and has no fixture

`Enterprise.garden3d` is `Thread.current[:garden3d_enterprise] ||= find_by!(...)`.
`test/fixtures/enterprises.yml` has only `sanctuary`, `one`, `two`, so it raises
`RecordNotFound` in the suite today. This is the same hazard the codebase
documents for `System.instance`. Tests need a garden3d fixture (enterprise, QBO
account, ledgers) **and** must clear the thread memo between cases (§12).

## 4. Architecture

```
S0  Per-entity invoice passes  (own PR, merged and verified first)

S1  garden3d's management fee          S2  Roster + benchmark
    trackers on garden3d's pass        MsoRolePeriod
    Mso::ManagementFeeInvoices         Mso::Benchmark
    Mso::ManagementFeeIncome           Ledger::QualifyingIncome
                    \                 /
                     v               v
             S3  Mso::Compensation   (pure: no DB, no QBO, no clock)
                            |
                            v
             S4  MsoTrueup · MsoSnapshot · Mso::MonthlyRun
```

### 4.1 Seam contracts

| Contract | Owner | Signature |
| --- | --- | --- |
| Fee income | S1 | `Mso::ManagementFeeIncome.for_month(date) -> BigDecimal`. Raises `RowMissing`. |
| Variance | S1 | `Mso::ManagementFeeIncome.reconcile(date) -> { account_total:, payer_total:, variance: }` |
| Trackers | S1 | `Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass:) -> [InvoiceTracker]`. No QBO writes. |
| Push one | S1 | `Mso::ManagementFeeInvoices.push_invoice!(invoice_tracker:) -> QboInvoice`. Raises, never no-ops. |
| Collected | S1 | `InvoicePass#management_fee_collected? -> Boolean` (§6.4). **S1 owns this method**; S0 owns the file. |
| Benchmark | S2 | `Mso::Benchmark.for_month(date) -> Mso::Benchmark::Result` (§7.3) |
| Roster | S2 | `MsoRolePeriod.active_during(date) -> relation`; rows respond to `#tier_multiplier -> BigDecimal` |
| Qualifying income | S2 | `Ledger::QualifyingIncome.for(ledger:, month:, excluding: []) -> BigDecimal` (§7.2) |
| Compensation | S3 | `Mso::Compensation.call(benchmark_average:, lines:, fee_income:, cap_percentage:) -> Result` (§8) |
| Orchestration | S4 | `Mso::MonthlyRun.call(invoice_pass:) -> MsoSnapshot`. Takes **garden3d's** pass. |

## 5. Subsystem 0 — Per-entity invoice passes

### 5.1 Model

A pass belongs to the **issuing** enterprise. A tracker lives on the pass of its
`qbo_account`'s enterprise.

`clients_served` must **not** be scoped by enterprise: external clients have no
`enterprise_forecast_client`, so scoping that way strips the entire external book
off Sanctuary's pass. Forecast invoicing stays Sanctuary-only instead:
`make_trackers!` raises on any other enterprise's pass.

### 5.2 Schema

```ruby
# Step 1 — nullable
add_reference :invoice_passes, :enterprise, null: true, foreign_key: true

# Step 2 — backfill (§5.3)

# Step 3 — constrain
change_column_null :invoice_passes, :enterprise_id, false
change_column_null :invoice_passes, :start_of_month, false   # closes the NULL-dup hole
remove_index :invoice_passes, name: "index_invoice_passes_on_start_of_month"
add_index :invoice_passes, [:enterprise_id, :start_of_month], unique: true
```

No column distinguishes tracker kinds — the pass's enterprise does (§5.6).

### 5.3 Backfill

1. Each pass's enterprise = its modal `qbo_account`'s enterprise (Sanctuary when
   a pass has no trackers).
2. For every **other** distinct `qbo_account_id` on that pass, find or create that
   enterprise's pass for the same `start_of_month` and move those trackers.
   Generalised over `qbo_account_id` — not hardcoded to garden3d or to the 7 known
   dates, since production may gain Index/USB trackers.
3. Assert zero null `enterprise_id`, then constrain.

`down` re-merges non-Sanctuary passes for a month into the Sanctuary pass and
drops the created ones. Neither model has validations, callbacks or
`acts_as_paranoid`, so the backfill is safe; existing pass ids stay Sanctuary's,
so `Trueup.invoice_pass_id` is unaffected.

`db/schema.rb` is hand-curated — update it deliberately.

### 5.4 Call sites

| Site | Breakage | Fix |
| --- | --- | --- |
| `app/models/invoice_pass.rb:39-57` `make_trackers!` | **Worst item in S0.** Resolves `qa` from the *client's* billing enterprise and creates the tracker on `self`, so a garden3d-billed client still lands on Sanctuary's pass — violating §5.1 on the first daily run. | `make_trackers!` is Forecast-specific, so it raises unless the pass is Sanctuary's, and takes `qa` from the pass's own enterprise. (Every non-internal client bills through Sanctuary, so a per-client issuer check would be a constant.) |
| `app/admin/invoice_passes.rb:39-56` | **Catastrophic.** Two unconditional `action_item`s call `Stacks::Automator.attempt_invoicing_for_invoice_pass`, which runs `make_trackers!` then `make_invoice!` on every tracker. Clicking "Generate Invoices" on garden3d's pass would create trackers for Sanctuary's entire external book (new rows — the unique index is per-pass) and **push a second full set of real QBO invoices**, plus a second Twist thread. | Guard both actions: refuse unless the pass's enterprise supports forecast invoicing. |
| `lib/stacks/automator.rb:145-153` | `InvoicePass.create!` with no enterprise → `RecordInvalid`, raised at `lib/tasks/stacks.rake:588` inside the **single** `begin/rescue` of `stacks:daily_tasks`. Everything after stops: Runn, QBO, Deel, salary windows, every tracker/studio snapshot, notifications, task-cache warm. | Pass Sanctuary explicitly; scope the `find_by`. |
| `lib/stacks/system.rb:79` | Unordered `.where(start_of_month:).first` may pick garden3d's pass → `NoMethodError` on nil `max_by`, or a **duplicate** founder true-up (`Trueup` has no uniqueness validation). | Scope to Sanctuary. |
| `app/models/periodic_report.rb:58-63` | Unions every enterprise's trackers → `#surplus` widens company-wide. | Scope to Sanctuary. |
| `app/models/admin_authorization.rb:94-95` | `return true if subject.is_a?(InvoicePass)` grants leads-in-training read on garden3d's pass. | §10. |
| `app/services/mcp/get_invoice_passes_tool.rb:35-45` | Already groups by enterprise via `entity_block`, and the `mom` series already groups by month and sums — so only the `passes[]` array gains a second row per month. Informational, not a correctness bug. | Group or label by enterprise. 4 creations + ~17 shape assertions in `test/services/mcp/invoice_passes_tool_test.rb` need updating. |
| `app/admin/invoice_trackers.rb:101` | Tracker moves rewrite `/admin/invoice_passes/:id/invoice_trackers/:id` URLs used in Twist notifications. | Regenerate from the tracker's current pass. |
| `test/` | **32 saved constructions plus 4 `.new`** across 18 files build `InvoicePass` without an enterprise. | Update all. |

`lib/stacks/client_revenue.rb` is **safe** — `build_rows` drops internal clients
at line 100.

`make_trackers!` raises on a non-Sanctuary pass, so it can never produce a
management-fee tracker.

### 5.6 The discriminator is the pass's enterprise, not a column

An earlier revision gave `invoice_trackers` a `source` enum
(`forecast` / `management_fee`). **It was removed.** A tracker's behaviour is a
switch on its pass's issuing enterprise:

| Pass belongs to | Behaviour |
| --- | --- |
| Sanctuary | Forecast-driven (blueprint, contributor payouts, the existing pipeline) |
| garden3d | Management-fee stub to each `management_fee_payer` enterprise |
| anything else | **Unsupported — raise.** No such pass exists today. |

The column duplicated state the enterprise already determines, and nothing read
it. It is also redundant by construction: `ForecastClient#is_internal?` and "has
a non-Sanctuary `billing_enterprise`" are the **same** predicate (both reduce to
`enterprise_forecast_client` being present), so only Sanctuary can ever receive a
Forecast-driven tracker regardless.

S1 introduces the derived predicate where it is needed rather than carrying a
column:

```ruby
# InvoiceTracker
def garden3d?
  invoice_pass.enterprise == Enterprise.garden3d
end
```

Three sites consume it (§6.4, §6.5). A pass whose enterprise is neither Sanctuary
nor garden3d must raise rather than fall to an `else` — Index Space and USB Club
both have QBO accounts, so such a pass is constructible, and silently treating it
as one case or the other is how the wrong entity gets invoiced. If Index or USB
Club should ever issue their own invoices, that is a design decision, not a
default.

**Consequence for a future need:** if garden3d ever wants to Forecast-invoice its
own external client, its pass would hold both kinds of tracker and the
enterprise would stop being a sufficient discriminator. That is already blocked
today for an unrelated reason (mapping such a client via
`enterprise_forecast_clients` makes it `is_internal?`, so nothing invoices it at
all), and resolving it requires separating "internal client" from "billing
enterprise" first. Revisit the discriminator then, not before.

### 5.5 Risk

Refactors live financial machinery. Ships as its own PR, merged and verified
against a real month, before any MSO work lands on it.

## 6. Subsystem 1 — Management fee invoices and fee income

### 6.1 Payers

```ruby
add_column :enterprises, :management_fee_payer, :boolean, null: false, default: false
add_column :enterprises, :g3d_qbo_customer_id, :string
```

`management_fee_payer` true for Sanctuary, Index Space, USB Club. Validate
garden3d is never flagged.

### 6.2 Customer resolution — stored id, never by name

The three naming systems disagree, so name matching misses at least one payer and
creates a **duplicate customer** Finance then invoices for real:

| Enterprise | ForecastClient | QBO customer |
| --- | --- | --- |
| `Sanctuary Computer Inc` | `Sanctuary Computer` | `Sanctuary Computer Inc` (2) |
| `Index Space, LLC` | `Index Space LLC` | `Index Space LLC` (5) |
| `USB Club, LLC` | `USB Club` | *absent* |

`fetch_all_customers` wraps `Quickbooks::Service::Customer#all`, which returns
**active customers only** — "including inactive" is not available without new code.

`enterprises.g3d_qbo_customer_id` is seeded in the migration with the verified ids
(Sanctuary `"2"`, Index Space `"5"`). A customer is created **only** when the
column is blank, and the id persisted immediately. USB Club is the only creation.

### 6.3 Fee income

`Mso::ManagementFeeIncome.for_month(date) -> BigDecimal`

- garden3d's `QboProfitAndLossReport`, **accrual**
- Reads `data["accrual"]["rows"]` directly; matches `/\A4100\b/`; `BigDecimal(str)`
- Raises `RowMissing` on a miss — never `0.0`
- **Never force-refreshes.** `find_or_fetch_for_range(start, end, force, qa)` takes
  `force` **positionally** and does `existing.delete_all` then two live QBO
  fetches, destroying the cached row the dashboard,
  `Enterprise#generate_snapshot!` and two MCP tools read —
  `app/services/mcp/get_enterprise_health_tool.rb:101` warns against exactly this.
  Fetch only when no persisted row exists.

**Payer restriction.** Account 4100 is an account, not a payer set: garden3d has a
non-MSO customer (Kevin Duncan Wall) and the default item `Services` also posts to
account 5. A $30,000 unrelated advisory fee would silently raise the cap.
`reconcile(date)` compares the 4100 total against the month's management-fee
invoice totals, and `Mso::MonthlyRun` **raises on non-zero variance**.

`app/models/qbo_profit_and_loss_report.rb` is owned by **S1**.

### 6.4 Collection gate

`InvoicePass#management_fee_collected?` — called on **garden3d's** pass, where
every tracker is a management-fee tracker by construction (§5.6), so this reads
`invoice_trackers` directly with no filtering. True when **at least one** invoice
on the pass was sent, and **every sent one** is collected. Per the
inferred-waiver decision, an unsent draft means that payer was not charged and is
ignored.

Both naive forms fail:

- "every tracker is `:paid`" — `InvoiceTracker#status` returns `:impossible` for a
  blueprint-less tracker with an invoice (`invoice_tracker.rb:128-141`), so it can
  never be `:paid`. Read `tracker.qbo_invoice&.status` directly, or add a
  `garden3d?` branch to `InvoiceTracker#status`.
- gating on unsent drafts — Stacks drafts one per payer every month, so an
  uncharged payer's unsent $0 draft would block forever.

A **zero-total** sent invoice counts as not collected (§3.2).

Knock-on: `InvoicePass#statuses`, `#payout_statuses` (which would render
`1x No payouts` per management-fee tracker via `contributor_payouts_status`) and
`Mcp::GetInvoicePassesTool.entity_block` must all skip management-fee trackers —
equivalently, must skip every tracker on a garden3d pass.

### 6.5 Draft generation

Per payer: find or create an `InvoiceTracker` on **garden3d's** pass with
`forecast_client` = the payer's internal client and `qbo_account` = garden3d's
(idempotent on the existing `[forecast_client_id, invoice_pass_id]` index). Then
one QBO line: description `"Management fee"`, amount **$0.00**, `item_ref` =
`Managerial Services` (id 2, resolved by name, failing loudly if absent),
`txn_date` = end of the pass month, term `Net 15`.

Finance edits the amount in QBO and sends. Stacks never writes the amount.

`make_invoice!` dispatches to `push_invoice!` when `garden3d?`; its
internal-client `raise` (`invoice_tracker.rb:738`) applies only to the Forecast
path. `make_invoice!` does `return if configuration_errors.any?` — a **silent
no-op**; `push_invoice!` must raise instead. Blueprint, `configuration_errors`
and the payout pipeline skip management-fee trackers.

### 6.6 GL account — external dependency

garden3d's chart has **no** compensation account; `CONCEPT_GL_BY_ENTERPRISE[:garden3d]`
maps every concept to `"6100"` Platform Infrastructure. Finance is creating a
dedicated MSO compensation account.

Until its `acct_num` is known:

```ruby
FALLBACKABLE_CONCEPTS = %i[subcontractor bonuses commission].freeze  # unchanged —
                                                                      # mso_compensation NOT added
CONCEPT_GL_BY_ENTERPRISE[:garden3d][:mso_compensation] = "____"       # raises until pinned
```

`"____"` is the codebase's existing convention for "intentionally unmatched so it
raises rather than misroutes". `MsoTrueup` routes to `:mso_compensation`, which is
**not** fallbackable, so S4 cannot silently file executive compensation under
Platform Infrastructure. Pin the real `acct_num` when Finance confirms it; S4's
unit tests run before then, end-to-end QBO verification does not.

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
  def period_ended_at = ended_at || Date.new(9999, 12, 31)   # §3.4
end
```

- `started_at null: false` **plus** a presence validation. `MsoRolePeriod` does not
  override `period_started_at`, so a nil would raise `NoMethodError` inside
  `does_not_overlap` (`ProjectLeadPeriod` survives nulls only because it *does*
  override), and a nil start would make the executive active for all history.
- The `period_ended_at` sentinel correctly rejects two open-ended periods while
  still accepting a closed period followed by a later open one. `current?` is
  behaviourally unchanged; `time_held_in_days` has **zero callers** today — do not
  render it in a new admin view without revisiting.
- `full_months_only` copied verbatim from `ProjectLeadPeriod`.
- `active_during(date)` is **new raw SQL**; `ActsAsPeriod` has no such scope, and
  building on `period_ended_at` would reintroduce the `Date.today` collapse.

### 7.2 Qualifying income

`Ledger::QualifyingIncome.for(ledger:, month:, excluding: []) -> BigDecimal`

```ruby
KLASSES = [ContributorPayout, Trueup, PayStub, MsoTrueup].freeze
```

- **Non-deleted rows only** (§3.3). Not an extraction of `items_grouped_by_month`,
  which reads `all_items_with_deleted` by design.
- `month:` takes a `Date`; rows bucket on `effective_on_for_display`. Verified
  safe: `ContributorPayout` returns the pass's `start_of_month`, `Trueup` returns
  `start_of_month.end_of_month` — different days, same bucket.
- `excluding:` matches `[class, id]` pairs.
- `BigDecimal(amount.to_s)`, never `to_f`.
- `items_grouped_by_month` keeps its own Float sum, but **does** gain `MsoTrueup`
  in its class list — otherwise an executive's ledger renders the true-up row
  while contributing $0 to that month's income total. A test asserts the two
  paths differ exactly by soft-deleted rows.

### 7.3 Benchmark

```ruby
Result = Struct.new(:average, :configured_n, :counted, :members, :small_sample,
                    keyword_init: true)
# average BigDecimal · configured_n Integer (the setting) · counted Integer
# (actually averaged) · members [{contributor_id:, amount:}] · small_sample Boolean
```

Pool, in order:

1. All contributors — **not** "those with a Sanctuary ledger", which is vacuous
   since `Ledger.ensure_all!` creates every (enterprise, contributor) pair.
2. Require an `admin_user` behind the contributor. Commission-only payouts to
   outside entities auto-accept with no `admin_user`
   (`invoice_tracker.rb:567-579`) and are plain `ContributorPayout`s. Verified:
   contributor 628 (`enquiries@aufi.com`) held a **$21,024.90** referral at #3 in
   May 2026 — +$1,359.90 on the top-3 average, ~$41.6k/yr across a 2.55 roster.
3. Exclude anyone with an `MsoRolePeriod` overlapping the month **and** anyone who
   has *ever* held one, so a departed executive cannot set their former peers'
   benchmark.
4. Score by `Ledger::QualifyingIncome` on the Sanctuary ledger; drop zero and
   negative.
5. Top N by income, averaged. Fewer than N → average over what exists, set
   `small_sample`. Never divide by N.

Top N is `System.first.mso_top_n` (Storext Integer, default 3) read through
`mso_top_n_clamped`, which coerces to Integer and clamps to `[1, ..]`, mirroring
`ghost_sweep_write_budget_clamped` — Storext returns Strings for Integer
attributes. Use `System.first`, not the memoized `System.instance`.
`app/models/system.rb` is owned by **S2**.

Current month only. No smoothing.

## 8. Subsystem 3 — Compensation calculator

Pure: no database, no QBO, no clock.

```ruby
Line   = Struct.new(:key, :multiplier, :already_earned, keyword_init: true)
Output = Struct.new(:key, :calculated, :final, :reduction, :trueup, keyword_init: true)
Result = Struct.new(:outputs, :cap, :total_calculated, :total_trueup, keyword_init: true)
```

`cap_percentage` is a **BigDecimal fraction** (`0.55`), not `55` — passing `55`
yields a cap 100× too large and no relative test would catch it. From
`Mso::Compensation::DEFAULT_CAP_PERCENTAGE`.

### 8.1 Algorithm — the cap is a ceiling, not a budget

```
calculated_i = benchmark_average * multiplier_i
cap          = cap_percentage * fee_income
total        = Σ calculated_i

if total > cap && total > 0
  final_i     = calculated_i * (cap / total)
  reduction_i = calculated_i - final_i
else
  final_i     = calculated_i
  reduction_i = 0
end

trueup_i = max(0, final_i - already_earned_i)
```

Single pass. No reallocation, no iteration.

**Unused cap is not distributed** — it is retained as garden3d profit. An
executive whose own earnings exceed their capped `final` receives no true-up and
no clawback, and their share of the cap is not reassigned. This is deliberate:
compensation earned as a contributor is paid by the operating company out of
project economics and never touches the management fee, so it is not MSO
compensation and does not count against the cap.

An earlier iterative-reallocation design was rejected: its re-fixing step made the
fixed total ratchet monotonically toward `Σ earned`, so it paid **every executive
$0** whenever `Σ earned > cap` — precisely the case it was written to solve.

### 8.2 Rounding

Largest-remainder (Hare), applied in **both** branches:

- Round each `final_i` down to cents, then distribute remaining cents by
  descending fractional part
- "Remainder to the largest line" was wrong twice: in the uncapped branch it would
  inflate the top earner until the total reached the cap, and it biases the same
  highest-tier executive every month
- The uncapped branch still needs correction — with `benchmark_average`
  18,333.6666…, naive rounding totals one cent above a cap of exactly 52,250.95
  while `total > cap` is false

Invariant: `Σ final <= cap` in every branch. (`Σ trueup` is necessarily ≤ that.)

### 8.3 Boundaries

`fee_income == 0` → cap 0 → all finals and true-ups 0. Empty `lines` → empty
result. `benchmark_average == 0` → all zeros. `total > 0` guards the division.

## 9. Subsystem 4 — True-up and orchestration

### 9.1 Schema

```ruby
create_table :mso_snapshots do |t|
  t.references :invoice_pass, null: false, foreign_key: true
  t.decimal :fee_income,        null: false, precision: 12, scale: 2
  t.decimal :benchmark_average, null: false, precision: 12, scale: 2
  t.integer :configured_n,      null: false
  t.integer :counted,           null: false
  t.decimal :cap_percentage,    null: false, precision: 5,  scale: 4
  t.decimal :cap,               null: false, precision: 12, scale: 2
  t.decimal :total_calculated,  null: false, precision: 12, scale: 2
  t.jsonb   :lines,             null: false, default: {}
  t.datetime :superseded_at
  t.references :superseded_by, foreign_key: { to_table: :mso_snapshots }
  t.timestamps
end

create_table :mso_trueups do |t|
  t.references :ledger,       null: false, foreign_key: true
  t.references :invoice_pass, null: false, foreign_key: true
  t.references :mso_snapshot, null: false, foreign_key: true
  t.references :mso_role_period, null: false, foreign_key: true
  t.decimal  :amount, null: false, precision: 12, scale: 2
  t.text     :description, null: false
  t.datetime :accepted_at
  t.string   :qbo_bill_id
  t.datetime :deleted_at
  t.timestamps
  t.index [:ledger_id, :invoice_pass_id], unique: true, where: "deleted_at IS NULL"
end
```

- The unique index is **partial on `deleted_at IS NULL`** — with `acts_as_paranoid`
  a total index would let one soft-deleted row block regeneration forever.
  Generation restores a soft-deleted row rather than inserting.
- `accepted_at` is **not** inherited: `Trueup` has no such column and `LedgerItem`
  defines only `payable?`.
- Per-line figures (`calculated`, `reduction`, `final`, `already_earned`) live in
  the snapshot's immutable `lines` jsonb, keyed by `mso_role_period_id` — **not**
  on `mso_trueups`, so a superseded snapshot keeps its own figures when a recompute
  repoints the true-up. `InvoicePass has_many :mso_snapshots` (supersede means
  several per pass) plus a `current` scope of `where(superseded_at: nil)`.

### 9.2 Required methods

| Method | Returns / why |
| --- | --- |
| `bill_txn_date` | `invoice_pass.start_of_month.end_of_month`. `SyncsAsQboBill` contract. |
| `bill_description` | Admin URL, as `Trueup`. Also feeds `Qbo::BillRouter#single_line`. |
| `bill_doc_number_code` | `"MT"` — verified free against the `case` at `qbo_account.rb:252-275`. |
| `payment_date` | `invoice_pass.start_of_month.end_of_month`. Called on `Trueup` by `Contributor#aggregated_new_deal_balance`. |
| `effective_on_for_display` | **Must be `payment_date`**, matching `Trueup`. If it returned `created_at.to_date`, a recompute in a later month would bucket into the wrong month and last month's true-up would count as this month's earned income. |
| `accepted?` | `accepted_at.present?`. |
| `before_destroy :detach_and_destroy_qbo_bill` | As `PayStub`/`Reimbursement`; otherwise a destroyed row orphans its QBO bill. |

Do **not** copy `Trueup#payable?`, which is hardcoded `true`. Note include order:
`SyncsAsQboBill#payable?` returns `false`, `LedgerItem`'s default is
`accepted_at.present?` — define `payable?` explicitly (§9.4).

### 9.3 Amount

```
trueup_i         = Mso::Compensation output for this role period
already_earned_i = Σ Ledger::QualifyingIncome across ALL the executive's ledgers
                   for the month, excluding this MsoTrueup
```

`excluding: [self]` suffices — an `MsoTrueup` lives on one ledger, and the partial
unique index plus `[enterprise_id, start_of_month]` guarantee one per executive per
month, so no prior month's leaks in. Without it the true-up nets against itself and
converges to zero, since `MsoTrueup` is in `KLASSES`. No cross-executive path
exists: `QualifyingIncome` is ledger-anchored, and §7.3 step 3 removes role-holders
from the pool.

Floors at `$0` — no clawback. The admin surface reads the uncapped figures from the
snapshot's `lines`.

### 9.4 Payability

```ruby
def payable?
  accepted? &&
    invoice_pass.management_fee_collected? &&
    mso_snapshot.all_expected_trueups_accepted?
end
```

`all?` over **existing rows** is unsafe: a generation that fails partway creates
two of three, both accept, `all?` is true for 2 of 2, and both pay at two-person
figures — permanently over cap once the third lands ($63,366.34 against a $56,000
cap). The gate asserts one accepted true-up per role period the snapshot recorded.

No early-release escape hatch ships now (§14); Finance will likely ask for one.

### 9.5 Orchestration

`Mso::MonthlyRun.call(invoice_pass:)` takes **garden3d's** pass for the month, and
creates it if absent (nothing else does — S0 scopes
`attempt_invoicing_for_previous_month` to Sanctuary). Wrapped in a transaction:

1. Require the Sanctuary pass for the same month to exist, be `complete?`, and have
   **at least one** contributor payout.
2. `reconcile` — raise on variance (§6.3).
3. Read fee income **once**, before the loop, so `RowMissing` leaves no partial
   state.
4. Benchmark, roster, `Mso::Compensation`.
5. Write one `MsoSnapshot` and one `MsoTrueup` per active role period.

**Why not "all Sanctuary payouts accepted":** verified live, 4 of the last 8 passes
have unaccepted payouts (2026-09 has **13**), usually one person who never clicked
Accept. With no override (§14) that would freeze all executives' compensation
indefinitely. Conversely a pass whose payouts were never generated has
`contributor_payouts == []` and would pass vacuously — hence the ≥1 requirement.

Note `completed_at` is stamped by `attempt_invoicing_for_invoice_pass`
(`automator.rb:87`) immediately after `make_invoice!`, **before** any payout
exists. It certifies "invoices generated", not "payouts final" — which is why
drift is handled by recompute, not by the gate.

**Idempotency is by recomputation, not find-or-create.** `ContributorPayout#amount`
is mutated by re-runs of `make_contributor_payouts!`
(`invoice_tracker.rb:530-544`) and surplus chunks land only after the QBO invoice
exists, so a run before that freezes a too-high true-up (a chief computed at
$25,942.59 against $0 earned, when $5,620 arrives a week later, **overpays
$5,620** if never revisited). Re-running supersedes the snapshot and updates any
true-up not yet paid; it refuses to alter one whose QBO bill has payments, and
surfaces that as drift for a human.

QBO invoice pushes (§6.5) are **not** transactional with the database and stay
outside this transaction.

### 9.6 Snapshot

A dedicated table, **not** jsonb on the pass: `InvoicePass` is unconditionally
readable by leads-in-training (`admin_authorization.rb:94-95`), so storing fee
income, benchmark, cap and per-executive figures there would publish the whole
compensation picture.

A recompute **supersedes**: the prior row is stamped `superseded_at` and linked via
`superseded_by_id`, retaining its own immutable `lines`. Write-once primacy locks
in stale overpayments; a supersede chain keeps the audit trail without freezing an
error.

### 9.7 Registration points

Eleven. Each is a distinct production bug.

| # | Edit | Failure if skipped |
| --- | --- | --- |
| 1 | `Money::PayableQboBills::HOST_KLASSES` | never payable |
| 2 | detach list in `QboAccount#sync_all_bills!` (`qbo_account.rb:239-245`) | dangling `qbo_bill_id`; "Sync to QBO" duplicates |
| 3 | `when "MT"` arm in `cleanup_orphaned_qbo_objects!` (`qbo_account.rb:252-275`) | falls to `klass = nil` and the last-defence path. The requirement is the `when` arm, not merely a unique code. |
| 4 | `Qbo::BillRouter#concept_lines` → `:mso_compensation` (§6.6) | silently posts to `6100` Platform Infrastructure (§3.5) |
| 5 | `Money::QboBillSummary::PRELOADS` | §9.4's `payable?` hits `invoice_pass` and the snapshot per row — N+1 on a page with documented 4s renders |
| 6 | `ledger_item_path` case, `app/views/admin/money/payable_qbo_bills.html.erb:20-28` | no `else`; nil path |
| 7 | `Ledger`: `has_many :mso_trueups`, `visible_items`, `all_items_with_deleted`, **and `items_grouped_by_month`'s class list** (§7.2) | never affects `balance`/`unsettled`, never renders, or renders with $0 income |
| 8 | `Contributor`: seven `*_with_deleted` readers, `preload_for_ledger_view!`, `aggregated_new_deal_balance` | same |
| 9 | `app/models/periodic_report.rb:206` `elevated_service?` | MSO compensation would not count toward elevated service. **Decision: it counts.** |
| 10 | A nag discovery for unaccepted true-ups, alongside `discoveries/unaccepted_payouts.rb` | §9.4 makes everyone's payment contingent on unanimous acceptance with nothing prompting anyone |
| 11 | The doc-code registry comment at `syncs_as_qbo_bill.rb:109-111` | the next host model collides on `"MT"` |

Plus the four `is_a?(Trueup)` branches in
`app/views/admin/contributors/_show.html.erb:142,198,290,336`.

## 10. Authorization and privacy

`AdminAuthorization#authorized?` has a blanket
`return true if (user.is_admin? || user.can_act_as_lead?)` at line 84.

- Guarding only `[:create, :update, :destroy]` lets `:read` fall through, so
  **every full lead reads executive compensation**
- Adding `MsoTrueup` to `OWN_LEDGER_ITEM_CLASSES` does nothing for leads — that
  list is consulted at lines 113-127, **below** line 84
- Worse, that list grants `[:index, :new, :create]` to any user with a contributor
  record, and `scope_collection` returns the **unnarrowed** collection when
  `scoped_ids` is empty — so every contributor could list every executive's
  true-up amounts, and a `:create` grant would let one write themselves a $50,000
  true-up, accept it (`all?` over one row is true) and have it paid

One **combined guard above line 84**:

```ruby
if [MsoTrueup, MsoRolePeriod, MsoSnapshot].any? { |k| subject == k || subject.is_a?(k) }
  return true if user.is_admin?
  return own_mso_trueup_read_or_accept?(subject, action)
  # everything else, :index/:new/:create included, is false
end
```

Plus:

- `scope_collection` branches for all three models — the `case` falls through to
  `else → collection` for unknown models
- `actions :index, :show` pinned on the admin resources (how `app/admin/trueups.rb`
  and `pay_stubs.rb` are safe today), and `MsoTrueup` **not** in
  `OWN_LEDGER_ITEM_CLASSES`
- An `InvoicePass` enterprise check above line 84, since
  `return true if subject.is_a?(InvoicePass)` grants leads-in-training read on
  garden3d's pass. `test/models/admin_authorization_test.rb:43` asserts
  **class-level** `:read` on `InvoicePass` — keep that true while restricting
  instances. (`app/admin/invoice_passes.rb:7` already pins `actions :index, :show`
  and line 3 sets `config.filters = false`, so no permit-params or filter work is
  needed there.)
- Non-admin permitted params stripped server-side — hiding an ActiveAdmin input
  enforces nothing

**MCP leak.** `Mcp::ListPayableBillsTool` emits `vendor`, `doc_number`, `total`
and `remaining_balance` per bill (`list_payable_bills_tool.rb:65-73`) with no MSO
exclusion; `doc_number` would read `Stacks_<id>_MT`. It must exclude `MsoTrueup`.
`Stacks::PeopleCostAccounts` does not help — its regexes gate the spend side only,
and management fee *income* still flows through `find_rows(..., ["Total Income"])`.

**Correction:** `test/integration/privacy_wall_test.rb` tests
`Document.corpus_eligible` and MCP tools; its only controller assertion (line 127)
checks that no API controller touches **corpus** data. It cannot see ActiveAdmin
resources and knows nothing about compensation. No existing test protects these
surfaces.

## 11. Edge cases

| Case | Behaviour |
| --- | --- |
| P&L row missing | Raise `RowMissing`. Never $0. |
| Fee income $0 | Cap 0 → no true-ups. |
| 4100 holds non-MSO fees | `reconcile` variance → raise. |
| Fewer than N earners | Average over available; `small_sample`. |
| Non-contributor in pool | Excluded — no `admin_user`. |
| Former executive in pool | Excluded — ever held a role. |
| Executive out-earns target | True-up $0, no clawback, cap share **not** reassigned (§8.1). |
| Future-dated promotion | Rejected as overlapping (§3.4). |
| Nil `started_at` | Rejected by `null: false` + validation. |
| Two lines for one contributor | **Possible.** One period per contributor per month is a model validation only, and `Mso::Compensation` checks only that line keys are unique. `Mso::MonthlyRun` (S4) must assert one active role period per `contributor_id` and refuse to run otherwise. |
| USB Club has no QBO customer | Created once; id persisted. |
| garden3d flagged as payer | Rejected by validation. |
| Payer not charged | Unsent draft ignored; gate reads sent invoices only. |
| $0 invoice sent | Not collected (§3.2). |
| Partial generation | Transactional; gate asserts one per active role period. |
| Sanctuary pass absent/incomplete/no payouts | Run refused (§9.5). |
| Payout amount changes after the run | Recompute supersedes; paid rows refused and surfaced as drift. |
| Soft-deleted payout | Excluded from qualifying income (§3.3). |
| Soft-deleted true-up | Partial unique index allows regeneration; restored, not duplicated. |
| garden3d pass missing | `Mso::MonthlyRun` creates it. |
| "Generate Invoices" clicked on garden3d's pass | Refused (§5.4). |
| Non-`qbo_bound` garden3d ledger | All 188 are `qbo_bound` today; a `legacy` one makes a true-up invisible on the Money page — assert and surface. |
| MSO comp unmapped in `BillRouter` | Raises (`"____"`, non-fallbackable). |
| Rounding | Largest-remainder in both branches; `Σ final <= cap` always. |

## 12. Testing

Each test must fail before its implementation exists.

Migrations never run in the suite — `db/schema.rb` is hand-curated and the test DB
is schema-loaded. Backfill tests instantiate the migration class explicitly against
a pre-constraint fixture state.

Tests touching garden3d need **new fixtures** (enterprise, `QboAccount`, ledgers)
and must clear `Thread.current[:garden3d_enterprise]` between cases (§3.6).

**S0** — backfill assigns the modal enterprise and splits mixed passes generically
over `qbo_account_id`; reversible; `[enterprise, start_of_month]` uniqueness;
existing 1,165 trackers read `:forecast`; **`attempt_invoicing_for_previous_month`
succeeds and targets Sanctuary** (the `daily_tasks` blast radius);
`make_trackers!` on garden3d's pass creates **zero** trackers; the admin
"Generate Invoices" actions refuse on a non-forecast pass; `sync_founder_trueups!`
writes exactly one founder true-up with two passes present; `PeriodicReport`
surplus unchanged; `clients_served` unchanged.

**S1** — `RowMissing` on an absent row **and** a separate test distinguishing a
genuine $0 from a miss; prefix match survives a label rename; no force-refresh
(note `force` is **positional**, so assert on the positional call);
`reconcile` raises on variance; customer resolved by stored id, created only when
blank, id persisted; draft carries item 2 and $0; generation idempotent;
`management_fee_collected?` false when nothing was sent, false for a $0 sent
invoice, true when every sent one is collected, and ignores unsent drafts;
garden3d rejected as payer; `push_invoice!` raises rather than no-ops.

**S2** — `full_months_only` rejects mid-month on both ends; nil `started_at`
rejected; **two open-ended periods rejected**; `active_during` returns a
future-dated period only for its own months; non-`admin_user` contributors
excluded (regression on contributor 628's $21,024.90); former executives excluded;
soft-deleted payouts excluded (regression on contributor 595's $10,300);
`small_sample`; `mso_top_n` as a String coerced and clamped;
`items_grouped_by_month` includes `MsoTrueup` and differs from
`QualifyingIncome` exactly by soft-deleted rows.

**S3** — pro rata reduction; `Σ final <= cap` in both branches including after
rounding; largest-remainder distribution; uncapped branch leaves each line at its
own rounded value; unused cap is **not** redistributed when a line's true-up floors
at zero; `cap_percentage` of `0.55` yields `0.55 * fee_income`; zero fee income;
empty lines; zero benchmark; purity (no DB, no clock).

**S4** — netting excludes self (fails if `excluding:` is dropped); netting spans
multiple ledgers; floors at zero; `effective_on_for_display` equals
`payment_date` so a recompute buckets into the original month; `payable?` false
until collected; `payable?` false until **every expected** true-up is accepted;
present in `PayableQboBills`; `"MT"` round-trips through
`cleanup_orphaned_qbo_objects!`; **`Qbo::BillRouter` raises for `MsoTrueup` while
`:mso_compensation` is `"____"`** (and maps to the real account once pinned);
`ledger_item_path` resolves; appears in `Ledger#balance` and in
`items_grouped_by_month`'s income total; counts toward
`PeriodicReport#elevated_service?`; run refused when the Sanctuary pass is absent,
incomplete, or has no payouts; recompute supersedes, retains the prior snapshot's
`lines`, and refuses paid rows; one true-up per role period; soft-deleted true-up
regenerates; the nag discovery surfaces unaccepted true-ups.

**Authorization** — a full lead cannot `:read` any MSO subject; a plain contributor
cannot `:index` `MsoTrueup`; cannot `:create` one; an executive can `:read` and
accept their own but not another's, and cannot `:update`/`:destroy` their own;
class-level `:read` on `InvoicePass` still passes while leads-in-training cannot
read garden3d's instance; `Mcp::ListPayableBillsTool` omits `MsoTrueup`.

Local constraints: run with
`--exclude "sync_meet runs the connector inside a SystemTask"` (live Google call,
can hang for over an hour); no concurrent suite runs against the shared test DB.

## 13. Build sequencing and ownership

| Stage | Work | Depends on |
| --- | --- | --- |
| 1 | S0 — per-entity passes (own PR, merged and verified) | — |
| 2 | S1, S2, S3 in parallel | S0 (S3 on pinned signatures only) |
| 3 | S4 | S1, S2, S3 |

S4 depends on **S2** as well as S1 and S3 — it consumes `Ledger::QualifyingIncome`,
`MsoRolePeriod.active_during` and `Mso::Benchmark.for_month`.

| Subsystem | Files |
| --- | --- |
| S0 | `app/models/invoice_pass.rb`, `app/models/invoice_tracker.rb` (enum, `status`, `make_trackers!` routing), `app/admin/invoice_passes.rb`, `app/admin/invoice_trackers.rb`, `lib/stacks/automator.rb`, `lib/stacks/system.rb`, `app/models/periodic_report.rb`, `app/services/mcp/get_invoice_passes_tool.rb`, pass/tracker migrations, affected tests |
| S1 | `app/services/mso/management_fee_invoices.rb`, `app/services/mso/management_fee_income.rb`, `app/models/qbo_profit_and_loss_report.rb`, `app/models/enterprise.rb`, `app/models/invoice_tracker.rb` (`make_invoice!` dispatch), `app/models/invoice_pass.rb` (`management_fee_collected?`), its migrations |
| S2 | `app/models/mso_role_period.rb`, `app/services/mso/benchmark.rb`, `app/models/ledger/qualifying_income.rb`, `app/models/system.rb`, its migration |
| S3 | `app/services/mso/compensation.rb` only |
| S4 | `app/models/mso_trueup.rb`, `app/models/mso_snapshot.rb`, `app/services/mso/monthly_run.rb`, `app/models/ledger.rb`, `app/models/contributor.rb`, `app/models/periodic_report.rb`, `app/services/money/payable_qbo_bills.rb`, `app/services/money/qbo_bill_summary.rb`, `app/services/qbo/bill_router.rb`, `app/models/qbo_account.rb`, `app/models/admin_authorization.rb`, `app/models/concerns/syncs_as_qbo_bill.rb`, `app/services/mcp/list_payable_bills_tool.rb`, `lib/stacks/task_builder/discoveries/`, `app/views/admin/money/payable_qbo_bills.html.erb`, `app/views/admin/contributors/_show.html.erb`, admin surfaces, its migrations |

**No "land registrations up front" protocol.** An earlier revision had S2/S0 add
`MsoTrueup` to `Ledger#visible_items`, `all_items_with_deleted` and
`QualifyingIncome::KLASSES` before the model existed. That cannot run:
`visible_items` would raise `relation "mso_trueups" does not exist` on **every**
`Ledger#balance` call, and `KLASSES` resolves the constant at class-body
evaluation, failing at load. Since **S4 runs alone at stage 3**, there is no
concurrency to protect against — S4 owns those edits sequentially, including
`MsoTrueup` in `QualifyingIncome::KLASSES` (S2 ships `KLASSES` without it).

`S1` and `S0` both touch `app/models/invoice_tracker.rb` and
`app/models/invoice_pass.rb`, sequenced across stages 1 and 2, never concurrent.

## 13a. As built — S2 and S3

S2 (roster, benchmark) and S3 (calculator) are built. Where the code differs
from §7, §8, §10 and §12 above, **this section governs**; those sections are
left as the record of the design.

**Calculator (§8)**

- Finals respect the cap **floored to cents** (`payable_cap`). 55% of a fee is
  rarely a whole number of cents, so `Σ final <= cap` is otherwise unachievable.
- Over the cap, lines are allocated by largest remainder to exactly that
  ceiling. Under the cap each line is rounded on its own; largest remainder is
  used only if rounding up would cross the ceiling.
- Negative benchmark, fee income, cap percentage or multiplier raise
  `ArgumentError`. Negative `already_earned` is treated as zero, so a true-up
  never exceeds the final. `reduction` is floored at zero.
- Line keys must be unique. Ties for the odd cent break numerically on numeric
  keys.

**Roster (§7.1, §10)**

- No `BustsTaskCache`. The tier enum is `_prefix: :tier`; `tier` is validated.
- `sibling_periods` queries fresh — going through `contributor.mso_role_periods`
  cached an empty list and let overlapping periods save.
- `Contributor has_many :mso_role_periods, dependent: :restrict_with_error`.
- The roster page allows create, edit and destroy and is admin-only for every
  action through one guard line above the blanket lead grant. No
  `scope_collection` branch is needed: non-admins fail `authorized?` first.
- One period per contributor per month is **not** enforced by the database.
  An exclusion constraint (`btree_gist` is enabled) is a follow-up; the
  hand-kept `schema.rb` cannot represent one.

**Qualifying income (§7.2, §4.1)**

- Signature: `Ledger::QualifyingIncome.for(ledger:, month:, excluding: [], klasses: KLASSES)`.
- **Qualifying income is anything that is payment for doing work** (decided
  2026-10-12, replacing §7.2's narrower list): payouts, pay stubs, profit
  shares, true-ups and **positive** contributor adjustments (recruiting fees,
  advances). S4 adds `MsoTrueup`.
- **Not counted:** reimbursements, Deel invoice adjustments, and **negative**
  contributor adjustments. On production 389 of the 398 adjustments are
  negative (−$2.95M, June 2025 – June 2026): the old ledger style's record
  of money paid out, mirrored from QuickBooks so a balance read
  earned-minus-paid. They are not pay cuts; counting them would subtract what
  people were paid from what they earned.
- An advance counts in the month it is given. If one is ever recovered by
  reducing a later payout, that month would need looking at; today recovery
  is expected to happen through QuickBooks, not through payouts.
- `Ledger#items_grouped_by_month` is untouched.
- A live row whose parent has gone missing raises rather than being skipped:
  silently dropping income would enlarge someone's true-up.

**Benchmark (§7.3)**

- Counts all qualifying income **except true-ups** (`Mso::Benchmark::KLASSES`).
  Every live true-up is the monthly founder top-up, which mirrors the highest
  earner; left in, it lifts the top-3 average by 4–22%.
- Having no login is a proxy for "outside party" and also leaves out ordinary
  contractors, so `Result` gains `excluded_without_login` listing anyone it
  removed who would have ranked or tied.
- "Ever held a role" means a role period starting on or before the month's end.
- Reads the Sanctuary ledger only. Top N comes from `System.mso_top_n`
  (default 3), which has no admin form: `System.first.update!(mso_top_n: 5)`.
- It is a live calculation. A backdated roster edit or a re-run payout changes
  a past month's answer, so S4 must store the members and the unrounded average
  it used (`average.to_s`, not a two-decimal column).
- Verified on production data. Counting payouts and pay stubs alone, top-3
  averages for May–July 2026 match the finance workbook to the dollar and
  May–September match an independent SQL recomputation on every id and
  amount. Adding profit shares and positive adjustments moves three months:
  March 2026 $23,216.96 → $25,345.22 and April $25,942.59 → $27,942.59
  (recruiting fees paid to a top-three earner), and June $21,447.73 →
  $21,534.30 (profit shares). **The workbook leaves those out**, so it no
  longer matches for March and April.

**Open questions these raise for S4**

- **Answered:** the founder true-up is replaced by a Principal-level MSO
  payout. S4 must stop `sync_founder_trueups!` writing one for any month the
  founder holds an MSO role.
- **Answered:** outside referral fees must not count, and the no-login rule
  is how — referral partners are not given Stacks logins.

## 13b. As built — S1

S1 (management fee invoices, fee income) is built. Where the code differs from
§3, §4.1 and §6 above, **this section governs**. The plan,
`docs/superpowers/plans/2026-10-13-mso-management-fee-invoices.md`, holds the
full decision list; note its Task 5 and Task 9 listings predate the final-review
fixes below.

**Corrections to the design**

- garden3d's passes are **not** all management-fee trackers. Seven legacy passes
  (2025-06 … 2025-12) hold Forecast trackers with blueprints. A management fee
  invoice tracker is "on garden3d's pass **and** has no blueprint"
  (`InvoiceTracker#intercompany_invoice?`); legacy passes behave as before and
  can never be drafted or extended.
- A garden3d enterprise fixture exists (contrary to §3.6); there is no garden3d
  `QboAccount` fixture, so tests create one.
- A payer can have several internal Forecast clients (Sanctuary has five); the
  tracker uses the lowest id.
- **Invoice lookups never cross QuickBooks accounts.** Mirrors were matched on
  `qbo_id` alone; garden3d's are the first second-realm rows, and ids collide
  with Sanctuary's.

**Drafting**

- Nothing scheduled writes to QuickBooks. The nightly job creates garden3d's
  previous-month pass and trackers, and catches up any earlier month since the
  start month that has none, looking back twelve months at most (database
  only); the write is an admin click.
- `MANAGEMENT_FEE_START = 2026-08-01`, the owner's decision: the first billing
  month is August 2026. Earlier months are never drafted: fee invoices were
  made by hand for nearly every month from 2024-01.
- August, September and October 2026 were also invoiced by hand, before this
  shipped. They are draftable, and the click is how their invoices reach
  Stacks: the pre-flight below refuses per payer and mirrors what it found,
  and an admin attaches each one.
- Before writing, the push reads QuickBooks for an invoice to that customer
  dated in the month. If one exists it refuses, and records what it found as
  mirror rows so the invoice can be attached from the tracker's edit page.
- A customer is created only when the stored id is blank **and** no active
  customer has the payer's exact name; otherwise it raises naming the id.
- `ensure_month!(date)` creates a pass and trackers for attaching hand-made
  invoices; it refuses legacy months. An admin reaches it from Money →
  Invoicing ("Open garden3d month"); it is database only.

**Collection gate (§6.4 replaced)**

- An invoice is **charged** when it is sent **or** its total is above zero. It is
  ignored only when unsent and zero, or voided (note says voided **and** total
  and balance are zero).
- Collected = at least one attached invoice is charged, and every charged one is
  fully paid with a total above zero — **and** Stacks can vouch for the whole
  month. The gate fails closed: each of the following is *unknown*, so not
  collected.
  - A current payer (`management_fee_payer`) has no management fee tracker on
    the pass. Same payer → tracker mapping as `ensure_trackers!`
    (`Mso::ManagementFeeInvoices.payer_trackers`); a legacy Forecast tracker
    (one with a blueprint) does not count.
  - A management fee tracker has no invoice attached.
  - An attached invoice's stored `txn_date` is outside the pass month, missing or
    unreadable. Applies to every attached invoice, drafts and voided ones
    included.
  - garden3d's mirror holds an invoice billed to a payer's
    `g3d_qbo_customer_id`, dated in the pass month, that is not attached to a
    tracker on this pass (a second or hand-made invoice). It blocks whatever
    its stored status, because nothing refreshes an unattached mirror. The one
    exception is an invoice stored as voided (note **and** zero total and
    balance): voiding is final. An invoice to a non-payer customer, in another
    month, or in another company's books does not block.
  - An attached invoice has no stored data or an unreadable amount.
- All of the above lives in `InvoicePass#management_fee_collected?`, the pure
  rule over stored mirrors (no QuickBooks call).
  `Mso::ManagementFeeInvoices.collected?(invoice_pass:)` refreshes every attached
  invoice from QuickBooks first, raises if any read fails, then asks the pure
  rule — so the two entry points always agree. It costs one read per attached
  invoice: call it once per run, never per row.
- The unattached-invoice check sees only what is mirrored. garden3d's mirror
  gains rows from a draft push, a refused push (which records what QuickBooks
  already holds for that customer and month) and a manual
  `QboAccount#sync_all_invoices!`; an invoice made by hand after those is
  invisible until one of them runs again.

**Fee income (§6.3)**

- A month with no fee has **no 4100 row** and raises `RowMissing` (December
  2025). S4 must decide what that means for a run.
- `reconcile` sums only `Managerial Services` lines on attached invoices and
  returns a per-invoice breakdown; `reconcile!` raises on variance. A fee line on
  the `Services` item blocks S4 until Finance moves it.
- `for_month` is a partial figure for an unfinished month.

**Who can see garden3d's passes**

- **Admins only**, the owner's decision, for every action including read: every
  invoice pass garden3d issues, every tracker on one, and the payouts pages
  under such a tracker. The seven legacy 2025 passes are included, so leads lose
  the access they had to those. Enforced in `AdminAuthorization` above the
  blanket lead grant; `scope_collection` keeps the same rows out of the index
  pages. This supersedes the narrower restriction §10 asked for (hiding the pass
  from leads-in-training only).
- A contributor paid on a legacy garden3d tracker still sees that payout on
  their own page and can open it; they cannot open the tracker.

**Also changed**

- Saving the tracker edit form no longer detaches its invoice, and only admins
  can change which invoice a tracker points at (enforced server-side).
- Intercompany fee invoices are excluded from the invoicing totals and from the
  AR aging and overdue-invoice MCP tools.

## 13c. S1 simplified (2026-10-13)

The owner's review of S1: an enterprise makes one invoice pass a month, the
pass makes its trackers, and who gets a tracker depends on the enterprise.
Sanctuary: every client it worked for. garden3d: every other enterprise it
bills. Where §6 and §13b differ from this section, **this section governs**.

- **`InvoicePass#make_trackers!` is the one entry point**, and is a plain
  `case` on the enterprise: Sanctuary, garden3d, else `NotImplementedError`.
  The admin page does the same for "Generate Invoices" and for which page a
  pass renders. There is no `forecast?` or `intercompany?` predicate, and
  `invoicing_kind`, `UnsupportedIssuer` and `legacy_forecast_trackers?` are
  gone. The start month (`InvoicePass::INTERCOMPANY_START`, August 2026) is
  checked where garden3d's trackers are made and where a draft is pushed, so
  the seven 2025 passes get no new trackers or drafts.
- **`enterprises.g3d_qbo_customer_id` is picked from a dropdown** of
  garden3d's QuickBooks customers, read live on the enterprise edit page
  (admins only), with a text input as the fallback.
- **Predicates are named for the enterprise, not for the fee.** A garden3d
  invoice carries the management fee and may carry other lines (a loan
  repayment between entities). `InvoicePass#garden3d?`,
  `InvoiceTracker#garden3d?`, `InvoiceTracker#intercompany_invoice?`
  (garden3d's pass, no blueprint), `QboInvoice.without_intercompany`. Fee
  income is still counted by Managerial Services line, never by invoice total.
- **No payer flag.** `enterprises.management_fee_payer` is not added. garden3d
  bills every other enterprise that has a customer id in garden3d's QuickBooks
  (`enterprises.g3d_qbo_customer_id`, `Enterprise.billed_by_garden3d`). An
  enterprise with no id stored gets no tracker.
- **Stacks never creates a QuickBooks customer.** Finance creates it and an
  admin stores its id on the enterprise's edit page (admin-only field).
- **With no enterprise stored as billed, the collection rule answers no.**
- **The nightly step is `InvoicePass.make_intercompany_passes!`**, from
  `Enterprise#daily_tasks` (`stacks:daily_enterprise_tasks`): garden3d's pass
  and trackers for every month from the start month through last month that
  has no pass. Database only. A month that already has its pass is left
  alone, so an enterprise that starts being billed later is not added to
  months already invoiced; "Generate Invoices" on a pass does add it. The
  12-month catch-up bound and "open a month" by hand are gone.
- **One button.** "Generate Invoices" on a pass makes that pass's invoices:
  Forecast invoicing on Sanctuary's, a $0.00 draft per tracker on garden3d's.
  "Create management fee drafts" and "Open garden3d month" are gone.
- **The index has one tab per enterprise** (Sanctuary by default; garden3d's
  for admins only).
- `Mso::ManagementFeeInvoices` is now `Mso::IntercompanyInvoices` and holds
  only the QuickBooks side: `push_invoice!` (with the pre-flight read),
  `refresh!`, `collected?`.

Unchanged: the pre-flight that refuses a second invoice and mirrors the
existing ones for attaching, the collection rule and its fail-closed cases,
`Mso::ManagementFeeIncome`, admin-only garden3d passes, and that nothing
writes to QuickBooks except on an admin's click.

## 14. Out of scope

- Per-person cap reduction limits and residual tracking
- Reallocating unused cap (explicitly rejected — §8.1)
- Routing contributor payouts away from Sanctuary
- An early-release escape hatch equivalent to `allow_early_contributor_payouts_on`
- Forecasting and scenario modelling — the workbook stays the planning tool
- Profit share in the benchmark
- Trailing-month smoothing
- Automatic month-end triggering; passes stay admin-created except garden3d's,
  which `Mso::MonthlyRun` creates
