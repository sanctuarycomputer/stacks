# Pay Cycles & Pay Stubs — Design Spec

**Date:** 2026-05-12
**Branch:** `feat/pay-stubs`
**Status:** Approved, ready for plan-writing

---

## 1. Goal

Generate contributor pay from Forecast hours for work that is **not** invoiced to an external client. Currently, the `InvoiceTracker → ContributorPayout` pipeline assumes every payout traces back to an external invoice with line items. The new enterprises (Garden3D LLC, Index Space LLC, USB Club LLC) — and a slice of Sanctuary's own internal work — pay contributors for internal hours where no external invoice exists. We need a first-class construct for this.

## 2. Background

Post-PR-93 (multi-enterprise routing), every ledger item already routes through `Ledger(enterprise, contributor)`. ContributorPayouts produced by InvoiceTracker land on the correct enterprise's ledger via `forecast_client.billing_enterprise`. What's missing is a way to produce payouts when **no invoice exists** — i.e., when hours are billed against an `is_internal?` forecast client. That's the gap this spec fills.

Critically: **invoices and pay cycles coexist within a single enterprise.** Sanctuary will invoice external clients (existing flow, unchanged) AND run monthly pay cycles for hours billed against its own internal forecast clients (new flow). The two flows are routed by `forecast_client.is_internal?`, not by which enterprise owns the client.

## 3. Architecture

Two new models:

- **`PayCycle`** — the container, one per `(enterprise, date_range)`. Holds dates and the implicit status computed from its children.
- **`PayStub`** — the per-contributor artifact, a first-class `LedgerItem` alongside `ContributorPayout`, `ContributorAdjustment`, etc. An admin reviews and approves each one.

`PayStub` does **not** reuse the `ContributorPayout` table; it's a sibling model. Reasoning (chosen during brainstorming):

- `ContributorPayout` is tightly coupled to `InvoiceTracker` (FK required; `accrual_date`, `bill_*`, `payable?`, `contributor_payouts_within_seventy_percent`, the 4-role blueprint shape all assume an invoice exists).
- The pay-stub world has no client invoice, no 70% post-commission cap, no role-allocation (AccountLead/ProjectLead/Commission). Forcing CP to handle both with branching on a nullable parent would muddy the existing well-trodden CP code paths.
- A clean sibling model that includes the shared `LedgerItem` concern keeps both paths simple. `Ledger#balance` / `#unsettled` / `#items_grouped_by_month` pick up `PayStub` mechanically (just add `pay_stubs` to the visible-items list).

## 4. Models & schema

### `PayCycle`
```
enterprise_id          int, not null, FK
starts_at              date, not null
ends_at                date, not null
created_by_id          int, FK admin_users
deleted_at             datetime (acts_as_paranoid)
created_at, updated_at

unique index (enterprise_id, starts_at, ends_at)
has_many :pay_stubs, dependent: :destroy
```

No `status` / `locked_at` / `paid_at` columns. Status is computed:

```ruby
def stubs_status
  return :no_stubs unless pay_stubs.any?
  pay_stubs.where(accepted_at: nil).none? ? :all_accepted : :some_pending
end
```

This mirrors `InvoiceTracker#contributor_payouts_status`.

### `PayStub`
```
pay_cycle_id           int, not null, FK
ledger_id              int, not null, FK            # set via LedgerItem concern
amount                 decimal(12, 2), not null     # sum over blueprint["lines"][*]["amount"]
blueprint              jsonb, not null, default '{}'
accepted_at            datetime
accepted_by_id         int, FK admin_users
qbo_bill_id            string                       # SyncsAsQboBill
deleted_at             datetime (acts_as_paranoid)
created_at, updated_at

unique index (pay_cycle_id, ledger_id)              # one stub per (cycle, contributor)
index (ledger_id)
```

`blueprint` shape:
```json
{
  "lines": [
    {
      "forecast_project": "fp-123",
      "hours": 40.0,
      "rate": 80.0,
      "amount": 3200.0,
      "description": "G3D-internal-2026 — 40h × $80"
    },
    ...
  ]
}
```

Distinct from `ContributorPayout#blueprint` (which has role keys AccountLead / ProjectLead / IndividualContributor / Commission and per-line `blueprint_metadata`). Simpler because there's no client billing to allocate against.

`PayStub` includes:
- `LedgerItem` concern (gives `belongs_to :ledger`, `delegate :contributor, :enterprise, to: :ledger`)
- `acts_as_paranoid`
- `SyncsAsQboBill` (so accepted, payable stubs sync as QBO bills — same plumbing as `ContributorPayout`)

The contributor is reachable via `pay_stub.ledger.contributor` (delegated to `pay_stub.contributor`). **No `contributor_id` column** — that would regress the consolidation done in PR #93's `RouteLedgerModelsThroughLedger` migration.

### `Enterprise` — one new column

```
pay_cycle_cadence    string (nullable)   # NULL | "monthly" | "twice_monthly"
```

- `NULL` → enterprise doesn't run pay cycles. The "New Pay Cycle" button is hidden on its admin show page.
- `"monthly"` → cycle defaults to `month.beginning_of_month .. month.end_of_month` when admin creates one.
- `"twice_monthly"` → splits the calendar month in half. Day ≤ 15 → defaults to `1..15` of the current month. Day ≥ 16 → defaults to `16..end_of_month`. Explicitly **not** 14-day rolling.

Each `PayCycle` row stores explicit `starts_at`/`ends_at`, so the admin can override the cadence default.

## 5. Routing: invoice vs pay cycle

The decision of whether a forecast project's hours route to invoice or to pay cycle is driven by the existing `forecast_client.is_internal?` flag — **not** by which enterprise owns the client.

| Forecast client | `billing_enterprise` | `is_internal?` | Hours route to |
|---|---|---|---|
| External Sanctuary client | Sanctuary | `false` | `InvoiceTracker` (existing flow, unchanged) |
| Sanctuary internal project | Sanctuary | `true` | Sanctuary's `PayCycle` (new) |
| External Garden3D client | Garden3D | `false` | `InvoiceTracker` (works today; Garden3D may invoice externally too) |
| Garden3D internal project | Garden3D | `true` | Garden3D's `PayCycle` (new) |

So every enterprise can do both. Today only Sanctuary is wired to issue invoice passes, but that's an orthogonal limitation noted under §13 (future direction).

## 6. Lifecycle and generation

### Cycle creation
Admin-triggered. From the enterprise show page (`/admin/enterprises/:id`) — when `pay_cycle_cadence` is set — a "New Pay Cycle" button opens a form pre-filled with the cadence's default `starts_at`/`ends_at`. Admin can adjust dates and submit. The PayCycle row is created with zero stubs.

### Stub generation (`PayCycle#generate_stubs!`)
Idempotent. Admin clicks "Regenerate from Forecast" on the cycle show page. The method:

1. Finds every `ForecastAssignment` whose `forecast_project.forecast_client.is_internal?` AND `forecast_client.billing_enterprise == pay_cycle.enterprise`, with a date range that overlaps `[starts_at, ends_at]`.
2. **Pro-rates** each assignment across the cycle boundary using the existing primitive `ForecastAssignment#allocation_during_range_in_hours(starts_at, ends_at)`. This already handles working-day filtering for `Time Off` (irrelevant here since Time Off isn't an internal client) and clips assignment start/end to the cycle window. **An assignment running May 10 – May 20 in a twice-monthly Index cycle naturally splits: 6 working days in the 1–15 cycle, 5 in the 16–31 cycle.**
3. Groups assignments by contributor.
4. **Skips salaried contributors** — same guard as `invoice_tracker.rb:467`: only emit a stub for a contributor whose `forecast_person.admin_user` is on a `variable_hours?` full-time period (or has no full-time period). Salaried people are paid via their full-time arrangement, not stubs.
5. Resolves rate per (project, contributor) using the existing hierarchy:
   ```ruby
   forecast_project.hourly_rate_override_for_email_address(contributor.email) ||
     forecast_project.hourly_rate
   ```
   **Hard-fails** with a listing of offending (project, contributor) pairs if any rate is missing. We refuse to silently emit $0 lines.
6. For each contributor, builds a blueprint:
   ```ruby
   { "lines" => qualifying_assignments.map { |a|
       {
         "forecast_project" => a.forecast_project.forecast_id,
         "hours" => clipped_hours_for(a),
         "rate" => resolved_rate_for(a, contributor),
         "amount" => (clipped_hours_for(a) * resolved_rate_for(a, contributor)).round(2),
         "description" => "#{a.forecast_project.display_name} — #{hours}h × $#{rate}"
       }
     } }
   ```
7. Computes `amount = blueprint["lines"].sum { |l| l["amount"] }`.
8. `Ledger.find_or_create_for(enterprise: pay_cycle.enterprise, contributor: contributor)`.
9. `find_or_initialize_by(pay_cycle_id:, ledger_id:)`:
   - If the stub is new → create with the computed blueprint, `accepted_at: nil`.
   - If the stub exists AND its existing `amount` equals the new amount → **preserve** `accepted_at`/`accepted_by_id`; rewrite blueprint (line metadata may have changed even if the total didn't).
   - If the stub exists AND the new amount differs → rewrite blueprint and amount, **reset** `accepted_at`/`accepted_by_id` to `nil`.
10. Stubs whose contributor no longer has qualifying hours in the cycle are **soft-deleted**, UNLESS their `accepted_at` is set — in that case raise so the admin investigates rather than losing acceptance silently.
11. $0-amount stubs (zero qualifying hours, or zero-rate edge case) are not written; existing $0 stubs are soft-deleted.

### Acceptance preservation — also retrofitted to `ContributorPayout`

The existing CP regen (`invoice_tracker.rb:469-477`) unconditionally resets `accepted_at` to `nil` for every contributor with an `admin_user`. This is buggy: a no-op regen invalidates valid acceptances. **This PR fixes that too**: CP regen preserves acceptance when the recomputed amount matches the existing amount; resets to `nil` when it changes. Same logic, same place — small, adjacent fix.

### Per-stub approval

Each stub has an Accept / Unaccept button on its show page:

```ruby
# Model — caller passes the admin doing the acceptance
def toggle_acceptance!(by:)
  if accepted?
    raise "Cannot unaccept a stub once all stubs in the cycle are accepted." if pay_cycle.stubs_status == :all_accepted
    update!(accepted_at: nil, accepted_by_id: nil)
  else
    update!(accepted_at: DateTime.now, accepted_by_id: by.id)
  end
end

# Controller calls: pay_stub.toggle_acceptance!(by: current_admin_user)
```

The "all-accepted lock-out" mirrors CP's `toggle_acceptance!`. Once you've flipped the last stub, the cycle is implicitly settled; corrections require an Adjustment. Note that `ContributorPayout#toggle_acceptance!` doesn't track *who* accepted today (just `accepted_at`); PayStub adds `accepted_by_id` because the new flow needs an audit trail for who approved each contributor's pay. The existing CP table is **not** retrofitted with `accepted_by_id` in this PR.

### Payable gate

```ruby
def payable?
  accepted? && pay_cycle.stubs_status == :all_accepted
end
```

Until the last stub is accepted, every stub (even accepted ones) is in `Ledger#unsettled`. The moment the last acceptance lands, all of the cycle's stubs flip `payable? → true` in lockstep, and they appear in `Ledger#balance` instead.

### QBO Bill sync

`PayStub` includes `SyncsAsQboBill`. Once `payable?`, a QBO bill is created (or updated) via the existing sync plumbing.
- `bill_doc_number_code = "PS"`
- `bill_txn_date = pay_cycle.ends_at`
- `bill_description = "https://stacks.garden3d.net/admin/pay_cycles/#{pay_cycle_id}/pay_stubs/#{id}"`

The CP-side internal-client account override (`ContributorPayout#find_qbo_account!`) has a sibling here — for `PayStub`s, the work is always "internal" by definition (every stub comes from an `is_internal?` forecast client), so the marketing-services-account override path applies uniformly. The QBO account resolution is implemented in `PayStub#find_qbo_account!`, mirroring CP's signature.

## 7. UI surfaces

### Enterprise show page (`/admin/enterprises/:id`)
- New "Pay cycles" section, visible when `pay_cycle_cadence` is set.
- Lists this enterprise's cycles: `starts_at..ends_at`, status (`No stubs` / `Some pending` / `All accepted`), stub count, ledger-total.
- "New Pay Cycle" button.

### Enterprise admin form
- New `pay_cycle_cadence` select: `(disabled)` / `Monthly` / `Twice monthly`.

### Pay cycle show page (`/admin/enterprises/:enterprise_id/pay_cycles/:id`)
Nested under enterprise — matches the multi-enterprise nesting convention from PR #93 (single canonical URL per resource).
- Header: enterprise name, date range, computed status.
- "Regenerate from Forecast" button calling `PayCycle#generate_stubs!`. When any stubs exist and have `accepted_at` set, a confirm modal lists the to-be-reset stubs: "Regen will reset acceptance on N stubs whose amount changes. Continue?"
- Table of stubs: contributor name, total hours, amount, accepted-by, accepted-at, link to stub show.

### Pay stub show page (`/admin/pay_cycles/:pay_cycle_id/pay_stubs/:id`)
- Header: contributor, cycle range, amount.
- Itemized line items table from `blueprint["lines"]`: forecast project, hours, rate, line amount.
- Accept / Unaccept button — Unaccept disabled (per `toggle_acceptance!` guard) once cycle is `all_accepted`.
- QBO Bill section (reuse the existing `SyncsAsQboBill` partial) once `payable?`.

### Contributor admin show page
Already tabbed per ledger (the pill UI from PR #93). Pay stubs surface in the appropriate ledger's tab automatically: `PayStub` shows up in `Ledger#all_items_with_deleted` once it's added to the visible-items list, and `Contributor#all_items_grouped_by_month` picks it up cross-ledger via the `has_many :pay_stubs, through: :ledgers` association.

### No top-level browse
No `/admin/pay_cycles` flat index. One canonical URL per resource: cycles live under enterprises, stubs live under cycles. Matches the PR-93 pattern for adjustments/reimbursements/trueups.

## 8. Validations and guards

### `PayCycle`
- `enterprise_id`, `starts_at`, `ends_at` present
- `starts_at <= ends_at`
- Uniqueness on `(enterprise_id, starts_at, ends_at)` (DB index + AR validation)

### `PayStub`
- `pay_cycle_id`, `ledger_id`, `amount`, `blueprint` present
- `blueprint["lines"]` is an array
- `amount` matches `blueprint["lines"].sum { |l| l["amount"] }` within rounding (mirrors `ContributorPayout#in_sync?`)
- `pay_cycle.enterprise_id == ledger.enterprise_id` — a Garden3D cycle's stub can't write to a Sanctuary or Index ledger
- `(accepted_at, accepted_by_id)` both set or both nil
- Uniqueness on `(pay_cycle_id, ledger_id)` (DB index + AR validation)

### Generation-time guards
- Hard error if any (qualifying assignment, contributor) pair has no resolvable rate.
- Soft-delete contributor stubs whose hours dropped to zero on regen — except when `accepted_at` is set; raise then.

## 9. Migrations

```
db/migrate/<timestamp>_create_pay_cycles_and_pay_stubs.rb   # <timestamp> = bin/rails g migration's autogenerated UTC ts
```

- `create_table :pay_cycles` (columns above)
- `create_table :pay_stubs` (columns above)
- `add_column :enterprises, :pay_cycle_cadence, :string` (nullable, no default)

No backfill needed — both tables start empty. Enterprises pick up `pay_cycle_cadence` via the admin form once we decide to enable cycles for them.

## 10. App code changes outside the new models

- **`Ledger`** — `visible_items` and `all_items_with_deleted` include `pay_stubs`.
- **`Contributor`** — add `has_many :pay_stubs, through: :ledgers`; add `pay_stubs_with_deleted` memoized method matching the pattern of the other 5 ledger-item collections; include in `preload_for_ledger_view!`; include in `all_items_grouped_by_month` aggregation.
- **`InvoiceTracker#make_contributor_payouts!`** — change the `accepted_at: payee.admin_user.present? ? nil : DateTime.now` line to preserve `accepted_at` when the recomputed amount equals the existing CP amount, reset to `nil` otherwise.
- **`Enterprise`** — adds `pay_cycle_cadence` accessor + admin form field. `has_many :pay_cycles`.
- **`Admin::PayCyclesController`** and **`Admin::PayStubsController`** — new admin pages following the nested pattern from PR #93.

## 11. Tests

- `PayCycle#stubs_status` returns the right state across `no_stubs`, `some_pending`, `all_accepted`.
- `PayCycle#generate_stubs!` end-to-end:
  - Pro-rates an assignment crossing the cycle boundary correctly.
  - Skips a salaried contributor.
  - Skips a non-internal forecast client.
  - Skips an internal client whose `billing_enterprise` differs.
  - Hard-fails when a qualifying assignment has no rate.
  - Preserves `accepted_at` when re-running over an unchanged stub.
  - Resets `accepted_at` when amount changes.
  - Soft-deletes a contributor stub whose hours dropped to zero (only if unaccepted).
  - Raises when an accepted stub's contributor has no qualifying hours on regen.
- `PayStub#payable?` flips correctly when the last stub is accepted.
- `PayStub#toggle_acceptance!` refuses unaccept once cycle is `all_accepted`.
- Validation: stub on Garden3D cycle pointed at Sanctuary ledger is rejected.
- `ContributorPayout` regen preserves `accepted_at` when amount unchanged (existing-flow fix).
- `Ledger#balance` includes payable stubs; `unsettled` includes un-payable stubs.
- Bi-monthly cadence: stub generation in the 1–15 cycle doesn't double-count hours into the 16–31 cycle.

## 12. Out of scope (v1)

- **Auto-creation of cycles on schedule.** Admin clicks "New Pay Cycle" each period. (Future: a scheduled job per `pay_cycle_cadence`.)
- **Excluding specific contributors from a cycle.** Every qualifying contributor gets a stub.
- **Editing a stub's blueprint by hand.** Corrections after acceptance go through `ContributorAdjustment` (existing path).
- **Surplus/profit-share semantics on stubs.** Pay stubs don't generate surplus (no client billing to overshoot). Profit shares remain a separate ledger item driven by `PeriodicReport`.
- **Pay-cycle currency / multi-currency.** USD only.
- **Cycle deletion.** Mark cycles as deleted by `acts_as_paranoid`; in the admin we hide the destroy button while any stub is `payable?` to avoid orphaning paid bills.

## 13. Future direction (informs design, not implemented)

- **Move `InvoicePass` under `Enterprise`.** Today every `InvoicePass` is implicitly Sanctuary's. As other enterprises (Garden3D, Index, USB Club) start invoicing external clients themselves, `InvoicePass` will need an `enterprise_id`. This spec deliberately keeps `is_internal?`-based routing (not enterprise-based routing) for the invoice-vs-stub decision so this future migration only adds an `enterprise_id` to `InvoicePass` without rerouting existing logic.
- **Per-enterprise pay-cycle cadence variants** beyond monthly / twice-monthly (e.g., weekly). The `pay_cycle_cadence` column is a string so we can extend it without a schema change.
- **Auto-creation jobs** keyed off `pay_cycle_cadence`.

## 14. Migration to production

No prod data backfill required. Steps for rollout:
1. Deploy migration (creates two empty tables, adds one nullable column).
2. Admins set `pay_cycle_cadence` on the enterprises that should run cycles (Garden3D, Index, USB Club, and Sanctuary).
3. Admins create the first cycle per enterprise, regenerate, review, accept.
4. From `Stacks::Deel.new.sync_all!` and the existing Forecast sync, all upstream data is already present.

No existing rows change. The CP regen fix (acceptance preservation) is a code-only change that helps future regens but doesn't retroactively flip any current state.
