# Payout margin guard on "Calculate Default Payouts"

Date: 2026-10-12
Branch: `feat/payout-margin-guard`
Revision 2 (after adversarial review)

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
   new ones are saved, so the validation can trip even when the final state is
   within the cap.
4. The cap reads `invoice_trackers.company_treasury_split`, which defaults to
   `0.3` regardless of the projects' billing models, so a `new_deal_v2`
   invoice (33% treasury) is capped at 70% instead of 67%.
5. The validation sums the tracker's payouts from the database, so when a
   persisted payout is edited it checks the pre-edit amount and never blocks.
6. `make_payouts` has no server-side admin check, and
   `skip_seventy_percent_check` is permitted for every user.

The usual cause of an overrun is `ForecastProject#hourly_rate_override_for_email_address`:
that path pays `hours x override rate` with no ceiling.

## Behaviour

When an admin clicks "Calculate Default Payouts":

1. The server builds the complete payout set in memory, including lead surplus
   shares, without writing anything.
2. If total payouts are within the invoice's cap, payouts are written.
3. If they exceed the cap, nothing is written. The admin is redirected to the
   payouts index with `?margin_breach=1`, where a full-screen overlay explains
   the breach and lists every line item.
4. From the overlay, an admin can type a reason and press "Generate anyway".
   Payouts are written and the override is appended to the tracker's notes.

The trigger is the invoice total only. A line over its own ceiling is flagged
in the table but does not block when the invoice as a whole is under.

## The cap: `InvoicePayouts::Cap`

One pure calculation used by both the pre-flight and the save-time validation.

Inputs: the invoice tracker, `commissions_by_line` (QBO line id => dollars of
commission recorded against that line), and `unattributed_commissions`
(commission dollars not tied to a mapped line).

A line is "mapped" when the QBO line item has blueprint metadata and its
`forecast_project` resolves to exactly one ProjectTracker through
`ProjectTrackerForecastProject`. Everything else on the invoice is the
"unmapped remainder": `invoice_tracker.total` minus the sum of mapped line
amounts.

- Internal client (`forecast_client.is_internal?`): cap = total - all
  commissions. Unchanged from today.
- `target_margin_override` present: cap = (total - all commissions) x
  (1 - override).
- Otherwise: sum over mapped lines of (line amount - that line's commissions) x
  (1 - that tracker's `billing_rules.treasury_share`), plus
  (remainder - unattributed commissions) x (1 - the default model's treasury
  share).

`post_commission_total` = total - all commissions. The overlay's percentages
are `pool / post_commission_total` and `cap / post_commission_total`, so a
mixed invoice or one with an unmapped discount shows its real blended figure.

The breach test keeps today's one dollar of slack: `pool > cap + 1`.

"Commissions" here always means commissions that are actually paid out: an
entry whose recipient is not payable is not saved today and is not counted, in
either the pre-flight or the validation.

## Schema change

`invoice_trackers.company_treasury_split` (decimal, default `0.3`) becomes
`target_margin_override` (decimal, nullable, default `nil`). The value's
meaning is unchanged: the share the company keeps.

Migration (raw SQL for the constraint rename; Rails 6.1 has no helper):

1. Rename the column; drop and re-add the range check as
   `check_target_margin_override_range`.
2. Change the default to `NULL`.
3. Backfill: set to `NULL` every row equal to `0.3` that has **no**
   non-deleted contributor payouts. Rows that already have payouts keep `0.3`
   as an explicit override.

Step 3 keeps history stable. `ProjectTracker#billing_model` is a live
attribute, not a per-invoice snapshot, so nulling an old tracker whose project
later moved to v2 would re-cap an invoice already paid out at 70% down to 67%
and block every later edit of its payouts. New trackers get `NULL` and follow
their projects' models. An admin can blank the field on any tracker that
should follow the model instead.

The admin form input is relabelled "Target margin override" with the hint
"Blank = derive the cap from each project's billing model."

### Deploy window

Migrations are manual and web dynos cache column lists until restarted, so
the new code must run against the old column for a few minutes:

- `InvoiceTracker#margin_override` is the only reader. It uses instance-level
  `has_attribute?(:target_margin_override)`; when the new column is absent it
  reads `company_treasury_split` as-is (so old behaviour holds exactly until
  the migration runs).
- The admin form input and the `permit_params` entry are included only when
  `InvoiceTracker.column_names` has the new column.
- Runbook for the PR description: merge, wait for the deploy, run
  `db:migrate`, then `heroku restart`.

The fallback and the conditionals are removed in a follow-up.

## Code shape

### `InvoicePayouts::Build` (new, `app/services/invoice_payouts/build.rb`)

The whole computation of `make_contributor_payouts!`, with no writes. It
replaces both the in-memory loop and the post-write surplus pass, so what it
returns is exactly what gets saved.

- `lines`: one per QBO line item with blueprint metadata, each with the QBO
  line item, metadata, `project_tracker` and `rules` (nil for internal-project
  lines without a tracker), `billed`, `commission_total`, `working_amount`,
  and `entries` (`role`, `payee` (a ForecastPerson), `amount`,
  `description_line`, `rate_override`).
- `payees`: one per ForecastPerson with `payable` and `blueprint` (role =>
  entries, the shape saved today) and `amount`.
  - `payable` is decided per payee, as the write does today: variable-hours at
    month end, or no admin user, or no full-time periods.
  - A payee whose total is zero is dropped, as today.
- Surplus is computed in memory with the same inputs the saved-state pass uses
  today: per IndividualContributor entry of a payable payee, working amount =
  line amount minus the line's *paid* commissions, `rules.surplus_for`, each
  lead's share = surplus x `surplus_lead_share`, paid to a lead only when that
  lead is payable and has (or, as a base payee, will have) a contributor.
- `retained_orphans`: existing payouts on the tracker whose ledger is not in
  the new payee set and whose cached QBO bill `has_payments?`. The write
  cannot destroy these, so they stay in the pool.
- Build performs no writes. `ensure_contributor_exists!` and
  `Ledger.find_or_create_for` stay in the write.

Build raises on the same malformed inputs generation raises on today (no or
multiple project trackers for a forecast project, missing records).

### `InvoicePayouts::MarginCheck` (new)

Input: a Build. Output: `cap`, `pool`, `post_commission_total`,
`payout_percentage`, `cap_percentage`, `breached?`, `over_by`, display rows per
line (billed, payouts, payout %, margin %, allowed, over, entries, whether the
line exceeds its own allowance), a row for retained orphans when present, and
an "unmapped / other" row. Pool = payable payees' amounts minus their
Commission entries, plus retained orphans' amounts minus theirs.

Per-line "allowed" is (billed - paid commissions) x (1 - treasury share of the
line's rules, or of the override when set). Per-line payouts include that
line's surplus shares.

### `InvoiceTracker#make_contributor_payouts!(created_by, build: nil)`

Writes `build.payees` (building one when not given): for each payable payee,
ensure the contributor and ledger, upsert the payout with the final blueprint
and amount, then destroy orphans (per-row rescue of `PaidQboBillError` as
today), run the commission-only auto-accept, and write descriptions. Every
save sets `skip_seventy_percent_check = true`: the pre-flight has ruled on the
final state.

One deliberate behaviour change: acceptance is preserved when the recomputed
*final* amount matches the existing one. Today the comparison uses the
pre-surplus amount, so any payout with a surplus share loses its acceptance on
every regenerate.

### Save-time validation

Renamed `contributor_payouts_within_cap`. It builds its list of payouts with
`self` substituted for its database copy (or appended when new), reads
commissions per line from the saved `Commission` entries' `blueprint_metadata.id`
(entries with no matching mapped line count as unattributed), and compares
against `InvoicePayouts::Cap`. Acceptance-only changes and
`skip_seventy_percent_check` skip it, as today. The message names the cap in
dollars and as a percentage of the post-commission total.

### Admin (`app/admin/contributor_payouts.rb`)

- `make_payouts`: non-admins get a redirect with "Admins only." (the file's
  existing pattern). Build + MarginCheck. A `StandardError` from Build
  redirects with "Could not calculate payouts: <message>".
  - Not breached: generate, "Payouts processed!".
  - Breached, no `force`: redirect to the index with `margin_breach=1`.
  - Breached, `force=1`, blank `override_reason`: redirect to the overlay with
    an alert; nothing written.
  - Breached, `force=1`, reason given: in one transaction, generate from the
    same Build and append to `notes` (blank line first, nil-safe):
    `[YYYY-MM-DD] <admin email> generated payouts over the cap (78.4% vs 67.0%): <reason>`.
- `create` / `update`: `skip_seventy_percent_check` is removed from the params
  for non-admins.
- Overlay: rendered only for admins, only when `params[:margin_breach]` is
  present and the re-run check is breached. If the re-run raises, no overlay.

### Overlay

Partial `app/views/admin/contributor_payouts/_margin_breach.html.erb`, using
the existing `.full-screen-modal` styles.

- Headline: "The generated payouts would be 78.4% of gross earnings. The cap
  for this invoice is 67.0%."
- Totals: billed (post-commission), generated payouts, allowed, over by.
- One block per line item: description, billed, payouts, payout %, margin %,
  allowed, over. Under each, every entry: role, payee email, amount, and the
  description line. IC entries from a rate override are marked "rate
  override"; entries for payees who are not paid are marked "not paid out"
  and excluded from totals. Lines over their own allowance are marked.
- Rows for retained paid payouts and for "unmapped / other", and a totals row.
- Form: required reason textarea, "Generate anyway", and a close link to the
  plain index.

## Tests

All run against real rows; `InvoiceTracker.any_instance.stubs(:qbo_invoice)`
for integration tests, since the action reloads the tracker.

- Build: existing `invoice_tracker_payouts_test.rb` cases pass through the new
  write path; surplus in memory equals what is saved; a full-time lead is not
  paid base or surplus; commission to a non-payable recipient; retained
  orphan detection.
- Cap: all-v1, all-v2, mixed, override, internal, commissions, unmapped
  remainder (with `total` stubbed above the line sum).
- MarginCheck: the reviewer's two-line case (cheap line + expensive override
  line, v1) breaches at 14,710 vs 14,000 once surplus is included.
- Validation: editing a persisted payout over the cap fails; same cap as the
  pre-flight; acceptance-only still skips.
- Action: breach redirects with the flag, asserts the breach was detected and
  no payouts exist; force with a reason writes payouts and the note; force
  without a reason writes nothing; non-admin is refused; a non-admin cannot
  set `skip_seventy_percent_check`; the overlay renders for an admin and not
  for a non-admin; a regenerate with changed payees succeeds.
- Deploy window: `margin_override` falls back when the attribute is absent.

The migration backfill is plain SQL and is verified by running the migration
against a scratch database, not by a test.

## Out of scope

- Blocking on a single over-ceiling line.
- Applying a ceiling to hourly rate overrides at generation time.
- Structured (queryable) override records; `notes` remains editable.
- Snapshotting the billing model per invoice.
