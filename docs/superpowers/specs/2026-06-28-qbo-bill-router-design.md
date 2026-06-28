# QBO Bill Router — Design

**Date:** 2026-06-28
**Status:** Approved, ready for implementation plan

## Problem

The logic that decides which QuickBooks account a synced bill (and each of its
line items) lands in is scattered across at least six places:

1. `SyncsAsQboBill#find_qbo_account!` — default → `"Contractors - Client Services"`,
   overridden by a studio sub-category.
2. `SyncsAsQboBill#bill_line_items` — default single-line bill.
3. `ContributorPayout#find_qbo_account!` — internal-client → `"Contractors - Marketing Services"`.
4. `ContributorPayout#bill_line_items` → `ContributorPayouts::QboBillLines` — the
   per-bucket multi-line splitter (surplus → acct `5710`, commission → acct `6120`).
5. `ProfitShare#find_qbo_account!` — → acct `2340` (Accrued Profit Sharing).
6. `PayStub#find_qbo_account!` — → `"Facilities Management Salaries"`.

Plus `Studio#qbo_subcontractors_categories`, which builds studio-specific account
*names* from `accounting_prefix`.

Each `Enterprise` has its own `QboAccount` (its own QuickBooks realm and its own
chart of accounts), and the **same logical account has a different GL code in each
enterprise**. The scattered code mixes name-matching and hard-coded GL numbers that
silently assume cross-enterprise consistency, which does not hold. We want one
service object that owns the entire "which account(s) does this bill go to"
decision, driven primarily by GL codes.

## Goals

- A single service object is the only place that decides bill line-splitting and
  account selection.
- The decision is made from the ledger item itself (which derives ledger →
  enterprise → contributor → chart of accounts).
- Account selection is GL-code-driven and per-enterprise.
- It is called on every bill during the daily sync, reading the chart of accounts
  from a per-session cache (fetched once per enterprise per run, not once per bill).
- Behavior is preserved exactly; this is a consolidation, not a behavior change.

## Non-Goals

- No admin UI / data-driven mapping table. Rules live in code (a Ruby constant),
  per an explicit decision against the data-driven approach taken in the
  `qbo-bill-account-mapping-engine` worktree.
- No schema changes. All GL codes — including per-studio subcontractor codes — are
  hardcoded in the service constant.
- No change to vendor resolution, the `qbo_bill_id` composite-key plumbing, the
  `amount <= 0` guard, or the bill push/upsert mechanics in `sync_qbo_bill!`.

## Architecture

One object: **`Qbo::BillRouter`** (`app/services/qbo/bill_router.rb`).

> Single answer to: "given this ledger item, what QBO bill lines does it become,
> and which account does each line land in?"

```ruby
Qbo::BillRouter.new(ledger_item, accounts_cache: cache).lines
# => [ { amount:, description:, account: <Quickbooks account> }, ... ]
```

The ledger item is the only required input. The router derives everything else:
`item.ledger → enterprise → qbo_account → chart of accounts`, plus the contributor
and (where relevant) the studio and the invoice's client.

Internally, two layers:

### Layer 1 — Routing (pure business rules)

Looks at the item's **type**, its **blueprint buckets** (for payouts), the
contributor's **studio**, and **internal-client** status, and emits a list of
`(amount, description, concept)` lines. A *concept* is a symbol — no GL codes, no
chart of accounts, no API calls. Pure and trivially unit-testable.

Concepts:

| Concept | Meaning | Legacy account |
| --- | --- | --- |
| `:subcontractor` | studio-specific subcontractor cost | studio name via `accounting_prefix` |
| `:subcontractor_default` | fallback subcontractor cost | `"Contractors - Client Services"` |
| `:marketing` | internal-client marketing cost | `"Contractors - Marketing Services"` |
| `:bonuses` | account/project lead surplus | GL `5710` |
| `:commission` | commission | GL `6120` |
| `:profit_share_liability` | accrued profit sharing | GL `2340` |
| `:salaries` | pay stub salaries | `"Facilities Management Salaries"` |

Routing rules by item type:

- **`PayStub`** → one line, `:salaries`.
- **`ProfitShare`** → one line, `:profit_share_liability`.
- **`Trueup`, `ContributorAdjustment`** → one line, `:subcontractor` (if the
  contributor has a studio) falling back to `:subcontractor_default`.
- **`ContributorPayout`** → multi-line, one line per non-zero blueprint bucket:
  - `individual_contributor`, `account_lead_base`, `project_lead_base`
    → `:subcontractor` / `:subcontractor_default`
  - `account_lead_surplus`, `project_lead_surplus` → `:bonuses`
  - `commission` → `:commission`
  - **Internal-client override** — when
    `invoice_tracker.forecast_client.is_internal?`, the
    `:subcontractor`/`:subcontractor_default` lines become `:marketing`, *unless*
    the contributor's studio is a non-client-services studio (then they stay
    `:subcontractor`). Surplus and commission lines are never affected. This
    mirrors `ContributorPayout#find_qbo_account!` exactly.

Preserved safety behaviors (load-bearing, ported verbatim from
`ContributorPayouts::QboBillLines`):

- If `cp.in_sync?` is false → collapse to a single `:subcontractor_default` line at
  `cp.amount`.
- If the per-bucket line sum drifts from `cp.amount` after rounding → log a WARN
  and collapse to a single `:subcontractor_default` line.
- Blueprint parsing handles both the first-class surplus arrays
  (`AccountLeadSurplus` / `ProjectLeadSurplus`) and the historical mixed
  `AccountLead` / `ProjectLead` arrays distinguished by the
  `"surplus revenue"` description marker.
- Line descriptions keep the existing `"# <Role Label>"` header + per-entry
  description lines + `bill_description` format.

### Layer 2 — Resolution (concept → GL code → account)

Maps `(enterprise, concept) → GL code → concrete QBO account` from that
enterprise's chart of accounts.

The map is a Ruby constant in the service — `CONCEPT_GL_BY_ENTERPRISE` — keyed by a
stable enterprise identifier (the small known set: Sanctuary Computer, garden3d).
Per-studio subcontractor GL codes are nested inside it (no schema, no studio
model changes); Sanctuary's larger studio list makes its entry the chunky one.

```ruby
CONCEPT_GL_BY_ENTERPRISE = {
  "Sanctuary Computer" => {
    subcontractor_default:  "____",
    marketing:              "____",
    salaries:               "____",
    bonuses:                "5710",
    commission:             "6120",
    profit_share_liability: "2340",
    subcontractor_by_studio: {
      # "<studio key>" => "<gl code>",
    },
  },
  "garden3d" => {
    subcontractor_default:  "____",
    # garden3d routes all subcontractors to a single account today
    # ("Total [SC] Subcontractors"), so its studio map is trivial.
    # ...
  },
}.freeze
```

Resolution algorithm for a concept:

1. Resolve the concept's GL code. For `:subcontractor`, look up the studio's code
   in `subcontractor_by_studio` for the enterprise; for everything else, read the
   concept's code directly from the enterprise's entry.
2. Find the account whose `acct_num` equals that GL code in the enterprise's cached
   chart of accounts.
3. **Fallback chain, then raise:**
   - A missing `:subcontractor` (studio), `:bonuses`, or `:commission` account →
     fall back to `:subcontractor_default` (today's behavior).
   - A missing `:subcontractor_default`, `:salaries`, or `:profit_share_liability`
     account → raise a precise error naming the enterprise, concept, and GL code.
     Silently misrouting payroll or a liability is worse than failing the sync.

### Caching (per sync session)

The daily `stacks:sync_contributor_qbo_bills` rake task loops over every syncable
record. Today each `sync_qbo_bill!` calls `qa.fetch_all_accounts` — one chart fetch
**per bill**. Instead:

- A lightweight `accounts_cache` memoizes `qa.fetch_all_accounts` per
  `qbo_account_id`.
- It is created once at the top of the rake loop and threaded into every
  `Qbo::BillRouter` (and into `sync_qbo_bill!`), so the chart is fetched **once per
  enterprise per run**.
- Callers that don't pass a cache (e.g. a single-record sync, `Contributor#sync_qbo_bills!`)
  get a lazily-created cache scoped to that call, so the API contract stays simple.

The cache is a plain in-memory object (`Qbo::AccountsCache`, or just a `Hash`
keyed by `qbo_account_id`); no persistence, no `QboChartAccount` mirror table.

## Call Site

`SyncsAsQboBill#sync_qbo_bill!` replaces its `find_qbo_account!` + `bill_line_items`
+ inline `fetch_all_accounts` with:

```ruby
lines = Qbo::BillRouter.new(self, accounts_cache: accounts_cache).lines
bill.line_items = lines.map do |data|
  line = Quickbooks::Model::BillLineItem.new(description: data[:description], amount: data[:amount])
  line.account_based_expense_item! { |d| d.account_ref = Quickbooks::Model::BaseReference.new(data[:account].id) }
  line
end
```

Everything else in `sync_qbo_bill!` (vendor lookup, `amount <= 0` guard, doc number,
QboBill upsert, `qbo_bill_id` write) is unchanged.

## Deletions

Removed in the same PR once the router is green:

- `ContributorPayouts::QboBillLines` (whole class) and its specs (ported as
  characterization specs against the router).
- `SyncsAsQboBill#find_qbo_account!` and `#bill_line_items`.
- `ContributorPayout#find_qbo_account!` and `#bill_line_items`.
- `ProfitShare#find_qbo_account!`.
- `PayStub#find_qbo_account!`.
- `Studio#qbo_subcontractors_categories` (and its sole consumer, now the router).

`qbo_account_for_bill`, `qbo_bill`, `load_qbo_bill!`, `detach_and_destroy_qbo_bill`,
`qbo_url`, `payable?`, and the host contract methods (`bill_txn_date`,
`bill_description`, `bill_doc_number_code`) stay on `SyncsAsQboBill`.

## Testing (TDD, behavior-preserving)

- **Layer 1 routing specs** — pure, no DB/API. For each item type and each blueprint
  shape (IC/base/surplus/commission, first-class vs. historical surplus arrays,
  `in_sync?` false, rounding drift, internal-client with/without studio, non-client-
  services studio), assert the emitted `(amount, description, concept)` lines.
- **Layer 2 resolution specs** — given a fake chart of accounts + an enterprise:
  assert concept→account by GL code, the studio lookup, the fallback chain, and the
  raise cases.
- **Characterization specs** — port the existing `ContributorPayouts::QboBillLines`
  specs to assert the router produces identical lines, proving no behavior change.
- **Caching spec** — `fetch_all_accounts` is called once per `qbo_account` across
  multiple router invocations sharing a cache.

## Rollout

Single PR, no migration:

1. Build `Qbo::BillRouter` (+ cache) behind green unit/characterization specs.
2. Fill `CONCEPT_GL_BY_ENTERPRISE` blanks by inspecting each enterprise's live chart
   of accounts and the studio list; confirm values before finalizing.
3. Wire `sync_qbo_bill!` and the rake loop to the router, threading the cache.
4. Delete the scattered logic listed above.
5. Full suite green.

## Open Implementation Details (resolved during build, not blocking)

- Exact GL-code values for each enterprise/concept and the studio key scheme used in
  `subcontractor_by_studio` (studio name vs. `accounting_prefix`) — determined by
  inspecting live data, confirmed with the user before finalizing the constant.
- Whether the session cache is a named `Qbo::AccountsCache` class or a bare `Hash` —
  cosmetic; decided in the plan.
