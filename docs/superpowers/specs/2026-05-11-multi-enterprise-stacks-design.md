# Multi-Enterprise Stacks

## Background

Stacks today is implicitly Sanctuary Computer Inc. All invoicing, contributor bills, vendors, customers, items, and QBO P&L queries for Sanctuary route through a singleton `Stacks::Quickbooks` class backed by a single `QuickbooksToken` row and `Stacks::Utils.config[:quickbooks]` env credentials. The `Enterprise` model exists but is only used to pull P&L snapshot reports for one other company (Index); it has no role in billing.

`ForecastClient` has a hardcoded `INTERNAL_CLIENTS` list (`"garden3d"`, `"Sanctuary Computer"`, `"Seaborne"`, `"XXIX"`, `"XXXI"`, `"Crystalizer"`, `"Index Space LLC"`). Internal clients receive specialised billing treatment in three places (`ContributorPayout#find_qbo_account!`, `InvoiceTracker#qbo_item_for_person`, `InvoiceTracker#make_contributor_payouts!`, `ContributorPayout#contributor_payouts_within_seventy_percent`): they bill to a Marketing Services QBO account/item, skip the company-treasury split, and produce IC-only payouts (no AL/PL splits). But the resulting bills still post to Sanctuary's QBO file.

A contributor's "ledger" is a virtual aggregation computed at render time by `Contributor#new_deal_ledger_items` and `Contributor#new_deal_balance`, mixing seven separately-tabled types: `ContributorPayout`, `ContributorAdjustment`, `Trueup`, `MiscPayment`, `Reimbursement`, `ProfitShare`, `DeelInvoiceAdjustment`. The aggregation is a large type-switch with type-specific date and signed-amount handling.

## Goal

Promote Stacks to a true multi-enterprise platform:

1. Sanctuary Computer Inc, Garden3D LLC, Index Space LLC, USB Club LLC each become first-class `Enterprise` rows with their own QBO files and Deel legal entity mappings.
2. When hours are recorded against an internal forecast client whose name matches an Enterprise (e.g. "Garden3D LLC"), the resulting contributor payout posts a bill to that Enterprise's QBO file (not Sanctuary's) and lands on a separate per-Enterprise ledger for the contributor.
3. Each contributor's `/admin/contributors/:id` page shows tabs across the top — one per Enterprise the contributor has a balance with — and each tab shows that Enterprise's ledger items and balance independently.
4. QBO connections gain a proper OAuth "Connect QBO" flow per Enterprise, eliminating the manual terminal-pasted-refresh-token reconnect ritual.
5. The hardcoded `Stacks::Quickbooks` singleton and `QuickbooksToken` table retire entirely; every QBO call goes through `enterprise.qbo_account`.

Non-goal: changing the existing internal-client payout math (treasury split, marketing override, IC-only structure). `is_internal?` semantics remain intact and orthogonal to which Enterprise pays the bill.

## Design

### Core models

**Enterprise** (existing table extended)
- `name` — unique. Sanctuary's row uses `"Sanctuary Computer Inc"`.
- `deel_legal_entity_id` — string. Deel's `legal_entity.id` for this Enterprise; admin selects via dropdown.
- `has_one :qbo_account`
- `has_many :ledgers`
- `has_many :forecast_clients` — first-class FK relationship; see Forecast routing below.
- `Enterprise.sanctuary` — class method returning the Sanctuary row by name (`Enterprise.find_by!(name: "Sanctuary Computer Inc")`, memoised per request). Used as the implicit fallback for any forecast client without an Enterprise assignment. Sanctuary is fixed as the default for the foreseeable future, so no `is_default` flag is needed.

**QboAccount** (existing, ownership unchanged)
- Continues to `belongs_to :enterprise`, `has_one :qbo_token`.
- Gains `connection_status` enum: `:active`, `:revoked`, `:never_connected`. Set to `:revoked` when `make_and_refresh_qbo_access_token` hits `invalid_grant`; surfaces a "Reconnect QBO" banner on the Enterprise admin page.
- Sanctuary's `client_id` / `client_secret` / `realm_id` migrate out of `Stacks::Utils.config[:quickbooks]` env vars into Sanctuary's `QboAccount` row.

**Ledger** (new)
- `belongs_to :enterprise`
- `belongs_to :contributor`
- `has_many :ledger_items`
- Unique on `(enterprise_id, contributor_id)`.
- Find-or-created the first time a `LedgerItem` is written for a `(contributor, enterprise)` pair. Admins never provision ledgers manually.

**LedgerItem (STI)** (new — replaces six existing tables)
- Single `ledger_items` table with `type` STI discriminator.
- `belongs_to :ledger`. The contributor + enterprise are reached via `ledger`; no `contributor_id` or `enterprise_id` on the item.
- Subclasses (all moved from their own tables):
  - `ContributorPayout`
  - `ContributorAdjustment`
  - `Trueup`
  - `MiscPayment`
  - `Reimbursement`
  - `ProfitShare`
  - `LedgerWithdrawal` (new; see below)

Columns on `ledger_items`:

| Column | Notes |
|---|---|
| `type` | STI discriminator |
| `ledger_id` | not null |
| `amount` | decimal(12, 2) |
| `effective_on` | date; unifies `paid_at` / `payment_date` / `applied_at` / `effective_on` / `invoice_pass.start_of_month`. Set per-subclass at create time. |
| `description` | text |
| `blueprint` | jsonb; default `{}`. Used by `ContributorPayout`, `ProfitShare`. |
| `accepted_at` | datetime |
| `accepted_by_id` | FK `admin_users`; nullable |
| `created_by_id` | FK `admin_users`; nullable |
| `deleted_at` | acts_as_paranoid |
| `invoice_tracker_id` | nullable — `ContributorPayout` |
| `invoice_pass_id` | nullable — `Trueup` |
| `periodic_report_id` | nullable — `ProfitShare` |
| `qbo_bill_id` | nullable |
| `qbo_invoice_id` | nullable — `ContributorAdjustment` attachment |
| `deel_contract_id` | nullable — `LedgerWithdrawal` when method = `deel_contract` |
| `deel_adjustment_id` | nullable — populated by Deel's API on withdrawal create |
| `receipts` | text — `Reimbursement` |
| `withdrawal_method` | integer enum — `LedgerWithdrawal` only |
| `withdrawal_status` | string — `LedgerWithdrawal`: `pending` / `approved` / `paid` / `rejected` / `cancelled` |
| `metadata` | jsonb default `{}`; catch-all for type-specific extras (e.g. `MiscPayment#remittance`) |
| `created_at`, `updated_at` | standard |

Each subclass defines:
- `signed_amount` — `+amount` or `-amount` toward balance.
- `payable?` — boolean used by `Ledger#balance` to split payable vs unsettled.
- Any subclass-specific date accessor (e.g. `ContributorPayout#accrual_date` keeps working).

**LedgerWithdrawal**
```ruby
class LedgerWithdrawal < LedgerItem
  enum withdrawal_method: { deel_contract: 0 }
  # withdrawal_status: pending | approved | paid | rejected | cancelled
end
```
- Started by a contributor via a "Withdraw" UI on their ledger tab. The user picks a method; today only `deel_contract` is implemented, but the enum is in place for future ACH / Wise / etc.
- When method = `deel_contract`: form filters contracts to those whose `deel_legal_entity_id` matches the ledger's `enterprise.deel_legal_entity_id`. On submit, Stacks calls `POST /rest/v2/invoice-adjustments` on Deel with that `contract_id`, persists the returned `deel_adjustment_id` and initial status.
- A periodic background job polls `GET /rest/v2/invoice-adjustments/:id` for each non-terminal withdrawal and updates `withdrawal_status`. Terminal statuses freeze the row.
- `signed_amount` returns `-amount` (withdrawals deduct from balance).
- `payable?` returns `withdrawal_status.in?(%w[approved paid])`.

### DeelInvoiceAdjustment stays out of STI

`DeelInvoiceAdjustment` is the Stacks-side cache of records upserted from Deel's API. We do not modify its table or its upsert path. To attribute it to a ledger at render time, walk the chain:

```
DeelInvoiceAdjustment
  → deel_contract (FK exists)
  → deel_contract.deel_legal_entity_id  (NEW cached column on deel_contracts)
  → Enterprise.find_by(deel_legal_entity_id: ...)
  → Ledger.find_by(enterprise:, contributor: dia.contributor)
```

Only one schema change supports this: a new `deel_legal_entity_id` column on `deel_contracts`, populated at sync time from `data["client"]["legal_entity"]["id"]`. Backfill once; thereafter `Stacks::Deel#sync_contracts!` writes it on every sync. The `DeelInvoiceAdjustment` table itself never changes.

### QBO graph reorganises around QboAccount

QBO IDs are not globally unique across QBO files (Sanctuary's invoice #1234 and Garden3D's invoice #1234 are different rows). So:

- `QboInvoice belongs_to :qbo_account` — gain `qbo_account_id`, unique `(qbo_account_id, qbo_id)`.
- `QboBill belongs_to :qbo_account` — same.
- `QboVendor belongs_to :qbo_account` — same. A contributor exists as a different vendor row in each QBO file that pays them.
- No `enterprise_id` on these tables — walk up: `qbo_invoice.qbo_account.enterprise`.

Vendor lookup gains a per-enterprise helper:

```ruby
class Contributor
  def qbo_vendor_for(enterprise)
    QboVendor.find_by(qbo_account_id: enterprise.qbo_account.id, contributor_id: id)
  end
end
```

(The current `Contributor.qbo_vendor_id` column points at the Sanctuary vendor row. It stays during the transition for back-compat — `qbo_vendor_for(sanctuary)` returns the same record — and is dropped in a later cleanup PR.)

When `SyncsAsQboBill#sync_qbo_bill!` runs, it switches from `Stacks::Quickbooks.fetch_all_accounts` and `Stacks::Quickbooks.make_and_refresh_qbo_access_token` to `enterprise.qbo_account.fetch_all_accounts` and `enterprise.qbo_account.make_and_refresh_qbo_access_token`, where `enterprise = ledger.enterprise`. If a `Contributor` does not yet have a `QboVendor` in the target enterprise's QBO, the sync raises a clear "Provision vendor in {enterprise.name}'s QBO" error rather than silently misposting.

### Forecast client → Enterprise routing

`forecast_clients` gains a nullable `enterprise_id` foreign key — a first-class relationship rather than name matching.

```ruby
class ForecastClient
  belongs_to :enterprise, optional: true

  def billing_enterprise
    enterprise || Enterprise.sanctuary
  end
end
```

Setup:
- Garden3D LLC's forecast client gets `enterprise_id` pointing at the Garden3D LLC Enterprise.
- USB Club LLC's forecast client gets `enterprise_id` pointing at USB Club LLC.
- Index Space LLC's forecast client gets `enterprise_id` pointing at Index Space LLC.
- All other forecast clients (external like Adidas, internal-only-as-a-studio like XXIX / Crystalizer / Seaborne / "Sanctuary Computer") leave `enterprise_id` null → `billing_enterprise` returns `Enterprise.sanctuary`.

`is_internal?` keeps its hardcoded list and continues to gate the payout-math overrides (treasury split, marketing override, IC-only); the two concerns are orthogonal.

Future per-client overrides for external clients (e.g. Garden3D LLC eventually invoices its own external client) are already supported — just set `enterprise_id` on that forecast client.

Two billing flows fall out:

- **External work** (`!forecast_client.is_internal?`): `InvoiceTracker#make_invoice!` creates a QBO invoice in `forecast_client.billing_enterprise.qbo_account`. `make_contributor_payouts!` creates contributor payouts on a `Ledger` keyed by that same enterprise. Bills post to that enterprise's QBO.
- **Internal entity work** (`forecast_client.is_internal? && forecast_client.billing_enterprise != Sanctuary`, e.g. Garden3D LLC's own forecast client): no QBO invoice — Garden3D doesn't invoice itself. `make_contributor_payouts!` still creates `ContributorPayout`s, using the existing internal payout math (no treasury split, marketing override, IC-only), but on Garden3D LLC's ledger. Bills post to Garden3D LLC's QBO.
- **Internal Sanctuary work** (`forecast_client.is_internal? && forecast_client.billing_enterprise == Sanctuary`, e.g. XXIX, Crystalizer): no change from today's behaviour. Bills post to Sanctuary's QBO, items land on the Sanctuary ledger tab.

### QBO OAuth — "Connect QBO" button

Manual refresh-token entry retires. Intuit's OAuth2 flow handles reconnection.

**Routes:**
- `GET /admin/enterprises/:id/qbo/authorize` — redirects to Intuit's consent URL with `enterprise.id` encoded into the `state` parameter.
- `GET /admin/qbo/callback` — single global callback. Intuit only permits one redirect URI per OAuth app, so all enterprises share this endpoint. Reads `state` to identify the target enterprise, captures the `realmId` Intuit returns alongside the auth code, exchanges the code for `access_token` + `refresh_token`, writes everything onto that enterprise's `QboAccount` + `QboToken`.

**Intuit app config:** each `QboAccount` already stores its own `client_id` / `client_secret` / `realm_id` (Index uses this today). We keep that — each Enterprise either points at its own Intuit OAuth app, or admins can consolidate by reusing the same `client_id` / `client_secret` across multiple `QboAccount` rows (one Intuit app can authorise many QBO company files). The redirect URI registered in each Intuit app's dashboard is `/admin/qbo/callback`. The `dev@sanctuary.computer` account must have admin access to each QBO file being connected.

**UX:** the Enterprise edit page surfaces:
- A "Connect QBO" action item that initiates the OAuth flow.
- The connected QBO company name, realm_id, and "Last refreshed N minutes ago" once authorised.
- A "Refresh now" manual override action.
- A red "Reconnect QBO" banner when `qbo_account.connection_status == :revoked`.
- The existing manual `client_id` / `client_secret` / `realm_id` / `refresh_token` form fields stay (collapsed by default) as an emergency fallback.

**Token health:** `make_and_refresh_qbo_access_token` rescues `OAuth2::Error` `invalid_grant` and marks `qbo_account.connection_status = :revoked` instead of raising silently. A notification is emitted so the admin sees the broken state on the dashboard, not at the next failed bill sync.

### Deel mapping detail

- Single org-wide Deel API token in Rails credentials. All enterprises share it (since Deel's "legal entity" is the per-LLC concept inside one workspace).
- `Enterprise.deel_legal_entity_id` is set via a dropdown on the Enterprise edit page, populated by a live call to `GET /rest/v2/legal-entities`. Validation: each `deel_legal_entity_id` is assigned to at most one Enterprise.
- A "Test connection" button calls `GET /legal-entities/:id` and reports ✓/✗.
- `Stacks::Deel#sync_contracts!` parses `data["client"]["legal_entity"]["id"]` into the new `deel_contracts.deel_legal_entity_id` column on every sync. Backfill runs once during PR 1.

### Ledger UI

The contributor admin show page (`/admin/contributors/:id`) renders one tab per Enterprise the contributor has any historical or current ledger items with:

```
[ Sanctuary Computer Inc ]  [ Garden3D LLC ]  [ Index Space LLC ]  [ USB Club LLC ]
                                    ▲
                                 active

Balance: $4,820.00 ($150.00 unsettled)
──────────────────────────────────────
Apr 2026   Contributor Payout    Adidas (Inv #1234)    +$3,200.00
Mar 2026   Reimbursement          Domain renewal        +$  47.00
...
```

- Active tab is selected via `?ledger_id=:id` query param so admins can deep-link.
- Balance + unsettled are computed per-ledger: `ledger.balance`, `ledger.unsettled`. No cross-enterprise aggregate — each Enterprise is a separate money pool.
- `Contributor#new_deal_ledger_items` and `#new_deal_balance` move onto `Ledger` (`Ledger#items_grouped_by_month`, `Ledger#balance`) and become polymorphic. The aggregation collapses from the existing type-switch (7+ branches) into `ledger_items.sum(&:signed_amount)` with `payable?` and `signed_amount` defined per subclass. `DeelInvoiceAdjustment`s for the contributor are joined in at render time via the deel_contracts → legal_entity → enterprise chain described above.
- Each tab surfaces a "Withdraw" action when `enterprise.deel_legal_entity_id` is configured and the contributor has applicable Deel contracts under that legal entity. The action opens the `LedgerWithdrawal` form.

## Implementation phases

Six PRs, each independently shippable. PRs 1–3 carry out the STI cutover with dual-write for safety. PRs 4–5 are the QBO and Deel cutovers. PR 6 is the new withdrawal feature, can be sequenced anytime after PR 3.

### PR 1 — Enterprise + Ledger + STI scaffolding (invisible)

- `enterprises`: add `deel_legal_entity_id` (string, nullable).
- Seed `"Sanctuary Computer Inc"` Enterprise row. Existing Index row keeps its data, renamed to `"Index Space LLC"` if it isn't already. Add `Enterprise.sanctuary` class method.
- `forecast_clients`: add nullable `enterprise_id` FK with `add_foreign_key :forecast_clients, :enterprises`. No backfill at this stage — left null everywhere, so `billing_enterprise` returns `Enterprise.sanctuary` for every client (preserves today's behaviour). PR 5 sets the FK on the Garden3D / USB Club / Index forecast clients during cutover.
- New `ledgers` table — `enterprise_id`, `contributor_id`, timestamps, unique `(enterprise_id, contributor_id)`.
- New `ledger_items` table — all columns in the STI section above.
- New `deel_contracts.deel_legal_entity_id` column — backfill by parsing `data["client"]["legal_entity"]["id"]` for each existing contract row.
- Migration backfills: for every existing `ContributorPayout`, `ContributorAdjustment`, `Trueup`, `MiscPayment`, `Reimbursement`, `ProfitShare` row, find-or-create a Ledger with (Sanctuary, contributor) and insert a `ledger_items` row with the right `type`. Old rows stay in their tables.
- Add a thin shim: writes from every old AR class (`ContributorPayout`, `Trueup`, etc.) write to BOTH the old table and the new `ledger_items` table inside a transaction. Reads still hit old tables. This shim's only job is to keep the two stores in lockstep during the cutover window.
- Add the ledger UI tab bar to `/admin/contributors/:id`. Only Sanctuary's tab shows (since Sanctuary is the only seeded Enterprise) — same data as today, rendered the same way.

Behaviour visible to users: none.

### PR 2 — Read cutover

- Switch every read path that previously used `Contributor#new_deal_ledger_items` / `#new_deal_balance` / direct `ContributorPayout.where(...)` etc. to read from `LedgerItem` via the contributor's ledgers.
- Move the aggregation logic onto `Ledger`. Drop the giant type-switch.
- Validate side-by-side in production for at least one full invoice pass: a comparison view that renders both the old and new aggregations and flags any divergence. No divergence → green to proceed.

Behaviour visible to users: none.

### PR 3 — Drop dual-write, drop old tables

- Stop writing to old tables. Writes now go only to `ledger_items`.
- Drop the dual-write shim.
- Drop the old tables: `contributor_payouts`, `contributor_adjustments`, `trueups`, `misc_payments`, `reimbursements`, `profit_shares` (with their soft-deleted rows preserved as `ledger_items` rows in the appropriate `type`).
- Inline any remaining hard-coded class references (`acts_as_paranoid` callbacks, `has_many` associations on `Contributor` etc.) and re-point at `Ledger` / `LedgerItem`.

Behaviour visible to users: none (if the validation in PR 2 was clean).

### PR 4 — QBO OAuth + retire Stacks::Quickbooks

- Build `Admin::QboOauthController` with `authorize` and `callback` actions; wire to `GET /admin/enterprises/:id/qbo/authorize` and `GET /admin/qbo/callback`. Use Intuit's `intuit-oauth` (already in OAuth2 stack) to handle the exchange.
- Add `connection_status` to `qbo_accounts`. Wire `invalid_grant` rescues to flip it to `:revoked`.
- Move Sanctuary's `client_id`, `client_secret`, `realm_id`, current refresh_token from `Stacks::Utils.config[:quickbooks]` env vars into Sanctuary's `QboAccount` + `QboToken` rows.
- Add `qbo_account_id` to `qbo_invoices`, `qbo_bills`, `qbo_vendors`. Backfill all to Sanctuary's `QboAccount`. Replace the global `qbo_id` unique index with `(qbo_account_id, qbo_id)`.
- Replace every `Stacks::Quickbooks.X` call site with `enterprise.qbo_account.X` (where `enterprise` is derived from context: invoice → forecast_client.billing_enterprise; bill → ledger.enterprise; etc.). Touches `InvoiceTracker`, `SyncsAsQboBill`, `Stacks::Deel`'s adjacent paths, and admin pages.
- Delete `QuickbooksToken` model and table. Delete `Stacks::Quickbooks`.

Behaviour visible to users: a "Connect QBO" button replaces the manual token form; Sanctuary's bills still post to Sanctuary's QBO (unchanged target).

### PR 5 — Light up additional enterprises

- Create Garden3D LLC and USB Club LLC Enterprise rows.
- Connect each via the OAuth button — admin signs in to each QBO file once.
- For each new Enterprise:
  - Provision QBO vendor records for every Contributor who will be paid by this Enterprise (one-time admin task, can be automated by a rake task that calls `Stacks::Vendors.provision_for(enterprise)` and creates vendor records in that QBO).
  - Pick `deel_legal_entity_id` from the dropdown.
- Set `forecast_clients.enterprise_id` on the Garden3D LLC, USB Club LLC, and Index Space LLC forecast client rows to point at their matching Enterprise. The forecast client names don't need to match the Enterprise names — the FK is authoritative — but renaming for legibility is encouraged.
- Run the next invoice pass through `make_contributor_payouts!`. Internal-entity work now creates `ContributorPayout`s on the right Ledger and posts bills to the right QBO. Contributors see new tabs appear on their `/admin/contributors/:id` page automatically.

Behaviour visible to users: new tabs appear on contributor pages; bills route to multiple QBO files.

### PR 6 — LedgerWithdrawal

Can ship anytime after PR 3.

- Add the `LedgerWithdrawal` STI subclass behaviour (the table column is already present from PR 1).
- Add the "Withdraw" action on each ledger tab. Form: method (today only `deel_contract`), Deel contract (filtered by legal entity), amount.
- Server: call `POST /rest/v2/invoice-adjustments` via `Stacks::Deel.create_invoice_adjustment!`, persist `deel_adjustment_id` and initial status.
- Background job (cron, every N minutes): poll `GET /invoice-adjustments/:id` for each non-terminal `LedgerWithdrawal`. Update `withdrawal_status`. Terminal statuses freeze the row.

## Risks and mitigations

**Backfill correctness (PR 1).** The STI backfill is the single largest data-migration risk. Mitigation: the migration is idempotent (`INSERT … ON CONFLICT DO NOTHING` keyed by `(type, source_table_pk)` stored as `metadata['legacy_id']`). A reconciliation rake task compares row counts and aggregate totals per (contributor, type) between old and new and fails the migration if any cell diverges.

**Dual-write drift (PR 1–2).** If a code path slips through that writes to the old table only, the ledger goes wrong. Mitigation: the dual-write shim lives in `before_save` callbacks on every legacy AR class — there's no "alternate" write path. A nightly job during the dual-write window compares aggregate totals and pages on any divergence.

**`Contributor.qbo_vendor_id` legacy column (PR 4).** The current FK points at a Sanctuary-only vendor row. After multi-vendor support, `qbo_vendor_for(sanctuary)` resolves identically — keep the column until PR 5 fully validates, then drop in a follow-up cleanup PR.

**OAuth token expiry across enterprises (PR 4–5).** Each enterprise's refresh token has the same 100-day Intuit expiry. Without monitoring, every connection can go silently stale. Mitigation: a daily cron checks each `QboAccount.connection_status` and the age of its last successful refresh; an admin notification fires before the 100-day mark.

**Vendor provisioning gap (PR 5).** When Garden3D's QBO doesn't yet have a vendor record for Hugh, the first bill sync into it will fail. The clear error described in the QBO section catches this — admin provisions, retries, done. Acceptable failure mode; do not silently fall back to Sanctuary's vendor.

**`Stacks::Quickbooks.cleanup_orphaned_qbo_objects!` is global (PR 4).** That method iterates ALL bills across QBO and matches their `doc_number` against Stacks rows. It needs to become per-`QboAccount` — `enterprise.qbo_account.cleanup_orphaned_bills!` — and run for each enterprise.

**Forecast client cutover (PR 5).** The FK assignment is purely a database write — no Forecast-side action required for routing to work. If admins also rename the Forecast clients for legibility, the `ForecastClient` table is keyed by `forecast_id`, so the rename propagates on the next sync without breaking joins. Code that hardcodes `"garden3d"` (in `INTERNAL_CLIENTS`, in `Studio.garden3d`, in tests) only needs updating if those rows are renamed.

## Open questions

None blocking. The following will be resolved during PR execution:

- Exact set of QBO accounts/items to provision in each new Enterprise's QBO file (Contractors - Marketing Services, etc.) — copy Sanctuary's chart of accounts as a starting point.
- Whether `Studio.garden3d` callers still make sense once garden3d is an Enterprise — likely deprecated in favour of `Enterprise.find_by(name: "Garden3D LLC")` lookups.
- Whether to expose Enterprise switching in the ActiveAdmin top nav, or keep it scoped to each contributor's page. Default: keep scoped; revisit if admins start needing a global "all Garden3D LLC payouts this month" view.
