# Payout margin guard on "Calculate Default Payouts"

Date: 2026-10-12
Branch: `feat/payout-margin-guard`

## Problem

Clicking "Calculate Default Payouts" on an invoice tracker's payouts index
(`app/admin/contributor_payouts.rb`, `collection_action :make_payouts`) calls
`InvoiceTracker#make_contributor_payouts!`. A cap on total payouts already
exists as a model validation, `ContributorPayout#contributor_payouts_within_seventy_percent`,
but the experience around it is broken:

1. Generation saves one payout per payee inside a transaction. The validation
   trips on whichever payee pushes the running sum over the cap, the
   `ActiveRecord::RecordInvalid` escapes the action, and the admin sees a 500.
2. The error names a dollar ceiling, not the line items that caused it.
3. On a regenerate, payouts from the previous generation still exist while the
   new ones are saved (orphans are destroyed afterwards), so the validation can
   trip even when the final state is within the cap.
4. The cap reads `invoice_trackers.company_treasury_split`, which defaults to
   `0.3` regardless of the projects' billing models. A `new_deal_v2` invoice
   (33% treasury) is therefore capped at 70% instead of 67%.

The usual real cause of an overrun is `ForecastProject#hourly_rate_override_for_email_address`:
that path pays `hours x override rate` with no ceiling, unlike the normal path,
which multiplies by `rules.ic_share`.

## Behaviour

When an admin clicks "Calculate Default Payouts":

1. The server builds the payout set in memory without writing anything.
2. If total payouts are within the invoice's cap, payouts are written as today.
3. If they exceed the cap, nothing is written. The admin is redirected to the
   payouts index, where a full-screen overlay explains the breach and lists
   every line item.
4. From the overlay, an admin can type a reason and press "Generate anyway".
   Payouts are then written and the override is recorded in the tracker's notes.

The trigger is the invoice total only. A single line over its own ceiling is
flagged in the table but does not block when the invoice as a whole is under.

## The cap

`InvoiceTracker#payout_cap` semantics, used by both the pre-flight and the
existing save-time validation:

- Internal client (`forecast_client.is_internal?`): cap is 100% of the
  post-commission invoice total. Unchanged from today.
- `target_margin_override` present: cap = (invoice total - commissions) x
  (1 - `target_margin_override`).
- Otherwise, weighted by line: each line mapped to a ProjectTracker contributes
  its post-commission amount x (1 - that tracker's `billing_rules.treasury_share`).
  Any remainder of `invoice_tracker.total` not covered by mapped lines
  contributes at the default billing model's share
  (`Stacks::BillingModel::DEFAULT`), which matches today's behaviour for those
  amounts.

So an all-v1 invoice caps at 70%, an all-v2 invoice at 67%, and a mixed invoice
in between. The comparison keeps today's one dollar of rounding slack, and the
pool is still payouts net of Commission entries.

The save-time validation (renamed `contributor_payouts_within_cap`, same
`skip_seventy_percent_check` escape hatch) needs line-level commission amounts
to compute the weighted cap from saved payouts; it reads them from the saved
blueprints' `Commission` entries by `blueprint_metadata.id`, as
`InvoiceTracker#commission_total_for_line` already does.

## Schema change

`invoice_trackers.company_treasury_split` (decimal, default `0.3`) becomes
`target_margin_override` (decimal, nullable, default `nil`).

Migration:

1. Rename the column and its check constraint
   (`check_target_margin_override_range`, null allowed, otherwise 0..1).
2. Change the default to `nil`.
3. Backfill: set rows equal to `0.3` to `NULL`. Rows with any other value keep
   it and continue to act as explicit overrides.

The value's meaning is unchanged: the share the company keeps (0.33 = 33%
margin, 67% payout cap). The admin form input is relabelled "Target margin
override" with a hint that blank means "derive from the projects' billing
models".

Deploy ordering: migrations here are run manually and there is no release
phase, so code reading `target_margin_override` will fail between deploy and
migration. To cover that window, one private reader on the model checks
`has_attribute?(:target_margin_override)` and falls back to the old column
(treating `0.3` as "no override") when the new one isn't there yet. That fallback is removed in a follow-up once the
migration has run. `db/schema.rb` is hand-curated and gets the matching edit.

## Code shape

### `InvoicePayouts::Build` (new, `app/services/invoice_payouts/build.rb`)

The in-memory half of `make_contributor_payouts!`, extracted. Input: an
invoice tracker. Output:

- `lines`: one per QBO line item that has blueprint metadata, each with
  `qbo_line_item`, `metadata`, `project_tracker`, `rules`, `billed`,
  `commission_total`, `working_amount`, and `entries`
  (`role`, `payee`, `amount`, `description_line`, `rate_override`,
  `payable`).
- `payouts_by_payee`: the same hash shape `make_contributor_payouts!` builds
  today, so the write path is behaviour-identical.

`payable` carries the existing rule that only variable-hours people (or people
with no admin user / no full-time periods) receive a payout. Entries for
non-payable payees are kept on the line for display but excluded from the pool,
so the dry run counts exactly what the write would save. The first-month-of-
New-Deal recompute and the internal-project branch move across unchanged.

### `InvoicePayouts::MarginCheck` (new)

Input: a `Build`. Output: `cap`, `pool`, `post_commission_total`,
`payout_percentage`, `cap_percentage`, `breached?`, and display rows per line
(billed, payouts, payout %, margin %, allowed, over, entries, and whether the
line exceeds its own ceiling), plus an "unmapped / other" row for the part of
the invoice total not covered by mapped lines.

### Surplus

Lead surplus shares are assigned after the write and are not in the dry run.
They cannot push the pool over the cap: for a line with margin `m` and
threshold `T`, payouts as a fraction of the working amount are
`(1 - m) + (AL + PL) + 2 x surplus_lead_share x (m - T)`, which equals
`1 - treasury_share` at `m = T` and falls as `m` rises while
`2 x surplus_lead_share < 1`. A test asserts that inequality for every entry in
`Stacks::BillingModel::ALL`.

With a `target_margin_override` stricter than a project's model, surplus could
in principle add to a pool already at the override cap. The override branch
therefore treats the pre-surplus pool as authoritative, the same as the
weighted branch; this is noted in the overlay copy as "before lead surplus
shares".

### `InvoiceTracker#make_contributor_payouts!(created_by)`

Consumes `Build#payouts_by_payee`. Sets `skip_seventy_percent_check = true` on
every payout it saves (the three `update!` sites and the description pass),
because the pre-flight has already ruled on the final state. The validation
continues to guard manual create and edit.

### `make_payouts` action

- Rejects non-admins server-side (today only the button is hidden).
- Runs `Build` and `MarginCheck`.
- Not breached: generate, redirect with "Payouts processed!".
- Breached, no `force`: redirect to the index with `margin_breach=1`.
- Breached, `force=1`: require a non-blank `override_reason`; otherwise
  redirect back to the overlay with an alert. With a reason, generate, then
  append to `invoice_tracker.notes`:
  `[YYYY-MM-DD] <admin email> generated payouts over the cap (78.4% vs 67.0%): <reason>`.

### Overlay

Rendered on the payouts index when `params[:margin_breach]` is present and the
re-run check is still breached (if it no longer is, no overlay). Uses the
existing `.full-screen-modal` styles from `active_admin.scss`, in a partial
`app/views/admin/contributor_payouts/_margin_breach.html.erb`.

Contents:

- Headline: "The generated payouts would be 78.4% of gross earnings. The cap
  for this invoice is 67%."
- Totals: billed (post-commission), generated payouts, allowed, over by.
- Table, one block per line item: description, billed, payouts, payout %,
  margin %, allowed, over. Under each, every entry: role, payee, amount, and
  the description line. IC entries paid from a rate override are marked
  "rate override". Lines over their own ceiling are marked.
- "Unmapped / other" row and a totals row that reconcile to the invoice total.
- Form: required reason textarea, "Generate anyway" (POST to `make_payouts`
  with `force=1`), and a close link back to the plain index.

## Tests

- `Build`: the existing `invoice_tracker_payouts_test.rb` cases pass unchanged
  through the refactored write path; `payable` excludes full-time payees.
- `MarginCheck`: all-v1, all-v2, mixed, `target_margin_override` set, rate
  override breach, internal client, commissions off the top, unmapped
  remainder.
- Surplus invariant for every billing model.
- Validation: uses the same cap; existing 70% tests updated for the rename.
- Action: breach redirects and writes nothing; force with a reason writes
  payouts and the note; force without a reason writes nothing; non-admin is
  refused; a regenerate whose payees changed no longer raises.
- Migration backfill: `0.3` becomes `NULL`, other values survive.

## Out of scope

- Blocking on a single over-ceiling line.
- Applying a ceiling to hourly rate overrides at generation time.
- Structured (queryable) override records.
