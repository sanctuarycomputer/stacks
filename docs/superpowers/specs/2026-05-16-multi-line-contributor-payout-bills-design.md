# Multi-line QBO bills for ContributorPayout

**Status:** Design approved 2026-05-16

## Problem

`ContributorPayout#sync_qbo_bill!` (via `SyncsAsQboBill`) currently pushes a single QBO Bill line item with the full payout amount. The blueprint that drove the payout amount already breaks the work down by role and source, but those distinctions are lost the moment we hit QBO. Finance can't attribute spend to different accounts (lead pay vs surplus shares vs commissions vs IC work) without re-deriving from the description text.

There's also a semantic bug in the current blueprint: `AccountLead` and `ProjectLead` arrays mix two kinds of pay — the 8%/5% base AND the 15%-of-surplus share — distinguishable only by description-text substring. Before we can route those to different QBO accounts, we need to separate them.

## Goal

A ContributorPayout, when reconciled, produces a multi-line QBO Bill with up to six lines, each routed to its own QBO account so finance can attribute spend by role and pay type.

When the payout isn't reconciled (blueprint sums disagree with the payout amount), fall back gracefully to the existing single-line behavior — never push a multi-line bill whose total wouldn't match `cp.amount`.

## The six buckets

| Bucket | Source in current blueprint | Recipient |
|---|---|---|
| `IndividualContributor` | `blueprint["IndividualContributor"]` | The contributor who did the hourly work |
| `AccountLeadBase` (8% of working amount) | Entries in `blueprint["AccountLead"]` whose `description_line` does NOT contain "surplus revenue" | The Account Lead |
| `AccountLeadSurplus` (15% of surplus) | Entries in `blueprint["AccountLead"]` whose `description_line` contains "surplus revenue" | The Account Lead |
| `ProjectLeadBase` (5% of working amount) | Entries in `blueprint["ProjectLead"]` whose `description_line` does NOT contain "surplus revenue" | The Project Lead |
| `ProjectLeadSurplus` (15% of surplus) | Entries in `blueprint["ProjectLead"]` whose `description_line` contains "surplus revenue" | The Project Lead |
| `Commission` | `blueprint["Commission"]` | Whoever's named on the ProjectTracker's `Commission` row |

No blueprint schema change. We discriminate AL/PL base vs surplus by parsing `description_line` at sync time (the heuristic is stable — the only writes that go into those buckets are produced by `InvoiceTracker#make_contributor_payouts!` and `InvoiceTracker` surplus distribution code, both of which write known description formats).

## Account routing

Naming convention: `"Contractors - {Role} - {Studio}"` where Studio is `contributor.forecast_person.studio.qbo_subcontractors_categories.first` (the existing convention used in `find_qbo_account!`).

Role strings: `"Individual Contributor"`, `"Account Lead"`, `"Account Lead Surplus"`, `"Project Lead"`, `"Project Lead Surplus"`, `"Commission"`.

Per-line lookup at sync time:

1. Compute the specific bucket account name.
2. Look it up in `qbo_account.fetch_all_accounts` by exact name match.
3. If found → use it for the line.
4. If NOT found → fall back to the per-bill default account from the existing `find_qbo_account!` (legacy "Contractors - Client Services" routing with internal-client override preserved for IC). The line still pushes; the bill is still multi-line; we just don't get per-bucket attribution for that one line.

This means a partially-configured QBO (some bucket accounts exist, some don't) still produces a useful bill. The admin can create missing accounts incrementally without blocking sync.

## Out-of-sync fallback

`ContributorPayout#in_sync?` already exists and checks whether `blueprint` sums equal `amount` to 2 decimal places. We reuse it.

At bill construction:

- `in_sync?` → build the multi-line bill (skip zero-amount buckets, fall back per-line to default account when missing).
- `not in_sync?` → build a single-line bill exactly as today (`amount = cp.amount`, account from `find_qbo_account!`, description from `bill_description`).

Never produce a multi-line bill whose line sums don't equal `cp.amount`. The single-line fallback is the safety net.

## Architecture

Three pieces:

**1. `app/models/contributor_payout_qbo_bill_lines.rb` — new module/class.**
Pure compute: given a `ContributorPayout` + the QBO account list, return either:
- An array of `{ amount:, description:, account: }` hashes (multi-line case), or
- A single-element array (single-line collapse case).

The bucket → role-string mapping lives here as a frozen constant. The discriminator that splits AL/PL into base vs surplus lives here. No QBO API calls inside this class — it receives the account list as input.

**2. `SyncsAsQboBill#bill_line_items` — new extension hook.**
A method that returns an `Array<Quickbooks::Model::BillLineItem>`. Default implementation produces a single line at the host's `find_qbo_account!` result (current behavior, refactored out of the inline `line_item` construction in `sync_qbo_bill!`). `ContributorPayout` overrides this to delegate to the new `ContributorPayoutQboBillLines` module.

**3. `sync_qbo_bill!` refactor.**
Replace the inline single-line construction with `bill.line_items = bill_line_items(qbo_accounts)`. All other models (`Trueup`, `ContributorAdjustment`, `ProfitShare`, `PayStub`) inherit the default single-line behavior — no changes needed.

## Edge cases

- **Zero-amount bucket:** skip the line entirely (don't push 0-value items to QBO).
- **Sum of multi-line items ≠ `cp.amount` (floating-point drift):** safety check after building. If `bill_line_items.sum(:amount).round(2) != cp.amount.to_f.round(2)`, fall back to single-line. Belt-and-suspenders against rounding in the per-bucket sums.
- **Total amount ≤ 0:** unchanged — `sync_qbo_bill!` already returns early in that case.
- **Internal-client payouts:** The existing `find_qbo_account!` override (flip to "Contractors - Marketing Services" when contributor is studio-less or on a client-services studio) applies to the IC line and any line that fell back to the default. AL/PL/Commission lines that DID find their specific bucket account are not flipped (they're routed by role, not by client-internal-ness).

## Out of scope

- Other `SyncsAsQboBill` hosts (`Trueup`, `ContributorAdjustment`, `ProfitShare`, `PayStub`) — unchanged.
- Blueprint schema migration — keep the existing 4-key shape; the base/surplus split happens at sync time via description parsing.
- Auto-creating missing QBO accounts.
- Per-forecast-project line splits within a bucket (chose consolidation in the brainstorm).

## Test plan

- Unit: `ContributorPayoutQboBillLines` returns the expected 6-bucket grouping for a synthetic blueprint covering all cases (AL base + surplus, PL base + surplus, IC, Commission, mixed studios, zero amounts).
- Unit: when payout `not in_sync?`, returns single-line collapse.
- Unit: when sum of multi-line items drifts, returns single-line collapse.
- Unit: when a bucket's specific account isn't in the qbo_accounts list, that line falls back to the default account.
- Existing `SyncsAsQboBill` tests for `Trueup` / `ContributorAdjustment` / `ProfitShare` / `PayStub` continue to pass unchanged (proves the default single-line path is preserved).

## Prerequisite (deploy-time)

Admin creates the bucket-specific QBO accounts in QBO (`Contractors - Account Lead - {Studio}`, etc.) for the studios that have contributors. Until those exist, lines fall back to the legacy account — so this PR can ship before the QBO chart is set up; finance gets progressively more attribution as accounts are added.
