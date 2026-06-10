# QBO Bill Account Mapping Engine — Design

**Date:** 2026-06-10
**Status:** Approved (pending spec review)

## Problem

Every Stacks-managed QBO bill comes from one of five ledger-item models that
include `SyncsAsQboBill`: ContributorPayout, Trueup, ContributorAdjustment,
ProfitShare, PayStub. The QBO expense account for each bill line is chosen by
hard-coded rules scattered across five files:

| Line kind | Current rule | Location |
|---|---|---|
| Payout — IC / AL base / PL base | Name match `"Contractors - Client Services"`, overridden by studio's `"Contractors - <accounting_prefix>"` (garden3d: `"Total [SC] Subcontractors"`) | `syncs_as_qbo_bill.rb:42-55`, `studio.rb:668-673` |
| Payout — same, internal client | Name match `"Contractors - Marketing Services"` when `invoice_tracker.forecast_client.is_internal?` and studio is nil or client-services | `contributor_payout.rb:29-52` |
| Payout — AL surplus / PL surplus | Acct num `"5710"` (Bonuses) | `qbo_bill_lines.rb:41-45` |
| Payout — Commission | Acct num `"6120"` (Commissions) | `qbo_bill_lines.rb:44` |
| Trueup / ContributorAdjustment | Inherit the default chain | base concern |
| ProfitShare | Acct num `"2340"` (Accrued Profit Sharing), falls back to default chain | `profit_share.rb:39-48` |
| PayStub | Name match `"Facilities Management Salaries"`, raises if missing | `pay_stub.rb:65-72` |

We want this to be configuration, not code: per-entity (Enterprise) defaults
for every line kind, overridable per contributor and per project tracker.

## Decisions (made during brainstorming)

1. **Resolution precedence:** project tracker → contributor → entity
   default. Project tracker wins over contributor.
2. **Unmapped is a hard error.** No silent fallback to legacy code; the
   legacy hard-coded routing is deleted.
3. **Seed from current values.** A data migration writes mappings that
   reproduce today's behavior exactly, so day one is behavior-identical.
4. **Payout bucket lines split per project tracker** so each line can carry
   its own account.
5. **No studio level.** Three levels are easier to reason about than four.
   Today's studio routing is preserved at seed time as a one-time snapshot:
   contributor-level rows derived from each contributor's current studio.
   Mappings do not follow studio changes afterward; admins adjust the
   contributor rows.
6. **Chart of accounts is mirrored locally** as `QboChartAccount`, following
   the existing `QboVendor`/`QboBill` mirror pattern. (In the QBO API the
   object is `Account`; that name is taken locally by the realm-connection
   model, so the mirror is named `QboChartAccount`.)

## Components

### 1. `QboChartAccount` — chart-of-accounts mirror

Table `qbo_chart_accounts`:

- `qbo_account_id` (FK to `qbo_accounts`, the realm connection) — required
- `qbo_id` (QBO's immutable Account Id within the realm) — required
- `name`, `acct_num`, `classification`, `account_type` — denormalized for
  display and seeding
- `active` (boolean, default true)
- `data` (jsonb — full QBO payload, same convention as `QboVendor`)
- Unique composite index on `(qbo_account_id, qbo_id)`

Sync: `QboAccount#sync_chart_accounts!` upserts all accounts from
`Quickbooks::Service::Account#all` (what `fetch_all_accounts` calls today).
Rows that disappear from QBO are marked `active: false`, never deleted, so
mappings cannot dangle silently. Called from the daily sync task and from an
on-demand "Refresh chart of accounts" action on the Enterprise admin page.

### 2. `QboBillAccountMapping` — the rules

Table `qbo_bill_account_mappings`:

- `enterprise_id` (FK) — required; all mappings are entity-scoped
- `line_item_key` (string) — required, one of:
  `payout_individual_contributor`, `payout_account_lead_base`,
  `payout_account_lead_surplus`, `payout_project_lead_base`,
  `payout_project_lead_surplus`, `payout_commission`, `trueup`,
  `contributor_adjustment`, `profit_share`, `pay_stub`
- `subject_type` / `subject_id` (polymorphic, nullable) — `ProjectTracker`
  or `Contributor`; `NULL` means entity-level default
- `qbo_chart_account_qbo_id` (string) — required; resolved against
  `QboChartAccount` scoped by the enterprise's realm (composite lookup, the
  same style `SyncsAsQboBill#qbo_bill` uses)
- Unique index on `(enterprise_id, line_item_key, subject_type, subject_id)`

Validations: the referenced chart account must exist and be active for the
enterprise's `qbo_account`; `subject_type` must be one of the two allowed
classes when present.

### 3. `Qbo::BillAccountResolver`

One service replaces every `find_qbo_account!` override:

```ruby
Qbo::BillAccountResolver.new(enterprise)
  .account_for(line_item_key, contributor:, project_tracker: nil)
# => QboChartAccount
```

Lookup order for the `(enterprise, line_item_key)` pair:

1. `subject = project_tracker` (when given)
2. `subject = contributor`
3. `subject = NULL` (entity default)

First match wins. If no mapping matches, or the mapped chart account is
missing or inactive, raise `Qbo::UnmappedLineItemError` naming the
enterprise, line kind, and the subject chain tried. The error propagates
through the existing bill-sync error surfacing.

`SyncsAsQboBill#find_qbo_account!` and its overrides in ContributorPayout,
ProfitShare, and PayStub are deleted, along with
`Studio#qbo_subcontractors_categories`, `SPECIFIC_ACCT_NUM_BY_BUCKET`, and
`PROFIT_SHARE_LIABILITY_ACCT_NUM`. `bill_line_items` implementations take
account refs from the resolver. The bill push itself (vendor lookup,
doc_number, QBO API calls in `sync_qbo_bill!`) is unchanged.

### 4. Line generation changes

- **ContributorPayout** (`ContributorPayouts::QboBillLines`): group blueprint
  entries by `(bucket, project_tracker)` instead of by bucket alone. The
  project tracker for an entry comes from
  `blueprint_metadata["forecast_project"]` matched against
  `invoice_tracker.project_trackers` (the same lookup `calculate_surplus`
  uses). Entries with no resolvable tracker group into a per-bucket line
  resolved with `project_tracker: nil`. The existing safety behavior is
  kept: out-of-sync blueprints and drifted bucket sums collapse to a single
  line, resolved as `payout_individual_contributor` with
  `project_tracker: nil` (contributor → entity), matching today's
  collapse-to-default behavior.
- **PayStub**: lines are already grouped per forecast project; each group
  resolves its project tracker via `ProjectTracker#forecast_project_ids` and
  calls the resolver with it (`nil` when no tracker matches).
- **Trueup / ContributorAdjustment / ProfitShare**: single line, resolved
  with contributor context only.

### 5. Seeding migration

For each enterprise with a connected `QboAccount`: sync `QboChartAccount`
first, then write mappings reproducing today's behavior:

- **Entity defaults:** `payout_individual_contributor`,
  `payout_account_lead_base`, `payout_project_lead_base`, `trueup`,
  `contributor_adjustment` → account named `"Contractors - Client
  Services"`; `payout_account_lead_surplus`, `payout_project_lead_surplus` →
  acct num `5710`; `payout_commission` → acct num `6120`; `profit_share` →
  acct num `2340`; `pay_stub` → account named `"Facilities Management
  Salaries"`.
- **Contributor level (studio snapshot):** for each contributor whose
  current studio (`contributor.forecast_person.studio`) has an
  `accounting_prefix`, map the five contractor-services kinds (IC, AL base,
  PL base, trueup, adjustment) to the account named
  `"Contractors - <first prefix>"` (garden3d: `"Total [SC] Subcontractors"`).
  This is a one-time snapshot of today's studio routing; it does not follow
  later studio changes.
- **Project-tracker level:** for each project tracker whose forecast client
  is internal to the enterprise, map IC, AL base, and PL base to
  `"Contractors - Marketing Services"`.

Seeds that reference an account not present in the mirror are logged and
skipped; affected syncs then fail strictly with a clear error, which is the
agreed behavior.

### 6. Admin UI (ActiveAdmin)

- **Enterprise page:** "Bill Account Mappings" panel — the ten line kinds
  with an account select per kind (entity defaults), options from
  `QboChartAccount.where(qbo_account:, active: true)` labeled
  `"Name (acct_num)"`. Below it, a table of all override rows for the
  enterprise (subject, line kind, account) with CRUD. Plus the
  "Refresh chart of accounts" action.
- **ProjectTracker / Contributor pages:** a panel listing that subject's
  mapping rows with add/edit/remove, scoped per enterprise.
- The Enterprise admin page's existing live `fetch_all_accounts` call
  (`enterprises.rb:183`) switches to the mirror.

## Decision notes & accepted behavior changes

- **New internal-client project trackers** will not automatically route to
  Marketing Services; an admin sets the project-tracker mapping explicitly.
  If that proves tedious, a future `subject_type` of client/enterprise-client
  can be added without schema changes.
- **Single-line fallback for out-of-sync payouts** resolves
  `payout_individual_contributor` with no project tracker (i.e., contributor
  → entity), which matches today's collapse-to-default behavior.
- **Studio routing no longer follows studio membership.** The seeded
  contributor rows snapshot each contributor's studio account at migration
  time; when a contributor changes studios, an admin updates their
  contributor-level mappings (or removes them to fall back to the entity
  default).
- **Multi-tracker payouts produce more bill lines** than before (one per
  bucket × tracker). Totals are unchanged; QBO bill regeneration on already
  -synced bills will rewrite their line structure the next time they sync.
- Resolution context never consults `is_internal?` or account names/numbers
  at runtime — those concepts survive only as seeded data.

## Error handling

- `Qbo::UnmappedLineItemError < StandardError` with a message like:
  `Enterprise "Sanctuary" has no QBO account mapping for payout_commission
  (tried ProjectTracker#42, Contributor#7, entity default)`.
- Nightly chart-account sync logs a warning listing mappings whose chart
  account became inactive/missing, so finance hears about renames/deletions
  before a bill push fails.

## Testing

- Resolver: precedence order, each level, strict error paths (no mapping;
  inactive chart account).
- `QboBillLines`: per-(bucket × tracker) splitting, unattributable entries,
  out-of-sync collapse, totals always equal `cp.amount`.
- PayStub line generation with and without a matching project tracker.
- Seeding migration against fixture chart accounts, including the
  missing-account skip path.
- `QboChartAccount` sync upsert + deactivation behavior.
- Admin smoke tests for the enterprise mappings panel.

## Out of scope

- Renaming `QboAccount` (the realm connection) — acknowledged misnomer,
  separate refactor.
- Client-level mapping subjects (noted as the natural follow-on if internal
  project trackers churn).
- Any change to vendor selection, doc numbering, or bill push mechanics.
