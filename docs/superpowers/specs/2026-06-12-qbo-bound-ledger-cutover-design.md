# QBO-Bound Ledger Cutover

A controlled, per-ledger cutover from the legacy balance model (negative ContributorAdjustments
and DeelInvoiceAdjustments deduct from balance) to a QBO-bound balance model (only the QBO Bill
"Paid" status drops a host from balance). The cutover is gated per-ledger by a "no resulting
difference" invariant so the financial controller migrates safely, ledger by ledger.

This spec also removes the LedgerWithdrawalRequest bundling apparatus we built earlier in this PR
(replaced by a direct Deel API call) and introduces a "Payable QBO Bills" controller-facing page
to drive the twice-monthly non-Deel payment cycle.

## Background

Today, a Ledger's balance is computed across four overlapping deduction mechanisms:

1. Positive hosts (ContributorPayout, ContributorAdjustment, ProfitShare, Trueup, PayStub) where
   `payable?` is true count into `balance`.
2. Negative ContributorAdjustments are inserted by hand to represent off-platform payments
   (Deel, S-Corp owner draws, BUS payments, etc.). They negatively offset balance.
3. DeelInvoiceAdjustments arriving via Deel sync deduct unless in a void/reject status
   (`deducts_balance?`).
4. SyncsAsQboBill hosts already write a QBO Bill mirror — but the bill's Paid status is
   informational; it doesn't affect Stacks balance.

The legacy world has been workable but is hard to reconcile: there are three places a payment
can be "recorded" and they must be kept consistent by hand. The cutover centralizes on the
QBO Bill Paid status as the single source of truth — a positive host stays in balance until its
corresponding QBO Bill is Paid in QBO.

A dry-run audit (`script/audit_qbo_cutover_balance_drift.rb`, deleted post-cutover) found that
under the broadest-scope new rule applied to all data, 26 contributors would see balance go
UP, 0 would go DOWN, and the net Σ Δbalance is +$82,430. Most of that is "in-flight payment
cycle" (latest month's bill not yet marked Paid in QBO) that will self-heal once the financial
controller works through the open bills; the remainder is a one-time correction to a small set
of historical ledgers with off-platform payment patterns that never had a corresponding positive
host.

## Goals

- Allow each Ledger to opt into the new model independently, with a hard guarantee that the
  flip does not change displayed balance/unsettled.
- Surface the migration as actionable work via the existing Task Builder system.
- Replace the contributor-driven withdrawal-request bundling flow with two simpler surfaces:
  - A direct Deel API call for contributors paid via Deel.
  - A cross-enterprise "Payable QBO Bills" page for the controller's twice-monthly pay cycle.
- Block the negative-CA pattern on qbo_bound ledgers so the cutover sticks.

## Non-goals

- Auto-marking QBO bills Paid from any Stacks-side flow (manual via QBO, per Q6 answer).
- Re-imagining Reimbursement or the salary/Justworks PayStub flow.
- Backfilling or modifying historical negative ContributorAdjustments — they sit as audit-only
  rows after migration.
- Building a finance-side dashboard beyond the per-ledger migration panel and the Payable QBO
  Bills page.

## Design Decisions (locked from brainstorm)

- **Q1**: On qbo_bound, only the QBO Bill "Paid" status determines whether a positive host drops
  from balance. Negative CAs and DIAs are audit-only.
- **Q2**: The Payable QBO Bills page shows bills where `ledger.payment_methods` includes `qbo`
  AND the underlying host is `payable?` (settled in Stacks) AND `qbo_bill.paid? == false`.
  Tabbed per QBO account.
- **Q3**: `payment_methods` is backfilled per-ledger from contributor data. With the final
  two-value enum (`deel`, `qbo`): non-US Deel contractor → `[deel]`; everyone else → `[qbo]`.
- **Q4**: Migration UI is a per-ledger button on the Ledger admin show page. Task Builder
  discovery generates one task per legacy ledger with activity.
- **Q5**: Page row actions: Open in QBO link + per-row Refresh + per-tab bulk Refresh.
- **Q6**: Manual mark-Paid in QBO — no Stacks-initiated QBO writes.
- **Q7**: Negative CAs on qbo_bound ledgers are rejected at model validation.
- **Q8 / clarification**: The Deel withdrawal trigger is the existing contributor-facing form,
  but it no longer persists a LedgerWithdrawalRequest. Submit calls Deel API directly.

## Architecture

### Schema

Add two columns to `ledgers`:

```ruby
add_column :ledgers, :mode, :integer, null: false, default: 0
add_column :ledgers, :payment_methods, :string, array: true, null: false, default: []
add_index  :ledgers, :mode
add_index  :ledgers, :payment_methods, using: :gin
```

`mode` is named to avoid Rails STI's reserved `type` column. The enum is
`{ legacy: 0, qbo_bound: 1 }`.

`payment_methods` is a Postgres `text[]` with values drawn from
`Ledger::PAYMENT_METHODS = %w[deel qbo].freeze`. GIN index supports the page-filter query
`WHERE 'qbo' = ANY(payment_methods)`.

The migration runs a data-driven backfill of `payment_methods` (mode stays `legacy` for every
existing row):

```ruby
Ledger.find_each do |ledger|
  contributor = ledger.contributor
  next if contributor.nil?

  # Contributor → DeelPerson (optional belongs_to via deel_person_id).
  # DeelPerson#data is the Deel-side JSON payload; country is a 2-letter
  # ISO code at data["country"] (verified by probing one record).
  dp = contributor.deel_person
  country = dp&.data.is_a?(Hash) ? dp.data["country"].to_s.upcase : nil
  is_non_us_deel = dp.present? && country.present? && country != "US"

  ledger.update_column(:payment_methods, is_non_us_deel ? %w[deel] : %w[qbo])
end
```

Default for any contributor without a Deel attachment is `["qbo"]` — they're paid via QBO
bill pay anyway and the Payable QBO Bills page is their lane.

### Runtime balance/unsettled rules

`Ledger#balance` and `Ledger#unsettled` branch on `mode`:

```ruby
def balance
  case mode
  when "legacy"    then visible_items.select(&:payable?).sum(&:signed_amount)
  when "qbo_bound" then qbo_bound_visible_items.select(&:in_balance_under_qbo_bound?).sum(&:signed_amount)
  end
end

def unsettled
  case mode
  when "legacy"    then visible_items.reject(&:payable?).sum(&:signed_amount)
  when "qbo_bound" then qbo_bound_visible_items.reject(&:in_balance_under_qbo_bound?).sum(&:signed_amount)
  end
end
```

`qbo_bound_visible_items` excludes `DeelInvoiceAdjustment` rows (audit-only) and negative
`ContributorAdjustment` rows (also audit-only).

Each host class gets `in_balance_under_qbo_bound?`:

- `ContributorPayout`, `ProfitShare`, `PayStub`, `ContributorAdjustment` (positive):
  `payable? && !qbo_bill&.paid?`
- `Trueup`: `!qbo_bill&.paid?` (Trueup has no `payable?`; it's always in balance until paid)
- `Reimbursement`: `accepted?` (no QBO involvement — same as legacy)

`items_grouped_by_month` continues to render historical negative CAs and DIAs for visibility —
display is independent of balance math.

### Model validations

```ruby
# app/models/contributor_adjustment.rb
validate :no_negative_on_qbo_bound_ledger

def no_negative_on_qbo_bound_ledger
  return unless ledger&.qbo_bound? && amount.to_f < 0
  errors.add(
    :amount,
    "negative adjustments are not allowed on QBO-bound ledgers — mark the corresponding QBO bill Paid instead",
  )
end
```

### Migration gate

```ruby
# app/services/ledgers/qbo_bound_migration_check.rb
class Ledgers::QboBoundMigrationCheck
  TOLERANCE = 0.01.freeze

  Result = Struct.new(
    :current_balance, :current_unsettled,
    :proposed_balance, :proposed_unsettled,
    :balance_delta, :unsettled_delta,
    :ready?, :blocking_bills, :ignored_negative_cas,
    keyword_init: true,
  )

  def self.call(ledger)
    legacy_b, legacy_u = compute_legacy(ledger)
    new_b,    new_u    = compute_qbo_bound(ledger)
    db = (new_b - legacy_b).round(2)
    du = (new_u - legacy_u).round(2)

    Result.new(
      current_balance: legacy_b, current_unsettled: legacy_u,
      proposed_balance: new_b,   proposed_unsettled: new_u,
      balance_delta: db,         unsettled_delta: du,
      ready?: db.abs < TOLERANCE && du.abs < TOLERANCE,
      blocking_bills: collect_blocking_bills(ledger),
      ignored_negative_cas: ledger.contributor_adjustments.where("amount < 0").to_a,
    )
  end
end
```

A `member_action :migrate_to_qbo_bound` on the Ledger admin show page invokes the service. If
`ready?`, flips `mode` to `qbo_bound`. Otherwise renders the discrepancy + blocking bills on
the panel for the controller to reconcile.

### Rake task for bulk auto-migration

```ruby
# lib/tasks/ledgers.rake
namespace :ledgers do
  desc "Flip every legacy ledger whose balance/unsettled would not change to qbo_bound"
  task migrate_qbo_bound_zero_drift: :environment do
    flipped, blocked, errors = 0, 0, 0

    Ledger.where(mode: :legacy).find_each do |ledger|
      result = Ledgers::QboBoundMigrationCheck.call(ledger)
      if result.ready?
        ledger.update!(mode: :qbo_bound)
        flipped += 1
      else
        blocked += 1
      end
    rescue => e
      errors += 1
      warn "Ledger ##{ledger.id}: #{e.class}: #{e.message}"
    end

    puts "Flipped #{flipped} ledgers; #{blocked} still blocked; #{errors} errors."
  end
end
```

Intended use: run after the schema migration, then re-run after each controller-reconciliation
session — anything that lands at net-zero flips automatically without manual button-pressing.

### Task Builder discovery

```ruby
# lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration.rb
class Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration <
  Stacks::TaskBuilder::Discoveries::Base

  PAYABLE_TABLES = %w[contributor_payouts contributor_adjustments profit_shares pay_stubs trueups].freeze

  def tasks
    Ledger
      .where(mode: :legacy)
      .joins(:enterprise)
      .where(enterprises: { id: Enterprise.joins(:qbo_account).select(:id) })
      .where("EXISTS (#{any_payable_subquery})")
      .includes(:contributor, enterprise: :qbo_account)
      .find_each.map do |ledger|
        task(
          subject: ledger,
          type: :legacy_ledger_needs_qbo_migration,
          owners: @admin_fallback,
        )
      end
  end

  private

  def any_payable_subquery
    PAYABLE_TABLES.map do |t|
      "SELECT 1 FROM #{t} WHERE #{t}.ledger_id = ledgers.id"
    end.join(" UNION ALL ")
  end
end
```

`StacksTask` already has a `when Ledger` branch in `subject_display_name` (uses
`"#{email} on #{enterprise.name}"`) — reusable as-is. The `subject_url` branch currently routes
every `Ledger` subject to `edit_admin_contributor_path(subject.contributor)`. We branch on
`type` so the migration task deep-links to the Ledger admin show page where the panel lives:

```ruby
# in StacksTask#subject_url
when Ledger
  if type == :legacy_ledger_needs_qbo_migration
    helpers.admin_ledger_path(subject)
  else
    helpers.edit_admin_contributor_path(subject.contributor)
  end
```

The Migrate panel renders inside `app/admin/ledgers.rb`'s `show` action via an
ActiveAdmin `sidebar` or inline panel.

### Payable QBO Bills page

Routed under the existing `app/admin/money.rb` ActiveAdmin page (currently a redirect).
Rewrite as:

```ruby
ActiveAdmin.register_page "Money" do
  menu priority: 50

  page_action :payable_qbo_bills, method: :get do
    @qbo_accounts = QboAccount.order(:id).to_a
    @active_qa    = params[:qbo_account_id].present? ? QboAccount.find(params[:qbo_account_id]) : @qbo_accounts.first
    @rows         = Money::PayableQboBills.call(qbo_account: @active_qa) if @active_qa
    render "admin/money/payable_qbo_bills"
  end

  page_action :refresh_bill, method: :post do
    host = host_from_params!(params)
    host.sync_qbo_bill!
    redirect_back(fallback_location: admin_money_payable_qbo_bills_path(qbo_account_id: params[:qbo_account_id]))
  end

  page_action :refresh_tab, method: :post do
    Money::RefreshPayableQboBills.call(qbo_account: QboAccount.find(params[:qbo_account_id]))
    redirect_back(fallback_location: admin_money_payable_qbo_bills_path(qbo_account_id: params[:qbo_account_id]))
  end
end
```

Row-selection service:

```ruby
class Money::PayableQboBills
  HOST_KLASSES = [ContributorPayout, ContributorAdjustment, ProfitShare, Trueup, PayStub].freeze
  Row = Struct.new(:host, :ledger, :contributor, :qbo_bill, :amount, keyword_init: true)

  def self.call(qbo_account:)
    rows = HOST_KLASSES.flat_map do |klass|
      klass
        .where.not(qbo_bill_id: nil)
        .joins(ledger: :enterprise)
        .where(enterprises: { qbo_account_id: qbo_account.id })
        .where("'qbo' = ANY(ledgers.payment_methods)")
        .includes(ledger: :contributor)
        .find_each.filter_map do |row|
          next nil unless row.payable?
          qb = row.qbo_bill rescue nil
          next nil if qb.nil? || qb.paid?
          Row.new(host: row, ledger: row.ledger, contributor: row.ledger.contributor, qbo_bill: qb, amount: row.amount.to_f)
        end
    end
    rows.sort_by { |r| [r.contributor.id, r.host.class.name, r.host.id] }
  end
end
```

Bulk refresh walks the same row set and calls `sync_qbo_bill!` on each host.

View layout:

- Top: tabs, one per QBO account, with `[Refresh all on this tab]` button.
- Body: rows grouped by contributor (sum + count in the group header), each row showing
  the host class, host ID, amount, an external link to the QBO bill, and a per-row Refresh
  button.

### Deel withdrawal trigger (replaces LedgerWithdrawalRequest)

The contributor-facing form (whatever its current path/UX — amount up to balance + contract
picker) is re-mounted as a `member_action :withdraw_via_deel` on `app/admin/contributors.rb`.
On submit:

```ruby
member_action :withdraw_via_deel, method: :post do
  ledger = Ledger.find(params.require(:ledger_id))
  unless ledger.deel_enabled?
    redirect_back fallback_location: admin_contributor_path(resource), alert: "Deel not enabled for this ledger."
    return
  end
  DeelInvoiceAdjustments::CreateForLedger.call(
    ledger: ledger,
    amount: params.require(:amount),
    contract_id: params.require(:contract_id),
    description: params[:description].to_s,
    date_submitted: params[:date_submitted].presence || Date.current,
    initiated_by: current_admin_user,
  )
  redirect_back fallback_location: admin_contributor_path(resource), notice: "Withdrew via Deel."
rescue DeelInvoiceAdjustments::CreateForLedger::Error => e
  redirect_back fallback_location: admin_contributor_path(resource), alert: e.message
end
```

`DeelInvoiceAdjustments::CreateForLedger` is the Deel-API-call core of the existing
`LedgerWithdrawalRequests::ProcessViaDeel` service, lifted out and de-coupled from the request
state machine. It calls Deel, persists a `DeelInvoiceAdjustment` row via
`DeelInvoiceAdjustment.create_from_deel_response!`, and raises a wrapped error on failure.

On qbo_bound ledgers the resulting DIA is audit-only — it appears in the timeline but does not
affect balance. The controller must mark the corresponding QBO bills Paid in QBO separately
(visible on the Payable QBO Bills page).

The trigger button is gated on `ledger.deel_enabled?` (i.e., `"deel"` ∈ `payment_methods`).

## Components and Boundaries

| Component | Purpose | Depends on |
|---|---|---|
| `Ledger#mode` enum + `#payment_methods` | Per-ledger feature flags + payout method list | n/a (schema column) |
| Per-host `#in_balance_under_qbo_bound?` | One-line predicate per host class deciding balance vs unsettled in the new rule | `qbo_bill`, `paid?`, `payable?`, `accepted?` |
| `Ledgers::QboBoundMigrationCheck` | Computes pre/post balance + unsettled, blocking bills | `Ledger`, `QboBill`, host classes |
| `Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration` | Emits one task per actionable legacy ledger | `Ledger`, `Enterprise`, `QboAccount` |
| `Money::PayableQboBills` | Selects rows for the page | host classes, `Ledger#payment_methods`, `QboBill` |
| `Money::RefreshPayableQboBills` | Bulk re-sync open bills for an enterprise | `SyncsAsQboBill#sync_qbo_bill!` |
| `DeelInvoiceAdjustments::CreateForLedger` | Wraps the Deel API call + persistence | Deel SDK, `DeelInvoiceAdjustment` |
| `lib/tasks/ledgers.rake :migrate_qbo_bound_zero_drift` | Bulk auto-flip | `QboBoundMigrationCheck` |

Each unit can be exercised in isolation:

- The migration check service takes a `Ledger` and returns a `Result` struct — no I/O beyond
  reading the ledger's host rows. Tests stub fixtures and assert deltas.
- The Payable QBO Bills page service takes a `QboAccount`, returns an array of `Row`. Tested
  by fixture combinations.
- The `CreateForLedger` service is the only place that touches the Deel API. Tested by
  stubbing the Deel HTTP client.
- The negative-CA validation is a single Active Record `validate` callback — tested via
  `valid?` assertions on a model instance.

## Data Flow

### Migration happy path

1. Schema migration runs; every ledger has `mode: :legacy` and a backfilled `payment_methods`.
2. Task Builder runs; one `:legacy_ledger_needs_qbo_migration` task per legacy ledger with
   activity appears in the controller's task list.
3. Controller opens a task → deep-links to the Ledger admin show page.
4. Migrate panel shows current vs proposed balance + Δ; if Δ < $0.01 on both, the Migrate
   button is enabled. Otherwise the controller sees the blocking bill list.
5. Controller marks bills Paid in QBO (via the linked URLs), comes back, clicks Re-check.
6. When ready, clicks Migrate. `mode` flips to `qbo_bound`. The task disappears on next discovery
   run.

### Payable QBO Bills happy path

1. Controller opens Money → Payable QBO Bills, picks a QBO account tab.
2. Page lists open bills with `payment_methods.include?(:qbo) && host.payable?`. Bills bound
   to Deel-only ledgers (e.g., non-US contractors) do not appear.
3. Controller pays bills in QBO (via per-row links).
4. Clicks "Refresh all on this tab" → bulk `sync_qbo_bill!` → newly-Paid bills drop from the
   list.

### Deel withdrawal happy path

1. Contributor opens their show page, clicks Withdraw via Deel (button visible iff
   `ledger.deel_enabled?`).
2. Form submits an amount (≤ current balance) → `DeelInvoiceAdjustments::CreateForLedger` calls
   Deel → DIA row persists.
3. On legacy: DIA deducts from balance (today's rule).
4. On qbo_bound: DIA is audit-only — visible in timeline, no balance impact. Controller
   separately marks corresponding QBO bills Paid via the Payable QBO Bills page.

## Error handling

- `DeelInvoiceAdjustments::CreateForLedger::Error` wraps Deel API failures so the controller
  redirects with a flash, not a 500.
- `Ledgers::QboBoundMigrationCheck` never raises; ineligible/empty ledgers return a Result with
  `ready?: true` (trivially) and an empty `blocking_bills` list — the rake task flips them
  freely.
- `Money::PayableQboBills` rescues `qbo_bill` access errors with `rescue nil` (existing
  pattern); a host with a broken QboBill linkage is skipped, not failed.
- Negative-CA-on-qbo_bound rejection happens at `valid?` time — no AR-level abort surprises.

## Code we delete (full deletion list)

| File | Disposition |
|---|---|
| `db/migrate/20260606135814_create_ledger_withdrawal_requests.rb` | Delete — never deployed; tables not needed |
| `app/models/ledger_withdrawal_request.rb` | Delete |
| `app/models/ledger_withdrawal_request_bill.rb` | Delete |
| `app/admin/ledger_withdrawal_requests.rb` | Delete |
| `app/views/admin/ledger_withdrawal_requests/_show.html.erb` | Delete |
| `app/views/admin/ledger_withdrawal_requests/_bills_panel.html.erb` | Delete |
| `app/views/admin/ledger_withdrawal_requests/_notes_panel.html.erb` | Delete |
| `app/services/ledger_withdrawal_requests/enumerate_candidate_bills.rb` | Delete |
| `app/services/ledger_withdrawal_requests/process_via_deel.rb` | Delete (Deel-call core extracted to `DeelInvoiceAdjustments::CreateForLedger`) |
| `lib/stacks/task_builder/discoveries/ledger_withdrawal_requests.rb` | Delete |
| Registration line in `lib/stacks/task_builder.rb` | Remove discovery from registry |
| References in `app/admin/deel_invoice_adjustments.rb` | Remove (any cross-links to withdrawal requests) |
| References in `app/models/admin_authorization.rb` | Remove (permission rules for the deleted admin page) |
| Splice into `app/views/admin/contributors/_show.html.erb` for `LedgerWithdrawalRequest` rendering | Remove |
| Contributor-side "new withdrawal" launch button in `app/admin/contributors.rb` | Repoint to new `withdraw_via_deel` action; remove withdrawal-request linkage |
| `Contributor#ledger_withdrawal_requests_with_deleted` + `preload_for_ledger_view!` add-ons | Remove |
| `Ledger#all_items_with_deleted` `LedgerWithdrawalRequest` line | Remove |
| `Ledger#has_many :ledger_withdrawal_requests` association | Remove |
| `StacksTask` `LedgerWithdrawalRequest` branches in `subject_display_name`, `subject_url` | Remove (Ledger branch repurposed for migration tasks) |
| `script/audit_qbo_cutover_balance_drift.rb` | Delete |
| `script/accountant_reconciliation_worklist.rb` | Delete |
| `script/why_balance_goes_up.rb` | Delete |

## Testing strategy

### Unit tests

- `Ledger#balance` / `#unsettled` mode-branching: one legacy fixture, one qbo_bound fixture
  with mixed paid/unpaid bills, neg CAs, DIAs — assert each rule's inclusion/exclusion.
- `Ledgers::QboBoundMigrationCheck`: three scenarios — ready (Δ < $0.01),
  blocked-by-open-bills (Δ > 0), blocked-by-neg-CA-mismatch (Δ > 0). Assert `blocking_bills`
  lists the right rows. Trivial-empty ledger returns ready.
- `ContributorAdjustment` negative-CA validation: allowed on legacy; rejected on qbo_bound
  with the right error message; positive CAs unaffected by mode.
- `Ledger#payment_methods` helpers: `deel_enabled?`, `qbo_enabled?` — array membership truth.
- `Money::PayableQboBills.call(qbo_account:)`: returns only `payable?` rows from ledgers
  whose `payment_methods` includes `qbo`; excludes Paid bills; sorts by contributor.
- `Money::RefreshPayableQboBills`: stubs `sync_qbo_bill!`, asserts called for each row.
- `DeelInvoiceAdjustments::CreateForLedger`: stubs Deel API, asserts DIA created with correct
  fields; raises wrapped error on Deel failure.
- `Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration`: legacy ledger with
  activity → task; qbo_bound ledger → no task; legacy ledger without QBO account → no task.
- `lib/tasks/ledgers.rake migrate_qbo_bound_zero_drift`: with mixed fixtures, flips only
  ready ledgers and reports counts correctly.

### Migration backfill test

A migration test that loads a snapshot fixture (US-Deel contributor, non-US-Deel contributor,
QBO-only vendor contributor) and asserts post-migration `payment_methods` matches the
inference rule.

### ActiveAdmin system tests

- Controller logs in, opens a legacy Ledger admin page, sees the Migrate panel with a
  discrepancy. Flips the underlying QBO bill Paid via fixture mutation. Clicks Re-check.
  Panel says Ready. Clicks Migrate. Ledger flips to `qbo_bound`.
- Controller opens the Payable QBO Bills page, sees rows for one QBO account, clicks
  per-row Refresh on a row whose QboBill fixture has flipped to Paid — row disappears.
- Contributor's show page renders the Withdraw via Deel button only when
  `ledger.payment_methods.include?("deel")`.

### Removed test coverage

The existing `LedgerWithdrawalRequest`-related model, service, and admin tests are deleted
along with the code. Substantive Deel-API-call coverage moves to
`DeelInvoiceAdjustments::CreateForLedger`'s tests — no loss of meaningful assertions.

## Rollout

1. Merge this PR. Schema migration runs, payment_methods backfilled.
2. Operator runs `bundle exec rake ledgers:migrate_qbo_bound_zero_drift`. Every ledger whose
   balance/unsettled wouldn't change flips immediately.
3. Task Builder runs (existing cron). Tasks appear for each remaining legacy ledger.
4. Controller works through tasks in the admin UI, reconciling bills in QBO and clicking
   Migrate.
5. Twice-monthly: controller works through the Payable QBO Bills page tab-by-tab to pay
   open bills.
6. Deel-only ledgers: contributor self-services via the Withdraw via Deel button as before.

When every ledger has flipped, the `legacy` branch of `Ledger#balance` can be removed and the
column dropped — out of scope for this PR.
