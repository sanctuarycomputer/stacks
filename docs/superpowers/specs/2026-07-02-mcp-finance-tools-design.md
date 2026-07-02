# Design: MCP finance tools — `get_ar_aging` + `list_overdue_invoices`

**Date:** 2026-07-02
**Source:** [Stacksbot ROADMAP](https://www.notion.so/garden3d/ROADMAP-md-391131fea2c7801485e0d767177e0da3) Phase 1a + [SPEC — Stacks MCP upgrades](https://www.notion.so/garden3d/SPEC-Stacks-MCP-upgrades-391131fea2c78147a3aff77c7a6a5493)
**Status:** Approved by Hugh 2026-07-02. Late fees confirmed per-client/human-judged — tools expose data, not policy.

## Why this slice

The roadmap's ranked delivery order puts the **Operations pre-read** automation first, and it
depends on exactly two P1a tools: `get_ar_aging` and `list_overdue_invoices`. Both read
already-synced `QboInvoice` rows — no schema changes, no new syncs, no new auth. Smallest
slice that unblocks the top-ranked automation.

**Slice choice (confirmed).** Chosen over (a) shipping all eight P1a tools at once
(bigger review surface, no automation needs the rest yet) and (b) privacy hardening G1–G4
first (prerequisite only to *widening the corpus*, which this slice doesn't do).

## Approaches considered

1. **Two standalone tools, computed in-tool (chosen).** One file per tool following the
   existing `app/services/mcp/*_tool.rb` pattern; buckets and overdue status computed at call
   time from synced rows. Matches the spec's naming (automations reference the tools by
   name) and the "no persisted aggregate exists — that's fine" guidance.
2. **One combined `get_ar_report` tool.** Fewer round trips, but diverges from the spec's
   named tool contract and couples two different consumers (aging trend vs. chase list).
   Rejected.
3. **Persist a nightly AR-aging aggregate, tool reads it.** Faster reads, but the spec
   explicitly forbids new syncs, and the dataset (hundreds of invoices) doesn't need it.
   Rejected.

## Architecture

Two new tool classes registered in `Mcp::Server::TOOLS` (`app/services/mcp/server.rb`),
riding the existing `/api/mcp` route, shared `X-Api-Key` auth, and stateless transport.
Read-only annotations (`read_only_hint: true, destructive_hint: false, idempotent_hint: true`)
like the four corpus tools.

```
/api/mcp ──► Mcp::Server::TOOLS ──► GetArAgingTool ──┐
                                └──► ListOverdueInvoicesTool ──┤
                                                               ▼
                              QboInvoice (synced rows only) ── qbo_account ── enterprise
```

### Shared scoping + safety (both tools)

- **Synced-rows-only guard (critical).** `QboInvoice#data` lazily calls `sync!` (a live QBO
  API call) when the stored jsonb is empty (`app/models/qbo_invoice.rb:50-54`). Both tools
  filter in SQL — `WHERE data IS NOT NULL AND data != '{}' AND data->>'due_date' IS NOT NULL`
  — so the lazy fetch can never fire. A tool call must never trigger N live QBO requests.
- **Enterprise scoping.** `Enterprise has_one :qbo_account`; `QboInvoice belongs_to
  :qbo_account`. Optional `enterprise` string param (name match); default = all enterprises,
  grouped per enterprise in the payload.
- **Population.** Only invoices that are really receivables: `email_status == "EmailSent"`
  and `balance > 0`. Excludes `not_sent`, `voided`, and paid invoices. Filtering happens in
  Ruby via the existing model accessors (`#status`, `#balance`, `#due_date`) after the SQL
  synced-rows guard — dataset is small (agency-scale invoice counts), so no jsonb index work.

## Tool 1: `get_ar_aging`

- **File:** `app/services/mcp/get_ar_aging_tool.rb`
- **Params:** `enterprise` (optional string)
- **Buckets:** `current` (not yet due) + `1-30` / `31-60` / `61-90` / `over-90` days overdue,
  computed from `Date.today - due_date`. The spec names the four overdue buckets; `current`
  is added because an AR aging report without outstanding-but-not-due balances understates
  total AR and the Ops pre-read logs "AR total" as a trend. Bucket names were made truthful
  (day 0 = current; day 90 = 61-90; over_90 is strictly >90), matching QBO's own
  "91 and over" convention.
- **Grouping:** per enterprise → per customer (`customer_ref["name"]`), bucket sums of
  `#balance` (not `#total` — aging is about what's still owed), plus per-customer and
  per-enterprise totals and an overall `total_ar`.
- **Payload shape:**

```json
{
  "as_of": "2026-07-02",
  "enterprises": [
    {
      "enterprise": "Sanctuary Computer",
      "customers": [
        { "customer": "Acme Co", "current": 0.0, "days_1_30": 1200.0,
          "days_31_60": 0.0, "days_61_90": 0.0, "days_over_90": 500.0, "total": 1700.0 }
      ],
      "total_ar": 1700.0
    }
  ],
  "total_ar": 1700.0
}
```

## Tool 2: `list_overdue_invoices`

- **File:** `app/services/mcp/list_overdue_invoices_tool.rb`
- **Params:** `enterprise` (optional string), `min_days_overdue` (optional integer, default 1)
- **Rows:** invoices whose `#status` is `:unpaid_overdue` or `:partially_paid_overdue` (the
  model already computes these), with `days_overdue >= min_days_overdue`, sorted most-overdue
  first.
- **Fields per invoice:** `doc_number`, `customer`, `enterprise`, `total`, `balance`,
  `due_date`, `days_overdue`, `status`, `qbo_invoice_link`, `display_name`.
- **Late-fee flags (resolved).** Late fees are decided per-client by humans — there is no
  automated rule (confirmed by Hugh, 2026-07-02). The tools therefore **expose data, not
  policy**: `days_overdue` + `status` are the flags, and the Ops pre-read surfaces them for
  the per-client human call. No `late_fee_eligible` field.

## Error handling

- Unknown `enterprise` name → `MCP::Tool::Response` with a clear error text (not an
  exception), listing valid enterprise names.
- Rows with malformed `data` (missing `due_date` after the SQL guard shouldn't happen, but
  jsonb is untyped) → skipped defensively, never raise mid-report.
- No matching invoices → valid empty payload (`total_ar: 0`, `invoices: []`), not an error.

## Testing

- **Unit** (`test/services/mcp/tools_test.rb`): add `qbo_invoices.yml` fixtures covering
  paid / unpaid / unpaid-overdue / partially-paid-overdue / not-sent / voided / **empty-data
  (unsynced)** rows. Assert: bucket math at boundaries (day 30/31, 60/61, 90/91), balance-not-
  total summing, enterprise scoping, `min_days_overdue` filter, unknown-enterprise error, and
  — most importantly — that an unsynced row is excluded **without any network call** (stub
  `QboInvoice#sync!` to raise; suite must stay green).
- **Integration** (`test/integration/mcp_endpoint_test.rb:48`): the hard-coded sorted
  tool-name array becomes
  `%w[get_ar_aging get_document list_documents list_overdue_invoices list_sources search]`.

## Out of scope

The other six P1a tools, privacy hardening G1–G4, the Ops pre-read automation itself
(lives in Stacksbot config, not Stacks), any write surface, any new sync or schema change.
