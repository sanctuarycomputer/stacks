# MSO Management Fee Invoices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give garden3d one invoice tracker per paying company each month, let an admin create a $0.00 draft invoice for each in garden3d's QuickBooks with one click, and read garden3d's management fee income for a month from its P&L.

**Architecture:** A tracker's behaviour is a switch on its pass's issuing enterprise: Sanctuary is Forecast invoicing, garden3d is management fee, anything else raises. `Mso::ManagementFeeInvoices` owns the trackers and the draft push. `Mso::ManagementFeeIncome` reads account 4100 from garden3d's stored accrual P&L. `InvoicePass#management_fee_collected?` says whether the fee that was charged has been paid.

**Tech Stack:** Rails 6.1, Postgres, Minitest, Mocha 2.7, ActiveAdmin 2.9, quickbooks-ruby 1.0.17.

**Revision 2 (2026-10-12):** folds in an adversarial review. Adds Task 0 (cross-account invoice lookup), a start month and a QuickBooks pre-flight before any draft, a collection gate that fails closed and refreshes first, and scopes every behaviour change away from garden3d's seven legacy 2025 passes.

This is subsystem **S1** of `docs/superpowers/specs/2026-10-09-garden3d-mso-compensation-design.md` (§3, §4.1, §5.6, §6, §10, §11, §12). S0 is merged; S2 and S3 are on this branch. `MsoTrueup`, `MsoSnapshot`, `Mso::MonthlyRun` and the `BillRouter` GL concept are S4 and are not touched here.

## Decisions and open questions

Read this before the tasks. Each item is a judgement call or a place where the spec and the code disagree. Items marked **OWNER** need an answer from the owner; none of them blocks starting.

### The owner's constraint, and how the plan meets it

1. **Nothing pushes an invoice to QuickBooks unattended.** The nightly `stacks:daily_enterprise_tasks` creates garden3d's previous-month pass and its trackers, and the same for any earlier month since the start month that has none (the catch-up, item 31). That is database-only (`Mso::ManagementFeeInvoices.ensure_previous_month!`, Task 10) and a test asserts it makes no QuickBooks call, catch-up included. The QuickBooks write happens only when an admin clicks **Create management fee drafts** on garden3d's pass (Task 7) or **Regenerate** on one tracker (Task 6). No rake task, job or `Stacks::Automator` method calls `push_invoice!` or `create_drafts!`.
2. **The known nightly bug is left alone.** `Stacks::Automator.attempt_invoicing_for_invoice_pass` appears never to push on its first run because `make_trackers!` calls `statuses` (`app/models/invoice_pass.rb:51`), which loads an empty `invoice_trackers` association, and the loop at `lib/stacks/automator.rb:98-100` then iterates that stale empty list before `completed_at` is stamped at line 101. `test/models/invoice_pass_make_trackers_test.rb:38-39` documents the same staleness. This plan does not change that method, does not depend on it, and adds nothing to it. Its only edit to `make_invoice!` is a dispatch at the top.

### Where the spec is wrong about the code

3. **garden3d's passes are not all management-fee trackers, and the legacy ones are left exactly as they are.** Spec §6.4 says every tracker on a garden3d pass is one "by construction". The dev database (a production copy) has seven garden3d passes, ids 838–844 for 2025-06 … 2025-12, each holding one legacy Forecast-driven tracker for garden3d's own internal client 1151929: a blueprint, no invoice, accepted contributor payouts. `management_fee?` is still "the pass is garden3d's", as the spec asks. But every behaviour change keys on the narrower `InvoiceTracker#management_fee_invoice?` (on garden3d's pass **and** no blueprint), and a pass holding a blueprint-bearing tracker (`InvoicePass#legacy_forecast_trackers?`) is never drafted on. For those seven passes and trackers: status, payout pills, `configuration_errors`, `make_invoice!`, the page the pass renders, and what the MCP tool reports are all unchanged, and each has a test or a verification step saying so. **Who may see or change them is NOT unchanged any more:** the owner made every garden3d pass admin-only (item 25), these seven included.
4. **"The payer's internal client" is ambiguous.** Spec §6.5 assumes one internal Forecast client per payer. Sanctuary has five (607830, 769476, 1022451, 1087451, 1414417). `ensure_trackers!` uses the lowest `forecast_client_id`, and first reuses a tracker already on any of the payer's clients, so remapping clients never creates a second tracker. On the dev data this picks 607830, 1466083 and 1858301, the three the spec names in §3.
5. **There is a garden3d fixture.** Spec §3.6 and §12 say there is none. `test/fixtures/enterprises.yml:4-5` has one (S0 added it). There is no garden3d `QboAccount` fixture; S0's tests create one in `setup` (`test/models/invoice_pass_make_trackers_test.rb:7-8`). This plan does the same through a support module and does not add a fixture, because tests that already create their own would then have two and `has_one :qbo_account` is unordered.
6. **`lib/stacks/quickbooks.rb` does not exist.** QuickBooks reads live on `QboAccount` (`app/models/qbo_account.rb:132-173`) and the invoice write is inline in `InvoiceTracker#make_invoice!` (`app/models/invoice_tracker.rb:836-839`). The plan reuses `fetch_all_items`, `fetch_all_terms` and `fetch_all_customers`.
7. **`reconcile` cannot compare against invoice totals.** Spec §6.3 says to compare account 4100 with "the month's management-fee invoice totals", but §2 chose the P&L precisely because invoice totals will carry loan repayment lines. Comparing totals would report a variance in every such month. `reconcile` sums only the invoice lines whose item is `Managerial Services` (see item 32 for what that strictness costs).
8. **`reconcile` returns; `reconcile!` raises.** Spec §4.1 gives `reconcile` a hash return and says `Mso::MonthlyRun` raises on variance; spec §12 says "`reconcile` raises on variance". Both exist here. The hash also gains an `invoices:` breakdown the spec does not list.
9. **`InvoicePass#statuses` is fixed, not skipped.** Spec §6.4 says `statuses`, `payout_statuses` and the MCP tool must all skip management-fee trackers. With `InvoiceTracker#status` fixed, `statuses` on garden3d's pass reads correctly ("1x Not made, 2x Not sent"), which is what an admin needs to see, so it is left to work. `payout_statuses` does skip them. The MCP tool leaves out blueprint-less trackers on a garden3d pass, because its month-over-month series sums all passes for a month (`app/services/mcp/get_invoice_passes_tool.rb:44-45`) and an intercompany fee of $130k–$170k would be added to "total invoiced".
10. **"Anything else raises" applies to actions, not reads.** `InvoicePass#invoicing_kind` raises for a pass that is neither Sanctuary's nor garden3d's, and `make_invoice!`, `ensure_trackers!` and `push_invoice!` go through it. `management_fee?` and `forecast?` are plain booleans, so an admin index page listing a stray pass does not crash. No such pass exists (passes by enterprise: Sanctuary 64, garden3d 7).

### Things the real data shows that the spec does not cover

11. **A month with no fee has no row, and raises.** garden3d's December 2025 P&L has no 4100 row at all; QuickBooks omits accounts with no activity. `for_month` raises `RowMissing` there, as the spec requires, so "genuine $0" is distinguishable from a miss only when QuickBooks emits a `0.0` row. S4 has to decide what a `RowMissing` month means for a run.
12. **Invoice mirrors are never refreshed on a schedule, so the gate refreshes itself.** `QboAccount#sync_all_invoices!` (`app/models/qbo_account.rb:207`) has no caller. A `QboInvoice` row is re-read only when someone opens its tracker's page (`app/admin/invoice_trackers.rb:313-322`). And `push_invoice!` stores the invoice as an unsent $0.00 draft, which is exactly what "nobody was charged" looks like. So the collection gate has two entry points (Task 9): `Mso::ManagementFeeInvoices.collected?(invoice_pass:)` reads QuickBooks first and **raises** if any invoice cannot be read, and is what any payability decision must call; `InvoicePass#management_fee_collected?` is the pure rule over stored data. `QboInvoice#sync!` swallows errors and returns `false` (`app/models/qbo_invoice.rb:147-154`), so the refresh checks the return value and whether the row survived.
13. **An invoice is "charged" when it was sent OR carries an amount.** (Supersedes the earlier "sent means `EmailSent`" rule and its open question.) The spec's rule ignored every unsent invoice. But an invoice edited to a real amount and never emailed from QuickBooks still posts to accrual account 4100 and raises the cap; Sanctuary's own mirror has 53 unsent invoices with non-zero totals. Ignoring it would let the gate open while that fee is unpaid. New rule: ignored only when unsent **and** zero, or voided. This also answers the worry that Finance may record intercompany invoices as paid without emailing them: such an invoice is a charge, and paid, so it counts as collected.
14. **Fee invoices were made by hand for nearly every month since 2024-01.** garden3d's account 4100 is non-zero for 2024-01 through 2025-11 and 2026-01 through 2026-10 (the review listed fewer months; the stored P&L shows these). garden3d has no trackers for any of them and its invoice mirror is empty. Three defences: (a) `MANAGEMENT_FEE_START` (August 2026, item 31) — Stacks drafts nothing before it, the nightly job creates nothing before it, and the button is not shown; (b) a pre-flight read before every draft that refuses when QuickBooks already holds an invoice for that customer dated in the pass month, naming the ids; (c) `ensure_month!(date)`, database-only, so a hand-invoiced month can be given a pass and trackers to attach its invoices to. See Deploy.
15. **A voided invoice is not a charge.** (Supersedes the earlier "a voided sent invoice blocks the gate".) In Sanctuary's mirror, the 10 voided invoices that had been sent read `EmailSent` with total 0. The gate recognises the "voided" private note, as `QboInvoice#status` does for unsent ones (`app/models/qbo_invoice.rb:82`), and ignores the invoice. A sent $0.00 invoice that is **not** voided still blocks, per spec §3.2.
16. **Duplicate P&L rows exist.** 49 ranges have two stored reports (Sanctuary and Index Space; none is a garden3d month) and `find_or_fetch_for_range` returns an unordered `existing.first` (`app/models/qbo_profit_and_loss_report.rb:82`). The reader takes the newest row by id and never calls `find_or_fetch_for_range` when a row is stored.

### Smaller calls

17. **The draft carries no customer memo and no ACH flag.** The Forecast path sets `DEFAULT_CUSTOMER_MEMO`, which is Sanctuary's EIN and W-9 (`lib/stacks/system.rb:33-35`), and forces `allow_online_ach_payment` (`app/models/invoice_tracker.rb:755-757`). Neither belongs on garden3d's invoice.
18. **The payment term is matched by 15 due days**, as `ForecastClient#qbo_term` does (`app/models/forecast_client.rb:57`), not by the name "Net 15". The item is matched by name and never falls back to `Services`, which posts to the same income account.
19. **A stored customer id that is not an active customer raises.** `fetch_all_customers` returns active customers only (`app/models/qbo_account.rb:165-173`). An inactive or wrong id is a configuration error, never a reason to create a customer.
20. **USB Club's customer is created as "USB Club, LLC", and only if nothing already has that name.** With a blank stored id, an active customer whose name is exactly the payer's makes `push_invoice!` raise with that customer's id: it neither creates a second nor adopts the first by name. QuickBooks' own duplicate-name refusal (error 6240) is turned into the same configuration error. **Unverified:** QuickBooks is understood to keep display names unique across customers, vendors and employees together, including inactive ones. From data already mirrored locally: no garden3d **vendor** has exactly any payer's name, but one (QuickBooks vendor id 68) has USB Club's name once punctuation is ignored. If QuickBooks treats the two spellings as the same name, creating the customer is impossible and the push will raise the duplicate-name error; Finance would then create the customer by hand and its id be stored. Employees and inactive names are not mirrored. **OWNER / Finance:** check garden3d's QuickBooks for any vendor, employee or inactive customer named like USB Club before the first USB Club draft. Verification Step 5 repeats the local check.
21. **The mirror row is stored with the data QuickBooks returned.** The Forecast path leaves it blank (`app/models/invoice_tracker.rb:852`), which makes `QboInvoice#data` fetch from QuickBooks on first read (`app/models/qbo_invoice.rb:90-94`).
22. **`make_invoice!` returns a `QboInvoice` for a management fee invoice tracker**, per the spec's seam, where the Forecast path returns a `Quickbooks::Model::Invoice`. The **Regenerate** action checked for the latter (`app/admin/invoice_trackers.rb:221`) and would have reported failure on success, so it gets its own branch, a confirmation dialog, and a rescue for anything QuickBooks throws.
23. **A $0 sent invoice still shows a "Paid" pill.** `QboInvoice#status` is unchanged (`app/models/qbo_invoice.rb:74-75`). Only the collection gate treats it as not collected.
24. **The two new columns have no admin form.** `app/admin/enterprises.rb:5-17` does not permit them and any lead can edit an enterprise. They are seeded by the migration and changed from the console.
25. **garden3d's passes are admin-only, for every action including read.** DECIDED by the owner ("Yes admins only"), who was told it also hides the seven legacy garden3d passes (June–December 2025, ids 838–844) from leads. It replaces the earlier position, under which a full lead could read garden3d's fee pass and its trackers (and so the fee totals) and kept `:update` on the legacy trackers.
    - **The rule** is in `AdminAuthorization#authorized?`, above the blanket lead grant and above the scoped-grantee branch: for anyone but an admin, any action on an `InvoicePass` issued by garden3d, or on an `InvoiceTracker` on one, is refused. `InvoicePass#management_fee?` ("the pass is garden3d's") decides, so the legacy passes are included. Class-level `:read` on `InvoicePass` and `InvoiceTracker` is unchanged, so menus and the index pages still work.
    - **Index pages.** `scope_collection` drops garden3d's passes, and the trackers on them, for everyone but an admin (leads, scoped grantees and plain users alike). The passes index and the nested trackers index both go through it. Both indexes set `download_links: false`, and ActiveAdmin then refuses the index in JSON, CSV and XML to everyone, so there is no other format to go round by.
    - **The nested trackers controller** (`app/admin/invoice_trackers.rb`) asks the same rule of the parent pass in a `before_action`. ActiveAdmin authorizes an index against the class alone, and does not authorize a member action that never loads its record (`toggle_contributor_payout_acceptance`); without this a lead would get an empty index titled with the month, and that action would not be checked at all.
    - **The payouts pages under a garden3d tracker** (`app/admin/contributor_payouts.rb`, nested under invoice trackers) follow the tracker: index, new, create, Calculate Default Payouts, edit, update, destroy and the acceptance toggles are admin-only. Only the legacy trackers have payouts; a management fee invoice never does. **One thing is kept: a contributor can still read their own payout** (its show page), because it is the record of what they were paid. They can no longer accept or unaccept it from the tracker's page or the payouts pages. The Accept/Unaccept link on their own contributor page is a different route (`Contributor#toggle_contributor_payout_acceptance`, which checks that the payout is theirs) and is untouched. Every legacy payout is already accepted (`{:all_accepted=>1}` per pass), and unaccepting one in that state raises, as it did before.
    - **What a contributor paid on a legacy garden3d tracker still has:** their own contributor (ledger) page renders and lists the payout row as before, for them and for a lead; the row's link opens their own payout. Tested by URL.
    - **`MANAGEMENT_FEE_TRACKER_ADMIN_ACTIONS` is gone.** It made `:update` and `:attempt_generate` admin-only on a management fee invoice tracker; every such tracker is on a garden3d pass, so the new rule covers it, and the tests that covered it now assert the wider rule. `MANAGEMENT_FEE_PASS_ADMIN_ACTIONS` stays: it also keeps the two pass actions admin-only on Sanctuary's passes, where the new rule does not reach.
    - The tracker edit page's invoice dropdown listed every company's unattached invoices with customer and total (`app/admin/invoice_trackers.rb:362-367`). It lists only the tracker's own QuickBooks account's, and nothing at all for a non-admin, for whom the field is disabled anyway.
    - **Fixed on this branch (commit e41cce66), outside the numbered tasks.** Hiding the dropdown enforces nothing on the server: `qbo_invoice_id` and `qbo_account_id` are permitted params (`app/admin/invoice_trackers.rb:7`), so a lead could attach any mirrored invoice, garden3d's included, to a Sanctuary tracker they may update by sending the field directly, and then read its total on that tracker's page. That hole existed for Sanctuary's invoices and this plan would have given it garden3d's. The controller now drops those two params for non-admins on create and update, before mass-assignment; only an admin can change which invoice a tracker points at.
    - **Other routes to a garden3d pass or tracker, and what was done.** Closed: the pass and tracker pages, both indexes, and the payouts pages (above). Already closed before this decision: the adhoc-invoice and contributor-adjustment dropdowns (`QboInvoice.without_management_fees`); the Money page (admin-only). Left as they are, none showing a fee total: a project tracker's "Generated Invoices" table and a contributor's ledger page each name a legacy garden3d tracker that bills the project or pays the contributor (month, status, the project's own lines) and link to its page, which is now refused to a non-admin. The MCP tools are not per-user: they are reached with an API token, and API tokens are admin-only to issue; `get_invoice_passes` lists garden3d's pass rows but leaves the fee invoices out of every total, and AR aging and overdue invoices exclude them.
    - The spec's ownership table gives `admin_authorization.rb` to S4; these guards cannot wait for it.
26. **garden3d's pass is never stamped `completed_at`.** Nothing reads it for a garden3d pass, and S4 gates on Sanctuary's.
27. **The pass is for the previous month**, like Sanctuary's (`lib/stacks/automator.rb:165`), and the draft is dated the last day of that month.
28. **Ids are never hardcoded.** Item 2, term 2 and customers 2 and 5 are production facts; the item and term are resolved at push time and the customer ids live in the new column.
29. **Not covered by a test:** that a legacy garden3d tracker with payouts still reports `:all_accepted`. Building payouts in a test needs most of the payout pipeline. Verification Step 2 checks it against the seven real passes, which read `{:all_accepted=>1}` today.

### Added by the review

30. **Task 0: an invoice lookup must not cross QuickBooks accounts.** `HasQboInvoiceViaCompositeKey#qbo_invoice` returns whatever is in the association's memory without checking its account (`app/models/concerns/has_qbo_invoice_via_composite_key.rb:21-23`), and the association is preloaded by `qbo_id` alone in `app/admin/invoice_passes.rb:19`, `app/models/contributor.rb:183,187` and `app/models/project_tracker.rb:908`. Only Sanctuary's account has mirror rows today (1,831; no other account has any), so it is latent. This plan creates the first rows in a second account, after which a Sanctuary tracker could read a garden3d invoice and `ContributorPayout#payable?` could see `:paid` from it. Task 0 fixes the concern before anything else is built. Nothing in this plan reads a fee invoice through that association.
31. **DECIDED: `MANAGEMENT_FEE_START = Date.new(2026, 8, 1)`.** The owner: "the first month we're doing this is for the billing month of August". (It was the coordinator's default of October, awaiting confirmation.) What follows from August:
    - **August, September and October 2026 were already invoiced by hand.** Account 4100 reads 140000 / 135000 / 10000 for those months so far. They are draftable all the same, and that is intended: **Create management fee drafts** runs the pre-flight for each payer, finds the existing invoice, creates nothing, mirrors it, and reports it in the alert; the admin then attaches it from the tracker's edit page. Nothing else gates on the date: `draftable?` is the only check, and the button, the page wording and `NotDraftable`'s message all read the constant. An integration test walks the path (button shown, click refuses and lists the invoice, edit page offers it, attaching saves). See Deploy.
    - **The pre-flight only sees an invoice DATED in the pass month.** It asks QuickBooks for invoices to that customer with `TxnDate` inside the month. A hand-made invoice for August's fee that is dated in September is not found by August's click, and a second, $0.00 draft is created for August. The P&L figures above are by transaction date, so each of the three months does hold at least one invoice dated in it; whether every payer's does is not known from the stored data. **Finance: before clicking on August, September or October, check the invoice dates in QuickBooks.** A stray $0.00 draft is an ordinary unsent invoice Finance can delete.
    - **The nightly run catches up.** It used to create last month's pass only, so on the day this ships (October) August's and September's would never have been made. `ensure_previous_month!` now makes a pass and trackers for every month from the start month through last month that lacks them: bounded (it looks back `CATCH_UP_MONTHS` = 12 at most, and never before the start), idempotent, stepping over a month whose pass holds a legacy Forecast tracker, and still database-only. This also retires the old limitation that a month whose nightly run was missed never got a pass.
    - **October's pass does not exist until 1 November**, because the nightly run stops at last month. To work on October before then, open it by hand (Deploy).
    - **An admin can open a month without the console.** Money → Invoicing has an admin-only **Open garden3d month** control: a month picker listing every month from January 2024 through the current one that has no garden3d pass, and a button. It calls `ensure_month!`, so it is database-only (a test asserts no QuickBooks call), and it redirects to the pass. `LegacyPass` and any other `Mso::ManagementFeeInvoices::Error` come back as an alert. A lead is refused by URL (`AdminAuthorization`, `:open_management_fee_month`). With the catch-up above it is mainly for months before the start month, and for the current month.
32. **`reconcile` is strict, and a strict month blocks S4.** A fee line on the default item `Services` (which posts to the same account), or on a renamed item, counts in `account_total` but not in `payer_total`. `reconcile!` raises, and `Mso::MonthlyRun` will not run for that month until Finance moves the line to `Managerial Services` (or the item name constant is changed). The `invoices:` breakdown shows which invoice falls short. The strictness is kept deliberately: the alternative is to accept any line and lose the payer restriction spec §6.3 exists for.
33. **Known limitation: the tracker-to-payer link is not stored.** `push_invoice!` works out the payer from `EnterpriseForecastClient` at push time, and any lead can edit that mapping (`app/admin/enterprises.rb:8`). Remapping a Forecast client between enterprises before a draft is pushed would change which customer it bills. Storing the payer on the tracker would need a column the spec deliberately removed (§5.6).
34. **The pre-flight query has not been run against QuickBooks.** It is `SELECT * FROM Invoice WHERE CustomerRef = '<id>' AND TxnDate >= '<first>' AND TxnDate <= '<last>'` through `Quickbooks::Service::Invoice#query`. Its syntax follows the QuickBooks query language and the gem's `query` signature (`service_crud.rb:5-7`), and the tests stub it. This plan's rules forbid a QuickBooks call, so the first admin click is its first live run. If QuickBooks rejects the query, the click fails before writing anything.
35. **Existing bug, fixed on this branch (commit e41cce66), outside the numbered tasks: saving the tracker edit form detached its invoice.** `QboInvoice.orphans` excludes invoices already attached (`app/models/qbo_invoice.rb:19-29`), so the dropdown had no option for the tracker's current invoice; and for a non-admin the field is disabled and not submitted. In both cases the submitted value was blank, and `split_packed_qbo_invoice_value!` turned a blank into `qbo_invoice_id = nil`. Editing a fee tracker's notes after attaching a hand-made invoice would have detached it, and the gate would then have ignored that payer. Now: saving a tracker changes its invoice only when the field is actually submitted (an explicit "None" still detaches); the select lists the attached invoice first, selected; and a non-admin's `qbo_invoice_id` and `qbo_account_id` params are stripped on the server (item 25).
36. **`collected?` costs a QuickBooks read per attached invoice.** S4's `MsoTrueup#payable?` must not call it per ledger row. It should be called once per run or page and the answer reused (or stored on the snapshot). The earlier note that S4 could preload through the `invoice_trackers` association is withdrawn: the rule now uses fresh queries by `(qbo_account_id, qbo_id)`.
37. **`for_month` on the current month is partial.** The stored report is whatever the last nightly sync saw; October 2026 reads 10000.0 on the 12th.

## Global Constraints

- **No test may reach the network.** Every QuickBooks call is stubbed with Mocha. Use `stub_garden3d_qbo` from the support module (Task 2); it makes any invoice or customer write a test did not ask for raise a `RuntimeError`.
- **`create_drafts!` rescues `StandardError` per tracker**, which would swallow that `RuntimeError` into its `failed` list. Its tests therefore assert on `created` and `failed` explicitly; do not weaken those assertions. (Mocha's own expectation errors are not `StandardError` and are never swallowed. On Mocha 2.7.1 an `expects(...).never` that sits on top of an earlier stub falls through to the stub, so it is the stub's raise that catches a stray call.)
- `Enterprise.sanctuary` / `.garden3d` memoize in `Thread.current`. Every test class here calls `clear_enterprise_memos` in `teardown`.
- `has_many` caches go stale. Tests read a pass's trackers through a fresh `InvoicePass.find(id)` or a direct `InvoiceTracker.where(...)`.
- The sanctuary fixture has two `QboAccount`s and `has_one` is unordered. Pin Sanctuary's with `Enterprise.find(enterprises(:sanctuary).id).qbo_account`; resolve garden3d's with an ordered query.
- Money is `BigDecimal`, built from strings. Never `to_f`. The stored jsonb amounts are Strings (`"130000.0"`).
- Never call `QboProfitAndLossReport#find_row`. Never pass `true` as the third argument of `find_or_fetch_for_range`.
- Never read `QboInvoice#data` on a row that may be blank; use `read_attribute(:data)`.
- `db/schema.rb` is **hand-edited**. Never run `bin/rails db:migrate` (it re-dumps the file and reintroduces `enable_extension "vector"`). `check_pending!` aborts every test run if a migration is newer than the schema's version line, so Task 1 bumps it to `2026_10_13_000001`.
- Run tests with `--exclude "sync_meet runs the connector inside a SystemTask"`. Never run two test processes at once.
- Baseline before this plan: **1936 runs, 0 failures**. Verify with a full run before Task 0; if it differs, use what you measure. Each task states how many runs it adds.
- Commit after every task.

## File Structure

| File | Responsibility |
| --- | --- |
| `db/migrate/20261013000001_add_management_fee_payer_to_enterprises.rb` | Two columns and the payer seed |
| `db/schema.rb` | Hand-edited: version line and two columns |
| `app/models/concerns/has_qbo_invoice_via_composite_key.rb` | An invoice lookup never crosses QuickBooks accounts (Task 0) |
| `app/models/enterprise.rb` | Payer scope, the garden3d validation, the nightly hook |
| `app/models/invoice_pass.rb` | `invoicing_kind`, `management_fee?`, `forecast?`, `legacy_forecast_trackers?`, `payout_statuses`, `management_fee_collected?` (the pure rule) |
| `app/models/invoice_tracker.rb` | `management_fee?`, `management_fee_invoice?`, `status`, payout status, `configuration_errors`, `make_invoice!` dispatch |
| `app/services/mso/management_fee_invoices.rb` | Trackers, draft push and its pre-flight, drafts for a pass, refresh, `collected?` (the refreshing gate), `ensure_month!`, nightly ensure |
| `app/services/mso/management_fee_income.rb` | Account 4100 for a month; reconcile |
| `app/models/admin_authorization.rb` | Admin-only writes; scoped grantees cannot open garden3d's pass |
| `app/admin/invoice_passes.rb` | Two admin actions and the garden3d show page |
| `app/admin/invoice_trackers.rb` | Regenerate branch and confirmation; invoice dropdown scoped to the tracker's own QuickBooks account |
| `app/admin/contributor_payouts.rb` | Calculate Default Payouts refuses a management fee invoice |
| `app/views/admin/invoice_passes/_management_fee_pass.html.erb` | garden3d pass page body |
| `app/services/mcp/get_invoice_passes_tool.rb` | Leave intercompany fee invoices out of the totals |
| `test/support/management_fee_fixtures.rb` | Builders and QuickBooks stubs shared by the tests |

`app/models/qbo_profit_and_loss_report.rb` is not modified. The spec lists it under S1, but the reader needs nothing from it.

---

### Task 0: An invoice lookup never crosses QuickBooks accounts

**Do this first. Everything after it creates the condition that makes this bug live.**

A QuickBooks invoice id is unique only within one QuickBooks account. `HasQboInvoiceViaCompositeKey#qbo_invoice` knows that and looks up by `(qbo_account_id, qbo_invoice_id)`, but its first two lines return whatever is already in the association's memory without checking which account it belongs to (`app/models/concerns/has_qbo_invoice_via_composite_key.rb:21-23`). The underlying `belongs_to :qbo_invoice` matches on `qbo_id` alone, and it is preloaded that way in four places:

- `app/admin/invoice_passes.rb:19` (the Invoicing index)
- `app/models/contributor.rb:183` and `:187` (every contributor ledger page)
- `app/models/project_tracker.rb:908`

Today only Sanctuary's account (id 2) has mirror rows — 1,831 of them, and none for any other account — so a preload can only ever find the right row. This plan creates the first rows in a second account. QuickBooks ids are small integers in every account (garden3d's customers are 1, 2, 5 and 55), so the same id in two accounts is to be expected, not a rarity. After that a Sanctuary tracker's preloaded `qbo_invoice` can be a garden3d invoice, and `ContributorPayout#payable?` (`app/models/contributor_payout.rb:267-271`) reads `invoice_tracker.status == :paid` from it.

`Mcp::GetInvoicePassesTool` and `Money::QboBillSummary` already carry "NEVER preload :qbo_invoice" comments for this reason (`app/services/mcp/get_invoice_passes_tool.rb:30-34`, `app/services/money/qbo_bill_summary.rb:20-23`). The fix is to make the concern safe, so no caller has to remember.

**Files:**
- Modify: `app/models/concerns/has_qbo_invoice_via_composite_key.rb`
- Create: `test/models/concerns/has_qbo_invoice_via_composite_key_test.rb`

**Interfaces:**
- Consumes: nothing
- Produces: `#qbo_invoice` on `InvoiceTracker`, `AdhocInvoiceTracker` and `ContributorAdjustment` returns an in-memory invoice only when its `qbo_account_id` matches the host's; otherwise it looks the pair up.

- [ ] **Step 1: Write the failing test**

Create `test/models/concerns/has_qbo_invoice_via_composite_key_test.rb`:

```ruby
require "test_helper"

class HasQboInvoiceViaCompositeKeyTest < ActiveSupport::TestCase
  def setup
    # Sanctuary has two qbo_account fixtures; pin the one has_one picks.
    @sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    @other_qa = QboAccount.create!(enterprise: enterprises(:garden3d), realm_id: "g-#{SecureRandom.hex(4)}",
                                   client_id: "x", client_secret: "y")
    pass = InvoicePass.create!(start_of_month: Date.new(2089, 1, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 930_101, name: "Composite Key Co")
    @tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                      qbo_account: @sanctuary_qa)
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  def invoice!(qbo_account, qbo_id, total)
    QboInvoice.create!(qbo_account: qbo_account, qbo_id: qbo_id,
                       data: { "total" => total, "balance" => "0.0", "email_status" => "EmailSent",
                               "due_date" => "2999-01-01" })
  end

  test "a preloaded invoice from another QuickBooks account is not this tracker's invoice" do
    # Only the OTHER account holds invoice 1001, so a preload by qbo_id alone
    # can find nothing else. update_columns: the model's own validation would
    # (rightly) refuse this pair.
    invoice!(@other_qa, "1001", "170000.0")
    @tracker.update_columns(qbo_invoice_id: "1001")

    preloaded = InvoiceTracker.includes(:qbo_invoice).find(@tracker.id)

    assert_nil preloaded.qbo_invoice
    assert_equal :not_made, preloaded.status
  end

  test "with the same id in two accounts, the tracker reads its own account's invoice" do
    mine = invoice!(@sanctuary_qa, "1002", "500.0")
    theirs = invoice!(@other_qa, "1002", "170000.0")
    @tracker.update!(qbo_invoice_id: "1002")
    tracker = InvoiceTracker.find(@tracker.id)
    # Exactly what a preload by qbo_id alone can leave behind.
    tracker.association(:qbo_invoice).target = theirs

    assert_equal mine, tracker.qbo_invoice
    assert_equal 500.0, tracker.value
    assert_equal mine, tracker.qbo_invoice, "and the corrected row is what stays in memory"
  end

  test "an in-memory invoice from the tracker's own account is still used without a query" do
    mine = invoice!(@sanctuary_qa, "1003", "500.0")
    @tracker.update!(qbo_invoice_id: "1003")
    tracker = InvoiceTracker.includes(:qbo_invoice).find(@tracker.id)

    queries = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*| queries += 1 }
    assert_equal mine, tracker.qbo_invoice
    assert_equal 0, queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
bin/rails test test/models/concerns/has_qbo_invoice_via_composite_key_test.rb
```

Expected: 3 runs, 2 failures. The first gets the other account's invoice instead of `nil`; the second gets `theirs` and a value of 170000.0. The third passes: it pins the fast path that must survive.

- [ ] **Step 3: Write the fix**

In `app/models/concerns/has_qbo_invoice_via_composite_key.rb`, replace `qbo_invoice` (lines 18-32) with:

```ruby
  # Look up the QboInvoice using the composite key (qbo_account_id, qbo_invoice_id).
  #
  # The in-memory association target is trusted ONLY when it belongs to this
  # record's QuickBooks account. The belongs_to matches on qbo_id alone, and a
  # QuickBooks invoice id is unique only within one account, so a preload
  # (`includes(:qbo_invoice)`) can hand us another company's invoice with the
  # same id. Returning that would report its status and total as ours.
  def qbo_invoice
    in_memory = association(:qbo_invoice).target
    return in_memory if in_memory.present? && in_memory.qbo_account_id == qbo_account_id
    return nil unless qbo_invoice_id && qbo_account_id

    # Cache the lookup on the association target so repeated calls (payable?
    # → qbo_invoice gets hit hundreds of times when rendering ledger views)
    # don't re-query the same row. Also replaces a wrong-account target, with
    # nil when this account has no such invoice.
    result = QboInvoice.find_by(qbo_id: qbo_invoice_id, qbo_account_id: qbo_account_id)
    association(:qbo_invoice).target = result if result || in_memory.present?
    result
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/models/concerns/has_qbo_invoice_via_composite_key_test.rb
```

Expected: PASS, 3 runs, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 3 more runs than the baseline, 0 failures, 0 errors. Report the actual total. Tests that hand a tracker an invoice directly (`InvoiceTracker.new(qbo_invoice: QboInvoice.new)`, `test/models/invoice_tracker_test.rb:21-23`) still pass: both account ids are `nil`, which match. If a test fails here because it assigns an invoice from one account to a host bound to another, that test was relying on the bug; stop and report it rather than loosening the check.

- [ ] **Step 6: Commit**

```bash
git add app/models/concerns/has_qbo_invoice_via_composite_key.rb \
  test/models/concerns/has_qbo_invoice_via_composite_key_test.rb
git commit -m "fix(qbo): an invoice lookup never crosses QuickBooks accounts

A preloaded qbo_invoice is matched on qbo_id alone, and ids are unique only
within one QuickBooks account. The lookup trusted whatever was in memory, so
once a second account has mirrored invoices a tracker could read another
company's invoice, status and total included. It now trusts the in-memory
row only when the account matches."
```

---

### Task 1: Payer columns, seed and validation

**Files:**
- Create: `db/migrate/20261013000001_add_management_fee_payer_to_enterprises.rb`
- Modify: `db/schema.rb`
- Modify: `app/models/enterprise.rb`
- Create: `test/models/enterprise_management_fee_payer_test.rb`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `enterprises.management_fee_payer` (boolean, default false, not null), `enterprises.g3d_qbo_customer_id` (string)
  - `Enterprise.management_fee_payers -> ActiveRecord::Relation`
  - `Enterprise#is_garden3d? -> Boolean`
  - garden3d can never be saved with `management_fee_payer: true`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20261013000001_add_management_fee_payer_to_enterprises.rb`:

```ruby
class AddManagementFeePayerToEnterprises < ActiveRecord::Migration[6.1]
  # Enterprise name => that company's customer id in garden3d's QuickBooks
  # (realm 9130355602868216), verified against production on 2026-10-09.
  # USB Club has no customer there yet: Stacks creates one the first time an
  # admin pushes its draft, and stores the id then.
  PAYERS = {
    "Sanctuary Computer Inc" => "2",
    "Index Space, LLC" => "5",
    "USB Club, LLC" => nil,
  }.freeze

  # Migration-local model: no validations, no callbacks, and no dependence on
  # app/models/enterprise.rb as it changes over time.
  class PayerEnterprise < ActiveRecord::Base
    self.table_name = "enterprises"
  end

  def up
    add_column :enterprises, :management_fee_payer, :boolean, null: false, default: false
    add_column :enterprises, :g3d_qbo_customer_id, :string
    seed_payers!
  end

  # Rolling back drops any customer id Stacks stored after CREATING a customer
  # (USB Club's). Re-migrating then leaves that id blank again. That is safe:
  # with a blank id, Mso::ManagementFeeInvoices refuses to create a customer
  # when an active one already has the payer's exact name, and names its id so
  # it can be stored by hand. It does not create a duplicate.
  def down
    remove_column :enterprises, :g3d_qbo_customer_id
    remove_column :enterprises, :management_fee_payer
  end

  # Public so the test can run the seed against the schema-loaded test
  # database, where the columns already exist. Safe to run twice.
  def seed_payers!
    PayerEnterprise.reset_column_information

    PAYERS.each do |name, customer_id|
      enterprise = PayerEnterprise.find_by(name: name)
      next if enterprise.nil? # a database without this company (development, CI)

      attrs = { management_fee_payer: true }
      attrs[:g3d_qbo_customer_id] = customer_id if customer_id && enterprise.g3d_qbo_customer_id.blank?
      enterprise.update_columns(attrs)
    end
  end
end
```

- [ ] **Step 2: Hand-edit `db/schema.rb`**

Change the version line (currently `db/schema.rb:13`) to:

```ruby
ActiveRecord::Schema.define(version: 2026_10_13_000001) do
```

In `create_table "enterprises"` (`db/schema.rb:375-383`), add two lines directly below `t.string "pay_cycle_cadence"`:

```ruby
    t.boolean "management_fee_payer", default: false, null: false
    t.string "g3d_qbo_customer_id"
```

Confirm nothing else changed: `grep -c 'enable_extension "vector"' db/schema.rb` must print `0`, and `git diff --stat db/schema.rb` must show 3 insertions and 1 deletion.

- [ ] **Step 3: Load the schema into the test database**

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
RAILS_ENV=test bin/rails db:environment:set db:schema:load
```

Expected: no error. Make sure no test process is running first.

- [ ] **Step 4: Write the failing test**

Create `test/models/enterprise_management_fee_payer_test.rb`:

```ruby
require "test_helper"
require Rails.root.join("db/migrate/20261013000001_add_management_fee_payer_to_enterprises.rb")

class EnterpriseManagementFeePayerTest < ActiveSupport::TestCase
  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "an enterprise is not a payer unless flagged" do
    enterprise = Enterprise.create!(name: "Unflagged #{SecureRandom.hex(3)}")

    assert_equal false, enterprise.reload.management_fee_payer
    assert_nil enterprise.g3d_qbo_customer_id
  end

  test "management_fee_payers lists only flagged enterprises" do
    payer = Enterprise.create!(name: "Payer #{SecureRandom.hex(3)}", management_fee_payer: true)
    other = Enterprise.create!(name: "Other #{SecureRandom.hex(3)}")

    ids = Enterprise.management_fee_payers.pluck(:id)

    assert_includes ids, payer.id
    refute_includes ids, other.id
  end

  test "garden3d can never be flagged as a payer" do
    garden3d = enterprises(:garden3d)
    garden3d.management_fee_payer = true

    assert_not garden3d.valid?
    assert_includes garden3d.errors[:management_fee_payer],
      "cannot be set on garden3d, LLC: it issues the management fee"
  end

  test "garden3d saves normally while unflagged" do
    assert enterprises(:garden3d).update(pay_cycle_cadence: "monthly")
  end

  test "the migration seeds the three payers and the two verified customer ids" do
    sanctuary = enterprises(:sanctuary)
    index = Enterprise.find_or_create_by!(name: Enterprise::INDEX_SPACE_NAME)
    usb = Enterprise.find_or_create_by!(name: Enterprise::USB_CLUB_NAME)

    AddManagementFeePayerToEnterprises.new.seed_payers!

    assert_equal [true, "2"], sanctuary.reload.values_at(:management_fee_payer, :g3d_qbo_customer_id)
    assert_equal [true, "5"], index.reload.values_at(:management_fee_payer, :g3d_qbo_customer_id)
    assert_equal [true, nil], usb.reload.values_at(:management_fee_payer, :g3d_qbo_customer_id)
  end

  test "seeding never overwrites a customer id that is already stored" do
    sanctuary = enterprises(:sanctuary)
    sanctuary.update_columns(g3d_qbo_customer_id: "99")

    AddManagementFeePayerToEnterprises.new.seed_payers!
    AddManagementFeePayerToEnterprises.new.seed_payers!

    assert_equal "99", sanctuary.reload.g3d_qbo_customer_id
    assert sanctuary.management_fee_payer
  end

  test "seeding skips a payer that is absent and never flags garden3d" do
    Enterprise.where(name: [Enterprise::INDEX_SPACE_NAME, Enterprise::USB_CLUB_NAME]).delete_all

    assert_nothing_raised { AddManagementFeePayerToEnterprises.new.seed_payers! }

    assert_equal false, enterprises(:garden3d).reload.management_fee_payer
    assert_equal false, enterprises(:one).reload.management_fee_payer
  end
end
```

- [ ] **Step 5: Run it to verify it fails**

```bash
bin/rails test test/models/enterprise_management_fee_payer_test.rb
```

Expected: `management_fee_payers lists only flagged enterprises` errors with `NoMethodError: undefined method 'management_fee_payers'`, and `garden3d can never be flagged as a payer` FAILS because garden3d is valid. The seed tests pass already; that is expected, the migration exists.

- [ ] **Step 6: Write the model code**

In `app/models/enterprise.rb`, directly below `VERTICAL_MATCHER = /\[(.+)\](.*)/` (line 22), add:

```ruby

  scope :management_fee_payers, -> { where(management_fee_payer: true) }

  # garden3d issues the management fee; it can never also pay it.
  #
  # The has_attribute? guard matters: migrations are run by hand on production,
  # after the deploy. Until the column exists this validation must not run, or
  # every Enterprise save -- including the nightly generate_snapshot! -- raises.
  validate :garden3d_is_never_a_management_fee_payer, if: -> { has_attribute?(:management_fee_payer) }

  def garden3d_is_never_a_management_fee_payer
    return unless is_garden3d? && management_fee_payer?
    errors.add(:management_fee_payer, "cannot be set on #{GARDEN3D_NAME}: it issues the management fee")
  end
```

Directly below `is_index?` (lines 60-62), add:

```ruby

  def is_garden3d?
    name == GARDEN3D_NAME
  end
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
bin/rails test test/models/enterprise_management_fee_payer_test.rb
```

Expected: PASS, 7 runs, 0 failures.

- [ ] **Step 8: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 7 more runs than after Task 0, 0 failures, 0 errors. Report the actual total.

- [ ] **Step 9: Commit**

```bash
git add db/migrate/20261013000001_add_management_fee_payer_to_enterprises.rb db/schema.rb \
  app/models/enterprise.rb test/models/enterprise_management_fee_payer_test.rb
git commit -m "feat(mso): flag which companies pay garden3d's management fee

Sanctuary, Index Space and USB Club are payers; garden3d can never be one.
Each payer's customer id in garden3d's QuickBooks is stored, so an invoice
is never matched to a customer by name."
```

---

### Task 2: The three-way switch

A tracker's kind is its pass's issuing enterprise (spec §5.6). There is no column.

**Files:**
- Modify: `app/models/invoice_pass.rb`
- Modify: `app/models/invoice_tracker.rb`
- Create: `test/support/management_fee_fixtures.rb`
- Create: `test/models/invoice_pass_kind_test.rb`

**Interfaces:**
- Consumes: the payer columns (Task 1), only in the support module
- Produces:
  - `InvoicePass#forecast? -> Boolean`, `InvoicePass#management_fee? -> Boolean`
  - `InvoicePass#invoicing_kind -> :forecast | :management_fee`, raising `InvoicePass::UnsupportedIssuer` for any other enterprise
  - `InvoiceTracker#management_fee? -> Boolean` (false for a tracker with no pass)
  - `InvoiceTracker#management_fee_invoice? -> Boolean`: on garden3d's pass **and** no blueprint. False for the seven legacy Forecast trackers on garden3d's 2025 passes, which carry a blueprint.
  - `InvoicePass#legacy_forecast_trackers? -> Boolean`: the pass holds at least one blueprint-bearing tracker
  - `ManagementFeeFixtures`, a test support module (auto-required by `test/test_helper.rb:4`)

Why two tracker predicates: `management_fee?` is the spec's switch on the pass. But garden3d's seven 2025 passes each hold a legacy Forecast tracker with a blueprint and accepted payouts (Decisions, item 3), and those must keep behaving exactly as they do today. Everything that changes behaviour keys on `management_fee_invoice?`.

- [ ] **Step 1: Write the support module**

Create `test/support/management_fee_fixtures.rb`:

```ruby
# Builders for garden3d management fee tests.
#
# There is a garden3d Enterprise fixture but no garden3d QboAccount fixture,
# and adding one would give every test that already creates its own two of
# them (has_one :qbo_account is unordered). So it is created here.
module ManagementFeeFixtures
  def clear_enterprise_memos
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  def garden3d
    enterprises(:garden3d)
  end

  def garden3d_qbo_account
    @garden3d_qbo_account ||= QboAccount.create!(
      enterprise: garden3d, realm_id: "g3d-#{SecureRandom.hex(4)}", client_id: "x", client_secret: "y",
    )
  end

  def garden3d_pass(month)
    InvoicePass.create!(start_of_month: month, enterprise: garden3d, data: {})
  end

  # A management fee payer with one internal Forecast client per forecast id.
  def make_payer(name, customer_id: nil, forecast_ids: [rand(1_000_000..2_000_000_000)])
    payer = Enterprise.find_by(name: name) || Enterprise.create!(name: name)
    payer.update!(management_fee_payer: true, g3d_qbo_customer_id: customer_id)
    forecast_ids.each do |forecast_id|
      ForecastClient.create!(forecast_id: forecast_id, name: "#{name} internal #{forecast_id}")
      EnterpriseForecastClient.create!(enterprise: payer, forecast_client_id: forecast_id)
    end
    payer
  end

  def fee_tracker(pass, payer)
    client_id = EnterpriseForecastClient
      .where(enterprise_id: payer.id).order(:forecast_client_id).pick(:forecast_client_id)
    InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client_id, qbo_account: garden3d_qbo_account)
  end

  # Attaches a mirrored QuickBooks invoice. The stored data is never blank:
  # QboInvoice#data fetches from QuickBooks when it is.
  def attach_invoice(tracker, qbo_id:, total:, balance:, sent:, lines: nil)
    QboInvoice.create!(qbo_account: tracker.qbo_account, qbo_id: qbo_id, data: {
      "id" => qbo_id,
      "total" => total,
      "balance" => balance,
      "email_status" => sent ? "EmailSent" : "NotSet",
      "due_date" => "2999-01-01",
      "line_items" => lines || [fee_line(total)],
    })
    tracker.update!(qbo_invoice_id: qbo_id)
    InvoiceTracker.find(tracker.id)
  end

  def fee_line(amount, item: "Managerial Services")
    {
      "amount" => amount,
      "description" => "Management fee",
      "detail_type" => "SalesItemLineDetail",
      "sales_line_item_detail" => { "item_ref" => { "name" => item, "value" => "2" } },
    }
  end

  # --- QuickBooks ------------------------------------------------------------

  def qbo_item(id, name)
    Quickbooks::Model::Item.new.tap do |item|
      item.id = id
      item.fully_qualified_name = name
    end
  end

  def qbo_term(id, name, due_days)
    Quickbooks::Model::Term.new.tap do |term|
      term.id = id
      term.name = name
      term.due_days = due_days
    end
  end

  def qbo_customer(id, name)
    Quickbooks::Model::Customer.new.tap do |customer|
      customer.id = id
      customer.display_name = name
    end
  end

  def qbo_created_invoice(id, total: "0", balance: "0", email_status: "NotSet", private_note: nil)
    Quickbooks::Model::Invoice.new.tap do |invoice|
      invoice.id = id
      invoice.email_status = email_status
      invoice.total = BigDecimal(total)
      invoice.balance = BigDecimal(balance)
      invoice.private_note = private_note
      invoice.due_date = Date.new(2999, 1, 1)
    end
  end

  # What Quickbooks::Service::Invoice#query answers with.
  def qbo_collection(entries)
    Quickbooks::Collection.new.tap { |collection| collection.entries = entries }
  end

  # Stubs everything garden3d's QuickBooks would answer, and makes any write a
  # test did not ask for raise. A test that expects a write says so with its
  # own `expects`, which Mocha prefers over these stubs.
  #
  # `invoices_in_month` is what QuickBooks already holds for the customer in
  # the pass month: the pre-flight read push_invoice! makes before it writes.
  def stub_garden3d_qbo(items: nil, terms: nil, customers: [], invoices_in_month: [])
    items ||= [qbo_item("1", "Services"), qbo_item("2", "Managerial Services")]
    terms ||= [qbo_term("1", "Net 30", 30), qbo_term("2", "Net 15", 15)]
    default_item = items.find { |item| item.fully_qualified_name == "Services" }

    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token).returns(:access_token)
    QboAccount.any_instance.stubs(:fetch_all_items).returns([items, default_item])
    QboAccount.any_instance.stubs(:fetch_all_terms).returns(terms)
    QboAccount.any_instance.stubs(:fetch_all_customers).returns(customers)

    # The gem's access_token= rebuilds an HTTP connection from the token.
    Quickbooks::Service::Invoice.any_instance.stubs(:access_token=)
    Quickbooks::Service::Customer.any_instance.stubs(:access_token=)
    Quickbooks::Service::Invoice.any_instance.stubs(:query).returns(qbo_collection(invoices_in_month))
    Quickbooks::Service::Invoice.any_instance.stubs(:create)
      .raises(RuntimeError, "unexpected QuickBooks invoice write")
    Quickbooks::Service::Customer.any_instance.stubs(:create)
      .raises(RuntimeError, "unexpected QuickBooks customer write")
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/models/invoice_pass_kind_test.rb`:

```ruby
require "test_helper"

class InvoicePassKindTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def teardown
    clear_enterprise_memos
  end

  def pass_for(enterprise, month)
    InvoicePass.create!(start_of_month: month, enterprise: enterprise, data: {})
  end

  test "Sanctuary's pass is Forecast invoicing" do
    pass = pass_for(enterprises(:sanctuary), Date.new(2097, 1, 1))

    assert_equal :forecast, pass.invoicing_kind
    assert pass.forecast?
    refute pass.management_fee?
  end

  test "garden3d's pass is management fee invoicing" do
    pass = garden3d_pass(Date.new(2097, 2, 1))

    assert_equal :management_fee, pass.invoicing_kind
    assert pass.management_fee?
    refute pass.forecast?
  end

  test "any other enterprise's pass raises instead of defaulting to one kind" do
    pass = pass_for(enterprises(:one), Date.new(2097, 3, 1))

    error = assert_raises(InvoicePass::UnsupportedIssuer) { pass.invoicing_kind }

    assert_match(/One LLC/, error.message)
    refute pass.forecast?
    refute pass.management_fee?
  end

  test "a Sanctuary pass never looks garden3d up" do
    pass = pass_for(enterprises(:sanctuary), Date.new(2097, 4, 1))
    Enterprise.expects(:garden3d).never

    refute pass.management_fee?
    assert_equal :forecast, pass.invoicing_kind
  end

  test "a tracker on garden3d's pass is a management fee tracker" do
    tracker = InvoiceTracker.new(invoice_pass: garden3d_pass(Date.new(2097, 5, 1)))

    assert tracker.management_fee?
  end

  test "a tracker on Sanctuary's pass is not" do
    tracker = InvoiceTracker.new(invoice_pass: pass_for(enterprises(:sanctuary), Date.new(2097, 6, 1)))

    refute tracker.management_fee?
  end

  test "a tracker with no pass is not" do
    refute InvoiceTracker.new.management_fee?
    refute InvoiceTracker.new.management_fee_invoice?
  end

  test "a management fee invoice tracker is one on garden3d's pass with no blueprint" do
    pass = garden3d_pass(Date.new(2097, 7, 1))

    assert InvoiceTracker.new(invoice_pass: pass).management_fee_invoice?
    legacy = InvoiceTracker.new(invoice_pass: pass, blueprint: { "lines" => {} })
    assert legacy.management_fee?, "the pass is still garden3d's"
    refute legacy.management_fee_invoice?, "but a blueprint marks a legacy Forecast tracker"
    refute InvoiceTracker.new(invoice_pass: pass_for(enterprises(:sanctuary), Date.new(2097, 7, 1)))
      .management_fee_invoice?
  end

  test "a pass knows whether it holds a legacy Forecast tracker" do
    garden3d_qbo_account
    pass = garden3d_pass(Date.new(2097, 8, 1))
    payer = make_payer("Legacy Check #{SecureRandom.hex(3)}")
    tracker = fee_tracker(pass, payer)

    refute pass.legacy_forecast_trackers?

    tracker.update!(blueprint: { "lines" => {} })
    assert pass.legacy_forecast_trackers?
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bin/rails test test/models/invoice_pass_kind_test.rb
```

Expected: every test errors with `NoMethodError` (`invoicing_kind`, `management_fee?`) or `NameError: uninitialized constant InvoicePass::UnsupportedIssuer`.

- [ ] **Step 4: Write the implementation**

In `app/models/invoice_pass.rb`, directly below `has_many :invoice_trackers` (line 7), add:

```ruby

  class UnsupportedIssuer < StandardError; end

  # What a tracker on this pass IS depends on who issues the pass:
  #
  #   Sanctuary  -> Forecast-driven (blueprint, contributor payouts)
  #   garden3d   -> a management fee invoice to each paying company
  #   otherwise  -> unsupported
  #
  # There is no column for this; the enterprise decides.
  def forecast?
    enterprise == Enterprise.sanctuary
  end

  # Checks forecast? first so a Sanctuary pass -- nearly every pass -- never
  # depends on a garden3d row existing.
  def management_fee?
    return false if forecast?
    enterprise == Enterprise.garden3d
  end

  # For anything that ACTS on a pass. Index Space and USB Club both have
  # QuickBooks accounts, so a pass for either is constructible; treating it as
  # one of the two known kinds is how the wrong company gets invoiced.
  def invoicing_kind
    return :forecast if forecast?
    return :management_fee if management_fee?

    raise UnsupportedIssuer, "InvoicePass #{id} belongs to #{enterprise&.name || 'no enterprise'}. Only " \
                             "#{Enterprise::SANCTUARY_NAME} (Forecast invoicing) and " \
                             "#{Enterprise::GARDEN3D_NAME} (management fee) issue invoices."
  end

  # garden3d's 2025 passes each hold one Forecast-driven tracker (a blueprint,
  # accepted payouts) from before passes were per-enterprise. A pass holding
  # one is left exactly as it was: Stacks never drafts on it. Always a fresh
  # query, so it cannot read a stale association.
  def legacy_forecast_trackers?
    InvoiceTracker.where(invoice_pass_id: id).where.not(blueprint: nil).exists?
  end
```

In `app/models/invoice_tracker.rb`, directly below `delegate :billing_enterprise, to: :forecast_client` (line 21), add:

```ruby

  # A tracker on garden3d's pass bills a paying company its management fee.
  # It has no blueprint and no contributor payouts; Finance sets the amount in
  # QuickBooks. See InvoicePass#invoicing_kind and Mso::ManagementFeeInvoices.
  def management_fee?
    invoice_pass.present? && invoice_pass.management_fee?
  end

  # The narrower question every behaviour change asks: is this a tracker made
  # to bill a paying company its fee? True on garden3d's pass with no
  # blueprint. garden3d's seven 2025 passes each hold a legacy Forecast
  # tracker WITH a blueprint; those answer false and behave as they always have.
  def management_fee_invoice?
    management_fee? && blueprint.nil?
  end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/models/invoice_pass_kind_test.rb
```

Expected: PASS, 9 runs, 0 failures.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 9 more runs than after Task 1, 0 failures, 0 errors. Report the actual total.

- [ ] **Step 7: Commit**

```bash
git add app/models/invoice_pass.rb app/models/invoice_tracker.rb \
  test/support/management_fee_fixtures.rb test/models/invoice_pass_kind_test.rb
git commit -m "feat(mso): a pass's issuer decides what its trackers are

Sanctuary is Forecast invoicing, garden3d is management fee, and a pass for
any other company raises when something tries to act on it."
```

---

### Task 3: Management-fee trackers read correctly

Four things misread a tracker that has an invoice and no blueprint (`app/models/invoice_tracker.rb`):

- `status` returns `:impossible` (lines 128-142)
- `contributor_payouts_status` returns `:no_payouts`, so the pass index shows "1x No payouts" per tracker (lines 115-126)
- `configuration_errors` matches the customer by name in garden3d's QuickBooks, which is the lookup spec §6.2 forbids, and makes a QuickBooks call to do it (lines 226-232)
- `make_contributor_payouts!` crashes with `NoMethodError` on `blueprint["lines"]` (line 336)

Every change below leaves a tracker **with** a blueprint behaving as it does today. That matters: seven legacy garden3d passes each hold one (Decisions, item 3).

**Files:**
- Modify: `app/models/invoice_tracker.rb`
- Modify: `app/models/invoice_pass.rb`
- Create: `test/models/invoice_tracker_management_fee_test.rb`

**Interfaces:**
- Consumes: `InvoiceTracker#management_fee?` (Task 2), `ManagementFeeFixtures` (Task 2)
- Produces:
  - `InvoiceTracker#status` returns the invoice's own status for a management-fee tracker
  - `InvoiceTracker#contributor_payouts_status` returns `nil` for a management-fee tracker with no payouts
  - `InvoiceTracker#configuration_errors` returns `[]` for a management-fee tracker, with no QuickBooks call
  - `InvoicePass#payout_statuses` ignores trackers with no payout status

- [ ] **Step 1: Write the failing test**

Create `test/models/invoice_tracker_management_fee_test.rb`:

```ruby
require "test_helper"

class InvoiceTrackerManagementFeeTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    garden3d_qbo_account
    @payer = make_payer("Fee Payer #{SecureRandom.hex(3)}")
    @pass = garden3d_pass(Date.new(2096, 1, 1))
    @tracker = fee_tracker(@pass, @payer)
    # Any live sync would be a QuickBooks call.
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    clear_enterprise_memos
  end

  test "a tracker with no invoice is not made" do
    assert_equal :not_made, @tracker.status
  end

  test "an unsent draft reads as not sent, not impossible" do
    tracker = attach_invoice(@tracker, qbo_id: "fee-1", total: "0.0", balance: "0.0", sent: false)

    assert_nil tracker.blueprint
    assert_equal :not_sent, tracker.status
  end

  test "a sent, unpaid invoice reads as unpaid" do
    tracker = attach_invoice(@tracker, qbo_id: "fee-2", total: "130000.0", balance: "130000.0", sent: true)

    assert_equal :unpaid, tracker.status
  end

  test "a Sanctuary tracker with an invoice and no blueprint is still impossible" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2096, 2, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 940_001, name: "External Co")
    QboInvoice.create!(qbo_account: sanctuary_qa, qbo_id: "sc-1",
                       data: { "total" => "100.0", "balance" => "100.0", "email_status" => "NotSet" })
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                     qbo_account: sanctuary_qa, qbo_invoice_id: "sc-1")

    assert_equal :impossible, tracker.status
  end

  test "a legacy garden3d tracker with a blueprint and no invoice is still deleted" do
    @tracker.update!(blueprint: { "lines" => {} })

    assert_equal :deleted, @tracker.status
  end

  test "a management fee tracker has no payout status" do
    assert @pass.allows_payment_splits?, "sanity: the pass is in the payment-splits era"
    assert_nil @tracker.contributor_payouts_status
  end

  test "a Sanctuary tracker with no payouts still reports no payouts" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2096, 3, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 940_002, name: "External Co 2")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                     qbo_account: sanctuary_qa)

    assert_equal :no_payouts, tracker.contributor_payouts_status
  end

  test "garden3d's pass shows invoice statuses and no payout pills" do
    other = make_payer("Second Payer #{SecureRandom.hex(3)}")
    attach_invoice(fee_tracker(@pass, other), qbo_id: "fee-3", total: "0.0", balance: "0.0", sent: false)

    pass = InvoicePass.find(@pass.id)

    assert_equal({ not_made: 1, not_sent: 1 }, pass.statuses)
    assert_equal({}, pass.payout_statuses)
  end

  test "a legacy garden3d tracker's configuration errors are still the Forecast checks" do
    @tracker.update!(blueprint: { "lines" => {} })
    QboAccount.any_instance.stubs(:fetch_all_customers).returns([])
    QboAccount.any_instance.stubs(:fetch_all_terms).returns([])

    assert_equal [[:missing_qbo_customer], [:missing_qbo_term]], @tracker.configuration_errors
  end

  test "configuration errors are empty and look nothing up in QuickBooks" do
    QboAccount.any_instance.expects(:fetch_all_customers).never
    QboAccount.any_instance.expects(:fetch_all_terms).never

    assert_equal [], @tracker.configuration_errors
  end

  test "generating payouts for a management fee invoice raises a clear error" do
    tracker = attach_invoice(@tracker, qbo_id: "fee-4", total: "130000.0", balance: "0.0", sent: true)

    error = assert_raises(RuntimeError) { tracker.make_contributor_payouts!(nil) }

    assert_match(/no contributor payouts/, error.message)
    assert_equal 0, ContributorPayout.where(invoice_tracker_id: tracker.id).count
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/invoice_tracker_management_fee_test.rb
```

Expected: 11 runs, 6 failures or errors. `an unsent draft…` and `a sent, unpaid invoice…` get `:impossible`; `a management fee tracker has no payout status` gets `:no_payouts`; `garden3d's pass shows…` gets `impossible` and `no_payouts` entries; `configuration errors…` fails its `never` expectations; `generating payouts…` raises `NoMethodError` instead of the message. The other 5 pass: they pin behaviour that must not change.

- [ ] **Step 3: Write the implementation**

In `app/models/invoice_tracker.rb`, replace `contributor_payouts_status` (lines 115-126) with:

```ruby
  def contributor_payouts_status
    return @_contributor_payouts_status if defined?(@_contributor_payouts_status)

    @_contributor_payouts_status =
      if !invoice_pass.allows_payment_splits?
        nil
      elsif contributor_payouts.loaded? ? contributor_payouts.any? : contributor_payouts.exists?
        (contributor_payouts.loaded? ? contributor_payouts.all?(&:accepted?) : contributor_payouts.where(accepted_at: nil).none?) ? :all_accepted : :some_pending
      elsif management_fee_invoice?
        # A management fee invoice never has payouts, so "no payouts" is not a
        # state worth a pill. (A legacy garden3d tracker carries a blueprint, so
        # it never reaches this branch and reports exactly as before.)
        nil
      else
        :no_payouts
      end
  end
```

Replace `status` (lines 128-142) with:

```ruby
  def status
    if qbo_invoice.nil?
      if blueprint.nil?
        :not_made
      else
        :deleted
      end
    else
      # A management fee tracker never has a blueprint -- Finance sets the
      # amount in QuickBooks -- so for it "an invoice and no blueprint" is the
      # normal case, not an impossible one.
      if blueprint.nil? && !management_fee?
        :impossible
      else
        qbo_invoice.status
      end
    end
  end
```

Replace `configuration_errors` (lines 226-232) with:

```ruby
  def configuration_errors
    # These checks match the Forecast client to a QuickBooks customer BY NAME.
    # A management fee invoice resolves its customer by stored id instead, and
    # Mso::ManagementFeeInvoices.push_invoice! raises on anything missing.
    return [] if management_fee_invoice?

    err = []
    qa = qbo_account
    err << [:missing_qbo_customer] if forecast_client.qbo_customer(qa: qa).nil?
    err << [:missing_qbo_term] if forecast_client.qbo_term(qa: qa).nil?
    err
  end
```

In `make_contributor_payouts!`, directly below `return [] if qbo_invoice.nil?` (line 330), add:

```ruby
    if management_fee_invoice?
      raise "Management fee invoices have no contributor payouts (InvoiceTracker #{id})"
    end
```

In `app/models/invoice_pass.rb`, replace `payout_statuses` (lines 26-30) with:

```ruby
  def payout_statuses
    return [] unless allows_payment_splits?
    # compact: a management fee tracker has no payout status at all.
    status = invoice_trackers.map(&:contributor_payouts_status).compact
    status.inject(Hash.new(0)) { |h, e| h[e] += 1 ; h }
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/models/invoice_tracker_management_fee_test.rb
```

Expected: PASS, 11 runs, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 11 more runs than after Task 2, 0 failures, 0 errors. Report the actual total.

- [ ] **Step 6: Commit**

```bash
git add app/models/invoice_tracker.rb app/models/invoice_pass.rb \
  test/models/invoice_tracker_management_fee_test.rb
git commit -m "fix(mso): a management fee tracker reads its invoice's status

It has an invoice and no blueprint by design, which read as 'impossible',
showed a 'No payouts' pill, looked its customer up by name in QuickBooks,
and crashed payout generation. Trackers with a blueprint are unchanged."
```

---

### Task 4: One tracker per payer

**Files:**
- Create: `app/services/mso/management_fee_invoices.rb`
- Create: `test/services/mso/management_fee_invoices_trackers_test.rb`

**Interfaces:**
- Consumes: `Enterprise.management_fee_payers` (Task 1), `InvoicePass#management_fee?` (Task 2)
- Produces:
  - `Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass:) -> [InvoiceTracker]`, one per payer, in payer id order. Idempotent. **No QuickBooks call.**
  - `Mso::ManagementFeeInvoices::Error` and its subclasses `WrongPass`, `Misconfigured`, `PushFailed`
  - `Mso::ManagementFeeInvoices::ITEM_NAME`, `LINE_DESCRIPTION`

A tracker is found or made on the pass with `forecast_client` set to the payer's internal Forecast client and `qbo_account` set to garden3d's. The existing unique index on `[forecast_client_id, invoice_pass_id]` (`db/schema.rb:542`) backs the idempotency.

- [ ] **Step 1: Write the failing test**

Create `test/services/mso/management_fee_invoices_trackers_test.rb`:

```ruby
require "test_helper"

class Mso::ManagementFeeInvoicesTrackersTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2095, 6, 1))
    @sanctuary = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [950_001])
    @index = make_payer(Enterprise::INDEX_SPACE_NAME, customer_id: "5", forecast_ids: [950_002])
  end

  def teardown
    clear_enterprise_memos
  end

  def trackers_on(pass)
    InvoiceTracker.where(invoice_pass_id: pass.id).order(:id)
  end

  test "it refuses Sanctuary's pass" do
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 6, 1), enterprise: enterprises(:sanctuary), data: {})

    error = assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: pass)
    end

    assert_match(/Sanctuary Computer Inc/, error.message)
    assert_equal 0, trackers_on(pass).count
  end

  test "it refuses any other enterprise's pass" do
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 6, 1), enterprise: enterprises(:one), data: {})

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: pass)
    end
  end

  test "it makes one blueprint-less tracker per payer on garden3d's QuickBooks account" do
    trackers = Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    assert_equal [950_001, 950_002].sort, trackers.map(&:forecast_client_id).sort
    assert_equal trackers.map(&:id).sort, trackers_on(@pass).pluck(:id)
    trackers.each do |tracker|
      assert_equal @qbo_account.id, tracker.qbo_account_id
      assert_nil tracker.blueprint
      assert_nil tracker.qbo_invoice_id
      assert tracker.management_fee?
    end
  end

  test "running it twice changes nothing" do
    first = Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    assert_no_difference -> { InvoiceTracker.count } do
      second = Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: InvoicePass.find(@pass.id))
      assert_equal first.map(&:id), second.map(&:id)
    end
  end

  test "it never calls QuickBooks" do
    QboAccount.any_instance.expects(:make_and_refresh_qbo_access_token).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    Quickbooks::Service::Customer.any_instance.expects(:create).never

    Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)
  end

  test "an enterprise that is not flagged gets no tracker" do
    bystander = Enterprise.create!(name: "Bystander #{SecureRandom.hex(3)}")
    ForecastClient.create!(forecast_id: 950_003, name: "Bystander internal")
    EnterpriseForecastClient.create!(enterprise: bystander, forecast_client_id: 950_003)

    Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    assert_equal 0, trackers_on(@pass).where(forecast_client_id: 950_003).count
  end

  test "a payer with no internal client raises and leaves no trackers behind" do
    orphan = Enterprise.create!(name: "No Client #{SecureRandom.hex(3)}", management_fee_payer: true)

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)
    end

    assert_match(/#{Regexp.escape(orphan.name)}/, error.message)
    assert_equal 0, trackers_on(@pass).count
  end

  test "a payer with several internal clients gets one tracker, on the lowest forecast id" do
    make_payer("Many Clients #{SecureRandom.hex(3)}", forecast_ids: [950_030, 950_010, 950_020])

    Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    on_many = trackers_on(@pass).where(forecast_client_id: [950_010, 950_020, 950_030])
    assert_equal [950_010], on_many.pluck(:forecast_client_id)
  end

  test "a tracker already on another of the payer's clients is reused" do
    many = make_payer("Remapped #{SecureRandom.hex(3)}", forecast_ids: [950_050])
    existing = fee_tracker(@pass, many)
    ForecastClient.create!(forecast_id: 950_040, name: "Remapped, lower id")
    EnterpriseForecastClient.create!(enterprise: many, forecast_client_id: 950_040)

    trackers = Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    assert_includes trackers.map(&:id), existing.id
    assert_equal 0, trackers_on(@pass).where(forecast_client_id: 950_040).count
  end

  test "it raises when garden3d has no QuickBooks account" do
    QboAccount.where(enterprise_id: garden3d.id).delete_all

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)
    end

    assert_match(/no connected QboAccount/, error.message)
  end

  test "it raises when no enterprise is flagged as a payer" do
    Enterprise.update_all(management_fee_payer: false)

    assert_raises(Mso::ManagementFeeInvoices::Misconfigured) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/mso/management_fee_invoices_trackers_test.rb
```

Expected: every test errors with `NameError: uninitialized constant Mso::ManagementFeeInvoices`.

- [ ] **Step 3: Write the implementation**

Create `app/services/mso/management_fee_invoices.rb`:

```ruby
module Mso
  # garden3d's management fee invoices: one InvoiceTracker per paying company
  # on garden3d's invoice pass, and one $0.00 draft invoice per tracker in
  # garden3d's QuickBooks. Finance sets the amount in QuickBooks and sends the
  # invoice; Stacks never writes an amount and never sends one.
  #
  # NOTHING HERE WRITES TO QUICKBOOKS UNATTENDED. ensure_trackers! and
  # ensure_previous_month! touch the database only. push_invoice! and
  # create_drafts! write to QuickBooks and are reached only from an admin's
  # click (app/admin/invoice_passes.rb, app/admin/invoice_trackers.rb). Do not
  # call either from a rake task, a job or Stacks::Automator.
  class ManagementFeeInvoices
    class Error < StandardError; end
    class WrongPass < Error; end
    class Misconfigured < Error; end
    class PushFailed < Error; end

    LINE_DESCRIPTION = "Management fee"
    # Resolved by name in garden3d's QuickBooks. The QBO default item
    # "Services" posts to the same income account, so falling back to it would
    # work and be wrong; a missing item raises instead.
    ITEM_NAME = "Managerial Services"
    ZERO = BigDecimal("0")

    class << self
      # One tracker per management-fee payer on garden3d's pass. Idempotent.
      # Database only: no QuickBooks call of any kind.
      def ensure_trackers!(invoice_pass:)
        assert_management_fee_pass!(invoice_pass)
        assert_schema_ready!
        qbo_account = issuer_qbo_account(invoice_pass)

        payers = Enterprise.management_fee_payers.order(:id).to_a
        raise Misconfigured, "No enterprise is flagged as a management fee payer" if payers.empty?

        # Resolve every payer before writing anything, so one misconfigured
        # payer leaves no half-made set of trackers behind.
        planned = payers.map { |payer| [payer, internal_client_ids!(payer)] }

        ActiveRecord::Base.transaction do
          planned.map do |_payer, client_ids|
            # A payer can have several internal Forecast clients. Reuse a
            # tracker on any of them, so remapping clients never doubles up.
            existing = InvoiceTracker
              .where(invoice_pass_id: invoice_pass.id, forecast_client_id: client_ids)
              .order(:id).first
            existing || InvoiceTracker.create!(
              invoice_pass: invoice_pass,
              forecast_client_id: client_ids.first,
              qbo_account: qbo_account,
            )
          end
        end
      end

      private

      def schema_ready?
        Enterprise.column_names.include?("management_fee_payer")
      end

      # Migrations are run by hand on production, after the deploy.
      def assert_schema_ready!
        return if schema_ready?
        raise Misconfigured, "The management fee columns are not on this database yet. " \
                             "Run migration 20261013000001 first."
      end

      def assert_management_fee_pass!(invoice_pass)
        return if invoice_pass.management_fee?
        raise WrongPass, "Management fee invoices live on #{Enterprise::GARDEN3D_NAME}'s pass; " \
                         "InvoicePass #{invoice_pass.id} belongs to #{invoice_pass.enterprise.name}"
      end

      # Ordered query, not enterprise.qbo_account: has_one is unordered.
      def issuer_qbo_account(invoice_pass)
        qbo_account = QboAccount.where(enterprise_id: invoice_pass.enterprise_id).order(:id).first
        raise Misconfigured, "#{invoice_pass.enterprise.name} has no connected QboAccount" if qbo_account.nil?
        qbo_account
      end

      # Queried fresh, lowest Forecast id first, so the choice is the same on
      # every run and never comes from a stale association cache.
      def internal_client_ids!(payer)
        ids = EnterpriseForecastClient
          .where(enterprise_id: payer.id)
          .order(:forecast_client_id)
          .pluck(:forecast_client_id)
        if ids.empty?
          raise Misconfigured, "#{payer.name} is a management fee payer but has no internal Forecast client " \
                               "to hang its invoice tracker on"
        end
        ids
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/management_fee_invoices_trackers_test.rb
```

Expected: PASS, 11 runs, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 11 more runs than after Task 3, 0 failures, 0 errors. Report the actual total.

- [ ] **Step 6: Commit**

```bash
git add app/services/mso/management_fee_invoices.rb \
  test/services/mso/management_fee_invoices_trackers_test.rb
git commit -m "feat(mso): one invoice tracker per management fee payer

Found or created on garden3d's pass, database only. A payer with several
internal Forecast clients gets one tracker, and a misconfigured payer
raises before anything is written."
```

---

### Task 5: Push one $0.00 draft

**This is the QuickBooks write.** It is called only from an admin's click (Tasks 6 and 7).

**Files:**
- Modify: `app/services/mso/management_fee_invoices.rb`
- Create: `test/services/mso/management_fee_invoices_push_test.rb`

**Interfaces:**
- Consumes: `ensure_trackers!` (Task 4), `enterprises.g3d_qbo_customer_id` (Task 1), `InvoicePass#legacy_forecast_trackers?` (Task 2)
- Produces:
  - `Mso::ManagementFeeInvoices.push_invoice!(invoice_tracker:) -> QboInvoice`. Raises; never returns without having created the invoice.
  - `Mso::ManagementFeeInvoices.draftable?(invoice_pass) -> Boolean`
  - `Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START = Date.new(2026, 10, 1)`
  - New errors `NotDraftable` and `AlreadyInvoiced`, both `Mso::ManagementFeeInvoices::Error`

What the draft is, each point grounded in the Forecast path it mirrors:

| Field | Value | Reference |
| --- | --- | --- |
| Customer | the payer's stored `g3d_qbo_customer_id`; created only when blank | spec §6.2 |
| Line | one, description `"Management fee"`, amount `0`, quantity `1`, unit price `0` | `invoice_tracker.rb:780-795` |
| Item | `Managerial Services`, by `fully_qualified_name`, no fallback | `invoice_tracker.rb:865` |
| Term | the term with 15 due days | `forecast_client.rb:57`, `invoice_tracker.rb:751-754` |
| `txn_date` | last day of the pass month | `invoice_tracker.rb:759` |
| `private_note` | the pass month, e.g. "October 2026" | `invoice_tracker.rb:749` |
| Customer memo, ACH flag | not set | Decisions, item 17 |

Three refusals that come before any write:

1. **The pass is not draftable.** Stacks drafts only from `MANAGEMENT_FEE_START` onward, and never on a pass that holds a legacy Forecast tracker. garden3d's account 4100 is non-zero for every month from 2024-01 to 2025-11 and from 2026-01 to 2026-10: all of those were invoiced by hand. A draft there would be a second invoice.
2. **QuickBooks already holds an invoice for this customer dated in the pass month.** One read before the write. This catches a hand-made invoice, and it is also what makes a retry safe after a lost response: if the first attempt did create the invoice, the second finds it and stops, naming its id.
3. **A customer would be created but one already has that name.** With a blank stored id, an active customer whose name is exactly the payer's is a sign that an earlier create succeeded and its id was lost (or that Finance made one). Stacks does not create a second and does not adopt the first by name; it raises with the customer's id so a person can store it.

`Quickbooks::Service::Invoice#create` returns `nil` on a non-200 response rather than raising (quickbooks-ruby `service_crud.rb:45-55`), so a nil result is treated as a failure.

- [ ] **Step 1: Write the failing test**

Create `test/services/mso/management_fee_invoices_push_test.rb`:

```ruby
require "test_helper"

class Mso::ManagementFeeInvoicesPushTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2095, 9, 1))
    @payer = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [960_001])
    @tracker = fee_tracker(@pass, @payer)
    @customers = [qbo_customer("2", "Sanctuary Computer Inc"), qbo_customer("55", "Someone Else")]
    stub_garden3d_qbo(customers: @customers)
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    clear_enterprise_memos
  end

  # Expects exactly one invoice write and returns what was sent.
  def expect_one_draft(qbo_id = "9001")
    sent = []
    Quickbooks::Service::Invoice.any_instance.expects(:create).once
      .with { |invoice| sent << invoice }
      .returns(qbo_created_invoice(qbo_id))
    sent
  end

  def forbid_writes
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    Quickbooks::Service::Customer.any_instance.expects(:create).never
  end

  def push
    Mso::ManagementFeeInvoices.push_invoice!(invoice_tracker: @tracker)
  end

  def unattached?
    InvoiceTracker.find(@tracker.id).qbo_invoice_id.nil?
  end

  # No id stored, and no active customer carrying the payer's name.
  def blank_customer_id!(customers: [qbo_customer("55", "Someone Else")])
    @payer.update_columns(g3d_qbo_customer_id: nil)
    stub_garden3d_qbo(customers: customers)
  end

  # --- the draft -------------------------------------------------------------

  test "the draft is one $0.00 Management fee line on Managerial Services, Net 15, dated month end" do
    sent = expect_one_draft

    push

    invoice = sent.first
    assert_equal "2", invoice.customer_ref.value
    assert_equal Date.new(2095, 9, 30), invoice.txn_date
    assert_equal "2", invoice.sales_term_ref.value
    assert_equal "September 2095", invoice.private_note
    assert_nil invoice.customer_memo

    assert_equal 1, invoice.line_items.size
    line = invoice.line_items.first
    assert_equal "Management fee", line.description
    assert_equal BigDecimal("0"), line.amount
    assert line.sales_item?
    assert_equal "2", line.sales_line_item_detail.item_ref.value, "Managerial Services, not the default Services item"
    assert_equal BigDecimal("0"), line.sales_line_item_detail.unit_price
    assert_equal 1, line.sales_line_item_detail.quantity
  end

  test "it records the invoice with its data and attaches it to the tracker" do
    expect_one_draft("9001")

    mirror = push

    assert_kind_of QboInvoice, mirror
    assert_equal "9001", mirror.qbo_id
    assert_equal @qbo_account.id, mirror.qbo_account_id
    assert_equal "NotSet", mirror.read_attribute(:data)["email_status"]

    tracker = InvoiceTracker.find(@tracker.id)
    assert_equal "9001", tracker.qbo_invoice_id
    assert_nil tracker.blueprint
    assert_equal :not_sent, tracker.status
  end

  # --- the customer ----------------------------------------------------------

  test "a stored customer id means no customer is ever created" do
    expect_one_draft
    Quickbooks::Service::Customer.any_instance.expects(:create).never

    push
  end

  test "a stored customer id that is not an active customer raises and pushes nothing" do
    @payer.update_columns(g3d_qbo_customer_id: "404")
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/404/, error.message)
    assert unattached?
  end

  test "a blank customer id creates the customer once, named after the enterprise, and stores its id" do
    blank_customer_id!
    created_customers = []
    Quickbooks::Service::Customer.any_instance.expects(:create).once
      .with { |customer| created_customers << customer }
      .returns(qbo_customer("77", Enterprise::SANCTUARY_NAME))
    sent = expect_one_draft

    push

    assert_equal Enterprise::SANCTUARY_NAME, created_customers.first.display_name
    assert_equal "77", @payer.reload.g3d_qbo_customer_id
    assert_equal "77", sent.first.customer_ref.value
  end

  test "a created customer's id survives the invoice push failing" do
    blank_customer_id!
    Quickbooks::Service::Customer.any_instance.expects(:create).once
      .returns(qbo_customer("77", Enterprise::SANCTUARY_NAME))
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.raises(RuntimeError, "QuickBooks is down")

    assert_raises(RuntimeError) { push }

    assert_equal "77", @payer.reload.g3d_qbo_customer_id, "or the next attempt creates a second customer"
    assert unattached?
  end

  test "a blank id with an active customer already carrying the payer's name raises; it neither creates nor adopts" do
    # What a lost response leaves behind: QuickBooks made the customer, Stacks
    # never learned its id.
    blank_customer_id!(customers: [qbo_customer("55", "Someone Else"),
                                    qbo_customer("77", Enterprise::SANCTUARY_NAME.upcase)])
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/\b77\b/, error.message)
    assert_nil @payer.reload.g3d_qbo_customer_id
    assert unattached?
  end

  test "QuickBooks refusing the name as a duplicate is the same configuration error" do
    # Names are unique across customers, vendors and employees, and across
    # inactive ones, none of which the active-customer check above can see.
    blank_customer_id!
    duplicate = Quickbooks::IntuitRequestException.new("Duplicate Name Exists Error:\n\tThe name supplied already exists.")
    duplicate.code = "6240"
    Quickbooks::Service::Customer.any_instance.expects(:create).once.raises(duplicate)
    Quickbooks::Service::Invoice.any_instance.expects(:create).never

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/already has that name/, error.message)
    assert_nil @payer.reload.g3d_qbo_customer_id
  end

  # --- configuration ---------------------------------------------------------

  test "a missing Managerial Services item raises and never falls back to Services" do
    stub_garden3d_qbo(items: [qbo_item("1", "Services")], customers: @customers)
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/Managerial Services/, error.message)
  end

  test "a missing 15-day payment term raises" do
    stub_garden3d_qbo(terms: [qbo_term("1", "Net 30", 30)], customers: @customers)
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/15 days/, error.message)
  end

  test "a tracker that already has an invoice raises instead of doing nothing" do
    @tracker = attach_invoice(@tracker, qbo_id: "8000", total: "0.0", balance: "0.0", sent: false)
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::PushFailed) { push }

    assert_match(/already has QuickBooks invoice 8000/, error.message)
  end

  test "a tracker on Sanctuary's pass is refused" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 9, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 960_002, name: "External Co")
    @tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                      qbo_account: sanctuary_qa)
    forbid_writes

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) { push }
  end

  test "a tracker whose client is not a flagged payer's is refused" do
    @payer.update_columns(management_fee_payer: false)
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { push }

    assert_match(/does not belong to a management fee payer/, error.message)
  end

  test "QuickBooks answering without an invoice is a failure, not a success" do
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(nil)

    assert_raises(Mso::ManagementFeeInvoices::PushFailed) { push }

    assert unattached?
    assert_equal 0, QboInvoice.where(qbo_account_id: @qbo_account.id).count
  end

  # --- refusing to double-invoice -------------------------------------------

  test "it refuses when QuickBooks already holds an invoice for that customer in the month, naming it" do
    stub_garden3d_qbo(customers: @customers,
                      invoices_in_month: [qbo_created_invoice("4411", total: "135000"), qbo_created_invoice("4412")])
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::AlreadyInvoiced) { push }

    assert_match(/4411/, error.message)
    assert_match(/4412/, error.message)
    assert unattached?
  end

  test "the pre-flight asks QuickBooks about this customer and this month only" do
    queries = []
    Quickbooks::Service::Invoice.any_instance.stubs(:query)
      .with { |query, _options| queries << query }
      .returns(qbo_collection([]))
    expect_one_draft

    push

    assert_equal 1, queries.size
    assert_match(/FROM Invoice/i, queries.first)
    assert_match(/CustomerRef = '2'/, queries.first)
    assert_match(/TxnDate >= '2095-09-01'/, queries.first)
    assert_match(/TxnDate <= '2095-09-30'/, queries.first)
  end

  test "a pass before the start month is refused without asking QuickBooks anything" do
    pass = garden3d_pass(Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START - 1.month)
    @tracker = fee_tracker(pass, @payer)
    QboAccount.any_instance.expects(:fetch_all_items).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    Quickbooks::Service::Invoice.any_instance.expects(:query).never
    forbid_writes

    error = assert_raises(Mso::ManagementFeeInvoices::NotDraftable) { push }

    assert_match(/October 2026/, error.message)
  end

  test "a pass holding a legacy Forecast tracker is refused" do
    other = make_payer("Legacy Neighbour #{SecureRandom.hex(3)}")
    fee_tracker(@pass, other).update!(blueprint: { "lines" => {} })
    forbid_writes

    assert_raises(Mso::ManagementFeeInvoices::NotDraftable) { push }
  end

  test "draftable? is garden3d's pass, from the start month, with no legacy tracker" do
    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START
    sanctuary_pass = InvoicePass.create!(start_of_month: start, enterprise: enterprises(:sanctuary), data: {})

    assert_equal Date.new(2026, 10, 1), start
    assert Mso::ManagementFeeInvoices.draftable?(garden3d_pass(start))
    refute Mso::ManagementFeeInvoices.draftable?(garden3d_pass(start - 1.month))
    refute Mso::ManagementFeeInvoices.draftable?(sanctuary_pass)

    assert Mso::ManagementFeeInvoices.draftable?(@pass)
    @tracker.update!(blueprint: { "lines" => {} })
    refute Mso::ManagementFeeInvoices.draftable?(@pass)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/mso/management_fee_invoices_push_test.rb
```

Expected: 19 runs, all erroring with `NoMethodError: undefined method 'push_invoice!'` (or `draftable?`), or `NameError` on `MANAGEMENT_FEE_START`.

- [ ] **Step 3: Write the implementation**

In `app/services/mso/management_fee_invoices.rb`, add two error classes directly below `class PushFailed < Error; end`:

```ruby
    class NotDraftable < Error; end
    class AlreadyInvoiced < Error; end
```

Add this constant directly below `ZERO = BigDecimal("0")`:

```ruby

    # The first month Stacks drafts management fee invoices for. Every earlier
    # month with a fee was invoiced by hand in QuickBooks (account 4100 is
    # non-zero from 2024-01), so a draft there would be a second invoice.
    # Earlier months can still have their existing invoices ATTACHED; see
    # ensure_month!. Awaiting the owner's confirmation of the date.
    MANAGEMENT_FEE_START = Date.new(2026, 10, 1)
```

Add these two public methods directly **above** the `private` line inside `class << self`:

```ruby

      # May Stacks create drafts on this pass at all?
      def draftable?(invoice_pass)
        invoice_pass.management_fee? &&
          invoice_pass.start_of_month >= MANAGEMENT_FEE_START &&
          !invoice_pass.legacy_forecast_trackers?
      end

      # Creates the $0.00 draft for one tracker in garden3d's QuickBooks and
      # attaches it. WRITES TO QUICKBOOKS. Raises on every failure; it never
      # returns without having created the invoice.
      #
      # Do not call inside a database transaction: a customer created here is
      # recorded straight away so that a later failure cannot lose its id.
      def push_invoice!(invoice_tracker:)
        pass = invoice_tracker.invoice_pass
        assert_management_fee_pass!(pass)
        assert_schema_ready!
        assert_draftable!(pass)
        assert_no_invoice!(invoice_tracker)

        qbo_account = invoice_tracker.qbo_account
        unless qbo_account.enterprise_id == pass.enterprise_id
          raise Misconfigured, "InvoiceTracker #{invoice_tracker.id} is bound to a QuickBooks account that is " \
                               "not #{pass.enterprise.name}'s"
        end

        payer = payer_for!(invoice_tracker)
        item = managerial_services_item!(qbo_account)
        term = net_15_term!(qbo_account)
        customer = resolve_customer!(payer, qbo_account)

        # The row lock makes a double click wait, then fail on the re-check,
        # instead of creating two drafts.
        invoice_tracker.with_lock do
          assert_no_invoice!(invoice_tracker)
          # The last thing before the write: does QuickBooks already have this
          # month's invoice for this customer? A hand-made one, or our own
          # from an attempt whose response never arrived.
          assert_not_already_invoiced!(qbo_account, customer, pass, payer)
          created = create_draft!(qbo_account, pass, customer, item, term)

          begin
            mirror = QboInvoice.find_or_create_by!(qbo_id: created.id.to_s, qbo_account: qbo_account) do |row|
              # Store what QuickBooks returned. A blank mirror would make
              # QboInvoice#data fetch from QuickBooks on first read.
              row.data = created.as_json
            end
            invoice_tracker.update!(qbo_invoice_id: created.id.to_s)
            mirror
          rescue ActiveRecord::ActiveRecordError => e
            raise PushFailed, "QuickBooks invoice #{created.id} was created for #{payer.name} but Stacks could " \
                              "not record it (#{e.message}). Attach it from the tracker's edit page. Trying " \
                              "again is safe: Stacks will find that invoice and refuse to make another."
          end
        end
      end
```

Add these private methods at the end of the `private` section, below `internal_client_ids!`:

```ruby

      def assert_draftable!(invoice_pass)
        return if draftable?(invoice_pass)

        reason =
          if invoice_pass.start_of_month < MANAGEMENT_FEE_START
            "Stacks drafts management fee invoices from #{MANAGEMENT_FEE_START.strftime('%B %Y')} onward; " \
              "#{invoice_pass.invoice_month} was invoiced by hand"
          else
            "#{invoice_pass.invoice_month}'s pass holds a Forecast-driven tracker from before passes were " \
              "per-company"
          end
        raise NotDraftable, "#{reason}. Attach the existing QuickBooks invoice from the tracker's edit page " \
                            "instead of creating a draft."
      end

      def assert_no_invoice!(invoice_tracker)
        return if invoice_tracker.qbo_invoice_id.blank?
        raise PushFailed, "InvoiceTracker #{invoice_tracker.id} already has QuickBooks invoice " \
                          "#{invoice_tracker.qbo_invoice_id}. Delete it in QuickBooks, or detach it, before " \
                          "creating another."
      end

      # One QuickBooks READ. Any invoice for this customer dated in the pass
      # month stops the push -- including a voided one, which a person should
      # look at rather than Stacks guess about.
      def assert_not_already_invoiced!(qbo_account, customer, pass, payer)
        customer_id = customer.id.to_s
        unless customer_id.match?(/\A\d+\z/)
          raise Misconfigured, "#{payer.name}'s QuickBooks customer id (#{customer_id.inspect}) is not numeric"
        end
        first_day = pass.start_of_month
        last_day = first_day.end_of_month

        service = Quickbooks::Service::Invoice.new
        service.company_id = qbo_account.realm_id
        service.access_token = qbo_account.make_and_refresh_qbo_access_token
        found = service.query(
          "SELECT * FROM Invoice WHERE CustomerRef = '#{customer_id}' " \
          "AND TxnDate >= '#{first_day.iso8601}' AND TxnDate <= '#{last_day.iso8601}'",
          per_page: 100,
        )
        existing = Array(found&.entries)
        return if existing.empty?

        listed = existing.map { |invoice| "#{invoice.id} (total #{invoice.total.to_f})" }.join(", ")
        raise AlreadyInvoiced, "#{qbo_account.enterprise.name}'s QuickBooks already holds #{existing.size} " \
                               "invoice(s) for #{payer.name} dated in #{pass.invoice_month}: #{listed}. Stacks " \
                               "will not create another. Attach the right one from the tracker's edit page " \
                               "(Refresh from QuickBooks first if it is not listed there)."
      end

      # The payer is the enterprise the tracker's Forecast client is internal to.
      def payer_for!(invoice_tracker)
        payer = Enterprise
          .joins(:enterprise_forecast_clients)
          .find_by(enterprise_forecast_clients: { forecast_client_id: invoice_tracker.forecast_client_id })
        unless payer&.management_fee_payer?
          raise Misconfigured, "InvoiceTracker #{invoice_tracker.id} does not belong to a management fee payer " \
                               "(#{payer&.name || 'its Forecast client is not internal to any enterprise'})"
        end
        payer
      end

      def managerial_services_item!(qbo_account)
        items, _default_item = qbo_account.fetch_all_items
        item = items.find { |candidate| candidate.fully_qualified_name == ITEM_NAME }
        if item.nil?
          raise Misconfigured, "#{qbo_account.enterprise.name}'s QuickBooks has no active item named " \
                               "\"#{ITEM_NAME}\". Restore it; Stacks will not fall back to another item."
        end
        item
      end

      def net_15_term!(qbo_account)
        due_days = Stacks::System.singleton_class::DEFAULT_PAYMENT_TERM
        term = qbo_account.fetch_all_terms.find { |candidate| candidate.due_days == due_days }
        if term.nil?
          raise Misconfigured, "#{qbo_account.enterprise.name}'s QuickBooks has no payment term due in " \
                               "#{due_days} days"
        end
        term
      end

      # By stored id, never by name: the Enterprise, Forecast client and
      # QuickBooks customer names all differ, so a name match would miss and
      # then create a duplicate customer that Finance invoices for real.
      def resolve_customer!(payer, qbo_account)
        stored_id = payer.g3d_qbo_customer_id.presence
        active_customers = qbo_account.fetch_all_customers

        if stored_id
          customer = active_customers.find { |candidate| candidate.id.to_s == stored_id.to_s }
          if customer.nil?
            raise Misconfigured, "#{payer.name}'s stored garden3d QuickBooks customer id (#{stored_id}) is not " \
                                 "an active customer. Correct the id; Stacks never creates a customer while " \
                                 "one is stored."
          end
          return customer
        end

        # No id stored. If an active customer already carries exactly this
        # name, an earlier create probably succeeded and its id was lost.
        # Do not create a second, and do not adopt this one on a name match.
        same_name = active_customers.select do |candidate|
          [candidate.display_name, candidate.company_name, candidate.fully_qualified_name]
            .compact.any? { |name| name.strip.casecmp?(payer.name.strip) }
        end
        if same_name.any?
          raise Misconfigured, "#{payer.name} has no stored garden3d QuickBooks customer id, but an active " \
                               "customer already has that name (id #{same_name.map(&:id).join(', ')}). If it " \
                               "is the right one, store its id on the enterprise (g3d_qbo_customer_id) and " \
                               "try again. Stacks will not create a second customer or adopt one by name."
        end

        customer = Quickbooks::Model::Customer.new
        customer.display_name = payer.name
        customer.company_name = payer.name

        service = Quickbooks::Service::Customer.new
        service.company_id = qbo_account.realm_id
        service.access_token = qbo_account.make_and_refresh_qbo_access_token
        begin
          created = service.create(customer)
        rescue Quickbooks::IntuitRequestException => e
          raise unless e.code.to_s == "6240" || e.message.to_s.match?(/duplicate name/i)
          raise Misconfigured, "QuickBooks refused to create a customer named \"#{payer.name}\": a customer, " \
                               "vendor or employee already has that name (it may be inactive). Find it in " \
                               "QuickBooks; if it is this company's customer record, store its id on the " \
                               "enterprise (g3d_qbo_customer_id)."
        end
        if created.nil? || created.id.blank?
          raise PushFailed, "QuickBooks did not create a customer for #{payer.name}"
        end

        # Straight to the column, before anything else can fail: losing this
        # id would mean a refused push on the next attempt.
        payer.update_columns(g3d_qbo_customer_id: created.id.to_s)
        created
      end

      def create_draft!(qbo_account, pass, customer, item, term)
        invoice = Quickbooks::Model::Invoice.new
        invoice.customer_id = customer.id
        invoice.private_note = pass.invoice_month
        invoice.bill_email = customer.primary_email_address if customer.primary_email_address.present?
        invoice.sales_term_ref = Quickbooks::Model::BaseReference.new(term.name, value: term.id)
        invoice.txn_date = pass.start_of_month.end_of_month

        line = Quickbooks::Model::InvoiceLineItem.new
        line.description = LINE_DESCRIPTION
        line.amount = ZERO
        line.sales_item! do |detail|
          detail.unit_price = ZERO
          detail.quantity = 1
          detail.item_id = item.id
        end
        invoice.line_items << line

        service = Quickbooks::Service::Invoice.new
        service.company_id = qbo_account.realm_id
        service.access_token = qbo_account.make_and_refresh_qbo_access_token
        created = service.create(invoice)
        if created.nil? || created.id.blank?
          raise PushFailed, "QuickBooks did not create the management fee invoice for #{pass.invoice_month}. " \
                            "Trying again is safe: Stacks checks QuickBooks for an existing invoice first."
        end
        created
      end
```

The invoice shape was built offline against the installed gem before the plan was written: it is `valid?`, serialises to one `<Line>` with `<Amount>0.0</Amount>`, `<ItemRef>2</ItemRef>` and `<Qty>1.0</Qty>`, and `as_json` yields `"total" => "0.0"`, `"email_status" => "NotSet"`. The pre-flight query's syntax (`CustomerRef`, `TxnDate` range) follows the QuickBooks query language but has **not** been run against QuickBooks; the first real click is its first live test (Decisions, item 34).

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/management_fee_invoices_push_test.rb
```

Expected: PASS, 19 runs, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 19 more runs than after Task 4, 0 failures, 0 errors. Report the actual total.

- [ ] **Step 6: Commit**

```bash
git add app/services/mso/management_fee_invoices.rb \
  test/services/mso/management_fee_invoices_push_test.rb
git commit -m "feat(mso): push a \$0.00 management fee draft to garden3d's QuickBooks

One line on Managerial Services, Net 15, dated month end. Before writing it
asks QuickBooks whether that customer already has an invoice in the month,
which stops a second invoice beside a hand-made one and makes a retry safe.
Months before October 2026 are never drafted. Nothing calls this yet."
```

---

### Task 6: `make_invoice!` dispatches, and the tracker's admin page is safe

`InvoiceTracker#make_invoice!` begins with `return if configuration_errors.any?` (`app/models/invoice_tracker.rb:732`), a silent no-op, and then refuses internal clients (line 738), which every paying company's client is. A management fee invoice tracker must go to `push_invoice!` before either. A **legacy** garden3d tracker (one with a blueprint) stays on the Forecast path and behaves exactly as it does today.

Five things on the tracker's admin surface need attention once a tracker can be a management fee invoice:

1. **Regenerate** posts to `attempt_generate` (`app/admin/invoice_trackers.rb:205-232`), which calls `make_invoice!` and checks for a `Quickbooks::Model::Invoice` return (line 221). It needs its own branch, a confirmation, and to survive QuickBooks misbehaving.
2. **Regenerate and Update must be admin-only on the server.** The button is shown only to admins (line 9), but hiding a button enforces nothing: `AdminAuthorization#authorized?` returns true for every lead at line 88, and ActiveAdmin passes a member action's name through as the permission (activeadmin `base_controller/authorization.rb:65-68, 97-101`).
3. **The invoice dropdown on the edit page lists every company's unattached invoices** (`app/admin/invoice_trackers.rb:362-367`). Once garden3d's invoices are mirrored, its fee invoices — customer and total — would be listed on any tracker edit page a lead can open. The value packs `qa_id:qbo_id` (lines 342-352), so picking one would also silently re-point the tracker at another company's QuickBooks account.
4. **Calculate Default Payouts** (`app/admin/contributor_payouts.rb:111-115`) would raise a 500 on a management fee invoice.
5. The same guards must **not** touch the seven legacy garden3d trackers: leads keep `:update` on them.

**Files:**
- Modify: `app/models/invoice_tracker.rb`
- Modify: `app/admin/invoice_trackers.rb`
- Modify: `app/admin/contributor_payouts.rb`
- Modify: `app/models/admin_authorization.rb`
- Create: `test/models/invoice_tracker_make_invoice_dispatch_test.rb`
- Create: `test/models/admin_authorization_management_fee_test.rb`
- Create: `test/integration/admin_management_fee_invoices_test.rb`

**Interfaces:**
- Consumes: `push_invoice!` (Task 5), `InvoicePass#invoicing_kind` and `InvoiceTracker#management_fee_invoice?` (Task 2)
- Produces:
  - `InvoiceTracker#make_invoice!` returns `push_invoice!`'s `QboInvoice` for a management fee invoice tracker, and raises `InvoicePass::UnsupportedIssuer` on a pass that is neither kind
  - Updating or regenerating a management fee invoice tracker is admin-only, server-side
  - The edit page's invoice dropdown lists only the tracker's own QuickBooks account's invoices, and nothing for a non-admin

- [ ] **Step 1: Write the failing tests**

Create `test/models/invoice_tracker_make_invoice_dispatch_test.rb`:

```ruby
require "test_helper"

class InvoiceTrackerMakeInvoiceDispatchTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2094, 5, 1))
    @payer = make_payer("Dispatch Payer #{SecureRandom.hex(3)}", customer_id: "2")
    @tracker = fee_tracker(@pass, @payer)
  end

  def teardown
    clear_enterprise_memos
  end

  test "a management fee invoice tracker is pushed as a management fee draft" do
    Mso::ManagementFeeInvoices.expects(:push_invoice!).once
      .with(invoice_tracker: @tracker).returns(:pushed)
    @tracker.expects(:configuration_errors).never
    @tracker.expects(:assignments).never

    assert_equal :pushed, @tracker.make_invoice!
  end

  test "a misconfigured management fee invoice tracker raises instead of silently doing nothing" do
    stub_garden3d_qbo(items: [qbo_item("1", "Services")], customers: [qbo_customer("2", "Payer")])

    assert_raises(Mso::ManagementFeeInvoices::Misconfigured) { @tracker.make_invoice! }
  end

  test "a legacy garden3d tracker stays on the Forecast path" do
    @tracker.update!(blueprint: { "lines" => {} })
    Mso::ManagementFeeInvoices.expects(:push_invoice!).never
    @tracker.stubs(:configuration_errors).returns([[:missing_qbo_customer]])

    assert_nil @tracker.make_invoice!, "the Forecast path's first guard, as today"
  end

  test "a tracker on a pass that is neither Sanctuary's nor garden3d's raises" do
    other_qa = QboAccount.create!(enterprise: enterprises(:one), realm_id: "one-#{SecureRandom.hex(4)}",
                                  client_id: "x", client_secret: "y")
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 5, 1), enterprise: enterprises(:one), data: {})
    client = ForecastClient.create!(forecast_id: 970_001, name: "External Co")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id, qbo_account: other_qa)
    Mso::ManagementFeeInvoices.expects(:push_invoice!).never
    tracker.expects(:configuration_errors).never

    assert_raises(InvoicePass::UnsupportedIssuer) { tracker.make_invoice! }
  end
end
```

Create `test/models/admin_authorization_management_fee_test.rb`:

```ruby
require "test_helper"

class AdminAuthorizationManagementFeeTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2094, 6, 1))
    @payer = make_payer("Auth Payer #{SecureRandom.hex(3)}")
    @fee_tracker = fee_tracker(@pass, @payer)

    @admin = AdminUser.create!(email: "fee-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "fee-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
  end

  def teardown
    clear_enterprise_memos
  end

  def auth_for(user)
    AdminAuthorization.new(nil, user)
  end

  def sanctuary_tracker
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 6, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 970_010, name: "External Co")
    InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id, qbo_account: sanctuary_qa)
  end

  test "only an admin may update or regenerate a management fee invoice tracker" do
    %i[update attempt_generate].each do |action|
      assert auth_for(@admin).authorized?(action, @fee_tracker), "admin should #{action}"
      refute auth_for(@lead).authorized?(action, @fee_tracker), "a lead must not #{action}"
    end
    assert auth_for(@lead).authorized?(:read, @fee_tracker), "reading is unchanged"
  end

  test "a lead may still update and regenerate a Sanctuary tracker" do
    tracker = sanctuary_tracker

    assert auth_for(@lead).authorized?(:update, tracker)
    assert auth_for(@lead).authorized?(:attempt_generate, tracker)
  end

  test "a lead keeps update on a legacy garden3d tracker" do
    other = make_payer("Legacy Auth #{SecureRandom.hex(3)}")
    legacy = fee_tracker(@pass, other)
    legacy.update!(blueprint: { "lines" => {} })

    assert auth_for(@lead).authorized?(:update, legacy)
    assert auth_for(@lead).authorized?(:attempt_generate, legacy)
  end
end
```

Create `test/integration/admin_management_fee_invoices_test.rb`:

```ruby
require "test_helper"

class AdminManagementFeeInvoicesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ManagementFeeFixtures

  setup do
    @admin = AdminUser.create!(email: "fee-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "fee-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2094, 7, 1))
    @payer = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [980_001])
    stub_garden3d_qbo(customers: [qbo_customer("2", "Sanctuary Computer Inc")])
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  teardown do
    clear_enterprise_memos
  end

  def tracker_path(tracker)
    admin_invoice_pass_invoice_tracker_path(tracker.invoice_pass, tracker)
  end

  def attempt_generate_path(tracker)
    attempt_generate_admin_invoice_pass_invoice_tracker_path(tracker.invoice_pass, tracker)
  end

  def orphan_invoice!(qbo_account, doc_number)
    QboInvoice.create!(qbo_account: qbo_account, qbo_id: "orphan-#{doc_number}", data: {
      "doc_number" => doc_number, "total" => "10.0", "balance" => "10.0", "email_status" => "NotSet",
      "customer_ref" => { "name" => "Some Customer", "value" => "9" },
    })
  end

  # --- Regenerate on one tracker --------------------------------------------

  test "an admin's Regenerate creates the management fee draft" do
    tracker = fee_tracker(@pass, @payer)
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(qbo_created_invoice("9100"))
    sign_in @admin

    post attempt_generate_path(tracker)

    assert_redirected_to tracker_path(tracker)
    assert_match(/Management fee draft created/, flash[:notice])
    assert_equal "9100", tracker.reload.qbo_invoice_id
  end

  test "a failed Regenerate says why" do
    tracker = fee_tracker(@pass, @payer)
    @payer.update_columns(g3d_qbo_customer_id: "404")
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    sign_in @admin

    post attempt_generate_path(tracker)

    assert_redirected_to tracker_path(tracker)
    assert_match(/404/, flash[:alert])
    assert_nil tracker.reload.qbo_invoice_id
  end

  test "QuickBooks failing mid-Regenerate tells the admin to look before retrying" do
    tracker = fee_tracker(@pass, @payer)
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.raises(Timeout::Error, "execution expired")
    sign_in @admin

    post attempt_generate_path(tracker)

    assert_redirected_to tracker_path(tracker)
    assert_match(/check garden3d's QuickBooks/i, flash[:alert])
    assert_match(/execution expired/, flash[:alert])
    assert_nil tracker.reload.qbo_invoice_id
  end

  test "a lead cannot Regenerate a management fee invoice tracker by posting directly" do
    tracker = fee_tracker(@pass, @payer)
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    sign_in @lead

    post attempt_generate_path(tracker)

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
    assert_nil tracker.reload.qbo_invoice_id
  end

  # --- the invoice dropdown on the edit page --------------------------------

  test "an admin editing a tracker is offered only its own QuickBooks account's invoices" do
    tracker = fee_tracker(@pass, @payer)
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    orphan_invoice!(@qbo_account, "G-ORPHAN-1")
    orphan_invoice!(sanctuary_qa, "S-ORPHAN-1")
    sign_in @admin

    get edit_admin_invoice_pass_invoice_tracker_path(@pass, tracker)

    assert_response :success
    assert_match(/G-ORPHAN-1/, response.body)
    assert_no_match(/S-ORPHAN-1/, response.body)
  end

  test "a lead editing a legacy garden3d tracker is shown no invoices at all" do
    other = make_payer("Legacy Edit #{SecureRandom.hex(3)}")
    legacy = fee_tracker(@pass, other)
    legacy.update!(blueprint: { "lines" => {} })
    orphan_invoice!(@qbo_account, "G-ORPHAN-2")
    sign_in @lead

    get edit_admin_invoice_pass_invoice_tracker_path(@pass, legacy)

    assert_response :success
    assert_no_match(/G-ORPHAN-2/, response.body)
  end

  # --- payouts ----------------------------------------------------------------

  test "Calculate Default Payouts on a management fee invoice is refused politely" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8200", total: "130000.0", balance: "0.0", sent: true)
    sign_in @admin

    post make_payouts_admin_invoice_tracker_contributor_payouts_path(tracker)

    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(tracker)
    assert_match(/no contributor payouts/, flash[:alert])
    assert_equal 0, ContributorPayout.where(invoice_tracker_id: tracker.id).count
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/models/invoice_tracker_make_invoice_dispatch_test.rb \
  test/models/admin_authorization_management_fee_test.rb \
  test/integration/admin_management_fee_invoices_test.rb
```

Expected, 14 runs, 11 failing.

- Dispatch (4): the first and fourth trip `expects(:configuration_errors).never`, because `make_invoice!` still starts on the Forecast path; the second raises "Refusing to invoice internal client" instead of `Misconfigured`. The legacy one passes.
- Authorization (3): `only an admin may update or regenerate…` FAILS on "a lead must not update". The other two pass.
- Page (7): the three admin Regenerate tests fail or error on the same "Refusing to invoice internal client" raise; the lead is allowed through; the admin's dropdown lists `S-ORPHAN-1`; the lead's lists `G-ORPHAN-2`; and Calculate Default Payouts raises "Management fee invoices have no contributor payouts" as a 500.

- [ ] **Step 3: Dispatch in `make_invoice!`**

In `app/models/invoice_tracker.rb`, replace the first two lines of `make_invoice!` (lines 731-732):

```ruby
  def make_invoice!
    return if configuration_errors.any?
```

with:

```ruby
  def make_invoice!
    # Which pipeline this tracker belongs to is decided by its pass's issuer.
    # invoicing_kind raises for a pass that is neither Sanctuary's nor
    # garden3d's. A management fee invoice tracker must leave here BEFORE the
    # Forecast path's two guards below: the first is a silent no-op, and the
    # second refuses internal clients, which every paying company is.
    #
    # blueprint.nil? keeps garden3d's legacy Forecast trackers (2025, each
    # with a blueprint) on the path they have always taken.
    if invoice_pass.invoicing_kind == :management_fee && blueprint.nil?
      return Mso::ManagementFeeInvoices.push_invoice!(invoice_tracker: self)
    end

    return if configuration_errors.any?
```

- [ ] **Step 4: Regenerate — a confirmation, and a branch that reports the truth**

In `app/admin/invoice_trackers.rb`, replace the `attempt_generate` action item (lines 9-15) with:

```ruby
  action_item :attempt_generate, only: :show, if: proc { current_admin_user.is_admin? } do
    options = { method: :post }
    if resource.management_fee_invoice?
      # On a management fee invoice this writes to QuickBooks.
      options[:data] = {
        confirm: "Create a $0.00 draft invoice in garden3d's QuickBooks for " \
                 "#{resource.invoice_pass.invoice_month}? If Finance already invoiced this month by hand, " \
                 "cancel and attach that invoice from Edit instead.",
      }
    end
    link_to(
      "Regenerate",
      attempt_generate_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
      options
    )
  end
```

Inside `member_action :attempt_generate` (line 205), add this as the first statement of the block, above `if resource.qbo_invoice_id.present?`:

```ruby
    # A management fee invoice tracker's make_invoice! returns a QboInvoice or
    # raises; the checks below are for the Forecast path.
    if resource.management_fee_invoice?
      tracker_page = admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource)
      begin
        resource.make_invoice!
      rescue Mso::ManagementFeeInvoices::Error => e
        return redirect_to(tracker_page, alert: e.message)
      rescue StandardError => e
        # QuickBooks timed out, refused, or answered something unexpected. The
        # invoice may or may not exist there.
        return redirect_to(
          tracker_page,
          alert: "QuickBooks did not confirm the draft (#{e.class}: #{e.message}). Check garden3d's " \
                 "QuickBooks for a new invoice before trying again. If one is there, attach it from Edit; " \
                 "Stacks will also refuse to create a second."
        )
      end
      return redirect_to(
        tracker_page,
        notice: "Management fee draft created in QuickBooks. Set the amount there and send it."
      )
    end

```

- [ ] **Step 5: Scope the invoice dropdown**

In `app/admin/invoice_trackers.rb`, in the `form` block, replace the `f.input :qbo_invoice` call's leading comment and `collection:` argument (lines 358-367):

```ruby
      # Single select across every realm's orphan invoices. Value packs
      # "qa_id:qbo_id" so the controller can set both columns in one shot;
      # composite FK on the DB blocks any (qa, qbo_id) pair that doesn't
      # reference a real row.
      f.input :qbo_invoice,
        as: :select,
        collection: QboInvoice.orphans.includes(qbo_account: :enterprise).map { |inv|
          ent_name = inv.qbo_account&.enterprise&.name || "?"
          ["[#{ent_name}] #{inv.display_name}", "#{inv.qbo_account_id}:#{inv.qbo_id}"]
        },
```

with:

```ruby
      # Unattached invoices from THIS tracker's QuickBooks account only. A
      # tracker lives on the pass of its account's enterprise, so an invoice
      # from another company's books is never the right one -- and because the
      # value packs "qa_id:qbo_id", picking one would silently re-point the
      # tracker at that company's account.
      #
      # A non-admin cannot change this field (it is disabled below), so they
      # are given no list: other invoices' customers and totals, garden3d's
      # management fee invoices among them, are not theirs to browse.
      orphan_invoices =
        if current_admin_user.is_admin?
          QboInvoice.orphans.where(qbo_account_id: f.object.qbo_account_id).includes(qbo_account: :enterprise)
        else
          QboInvoice.none
        end
      f.input :qbo_invoice,
        as: :select,
        collection: orphan_invoices.map { |inv|
          ent_name = inv.qbo_account&.enterprise&.name || "?"
          ["[#{ent_name}] #{inv.display_name}", "#{inv.qbo_account_id}:#{inv.qbo_id}"]
        },
```

Leave the rest of that `f.input` call (`selected:`, `include_blank:`, `input_html:`) as it is.

- [ ] **Step 6: Refuse payouts for a management fee invoice**

In `app/admin/contributor_payouts.rb`, in `collection_action :make_payouts` (lines 111-115), add directly below `invoice_tracker = InvoiceTracker.find(params["invoice_tracker_id"])`:

```ruby
    if invoice_tracker.management_fee_invoice?
      return redirect_to admin_invoice_tracker_contributor_payouts_path(invoice_tracker),
        alert: "A management fee invoice has no contributor payouts."
    end
```

- [ ] **Step 7: Make it admin-only on the server**

In `app/models/admin_authorization.rb`, directly below `OWN_LEDGER_ITEM_DENY = [:update, :destroy].freeze` (line 13), add:

```ruby

  # On a management fee invoice tracker, :update attaches or detaches a
  # QuickBooks invoice and :attempt_generate writes one to QuickBooks.
  MANAGEMENT_FEE_TRACKER_ADMIN_ACTIONS = [:update, :attempt_generate].freeze
```

Directly below the `MsoRolePeriod` guard (line 81), add:

```ruby

    # garden3d's management fee invoices are written to QuickBooks only by an
    # explicit admin act. Must stay above the blanket lead grant: hiding the
    # button in the page enforces nothing. management_fee_invoice? (not
    # management_fee?) so the legacy Forecast trackers on garden3d's 2025
    # passes keep the access they have always had.
    if subject.is_a?(InvoiceTracker) && MANAGEMENT_FEE_TRACKER_ADMIN_ACTIONS.include?(action) &&
       subject.management_fee_invoice?
      return user.is_admin?
    end
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
bin/rails test test/models/invoice_tracker_make_invoice_dispatch_test.rb \
  test/models/admin_authorization_management_fee_test.rb \
  test/integration/admin_management_fee_invoices_test.rb
```

Expected: PASS, 14 runs, 0 failures.

- [ ] **Step 9: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 14 more runs than after Task 5, 0 failures, 0 errors. Report the actual total. `test/models/invoice_tracker_test.rb:238` ("make_invoice! refuses to push when forecast_client is internal") must still pass: it is on a Sanctuary pass.

- [ ] **Step 10: Commit**

```bash
git add app/models/invoice_tracker.rb app/admin/invoice_trackers.rb app/admin/contributor_payouts.rb \
  app/models/admin_authorization.rb \
  test/models/invoice_tracker_make_invoice_dispatch_test.rb \
  test/models/admin_authorization_management_fee_test.rb \
  test/integration/admin_management_fee_invoices_test.rb
git commit -m "feat(mso): make_invoice! sends a management fee invoice to its own push

It used to no-op on configuration errors and then refuse the client as
internal. Regenerate confirms first and reports the real outcome, updating
or regenerating such a tracker is admin-only on the server, and the edit
page offers only the tracker's own QuickBooks account's invoices. Legacy
Forecast trackers on garden3d's 2025 passes are untouched."
```

---

### Task 7: The garden3d pass page

S0 hides **Send Reminders** and **Generate Invoices** on a non-Sanctuary pass and refuses both if posted (`app/admin/invoice_passes.rb:40-68`). That leaves garden3d's pass with no action at all, and its page renders the Forecast partial and a missing-hours report that mean nothing there (lines 118-139).

This task adds:

- **Create management fee drafts** — makes sure the pass has its trackers, then pushes a draft for each tracker that has no invoice. One payer failing does not stop the others. Offered, and allowed, only on a draftable pass (Task 5): garden3d's, from the start month (August 2026), with no legacy tracker.
- **Refresh from QuickBooks** — re-reads each attached invoice and says honestly how many it managed. This is a QuickBooks read; it writes nothing there.
- A page body listing who is billed, the status and the amount.

**What each kind of garden3d pass shows:**

| Pass | Page body | Create drafts | Refresh |
| --- | --- | --- | --- |
| August 2026 onward | the new management fee page | yes | yes |
| Before August 2026, no legacy tracker (made with `ensure_month!` to attach hand-made invoices, Task 10) | the new page, with a line saying drafting is off for this month | no | yes |
| One of the seven 2025 passes holding a legacy Forecast tracker | **exactly what it renders today** | no | no |

**Files:**
- Modify: `app/services/mso/management_fee_invoices.rb`
- Modify: `app/admin/invoice_passes.rb`
- Create: `app/views/admin/invoice_passes/_management_fee_pass.html.erb`
- Modify: `app/models/admin_authorization.rb`
- Create: `test/services/mso/management_fee_invoices_drafts_test.rb`
- Modify: `test/models/admin_authorization_management_fee_test.rb`
- Modify: `test/integration/admin_management_fee_invoices_test.rb`

**Interfaces:**
- Consumes: `ensure_trackers!` (Task 4), `push_invoice!` and `draftable?` (Task 5)
- Produces:
  - `Mso::ManagementFeeInvoices.create_drafts!(invoice_pass:) -> DraftRun` with `created`, `already_drafted` (arrays of `InvoiceTracker`) and `failed` (array of `[InvoiceTracker, message]`). **Writes to QuickBooks.** Raises `WrongPass` or `NotDraftable` before touching anything.
  - `Mso::ManagementFeeInvoices.refresh!(invoice_pass:) -> RefreshRun` with `attempted`, `succeeded`, `detached` (Integers) and `failed` (array of `InvoiceTracker`)
  - `POST /admin/invoice_passes/:id/create_management_fee_drafts` and `…/refresh_management_fee_invoices`, admin-only

**Why `refresh!` cannot just count `sync!` calls.** `QboInvoice#sync!` rescues every error and returns `false` (`app/models/qbo_invoice.rb:147-154`). It returns `false` in two very different cases: QuickBooks said the invoice no longer exists, in which case it has destroyed the mirror row and the database trigger has detached the tracker; or anything else went wrong, in which case the row is untouched and now stale. `refresh!` tells them apart by whether the row still exists.

- [ ] **Step 1: Write the failing service test**

Create `test/services/mso/management_fee_invoices_drafts_test.rb`:

```ruby
require "test_helper"

class Mso::ManagementFeeInvoicesDraftsTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2093, 9, 1))
    @sanctuary = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [990_001])
    @index = make_payer(Enterprise::INDEX_SPACE_NAME, customer_id: "5", forecast_ids: [990_002])
    stub_garden3d_qbo(customers: [qbo_customer("2", "Sanctuary Computer Inc"), qbo_customer("5", "Index Space LLC")])
  end

  def teardown
    clear_enterprise_memos
  end

  # --- create_drafts! --------------------------------------------------------

  test "it makes the trackers and pushes a draft for each payer" do
    Quickbooks::Service::Invoice.any_instance.expects(:create).twice
      .returns(qbo_created_invoice("9201")).then.returns(qbo_created_invoice("9202"))

    run = Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: @pass)

    assert_equal 2, run.created.size
    assert_equal [], run.already_drafted
    assert_equal [], run.failed
    assert_equal %w[9201 9202], InvoiceTracker.where(invoice_pass_id: @pass.id).order(:id).pluck(:qbo_invoice_id)
  end

  test "a tracker that already has an invoice is left alone" do
    existing = attach_invoice(fee_tracker(@pass, @sanctuary), qbo_id: "8000", total: "0.0", balance: "0.0", sent: false)
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(qbo_created_invoice("9203"))

    run = Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: @pass)

    assert_equal [existing.id], run.already_drafted.map(&:id)
    assert_equal 1, run.created.size
    assert_equal [], run.failed
    assert_equal "8000", existing.reload.qbo_invoice_id
  end

  test "one payer failing does not stop the others" do
    @sanctuary.update_columns(g3d_qbo_customer_id: "404")
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(qbo_created_invoice("9204"))

    run = Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: @pass)

    assert_equal 1, run.created.size
    assert_equal 1, run.failed.size
    failed_tracker, message = run.failed.first
    assert_equal 990_001, failed_tracker.forecast_client_id
    assert_match(/404/, message)
  end

  test "it refuses a pass that is not garden3d's" do
    pass = InvoicePass.create!(start_of_month: Date.new(2093, 9, 1), enterprise: enterprises(:sanctuary), data: {})
    Quickbooks::Service::Invoice.any_instance.expects(:create).never

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: pass)
    end
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  test "it refuses a month before drafting started, and makes no trackers" do
    pass = garden3d_pass(Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START - 1.month)
    Quickbooks::Service::Invoice.any_instance.expects(:create).never

    assert_raises(Mso::ManagementFeeInvoices::NotDraftable) do
      Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: pass)
    end
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  test "it refuses a pass that holds a legacy Forecast tracker" do
    fee_tracker(@pass, @sanctuary).update!(blueprint: { "lines" => {} })
    Quickbooks::Service::Invoice.any_instance.expects(:create).never

    assert_raises(Mso::ManagementFeeInvoices::NotDraftable) do
      Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: @pass)
    end
    assert_equal 1, InvoiceTracker.where(invoice_pass_id: @pass.id).count
  end

  # --- refresh! --------------------------------------------------------------
  # These run the real QboInvoice#sync!; only the QuickBooks fetch is stubbed.

  test "refresh stores what QuickBooks now says and counts it" do
    tracker = attach_invoice(fee_tracker(@pass, @sanctuary), qbo_id: "8001", total: "0.0", balance: "0.0", sent: false)
    fee_tracker(@pass, @index) # no invoice: not attempted
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.with("8001")
      .returns(qbo_created_invoice("8001", total: "130000", balance: "0", email_status: "EmailSent"))

    run = Mso::ManagementFeeInvoices.refresh!(invoice_pass: @pass)

    assert_equal [1, 1, 0, []], [run.attempted, run.succeeded, run.detached, run.failed]
    stored = QboInvoice.find_by(qbo_account_id: @qbo_account.id, qbo_id: "8001").read_attribute(:data)
    assert_equal "EmailSent", stored["email_status"]
    assert_equal BigDecimal("130000"), BigDecimal(stored["total"])
    assert_equal :paid, InvoiceTracker.find(tracker.id).status
  end

  test "a sync that fails is reported, not counted as refreshed" do
    tracker = attach_invoice(fee_tracker(@pass, @sanctuary), qbo_id: "8002", total: "0.0", balance: "0.0", sent: false)
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.raises(RuntimeError, "QuickBooks is down")

    run = Mso::ManagementFeeInvoices.refresh!(invoice_pass: @pass)

    assert_equal [1, 0, 0], [run.attempted, run.succeeded, run.detached]
    assert_equal [tracker.id], run.failed.map(&:id)
    assert_equal "8002", InvoiceTracker.find(tracker.id).qbo_invoice_id, "a failed read changes nothing"
  end

  test "an invoice deleted in QuickBooks is detached, and that is not a failure" do
    tracker = attach_invoice(fee_tracker(@pass, @sanctuary), qbo_id: "8003", total: "0.0", balance: "0.0", sent: false)
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once
      .raises(RuntimeError, "Object Not Found: Something you're trying to use has been made inactive.")

    run = Mso::ManagementFeeInvoices.refresh!(invoice_pass: @pass)

    assert_equal [1, 0, 1, []], [run.attempted, run.succeeded, run.detached, run.failed]
    assert_nil InvoiceTracker.find(tracker.id).qbo_invoice_id
    assert_equal :not_made, InvoiceTracker.find(tracker.id).status
  end

  test "refresh refuses a pass that is not garden3d's" do
    pass = InvoicePass.create!(start_of_month: Date.new(2093, 9, 1), enterprise: enterprises(:sanctuary), data: {})
    QboAccount.any_instance.expects(:fetch_invoice_by_id).never

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.refresh!(invoice_pass: pass)
    end
  end
end
```

- [ ] **Step 2: Add the failing authorization tests**

Append inside `AdminAuthorizationManagementFeeTest` in `test/models/admin_authorization_management_fee_test.rb`, before the final `end`:

```ruby

  test "only an admin may create drafts or refresh on a pass" do
    %i[create_management_fee_drafts refresh_management_fee_invoices].each do |action|
      assert auth_for(@admin).authorized?(action, @pass), "admin should #{action}"
      refute auth_for(@lead).authorized?(action, @pass), "a lead must not #{action}"
    end
    assert auth_for(@lead).authorized?(:read, @pass), "a full lead's read is unchanged"
  end

  def trainee_auth
    trainee = AdminUser.create!(email: "fee-trainee@sanctuary.computer", password: "password12345")
    project = ProjectTracker.new(name: "Training Project")
    project.save!(validate: false)
    PermissionGrant.create!(admin_user: trainee, permission: "lead", subject: project)
    auth_for(trainee)
  end

  test "a project-scoped grantee can list passes but cannot open garden3d's management fee pass" do
    sanctuary_pass = InvoicePass.create!(start_of_month: Date.new(2094, 6, 1),
                                         enterprise: enterprises(:sanctuary), data: {})

    auth = trainee_auth
    assert auth.authorized?(:read, InvoicePass), "class-level read keeps the menu and index working"
    assert auth.authorized?(:read, sanctuary_pass)
    refute auth.authorized?(:read, @pass)
  end

  test "a project-scoped grantee can still open a legacy garden3d pass, as today" do
    @fee_tracker.update!(blueprint: { "lines" => {} })

    assert trainee_auth.authorized?(:read, @pass)
  end
```

- [ ] **Step 3: Add the failing page tests**

Append inside `AdminManagementFeeInvoicesTest` in `test/integration/admin_management_fee_invoices_test.rb`, before the final `end`:

```ruby

  # --- The pass page ---------------------------------------------------------

  def create_drafts_path(pass)
    create_management_fee_drafts_admin_invoice_pass_path(pass)
  end

  def refresh_path(pass)
    refresh_management_fee_invoices_admin_invoice_pass_path(pass)
  end

  test "garden3d's pass page offers the two management fee actions and lists who is billed" do
    attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8100", total: "130000.0", balance: "130000.0", sent: true)
    # The Forecast missing-hours report means nothing on this pass.
    Stacks::Automator.expects(:discover_people_missing_hours_for_month).never
    sign_in @admin

    get admin_invoice_pass_path(@pass)

    assert_response :success
    assert_select "a[href=?]", create_drafts_path(@pass), count: 1
    assert_select "a[href=?]", refresh_path(@pass), count: 1
    assert_select "a[href=?]", rerun_invoice_pass_without_reminders_admin_invoice_pass_path(@pass), count: 0
    assert_match(/Sanctuary Computer Inc/, response.body)
    assert_match(/\$130,000\.00/, response.body)
  end

  test "a Sanctuary pass page does not offer the management fee actions" do
    Stacks::Automator.stubs(:discover_people_missing_hours_for_month).returns([])
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 7, 1), enterprise: enterprises(:sanctuary), data: {})
    sign_in @admin

    get admin_invoice_pass_path(pass)

    assert_response :success
    assert_select "a[href=?]", create_drafts_path(pass), count: 0
    assert_select "a[href=?]", refresh_path(pass), count: 0
  end

  test "a garden3d pass from before drafting started offers Refresh but not Create drafts, and says why" do
    pass = garden3d_pass(Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START - 1.month)
    fee_tracker(pass, @payer)
    sign_in @admin

    get admin_invoice_pass_path(pass)

    assert_response :success
    assert_select "a[href=?]", create_drafts_path(pass), count: 0
    assert_select "a[href=?]", refresh_path(pass), count: 1
    assert_match(/invoiced by hand/, response.body)
  end

  test "a legacy garden3d pass renders as it does today, with neither action" do
    fee_tracker(@pass, @payer).update!(blueprint: { "lines" => {} })
    Stacks::Automator.expects(:discover_people_missing_hours_for_month).once.returns([])
    sign_in @admin

    get admin_invoice_pass_path(@pass)

    assert_response :success
    assert_select "a[href=?]", create_drafts_path(@pass), count: 0
    assert_select "a[href=?]", refresh_path(@pass), count: 0
    assert_no_match(/Management fee invoices/, response.body)
  end

  test "an admin creates the drafts with one click" do
    Quickbooks::Service::Invoice.any_instance.expects(:create).once.returns(qbo_created_invoice("9300"))
    sign_in @admin

    post create_drafts_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/Created 1 draft/, flash[:notice])
    assert_equal ["9300"], InvoiceTracker.where(invoice_pass_id: @pass.id).pluck(:qbo_invoice_id)
  end

  test "a lead cannot create drafts by posting directly" do
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    sign_in @lead

    post create_drafts_path(@pass)

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: @pass.id).count
  end

  test "creating drafts on a Sanctuary pass is refused" do
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 7, 1), enterprise: enterprises(:sanctuary), data: {})
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    sign_in @admin

    post create_drafts_path(pass)

    assert_redirected_to admin_invoice_pass_path(pass)
    assert_match(/garden3d, LLC's pass/, flash[:alert])
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  test "an admin refreshes the attached invoices from QuickBooks" do
    attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8101", total: "0.0", balance: "0.0", sent: false)
    QboInvoice.any_instance.stubs(:sync!).returns(true)
    sign_in @admin

    post refresh_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/Refreshed 1 of 1 invoice/, flash[:notice])
    assert_nil flash[:alert]
  end

  test "a refresh that could not read an invoice says so in an alert, not a green notice" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "8102", total: "0.0", balance: "0.0", sent: false)
    QboInvoice.any_instance.stubs(:sync!).returns(false)
    sign_in @admin

    post refresh_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_nil flash[:notice]
    assert_match(/Refreshed 0 of 1 invoice/, flash[:alert])
    assert_match(/#{tracker.id}/, flash[:alert])
  end
```

- [ ] **Step 4: Run them to verify they fail**

```bash
bin/rails test test/services/mso/management_fee_invoices_drafts_test.rb \
  test/models/admin_authorization_management_fee_test.rb \
  test/integration/admin_management_fee_invoices_test.rb
```

Expected, 32 runs, 21 failing. The 10 service tests error with `NoMethodError` (`create_drafts!`, `refresh!`). `only an admin may create drafts or refresh…` FAILS on "a lead must not"; `…cannot open garden3d's management fee pass` FAILS on the last `refute`; `…can still open a legacy garden3d pass` passes. The 9 new page tests error with `NoMethodError` on the two undefined route helpers. The 3 authorization and 7 page tests from Task 6 still pass.

- [ ] **Step 5: Write the service methods**

In `app/services/mso/management_fee_invoices.rb`, add below the `MANAGEMENT_FEE_START` constant:

```ruby

    DraftRun = Struct.new(:created, :already_drafted, :failed, keyword_init: true)
    RefreshRun = Struct.new(:attempted, :succeeded, :detached, :failed, keyword_init: true)
```

Add these two public methods directly above the `private` line inside `class << self`:

```ruby

      # The admin's one click: makes sure the pass has its trackers, then
      # pushes a draft for each one that has no invoice. WRITES TO QUICKBOOKS.
      # One payer failing is reported and does not stop the others.
      def create_drafts!(invoice_pass:)
        assert_management_fee_pass!(invoice_pass)
        assert_draftable!(invoice_pass) # before ensure_trackers!, so a refusal leaves nothing behind
        run = DraftRun.new(created: [], already_drafted: [], failed: [])

        ensure_trackers!(invoice_pass: invoice_pass).each do |tracker|
          if tracker.qbo_invoice_id.present?
            run.already_drafted << tracker
            next
          end

          begin
            push_invoice!(invoice_tracker: tracker)
            run.created << tracker
          rescue StandardError => e
            run.failed << [tracker, e.message]
          end
        end

        run
      end

      # Re-reads each attached invoice from QuickBooks so its status, total
      # and balance are current. A QuickBooks READ; it writes nothing there.
      #
      # QboInvoice#sync! swallows every error and returns false, so its return
      # value alone cannot be trusted:
      #   - true-ish: the mirror now holds what QuickBooks says   -> succeeded
      #   - false, mirror row gone: QuickBooks no longer has the invoice; the
      #     row was destroyed and the tracker detached             -> detached
      #   - false, mirror row still there: the read failed and the
      #     row is STALE                                           -> failed
      def refresh!(invoice_pass:)
        assert_management_fee_pass!(invoice_pass)
        run = RefreshRun.new(attempted: 0, succeeded: 0, detached: 0, failed: [])

        InvoiceTracker.where(invoice_pass_id: invoice_pass.id).where.not(qbo_invoice_id: nil).order(:id).each do |tracker|
          # By the (account, id) pair, never through the association.
          mirror = QboInvoice.find_by(qbo_account_id: tracker.qbo_account_id, qbo_id: tracker.qbo_invoice_id)
          next if mirror.nil?

          run.attempted += 1
          if mirror.sync!
            run.succeeded += 1
          elsif QboInvoice.exists?(mirror.id)
            run.failed << tracker
          else
            run.detached += 1
          end
        end

        run
      end
```

- [ ] **Step 6: Write the page partial**

Create `app/views/admin/invoice_passes/_management_fee_pass.html.erb`:

```erb
<% trackers = InvoiceTracker.where(invoice_pass_id: invoice_pass.id).order(:id).to_a %>

<div class="dashboard-modules table index_table index">
  <div class="dashboard-module">
    <div class="module-header">
      <p>Management fee invoices</p>
    </div>
    <div class="module-body">
      <% if draftable %>
        <p>
          One $0.00 draft per paying company in garden3d's QuickBooks. Finance sets each amount in QuickBooks and
          sends it. Stacks never writes an amount and never sends an invoice.
        </p>
      <% else %>
        <p>
          This month was invoiced by hand in QuickBooks, so Stacks does not create drafts for it. Attach each
          existing invoice from its tracker's edit page.
        </p>
      <% end %>
      <p>
        What is shown here is Stacks' last copy of each invoice. Use "Refresh from QuickBooks" to bring it up to
        date.
      </p>
    </div>
  </div>
</div>

<% if trackers.empty? %>
  <div class="empty_state">
    <p>No management fee invoices have been set up for this month yet.</p>
  </div>
<% else %>
  <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
    <thead>
      <tr>
        <th class="col">Billed to</th>
        <th class="col">Status</th>
        <th class="col">Total</th>
        <th class="col">Outstanding</th>
        <th class="col col-actions"></th>
      </tr>
    </thead>
    <tbody>
      <% trackers.each_with_index do |tracker, index| %>
        <% status = tracker.status %>
        <tr class="<%= index.even? ? "even" : "odd" %>">
          <td class="col"><%= tracker.forecast_client.enterprise&.name || tracker.forecast_client.name %></td>
          <td class="col"><span class="pill <%= status %>"><%= status.to_s.humanize %></span></td>
          <td class="col"><%= number_to_currency(tracker.value) %></td>
          <td class="col"><%= number_to_currency(tracker.balance) %></td>
          <td class="col col-actions">
            <div class="table_actions">
              <%= link_to "Open →", admin_invoice_pass_invoice_tracker_path(invoice_pass, tracker), class: "member_link" %>
              <% if tracker.qbo_invoice_link.present? %>
                <%= link_to "QuickBooks ↗", tracker.qbo_invoice_link, target: "_blank", class: "member_link" %>
              <% end %>
            </div>
          </td>
        </tr>
      <% end %>
    </tbody>
  </table>
<% end %>
```

The partial reads no new column, so the page renders before the migration is run.

- [ ] **Step 7: Add the admin actions and switch the page body**

In `app/admin/invoice_passes.rb`, directly below the `rerun_invoice_pass` member action (ends line 68), add:

```ruby

  # --- garden3d's management fee -------------------------------------------
  # The ONLY places a management fee invoice is written to QuickBooks are
  # this action and "Regenerate" on a single tracker. Both are an admin's
  # click; nothing scheduled does it. AdminAuthorization enforces admin-only
  # on the server -- the `if:` below only hides the button.

  action_item :create_management_fee_drafts, only: :show,
    if: proc { current_admin_user.is_admin? && Mso::ManagementFeeInvoices.draftable?(resource) } do
    link_to "Create management fee drafts",
      create_management_fee_drafts_admin_invoice_pass_path(resource),
      method: :post,
      data: { confirm: "Create a $0.00 draft invoice in garden3d's QuickBooks for each paying company that " \
                       "does not have one for #{resource.invoice_month}? Stacks first checks QuickBooks and " \
                       "skips any company that already has an invoice dated in this month." }
  end

  action_item :refresh_management_fee_invoices, only: :show,
    if: proc {
      current_admin_user.is_admin? && resource.management_fee? && !resource.legacy_forecast_trackers?
    } do
    link_to "Refresh from QuickBooks",
      refresh_management_fee_invoices_admin_invoice_pass_path(resource), method: :post
  end

  member_action :create_management_fee_drafts, method: :post do
    unless current_admin_user.is_admin?
      return redirect_to admin_invoice_pass_path(resource), alert: "Management fee drafts are created by an admin."
    end

    begin
      # Raises WrongPass off garden3d's pass, and NotDraftable before
      # October 2026 or on a pass holding a legacy Forecast tracker.
      run = Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: resource)
    rescue Mso::ManagementFeeInvoices::Error => e
      return redirect_to admin_invoice_pass_path(resource), alert: e.message
    end

    summary = "Created #{run.created.size} draft(s) in QuickBooks; " \
              "#{run.already_drafted.size} already had an invoice."
    if run.failed.any?
      failures = run.failed.map { |tracker, message| "#{tracker.forecast_client.name}: #{message}" }.join(" | ")
      redirect_to admin_invoice_pass_path(resource), alert: "#{summary} Failed: #{failures}"
    else
      redirect_to admin_invoice_pass_path(resource), notice: summary
    end
  end

  member_action :refresh_management_fee_invoices, method: :post do
    unless current_admin_user.is_admin?
      return redirect_to admin_invoice_pass_path(resource), alert: "Management fee invoices are refreshed by an admin."
    end

    begin
      run = Mso::ManagementFeeInvoices.refresh!(invoice_pass: resource)
    rescue Mso::ManagementFeeInvoices::Error => e
      return redirect_to admin_invoice_pass_path(resource), alert: e.message
    end

    summary = "Refreshed #{run.succeeded} of #{run.attempted} invoice(s) from QuickBooks."
    if run.detached.positive?
      summary += " #{run.detached} no longer exist(s) in QuickBooks and was detached."
    end
    if run.failed.any?
      # Never a green notice when some of what is on screen is stale.
      redirect_to admin_invoice_pass_path(resource),
        alert: "#{summary} Could not read the invoice on InvoiceTracker #{run.failed.map(&:id).join(', ')}; " \
               "what Stacks shows for it may be out of date. Try again."
    else
      redirect_to admin_invoice_pass_path(resource), notice: summary
    end
  end
```

Replace the `show` block (lines 118-139) with:

```ruby
  show title: :invoice_month do
    if resource.management_fee? && !resource.legacy_forecast_trackers?
      # No Forecast hours, no generator errors: this pass holds garden3d's
      # management fee invoices and nothing else that page describes.
      render 'management_fee_pass', {
        invoice_pass: invoice_pass,
        draftable: Mso::ManagementFeeInvoices.draftable?(invoice_pass),
      }
    else
      # Sanctuary's passes, and garden3d's seven 2025 passes that each hold a
      # legacy Forecast tracker: rendered exactly as before.
      #
      # Same company-wide exposure concern as the index aggregates: the
      # missing-hours report lists every contributor's name + missing
      # allocation, not just those tied to the viewer's scoped projects.
      # Scoped grantees get an empty report — the partial no-ops on empty.
      hours_report = if current_admin_user.is_admin? || current_admin_user.can_act_as_lead?
        Stacks::Automator.discover_people_missing_hours_for_month(
          [],
          resource.start_of_month,
        ).map do |d|
          {
            forecast_person: d[:forecast_data],
            missing_allocation: d[:missing_allocation]
          }
        end
      else
        []
      end

      render 'invoice_pass', { invoice_pass: invoice_pass, hours_report: hours_report }
    end
  end
```

- [ ] **Step 8: Add the server-side rules**

In `app/models/admin_authorization.rb`, directly below `MANAGEMENT_FEE_TRACKER_ADMIN_ACTIONS` (added in Task 6), add:

```ruby
  MANAGEMENT_FEE_PASS_ADMIN_ACTIONS = [:create_management_fee_drafts, :refresh_management_fee_invoices].freeze
```

Directly above the `InvoiceTracker` guard added in Task 6 (still above the blanket lead grant), add:

```ruby
    if subject.is_a?(InvoicePass) && MANAGEMENT_FEE_PASS_ADMIN_ACTIONS.include?(action)
      return user.is_admin?
    end

```

In the project-scoped block, replace line 99:

```ruby
        return true if subject.is_a?(InvoicePass)
```

with:

```ruby
        # A scoped grantee needs passes as containers to reach their own
        # trackers. They bill nothing on garden3d's management fee pass, which
        # holds what the operating companies pay garden3d. (garden3d's 2025
        # passes holding a legacy Forecast tracker stay readable, as before.)
        if subject.is_a?(InvoicePass)
          return true if !subject.management_fee? || subject.legacy_forecast_trackers?
        end
```

- [ ] **Step 9: Run the tests to verify they pass**

```bash
bin/rails test test/services/mso/management_fee_invoices_drafts_test.rb \
  test/models/admin_authorization_management_fee_test.rb \
  test/integration/admin_management_fee_invoices_test.rb \
  test/integration/admin_permission_grants_test.rb
```

Expected: PASS. 32 runs in the first three files (10 + 6 + 16), plus the existing permission-grants file, 0 failures. Its two S0 tests on a garden3d pass (`test/integration/admin_permission_grants_test.rb:183-207`) must still pass.

- [ ] **Step 10: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 22 more runs than after Task 6 (10 service, 3 authorization, 9 page), 0 failures, 0 errors. Report the actual total.

- [ ] **Step 11: Commit**

```bash
git add app/services/mso/management_fee_invoices.rb app/admin/invoice_passes.rb \
  app/views/admin/invoice_passes/_management_fee_pass.html.erb app/models/admin_authorization.rb \
  test/services/mso/management_fee_invoices_drafts_test.rb \
  test/models/admin_authorization_management_fee_test.rb \
  test/integration/admin_management_fee_invoices_test.rb
git commit -m "feat(mso): an admin creates garden3d's management fee drafts with one click

garden3d's pass page lists who is billed and offers two admin-only actions:
create the drafts, and refresh the attached invoices from QuickBooks. The
refresh reports how many it could actually read. Months invoiced by hand and
the 2025 passes holding a Forecast tracker are never drafted on."
```

---

### Task 8: Management fee income

**Files:**
- Create: `app/services/mso/management_fee_income.rb`
- Create: `test/services/mso/management_fee_income_test.rb`

**Interfaces:**
- Consumes: `Mso::ManagementFeeInvoices::ITEM_NAME` (Task 4), garden3d's stored `QboProfitAndLossReport` rows
- Produces:
  - `Mso::ManagementFeeIncome.for_month(date) -> BigDecimal`. Raises `RowMissing` or `MalformedRow`.
  - `Mso::ManagementFeeIncome.reconcile(date) -> { account_total:, payer_total:, variance:, invoices: }`. The three totals are `BigDecimal`; `invoices` is one `{ tracker_id:, qbo_id:, total:, managerial_services: }` per attached invoice, so a variance can be explained.
  - `Mso::ManagementFeeIncome.reconcile!(date)`, the same hash, raising `VarianceError` unless the variance is zero
  - `Mso::ManagementFeeIncome::Error` and its subclasses `RowMissing`, `MalformedRow`, `UnsyncedInvoice`, `WrongAccount`, `VarianceError`

Three traps this reader exists to avoid:

- `QboProfitAndLossReport#find_row` returns `0.0` when the label is not found, in both branches, then `.to_f` (`app/models/qbo_profit_and_loss_report.rb:10-16`). A miss would be a $0 cap and nobody paid, with no error.
- `find_or_fetch_for_range(start, end, force, qbo_account)` takes `force` **positionally** and, when true, deletes the stored rows before fetching (lines 68-81).
- The stored value is a String: `["4100 Management Fee Income", "130000.0"]`.

Two things a caller must know:

- **`for_month` on the current, unfinished month returns a partial figure.** October 2026 already reads 10000.0. The stored report is whatever the last nightly sync saw.
- **`reconcile` is strict on purpose, and will block a month until Finance corrects it.** It counts an invoice line as fee income only when its item is named `Managerial Services`. A hand-made line on the QuickBooks default item `Services` posts to the same account 4100 and so is in `account_total`, but not in `payer_total`. The same happens if the item is renamed. That reads as a variance, `reconcile!` raises, and S4's `MonthlyRun` will not run for that month. The `invoices` breakdown shows which invoice's Managerial Services subtotal falls short of its total.

This exact class was run read-only against the dev database, with QuickBooks calls blocked, before the plan was finalised. It returned `130000.0`, `170000.0` and `140000.0` for 2026-06, -07 and -08, `10000.0` for the unfinished 2026-10, and raised `RowMissing` for 2025-12, which has no 4100 row.

- [ ] **Step 1: Write the failing test**

Create `test/services/mso/management_fee_income_test.rb`:

```ruby
require "test_helper"

class Mso::ManagementFeeIncomeTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  MONTH = Date.new(2092, 6, 1)

  def setup
    @qbo_account = garden3d_qbo_account
    # Nothing here may fetch a report or sync an invoice unless a test says so.
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range).raises(RuntimeError, "unexpected QuickBooks read")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    clear_enterprise_memos
  end

  def report!(accrual_rows, cash_rows: [], qbo_account: @qbo_account, month: MONTH)
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account, starts_at: month, ends_at: month.end_of_month,
      data: { cash: { rows: cash_rows }, accrual: { rows: accrual_rows } },
    )
  end

  def fee_rows(amount)
    [["4100 Management Fee Income", amount], ["Total Income", amount], ["Net Income", amount]]
  end

  # --- for_month -------------------------------------------------------------

  test "it reads the accrual 4100 row as a BigDecimal" do
    report!(fee_rows("130000.0"), cash_rows: fee_rows("5.0"))

    income = Mso::ManagementFeeIncome.for_month(MONTH)

    assert_kind_of BigDecimal, income
    assert_equal BigDecimal("130000"), income
  end

  test "any date in the month reads that month" do
    report!(fee_rows("170000.0"))

    assert_equal BigDecimal("170000"), Mso::ManagementFeeIncome.for_month(Date.new(2092, 6, 17))
  end

  test "a missing row raises instead of reading as zero" do
    report!([["Total Income", nil], ["6100 Platform Infrastructure", "250.0"]])

    error = assert_raises(Mso::ManagementFeeIncome::RowMissing) { Mso::ManagementFeeIncome.for_month(MONTH) }

    assert_match(/June 2092/, error.message)
  end

  test "a genuine zero is zero, not a missing row" do
    report!(fee_rows("0.0"))

    assert_equal BigDecimal("0"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "the match is on the account number, so a renamed account still reads" do
    report!([["4100 Mgmt Fees (renamed)", "140000.0"], ["Total Income", "140000.0"]])

    assert_equal BigDecimal("140000"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "a total row and a longer account number do not match" do
    report!([["Total 4100 Management Fee Income", "1.0"], ["41000 Something Else", "2.0"]])

    assert_raises(Mso::ManagementFeeIncome::RowMissing) { Mso::ManagementFeeIncome.for_month(MONTH) }
  end

  test "two rows starting with 4100 raise rather than guess" do
    report!([["4100 Management Fee Income", "100.0"], ["4100.1 Sub-account", "50.0"]])

    error = assert_raises(Mso::ManagementFeeIncome::RowMissing) { Mso::ManagementFeeIncome.for_month(MONTH) }

    assert_match(/2 rows/, error.message)
  end

  test "a row with no amount raises" do
    report!([["4100 Management Fee Income", nil]])

    assert_raises(Mso::ManagementFeeIncome::RowMissing) { Mso::ManagementFeeIncome.for_month(MONTH) }
  end

  test "an amount that is not a number raises this reader's own error, not a bare ArgumentError" do
    report!([["4100 Management Fee Income", "1,300.00 USD"]])

    error = assert_raises(Mso::ManagementFeeIncome::MalformedRow) { Mso::ManagementFeeIncome.for_month(MONTH) }

    assert_kind_of Mso::ManagementFeeIncome::Error, error
    assert_match(/1,300\.00 USD/, error.message)
  end

  test "it reads garden3d's report, never Sanctuary's" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    report!(fee_rows("999999.0"), qbo_account: sanctuary_qa)
    report!(fee_rows("130000.0"))

    assert_equal BigDecimal("130000"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "with duplicate stored reports it reads the newest" do
    report!(fee_rows("100.0"))
    report!(fee_rows("130000.0"))

    assert_equal BigDecimal("130000"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "a stored report is never re-fetched" do
    report!(fee_rows("130000.0"))
    QboProfitAndLossReport.expects(:find_or_fetch_for_range).never

    Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "with nothing stored it fetches once, and never with force" do
    fetched = QboProfitAndLossReport.new(data: { "accrual" => { "rows" => fee_rows("130000.0") } })
    # force is the THIRD POSITIONAL argument. `true` there deletes stored rows.
    QboProfitAndLossReport.expects(:find_or_fetch_for_range).once
      .with(MONTH, MONTH.end_of_month, false, @qbo_account)
      .returns(fetched)

    assert_equal BigDecimal("130000"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "it raises when garden3d has no QuickBooks account" do
    QboAccount.where(enterprise_id: garden3d.id).delete_all

    error = assert_raises(Mso::ManagementFeeIncome::Error) { Mso::ManagementFeeIncome.for_month(MONTH) }

    assert_match(/no connected QboAccount/, error.message)
  end

  # --- reconcile -------------------------------------------------------------

  def payer_with_invoice(pass, forecast_id:, qbo_id:, lines:)
    payer = make_payer("Reconcile Payer #{forecast_id}", forecast_ids: [forecast_id])
    total = lines.sum(BigDecimal("0")) { |line| BigDecimal(line["amount"]) }.to_s("F")
    attach_invoice(fee_tracker(pass, payer), qbo_id: qbo_id, total: total, balance: total, sent: true, lines: lines)
  end

  test "reconcile reports no variance when the fee lines equal account 4100" do
    report!(fee_rows("170000.0"))
    pass = garden3d_pass(MONTH)
    payer_with_invoice(pass, forecast_id: 991_001, qbo_id: "r-1", lines: [fee_line("130000.0")])
    payer_with_invoice(pass, forecast_id: 991_002, qbo_id: "r-2", lines: [fee_line("40000.0")])

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("170000"), result[:account_total]
    assert_equal BigDecimal("170000"), result[:payer_total]
    assert_equal BigDecimal("0"), result[:variance]
    result.slice(:account_total, :payer_total, :variance).each_value { |value| assert_kind_of BigDecimal, value }
  end

  test "reconcile counts only Managerial Services lines, so a loan repayment line is not fee income" do
    report!(fee_rows("130000.0"))
    pass = garden3d_pass(MONTH)
    payer_with_invoice(pass, forecast_id: 991_003, qbo_id: "r-3",
                       lines: [fee_line("130000.0"), fee_line("25000.0", item: "Loan Repayment")])

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("130000"), result[:payer_total]
    assert_equal BigDecimal("0"), result[:variance]
  end

  test "reconcile reports the variance when account 4100 holds income no payer was invoiced for" do
    # A $30,000 advisory fee to an outside customer, booked to the same account.
    report!(fee_rows("160000.0"))
    pass = garden3d_pass(MONTH)
    payer_with_invoice(pass, forecast_id: 991_004, qbo_id: "r-4", lines: [fee_line("130000.0")])

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("30000"), result[:variance]
  end

  test "the breakdown shows which invoice's fee line is on the wrong item" do
    # Finance billed the fee on the default Services item. It posts to 4100,
    # so the account has it, but it is not a Managerial Services line.
    report!(fee_rows("170000.0"))
    pass = garden3d_pass(MONTH)
    good = payer_with_invoice(pass, forecast_id: 991_008, qbo_id: "r-8", lines: [fee_line("130000.0")])
    wrong = payer_with_invoice(pass, forecast_id: 991_009, qbo_id: "r-9",
                               lines: [fee_line("40000.0", item: "Services")])

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("40000"), result[:variance]
    assert_equal [
      { tracker_id: good.id, qbo_id: "r-8", total: BigDecimal("130000"), managerial_services: BigDecimal("130000") },
      { tracker_id: wrong.id, qbo_id: "r-9", total: BigDecimal("40000"), managerial_services: BigDecimal("0") },
    ], result[:invoices]
  end

  test "reconcile with no garden3d pass for the month has a payer total of zero" do
    report!(fee_rows("130000.0"))

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("0"), result[:payer_total]
    assert_equal BigDecimal("130000"), result[:variance]
    assert_equal [], result[:invoices]
  end

  test "reconcile refuses an invoice that has never been synced, without syncing it" do
    report!(fee_rows("130000.0"))
    pass = garden3d_pass(MONTH)
    payer = make_payer("Unsynced Payer", forecast_ids: [991_005])
    tracker = fee_tracker(pass, payer)
    QboInvoice.create!(qbo_account: @qbo_account, qbo_id: "r-5", data: {})
    tracker.update!(qbo_invoice_id: "r-5")

    error = assert_raises(Mso::ManagementFeeIncome::UnsyncedInvoice) { Mso::ManagementFeeIncome.reconcile(MONTH) }

    assert_match(/r-5/, error.message)
  end

  test "reconcile refuses a tracker that has been pointed at another company's QuickBooks account" do
    # The tracker edit form can attach an invoice from any account, which
    # re-points qbo_account_id along with it.
    report!(fee_rows("130000.0"))
    pass = garden3d_pass(MONTH)
    payer = make_payer("Repointed Payer", forecast_ids: [991_010])
    tracker = fee_tracker(pass, payer)
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    QboInvoice.create!(qbo_account: sanctuary_qa, qbo_id: "r-10",
                       data: { "total" => "130000.0", "balance" => "0.0", "line_items" => [fee_line("130000.0")] })
    tracker.update!(qbo_account: sanctuary_qa, qbo_invoice_id: "r-10")

    error = assert_raises(Mso::ManagementFeeIncome::WrongAccount) { Mso::ManagementFeeIncome.reconcile(MONTH) }

    assert_match(/InvoiceTracker #{tracker.id}/, error.message)
  end

  test "reconcile! raises on a variance and returns the figures when there is none" do
    report!(fee_rows("160000.0"))
    pass = garden3d_pass(MONTH)
    payer_with_invoice(pass, forecast_id: 991_006, qbo_id: "r-6", lines: [fee_line("130000.0")])

    error = assert_raises(Mso::ManagementFeeIncome::VarianceError) { Mso::ManagementFeeIncome.reconcile!(MONTH) }
    assert_match(/30000/, error.message)
    assert_match(/r-6/, error.message, "the error names the invoices it compared")

    payer_with_invoice(pass, forecast_id: 991_007, qbo_id: "r-7", lines: [fee_line("30000.0")])
    assert_equal BigDecimal("0"), Mso::ManagementFeeIncome.reconcile!(MONTH)[:variance]
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/mso/management_fee_income_test.rb
```

Expected: 22 runs, every one erroring with `NameError: uninitialized constant Mso::ManagementFeeIncome`.

- [ ] **Step 3: Write the implementation**

Create `app/services/mso/management_fee_income.rb`:

```ruby
module Mso
  # garden3d's management fee income for a month: the accrual P&L row for
  # account 4100. This is the basis of the MSO compensation cap.
  #
  # Reads the stored report rows directly. QboProfitAndLossReport#find_row is
  # unusable here: it returns 0.0 when the label is not found, so a renamed
  # account would silently become a $0 cap, and it converts through Float.
  #
  # for_month on the current, unfinished month returns a partial figure: the
  # stored report is whatever the last nightly sync saw.
  class ManagementFeeIncome
    class Error < StandardError; end
    class RowMissing < Error; end
    class MalformedRow < Error; end
    class UnsyncedInvoice < Error; end
    class WrongAccount < Error; end
    class VarianceError < Error; end

    # "4100 Management Fee Income" today. Matching the account number alone
    # survives a rename of the account; "Total 4100 ..." and "41000 ..." do
    # not match.
    ACCOUNT_ROW = /\A4100\b/
    ZERO = BigDecimal("0")

    class << self
      def for_month(date)
        month = date.to_date.beginning_of_month
        label = month.strftime("%B %Y")
        report = report_for(month)
        rows = report.data.is_a?(Hash) ? report.data.dig("accrual", "rows") : nil
        raise RowMissing, "garden3d's P&L for #{label} has no accrual rows" unless rows.is_a?(Array)

        matches = rows.select { |row| row.is_a?(Array) && row[0].to_s.match?(ACCOUNT_ROW) }
        if matches.empty?
          raise RowMissing, "garden3d's accrual P&L for #{label} has no account 4100 row (#{rows.size} rows). " \
                            "No management fee was booked, or the account was renumbered."
        end
        if matches.size > 1
          raise RowMissing, "garden3d's accrual P&L for #{label} has #{matches.size} rows starting with 4100; " \
                            "refusing to guess which is management fee income"
        end

        value = matches.first[1].to_s.strip
        raise RowMissing, "garden3d's account 4100 row for #{label} has no amount" if value.empty?

        begin
          BigDecimal(value)
        rescue ArgumentError
          raise MalformedRow, "garden3d's account 4100 row for #{label} is not a number: #{value.inspect}"
        end
      end

      # Compares the 4100 total against what garden3d's management fee
      # invoices for the month actually charge on the Managerial Services
      # item. A difference means account 4100 holds income that is not a fee
      # line Stacks recognises: an outside customer, a fee billed on another
      # item, or an invoice dated in another month. The cap would be wrong.
      #
      # `invoices` lists each attached invoice with its total and its
      # Managerial Services subtotal, so a variance can be traced to one.
      #
      # Reads the stored invoice mirrors. Refresh them first
      # (Mso::ManagementFeeInvoices.refresh!) if they may be stale.
      def reconcile(date)
        month = date.to_date.beginning_of_month
        account_total = for_month(month)
        invoices = fee_invoices_for(month)
        payer_total = invoices.sum(ZERO) { |invoice| invoice[:managerial_services] }
        {
          account_total: account_total,
          payer_total: payer_total,
          variance: account_total - payer_total,
          invoices: invoices,
        }
      end

      def reconcile!(date)
        result = reconcile(date)
        return result if result[:variance].zero?

        compared = result[:invoices].map do |invoice|
          "#{invoice[:qbo_id]} (total #{invoice[:total].to_s('F')}, " \
            "Managerial Services #{invoice[:managerial_services].to_s('F')})"
        end
        raise VarianceError, "garden3d's account 4100 reads #{result[:account_total].to_s('F')} for " \
                             "#{date.to_date.strftime('%B %Y')} but its management fee invoices charge " \
                             "#{result[:payer_total].to_s('F')} on Managerial Services (variance " \
                             "#{result[:variance].to_s('F')}). Invoices compared: " \
                             "#{compared.empty? ? 'none' : compared.join('; ')}"
      end

      private

      def report_for(month)
        qbo_account = garden3d_qbo_account
        persisted = QboProfitAndLossReport
          .where(qbo_account_id: qbo_account.id, starts_at: month, ends_at: month.end_of_month)
          .order(:id).last
        return persisted if persisted

        # Nothing stored for this month: fetch it once. `force` is the THIRD
        # POSITIONAL argument and must stay false -- true deletes the stored
        # rows the dashboard, the enterprise snapshot and two MCP tools read.
        QboProfitAndLossReport.find_or_fetch_for_range(month, month.end_of_month, false, qbo_account)
      end

      def garden3d_qbo_account
        qbo_account = QboAccount.where(enterprise_id: Enterprise.garden3d.id).order(:id).first
        raise Error, "#{Enterprise::GARDEN3D_NAME} has no connected QboAccount" if qbo_account.nil?
        qbo_account
      end

      # One entry per invoice attached to garden3d's pass for the month.
      # Fee income is counted by LINE, not by invoice total: an invoice can
      # also carry lines that are not fee income (a loan repayment), which
      # never post to 4100.
      def fee_invoices_for(month)
        garden3d_id = Enterprise.garden3d.id
        pass = InvoicePass.find_by(enterprise_id: garden3d_id, start_of_month: month)
        return [] if pass.nil?

        garden3d_account_ids = QboAccount.where(enterprise_id: garden3d_id).pluck(:id)
        trackers = InvoiceTracker.where(invoice_pass_id: pass.id).where.not(qbo_invoice_id: nil).order(:id).to_a

        trackers.map do |tracker|
          # The tracker edit form can attach an invoice from any QuickBooks
          # account, re-pointing qbo_account_id with it. Another company's
          # invoice is never garden3d's fee income.
          unless garden3d_account_ids.include?(tracker.qbo_account_id)
            raise WrongAccount, "InvoiceTracker #{tracker.id} on garden3d's pass points at QuickBooks account " \
                                "#{tracker.qbo_account_id}, which is not garden3d's"
          end

          # By the (account, id) pair, and stored data only. QboInvoice#data
          # fetches from QuickBooks when the stored jsonb is blank; an
          # unsynced invoice is unknown, not zero.
          mirror = QboInvoice.find_by(qbo_account_id: tracker.qbo_account_id, qbo_id: tracker.qbo_invoice_id)
          stored = mirror&.read_attribute(:data)
          if stored.blank?
            raise UnsyncedInvoice, "QuickBooks invoice #{tracker.qbo_invoice_id} on InvoiceTracker #{tracker.id} " \
                                   "has not been synced; refresh garden3d's pass from QuickBooks first"
          end

          fee_lines = (stored["line_items"] || []).select do |line|
            line.is_a?(Hash) &&
              line.dig("sales_line_item_detail", "item_ref", "name") == Mso::ManagementFeeInvoices::ITEM_NAME
          end

          {
            tracker_id: tracker.id,
            qbo_id: tracker.qbo_invoice_id,
            total: stored_amount(stored["total"]),
            managerial_services: fee_lines.sum(ZERO) { |line| stored_amount(line["amount"]) },
          }
        end
      end

      def stored_amount(value)
        BigDecimal(value.to_s)
      rescue ArgumentError
        raise MalformedRow, "a stored QuickBooks amount is not a number: #{value.inspect}"
      end
    end
  end
end
```

`trackers` and `invoices` are Arrays, so `sum(ZERO) { }` is `Enumerable#sum`; calling it on a relation raises in Rails 6.1.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/management_fee_income_test.rb
```

Expected: PASS, 22 runs, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 22 more runs than after Task 7, 0 failures, 0 errors. Report the actual total.

- [ ] **Step 6: Commit**

```bash
git add app/services/mso/management_fee_income.rb test/services/mso/management_fee_income_test.rb
git commit -m "feat(mso): read garden3d's management fee income from its P&L

Account 4100, accrual, as a BigDecimal. A missing row raises instead of
reading as zero, a stored report is never re-fetched, and reconcile compares
the account against the Managerial Services lines actually invoiced, listing
each invoice so a variance can be traced."
```

---

### Task 9: Has the fee been collected?

This gate decides whether executives are paid. It must fail **closed**: when in doubt, the answer is no, or an error.

**Files:**
- Modify: `app/models/invoice_pass.rb`
- Modify: `app/services/mso/management_fee_invoices.rb`
- Create: `test/models/invoice_pass_management_fee_collected_test.rb`
- Create: `test/services/mso/management_fee_invoices_collected_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#management_fee?` (Task 2), `Mso::ManagementFeeInvoices.refresh!` (Task 7)
- Produces:
  - `Mso::ManagementFeeInvoices.collected?(invoice_pass:) -> Boolean`. **The entry point for any payability decision.** Refreshes every attached invoice from QuickBooks first and raises `RefreshFailed` if any of them could not be read.
  - `InvoicePass#management_fee_collected? -> Boolean`. The pure rule over the mirrors **as stored**. No QuickBooks call. Right only if the mirrors are fresh; use it for display, or after a refresh.

**Two entry points, because the stored copy lies by default.** `push_invoice!` stores the invoice as QuickBooks returned it: unsent, $0.00. Finance then edits the amount and sends it in QuickBooks, and nothing in Stacks finds out until someone refreshes: `QboAccount#sync_all_invoices!` has no caller, and a mirror row is otherwise re-read only when its tracker's page is opened (`app/admin/invoice_trackers.rb:313-322`). A gate reading that stale row would see "an unsent $0 draft — nobody was charged". So the refresh is part of the gate's contract, not a courtesy.

**The rule.** For each invoice attached to the pass:

| Stored invoice | Counts as | Why |
| --- | --- | --- |
| Voided (private note says "voided") | **not charged**, ignored | Voiding cancels the charge. A sent-then-voided invoice reads `EmailSent` with total 0, and `QboInvoice#status` only recognises voided for unsent ones (`app/models/qbo_invoice.rb:82`). |
| Unsent **and** total 0 | **not charged**, ignored | The untouched draft Stacks makes for every payer every month. Gating on it would block forever. |
| Sent, **or** total above 0 | **charged** | An invoice with an amount posts to accrual account 4100 whether or not it was emailed, and so raises the cap. Sanctuary's own mirror has 53 unsent invoices with non-zero totals: it happens. |

Collected = **at least one charged invoice, and every charged invoice has a total above zero and a balance of zero.**

- A sent $0.00 invoice is charged and has no total above zero, so it is **not** collected. `QboInvoice#status` would call it `:paid` (it tests `balance == 0` first, lines 74-75).
- An invoice with no stored data, or an unreadable amount, is unknown: not collected.
- A tracker pointing at another company's QuickBooks account raises. The tracker edit form can cause that (`app/admin/invoice_trackers.rb:342-352`).
- Mirrors are looked up by the `(qbo_account_id, qbo_id)` pair, never through the `qbo_invoice` association.

- [ ] **Step 1: Write the failing test for the rule**

Create `test/models/invoice_pass_management_fee_collected_test.rb`:

```ruby
require "test_helper"

class InvoicePassManagementFeeCollectedTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2091, 6, 1))
    @sanctuary = make_payer(Enterprise::SANCTUARY_NAME, forecast_ids: [992_001])
    @index = make_payer(Enterprise::INDEX_SPACE_NAME, forecast_ids: [992_002])
    # The pure rule must never read QuickBooks.
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    clear_enterprise_memos
  end

  def collected?
    InvoicePass.find(@pass.id).management_fee_collected?
  end

  def invoice_for(payer, qbo_id, total:, balance:, sent:, private_note: nil)
    tracker = attach_invoice(fee_tracker(@pass, payer), qbo_id: qbo_id, total: total, balance: balance, sent: sent)
    if private_note
      mirror = QboInvoice.find_by!(qbo_account_id: @qbo_account.id, qbo_id: qbo_id)
      mirror.update!(data: mirror.read_attribute(:data).merge("private_note" => private_note))
    end
    tracker
  end

  # --- nothing charged -------------------------------------------------------

  test "not collected when the pass has no trackers" do
    refute collected?
  end

  test "not collected when every invoice is an untouched draft" do
    invoice_for(@sanctuary, "c-1", total: "0.0", balance: "0.0", sent: false)
    invoice_for(@index, "c-2", total: "0.0", balance: "0.0", sent: false)

    refute collected?
  end

  # --- sent invoices ---------------------------------------------------------

  test "collected when the one sent invoice is paid in full" do
    invoice_for(@sanctuary, "c-3", total: "130000.0", balance: "0.0", sent: true)

    assert collected?
  end

  test "not collected while a sent invoice is unpaid" do
    invoice_for(@sanctuary, "c-4", total: "130000.0", balance: "130000.0", sent: true)

    refute collected?
  end

  test "not collected while a sent invoice is partly paid" do
    invoice_for(@sanctuary, "c-5", total: "130000.0", balance: "0.01", sent: true)

    refute collected?
  end

  test "a sent $0.00 invoice is not collected, though QuickBooks status calls it paid" do
    tracker = invoice_for(@sanctuary, "c-6", total: "0.0", balance: "0.0", sent: true)

    assert_equal :paid, tracker.qbo_invoice.status, "the trap this rule exists for"
    refute collected?
  end

  test "not collected when one of two sent invoices is unpaid" do
    invoice_for(@sanctuary, "c-10", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-11", total: "40000.0", balance: "40000.0", sent: true)

    refute collected?
  end

  # --- who is ignored --------------------------------------------------------

  test "an untouched draft is ignored when another payer's invoice is sent and paid" do
    invoice_for(@sanctuary, "c-7", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-8", total: "0.0", balance: "0.0", sent: false)

    assert collected?
  end

  test "a payer with no invoice at all is ignored the same way" do
    invoice_for(@sanctuary, "c-9", total: "130000.0", balance: "0.0", sent: true)
    fee_tracker(@pass, @index)

    assert collected?
  end

  # --- an amount is a charge, emailed or not ---------------------------------

  test "an unsent invoice with an amount is a charge: unpaid, it blocks collection" do
    # Finance set the amount but never emailed it from QuickBooks. It still
    # posts to account 4100 and raises the cap, so it must be paid first.
    invoice_for(@sanctuary, "c-20", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-21", total: "40000.0", balance: "40000.0", sent: false)

    refute collected?
  end

  test "an unsent invoice with an amount, paid in full, is collected" do
    # An intercompany invoice recorded as paid without ever being emailed.
    invoice_for(@sanctuary, "c-22", total: "130000.0", balance: "0.0", sent: false)

    assert collected?
  end

  # --- voided ----------------------------------------------------------------

  test "a sent-then-voided invoice is not a charge and is ignored" do
    invoice_for(@sanctuary, "c-30", total: "130000.0", balance: "0.0", sent: true)
    invoice_for(@index, "c-31", total: "0.0", balance: "0.0", sent: true, private_note: "Voided - sent in error")

    assert collected?
  end

  test "a pass whose only invoice was voided has collected nothing" do
    invoice_for(@sanctuary, "c-32", total: "0.0", balance: "0.0", sent: true, private_note: "Voided")

    refute collected?
  end

  # --- unknown, and misuse ---------------------------------------------------

  test "an invoice that was never synced is unknown: not collected, and not fetched" do
    invoice_for(@sanctuary, "c-12", total: "130000.0", balance: "0.0", sent: true)
    tracker = fee_tracker(@pass, @index)
    QboInvoice.create!(qbo_account: @qbo_account, qbo_id: "c-13", data: {})
    tracker.update!(qbo_invoice_id: "c-13")

    refute collected?
  end

  test "a tracker pointed at another company's QuickBooks account raises" do
    invoice_for(@sanctuary, "c-40", total: "130000.0", balance: "0.0", sent: true)
    tracker = fee_tracker(@pass, @index)
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    QboInvoice.create!(qbo_account: sanctuary_qa, qbo_id: "c-41",
                       data: { "total" => "40000.0", "balance" => "0.0", "email_status" => "EmailSent" })
    tracker.update!(qbo_account: sanctuary_qa, qbo_invoice_id: "c-41")

    error = assert_raises(RuntimeError) { collected? }

    assert_match(/InvoiceTracker #{tracker.id}/, error.message)
    assert_match(/not garden3d, LLC's/, error.message)
  end

  test "it refuses to answer for a pass that is not garden3d's" do
    pass = InvoicePass.create!(start_of_month: Date.new(2091, 6, 1), enterprise: enterprises(:sanctuary), data: {})

    error = assert_raises(RuntimeError) { pass.management_fee_collected? }

    assert_match(/only applies to garden3d, LLC's passes/, error.message)
  end
end
```

- [ ] **Step 2: Write the failing test for the refreshing entry point**

Create `test/services/mso/management_fee_invoices_collected_test.rb`:

```ruby
require "test_helper"

class Mso::ManagementFeeInvoicesCollectedTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2091, 7, 1))
    @payer = make_payer(Enterprise::SANCTUARY_NAME, forecast_ids: [992_101])
    # Exactly what push_invoice! leaves behind: an unsent $0.00 snapshot.
    @tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "k-1", total: "0.0", balance: "0.0", sent: false)
  end

  def teardown
    clear_enterprise_memos
  end

  test "it reads QuickBooks first, so a stale draft snapshot cannot hide a paid invoice" do
    refute InvoicePass.find(@pass.id).management_fee_collected?, "sanity: the stored snapshot says nobody was charged"
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.with("k-1")
      .returns(qbo_created_invoice("k-1", total: "130000", balance: "0", email_status: "EmailSent"))

    assert Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "it reads QuickBooks first, so a stale paid snapshot cannot hide an unpaid invoice" do
    mirror = QboInvoice.find_by!(qbo_account_id: @qbo_account.id, qbo_id: "k-1")
    mirror.update!(data: mirror.read_attribute(:data).merge("email_status" => "EmailSent", "total" => "130000.0"))
    assert InvoicePass.find(@pass.id).management_fee_collected?, "sanity: the stored snapshot says paid"
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once
      .returns(qbo_created_invoice("k-1", total: "130000", balance: "130000", email_status: "EmailSent"))

    refute Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
  end

  test "it raises when an invoice cannot be read, rather than answer from a stale copy" do
    QboAccount.any_instance.expects(:fetch_invoice_by_id).once.raises(RuntimeError, "QuickBooks is down")

    error = assert_raises(Mso::ManagementFeeInvoices::RefreshFailed) do
      Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
    end

    assert_match(/InvoiceTracker #{@tracker.id}/, error.message)
  end

  test "it refuses a pass that is not garden3d's" do
    pass = InvoicePass.create!(start_of_month: Date.new(2091, 7, 1), enterprise: enterprises(:sanctuary), data: {})
    QboAccount.any_instance.expects(:fetch_invoice_by_id).never

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.collected?(invoice_pass: pass)
    end
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

```bash
bin/rails test test/models/invoice_pass_management_fee_collected_test.rb \
  test/services/mso/management_fee_invoices_collected_test.rb
```

Expected: 20 runs, every one erroring with `NoMethodError` (`management_fee_collected?`, or `collected?` on the service).

- [ ] **Step 4: Write the rule**

In `app/models/invoice_pass.rb`, directly below `legacy_forecast_trackers?` (added in Task 2), add:

```ruby

  # Has garden3d been paid the management fee it charged for this month?
  # THE PURE RULE, over the invoice mirrors AS STORED. It makes no QuickBooks
  # call, so it is only as right as the mirrors are fresh -- and a mirror is
  # stored as an unsent $0.00 draft and not updated until someone refreshes.
  #
  #   To decide whether anyone is PAID, call
  #   Mso::ManagementFeeInvoices.collected?(invoice_pass:) instead. It
  #   refreshes from QuickBooks first and raises if it cannot.
  #
  # An invoice is CHARGED when it was sent OR its total is above zero. It is
  # ignored only when it is unsent and zero (the untouched draft Stacks makes
  # for every payer), or voided. Collected = at least one charged invoice,
  # and every charged invoice has a total above zero and nothing outstanding.
  #
  # - An invoice with an amount that was never emailed still posts to account
  #   4100 and raises the cap, so it is a charge.
  # - A sent $0.00 invoice is a charge with no total, so it is NOT collected.
  #   QboInvoice#status reads it as :paid, which is why this does not use it.
  # - No stored data, or an unreadable amount, is unknown: not collected.
  def management_fee_collected?
    unless management_fee?
      raise "management_fee_collected? only applies to #{Enterprise::GARDEN3D_NAME}'s passes " \
            "(this pass belongs to #{enterprise.name})"
    end

    own_account_ids = QboAccount.where(enterprise_id: enterprise_id).pluck(:id)
    charged = []

    # Fresh queries throughout, by the (account, id) pair: never the cached
    # association, and never the qbo_invoice association.
    InvoiceTracker.where(invoice_pass_id: id).where.not(qbo_invoice_id: nil).order(:id).each do |tracker|
      unless own_account_ids.include?(tracker.qbo_account_id)
        raise "InvoiceTracker #{tracker.id} on this pass points at QuickBooks account " \
              "#{tracker.qbo_account_id}, which is not #{enterprise.name}'s"
      end

      mirror = QboInvoice.find_by(qbo_account_id: tracker.qbo_account_id, qbo_id: tracker.qbo_invoice_id)
      stored = mirror&.read_attribute(:data)
      return false if stored.blank?

      next if stored["private_note"].to_s.downcase.include?("voided")

      total = stored_amount(stored["total"])
      balance = stored_amount(stored["balance"])
      return false if total.nil? || balance.nil?

      sent = stored["email_status"] == "EmailSent"
      next unless sent || total.positive? # unsent and zero: nobody was charged

      charged << [total, balance]
    end

    return false if charged.empty?
    charged.all? { |total, balance| total.positive? && balance.zero? }
  end
```

At the very end of the class, directly above the final `end`, add:

```ruby

  private

  # The mirror stores amounts as Strings ("130000.0"). nil when unparseable.
  def stored_amount(value)
    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end
```

- [ ] **Step 5: Write the refreshing entry point**

In `app/services/mso/management_fee_invoices.rb`, add an error class directly below `class AlreadyInvoiced < Error; end`:

```ruby
    class RefreshFailed < Error; end
```

Add this public method directly above the `private` line inside `class << self`:

```ruby

      # Has garden3d been paid the fee it charged for this pass's month?
      # THE ENTRY POINT FOR ANY PAYABILITY DECISION.
      #
      # Reads every attached invoice from QuickBooks first, because the stored
      # copy starts life as an unsent $0.00 draft and nothing else updates it.
      # If any invoice cannot be read it RAISES: an answer from a stale copy
      # could say "nobody was charged" about an invoice that is unpaid.
      #
      # Costs one QuickBooks read per attached invoice. Call it once per run
      # or page and reuse the answer; do not call it per ledger row.
      def collected?(invoice_pass:)
        run = refresh!(invoice_pass: invoice_pass)
        if run.failed.any?
          raise RefreshFailed, "Could not read the QuickBooks invoice on InvoiceTracker " \
                               "#{run.failed.map(&:id).join(', ')}; refusing to say whether " \
                               "#{invoice_pass.invoice_month}'s management fee was collected"
        end

        # A fresh pass: refresh! may have detached a tracker.
        InvoicePass.find(invoice_pass.id).management_fee_collected?
      end
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/models/invoice_pass_management_fee_collected_test.rb \
  test/services/mso/management_fee_invoices_collected_test.rb
```

Expected: PASS, 20 runs (16 + 4), 0 failures.

- [ ] **Step 7: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 20 more runs than after Task 8, 0 failures, 0 errors. Report the actual total.

- [ ] **Step 8: Commit**

```bash
git add app/models/invoice_pass.rb app/services/mso/management_fee_invoices.rb \
  test/models/invoice_pass_management_fee_collected_test.rb \
  test/services/mso/management_fee_invoices_collected_test.rb
git commit -m "feat(mso): has garden3d's management fee been collected?

An invoice is a charge when it was sent or carries an amount; untouched
drafts and voided invoices are not. Collected means at least one charge and
every charge paid in full. Mso::ManagementFeeInvoices.collected? reads
QuickBooks first and raises if it cannot, because the stored copy starts as
an unsent \$0.00 draft."
```

---

### Task 10: The pass and its trackers appear on their own

**Decision, restated because it is the point of this task:** the nightly job creates garden3d's pass for the previous month and one tracker per payer. That is all it does. It makes **no** QuickBooks call. The drafts are created only when an admin clicks.

Nothing else creates garden3d's pass. `InvoicePass` has no create page (`app/admin/invoice_passes.rb:7`), and `attempt_invoicing_for_previous_month` is scoped to Sanctuary (`lib/stacks/automator.rb:164-177`). Without this task an admin would have no pass to click on.

Two entry points:

- **`ensure_month!(date)`** — pass and trackers for **any** month, database only. This is how a month that was invoiced by hand gets a pass to attach those invoices to (see Deploy). Attaching is not drafting, so it has no start-month limit.
- **`ensure_previous_month!`** — the nightly one. It does nothing for a month before `MANAGEMENT_FEE_START`: those months were invoiced by hand and nobody should be invited to draft them. It makes last month's pass, and catches up any earlier month since the start that has none (at most `CATCH_UP_MONTHS` = 12 back). With the start at August 2026 and the code shipping in October, its first run creates August's and September's passes; October's follows on 1 November. (As first written this task created last month's pass only; the code blocks below show that version.)

The hook is `Enterprise#daily_tasks`, which exists for exactly this (`app/models/enterprise.rb:64-68`) and is called per enterprise with its own rescue from `stacks:daily_enterprise_tasks` (`lib/tasks/stacks.rake:134-139`). One failure there is logged and does not stop the other enterprises or the rest of the task.

**Files:**
- Modify: `app/services/mso/management_fee_invoices.rb`
- Modify: `app/models/enterprise.rb`
- Create: `test/services/mso/management_fee_invoices_nightly_test.rb`

**Interfaces:**
- Consumes: `ensure_trackers!` (Task 4), `MANAGEMENT_FEE_START` (Task 5), `Enterprise#is_garden3d?` (Task 1)
- Produces:
  - `Mso::ManagementFeeInvoices.ensure_month!(date) -> InvoicePass`. **Database only.** Any month.
  - `Mso::ManagementFeeInvoices.ensure_previous_month!(today: Date.today) -> InvoicePass`, or `nil` when last month predates `MANAGEMENT_FEE_START` or the migration has not been run. **Database only.**
  - `Enterprise#daily_tasks` calls `ensure_previous_month!` for garden3d

- [ ] **Step 1: Write the failing test**

Create `test/services/mso/management_fee_invoices_nightly_test.rb`:

```ruby
require "test_helper"

class Mso::ManagementFeeInvoicesNightlyTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include ManagementFeeFixtures

  TODAY = Date.new(2090, 10, 12)
  LAST_MONTH = Date.new(2090, 9, 1)

  def setup
    @qbo_account = garden3d_qbo_account
    make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [993_001])
    make_payer(Enterprise::INDEX_SPACE_NAME, customer_id: "5", forecast_ids: [993_002])
  end

  def teardown
    clear_enterprise_memos
  end

  def forbid_quickbooks
    QboAccount.any_instance.expects(:make_and_refresh_qbo_access_token).never
    QboAccount.any_instance.expects(:fetch_all_items).never
    QboAccount.any_instance.expects(:fetch_all_terms).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    QboAccount.any_instance.expects(:fetch_invoice_by_id).never
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    Quickbooks::Service::Invoice.any_instance.expects(:query).never
    Quickbooks::Service::Customer.any_instance.expects(:create).never
    Mso::ManagementFeeInvoices.expects(:push_invoice!).never
    Mso::ManagementFeeInvoices.expects(:create_drafts!).never
  end

  def garden3d_passes
    InvoicePass.where(enterprise_id: garden3d.id)
  end

  # --- ensure_month! ---------------------------------------------------------

  test "ensure_month! creates garden3d's pass for that month with one tracker per payer" do
    pass = Mso::ManagementFeeInvoices.ensure_month!(Date.new(2090, 9, 17))

    assert_equal garden3d, pass.enterprise
    assert_equal LAST_MONTH, pass.start_of_month
    trackers = InvoiceTracker.where(invoice_pass_id: pass.id)
    assert_equal [993_001, 993_002], trackers.pluck(:forecast_client_id).sort
    assert_equal [nil, nil], trackers.pluck(:qbo_invoice_id)
  end

  test "ensure_month! works for a month before drafting started, so its invoices can be attached" do
    forbid_quickbooks
    month = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START - 4.months

    pass = Mso::ManagementFeeInvoices.ensure_month!(month)

    assert_equal month, pass.start_of_month
    assert_equal 2, InvoiceTracker.where(invoice_pass_id: pass.id).count
    refute Mso::ManagementFeeInvoices.draftable?(pass), "attachable, never draftable"
  end

  test "ensure_month! twice changes nothing" do
    first = Mso::ManagementFeeInvoices.ensure_month!(LAST_MONTH)

    assert_no_difference [-> { InvoicePass.count }, -> { InvoiceTracker.count }] do
      assert_equal first.id, Mso::ManagementFeeInvoices.ensure_month!(LAST_MONTH).id
    end
  end

  # --- ensure_previous_month! ------------------------------------------------

  test "the nightly run creates last month's pass and never touches QuickBooks" do
    forbid_quickbooks

    pass = Mso::ManagementFeeInvoices.ensure_previous_month!(today: TODAY)

    assert_equal LAST_MONTH, pass.start_of_month
    assert_equal 2, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  test "the nightly run does nothing while last month predates the start month" do
    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START

    assert_no_difference [-> { InvoicePass.count }, -> { InvoiceTracker.count }] do
      # Any day in the start month: "last month" was invoiced by hand.
      assert_nil Mso::ManagementFeeInvoices.ensure_previous_month!(today: start + 11.days)
    end

    # The first of the following month: last month IS the start month.
    assert_equal start, Mso::ManagementFeeInvoices.ensure_previous_month!(today: start.next_month).start_of_month
  end

  test "the nightly run leaves Sanctuary's pass for the same month alone" do
    sanctuary_pass = InvoicePass.create!(start_of_month: LAST_MONTH, enterprise: enterprises(:sanctuary), data: {})

    pass = Mso::ManagementFeeInvoices.ensure_previous_month!(today: TODAY)

    refute_equal sanctuary_pass.id, pass.id
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: sanctuary_pass.id).count
  end

  # --- the hook --------------------------------------------------------------

  test "garden3d's daily tasks run it, without QuickBooks" do
    forbid_quickbooks
    Stacks::Optix.expects(:deactivate_inactive_members!).never

    travel_to TODAY do
      assert_difference -> { garden3d_passes.count }, 1 do
        Enterprise.find(garden3d.id).daily_tasks
      end
    end
    assert_equal [LAST_MONTH], garden3d_passes.pluck(:start_of_month)
  end

  test "another enterprise's daily tasks do not" do
    Mso::ManagementFeeInvoices.expects(:ensure_previous_month!).never

    enterprises(:one).daily_tasks
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/mso/management_fee_invoices_nightly_test.rb
```

Expected: 8 runs, 7 failing. The first six error with `NoMethodError` (`ensure_month!`, `ensure_previous_month!`); `garden3d's daily tasks run it…` FAILS (no pass created); `another enterprise's daily tasks do not` passes.

- [ ] **Step 3: Write the implementation**

In `app/services/mso/management_fee_invoices.rb`, add these two public methods directly above the `private` line inside `class << self`:

```ruby

      # garden3d's pass for the month containing `date`, with one tracker per
      # payer. DATABASE ONLY -- no QuickBooks call.
      #
      # Works for ANY month, including ones before MANAGEMENT_FEE_START: a
      # month invoiced by hand needs a pass and trackers so those invoices can
      # be attached. It never makes a pass draftable; see draftable?.
      def ensure_month!(date)
        assert_schema_ready!

        month = date.to_date.beginning_of_month
        pass = InvoicePass.find_or_create_by!(enterprise: Enterprise.garden3d, start_of_month: month) do |new_pass|
          new_pass.data = {}
        end
        ensure_trackers!(invoice_pass: pass)
        pass
      end

      # The nightly, database-only half: makes sure garden3d has a pass for
      # last month, ready for an admin to act on.
      #
      # NEVER WRITES TO QUICKBOOKS. Do not add a push here. Creating the
      # drafts is an explicit admin click (create_drafts!).
      def ensure_previous_month!(today: Date.today)
        # Migrations are run by hand on production, after the deploy. Until
        # then this is a no-op rather than a nightly error.
        return nil unless schema_ready?

        month = (today - 1.month).beginning_of_month
        # Months before the start were invoiced by hand. Do not put a pass in
        # front of an admin that invites drafting them.
        return nil if month < MANAGEMENT_FEE_START

        ensure_month!(month)
      end
```

In `app/models/enterprise.rb`, replace `daily_tasks` (lines 64-68) with:

```ruby
  # Per-enterprise daily automation, dispatched by stacks:daily_enterprise_tasks.
  # Add new per-enterprise behaviors here rather than as new rake steps.
  def daily_tasks
    Stacks::Optix.deactivate_inactive_members! if is_index?
    # Database only: garden3d's pass for last month and its trackers. Nothing
    # here may write to QuickBooks; an admin creates the drafts by hand.
    Mso::ManagementFeeInvoices.ensure_previous_month! if is_garden3d?
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/management_fee_invoices_nightly_test.rb test/models/enterprise_test.rb
```

Expected: PASS. 8 runs in the new file, plus the existing enterprise tests, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 8 more runs than after Task 9, 0 failures, 0 errors. Report the actual total.

- [ ] **Step 6: Commit**

```bash
git add app/services/mso/management_fee_invoices.rb app/models/enterprise.rb \
  test/services/mso/management_fee_invoices_nightly_test.rb
git commit -m "feat(mso): garden3d's pass and trackers are created nightly, database only

The nightly task makes last month's pass and one tracker per payer so an
admin has something to act on, starting with October 2026. It never calls
QuickBooks. ensure_month! does the same for any month, so a month invoiced
by hand can have its invoices attached."
```

---

### Task 11: Keep the fee out of the invoicing totals

`Mcp::GetInvoicePassesTool` reports invoiced totals per pass and a month-over-month series that sums every pass in a month (`app/services/mcp/get_invoice_passes_tool.rb:44-45`). garden3d's fee invoices are intercompany: Sanctuary pays garden3d. Counting them adds $130k–$170k to a month's "total invoiced". It would also report each as `impossible` (lines 106-108).

**Files:**
- Modify: `app/services/mcp/get_invoice_passes_tool.rb`
- Modify: `test/services/mcp/invoice_passes_tool_test.rb`

**Interfaces:**
- Consumes: `InvoicePass#management_fee?` (Task 2)
- Produces: management fee invoice trackers (blueprint-less, on a garden3d pass) are left out of `entities`, `total_invoiced` and the `mom` series; a legacy Forecast tracker on a garden3d pass is reported as before

- [ ] **Step 1: Write the failing test**

In `test/services/mcp/invoice_passes_tool_test.rb`, add directly above the test named `"each pass row names its issuing enterprise"` (line 216):

```ruby
  test "garden3d's management fee invoices are intercompany and stay out of the totals" do
    seed_july!
    garden3d = enterprises(:garden3d)
    garden3d_qa = QboAccount.create!(enterprise: garden3d, client_id: 'c', client_secret: 's',
                                     realm_id: "g-#{SecureRandom.hex(4)}")
    fee_pass = InvoicePass.create!(start_of_month: Date.new(2026, 7, 1), enterprise: garden3d)
    invoice!('fee-july', { 'total' => 170000.0, 'balance' => 170000.0, 'email_status' => 'EmailSent',
                           'due_date' => '2026-08-15' }, account: garden3d_qa)
    tracker!(fee_pass, @client, qbo_invoice_id: 'fee-july', account: garden3d_qa)

    payload = mcp_payload(Mcp::GetInvoicePassesTool.call(server_context: {}))

    fee_row = payload['passes'].find { |p| p['enterprise'] == 'garden3d, LLC' }
    assert_equal '2026-07-01', fee_row['month']
    assert_equal [], fee_row['entities']
    assert_equal 0.0, fee_row['total_invoiced']

    july = payload['mom'].find { |m| m['month'] == '2026-07-01' }
    assert_equal 1750.0, july['total_invoiced'], 'the fee must not be added to the month'
  ensure
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "a legacy Forecast tracker on a garden3d pass is still reported, as before" do
    garden3d = enterprises(:garden3d)
    garden3d_qa = QboAccount.create!(enterprise: garden3d, client_id: 'c', client_secret: 's',
                                     realm_id: "g-#{SecureRandom.hex(4)}")
    legacy_pass = InvoicePass.create!(start_of_month: Date.new(2026, 7, 1), enterprise: garden3d)
    tracker!(legacy_pass, @client, account: garden3d_qa, blueprint: { 'lines' => {} })

    payload = mcp_payload(Mcp::GetInvoicePassesTool.call(server_context: {}))

    row = payload['passes'].find { |p| p['enterprise'] == 'garden3d, LLC' }
    assert_equal [{ 'entity' => 'garden3d, LLC', 'invoiced_total' => 0.0, 'invoice_count' => 0,
                    'status_mix' => { 'deleted' => 1 }, 'skipped_invoices' => 0 }], row['entities']
  ensure
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/mcp/invoice_passes_tool_test.rb
```

Expected: the first new test FAILS. `fee_row['entities']` holds a garden3d entity with `invoiced_total` 170000.0 and a status mix of `impossible`, and July's series reads 171750.0. The second passes already: it pins what must not change.

- [ ] **Step 3: Write the implementation**

In `app/services/mcp/get_invoice_passes_tool.rb`, replace the start of `pass_block` (lines 60-64):

```ruby
    def self.pass_block(pass)
      entities = pass.invoice_trackers
        .group_by { |t| t.qbo_account&.enterprise&.name || 'Unknown entity' }
```

with:

```ruby
    def self.pass_block(pass)
      # garden3d's pass holds its management fee invoices to the operating
      # companies. Those are intercompany: counting them would add the fee to
      # the month's invoiced total and to the MoM series, which sums every
      # pass in a month. The pass row is still listed.
      #
      # Only blueprint-less trackers are left out. garden3d's 2025 passes each
      # hold a legacy Forecast tracker with a blueprint; those are reported
      # exactly as before.
      trackers = pass.invoice_trackers
      trackers = trackers.reject { |tracker| tracker.blueprint.nil? } if pass.management_fee?
      entities = trackers
        .group_by { |t| t.qbo_account&.enterprise&.name || 'Unknown entity' }
```

In the tool's `description` (lines 4-11), replace the last sentence:

```ruby
                'QBO invoice data only — mirrors with no synced data yet are skipped and ' \
                'counted per entity, never fetched live.'
```

with:

```ruby
                'QBO invoice data only — mirrors with no synced data yet are skipped and ' \
                'counted per entity, never fetched live. garden3d\'s own passes hold its ' \
                'intercompany management fee invoices, which are left out of every total.'
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mcp/invoice_passes_tool_test.rb
```

Expected: PASS, two more runs than this file had before, 0 failures.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 2 more runs than after Task 10, 0 failures, 0 errors. The total is the baseline plus 148 (3 + 7 + 9 + 11 + 11 + 19 + 14 + 22 + 22 + 20 + 8 + 2): 2084 if the baseline was 1936. Report the actual total.

- [ ] **Step 6: Commit**

```bash
git add app/services/mcp/get_invoice_passes_tool.rb test/services/mcp/invoice_passes_tool_test.rb
git commit -m "fix(mcp): garden3d's management fee invoices stay out of invoiced totals

They are intercompany. Counted, they added the whole fee to a month's total
invoiced and to the month-over-month series."
```

---

### Task 12: Verification against the dev database

Read-only checks against real data. The dev database is a copy of production with live credentials, so every script below first makes a QuickBooks call impossible, prints ids, counts and amounts only (never a person's or company's name), and writes nothing.

No commit in this task. Delete each script after running it. `tmp/` is git-ignored.

Every script starts with the same guard. It is written out in each so they can be run alone.

- [ ] **Step 1: Fee income for the three verified months**

Needs no migration. Save as `tmp/verify_fee_income.rb`:

```ruby
ActiveRecord::Base.logger = nil
# Any QuickBooks call needs a token. Make getting one impossible.
QboAccount.class_eval do
  def make_and_refresh_qbo_access_token(*)
    raise "verification must not call QuickBooks"
  end
end

[Date.new(2026, 6, 1), Date.new(2026, 7, 15), Date.new(2026, 8, 31)].each do |date|
  value = Mso::ManagementFeeIncome.for_month(date)
  puts "#{date.strftime('%Y-%m')} #{value.class} #{value.to_s('F')}"
end

begin
  Mso::ManagementFeeIncome.for_month(Date.new(2025, 12, 1))
  puts "2025-12 UNEXPECTED: no error"
rescue Mso::ManagementFeeIncome::RowMissing => e
  puts "2025-12 RowMissing: #{e.message}"
end

result = Mso::ManagementFeeIncome.reconcile(Date.new(2026, 8, 1))
totals = result.slice(:account_total, :payer_total, :variance).transform_values { |v| v.to_s('F') }
puts "reconcile 2026-08: #{totals.inspect} invoices=#{result[:invoices].size}"
```

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
bin/rails runner tmp/verify_fee_income.rb
rm tmp/verify_fee_income.rb
```

Expected (the first four lines are what the reader printed when the plan was written):

```
2026-06 BigDecimal 130000.0
2026-07 BigDecimal 170000.0
2026-08 BigDecimal 140000.0
2025-12 RowMissing: garden3d's accrual P&L for December 2025 has no account 4100 row (27 rows). No management fee was booked, or the account was renumbered.
reconcile 2026-08: {:account_total=>"140000.0", :payer_total=>"0.0", :variance=>"140000.0"} invoices=0
```

The August variance is correct for the dev data: garden3d has no pass or tracker for August, so nothing has been attached yet. If any line raises `verification must not call QuickBooks`, a stored report is missing and the reader tried to fetch it; stop and report that.

- [ ] **Step 2: The seven legacy garden3d passes are unchanged**

Needs no migration. Save as `tmp/verify_legacy_passes.rb`:

```ruby
ActiveRecord::Base.logger = nil
QboAccount.class_eval do
  def make_and_refresh_qbo_access_token(*)
    raise "verification must not call QuickBooks"
  end
end

garden3d = Enterprise.find_by!(name: Enterprise::GARDEN3D_NAME)
InvoicePass.where(enterprise_id: garden3d.id).order(:start_of_month).each do |pass|
  trackers = InvoiceTracker.where(invoice_pass_id: pass.id).to_a
  puts "pass=#{pass.id} month=#{pass.start_of_month} kind=#{pass.invoicing_kind} " \
       "legacy=#{pass.legacy_forecast_trackers?} draftable=#{Mso::ManagementFeeInvoices.draftable?(pass)} " \
       "statuses=#{pass.statuses.inspect} payout_statuses=#{pass.payout_statuses.inspect} " \
       "trackers=#{trackers.map { |t| [t.id, t.management_fee_invoice?, t.status] }.inspect} " \
       "collected=#{pass.management_fee_collected?}"
end
puts "passes by enterprise id: #{InvoicePass.group(:enterprise_id).count.inspect}"
```

```bash
bin/rails runner tmp/verify_legacy_passes.rb
rm tmp/verify_legacy_passes.rb
```

Expected: seven lines, passes 838–844 for 2025-06-01 … 2025-12-01, each reading

```
kind=management_fee legacy=true draftable=false statuses={:deleted=>1} payout_statuses={:all_accepted=>1} trackers=[[<id>, false, :deleted]] collected=false
```

`statuses` and `payout_statuses` are what those passes report on `main` today. An empty `payout_statuses` means a legacy tracker lost its payout pill and Task 3 is wrong (Decisions, item 29). `true` in a tracker triple means a legacy tracker is being treated as a management fee invoice and Task 2 is wrong. The last line reads `{35=>7, 2=>64}` or the same with more Sanctuary passes; any third enterprise id means a pass exists that `invoicing_kind` will raise on.

- [ ] **Step 3: Which client each payer's tracker would use**

Needs no migration: it reads the join table, not the new columns. Save as `tmp/verify_payer_clients.rb`:

```ruby
ActiveRecord::Base.logger = nil
[Enterprise::SANCTUARY_NAME, Enterprise::INDEX_SPACE_NAME, Enterprise::USB_CLUB_NAME].each do |name|
  enterprise = Enterprise.find_by!(name: name)
  client_ids = EnterpriseForecastClient.where(enterprise_id: enterprise.id).order(:forecast_client_id)
                                       .pluck(:forecast_client_id)
  qbo_accounts = QboAccount.where(enterprise_id: enterprise.id).order(:id).pluck(:id)
  puts "enterprise=#{enterprise.id} internal_clients=#{client_ids.inspect} tracker_client=#{client_ids.first} " \
       "qbo_accounts=#{qbo_accounts.inspect}"
end
garden3d = Enterprise.find_by!(name: Enterprise::GARDEN3D_NAME)
puts "garden3d=#{garden3d.id} qbo_accounts=#{QboAccount.where(enterprise_id: garden3d.id).order(:id).pluck(:id).inspect}"
```

```bash
bin/rails runner tmp/verify_payer_clients.rb
rm tmp/verify_payer_clients.rb
```

Expected:

```
enterprise=2 internal_clients=[607830, 769476, 1022451, 1087451, 1414417] tracker_client=607830 qbo_accounts=[2]
enterprise=1 internal_clients=[1466083] tracker_client=1466083 qbo_accounts=[1]
enterprise=68 internal_clients=[1858301] tracker_client=1858301 qbo_accounts=[68]
garden3d=35 qbo_accounts=[35]
```

`tracker_client` must be 607830, 1466083 and 1858301, the internal clients spec §3 names. If Sanctuary's lowest id is no longer 607830, stop: the lowest-id rule (Decisions, item 4) would pick the wrong client.

- [ ] **Step 4: Which months were invoiced by hand, and what is mirrored**

Needs no migration. This is the evidence for `MANAGEMENT_FEE_START` and for Task 0. Save as `tmp/verify_hand_invoiced.rb`:

```ruby
ActiveRecord::Base.logger = nil
garden3d = Enterprise.find_by!(name: Enterprise::GARDEN3D_NAME)
qbo_account = QboAccount.where(enterprise_id: garden3d.id).order(:id).first

monthly = QboProfitAndLossReport.where(qbo_account_id: qbo_account.id).where("ends_at - starts_at < 32").order(:starts_at)
with_fee = monthly.select do |report|
  row = (report.data.dig("accrual", "rows") || []).find { |r| r[0].to_s.match?(/\A4100\b/) }
  row && BigDecimal(row[1].to_s) != 0
end
puts "months with a non-zero 4100: #{with_fee.map { |r| r.starts_at.strftime('%Y-%m') }.uniq.inspect}"
puts "start month: #{Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START}"
start_report = monthly.where(starts_at: Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START).order(:id).last
start_row = start_report && (start_report.data.dig("accrual", "rows") || []).find { |r| r[0].to_s.match?(/\A4100\b/) }
puts "4100 already booked in the start month: #{start_row ? start_row[1] : 'none'}"
puts "invoice mirror rows by qbo_account id: #{QboInvoice.group(:qbo_account_id).count.inspect}"
puts "garden3d passes from the start month on: #{InvoicePass.where(enterprise_id: garden3d.id).where('start_of_month >= ?', Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START).count}"
```

```bash
bin/rails runner tmp/verify_hand_invoiced.rb
rm tmp/verify_hand_invoiced.rb
```

Expected on the dev data as of 2026-10-12:

```
months with a non-zero 4100: ["2024-01", "2024-02", … every month … "2025-11", "2026-01", "2026-02", … "2026-10"]
start month: 2026-10-01
4100 already booked in the start month: 10000.0
invoice mirror rows by qbo_account id: {2=>1831}
garden3d passes from the start month on: 0
```

That is 2024-01 through 2025-11 with no gaps, then 2026-01 through 2026-10; only 2025-12 is missing. Report two things to the owner verbatim: the `4100 already booked in the start month` figure (Decisions, item 31: a non-zero figure means a hand-made invoice is already dated in the first month Stacks would draft), and the mirror line (any account other than 2 already holding rows means Task 0's bug is already live, not latent).

- [ ] **Step 5: Would creating a customer collide with an existing name?**

Needs no migration. Answerable only for **vendors**, which are mirrored nightly; employees and inactive names are not mirrored and are a manual check for Finance (Decisions, item 20). Prints QuickBooks ids only. Save as `tmp/verify_name_collisions.rb`:

```ruby
ActiveRecord::Base.logger = nil
garden3d = Enterprise.find_by!(name: Enterprise::GARDEN3D_NAME)
qbo_account = QboAccount.where(enterprise_id: garden3d.id).order(:id).first
vendors = QboVendor.where(qbo_account_id: qbo_account.id).to_a
puts "garden3d mirrored vendors: #{vendors.size}"

squash = ->(name) { name.to_s.downcase.gsub(/[^a-z0-9]/, "") }
[Enterprise::SANCTUARY_NAME, Enterprise::INDEX_SPACE_NAME, Enterprise::USB_CLUB_NAME].each do |name|
  enterprise = Enterprise.find_by!(name: name)
  names_of = ->(vendor) { data = vendor.read_attribute(:data) || {}; [data["display_name"], data["company_name"]].compact }
  exact = vendors.select { |v| names_of.call(v).any? { |n| n.strip.casecmp?(name) } }
  loose = vendors.select { |v| names_of.call(v).any? { |n| squash.call(n) == squash.call(name) } }
  puts "enterprise=#{enterprise.id} vendors_with_exact_name=#{exact.map(&:qbo_id).inspect} " \
       "vendors_with_name_ignoring_punctuation=#{loose.map(&:qbo_id).inspect}"
end
```

```bash
bin/rails runner tmp/verify_name_collisions.rb
rm tmp/verify_name_collisions.rb
```

Expected on the dev data:

```
garden3d mirrored vendors: 140
enterprise=2 vendors_with_exact_name=[] vendors_with_name_ignoring_punctuation=[]
enterprise=1 vendors_with_exact_name=[] vendors_with_name_ignoring_punctuation=[]
enterprise=68 vendors_with_exact_name=[] vendors_with_name_ignoring_punctuation=["68"]
```

Only enterprise 68 (USB Club) matters: it is the only payer with no stored customer id. An id under `vendors_with_exact_name` means QuickBooks will certainly refuse the customer create. An id only under `…ignoring_punctuation` (vendor 68 today) means it may. Either way the push raises a clear error rather than making a duplicate; report the line to the owner so Finance can settle it before the first USB Club draft.

- [ ] **Step 6: The payer seed — only once the migration has been run on that database**

This step reads the new columns. Do **not** run `bin/rails db:migrate` to get them; it re-dumps `db/schema.rb`. Run this only against a database the owner has migrated (see Deploy), and skip it otherwise. Save as `tmp/verify_payer_seed.rb`:

```ruby
ActiveRecord::Base.logger = nil
abort "the management fee columns are not on this database yet" unless Enterprise.column_names.include?("management_fee_payer")

Enterprise.order(:id).each do |enterprise|
  puts "enterprise=#{enterprise.id} payer=#{enterprise.management_fee_payer} " \
       "g3d_customer=#{enterprise.g3d_qbo_customer_id.inspect} valid=#{enterprise.valid?}"
end
```

```bash
bin/rails runner tmp/verify_payer_seed.rb
rm tmp/verify_payer_seed.rb
```

Expected:

```
enterprise=1 payer=true g3d_customer="5" valid=true
enterprise=2 payer=true g3d_customer="2" valid=true
enterprise=35 payer=false g3d_customer=nil valid=true
enterprise=68 payer=true g3d_customer=nil valid=true
```

- [ ] **Step 7: Confirm nothing scheduled can write an invoice**

```bash
grep -rn "push_invoice!\|create_drafts!" app lib --include="*.rb" --include="*.rake"
```

Expected: matches only in `app/services/mso/management_fee_invoices.rb` (the definitions, and `create_drafts!` calling `push_invoice!`), `app/models/invoice_tracker.rb` (the `make_invoice!` dispatch) and `app/admin/invoice_passes.rb` (the admin action). No match in `lib/`, in any `.rake` file, or in `lib/stacks/automator.rb`.

```bash
grep -n "make_invoice!" -r app lib --include="*.rb" --include="*.rake"
```

Expected: the definition in `app/models/invoice_tracker.rb`, the call in `app/admin/invoice_trackers.rb` (`attempt_generate`), and `lib/stacks/automator.rb:99`. That last one is inside `attempt_invoicing_for_invoice_pass`, which returns at lines 69-75 for any pass that is not Sanctuary's, so it cannot reach a management fee invoice tracker.

```bash
grep -rn "includes(.*:qbo_invoice\|preload(.*:qbo_invoice" app lib --include="*.rb"
```

Expected: the four preloads Task 0 names (`app/admin/invoice_passes.rb`, two in `app/models/contributor.rb`, `app/models/project_tracker.rb`) and nothing under `app/services/mso/` or in `InvoicePass#management_fee_collected?`. The preloads are safe after Task 0; the point is that no fee code relies on one.

---

## Deploy

Merging to `main` deploys once `main`'s own CI is green. **Migrations are run by hand afterwards; there is no release phase.** So the new code runs for a while against a database without the two new columns.

**What breaks between merge and migrate: nothing that works today.**

| Code path | Before the migration | Why it is safe |
| --- | --- | --- |
| Saving any `Enterprise` (admin edit, nightly `generate_snapshot!`) | unchanged | the payer validation is skipped while `has_attribute?(:management_fee_payer)` is false (Task 1) |
| Nightly `stacks:daily_enterprise_tasks` | unchanged | `ensure_previous_month!` returns `nil` while the column is absent (Task 10) |
| Every Sanctuary pass and tracker | unchanged | `forecast?` is checked first; no new column is read |
| The seven legacy garden3d passes and their trackers | behave as before, **but only an admin can now open them** | every behaviour change keys on `management_fee_invoice?` or `legacy_forecast_trackers?` (Decisions, item 3); the admin-only rule is deliberate (item 25) |
| Any invoice lookup | unchanged while only Sanctuary's account has mirror rows | Task 0 changes the answer only when a preloaded invoice belongs to another account |
| **Create management fee drafts**, **Regenerate** on a fee tracker, `ensure_month!` | an error: "The management fee columns are not on this database yet" | `assert_schema_ready!`; these are new features, not regressions |

Three behaviours change at deploy whether or not the migration has run:

- **garden3d's invoice passes become admin-only**, with their trackers and the payouts pages under them (Decisions item 25). At deploy that is the seven legacy passes, June–December 2025: leads and project-scoped grantees stop seeing them in Money → Invoicing and are refused their pages. A contributor paid on one still sees the payout on their own page and can open it.
- `make_invoice!` on a pass that is neither Sanctuary's nor garden3d's raises `InvoicePass::UnsupportedIssuer`. No such pass exists.
- The tracker edit page's invoice dropdown lists only that tracker's own QuickBooks account's unattached invoices, and none for a non-admin. Today every mirrored invoice is Sanctuary's and every tracker with a live use for the dropdown is Sanctuary's, so an admin sees the same list.

**Steps, in order:**

1. Merge. Wait for the deploy. Task 0 is now live, which is what makes step 6 safe.
2. Run the migration on production by hand: `rails db:migrate`. It adds two columns with defaults and updates three rows.
3. **Restart the dynos.** Running processes cached the old column list; until they restart, `has_attribute?` and `column_names` still say the columns are missing and the feature stays switched off.
4. Run Task 12, Step 6 against production to confirm the seed, and Steps 4 and 5 to see the hand-invoiced months and the USB Club name check on live data.
5. Settle the owner question in Decisions item 20 (USB Club's name) before the first click. The start month is settled: August 2026 (item 31).
6. The first nightly run after step 3 creates August's and September's passes, three trackers each (the catch-up). October's follows on 1 November. Nothing is sent to QuickBooks, and QuickBooks is not read.

**Drafting a month (August 2026 onward).** An admin opens garden3d's pass and clicks **Create management fee drafts** once. For each payer Stacks first asks QuickBooks whether that customer already has an invoice dated in the month, and skips it with a message if so. Finance edits the amounts in QuickBooks and sends them. **Refresh from QuickBooks** brings statuses and totals back.

**August, September and October 2026: already invoiced by hand.** These three are inside the start month, so the button is offered, but Finance made their invoices in QuickBooks before this shipped. Do NOT expect new drafts; the click is how the existing invoices get into Stacks. For each of the three months:

1. Check in QuickBooks that each payer's invoice for the month is **dated inside that month** (Decisions item 31). The pre-flight cannot see one dated outside it and would create a $0.00 draft beside it.
2. Open garden3d's pass for the month (Money → Invoicing; only an admin sees garden3d's passes). August's and September's exist after the first nightly run. October's does not exist until 1 November; to work on it sooner, or on August and September before the nightly run has been, pick the month in **Open garden3d month** at the top of Money → Invoicing and click the button. That makes the pass and its trackers and takes you to it. It is database only: no QuickBooks call.
3. Click **Create management fee drafts**. It will refuse for each payer QuickBooks already holds an invoice for, and the alert lists those invoices by id and total ("garden3d, LLC's QuickBooks already holds 1 invoice(s) for … Stacks will not create another"). That is the expected result. A payer with no invoice dated in the month does get a $0.00 draft.
4. For each tracker on the pass: **Open →**, **Edit**, pick the listed invoice from the dropdown, save.
5. Click **Refresh from QuickBooks** on the pass.

No console sync of garden3d's mirror is needed for these months: the refused click records exactly the invoices it found. October is unfinished, so its invoices may still change; refresh again once the month is closed.

**A month that was invoiced by hand (every month before the start except June–December 2025, and any later month Finance does by hand).** Stacks will not draft it. To have its existing invoices attached, so that `reconcile` and the collection gate can see them:

1. Fill garden3d's invoice mirror. Console, by the owner; a QuickBooks **read** that upserts mirror rows:
   ```ruby
   garden3d_account = QboAccount.where(enterprise_id: Enterprise.garden3d.id).order(:id).first
   garden3d_account.sync_all_invoices!
   ```
   Not before step 1 above: this creates the second-account rows that Task 0 guards against.
2. Give the month a pass and trackers. In the admin: Money → Invoicing, pick the month in **Open garden3d month**, click the button. Database only, no QuickBooks call. (The console equivalent is `Mso::ManagementFeeInvoices.ensure_month!(Date.new(2026, 7, 1))`.)
   **Not for June–December 2025.** Those seven passes each hold a legacy Forecast tracker; their page is rendered as it always was and cannot manage fee trackers, so `ensure_month!` raises `LegacyPass` and adds nothing. Their fee invoices cannot be attached, and the collection gate answers "not collected" for those months.
3. In the admin, open that pass (Money → Invoicing), open each tracker, **Edit**, pick the month's invoice from the dropdown (it lists garden3d's unattached invoices only) and save.
4. Click **Refresh from QuickBooks** on the pass.

Saving a tracker's edit form again after step 3 is safe: the bug that detached an attached invoice on a later save is fixed (Decisions item 35, commit e41cce66). Only choosing "None" detaches.

Which past months need this is S4's call: it depends on which months `Mso::MonthlyRun` will be run for.

**Rollback:** revert the merge and deploy. The columns can stay; nothing else reads them. Trackers and passes the nightly job or `ensure_month!` created are inert without the code. Drafts already in QuickBooks are ordinary $0.00 invoices Finance can delete. One caution: if garden3d's mirror was filled (step 1 of attaching), reverting also reverts Task 0, and the cross-account lookup bug is then live. Either keep Task 0's commit when reverting, or delete garden3d's mirror rows first (`QboInvoice.where(qbo_account_id: garden3d_account.id).delete_all`, after detaching its trackers).

---

## Self-Review

**Spec coverage.** §6.1 payer columns, seed and the garden3d validation → Task 1. §5.6 the three-way switch and `management_fee?` → Task 2. §6.4's knock-ons (`status`, `payout_statuses`) and §6.5's "blueprint, `configuration_errors` and the payout pipeline skip" → Task 3. §6.5 one tracker per payer, idempotent, no QuickBooks → Task 4. §6.2 customer by stored id, created only when blank and stored at once; §6.5 the $0.00 line, item by name, month-end date, Net 15, raise rather than no-op → Task 5. §6.5 `make_invoice!` dispatch → Task 6. The garden3d pass's admin action and §10's server-side rules → Tasks 6 and 7. §6.3 and §3.1 fee income, `RowMissing`, no force-refresh, `reconcile` → Task 8. §6.4 the collection gate → Task 9. How the pass comes to exist → Task 10. §6.4's MCP knock-on → Task 11. §12's S1 list: every item has a test, with "`reconcile` raises on variance" met by `reconcile!`.

**Review findings, and where each landed.**

| Finding | Where |
| --- | --- |
| C1 cross-account invoice lookup | Task 0; the gate, `reconcile` and `refresh!` look mirrors up by `(qbo_account_id, qbo_id)`; Decisions 30, 36 |
| C2 gate fails open (unsent with an amount; stale snapshot) | Task 9: the "charged" rule and `collected?`; Task 7: `refresh!` detects a `false` sync; Decisions 12, 13 |
| I1 hand-made invoices for many months | Task 5: `MANAGEMENT_FEE_START`, `draftable?`, the pre-flight; Task 10: `ensure_month!`; Deploy; Decisions 14, 31 |
| I2 customer creation after a lost response | Task 5: same-name refusal and the duplicate-name rescue; Task 12 Step 5; Decisions 20 |
| I3 legacy passes | Task 2: `management_fee_invoice?`, `legacy_forecast_trackers?`; Tasks 3, 6, 7, 11 scoped to them; Decisions 3 |
| I4 sent-then-voided | Task 9; Decisions 15 |
| I5 honest refresh counts | Task 7: `RefreshRun` and the alert |
| I6 strict `reconcile`, explained | Task 8: the `invoices:` breakdown; Decisions 32, 37 |
| Minors | Task 6 (Regenerate rescue and confirm, dropdown, payouts), Task 8 (`MalformedRow`, `WrongAccount`), Task 9 (wrong account raises), Task 1 (migration comment), Decisions 25, 33 |

**Differences from the spec, to carry back into it.** Decisions items 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14 and 15. The two that change the spec's rules rather than correct its facts: §6.4's gate ("every *sent* invoice collected; unsent ignored") becomes "every *charged* invoice collected, where charged is sent or non-zero, and voided is not charged"; and §6.5's unconditional draft becomes "from `MANAGEMENT_FEE_START`, and only when QuickBooks has no invoice for that customer in the month".

**For S4.**

- Payability must go through `Mso::ManagementFeeInvoices.collected?(invoice_pass:)`, once per run or page, never per row. It raises `RefreshFailed` when QuickBooks cannot be read; decide whether that blocks the page or shows "unknown".
- `reconcile` reads stored mirrors. Call `Mso::ManagementFeeInvoices.refresh!` first (a QuickBooks read, outside the run's transaction) and treat a non-empty `failed` as a stop.
- `reconcile!` will raise, and block the run, in any month where a fee line is not on the `Managerial Services` item (Decisions 32) or where account 4100 holds anything else. The `invoices:` breakdown is there to show Finance what to correct.
- `for_month` raises `RowMissing` for a month with no fee activity (December 2025) and returns a partial figure for an unfinished month.
- `reconcile` raises `UnsyncedInvoice` and `WrongAccount`; all are `Mso::ManagementFeeIncome::Error`.
- Spec §9.5 says `MonthlyRun` creates garden3d's pass if absent; `ensure_month!` is that, already written.

**Known limitations, stated rather than solved.**

- A QuickBooks invoice created just before a database failure is not rolled back. `push_invoice!` raises with the invoice's id; a retry finds it through the pre-flight and refuses rather than making a second.
- The pre-flight matches on customer and invoice date. An invoice Finance dated in a neighbouring month is not seen, and a draft would be created beside it.
- The pre-flight query has not been run against QuickBooks (Decisions 34).
- Two admins clicking at the same moment for the same payer: the row lock serialises trackers, and the pre-flight catches the second. For USB Club's first-ever customer, QuickBooks rejects the second create by name and that click reports a configuration error.
- `ensure_trackers!` trusts the unique index for a simultaneous double run; the loser raises `RecordNotUnique`, as `InvoicePass#make_trackers!` would.
- The tracker-to-payer link is derived at push time from a mapping leads can edit (Decisions 33).
- No longer limitations: a lead attaching any mirrored invoice to a tracker they may update by sending the field directly (Decisions 25), and the edit form detaching an invoice on a later save (Decisions 35). Both predated this plan and both are fixed in commit e41cce66.
- The schema guards (`has_attribute?`, `schema_ready?`) have no test: the test database always has the columns. They can be removed once production is migrated.
- Once garden3d's mirror has rows, `Mcp::QboReceivables` will list an unpaid fee invoice as a garden3d receivable. That is accurate, and intercompany.

**Placeholders.** None.

**Type consistency.** `ensure_trackers!` returns `[InvoiceTracker]`; `create_drafts!` iterates it and returns a `DraftRun`. `push_invoice!` returns a `QboInvoice`, which `make_invoice!` returns for a management fee invoice tracker. `refresh!` returns a `RefreshRun`; `collected?` reads its `failed`. `for_month` returns the `BigDecimal` that S3's `Mso::Compensation.call(fee_income:)` takes. `reconcile` returns `{ account_total:, payer_total:, variance:, invoices: }`: the spec §4.1 shape plus the breakdown. `InvoicePass#management_fee_collected?` and `Mso::ManagementFeeInvoices.collected?` both return a Boolean; only the second touches QuickBooks. `Mso::ManagementFeeInvoices::ITEM_NAME` is the one definition of the item name, used by the push and by `reconcile`. `MANAGEMENT_FEE_START` is the one definition of the start month, used by `draftable?` and `ensure_previous_month!`.
