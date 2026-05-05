# Project Tracker Commissions — Design

## Problem

Some projects carry an obligation to pay a commission to a third party (often a referrer, but not always). The commission must:

- Not appear on the client-facing QBO invoice. The hourly rate billed to the client is unchanged.
- Be deducted "off the top" of every billable line on the invoice, before downstream payout math runs.
- Reduce the base used for Account Lead, Project Lead, Individual Contributor, company treasury slice, surplus, and the 70% contributor-pool cap.
- Be paid out to a `Contributor` recipient (referrers are onboarded as contributors with a `ForecastPerson`).

## Scope

In:
- A new `Commission` model (STI) attached to `ProjectTracker`, with two initial subclasses: `PercentageCommission` and `PerHourCommission`.
- Per-line deduction of all applicable commissions inside `InvoiceTracker#make_contributor_payouts!`.
- Commission payouts ride the existing `ContributorPayout` model via a new `Commission` blueprint role; auto-accepted when the CP is commission-only.
- Validation, surplus, and cap math updated to use post-commission amounts.
- Admin UI on the `ProjectTracker` edit page (nested form) and read-only display on the `InvoiceTracker` and `ProjectTracker` show pages.

Out (deferred):
- Time-bounded commissions (started_at/ended_at).
- Per-`forecast_project` scoping within a tracker.
- Caps on lifetime commission totals.
- Dedicated QBO expense account for commissions (will follow the existing studio-derived expense account; revisit later).

## Data model

### New table: `commissions`

| column              | type         | notes                                       |
| ------------------- | ------------ | ------------------------------------------- |
| `id`                | bigint       |                                             |
| `project_tracker_id`| bigint, FK   | required                                    |
| `contributor_id`    | bigint, FK   | recipient; required                         |
| `type`              | string       | STI: `PercentageCommission` / `PerHourCommission` |
| `rate`              | decimal      | semantic depends on subclass                |
| `notes`             | text         | optional                                    |
| `deleted_at`        | datetime     | `acts_as_paranoid` so historical CP blueprints retain a resolvable record |
| `created_at`        | datetime     |                                             |
| `updated_at`        | datetime     |                                             |

`PercentageCommission`: `rate` is a decimal in `[0, 1]` (e.g. `0.15` = 15% of the line's billed amount).
`PerHourCommission`: `rate` is a decimal in dollars per hour (e.g. `15.00`).

Future commission kinds add a subclass and any new columns they require; no schema rework needed for existing kinds.

### Model

```ruby
class Commission < ApplicationRecord
  acts_as_paranoid
  belongs_to :project_tracker
  belongs_to :contributor

  validates :type, presence: true
  validates :rate, presence: true, numericality: { greater_than_or_equal_to: 0 }

  # Subclasses must implement:
  #   deduction_for_line(qbo_line_item, blueprint_line) -> BigDecimal
  #   description_line(qbo_line_item, blueprint_line, deduction) -> String
end

class PercentageCommission < Commission
  validates :rate, numericality: { less_than_or_equal_to: 1 }

  def deduction_for_line(qbo_line_item, _blueprint_line)
    (qbo_line_item["amount"].to_f * rate.to_f).round(2)
  end

  def description_line(qbo_line_item, blueprint_line, deduction)
    n2c = ->(v) { ActionController::Base.helpers.number_to_currency(v) }
    hrs = blueprint_line["quantity"].to_f
    rt  = blueprint_line["unit_price"].to_f
    "- #{hrs} hrs * #{n2c.call(rt)} p/h * #{(rate.to_f * 100).round(2)}% = #{n2c.call(deduction)} (commission to #{contributor.display_name})"
  end
end

class PerHourCommission < Commission
  def deduction_for_line(_qbo_line_item, blueprint_line)
    (blueprint_line["quantity"].to_f * rate.to_f).round(2)
  end

  def description_line(_qbo_line_item, blueprint_line, deduction)
    n2c = ->(v) { ActionController::Base.helpers.number_to_currency(v) }
    hrs = blueprint_line["quantity"].to_f
    "- #{hrs} hrs * #{n2c.call(rate)} p/h commission = #{n2c.call(deduction)} (commission to #{contributor.display_name})"
  end
end
```

`PercentageCommission#deduction_for_line` reads from the QBO line's `amount` (so it's correct even when the line was edited in QBO post-generation). `PerHourCommission#deduction_for_line` reads from the blueprint's `quantity` (the agreed-upon hours basis).

### `ProjectTracker` association

```ruby
has_many :commissions, dependent: :destroy
accepts_nested_attributes_for :commissions, allow_destroy: true
```

## Generation flow

`InvoiceTracker#make_contributor_payouts!` walks each QBO line item, looks up the `ProjectTracker` via the line's `forecast_project`, and currently computes AL/PL/IC against the line's `amount`. Change:

1. Compute `deductions` for the line — `pt.commissions.map { |c| { commission: c, amount: c.deduction_for_line(line_item, metadata).round(2) } }.reject { |d| d[:amount] <= 0 }`.
2. `commission_total = deductions.sum { |d| d[:amount] }`.
3. `working_amount -= commission_total`. `working_hours` and `working_rate` unchanged.
4. For each deduction, append to the recipient Contributor's blueprint:
   ```ruby
   payouts[d[:commission].contributor.forecast_person][:blueprint][:Commission] << {
     blueprint_metadata: ContributorPayout.slim_metadata(metadata),
     amount: d[:amount],
     description_line: d[:commission].description_line(line_item, metadata, d[:amount]),
   }
   ```
5. AL/PL/IC math runs unchanged against the reduced `working_amount`.

The empty-blueprint shape used at the start of each payout entry gains a `Commission: []` key alongside the existing `AccountLead`, `ProjectLead`, `IndividualContributor` keys.

### Hourly-rate override interaction

Lines where the IC has `hourly_rate_override_for_email_address` already pay `working_hours × override_rate` regardless of `working_amount`. Commission still deducts from `working_amount`, which only affects the company's slice — the override-IC's pay is unchanged. AL/PL on those lines still see the reduced `working_amount`. This is intended.

### Auto-accept

The existing CP creation in `make_contributor_payouts!` gates `accepted_at` on `payee.admin_user.present?`. That gate stays as-is for non-commission CPs. After the synced-CPs reduction step (and before the surplus distribution loop), do a second pass: for any CP whose blueprint contains `Commission` entries and no `IndividualContributor` / `AccountLead` / `ProjectLead` entries, force `accepted_at: DateTime.now`. This overrides the admin_user gate, since a commission-only CP has no contributor reviewing their own work — the rate was agreed up front on the tracker.

CPs that mix Commission with other roles (a contributor who is also the commission recipient on the same tracker) follow the normal acceptance flow.

### Idempotency

The existing transaction-wrapped reconciliation (`find_or_initialize_by(contributor:)`, then destroy CPs not in the synced set) handles regen for free. Editing a `Commission`'s rate, adding/removing commissions, and re-running `make_contributor_payouts!` produces the right CPs.

## Validation and downstream math

### 70% cap (`ContributorPayout#contributor_payouts_within_seventy_percent`)

Today:

```ruby
max_amount = invoice_tracker.total * (1 - invoice_tracker.company_treasury_split)
errors.add(:base, ...) if cps.sum(&:amount) > max_amount + 1
```

After:

```ruby
post_commission_total = invoice_tracker.total - cps.sum(&:as_commission)
max_amount            = post_commission_total * (1 - invoice_tracker.company_treasury_split)
contributor_pool_sum  = cps.sum { |cp| cp.amount - cp.as_commission }
errors.add(:base, ...) if contributor_pool_sum > max_amount + 1
```

### `ContributorPayout#as_commission`

New helper, parallel to `as_account_lead` / `as_project_lead` / `as_individual_contributor`:

```ruby
def as_commission
  return 0 unless blueprint["Commission"].present?
  blueprint["Commission"].sum { |l| l["amount"].to_f }
end
```

### `calculate_surplus`

Today, `amount_billed = qbo_line_item["amount"].to_f`. After:

```ruby
amount_billed       = qbo_line_item["amount"].to_f
commission_for_line = invoice_tracker.commission_total_for_line(qbo_line_item["id"])
working_amount      = amount_billed - commission_for_line

profit_margin = (working_amount - amount_paid) / working_amount
surplus       = ((profit_margin - 0.43) * working_amount).round(2)
surplus       = 0 if surplus <= 0
```

`maximum` in the returned hash also moves to `0.57 * working_amount`.

### `InvoiceTracker#commission_total_for_line(line_item_id)`

Walks all CPs on this invoice, sums any `Commission` blueprint entries whose `blueprint_metadata["id"]` matches `line_item_id`. The blueprint already carries the line-level breakdown so no separate ledger is needed.

```ruby
def commission_total_for_line(line_item_id)
  contributor_payouts.includes(:contributor).sum do |cp|
    (cp.blueprint["Commission"] || []).sum do |entry|
      entry.dig("blueprint_metadata", "id").to_s == line_item_id.to_s ? entry["amount"].to_f : 0
    end
  end
end
```

### Blueprint integrity / surplus chunks

`blueprint_integrity_errors` only checks `IndividualContributor` entries, so `Commission` entries don't trip it. `calculate_surplus` only reads `IndividualContributor` entries, so a commission-only CP returns `[]` — no change needed.

## Pay-out side (QBO Bill)

`ContributorPayout` already syncs as a QBO Bill via `SyncsAsQboBill`. A commission-only CP rides the same path. The existing `find_qbo_account!` picks an expense account based on the contributor's studio; commissions use that account for now. Switching to a dedicated "Commissions Paid" expense account is deferred — the override pattern already exists in `find_qbo_account!`, so the change will be small when needed.

## UI / admin surface

### `ProjectTracker` edit page

New "Commissions" section, modeled on `account_lead_periods`. Per row: Recipient (contributor select), Type (`PercentageCommission` / `PerHourCommission`), Rate, Notes. Add/remove rows; destroy soft-deletes via `acts_as_paranoid`.

### `InvoiceTracker` show page

New "Commissions Deducted" section above the contributor payouts list, showing per-line: line description, commission recipient, type, deduction amount, sourced from the commission entries across this invoice's CPs. The recipient's CP appears in the normal payouts list with a `# Commission` section in its description (rendered by the existing description builder, which iterates blueprint roles).

### `ProjectTracker` show page

"Total Commissions Paid (Lifetime)" displayed alongside existing tracker financials. Computed as the sum of `as_commission` across all CPs on this tracker's invoices.

### Description rendering

The existing CP description builder concatenates one section per blueprint role. `Commission` becomes another role:

```
# Commission
- 12.0 hrs * $234.00 p/h * 15.0% = $421.20 (commission to Acme Corp)

# Total: $421.20
```

## Testing

### Unit

- `PercentageCommission#deduction_for_line`: round to 2 decimals; uses `qbo_line_item["amount"]`.
- `PerHourCommission#deduction_for_line`: uses `blueprint_line["quantity"]`; round to 2 decimals.
- `Commission` STI roundtrip via `accepts_nested_attributes_for` on `ProjectTracker`.
- `ContributorPayout#as_commission` mirrors existing `as_*` helpers.

### Integration — `InvoiceTracker#make_contributor_payouts!`

- One tracker, one `PercentageCommission`, one line: `working_amount` reduced; AL/PL/IC computed off reduced amount; commission CP minted; commission-only CP auto-accepted.
- Two commissions stacking on one tracker (one %, one $/hr): both deductions applied additively; two distinct CPs (or one CP if same recipient).
- Commission recipient also acts as IC on the line: single CP with both `IndividualContributor` and `Commission` blueprint entries; not auto-accepted (mixed).
- Hourly-rate override + commission: IC payout = `hours × override_rate` unchanged; AL/PL off reduced `working_amount`.
- Internal-client invoice + commission: existing internal-client path (no AL/PL/IC, just IC) still works; commission still deducts correctly.
- Regen idempotency: edit a `Commission` rate, re-run `make_contributor_payouts!`, CP amounts update; remove a Commission, the corresponding CP entries disappear; soft-deleted commissions don't break historical CP integrity.

### Validation

- 70% cap: basis is post-commission total; commission portions excluded from LHS sum. A CP that breaches the cap after exclusion still raises; one that's only over the *raw* cap but fine post-commission does not.

### Surplus

- `calculate_surplus` uses post-commission `working_amount` as both `amount_billed` and divisor; `maximum = 0.57 * working_amount`; surplus distribution to AL/PL on `make_contributor_payouts!` reflects the post-commission basis.

## Migration / rollout

- The schema migration only adds the `commissions` table; existing data is unchanged.
- Trackers with no `commissions` rows behave identically to today (loops over an empty collection, `working_amount` unchanged).
- Re-running `make_contributor_payouts!` on a historical invoice after attaching commissions to its tracker will retroactively apply them. This is the expected escape hatch for back-filling, and is the same lever already used to regenerate CPs after AL/PL changes.
