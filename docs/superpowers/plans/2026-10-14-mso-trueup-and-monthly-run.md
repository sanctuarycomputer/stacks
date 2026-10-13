# MSO True-up and Monthly Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each MSO executive a monthly true-up on their garden3d ledger (target minus what they already earned that month across all their ledgers, never negative), produced by one admin click that records every input and output of the calculation so a past month can be reproduced.

**Architecture:** `Mso::MonthlyRun.call(invoice_pass:)` takes garden3d's pass, refreshes and reconciles the month's fee invoices, reads the roster, the benchmark and each executive's qualifying income, calls the pure `Mso::Compensation`, and writes one immutable `MsoSnapshot` plus one `MsoTrueup` per executive who is owed money. A re-run supersedes the snapshot and updates the true-ups in place. A true-up is dated the last day of its fee month. Its first QuickBooks bill is created only by an admin's click, after a live check that the fee was collected and a fresh computation of the month. `MsoTrueup` is a ledger item like `Trueup` and `ProfitShare` and is registered where those are.

**Tech Stack:** Rails 6.1, Ruby 3.1, Postgres, Minitest, Mocha 2.7, ActiveAdmin 2.9, acts_as_paranoid 0.7, quickbooks-ruby 1.0.17.

This is subsystem **S4** of `docs/superpowers/specs/2026-10-09-garden3d-mso-compensation-design.md` (§9, §10, §11, §12, with §13a and §13b governing where they differ). **Revision 2 (2026-10-12):** folds in an adversarial review (three critical findings, eight important, seven minor; none rejected) and three decisions the owner made during it: the first MSO month is August 2026, a true-up and its bill are dated the last day of the fee month, and garden3d's passes are admin-only to view.

S0–S3 are on this branch: `Mso::Compensation`, `Mso::Benchmark`, `MsoRolePeriod`, `Ledger::QualifyingIncome`, `Mso::ManagementFeeInvoices`, `Mso::ManagementFeeIncome`.

## Decisions and open questions

Read this before the tasks. Each item is a decision the owner made, a place where the spec and the code disagree, or a judgement call. Items marked **default — awaiting owner** are built as written and listed again, as yes/no questions, at the end of this section.

### Decided by the owner during the review

- **O1. The first MSO month is August 2026**, and the executives' role periods start **2026-08-01**. `Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START` is now 2026-08-01 (commit `8e0664e2`), and S1's nightly hook creates garden3d's pass for every month from the start through last month. This plan reads the constant and hardcodes no month. What it means in practice:
    - August and September 2026 already have founder true-ups, written and billed the old way: Trueup 203 (26,383.92) and Trueup 204 (29,289.60), both with unpaid bills in Sanctuary's QuickBooks on the dev copy of 2026-10-12. June and July (201, 202) are before the MSO and **stay untouched**. **October has none yet**: the nightly task writes a month only after it ends, so October's would appear on 1 November unless the role periods are entered first.
    - The run refuses a month while a founder true-up stands in it (item 4), so the first months need a one-time ordered procedure, which is in Deploy: enter the role periods; the nightly founder sync then skips August onward; an admin deletes 203 and 204 (which now deletes their bills, and is refused if a bill has been paid); attach the hand-made fee invoices; run each month.
    - What the founder is paid for the month, before and after (contributor 3 at Principal, hypothetical): August 28,692.42 → 29,994.32; September 29,546.10 → 32,064.60. The whole table, with the other executive, is in Deploy.
    - A month is run whenever an admin clicks, however long after it ended (August in mid-October). Nothing in the run assumes "last month": it reads the pass's month, and refuses only a month that has not ended.
- **O2. Accrual dating: the true-up and its bill are dated the last day of the fee month.** The finance lead: "The MSO payouts should also be processed with an 08/31 date. Once those finalize, we'd be able to hard close g3d (and consolidated FS)." This is what the plan already did and it is now pinned: `MsoTrueup#effective_on_for_display`, `#payment_date` and `#bill_txn_date` are all the pass month's last day, whenever the month is run or the bill is created, and Task 1 tests it with a row created months later. So August's true-up counts as August income for qualifying income and elevated service, and its bill carries `txn_date` 08/31.
    - **The bill's due date is the same day.** `SyncsAsQboBill` sets `due_date` to `bill_txn_date` for every ledger item (`app/models/concerns/syncs_as_qbo_bill.rb:145-146`). An August bill created in October is therefore already overdue in QuickBooks on the day it is created. That is how every other Stacks bill behaves; whether Finance wants a different due date for these is question R.
    - **Closed books.** If garden3d's books for the month are closed before the bill is created, QuickBooks rejects a bill dated in the closed period. The sync turns that into a named refusal ("garden3d's books are closed for 08/31 …: reopen the period, or create the bill before closing") and writes nothing (Task 8). Deploy says the order plainly: **sync the bills, then hard-close**. The error is recognised by its text, which has not been seen from QuickBooks.
- **O3. garden3d's invoice passes and their trackers are becoming admin-only to view** (an S1 change in progress). So the run button, the link to the snapshot and Check collection sit on pages only an admin can open. The plan no longer tests what a lead sees on the pass, and keeps an explicit admin-only guard on every new action all the same: authorization in `AdminAuthorization` and a check in each action.

### The owner's decisions, and how the plan builds them in

1. **The cap is a ceiling, not a budget.** `Mso::Compensation` already works this way (`app/services/mso/compensation.rb:90-102`). The run passes it one line per executive and never redistributes. One consequence the run depends on: because nothing is redistributed, one executive's true-up never depends on another executive's earnings, only on the roster, the benchmark and the fee.
2. **True-ups are not benchmark income.** `Mso::Benchmark::KLASSES` is `Ledger::QualifyingIncome::KLASSES - [Trueup]` (`app/services/mso/benchmark.rb:19`). The moment `MsoTrueup` joins `QualifyingIncome::SOURCES` it would enter the benchmark unless that line also subtracts it. Task 2 changes it to `- [Trueup, MsoTrueup]` and pins it with a test.
3. **"Already earned" excludes the month's own MSO true-up.** The run passes every live `MsoTrueup` on garden3d's pass as `excluding:` (`app/models/ledger/qualifying_income.rb:38,43,54`). Tests: re-running an unchanged month leaves the amount alone; and month M's true-up does not reduce month M+1's.
4. **The founder true-up is replaced, from the first month the founder holds an MSO role — and the two can never both stand for one month.** (Rewritten after review; the earlier "leave an existing row frozen and net against it" was wrong twice.)
    - *What exists today.* `Stacks::System.sync_founder_trueups!` (`lib/stacks/system.rb:77-111`) runs every night and rewrites the founder true-up for every completed month since 2025-06 on Sanctuary's ledger. The nightly bill sync then writes a QuickBooks bill for it, accepted or not (`lib/tasks/stacks.rake:546`); `Trueup#payable?` is hard-coded `true` (`app/models/trueup.rb:19-21`); and `Trueup` has no `before_destroy`, so deleting the row leaves the bill open in Sanctuary's QuickBooks. All 16 existing founder true-ups have bills.
    - *Why netting against a leftover row was wrong.* (a) If an admin deleted the row to tidy up, the bill stayed payable and the MSO true-up then became the full amount as well: a double payment. (b) Even left alone it was not neutral when the cap binds: the founder true-up is uncapped Sanctuary money, so the founder would end the month above their capped figure.
    - *What is built (Task 9).* (i) `Trueup` gains `before_destroy :detach_and_destroy_qbo_bill`, as `ProfitShare` has (`app/models/profit_share.rb:8`): deleting a founder true-up now deletes its bill, and is refused if the bill has any payment. The only code path that destroys a `Trueup` is its admin page's Delete (`app/admin/trueups.rb:4`); it gains a rescue so the refusal is a message, not an error page. (ii) **`Mso::MonthlyRun` refuses** when a live `Trueup` exists in the run month for anyone on the roster, names its id and ledger, and says to delete it first. (iii) The nightly founder sync skips a month when the founder has an active role period **or** any `MsoSnapshot` line or `MsoTrueup` (soft-deleted included) exists for them in that month. (iv) A role period that a run has used cannot be destroyed, and its tier, start or end cannot be edited so as to change a month that has a snapshot (item 5).
    - *History.* Months before the founder's first MSO month are untouched and keep being recomputed nightly.
    - *If the role is entered late* (after the nightly task has written and billed that month's founder true-up): the run refuses until an admin deletes that true-up, which removes its Sanctuary bill. If that bill has already been **paid**, deletion is refused and the month cannot also be paid through the MSO; the options are to void the payment in QuickBooks, or start the role period the following month.
    - With the first MSO month now August 2026 (O1), this is not a corner case: August and September are in exactly this state, with unpaid bills. Deploy gives the order. October avoids it if the role periods are entered before 1 November 2026.
    - **Default — awaiting owner** (question A).
5. **Founder true-ups cannot come back unattended** (review C2). The roster page allows edit and destroy (`app/admin/mso_role_periods.rb:5`). Deleting and recreating a period, moving its start later, backdating its end, or reverting this branch would each have let the nightly sync recreate founder true-ups for months already paid through the MSO and bill them the same night. Two defences, both in Task 9: the skip in 4(iii) looks at what was *run*, not only at the roster; and `MsoRolePeriod` refuses, with a message on the admin form, to be destroyed once any snapshot line names it, or to have its tier, contributor, start or end changed in a way that alters a month that has a snapshot. Ending a period going forward (an end date on or after the last month run) stays possible; a promotion is "end this period, start a new one". The one cost: a period entered for the wrong person and then run can only be undone from the console.
6. **MSO true-ups count toward elevated service.** Three places compute it and all three are changed in Task 3: `Contributor#all_items_grouped_by_month` (`app/models/contributor.rb:538-545`), `Contributor.elevated_service_admin_user_ids` (`:615-624`) and `PeriodicReport#profit_share_elevated_service_by_month` (`app/models/periodic_report.rb:212`).
7. **No waiver, no per-person reduction limit, netting across all ledgers.** `Mso::MonthlyRun.already_earned` sums `Ledger::QualifyingIncome` over every ledger the contributor has.
8. **One line per person.** The run refuses, naming the role period ids, if any `contributor_id` appears twice in the month. The calculator is keyed by `contributor_id` and raises on a duplicate key (`app/services/mso/compensation.rb:40-41`).
9. **Nothing pays anyone or writes to QuickBooks unattended.**
    - **Nothing computes on a schedule.** `Mso::MonthlyRun.call` is reached only from an admin's click on garden3d's pass.
    - **⚠ Existing ledger items ARE pushed to QuickBooks unattended, and `MsoTrueup` is deliberately kept out of that.** `stacks:sync_contributor_qbo_bills` runs nightly and calls `sync_qbo_bill!` on every payout, adjustment, profit share, accepted reimbursement, accepted pay stub, and every `Trueup` (`lib/tasks/stacks.rake:539-547`). `sync_qbo_bill!` has no payable guard (`app/models/concerns/syncs_as_qbo_bill.rb:128-177`). `MsoTrueup` is not added to that task or to `Contributor#sync_qbo_bills!` (`app/models/contributor.rb:274-288`), and its own `sync_qbo_bill!` refuses unless every condition in item 22 holds.
    - **The only path that writes an MSO bill** is an admin on the Money page: "Sync to QBO" on one row (`app/admin/money.rb:70-102`) or "Sync all to QBO" (`:108-124`).
    - **Two things are added to the nightly garden3d step** (`Enterprise#daily_tasks`, `app/models/enterprise.rb:84-90`), neither of which can write to QuickBooks or pay anyone: a **database-only** comparison of the stored 4100 figure with each live snapshot's fee income, which invalidates a snapshot whose fee has moved (item 21); and a **read-only** refresh of the mirrors of MSO bills that already exist, so a paid bill is seen as paid (item 23). The refresh calls `fetch_bill_by_id` and nothing else; a test stubs QuickBooks' create, update and delete to fail if touched.
10. **GL account: `:mso_compensation`, not fallbackable, garden3d mapped to `"____"`.** Task 4. Routing raises until Finance creates the account. End-to-end QuickBooks verification is out of scope until then. A raise is contained per row in every batch path: the single-row sync rescues and shows the message (`app/admin/money.rb:97-99`); "Sync all" rescues per row (`app/services/money/refresh_payable_qbo_bills.rb:19-24`); the nightly bill sync never reaches an `MsoTrueup`. No other batch calls the router. Neither expected executive (contributors 3 and 120) has a garden3d QuickBooks vendor today.

### Where the spec is wrong about the code

11. **`Mso::MonthlyRun` does not create garden3d's pass.** Spec §9.5 and §11 say it does. Its signature takes the pass; `Mso::ManagementFeeInvoices.ensure_previous_month!` creates it nightly, for last month and for any earlier month since the start that has none (`app/services/mso/management_fee_invoices.rb:282`, `app/models/enterprise.rb:89`), and `ensure_month!` on demand (`:251`).
12. **The benchmark average is a string column, not `decimal(12,2)`.** Spec §9.1 versus §13a. September 2026's average is `27882.263333333333333333333333333`. `benchmark_average` and `total_calculated` are strings holding `to_s("F")`; `cap` is `decimal(16,6)`. Amounts inside jsonb are strings.
13. **`lines` is an array, not a hash keyed by `mso_role_period_id`.** The calculator is keyed by `contributor_id`. The snapshot also has columns the spec does not list: `small_sample`, `total_trueup`, `total_trueup_as_billed`, `benchmark_members`, `excluded_without_login`, `reconciliation`, `drift`, `sanctuary_invoice_pass_id`, `created_by_id`, `fee_collected_at`, `invalidated_at`, `invalidated_reason`.
14. **`payable?` does not call `invoice_pass.management_fee_collected?`.** Spec §9.4. See item 21.
15. **A true-up of $0.00 gets no row.** Spec §9.5 says one per active role period. A zero row would need its executive to accept $0.00 before anyone else could be paid, and would sit on the Money page forever as "No QBO bill" (`app/models/concerns/syncs_as_qbo_bill.rb:142`, `app/services/money/payable_qbo_bills.rb:5-6`). A row exists only when the true-up is at least one cent. **Default — awaiting owner** (question H).
16. **A true-up is rounded DOWN to the cent** (review I1). Not in the spec. `Mso::Compensation` returns `final − earned` unrounded, and earned income is not always whole cents: profit shares are stored unrounded (`db/schema.rb`, `profit_shares.amount` has no scale; the review cites `179.8089646737429`). The column is `decimal(12,2)`, so an unrounded figure was rounded on save and then compared unequal on the next run, clearing the acceptance every time. Every use of a true-up amount now goes through one method that floors to cents: the "is anything owed" test, the row, the snapshot line, the totals and the drift comparison. The unrounded figure is kept on the line as `trueup_before_rounding`. **Default — awaiting owner** (question D).
17. **Spec §9.7's eleven registration points, checked against the code.** All eleven are real. Corrections and additions:
    - #2 is `app/models/qbo_account.rb:239-244`; #3's `case` is `:254-275`; #9 is `periodic_report.rb:212`, not `:206`, and there are two more elevated-service computations.
    - The sort comparator in `Contributor#all_items_grouped_by_month` (`app/models/contributor.rb:492-528`) is not in the spec's list and would crash on an unlisted class.
    - `Money::PayableQboBills::HOST_KLASSES` is also read by `app/admin/money.rb:74` and `app/models/qbo_account.rb:301`; two task discoveries enumerate ledger-item tables; `StacksTask::HUMANIZED_TYPES` needs a label (`app/models/stacks_task.rb:56-60`).
    - **Deliberately not registered:** the nightly bill sync and `Contributor#sync_qbo_bills!` (item 9); `AdminAuthorization::OWN_LEDGER_ITEM_CLASSES` (item 27); and **`Contributor.aggregated_new_deal_balance`**, which spec #8 names (item 29).
18. **Spec §10's combined guard includes `MsoRolePeriod`; that guard already exists** (`app/models/admin_authorization.rb:84-86`). No `scope_collection` branch is added: a lead fails `authorized?` before an index is built.
19. **The baseline must be measured.** The brief gave 2114 runs; main has been merged in twice since. The reviewer measured **2387 runs, 0 failures, 2 skips** at `06623f0a`, and another worker is landing fixes on this branch (HEAD was `8e0664e2` when this revision was finished, after a third merge of main), so it will be a little higher. Every task states its runs as a delta: **146 new runs** in all. `db/schema.rb` is still at `2026_10_13_000001`; this plan's migration is `20261014000001`.

### What the earlier subsystems learned, and the policy for each

20. **An unfinished month is refused; a month with no 4100 row is refused.** `for_month` returns a partial figure for the current month and raises `RowMissing` when no fee was booked. Treating a missing row as a $0 cap would silently pay nobody if the account were renumbered (spec §3.1). **Default — awaiting owner** (question I).
21. **Collection is a stamp, the stamp can be withdrawn four ways, and it is re-checked live before any bill** (rewritten after review I2).
    - `MsoTrueup#payable?` is called per row on every ledger page and Money page render, so it reads stored data only: accepted, snapshot current, snapshot not invalidated, `fee_collected_at` set, every expected true-up accepted.
    - `fee_collected_at` is set only from `Mso::ManagementFeeInvoices.collected?`, which refreshes every attached invoice from QuickBooks and raises if any read fails (`app/services/mso/management_fee_invoices.rb:229-239`). It is called once by the run and once per **Check collection** click.
    - **S1 tightened that gate while this plan was in review** (commit `19bc992e`): it now also answers "not collected" when any current payer has no fee tracker on the pass, when an attached invoice is dated outside the pass month, and when garden3d's mirror holds an unattached invoice to a payer dated in the month (`app/models/invoice_pass.rb:63-87,99-150`). This plan calls the gate and never reimplements it, so it inherits all of that; the run's instructions and the Deploy steps say so.
    - *The stamp is cleared* when: an admin clicks **Refresh from QuickBooks** on the pass; a fee tracker's invoice is attached or detached; or Check collection answers no.
    - *The snapshot is invalidated* (a stronger state: nothing from it is payable, Check collection refuses, and only a successful run, which writes a new snapshot, clears it) when: a run of the month is refused; a run fails with any other error; the nightly database-only check finds that account 4100 no longer reads what the snapshot used; an admin removes a true-up's QuickBooks bill; or the nightly read-only refresh finds a bill has been deleted in QuickBooks.
    - *Before a bill is first created* the collection check runs live again (one QuickBooks read per fee invoice, inside the admin's Sync click). No nightly QuickBooks call is added for collection.
    - **Default — awaiting owner** (questions C and G).
22. **A true-up's first QuickBooks bill is created only if the figure is still right** (review C3). Sanctuary's payouts keep moving for weeks after a pass completes, and creating the bill is what locks the amount. On first bill creation `MsoTrueup#sync_qbo_bill!` (Task 8), in order: refuses unless `payable?`; refuses with a named error if the executive has no garden3d vendor, or if the MSO compensation account does not resolve; re-checks collection live; then calls `Mso::MonthlyRun.preview`, which computes the month from the database without writing, and refuses with "figures changed since the run — run the month again" if this row's amount would differ. Then it takes the row lock, so a double click cannot create two bills, and writes. Cost: one benchmark computation (969 queries for September 2026) per first sync; it is one click per executive per month. **Default — awaiting owner** (question B).
23. **A true-up with a QuickBooks bill is locked, and counts as payable** (review I3).
    - *Locked:* a run never changes its amount or deletes it, and it cannot be un-accepted. If the recomputed figure differs the run completes and records the difference in the snapshot's `drift`. This is stricter than the spec's "has payments" and needs no QuickBooks call in the run.
    - *Counts as payable:* once a bill exists the money is in garden3d's accounts payable whatever happens to the snapshot later. Without this a billed row whose snapshot was invalidated would move to "unsettled" and never leave, because only payable rows are refreshed from the Money page. `payable?` returns true for a row with a bill; the not-payable guard applies only while there is no bill.
    - *Its mirror is refreshed nightly, read-only* (item 9), so a paid bill drops out of the balance. That is how the existing nightly sync refreshes the other classes' mirrors too, except theirs does it by re-writing the bill (`app/models/concerns/syncs_as_qbo_bill.rb:144-174`); the MSO refresh only reads.
    - *To change a locked amount* an admin clicks **Remove QuickBooks bill** on the true-up's page. It re-reads the bill and refuses if it has any payment (`app/models/concerns/syncs_as_qbo_bill.rb:33-77`); on success it also clears the row's acceptance and invalidates the snapshot, so the row cannot be re-synced at the old amount without a re-run (review I6).
    - *Over the cap:* if the fee falls after a bill was written, billed rows plus recomputed rows can total more than the cap. The snapshot stores `total_trueup_as_billed` and its page shows a prominent warning when that exceeds the cap.
    - **Default — awaiting owner** (question K).
24. **A reconcile variance refuses the run; there is no override** (review I7). The refusal lists each invoice compared with its total and its Managerial Services figure, and four numbered remedies: attach a missing invoice; move a fee line to the `Managerial Services` item; move non-fee income out of account 4100 and wait for the nightly sync; correct an invoice dated in another month. An admin override that would cap on the lower of the two totals, recorded on the snapshot, is **not built** (question J).
25. **`MANAGEMENT_FEE_START` bounds the run** (`app/services/mso/management_fee_invoices.rb:39`; 2026-08-01 by the owner's decision O1, landed in commit `8e0664e2` while this revision was being written). The run refuses any earlier month and the button is not shown for it. No test or line of code here names the date.
26. **The benchmark is live and expensive; the snapshot is the record.** 969 queries for September 2026. Called once per run and once per first bill sync.

### Authorization and privacy

27. **Who can see what, and who can accept.**
    - `MsoSnapshot`: admins only, every action, above the blanket lead grant (`app/models/admin_authorization.rb:107`).
    - `MsoTrueup` page: admins, and the executive whose ledger it is on. `MsoTrueup` is not in `OWN_LEDGER_ITEM_CLASSES`, which grants `:index`, `:new` and `:create` to anyone with a contributor record (`:150`).
    - **Only the owner of a true-up can accept it — not any admin** (review I4). Both expected executives are admins, so "an admin may accept" would have let each accept on the other's behalf. Enforced in `AdminAuthorization` and again in the action, and tested by URL as another admin. Accept also carries the amount the person saw and is refused if the row no longer shows that amount.
    - **Unchanged, and a question for the owner:** an admin can still *see* every true-up and the snapshot. The two executives are admins, so each can see the other's figures (question F). An executive with no Stacks login cannot accept at all; an admin would have to give them one.
    - Running the month, Check collection and Remove QuickBooks bill: admins only, each with its own guard, even though the pass page they start from is itself becoming admin-only (O3).
28. **The contributor ledger page would have leaked it; the spec does not cover this.** Any lead can open any contributor's page. Task 11 adds an `include_mso_trueups:` switch to the ledger's balance, unsettled total and month walk, and the page passes `false` unless the viewer is an admin or the contributor themself.
29. **Company-wide totals and reports** (review I4).
    - `Contributor.aggregated_new_deal_balance` is on the dashboard every logged-in user can open (`app/admin/dashboard.rb:108`) and in `Mcp::GetExecutiveDashboardTool` (`app/services/mcp/get_executive_dashboard_tool.rb:130`). With two executives it would jump by the month's total true-up on run day. **MSO true-ups are left out of that aggregate entirely**, for everyone: simpler than a per-viewer figure, and the dashboard result is cached. Spec §9.7 #8 said to add them. **Default — awaiting owner** (question E).
    - `Stacks::FinancialOutlook` lists spend by P&L account and hides only accounts matching `Stacks::PeopleCostAccounts::PATTERNS` (`lib/stacks/financial_outlook.rb:195`, `lib/stacks/people_cost_accounts.rb:5-15`). A garden3d account named "MSO Compensation" or "Executive Compensation" matches none of them, and `get_financial_outlook` would report total executive pay as a spend category. Task 5 adds `/compensation/i`, `/\bmso\b/i` and `/executive/i`. Checked read-only against every stored P&L on the dev copy: **the three patterns newly hide no existing account on any enterprise** (0 of all spend rows; "Officer Compensation" was already hidden by `/officer/`).
    - `Mcp::ListPayableBillsTool` leaves MSO bills out for everyone (Task 5).
    - garden3d's P&L totals (total expenses, net income) will include the compensation once bills exist. That is the P&L being correct.
30. **The amounts are partly derivable anyway.** Hiding the rows does not make executive pay secret from a determined lead: any lead can read every Sanctuary ledger and so compute the top-N average; the tier multipliers are in the code (`app/models/mso_role_period.rb:7-12`); the cap percentage is in the code; so 55% of the fee is the one input a lead cannot read once garden3d's passes are admin-only (O3), and it only matters in a month the cap binds. What a lead cannot derive without the roster is who holds which tier. The privacy work here keeps the figures off pages people land on by accident; it is not a wall.
31. **The nag reveals who is on the roster, not what they are paid.** Task 12's task is owned by the executive and lists no amount, but anyone who can see all tasks (the Tasks dashboard, `Mcp::ListOpenAdminTasksTool`) sees that the person has an MSO true-up to accept (question L).

### Smaller calls

32. **Acceptance and re-runs.** A re-run that changes an accepted amount clears the acceptance; one that leaves it the same keeps it. The run writes the new amount and the cleared acceptance in one statement while holding the row's lock, which Accept and Sync also take.
33. **Safe between merge and migrate.** `MsoTrueup.schema_ready?` guards every registration point. It remembers "yes" for the life of the process and, while the answer is "no", asks the database at most once a minute, so a ledger page before the migration costs no extra query per balance and no dyno restart is needed afterwards. `sync_founder_trueups!` also guards `mso_role_periods`.
34. **The run is three steps, and only the last is transactional.** Refuse early; refresh and reconcile (QuickBooks reads, outside the transaction); then lock garden3d's pass row and compute and write in one transaction. Two runs of one month are serialised by that lock; the partial unique index on current snapshots is the backstop.
35. **The snapshot's figures are immutable.** Only the stamps change after creation, and the nightly check's `income_drift` note (item 43).
36. **A soft-deleted true-up is restored, not re-inserted**, keeping its id; its acceptance is cleared.
37. **A superseded snapshot's page is drawn from its own stored lines**, not from today's rows, which now belong to a later run.
38. **Sync failures say what to do** (review I5). A missing vendor used to make `sync_qbo_bill!` return `nil`, which "Sync all" reported as success; a router raise showed only a class name. Both are now named errors with an instruction, and the Money page's "Sync all" alert shows each failure's message.
39. **A line's `reduction` is not exactly zero under the cap**: the calculator reports `calculated − final` and `final` is rounded (`app/services/mso/compensation.rb:65,97`). Stored as computed, shown rounded.
40. **Not built:** a nightly run; a reconciliation override; an early-release hatch (spec §14); the `btree_gist` exclusion constraint; an edit form for a true-up or a snapshot.

### Changed by the final review (after the tasks below were built)

Where a task below says otherwise, these stand.

41. **A true-up that has had a bill never gets a second one from a sync.** Task 8 skipped the first-bill checks for a row that already had a bill, and the shared sync then created a new bill, at the old amount, when QuickBooks no longer had the old one or could not be read. Now a billed true-up's bill is read first. If it is gone, the row is unlocked exactly as the nightly refresh unlocks it (bill id and acceptance cleared, snapshot invalidated) and the sync raises `MsoTrueup::BillGone`: the month has to be run again. `MsoTrueup#load_qbo_bill!` is overridden so that, inside a sync, a bill is created only by the call that passed the first-bill checks; a bill that cannot be read at the write raises `BillUnreadable` and nothing is written.
42. **Only an admin can delete a founder true-up** (`Trueup`). Deleting one deletes its QuickBooks bill in that company's books, and for an MSO month the nightly sync will not write it again. `AdminAuthorization` refuses `:destroy` to everyone else, above the blanket lead grant, and ActiveAdmin hides the Delete control with it. Testing the refusal with a real `Quickbooks::Model::Bill` also showed that `SyncsAsQboBill#detach_and_destroy_qbo_bill` never used the bill it had just read (it asked for `total_amt`; the gem calls it `total`) and decided on the stored copy instead. It now reads either. This applies to every ledger item, not only these.
43. **Income that lands after the run is noticed, in two ways.** Netting is across all of a person's ledgers, but the run waits only for Sanctuary's pass.
    - *At the run, a warning and never a refusal:* the snapshot's `run_warnings` lists every other company's pass for the month that is not complete, and every unaccepted payout to someone on the roster (ids and counts). August is run in October on purpose; waiting would let one person freeze everyone's pay.
    - *Nightly, database only:* `Mso::MonthlyRun.record_income_drift!` recomputes each current, valid snapshot whose month is within the last **six** months (`DRIFT_WINDOW_MONTHS`) with `.preview`, and writes on the snapshot, with the time, each executive whose true-up would now be a different amount (stored and now), including someone who has joined or left the month's roster. If such a true-up has **no** QuickBooks bill, the snapshot is invalidated, as the fee check invalidates it; if it **has** a bill, the drift is recorded only and a person decides. A month that can no longer be computed at all (a refused preview) is recorded and not invalidated: the fee check and the first-bill check already deal with what stops it. It makes no QuickBooks call (a month with no stored P&L is skipped rather than fetched), writes no true-up and no bill, and nothing raises out of the job. There is no cheap sound test for "nothing can have changed" (a deleted payout leaves no timestamp), so every snapshot in the window is recomputed, about a thousand queries each; the window is the bound.
    - Both are on the snapshot page, the drift above the figures. Two new columns, in a second migration (`20261014000002`); everything is guarded until it has been run.
44. **`get_enterprise_health`'s `raw_rows` leaves out people-cost accounts.** It returned every P&L row by account label, so it would have reported total executive pay once MSO bills post to their own account. Rows now go through `Stacks::PeopleCostAccounts.rows_without_people_costs`: the account's own row, everything under a people-cost header, and their Total rows, everywhere except the income sections. This also hides the payroll, benefit, contractor, payout and intercompany rows `raw_rows` showed until now, which is how the financial outlook already treats them. Section totals stay (the snapshot datapoints report the same figures), so for a company whose costs are mostly people, the hidden amount is still roughly "total expenses less the rows shown".
45. **Smaller ones.** garden3d's nightly steps each run on their own and report a failure to the log and Sentry. The nightly bill refresh still reads a settled bill while its month is within six months (a payment voided later is seen). An MSO role period cannot start before `MANAGEMENT_FEE_START`. With the MSO tables absent, the run is not offered and a posted one is refused in words. Nobody is asked to accept a true-up on an invalidated snapshot. Orphan cleanup never deletes an MSO bill that has a payment.

### Questions for the owner

**Nothing blocks the build.** Every question has a default, and the default is what the tasks build. A–G are the coordinator's chosen defaults for the reviewer's questions; H–L are this plan's own. Each can be answered yes or no.

*Worth answering before the branch merges, because they change who is paid what, when, or by which company:*

- **A. If a month already has an old-style founder true-up, should the MSO run for that month refuse until someone deletes it?** Built: yes. (Deleting it now also removes its QuickBooks bill. If that bill was already paid, the month stays paid the old way.)
- **B. When an admin sends a true-up to QuickBooks for the first time, should Stacks re-do the sums and refuse if the figure has changed since the run?** Built: yes.
- **C. At that same moment, should Stacks re-check with QuickBooks that the management fee has really been paid?** Built: yes.
- **D. Should a true-up be rounded down to the cent** (so $2,518.507 pays $2,518.50, and anything under one cent pays nothing)? Built: yes.
- **E. Should the company-wide "balance owed" figure on the dashboard leave MSO true-ups out,** so that nobody can read the executives' total from it? Built: yes, for everyone.
- **F. Is it acceptable that every admin, the two executives included, can see every executive's true-up and the full calculation?** Built: yes, unchanged. (Only the person a true-up belongs to can *accept* it.)
- **G. Is it acceptable that "the fee has been collected" is something an admin confirms by clicking, rather than something Stacks re-checks every time a page loads?** Built: yes, with the automatic withdrawals listed in item 21.
- **H. If an executive is owed nothing for a month, is it right that they get no line to accept?** Built: yes.
- **I. If garden3d's books show no management fee income at all for a month, should the run refuse** (rather than treat the cap as $0 and pay nobody without saying so)? Built: yes.

*Can be answered later:*

- **J. When QuickBooks' fee income and the fee invoices disagree, should an admin be able to override and run the month on the lower figure?** Built: no; the run refuses and says how to fix the books.
- **K. Once a true-up has a QuickBooks bill, should it be frozen even if that bill has not been paid yet?** Built: yes; an admin can remove an unpaid bill to unfreeze it.
- **L. Is it acceptable that the task list shows which people have an MSO true-up waiting to be accepted** (never the amount)? Built: yes.
- **M. Should leads stop seeing the existing founder true-up and profit shares on other people's ledger pages?** Built: no change.
- **N. Should the calculation also run by itself each night** (in the database only, paying nobody), so the figures are waiting for the admin? Built: no.
- **P. Finance:** the garden3d MSO compensation account number, and a garden3d QuickBooks vendor for each executive. Needed before the first payment, not before the first run.
- **Q. If the benchmark ever leaves someone out for having no Stacks login, should that stop the run?** Built: no; the snapshot shows who was left out.
- **R. Is it right that an MSO bill's due date is the same as its date** (so August's bill, dated 08/31, is due 08/31)? Built: yes, as for every other Stacks bill. Say no if Finance wants a different due date.
- **S. If a founder true-up for August or September turns out to have been paid already, should that month stay paid the old way** (and the MSO start a month later for the founder)? Built: the delete is refused and a person decides; nothing is automatic.

## Global Constraints

- **No test may reach the network.** Every QuickBooks call is stubbed with Mocha. `Mso::ManagementFeeInvoices.collected?` is stubbed in every `Mso::MonthlyRun` test; `QboInvoice#sync!` and `QboProfitAndLossReport.find_or_fetch_for_range` are stubbed to raise.
- `Enterprise.sanctuary` / `.garden3d` memoize in `Thread.current`. Every test class here calls `clear_enterprise_memos` in `teardown`.
- `has_many` caches go stale. Read a pass's true-ups and snapshots with a fresh query.
- The sanctuary fixture has two `QboAccount`s and `has_one` is unordered. Pin Sanctuary's with `Enterprise.find(enterprises(:sanctuary).id).qbo_account`.
- Money in new code is `BigDecimal`, built from strings, and never passes through `to_f`. (`Ledger#balance` and `#unsettled` are existing Float-returning methods; tests compare their `.to_f`.) Amounts inside jsonb are Strings written with `to_s("F")`.
- `db/schema.rb` is **hand-edited**. Never run `bin/rails db:migrate` (it re-dumps the file and reintroduces `enable_extension "vector"`). `check_pending!` aborts every test run if a migration is newer than the schema's version line, so Task 1 bumps it to `2026_10_14_000001`.
- Tests use months far in the future (2090s) so they never collide with fixtures, and pass `today:` to the run. Those months are after `MANAGEMENT_FEE_START`, so they are runnable.
- Run tests with `--exclude "sync_meet runs the connector inside a SystemTask"`. Never run two test processes at once.
- **Measure the baseline before Task 1** with a full run, and write it down. The reviewer measured 2387 runs, 0 failures, 2 skips at `06623f0a`; another worker has been committing to this branch since, so expect a little more. Each task states how many runs it adds and the running total as "baseline + N". After Task 12: **baseline + 146**.
- Commit after every task.
- Never add `MsoTrueup` to `lib/tasks/stacks.rake` or to `Contributor#sync_qbo_bills!`.
- A true-up amount is always `Planned#amount` (the calculator's figure rounded **down** to the cent). Never use `output.trueup` directly for anything that is stored, compared or paid.
- No test names a month for `MANAGEMENT_FEE_START` (2026-08-01 since `8e0664e2`). Read the constant.

## File Structure

| File | Responsibility |
| --- | --- |
| `db/migrate/20261014000001_create_mso_snapshots_and_trueups.rb` | The two tables |
| `db/schema.rb` | Hand-edited: version line, two tables, seven foreign keys |
| `app/models/mso_snapshot.rb` | The immutable record of one run; `current`, expected true-ups, the collection stamp, invalidation |
| `app/models/mso_trueup.rb` | The ledger item; `payable?`, owner acceptance, dating, the bill guard, remove-bill, the read-only mirror refresh |
| `app/services/mso/monthly_run.rb` | `call` (compute and write), `preview` (compute only), the nightly database-only fee check |
| `app/models/invoice_pass.rb` | `has_many :mso_snapshots` |
| `app/models/invoice_tracker.rb` | Attaching or detaching a fee invoice withdraws the collection stamp |
| `app/models/ledger.rb` | `has_many :mso_trueups`; item lists; `include_mso_trueups:` |
| `app/models/ledger/qualifying_income.rb` | `MsoTrueup` is qualifying income |
| `app/services/mso/benchmark.rb` | …but never benchmark income |
| `app/models/contributor.rb` | Readers, ledger walk, elevated service, visibility predicate |
| `app/models/periodic_report.rb` | Profit-share elevated service counts it |
| `app/services/qbo/bill_router.rb` | `:mso_compensation` |
| `app/models/concerns/syncs_as_qbo_bill.rb` | Doc-code registry comment |
| `app/models/qbo_account.rb` | Detach list, `"MT"` arm, guarded host list |
| `app/services/money/payable_qbo_bills.rb`, `qbo_bill_summary.rb` | Host class, guarded reader, preloads |
| `app/admin/money.rb`, `app/views/admin/money/payable_qbo_bills.html.erb` | Allow-list reader; failure messages; row link |
| `app/services/mcp/list_payable_bills_tool.rb` | Leave MSO bills out |
| `lib/stacks/people_cost_accounts.rb` | The financial outlook hides compensation, MSO and executive accounts |
| `app/models/admin_authorization.rb` | Admin-only snapshot; owner-only acceptance; admin-only run |
| `app/models/enterprise.rb` | garden3d's nightly step: database-only fee check, read-only bill refresh |
| `app/models/trueup.rb`, `app/admin/trueups.rb` | Deleting a founder true-up deletes its bill |
| `lib/stacks/system.rb` | Founder true-up skips every month paid through the MSO |
| `app/models/mso_role_period.rb`, `app/admin/mso_role_periods.rb` | A role period a run has used cannot be destroyed or changed for those months |
| `app/admin/mso_trueups.rb`, `app/views/admin/mso_trueups/_show.html.erb` | The true-up page, Accept, Remove QuickBooks bill |
| `app/admin/mso_snapshots.rb` | The snapshot pages and Check collection |
| `app/admin/invoice_passes.rb`, `app/views/admin/invoice_passes/_management_fee_pass.html.erb` | Run MSO compensation; link to the snapshot; Refresh withdraws the stamp |
| `app/admin/contributors.rb`, `app/views/admin/contributors/_show.html.erb`, `_ledger_tabs.html.erb`, `app/views/admin/admin_users/_show.html.erb` | Ledger rows; hidden from other viewers |
| `lib/stacks/task_builder/discoveries/unaccepted_mso_trueups.rb`, `lib/stacks/task_builder.rb`, `app/models/stacks_task.rb`, two existing discoveries | The nag |
| `test/support/mso_fixtures.rb` | Builders shared by the tests |

`lib/tasks/stacks.rake` is not modified.

---

### Task 1: The two tables and their models

**Files:**
- Create: `db/migrate/20261014000001_create_mso_snapshots_and_trueups.rb`
- Modify: `db/schema.rb`
- Create: `app/models/mso_snapshot.rb`, `app/models/mso_trueup.rb`
- Modify: `app/models/invoice_pass.rb`
- Create: `test/support/mso_fixtures.rb`, `test/models/mso_trueup_test.rb`, `test/models/mso_snapshot_test.rb`

**Interfaces:**
- Consumes: `Mso::ManagementFeeInvoices.collected?(invoice_pass:)`, `LedgerItem`, `SyncsAsQboBill`
- Produces:
  - `MsoSnapshot.current`, `.unconfirm_collection!(invoice_pass_id)`, `#current?`, `#invalidated?`, `#invalidate!(reason)`, `#fee_collected?`, `#over_cap?`, `#expected_ledger_ids`, `#all_expected_trueups_accepted?`, `#check_collection! -> Boolean` (raises `MsoSnapshot::Unusable` when superseded or invalidated)
  - `MsoTrueup.schema_ready?`, `#payment_date`, `#effective_on_for_display`, `#bill_txn_date` (all the last day of the pass month), `#accepted?`, `#locked?`, `#toggle_acceptance!(expected_amount: nil)`, `#payable?` (true once billed), `#sync_qbo_bill!` (raises `MsoTrueup::NotPayable` unless payable; Task 8 adds the rest), `#bill_description`, `#bill_doc_number_code == "MT"`
  - The error classes `MsoTrueup::SyncRefused` and its subclasses, `MsoTrueup::Locked`, `MsoTrueup::AmountChanged`
  - `InvoicePass has_many :mso_snapshots`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20261014000001_create_mso_snapshots_and_trueups.rb`:

```ruby
class CreateMsoSnapshotsAndTrueups < ActiveRecord::Migration[6.1]
  def change
    # One row per run of a month's MSO compensation. Everything the run read
    # and everything it produced, so a past month can be reproduced after the
    # roster, the payouts or the Top-N setting have changed.
    create_table :mso_snapshots do |t|
      t.bigint :invoice_pass_id, null: false            # garden3d's pass
      t.bigint :sanctuary_invoice_pass_id, null: false  # the pass whose payouts were read
      t.bigint :created_by_id                           # the admin who ran it
      t.decimal :fee_income, null: false, precision: 12, scale: 2
      # Unrounded, as a string: the benchmark average is a division and a
      # two-decimal column would make a later recomputation differ by a cent.
      t.string :benchmark_average, null: false
      t.integer :configured_n, null: false
      t.integer :counted, null: false
      t.boolean :small_sample, null: false, default: false
      t.decimal :cap_percentage, null: false, precision: 5, scale: 4
      t.decimal :cap, null: false, precision: 16, scale: 6
      t.string :total_calculated, null: false
      t.decimal :total_trueup, null: false, precision: 12, scale: 2
      # The same total, but counting a true-up that already has a QuickBooks
      # bill at its billed amount. More than `cap` means the fee fell after a
      # bill was written.
      t.decimal :total_trueup_as_billed, null: false, precision: 12, scale: 2
      t.jsonb :benchmark_members, null: false, default: []
      t.jsonb :excluded_without_login, null: false, default: []
      t.jsonb :lines, null: false, default: []
      t.jsonb :drift, null: false, default: []
      t.jsonb :reconciliation, null: false, default: {}
      t.datetime :fee_collected_at
      # Set when something after the run means its figures may be wrong.
      # Nothing from an invalidated snapshot is payable; only a new run clears it.
      t.datetime :invalidated_at
      t.text :invalidated_reason
      t.datetime :superseded_at
      t.bigint :superseded_by_id
      t.timestamps
    end
    add_index :mso_snapshots, :invoice_pass_id, name: "index_mso_snapshots_on_invoice_pass_id"
    # At most one snapshot per pass is current.
    add_index :mso_snapshots, :invoice_pass_id, unique: true, where: "superseded_at IS NULL",
      name: "index_mso_snapshots_one_current_per_pass"
    add_index :mso_snapshots, :superseded_by_id, name: "index_mso_snapshots_on_superseded_by_id"
    add_foreign_key :mso_snapshots, :invoice_passes
    add_foreign_key :mso_snapshots, :invoice_passes, column: :sanctuary_invoice_pass_id
    add_foreign_key :mso_snapshots, :mso_snapshots, column: :superseded_by_id

    create_table :mso_trueups do |t|
      t.bigint :ledger_id, null: false
      t.bigint :invoice_pass_id, null: false
      t.bigint :mso_snapshot_id, null: false
      t.bigint :mso_role_period_id, null: false
      t.decimal :amount, null: false, precision: 12, scale: 2
      t.text :description, null: false
      t.datetime :accepted_at
      t.string :qbo_bill_id
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :mso_trueups, :invoice_pass_id, name: "index_mso_trueups_on_invoice_pass_id"
    add_index :mso_trueups, :mso_snapshot_id, name: "index_mso_trueups_on_mso_snapshot_id"
    add_index :mso_trueups, :mso_role_period_id, name: "index_mso_trueups_on_mso_role_period_id"
    add_index :mso_trueups, :qbo_bill_id, name: "index_mso_trueups_on_qbo_bill_id"
    # Partial: with soft deletes a total index would let one deleted row block
    # regeneration forever.
    add_index :mso_trueups, [:ledger_id, :invoice_pass_id], unique: true, where: "deleted_at IS NULL",
      name: "index_mso_trueups_one_live_per_ledger_and_pass"
    add_foreign_key :mso_trueups, :ledgers
    add_foreign_key :mso_trueups, :invoice_passes
    add_foreign_key :mso_trueups, :mso_snapshots
    add_foreign_key :mso_trueups, :mso_role_periods
  end
end
```

`created_by_id` has no foreign key on purpose: an admin user can be deleted, and the snapshot must survive.

- [ ] **Step 2: Hand-edit `db/schema.rb`**

Change the version line (`db/schema.rb:13`) to:

```ruby
ActiveRecord::Schema.define(version: 2026_10_14_000001) do
```

Directly below the `create_table "mso_role_periods"` block (`db/schema.rb:681-690`) and above `create_table "notifications"` (`:692`), add:

```ruby
  create_table "mso_snapshots", force: :cascade do |t|
    t.bigint "invoice_pass_id", null: false
    t.bigint "sanctuary_invoice_pass_id", null: false
    t.bigint "created_by_id"
    t.decimal "fee_income", precision: 12, scale: 2, null: false
    t.string "benchmark_average", null: false
    t.integer "configured_n", null: false
    t.integer "counted", null: false
    t.boolean "small_sample", default: false, null: false
    t.decimal "cap_percentage", precision: 5, scale: 4, null: false
    t.decimal "cap", precision: 16, scale: 6, null: false
    t.string "total_calculated", null: false
    t.decimal "total_trueup", precision: 12, scale: 2, null: false
    t.decimal "total_trueup_as_billed", precision: 12, scale: 2, null: false
    t.jsonb "benchmark_members", default: [], null: false
    t.jsonb "excluded_without_login", default: [], null: false
    t.jsonb "lines", default: [], null: false
    t.jsonb "drift", default: [], null: false
    t.jsonb "reconciliation", default: {}, null: false
    t.datetime "fee_collected_at"
    t.datetime "invalidated_at"
    t.text "invalidated_reason"
    t.datetime "superseded_at"
    t.bigint "superseded_by_id"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["invoice_pass_id"], name: "index_mso_snapshots_on_invoice_pass_id"
    t.index ["invoice_pass_id"], name: "index_mso_snapshots_one_current_per_pass", unique: true, where: "(superseded_at IS NULL)"
    t.index ["superseded_by_id"], name: "index_mso_snapshots_on_superseded_by_id"
  end

  create_table "mso_trueups", force: :cascade do |t|
    t.bigint "ledger_id", null: false
    t.bigint "invoice_pass_id", null: false
    t.bigint "mso_snapshot_id", null: false
    t.bigint "mso_role_period_id", null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.text "description", null: false
    t.datetime "accepted_at"
    t.string "qbo_bill_id"
    t.datetime "deleted_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["invoice_pass_id"], name: "index_mso_trueups_on_invoice_pass_id"
    t.index ["ledger_id", "invoice_pass_id"], name: "index_mso_trueups_one_live_per_ledger_and_pass", unique: true, where: "(deleted_at IS NULL)"
    t.index ["mso_role_period_id"], name: "index_mso_trueups_on_mso_role_period_id"
    t.index ["mso_snapshot_id"], name: "index_mso_trueups_on_mso_snapshot_id"
    t.index ["qbo_bill_id"], name: "index_mso_trueups_on_qbo_bill_id"
  end
```

Directly below `add_foreign_key "mso_role_periods", "contributors"` (`db/schema.rb:1657`), add:

```ruby
  add_foreign_key "mso_snapshots", "invoice_passes"
  add_foreign_key "mso_snapshots", "invoice_passes", column: "sanctuary_invoice_pass_id"
  add_foreign_key "mso_snapshots", "mso_snapshots", column: "superseded_by_id"
  add_foreign_key "mso_trueups", "invoice_passes"
  add_foreign_key "mso_trueups", "ledgers"
  add_foreign_key "mso_trueups", "mso_role_periods"
  add_foreign_key "mso_trueups", "mso_snapshots"
```

Confirm nothing else changed: `grep -c 'enable_extension "vector"' db/schema.rb` must print `0`, and `git diff --stat db/schema.rb` must show 58 insertions and 1 deletion.

- [ ] **Step 3: Load the schema into the test database**

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
RAILS_ENV=test bin/rails db:environment:set db:schema:load
```

Expected: no error. Make sure no test process is running first.

- [ ] **Step 4: Write the shared builders**

Create `test/support/mso_fixtures.rb` (every file under `test/support` is required by `test/test_helper.rb:4`):

```ruby
# Builders for MSO true-up, snapshot and monthly-run tests. Builds on
# ManagementFeeFixtures (garden3d's QuickBooks account, pass and fee trackers).
module MsoFixtures
  include ManagementFeeFixtures

  def mso_admin
    @mso_admin ||= AdminUser.create!(email: "mso-admin-#{SecureRandom.hex(3)}@example.com",
                                     password: "password12345", roles: ["admin"])
  end

  # A contributor. ForecastPerson's after_create may already have made one.
  # `login:` gives them an AdminUser, matched to the ForecastPerson by email.
  def mso_person(tag, login: true)
    email = "mso-#{tag}-#{SecureRandom.hex(3)}@example.com"
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    AdminUser.create!(email: email, password: "password12345") if login
    fp.contributor || Contributor.create!(forecast_person: fp)
  end

  def login_for(contributor)
    AdminUser.find_by!(email: contributor.forecast_person.email)
  end

  def garden3d_ledger(contributor)
    Ledger.find_or_create_for(enterprise: garden3d, contributor: contributor)
  end

  def sanctuary_pass(month, completed: true)
    InvoicePass.create!(start_of_month: month, enterprise: enterprises(:sanctuary), data: {},
                        completed_at: completed ? Time.current : nil)
  end

  def mso_role(contributor, tier: :chief, title: "Operations", started_at: Date.new(2090, 1, 1), ended_at: nil)
    MsoRolePeriod.create!(contributor: contributor, tier: tier, title: title,
                          started_at: started_at, ended_at: ended_at)
  end

  # One snapshot line, shaped as Mso::MonthlyRun writes it.
  def mso_line(role, ledger, trueup:, already_earned: "0.0")
    {
      "mso_role_period_id" => role.id, "contributor_id" => role.contributor_id, "ledger_id" => ledger.id,
      "tier" => role.tier, "title" => role.title, "multiplier" => role.tier_multiplier.to_s("F"),
      "started_at" => role.started_at.iso8601, "ended_at" => role.ended_at&.iso8601,
      "already_earned" => already_earned, "earned_by_ledger" => {},
      "calculated" => trueup, "final" => trueup, "reduction" => "0.0", "trueup" => trueup,
      "trueup_before_rounding" => trueup
    }
  end

  def mso_snapshot(pass, lines: [], collected: false)
    sanctuary = InvoicePass.find_by(enterprise: enterprises(:sanctuary), start_of_month: pass.start_of_month) ||
                sanctuary_pass(pass.start_of_month)
    MsoSnapshot.create!(
      invoice_pass: pass, sanctuary_invoice_pass: sanctuary, fee_income: "100000", benchmark_average: "20000.0",
      configured_n: 3, counted: 3, small_sample: false, cap_percentage: "0.55", cap: "55000",
      total_calculated: "20000.0",
      total_trueup: lines.sum(BigDecimal("0")) { |line| BigDecimal(line["trueup"]) },
      total_trueup_as_billed: lines.sum(BigDecimal("0")) { |line| BigDecimal(line["trueup"]) },
      lines: lines, fee_collected_at: collected ? Time.current : nil,
    )
  end

  def mso_trueup(snapshot, role, ledger, amount:, accepted: false)
    MsoTrueup.create!(ledger: ledger, invoice_pass: snapshot.invoice_pass, mso_snapshot: snapshot,
                      mso_role_period: role, amount: amount, description: "MSO true-up",
                      accepted_at: accepted ? Time.current : nil)
  end

  # A stored accrual P&L for garden3d with `amount` on account 4100.
  def fee_report(month, amount)
    QboProfitAndLossReport.create!(
      qbo_account: garden3d_qbo_account, starts_at: month, ends_at: month.end_of_month,
      data: { cash: { rows: [] }, accrual: { rows: [["4100 Management Fee Income", amount], ["Total Income", amount]] } },
    )
  end
end
```

- [ ] **Step 5: Write the failing tests**

Create `test/models/mso_trueup_test.rb`:

```ruby
require "test_helper"

class MsoTrueupTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 3, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("exec")
    @other = mso_person("other")
    @ledger = garden3d_ledger(@exec)
    @other_ledger = garden3d_ledger(@other)
    @role = mso_role(@exec)
    @other_role = mso_role(@other, tier: :principal)
    # Nothing here may reach QuickBooks unless a test says so.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
  end

  def teardown
    clear_enterprise_memos
  end

  def snapshot(lines: nil, collected: true)
    lines ||= [mso_line(@role, @ledger, trueup: "1000.0")]
    mso_snapshot(@pass, lines: lines, collected: collected)
  end

  # Accrual dating (owner decision O2): March's true-up, run and billed in
  # July, is March's income and its bill is dated 03/31.
  test "it is dated the last day of the fee month, whenever it was run or billed" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")
    trueup.update_columns(created_at: Time.utc(2090, 7, 9), updated_at: Time.utc(2090, 7, 9))
    trueup = MsoTrueup.find(trueup.id)

    assert_equal Date.new(2090, 3, 31), trueup.payment_date
    assert_equal Date.new(2090, 3, 31), trueup.effective_on_for_display
    assert_equal Date.new(2090, 3, 31), trueup.bill_txn_date
    # (That it then counts as March's income, not July's, is Task 2's test.)
  end

  test "its QuickBooks bill is tagged MT and described by its admin URL" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")

    assert_equal "MT", trueup.bill_doc_number_code
    assert_equal "https://stacks.garden3d.net/admin/ledgers/#{@ledger.id}/mso_trueups/#{trueup.id}",
      trueup.bill_description
  end

  test "an amount of zero or less, or no description, is invalid" do
    base = { ledger: @ledger, invoice_pass: @pass, mso_snapshot: snapshot, mso_role_period: @role }

    assert_not MsoTrueup.new(base.merge(amount: 0, description: "x")).valid?
    assert_not MsoTrueup.new(base.merge(amount: -5, description: "x")).valid?
    assert_not MsoTrueup.new(base.merge(amount: 5, description: "")).valid?
    assert MsoTrueup.new(base.merge(amount: 5, description: "x")).valid?
  end

  test "it can only sit on a garden3d ledger and garden3d's pass" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: @exec)
    snap = snapshot

    on_wrong_ledger = MsoTrueup.new(ledger: sanctuary_ledger, invoice_pass: @pass, mso_snapshot: snap,
                                    mso_role_period: @role, amount: 5, description: "x")
    on_wrong_pass = MsoTrueup.new(ledger: @ledger, invoice_pass: snap.sanctuary_invoice_pass, mso_snapshot: snap,
                                  mso_role_period: @role, amount: 5, description: "x")

    assert_not on_wrong_ledger.valid?
    assert_includes on_wrong_ledger.errors[:ledger], "must be a garden3d, LLC ledger"
    assert_not on_wrong_pass.valid?
    assert_includes on_wrong_pass.errors[:invoice_pass], "must be garden3d, LLC's pass"
  end

  test "one live true-up per ledger per pass, and a soft-deleted one does not block another" do
    snap = snapshot
    first = mso_trueup(snap, @role, @ledger, amount: "1000")

    assert_raises(ActiveRecord::RecordNotUnique) { mso_trueup(snap, @role, @ledger, amount: "900") }

    first.destroy
    assert_nothing_raised { mso_trueup(snap, @role, @ledger, amount: "900") }
    assert_equal 2, MsoTrueup.with_deleted.where(ledger_id: @ledger.id, invoice_pass_id: @pass.id).count
  end

  test "it is not payable until it is accepted" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")

    assert_equal false, trueup.payable?
    trueup.toggle_acceptance!
    assert_equal true, MsoTrueup.find(trueup.id).payable?
  end

  test "it is not payable until the fee is confirmed collected" do
    snap = snapshot(collected: false)
    trueup = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)

    assert_equal false, trueup.payable?
    snap.update_columns(fee_collected_at: Time.current)
    assert_equal true, MsoTrueup.find(trueup.id).payable?
  end

  test "it is not payable until every expected true-up is accepted, including one that does not exist yet" do
    snap = snapshot(lines: [mso_line(@role, @ledger, trueup: "1000.0"),
                            mso_line(@other_role, @other_ledger, trueup: "2000.0")])
    mine = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)

    # The other executive's row has not been created: 1 of 1 accepted is not 2 of 2.
    assert_equal false, mine.payable?

    theirs = mso_trueup(snap, @other_role, @other_ledger, amount: "2000")
    assert_equal false, MsoTrueup.find(mine.id).payable?

    theirs.toggle_acceptance!
    assert_equal true, MsoTrueup.find(mine.id).payable?
  end

  test "a line with a zero true-up expects no row" do
    snap = snapshot(lines: [mso_line(@role, @ledger, trueup: "1000.0"),
                            mso_line(@other_role, @other_ledger, trueup: "0.0")])
    mine = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)

    assert_equal [@ledger.id], snap.expected_ledger_ids
    assert_equal true, mine.payable?
  end

  test "it is not payable once its snapshot has been superseded" do
    snap = snapshot
    trueup = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)
    assert_equal true, trueup.payable?

    snap.update_columns(superseded_at: Time.current)
    assert_equal false, MsoTrueup.find(trueup.id).payable?
  end

  test "acceptance toggles, and is refused once a QuickBooks bill exists" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")

    trueup.toggle_acceptance!
    assert trueup.reload.accepted?
    trueup.toggle_acceptance!
    assert_not trueup.reload.accepted?

    trueup.update_columns(accepted_at: Time.current, qbo_bill_id: "77")
    assert trueup.locked?
    error = assert_raises(MsoTrueup::Locked) { trueup.toggle_acceptance! }
    assert_match(/QuickBooks bill/, error.message)
    assert trueup.reload.accepted?
  end

  test "sync_qbo_bill! refuses a true-up that is not payable, before any QuickBooks call" do
    trueup = mso_trueup(snapshot(collected: false), @role, @ledger, amount: "1000", accepted: true)
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(RuntimeError, "unexpected QuickBooks bill write")

    error = assert_raises(MsoTrueup::NotPayable) { trueup.sync_qbo_bill! }
    assert_match(/not payable/, error.message)
    assert_nil trueup.reload.qbo_bill_id
  end

  test "a billed true-up counts as payable whatever else has changed" do
    snap = snapshot(collected: false)
    trueup = mso_trueup(snap, @role, @ledger, amount: "1000")
    assert_equal false, trueup.payable?

    trueup.update_columns(qbo_bill_id: "77")

    assert_equal true, MsoTrueup.find(trueup.id).payable?
  end

  test "it is not payable while its snapshot is invalidated, and confirming collection cannot bring it back" do
    snap = snapshot
    trueup = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)
    assert_equal true, trueup.payable?

    snap.invalidate!("a later run was refused")

    assert_equal false, MsoTrueup.find(trueup.id).payable?
    Mso::ManagementFeeInvoices.stubs(:collected?).raises(RuntimeError, "unexpected QuickBooks read")
    error = assert_raises(MsoSnapshot::Unusable) { MsoSnapshot.find(snap.id).check_collection! }
    assert_match(/a later run was refused/, error.message)
    assert_equal false, MsoTrueup.find(trueup.id).payable?
  end

  test "accepting is refused when the amount is no longer the one the person saw" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")

    error = assert_raises(MsoTrueup::AmountChanged) { trueup.toggle_acceptance!(expected_amount: "999.99") }
    assert_match(/1000\.0/, error.message)
    assert_raises(MsoTrueup::AmountChanged) { trueup.toggle_acceptance!(expected_amount: "not a number") }
    assert_not trueup.reload.accepted?

    trueup.toggle_acceptance!(expected_amount: "1000.0")
    assert trueup.reload.accepted?
  end

  test "schema_ready? remembers yes, and while the answer is no asks the database at most once a minute" do
    MsoTrueup.instance_variable_set(:@schema_ready, nil)
    MsoTrueup.instance_variable_set(:@schema_checked_at, nil)
    MsoTrueup.connection.stubs(:data_source_exists?).returns(true) # any other table Rails asks about
    MsoTrueup.connection.expects(:data_source_exists?).with("mso_trueups").once.returns(false)

    assert_equal false, MsoTrueup.schema_ready?
    assert_equal false, MsoTrueup.schema_ready?
    assert_equal false, MsoTrueup.schema_ready?
  ensure
    MsoTrueup.instance_variable_set(:@schema_ready, true)
    MsoTrueup.instance_variable_set(:@schema_checked_at, nil)
  end

  test "deleting it takes its QuickBooks bill with it" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")
    trueup.expects(:detach_and_destroy_qbo_bill).once

    trueup.destroy

    assert_nil MsoTrueup.find_by(id: trueup.id)
    assert MsoTrueup.with_deleted.find(trueup.id).deleted_at.present?
  end
end
```

Create `test/models/mso_snapshot_test.rb`:

```ruby
require "test_helper"

class MsoSnapshotTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 4, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
  end

  def teardown
    clear_enterprise_memos
  end

  test "a pass has at most one current snapshot, and any number of superseded ones" do
    first = mso_snapshot(@pass)

    assert_raises(ActiveRecord::RecordNotUnique) { mso_snapshot(@pass) }

    first.update_columns(superseded_at: Time.current)
    second = mso_snapshot(@pass)
    first.update_columns(superseded_by_id: second.id)

    assert_equal [second.id], MsoSnapshot.current.where(invoice_pass_id: @pass.id).pluck(:id)
    assert_equal 2, InvoicePass.find(@pass.id).mso_snapshots.count
    assert_equal false, first.reload.current?
    assert_equal second, first.superseded_by
  end

  test "its figures can never be changed, but its stamps can" do
    snapshot = mso_snapshot(@pass)

    assert_not snapshot.update(fee_income: "1")
    assert_includes snapshot.errors[:base], "A snapshot's figures cannot be changed (fee_income); run the month again"
    assert_not MsoSnapshot.find(snapshot.id).update(lines: [{ "trueup" => "5.0" }])
    assert_not MsoSnapshot.find(snapshot.id).update(benchmark_average: "1.0")

    assert MsoSnapshot.find(snapshot.id).update(fee_collected_at: Time.current)
    assert_equal BigDecimal("100000"), snapshot.reload.fee_income
  end

  test "check_collection! asks QuickBooks once and stamps the answer" do
    snapshot = mso_snapshot(@pass)
    Mso::ManagementFeeInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(true)

    assert_equal true, snapshot.check_collection!
    assert snapshot.reload.fee_collected?
  end

  test "check_collection! clears the stamp when the fee is no longer collected" do
    snapshot = mso_snapshot(@pass, collected: true)
    Mso::ManagementFeeInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(false)

    assert_equal false, snapshot.check_collection!
    assert_not snapshot.reload.fee_collected?
  end

  test "check_collection! refuses a superseded snapshot without asking QuickBooks" do
    snapshot = mso_snapshot(@pass)
    snapshot.update_columns(superseded_at: Time.current)
    Mso::ManagementFeeInvoices.stubs(:collected?).raises(RuntimeError, "unexpected QuickBooks read")

    error = assert_raises(MsoSnapshot::Unusable) { snapshot.check_collection! }
    assert_match(/superseded/, error.message)
  end

  test "invalidating records why and withdraws the collection stamp; the figures stay as they were" do
    snapshot = mso_snapshot(@pass, collected: true)

    snapshot.invalidate!("Account 4100 now reads 90000.0")

    snapshot.reload
    assert snapshot.invalidated?
    assert_equal "Account 4100 now reads 90000.0", snapshot.invalidated_reason
    assert_not snapshot.fee_collected?
    assert snapshot.current?
    assert_equal BigDecimal("100000"), snapshot.fee_income
  end

  test "unconfirm_collection! withdraws the stamp on the pass's current snapshot only" do
    old = mso_snapshot(@pass, collected: true)
    old.update_columns(superseded_at: Time.current)
    current = mso_snapshot(@pass, collected: true)
    elsewhere = mso_snapshot(garden3d_pass(Date.new(2090, 5, 1)), collected: true)

    assert_equal 1, MsoSnapshot.unconfirm_collection!(@pass.id)

    assert_not current.reload.fee_collected?
    assert old.reload.fee_collected?
    assert elsewhere.reload.fee_collected?
    assert_equal false, current.over_cap?
  end
end
```

- [ ] **Step 6: Run them to verify they fail**

```bash
bin/rails test test/models/mso_trueup_test.rb test/models/mso_snapshot_test.rb
```

Expected: every test errors with `NameError: uninitialized constant MsoSnapshot` (or `MsoTrueup`).

- [ ] **Step 7: Write the models**

Create `app/models/mso_snapshot.rb`:

```ruby
# The record of one run of a month's MSO compensation: every input
# Mso::MonthlyRun read and every figure it produced. Mso::Benchmark is a live
# calculation that changes when the roster or a payout is edited later, so
# this row, not a recomputation, is what a past month was paid on.
#
# A re-run never edits a snapshot. It writes a new one and stamps the old one
# superseded. The figures below are immutable; only the stamps change:
#
#   superseded_at / superseded_by_id     a later run replaced this one
#   fee_collected_at                     an admin's run or Check collection
#                                        confirmed, with QuickBooks, that the
#                                        month's fee was paid. Withdrawn when
#                                        the pass's invoices change.
#   invalidated_at / invalidated_reason  something happened after the run
#                                        that means its figures may be wrong.
#                                        Nothing from it is payable, and only
#                                        a successful run (a new snapshot)
#                                        undoes that.
#
# Executive compensation: admins only (AdminAuthorization).
class MsoSnapshot < ApplicationRecord
  # Superseded or invalidated: not something to confirm collection on.
  class Unusable < StandardError; end

  FIGURES = %w[
    invoice_pass_id sanctuary_invoice_pass_id fee_income benchmark_average configured_n counted
    small_sample cap_percentage cap total_calculated total_trueup total_trueup_as_billed
    benchmark_members excluded_without_login lines drift reconciliation
  ].freeze

  ZERO = BigDecimal("0")

  belongs_to :invoice_pass
  belongs_to :sanctuary_invoice_pass, class_name: "InvoicePass"
  belongs_to :created_by, class_name: "AdminUser", optional: true
  belongs_to :superseded_by, class_name: "MsoSnapshot", optional: true
  has_many :mso_trueups

  scope :current, -> { where(superseded_at: nil) }

  validate :figures_never_change, on: :update

  # Withdraws "the fee was collected" from a pass's current snapshot. Called
  # when the pass's invoices change (one attached or detached, or refreshed
  # from QuickBooks): the confirmation described the invoices as they were.
  def self.unconfirm_collection!(invoice_pass_id)
    return 0 unless MsoTrueup.schema_ready?
    current.where(invoice_pass_id: invoice_pass_id).update_all(fee_collected_at: nil)
  end

  def current?
    superseded_at.nil?
  end

  def invalidated?
    invalidated_at.present?
  end

  def fee_collected?
    fee_collected_at.present?
  end

  def month
    invoice_pass.start_of_month
  end

  # What is owed after this run, counting a billed true-up at its billed
  # amount, is more than the cap. Possible only when the fee fell after a
  # bill was written. The snapshot page warns about it.
  def over_cap?
    total_trueup_as_billed > cap
  end

  # The garden3d ledgers that are owed a true-up by this run. A line whose
  # true-up is zero has no row and needs no acceptance.
  def expected_ledger_ids
    lines.select { |line| BigDecimal(line["trueup"].to_s) > ZERO }.map { |line| line["ledger_id"] }
  end

  # One accepted true-up for EVERY line this run says is owed. Checking only
  # the rows that exist is unsafe: with two of three created and both
  # accepted, "all of them" would be true and two people would be paid at
  # figures computed for three.
  def all_expected_trueups_accepted?
    by_ledger = mso_trueups.index_by(&:ledger_id)
    expected_ledger_ids.all? { |ledger_id| by_ledger[ledger_id]&.accepted? }
  end

  # Nothing from this snapshot is payable any more, and confirming collection
  # cannot bring it back. Only running the month again does: that writes a
  # new snapshot.
  def invalidate!(reason)
    update_columns(invalidated_at: Time.current, invalidated_reason: reason.to_s.truncate(2000),
                   fee_collected_at: nil)
  end

  # Asks QuickBooks whether the month's management fee has been paid, and
  # stamps the answer. ONE QuickBooks read per fee invoice: call it from an
  # admin's click, never per row. Raises if any invoice cannot be read.
  def check_collection!
    raise Unusable, "This snapshot has been superseded; check collection on the current one" unless current?
    if invalidated?
      raise Unusable, "This run's figures are no longer valid (#{invalidated_reason}). Run the month again " \
                      "before confirming collection"
    end

    collected = Mso::ManagementFeeInvoices.collected?(invoice_pass: invoice_pass)
    update_columns(fee_collected_at: collected ? Time.current : nil)
    collected
  end

  private

  def figures_never_change
    touched = changed & FIGURES
    return if touched.empty?
    errors.add(:base, "A snapshot's figures cannot be changed (#{touched.join(', ')}); run the month again")
  end
end
```

Create `app/models/mso_trueup.rb`:

```ruby
# An MSO executive's true-up for one month, on their garden3d ledger: what
# their tier entitles them to, less what they already earned that month
# across all their ledgers. Written and rewritten only by Mso::MonthlyRun.
# The figures behind the amount live on its MsoSnapshot.
#
# Dated the LAST DAY OF THE FEE MONTH, whenever it is run or billed: that is
# the month it counts in as income, and the date on its QuickBooks bill.
#
# Executive compensation: visible to admins and to the executive it belongs
# to. Only that executive can accept it (AdminAuthorization).
class MsoTrueup < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill

  # Why a true-up was not sent to QuickBooks. Every message says what to do;
  # the Money page shows it to the admin who clicked.
  class SyncRefused < StandardError; end
  class NotPayable < SyncRefused; end
  class MissingVendor < SyncRefused; end
  class AccountNotConfigured < SyncRefused; end
  class NotCollected < SyncRefused; end
  class FiguresChanged < SyncRefused; end
  class BooksClosed < SyncRefused; end

  class Locked < StandardError; end
  class AmountChanged < StandardError; end

  belongs_to :invoice_pass
  belongs_to :mso_snapshot
  belongs_to :mso_role_period

  # A true-up under one cent has no row at all (see MsoSnapshot#expected_ledger_ids).
  validates :amount, numericality: { greater_than: 0 }
  validates :description, presence: true
  validate :lives_on_garden3d

  # As ProfitShare and PayStub: without this a deleted row orphans its bill.
  before_destroy :detach_and_destroy_qbo_bill

  # Migrations are run by hand on production, after the deploy. Everything
  # that enumerates ledger items asks this first, so the ledger, the Money
  # page and the nightly jobs keep working until the table exists.
  #
  # "Yes" is remembered for the life of the process. While the answer is
  # "no" the database is asked at most once a minute, so a ledger page before
  # the migration does not pay a query per balance, and nothing needs
  # restarting after it.
  def self.schema_ready?
    return true if @schema_ready

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return false if @schema_checked_at && now - @schema_checked_at < 60

    @schema_checked_at = now
    @schema_ready = connection.data_source_exists?(table_name)
  end

  def payment_date
    invoice_pass.start_of_month.end_of_month
  end

  # Must be the pass month, NOT created_at and NOT the day it was run or
  # billed: August's true-up, run in October, is August's income. A re-run in
  # a later month would otherwise move this row into that month, where it
  # would count as that month's earned income.
  def effective_on_for_display
    payment_date
  end

  def accepted?
    accepted_at.present?
  end

  # Once a QuickBooks bill exists the amount may already have been paid.
  # Mso::MonthlyRun never changes or deletes a locked true-up, and it cannot
  # be un-accepted.
  def locked?
    qbo_bill_id.present?
  end

  # `expected_amount` is the amount the person was looking at when they
  # clicked. A run may have changed it since; accepting a figure nobody saw
  # is refused. Under the row lock Mso::MonthlyRun also takes.
  def toggle_acceptance!(expected_amount: nil)
    with_lock do
      if locked?
        raise Locked, "This true-up has a QuickBooks bill and can no longer be changed here. " \
                      "An admin must remove the bill first."
      end
      unless expected_amount.nil?
        seen = BigDecimal(expected_amount.to_s, exception: false)
        if seen != amount
          raise AmountChanged, "This true-up is now #{amount.to_s('F')}, not the figure you were shown. " \
                               "Look at it again before accepting."
        end
      end
      update!(accepted_at: accepted? ? nil : Time.current)
    end
  end

  # Reads stored data only: no QuickBooks call, and no read of the invoice
  # mirrors. This is called per row on ledger pages and the Money page.
  #
  # A true-up with a bill is payable, full stop: the money is in garden3d's
  # accounts payable whatever happens to the snapshot afterwards, and a row
  # that stopped being payable could never settle here. Before the bill,
  # "the fee was collected" is a stamp on the snapshot, set from the
  # refreshing gate by Mso::MonthlyRun or an admin's Check collection click.
  def payable?
    return true if locked?
    return false unless accepted?

    snapshot = mso_snapshot
    snapshot.present? && snapshot.current? && !snapshot.invalidated? && snapshot.fee_collected? &&
      snapshot.all_expected_trueups_accepted?
  end

  # sync_qbo_bill! has no payable guard of its own, and the nightly
  # stacks:sync_contributor_qbo_bills task pushes every row it is given.
  # MsoTrueup is deliberately not in that task; this makes sure nothing
  # unaccepted or uncollected can reach QuickBooks even if it is added.
  # (Task 8 replaces this with the full set of checks.)
  def sync_qbo_bill!(accounts_cache: nil)
    unless payable?
      raise NotPayable, "MsoTrueup #{id} is not payable yet: it needs its executive's acceptance, every " \
                        "other executive's acceptance for the month, and a confirmed fee collection. " \
                        "No bill was written."
    end
    super
  end

  # SyncsAsQboBill contract. The bill's txn_date AND its due_date are both
  # this (syncs_as_qbo_bill.rb:145-146 sets them to the same value): the last
  # day of the fee month, so the expense lands in the month it belongs to.
  def bill_txn_date
    payment_date
  end

  def bill_description
    "https://stacks.garden3d.net/admin/ledgers/#{ledger_id}/mso_trueups/#{id}"
  end

  def bill_doc_number_code
    "MT"
  end

  private

  def lives_on_garden3d
    garden3d_id = Enterprise.garden3d.id
    if ledger && ledger.enterprise_id != garden3d_id
      errors.add(:ledger, "must be a #{Enterprise::GARDEN3D_NAME} ledger")
    end
    if invoice_pass && invoice_pass.enterprise_id != garden3d_id
      errors.add(:invoice_pass, "must be #{Enterprise::GARDEN3D_NAME}'s pass")
    end
  end
end
```

Notes on what was read to write this:
- `Trueup` is the model for the date methods and the bill contract (`app/models/trueup.rb:11-34`); `ProfitShare` for `before_destroy` and `accepted?` (`app/models/profit_share.rb:8,22-24`).
- `payable?` must be defined on the class. Both concerns define one (`app/models/concerns/ledger_item.rb:25-27`, `app/models/concerns/syncs_as_qbo_bill.rb:112-114`) and whichever is included last wins.
- `"MT"` is free: the registry lists CP, TU, CA, PS, SB (`app/models/concerns/syncs_as_qbo_bill.rb:109-110`), `Reimbursement` uses RB (`app/models/qbo_account.rb:265`), and no mirrored bill's doc number ends `_MT` on the dev copy.

In `app/models/invoice_pass.rb`, directly below `has_many :invoice_trackers` (line 7), add:

```ruby
  # One per run of the month's MSO compensation; at most one is current.
  # Only garden3d's passes ever have any.
  has_many :mso_snapshots
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
bin/rails test test/models/mso_trueup_test.rb test/models/mso_snapshot_test.rb
```

Expected: PASS, 24 runs, 0 failures.

- [ ] **Step 9: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 24 more runs than the baseline (baseline + 24), 0 failures, 0 errors. Report the actual total.

- [ ] **Step 10: Commit**

```bash
git add db/migrate/20261014000001_create_mso_snapshots_and_trueups.rb db/schema.rb \
  app/models/mso_snapshot.rb app/models/mso_trueup.rb app/models/invoice_pass.rb \
  test/support/mso_fixtures.rb test/models/mso_trueup_test.rb test/models/mso_snapshot_test.rb
git commit -m "feat(mso): the MSO true-up and the snapshot of the run that produced it

A true-up is dated the last day of its fee month. Before it has a QuickBooks
bill it is payable only when it is accepted, its snapshot is current and not
invalidated, the fee is confirmed collected, and every true-up the run says
is owed has been accepted; it refuses to write a bill until then. Once it
has a bill it stays payable so it can settle. A snapshot's figures can never
be edited."
```

---

### Task 2: The ledger knows about MSO true-ups

**Files:**
- Modify: `app/models/ledger.rb`
- Modify: `app/models/ledger/qualifying_income.rb`
- Modify: `app/services/mso/benchmark.rb`
- Create: `test/models/ledger/mso_trueup_ledger_test.rb`

**Interfaces:**
- Consumes: `MsoTrueup`, `MsoTrueup.schema_ready?`
- Produces:
  - `Ledger has_many :mso_trueups`
  - `Ledger#balance(include_mso_trueups: true)`, `#unsettled(include_mso_trueups: true)`, `#items_grouped_by_month(…, include_mso_trueups: true)`
  - `Ledger::QualifyingIncome::SOURCES` includes `MsoTrueup`; `Mso::Benchmark::KLASSES` does not

- [ ] **Step 1: Write the failing test**

Create `test/models/ledger/mso_trueup_ledger_test.rb`:

```ruby
require "test_helper"

class Ledger::MsoTrueupLedgerTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 5, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("ledger-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(@role, @ledger, trueup: "1500.0")], collected: true)
  end

  def teardown
    clear_enterprise_memos
  end

  def fresh_ledger
    Ledger.find(@ledger.id)
  end

  # Two months starting at MONTH; without the overrides an empty ledger's
  # walk stops two months from today and never reaches 2090.
  def grouped(ledger, **opts)
    ledger.items_grouped_by_month(MONTH, MONTH + 2.months, **opts)
  end

  def month_of(result)
    result[:by_month].find { |period, _| period.starts_at == MONTH }&.last
  end

  test "an unaccepted true-up is unsettled, and an accepted, collected one is balance" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1500")

    assert_equal 1500.0, fresh_ledger.unsettled.to_f
    assert_equal 0.0, fresh_ledger.balance.to_f

    trueup.toggle_acceptance!

    assert_equal 0.0, fresh_ledger.unsettled.to_f
    assert_equal 1500.0, fresh_ledger.balance.to_f
  end

  test "include_mso_trueups: false leaves it out of the balance, the unsettled total and the month" do
    mso_trueup(@snapshot, @role, @ledger, amount: "1500")

    assert_equal 0.0, fresh_ledger.unsettled(include_mso_trueups: false).to_f
    assert_equal 0.0, fresh_ledger.balance(include_mso_trueups: false).to_f
    hidden = month_of(grouped(fresh_ledger, include_mso_trueups: false))
    assert_equal [], hidden[:items]
    assert_equal 0, hidden[:total_income]
  end

  test "it is listed in its pass month and counts toward that month's income" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1500")

    month = month_of(grouped(fresh_ledger))

    assert_equal [trueup], month[:items]
    assert_equal 1500.0, month[:total_income]
  end

  test "a soft-deleted true-up is still listed for the strikethrough, but is in no total" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1500")
    trueup.destroy

    month = month_of(grouped(fresh_ledger))

    assert_equal [trueup.id], month[:items].map(&:id)
    assert_equal 0.0, fresh_ledger.unsettled.to_f
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: @ledger, month: MONTH)
  end

  test "it is qualifying income, and excluding: takes it back out" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1500")

    assert_equal BigDecimal("1500"), Ledger::QualifyingIncome.for(ledger: @ledger, month: MONTH)
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: @ledger, month: MONTH, excluding: [trueup])
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: @ledger, month: MONTH + 1.month)
  end

  test "no kind of true-up is benchmark income" do
    assert_includes Ledger::QualifyingIncome::KLASSES, MsoTrueup
    assert_not_includes Mso::Benchmark::KLASSES, MsoTrueup
    assert_not_includes Mso::Benchmark::KLASSES, Trueup
    assert_includes Mso::Benchmark::KLASSES, ContributorPayout
  end

  test "before the table exists, the ledger works and never queries it" do
    MsoTrueup.stubs(:schema_ready?).returns(false)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    ledger = fresh_ledger
    assert_equal 0.0, ledger.balance.to_f
    assert_equal 0.0, ledger.unsettled.to_f
    assert_equal [], month_of(grouped(ledger))[:items]
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: ledger, month: MONTH)

    assert_empty statements.grep(/mso_trueups/)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/ledger/mso_trueup_ledger_test.rb
```

Expected: 7 runs, 7 failures or errors. The first reads an unsettled total of 0.0; the second errors with `ArgumentError: unknown keyword: :include_mso_trueups`; "no kind of true-up" fails on the first assertion.

- [ ] **Step 3: Write the ledger code**

In `app/models/ledger.rb`, directly below `has_many :pay_stubs` (line 23), add:

```ruby
  has_many :mso_trueups
```

Replace `balance` and `unsettled` (lines 117-123) with:

```ruby
  # include_mso_trueups: false leaves MSO true-ups out. An MSO true-up is
  # executive compensation; the ledger page passes false when the viewer is
  # neither an admin nor the contributor whose ledger this is.
  def balance(include_mso_trueups: true)
    sum_for_bucket(payable: true, include_mso_trueups: include_mso_trueups)
  end

  def unsettled(include_mso_trueups: true)
    sum_for_bucket(payable: false, include_mso_trueups: include_mso_trueups)
  end
```

Replace the signature and first line of `items_grouped_by_month` (lines 128-129) with:

```ruby
  def items_grouped_by_month(override_starts_at = nil, override_ends_at = nil, min_ends_at: nil,
                             include_mso_trueups: true)
    all_items = all_items_with_deleted
    all_items = all_items.reject { |li| li.is_a?(MsoTrueup) } unless include_mso_trueups
```

Replace the `total_income` block (lines 150-152) with:

```ruby
      total_income = sorted.sum do |li|
        income = li.is_a?(ContributorPayout) || li.is_a?(Trueup) || li.is_a?(PayStub) || li.is_a?(MsoTrueup)
        income ? li.amount.to_f : 0
      end
```

Replace `visible_items`, `qbo_bound_visible_items` and `qbo_bound_open_items` (lines 173-199; keep the comments above each) with:

```ruby
  # Non-deleted only — used by balance/unsettled sums.
  def visible_items(include_mso_trueups: true)
    [
      contributor_payouts.to_a,
      contributor_adjustments.to_a,
      trueups.to_a,
      reimbursements.to_a,
      profit_shares.to_a,
      deel_invoice_adjustments.to_a,
      pay_stubs.to_a,
      (include_mso_trueups && MsoTrueup.schema_ready? ? mso_trueups.to_a : []),
    ].flatten
  end

  # qbo_bound mode: drop audit-only rows. The remaining items are then split
  # by `qbo_bound_open_items` (paid bills drop too) and bucketed by `payable?`.
  def qbo_bound_visible_items(include_mso_trueups: true)
    visible_items(include_mso_trueups: include_mso_trueups)
      .reject { |li| self.class.audit_only_under_qbo_bound?(li) }
  end

  # qbo_bound mode: items that should still appear somewhere (balance or
  # unsettled). Audit-only items are dropped, AND any host whose QBO bill
  # is fully Paid is dropped — paid bills are settled in QBO and shouldn't
  # show up in Stacks at all. Partial-paid bills survive (their remaining
  # balance is the contribution).
  def qbo_bound_open_items(include_mso_trueups: true)
    qbo_bound_visible_items(include_mso_trueups: include_mso_trueups)
      .reject { |li| li.try(:qbo_bill)&.paid? }
  end
```

`Ledgers::QboBoundMigrationCheck` calls `ledger.send(:visible_items)` with no arguments (`app/services/ledgers/qbo_bound_migration_check.rb:32`); the default keeps it working.

Replace `sum_for_bucket` (lines 219-227) with:

```ruby
  def sum_for_bucket(payable:, include_mso_trueups: true)
    if legacy?
      visible_items(include_mso_trueups: include_mso_trueups)
        .select { |li| li.payable? == payable }.sum(&:signed_amount)
    elsif qbo_bound?
      qbo_bound_open_items(include_mso_trueups: include_mso_trueups)
        .select { |li| li.payable? == payable }.sum { |li| qbo_bound_contribution(li) }
    else
      raise "Unknown ledger mode: #{mode.inspect}"
    end
  end
```

In `all_items_with_deleted` (lines 236-246), add one entry directly below the `PayStub` line (245):

```ruby
      (MsoTrueup.schema_ready? ? MsoTrueup.with_deleted.includes(:invoice_pass, mso_snapshot: :mso_trueups).where(ledger_id: id).to_a : []),
```

- [ ] **Step 4: Qualifying income, and the benchmark's exclusion**

In `app/models/ledger/qualifying_income.rb`, update the header comment's "Counts:" line (lines 4-6) to read `contributor payouts, pay stubs, profit shares, true-ups (the founder's and the MSO's), and POSITIVE contributor adjustments`, and add `MsoTrueup` to `SOURCES` (lines 20-26):

```ruby
  SOURCES = {
    ContributorPayout => { invoice_tracker: :invoice_pass },
    Trueup => :invoice_pass,
    PayStub => :pay_cycle,
    ProfitShare => :periodic_report,
    ContributorAdjustment => nil,
    # An executive's MSO true-up. Mso::MonthlyRun passes the month's own
    # true-ups as `excluding:`, or a re-run would net each against itself.
    MsoTrueup => :invoice_pass,
  }.freeze
```

Inside `self.for`, make the block passed to `klasses.uniq.sum(ZERO)` (line 46) start with a guard, so its first lines read:

```ruby
    klasses.uniq.sum(ZERO) do |klass|
      # Migrations are run by hand after the deploy: a class whose table is
      # not there yet has no rows.
      next ZERO if klass.respond_to?(:schema_ready?) && !klass.schema_ready?

      rows = klass.where(ledger_id: ledger.id)
```

In `app/services/mso/benchmark.rb`, replace the comment and constant at lines 14-19 with:

```ruby
    # Everything that is payment for work — payouts, pay stubs, profit shares
    # and positive adjustments such as recruiting fees — but no true-up of
    # either kind. A true-up is a top-up, not earnings. The founder true-up
    # lifts one person to exactly the highest earner's figure, so counting it
    # would put a copy of the top earner in the pool; an MSO true-up is what
    # this benchmark is used to compute, so counting it would be circular.
    # (An MsoTrueup only ever sits on a garden3d ledger and this reads
    # Sanctuary's, but that is an accident of today's data, not a rule.)
    KLASSES = (Ledger::QualifyingIncome::KLASSES - [Trueup, MsoTrueup]).freeze
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/models/ledger/mso_trueup_ledger_test.rb test/models/ledger test/services/mso
```

Expected: PASS. The new file has 7 runs; the existing qualifying-income and benchmark tests still pass unchanged.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 7 more runs than after Task 1 (baseline + 31), 0 failures, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add app/models/ledger.rb app/models/ledger/qualifying_income.rb app/services/mso/benchmark.rb \
  test/models/ledger/mso_trueup_ledger_test.rb
git commit -m "feat(mso): an MSO true-up is on the ledger and is qualifying income

It is in the balance, the unsettled total and the month's income, and it
counts as income a person has already earned. It is never benchmark income.
Until its table exists the ledger does not query it."
```

---

### Task 3: The contributor's ledger walk and elevated service

**Files:**
- Modify: `app/models/contributor.rb`
- Modify: `app/models/periodic_report.rb`
- Create: `test/models/contributor_mso_trueup_test.rb`

**Interfaces:**
- Consumes: `MsoTrueup`, `Ledger#balance(include_mso_trueups:)`
- Produces:
  - `Contributor has_many :mso_trueups, through: :ledgers`, `#mso_trueups_with_deleted`
  - `Contributor#all_items_grouped_by_month(…, include_mso_trueups: true)`, `#new_deal_balance(_ledger_items = nil, include_mso_trueups: true)`
  - MSO true-ups count in all three elevated-service computations
  - `Contributor.aggregated_new_deal_balance` (the company-wide figure on the dashboard) is deliberately **unchanged** and never includes them

- [ ] **Step 1: Write the failing test**

Create `test/models/contributor_mso_trueup_test.rb`:

```ruby
require "test_helper"

class ContributorMsoTrueupTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 6, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("walk-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(@role, @ledger, trueup: "9500.0")], collected: true)
    @period = Stacks::Period.new("June 2090", MONTH, MONTH.end_of_month)
  end

  def teardown
    clear_enterprise_memos
  end

  def fresh
    Contributor.find(@exec.id)
  end

  # The window Contributor#elevated_service_for_month uses (contributor.rb:584).
  def walk(contributor = fresh, **opts)
    contributor.all_items_grouped_by_month(false, MONTH, MONTH.end_of_month + 1.day, **opts)
  end

  def month_of(result)
    result[:by_month].find { |period, _| period.starts_at == MONTH }&.last
  end

  # A Sanctuary payout in the same month, so the walk has two kinds of item to sort.
  def sanctuary_payout(amount)
    sanctuary = enterprises(:sanctuary)
    pass = InvoicePass.find_by!(enterprise: sanctuary, start_of_month: MONTH)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Walk Client #{SecureRandom.hex(3)}")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client: client,
                                     qbo_account: Enterprise.find(sanctuary.id).qbo_account)
    payout = ContributorPayout.new(ledger: Ledger.find_or_create_for(enterprise: sanctuary, contributor: @exec),
                                   invoice_tracker: tracker, created_by: mso_admin, amount: amount)
    payout.save!(validate: false)
    payout
  end

  test "the walk lists an MSO true-up beside other items without failing to sort them" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "9500")
    payout = sanctuary_payout(200)

    month = month_of(walk)

    assert_equal [trueup, payout].map { |i| [i.class, i.id] }.sort_by(&:to_s),
      month[:items].map { |i| [i.class, i.id] }.sort_by(&:to_s)
    assert_includes fresh.mso_trueups, trueup
  end

  test "an MSO true-up counts toward the month's income and so toward elevated service" do
    mso_trueup(@snapshot, @role, @ledger, amount: "9500")

    month = month_of(walk)

    assert_equal BigDecimal("9500"), month[:total_income]
    assert_equal true, month[:elevated_service]
  end

  test "include_mso_trueups: false hides it and its income from the walk and the balance" do
    mso_trueup(@snapshot, @role, @ledger, amount: "9500")

    month = month_of(walk(include_mso_trueups: false))

    assert_equal [], month[:items]
    assert_equal 0, month[:total_income]
    assert_equal false, month[:elevated_service]
    assert_equal({ balance: 0.0, unsettled: 9500.0 }, fresh.new_deal_balance)
    assert_equal({ balance: 0.0, unsettled: 0.0 }, fresh.new_deal_balance(nil, include_mso_trueups: false))
  end

  test "the bulk elevated-service query counts it too" do
    mso_trueup(@snapshot, @role, @ledger, amount: "9500")
    login = login_for(@exec)

    ids = Contributor.elevated_service_admin_user_ids([@period], [@exec.forecast_person_id])

    assert_includes ids, login.id
  end

  test "the bulk elevated-service query ignores a soft-deleted true-up" do
    mso_trueup(@snapshot, @role, @ledger, amount: "9500").destroy
    login = login_for(@exec)

    ids = Contributor.elevated_service_admin_user_ids([@period], [@exec.forecast_person_id])

    assert_not_includes ids, login.id
  end

  test "profit-share elevated service counts an MSO true-up on a profit-share company's ledger" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "9500")
    report = PeriodicReport.new
    report.stubs(:period).returns(Stacks::Period.new("Q2 2090", Date.new(2090, 4, 1), Date.new(2090, 6, 30), :quarter))

    result = report.profit_share_elevated_service_by_month(fresh, { @period => { items: [trueup] } })

    assert_equal({ @period => true }, result)
  end

  # Decisions 29: the dashboard every logged-in user can open shows this
  # figure. It must not move when executives' true-ups are written.
  test "the company-wide balance on the dashboard leaves MSO true-ups out" do
    past_pass = garden3d_pass(Date.new(2019, 2, 1))
    past_snapshot = mso_snapshot(past_pass, lines: [mso_line(@role, @ledger, trueup: "700.0")], collected: true)
    before = Contributor.aggregated_new_deal_balance
    mso_trueup(past_snapshot, @role, @ledger, amount: "700", accepted: true)
    mso_trueup(@snapshot, @role, @ledger, amount: "9500")

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end
    after = Contributor.aggregated_new_deal_balance

    assert_empty statements.grep(/mso_trueups/)
    assert_in_delta before[:balance].to_f, after[:balance].to_f, 0.001
    assert_in_delta before[:unsettled].to_f, after[:unsettled].to_f, 0.001
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/contributor_mso_trueup_test.rb
```

Expected: 7 runs, 5 failures or errors. The first finds only the payout in the month; the income tests read 0; `include_mso_trueups: false` is an unknown keyword. Two pass already and pin behaviour: "ignores a soft-deleted true-up" (nothing counts any MSO true-up yet) and "the company-wide balance … leaves MSO true-ups out" (which must stay true).

- [ ] **Step 3: Write the contributor code**

All edits are in `app/models/contributor.rb`.

Directly below `has_many :pay_stubs, through: :ledgers` (line 79), add:

```ruby
  has_many :mso_trueups, through: :ledgers
```

Directly below `pay_stubs_with_deleted` (it ends at line 137, above `private` at 139), add:

```ruby

  # The snapshot and its true-ups are what MsoTrueup#payable? reads.
  def mso_trueups_with_deleted
    @_mso_trueups_with_deleted ||=
      if MsoTrueup.schema_ready?
        MsoTrueup.with_deleted
          .joins(:ledger)
          .includes(:invoice_pass, mso_snapshot: :mso_trueups)
          .where(ledgers: { contributor_id: id }).to_a
      else
        []
      end
  end
```

In `preload_for_ledger_view!`, directly below the `@_pay_stubs_with_deleted = …` assignment (lines 200-202), add:

```ruby
    @_mso_trueups_with_deleted =
      if MsoTrueup.schema_ready?
        MsoTrueup.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id })
          .includes(:ledger, :invoice_pass, mso_snapshot: :mso_trueups).to_a
      else
        []
      end
```

and add `@_mso_trueups_with_deleted,` as the last entry of the array that follows (lines 207-215), below `@_pay_stubs_with_deleted,`.

Replace `new_deal_balance` (lines 311-317) with:

```ruby
  def new_deal_balance(_ledger_items = nil, include_mso_trueups: true)
    ledgers.reduce({ balance: 0, unsettled: 0 }) do |acc, l|
      acc[:balance]   += l.balance(include_mso_trueups: include_mso_trueups).to_f
      acc[:unsettled] += l.unsettled(include_mso_trueups: include_mso_trueups).to_f
      acc
    end
  end
```

**Do not touch `aggregated_new_deal_balance`** (lines 328-374). Spec §9.7 #8 lists it, but it is the company-wide "balance owed" on the dashboard every logged-in user can open (`app/admin/dashboard.rb:108`) and in `Mcp::GetExecutiveDashboardTool`; with two executives it would jump by the month's total true-up on run day (Decisions 29). It enumerates classes by hand, so leaving `MsoTrueup` out of it is all that is needed, and a test pins that.

In `all_items_grouped_by_month`:

Replace the signature (line 380) with:

```ruby
  def all_items_grouped_by_month(include_salary = true, override_ledger_starts_at = nil, override_ledger_ends_at = nil,
                                 min_ends_at: nil, include_mso_trueups: true)
```

Directly below `preloaded_pay_stubs = pay_stubs_with_deleted` (line 387), add:

```ruby
    # Executive compensation: left out when the viewer may not see it.
    preloaded_mso_trueups = include_mso_trueups ? mso_trueups_with_deleted : []
```

In the `ledger_ends_at` array (lines 392-398), add `*preloaded_mso_trueups,` below `*preloaded_pay_stubs,`, and change line 403 from `elsif li.is_a?(Trueup)` to:

```ruby
        elsif li.is_a?(Trueup) || li.is_a?(MsoTrueup)
```

Directly below the `pay_stubs_in_period` block (lines 478-481), add:

```ruby

      mso_trueups_in_period = preloaded_mso_trueups.select do |mt|
        mt.payment_date >= period.starts_at &&
        mt.payment_date <= period.ends_at
      end
```

In the `sorted` array (lines 484-491), add `*mso_trueups_in_period,` below `*pay_stubs_in_period,`.

In the sort comparator, change line 494 from `if a.is_a?(Trueup)` and line 511 from `if b.is_a?(Trueup)` to, respectively:

```ruby
        if a.is_a?(Trueup) || a.is_a?(MsoTrueup)
```

```ruby
        if b.is_a?(Trueup) || b.is_a?(MsoTrueup)
```

Both classes answer `payment_date`. Without these two edits an MSO true-up's date is `nil` and `date_b <=> date_a` (line 527) returns `nil`, which makes `sort` raise as soon as a month holds an MSO true-up and anything else.

In the `total_income` reduce, change line 539 from `if item.is_a?(Trueup)` to:

```ruby
        if item.is_a?(Trueup) || item.is_a?(MsoTrueup)
```

In `self.elevated_service_admin_user_ids`, replace the array literal and its `.each do |grouped|` opener (lines 615-624) with:

```ruby
    grouped_income = [
      ContributorPayout.joins(:ledger).joins(invoice_tracker: :invoice_pass)
        .where(ledgers: { contributor_id: contributor_ids })
        .where("invoice_passes.start_of_month BETWEEN ? AND ?", span_start, span_end)
        .group("ledgers.contributor_id", "invoice_passes.start_of_month").sum(:amount),
      Trueup.joins(:ledger).joins(:invoice_pass)
        .where(ledgers: { contributor_id: contributor_ids })
        .where("invoice_passes.start_of_month BETWEEN ? AND ?", span_start, span_end)
        .group("ledgers.contributor_id", "invoice_passes.start_of_month").sum(:amount),
    ]
    if MsoTrueup.schema_ready?
      grouped_income << MsoTrueup.joins(:ledger).joins(:invoice_pass)
        .where(ledgers: { contributor_id: contributor_ids })
        .where("invoice_passes.start_of_month BETWEEN ? AND ?", span_start, span_end)
        .group("ledgers.contributor_id", "invoice_passes.start_of_month").sum(:amount)
    end
    grouped_income.each do |grouped|
```

- [ ] **Step 4: Profit-share elevated service**

In `app/models/periodic_report.rb`, change line 212 from

```ruby
        if (item.is_a?(ContributorPayout) || item.is_a?(Trueup)) && scope_ids.include?(item.ledger.enterprise_id)
```

to:

```ruby
        counts = item.is_a?(ContributorPayout) || item.is_a?(Trueup) || item.is_a?(MsoTrueup)
        if counts && scope_ids.include?(item.ledger.enterprise_id)
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/models/contributor_mso_trueup_test.rb test/models/contributor_test.rb test/models/periodic_report_test.rb test/models/periodic_report_scoping_test.rb
```

Expected: PASS. The new file has 7 runs.

`Contributor.aggregated_new_deal_balance` walks every ledger item in the test database, fixtures included. If "the company-wide balance" errors on a fixture row rather than on its assertions, that is an existing fragility in the method; report it and keep the `mso_trueups` SQL assertion, do not delete the test.

If "profit-share elevated service" errors inside `recorded_allocation_during_range_in_hours_from_assignments` rather than on the assertion, the stubbed report is missing something that method reads; stop and report what, rather than deleting the test.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 7 more runs than after Task 2 (baseline + 38), 0 failures, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add app/models/contributor.rb app/models/periodic_report.rb test/models/contributor_mso_trueup_test.rb
git commit -m "feat(mso): MSO true-ups are in the contributor's ledger walk and count toward elevated service

All three elevated-service computations count them, as the owner decided.
The walk's sort gains the new class; without it a month holding an MSO
true-up and anything else would fail to render. The company-wide balance on
the dashboard deliberately leaves them out."
```

---

### Task 4: QuickBooks registration, and a GL concept that raises

Six of spec §9.7's registration points (#1–#5 and #11). After this task an MSO true-up appears on the Money page, and routing it **raises** because garden3d has no MSO compensation account. That is the intended state until Finance creates one. What happens when an admin clicks Sync is Task 8.

**Files:**
- Modify: `app/services/qbo/bill_router.rb`
- Modify: `app/models/concerns/syncs_as_qbo_bill.rb`
- Modify: `app/models/qbo_account.rb`
- Modify: `app/services/money/payable_qbo_bills.rb`, `app/services/money/qbo_bill_summary.rb`
- Modify: `app/admin/money.rb`
- Create: `test/models/mso_trueup_qbo_registration_test.rb`

**Interfaces:**
- Consumes: `MsoTrueup`
- Produces:
  - `Qbo::BillRouter` routes `MsoTrueup` to `:mso_compensation`, which is not fallbackable; garden3d's code is `"____"`
  - `Money::PayableQboBills::HOST_KLASSES` includes `MsoTrueup`; `Money::PayableQboBills.host_klasses -> [Class]` leaves out any class whose table is not there yet

- [ ] **Step 1: Write the failing test**

Create `test/models/mso_trueup_qbo_registration_test.rb`:

```ruby
require "test_helper"
require "ostruct"

class MsoTrueupQboRegistrationTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 7, 1)

  def setup
    @qa = garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("qbo-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(@role, @ledger, trueup: "1200.0")], collected: true)
    @trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1200", accepted: true)
    @vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    ContributorQboVendor.create!(contributor: @exec, qbo_account: @qa, qbo_vendor: @vendor)

    # garden3d's chart as it is today: the 6100 catch-all and nothing for MSO.
    QboAccount.any_instance.stubs(:fetch_all_accounts).returns([account("6100", 61)])
    # Anything that would write to QuickBooks fails the test.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(RuntimeError, "unexpected QuickBooks bill write")
    Quickbooks::Service::Bill.any_instance.stubs(:update).raises(RuntimeError, "unexpected QuickBooks bill write")
  end

  def teardown
    clear_enterprise_memos
  end

  def account(num, id)
    OpenStruct.new(acct_num: num, id: id, name: "Acct #{num}")
  end

  def router(item = MsoTrueup.find(@trueup.id))
    Qbo::BillRouter.new(item, accounts_cache: Qbo::AccountsCache.new)
  end

  def bill!(qbo_id, data = { "balance" => "1200", "total_amt" => "1200" })
    QboBill.create!(qbo_account: @qa, qbo_id: qbo_id, qbo_vendor_id: @vendor.qbo_id, data: data)
  end

  # --- routing ---------------------------------------------------------------

  test "an MSO true-up is one line on the mso_compensation concept" do
    lines = router.concept_lines

    assert_equal 1, lines.size
    assert_equal :mso_compensation, lines.first[:concept]
    assert_equal BigDecimal("1200"), lines.first[:amount]
    assert_equal @trueup.bill_description, lines.first[:description]
  end

  test "mso_compensation can never fall back, and garden3d's account is deliberately unmatched" do
    assert_not_includes Qbo::BillRouter::FALLBACKABLE_CONCEPTS, :mso_compensation
    assert_equal "____", Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:garden3d][:mso_compensation]
  end

  test "routing raises rather than filing executive pay under Platform Infrastructure" do
    error = assert_raises(RuntimeError) { router.lines }

    assert_match(/mso_compensation/, error.message)
    assert_match(/____/, error.message)
  end

  test "once the account number is pinned and the account exists, it routes there" do
    QboAccount.any_instance.stubs(:fetch_all_accounts).returns([account("6100", 61), account("6200", 62)])
    pinned = router
    pinned.stubs(:enterprise_gl_map)
      .returns(Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:garden3d].merge(mso_compensation: "6200"))

    assert_equal [62], pinned.lines.map { |line| line[:account].id }
  end

  # --- the Money page ----------------------------------------------------------

  test "a payable true-up is listed as payable, and an unaccepted one is counted as unsettled" do
    payable = Money::PayableQboBills.call(qbo_account: @qa).map(&:host)
    assert_includes payable, @trueup
    before = Money::QboBillSummary.call(qbo_account: @qa)
    assert_includes before.payable_rows.map(&:host), @trueup

    @trueup.update_columns(accepted_at: nil)

    assert_not_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup
    after = Money::QboBillSummary.call(qbo_account: @qa)
    assert_not_includes after.payable_rows.map(&:host), @trueup
    assert_equal before.unsettled_count + 1, after.unsettled_count
    assert_in_delta 1200.0, after.unsettled_total - before.unsettled_total, 0.001
  end

  test "until the table exists the Money page leaves MsoTrueup out and still renders its data" do
    assert_includes Money::PayableQboBills::HOST_KLASSES, MsoTrueup
    assert_includes Money::PayableQboBills.host_klasses, MsoTrueup

    MsoTrueup.stubs(:schema_ready?).returns(false)

    assert_not_includes Money::PayableQboBills.host_klasses, MsoTrueup
    assert_includes Money::PayableQboBills.host_klasses, ContributorPayout
    assert_not_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup
    assert_nothing_raised { Money::QboBillSummary.call(qbo_account: @qa) }
  end

  # --- bill housekeeping ---------------------------------------------------------

  test "when its bill vanishes from QuickBooks the true-up is detached" do
    bill!("501")
    @trueup.update_columns(qbo_bill_id: "501")
    @qa.stubs(:fetch_all_bills).returns([])

    @qa.sync_all_bills!

    assert_nil @trueup.reload.qbo_bill_id
    assert_nil QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "501")
  end

  test "orphan cleanup leaves a live true-up's bill alone" do
    bill!("502")
    @trueup.update_columns(qbo_bill_id: "502")
    @qa.stubs(:fetch_all_bills).returns([OpenStruct.new(id: "502", doc_number: "Stacks_#{@trueup.id}_MT")])
    QboBill.any_instance.stubs(:delete_qbo_bill!).raises(RuntimeError, "unexpected QuickBooks bill delete")
    @qa.stubs(:delete_bill).raises(RuntimeError, "unexpected QuickBooks bill delete")

    @qa.cleanup_orphaned_qbo_objects!

    assert_equal "502", @trueup.reload.qbo_bill_id
    assert QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "502")
  end

  test "orphan cleanup knows the MT code: a soft-deleted true-up's leftover bill is removed" do
    bill!("503")
    @trueup.update_columns(qbo_bill_id: "503", deleted_at: Time.current)
    @qa.stubs(:fetch_all_bills).returns([OpenStruct.new(id: "503", doc_number: "Stacks_#{@trueup.id}_MT")])
    # QboBill#destroy deletes the remote bill; that is the one call allowed here.
    QboBill.any_instance.expects(:delete_qbo_bill!).once

    @qa.cleanup_orphaned_qbo_objects!

    assert_nil MsoTrueup.with_deleted.find(@trueup.id).qbo_bill_id
    assert_nil QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "503")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/mso_trueup_qbo_registration_test.rb
```

Expected: 9 runs, 9 failures or errors. The first reads `:subcontractor`; "routing raises" does **not** raise (it resolves to account 61, the bug this task closes); the Money tests do not find the true-up; `host_klasses` is undefined; the detach test sees no change. Both orphan-cleanup tests fail for the same reason, and it is worth reading: with no `"MT"` arm and `MsoTrueup` absent from the host list, cleanup treats the bill as an orphan and **deletes it**, live true-up or not.

- [ ] **Step 3: The router**

In `app/services/qbo/bill_router.rb`, in the `garden3d:` map, directly below `profit_share_liability: "6100",` (line 64), add:

```ruby
        # MSO executive compensation (MsoTrueup). Finance has not created the
        # account yet. "____" matches no account, and :mso_compensation is NOT
        # in FALLBACKABLE_CONCEPTS, so routing RAISES rather than filing
        # executive pay under 6100. Replace with the account's acct_num once
        # it exists. No other enterprise has this key: nil raises the same way.
        mso_compensation:       "____",
```

Leave `FALLBACKABLE_CONCEPTS` (line 16) exactly as it is.

Replace `concept_lines` (lines 122-133) with:

```ruby
    def concept_lines
      case item
      when PayStub
        paystub_concept_lines
      when ProfitShare
        [single_line(:profit_share_liability)]
      when ContributorPayout
        payout_concept_lines
      when MsoTrueup
        # Must be named here: anything unnamed falls to :subcontractor below,
        # which is fallbackable and would land on the enterprise's catch-all.
        [single_line(:mso_compensation)]
      else # Trueup, ContributorAdjustment
        [single_line(:subcontractor)]
      end
    end
```

- [ ] **Step 4: The doc-code registry**

In `app/models/concerns/syncs_as_qbo_bill.rb`, replace the comment at lines 108-110 with:

```ruby
  #   (must be unique across all host models). Current mappings:
  #     CP = ContributorPayout, TU = Trueup, CA = ContributorAdjustment,
  #     PS = ProfitShare, SB = PayStub, RB = Reimbursement, MT = MsoTrueup.
  #   A new code also needs a `when` arm in
  #   QboAccount#cleanup_orphaned_qbo_objects!.
```

- [ ] **Step 5: The host list, guarded**

In `app/services/money/payable_qbo_bills.rb`, replace `HOST_KLASSES` (lines 9-16) with:

```ruby
    HOST_KLASSES = [
      ContributorPayout,
      ContributorAdjustment,
      ProfitShare,
      Trueup,
      PayStub,
      Reimbursement,
      MsoTrueup,
    ].freeze

    # HOST_KLASSES, less any class whose table is not on this database yet.
    # Migrations are run by hand after the deploy; iterate THIS, not the
    # constant, or the Money page raises until then.
    def self.host_klasses
      HOST_KLASSES.select { |klass| !klass.respond_to?(:schema_ready?) || klass.schema_ready? }
    end
```

and change line 21 from `rows = HOST_KLASSES.flat_map do |klass|` to:

```ruby
      rows = host_klasses.flat_map do |klass|
```

In `app/services/money/qbo_bill_summary.rb`, add to `PRELOADS` directly below the `Reimbursement` entry (line 19):

```ruby
      # payable? reads the snapshot and every true-up on it.
      MsoTrueup         => { mso_snapshot: :mso_trueups },
```

and change line 34 from `Money::PayableQboBills::HOST_KLASSES.each do |klass|` to:

```ruby
      Money::PayableQboBills.host_klasses.each do |klass|
```

In `app/admin/money.rb`, change line 74 so the allow-list for "Sync to QBO" uses the same reader:

```ruby
    raise ActionController::BadRequest, "unsupported host class" unless Money::PayableQboBills.host_klasses.map(&:name).include?(raw_class)
```

- [ ] **Step 6: Bill housekeeping**

In `app/models/qbo_account.rb`, in `sync_all_bills!`, directly below the `Reimbursement` line (244), add:

```ruby
      if MsoTrueup.schema_ready?
        # Scoped to this account's own ledgers: a bill id is unique only
        # within one QuickBooks account.
        MsoTrueup.with_deleted
          .where(qbo_bill_id: deleted_qbo_ids, ledger_id: Ledger.where(enterprise_id: enterprise_id).select(:id))
          .update_all(qbo_bill_id: nil)
      end
```

In `cleanup_orphaned_qbo_objects!`, add an arm directly below `when "RB"` / `klass = Reimbursement` (lines 265-266):

```ruby
      when "MT"
        klass = MsoTrueup
```

and change line 301 from `next if Money::PayableQboBills::HOST_KLASSES.any? do |k|` to:

```ruby
      next if Money::PayableQboBills.host_klasses.any? do |k|
```

The six lines above line 244 detach by bill id alone, across every QuickBooks account. That is an existing hazard for the older classes and is out of scope here; the new line does not repeat it. Neither `sync_all_bills!` nor `cleanup_orphaned_qbo_objects!` has a caller in `app/` or `lib/` today; both are run from a console.

- [ ] **Step 7: Run the test to verify it passes**

```bash
bin/rails test test/models/mso_trueup_qbo_registration_test.rb test/services/qbo test/services/money test/models/qbo_account_test.rb test/integration/payable_qbo_bills_test.rb
```

Expected: PASS. The new file has 9 runs.

- [ ] **Step 8: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 9 more runs than after Task 3 (baseline + 47), 0 failures, 0 errors.

- [ ] **Step 9: Commit**

```bash
git add app/services/qbo/bill_router.rb app/models/concerns/syncs_as_qbo_bill.rb app/models/qbo_account.rb \
  app/services/money/payable_qbo_bills.rb app/services/money/qbo_bill_summary.rb app/admin/money.rb \
  test/models/mso_trueup_qbo_registration_test.rb
git commit -m "feat(mso): MSO true-ups are QuickBooks bill hosts, routed to a concept that raises

garden3d has no MSO compensation account yet. Unnamed, a true-up would have
been filed under Platform Infrastructure without an error. It now routes to
:mso_compensation, which cannot fall back and is deliberately unmatched, so
routing fails loudly until Finance creates the account."
```

---

### Task 5: Executive pay stays out of the MCP bill list and the financial outlook

Two reports would otherwise publish it. `Mcp::ListPayableBillsTool` lists every mirrored bill with its vendor and total. And `Stacks::FinancialOutlook` lists spend by P&L account, hiding only accounts whose name matches `Stacks::PeopleCostAccounts::PATTERNS` (`lib/stacks/financial_outlook.rb:195`, `lib/stacks/people_cost_accounts.rb:5-15`): once Finance creates an account called "MSO Compensation" or "Executive Compensation", `get_financial_outlook` would show total executive pay as a spend category, because neither name matches any existing pattern.

**Files:**
- Modify: `app/services/mcp/list_payable_bills_tool.rb`
- Modify: `lib/stacks/people_cost_accounts.rb`
- Create: `test/services/mcp/payable_bills_tool_mso_test.rb`, `test/lib/stacks/people_cost_accounts_mso_test.rb`

**Interfaces:**
- Consumes: `MsoTrueup`
- Produces:
  - `Mcp::ListPayableBillsTool` omits, from the listing and from `total_outstanding`, every bill an `MsoTrueup` points at and every bill whose doc number is `Stacks_<n>_MT`
  - `Stacks::PeopleCostAccounts.excluded?` is true for an account, or a parent header, named for compensation, the MSO or executives

- [ ] **Step 1: Write the failing test**

Create `test/services/mcp/payable_bills_tool_mso_test.rb`:

```ruby
require "test_helper"

class Mcp::PayableBillsToolMsoTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 8, 1)

  def setup
    @qa = garden3d_qbo_account
    pass = garden3d_pass(MONTH)
    exec = mso_person("mcp-exec")
    ledger = garden3d_ledger(exec)
    role = mso_role(exec)
    snapshot = mso_snapshot(pass, lines: [mso_line(role, ledger, trueup: "1200.0")])
    @trueup = mso_trueup(snapshot, role, ledger, amount: "1200")
    @vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}",
                                data: { "display_name" => "An Executive" })
    # A read tool must never destroy a bill: that deletes it in QuickBooks.
    QboBill.any_instance.stubs(:delete_qbo_bill!).raises(RuntimeError, "unexpected QuickBooks bill delete")
  end

  def teardown
    clear_enterprise_memos
  end

  def bill!(qbo_id, data)
    QboBill.create!(qbo_account: @qa, qbo_id: qbo_id, qbo_vendor_id: @vendor.qbo_id, data: data)
  end

  def garden3d_block
    payload = mcp_payload(Mcp::ListPayableBillsTool.call(entity: garden3d.name, server_context: {}))
    payload["entities"].first
  end

  test "an executive's MSO bill is not listed and not in the outstanding total" do
    bill!("601", { "doc_number" => "Stacks_#{@trueup.id}_MT", "total_amt" => 1200.0, "balance" => 1200.0 })
    @trueup.update_columns(qbo_bill_id: "601")
    # A leftover MSO bill no true-up points at any more is recognised by its doc number.
    bill!("602", { "doc_number" => "Stacks_999999_MT", "total_amt" => 800.0, "balance" => 800.0 })
    bill!("603", { "doc_number" => "B-603", "total_amt" => 50.0, "balance" => 50.0 })

    block = garden3d_block

    assert_equal ["B-603"], block["bills"].map { |bill| bill["doc_number"] }
    assert_in_delta 50.0, block["total_outstanding"], 0.001
    assert_no_match(/1200|800/, block.to_json)
  end

  test "a bill a true-up points at is left out whatever its stored data says, even when the true-up is deleted" do
    bill!("604", {})
    bill!("605", { "doc_number" => "renamed-by-hand", "total_amt" => 1200.0, "balance" => 1200.0 })
    @trueup.update_columns(qbo_bill_id: "605", deleted_at: Time.current)

    block = garden3d_block

    assert_equal [], block["bills"]
    assert_in_delta 0.0, block["total_outstanding"], 0.001
    # 604 is an ordinary unsynced mirror row: skipped and counted, as before.
    assert_equal 1, block["skipped_count"]
  end
end
```

Create `test/lib/stacks/people_cost_accounts_mso_test.rb`:

```ruby
require "test_helper"

class PeopleCostAccountsMsoTest < ActiveSupport::TestCase
  def excluded?(*labels)
    Stacks::PeopleCostAccounts.excluded?(*labels)
  end

  test "an account named for compensation, the MSO or executives is a people cost" do
    ["6200 MSO Compensation", "Executive Compensation", "[NYC] 6210 Executive Team", "MSO", "6200 Compensation - MSO",
     "Deferred compensation"].each { |label| assert excluded?(label), label }
    assert excluded?("6210 Principals", "6200 MSO"), "a parent header hides its children"
    assert excluded?("Anything", "Executive Compensation")
  end

  test "ordinary spend accounts are still shown" do
    ["6100 Platform Infrastructure", "Software and Subscriptions", "Rent Expense", "Marketing and Advertising",
     "Compost Service", "Msolutions Hosting", "Cosmos DB", "Carbon Offset Contributions"].each do |label|
      refute excluded?(label), label
    end
  end

  test "the outlook's spend by category leaves an MSO compensation account out" do
    rows = [
      ["Expenses", nil],
      ["6100 Platform Infrastructure", "500.0"],
      ["6200 MSO Compensation", "59946.87"],
      ["Total Expenses", "60446.87"],
    ]
    seen = {}

    # allocate: each_spend_row reads only its argument and two constants.
    Stacks::FinancialOutlook.allocate.each_spend_row(rows) { |category, value| seen[category] = value }

    assert_equal({ "Platform Infrastructure" => 500.0 }, seen)
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/services/mcp/payable_bills_tool_mso_test.rb test/lib/stacks/people_cost_accounts_mso_test.rb
```

Expected: 5 runs, 4 failures. The bill tool lists all three doc numbers, and bill 605; "MSO Compensation" is not excluded; the outlook yields it. "Ordinary spend accounts are still shown" passes already and must keep passing.

- [ ] **Step 3: Write the exclusion**

In `app/services/mcp/list_payable_bills_tool.rb`, directly below `MAX_BILLS_PER_ENTITY = 500` (line 15), add:

```ruby

    # MSO executive compensation is never listed here. This tool has no notion
    # of who is asking, and a bill carries the executive's vendor name and the
    # amount. Recognised two ways: a bill an MsoTrueup points at, and the "MT"
    # doc-number code SyncsAsQboBill gives every MsoTrueup bill.
    MSO_DOC_NUMBER = /\AStacks_\d+_MT\z/
```

In `self.entity_block`, replace line 54

```ruby
      records = QboBill.joins(:qbo_account).where(qbo_accounts: { enterprise_id: ent.id }).to_a
```

with:

```ruby
      mso_bill_ids = mso_trueup_bill_ids(ent)
      records = QboBill.joins(:qbo_account).where(qbo_accounts: { enterprise_id: ent.id }).to_a
        .reject { |bill| mso_compensation_bill?(bill, mso_bill_ids) }
```

Directly above `self.vendors_for` (line 95, with its comment starting at line 91), add:

```ruby
    # Bill ids every MsoTrueup on this entity's ledgers points at, deleted
    # true-ups included: a deleted row's bill can outlive it.
    def self.mso_trueup_bill_ids(ent)
      return Set.new unless MsoTrueup.schema_ready?

      MsoTrueup.with_deleted.joins(:ledger)
        .where(ledgers: { enterprise_id: ent.id })
        .where.not(qbo_bill_id: nil)
        .pluck(:qbo_bill_id).map(&:to_s).to_set
    end

    def self.mso_compensation_bill?(bill, mso_bill_ids)
      return true if mso_bill_ids.include?(bill.qbo_id.to_s)

      (bill.data || {})["doc_number"].to_s.match?(MSO_DOC_NUMBER)
    end

```

`QboBill#data` is a plain jsonb read with no live fetch (`app/services/mcp/list_payable_bills_tool.rb:58-60` relies on that), so reading it here costs nothing.

- [ ] **Step 4: The outlook's exclusion patterns**

In `lib/stacks/people_cost_accounts.rb`, add one line to `PATTERNS`, directly below the `/management fee/i, …` line (14):

```ruby
    # MSO executive compensation, whatever Finance names the account. Without these an account called
    # "MSO Compensation" matches nothing above and the outlook would report total executive pay.
    /compensation/i, /\bmso\b/i, /executive/i,
```

These were checked, read-only, against every stored P&L on the dev copy: they hide **no** account that is shown today on any enterprise (Verification Step 5 repeats the check). "Officer Compensation" was already hidden by `/officer/`.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bin/rails test test/services/mcp/payable_bills_tool_mso_test.rb test/services/mcp/payable_bills_tool_test.rb test/lib/stacks/people_cost_accounts_mso_test.rb test/lib/stacks/financial_outlook_test.rb
```

Expected: PASS. 5 new runs; the existing tool and outlook tests are unchanged.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 5 more runs than after Task 4 (baseline + 52), 0 failures, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add app/services/mcp/list_payable_bills_tool.rb lib/stacks/people_cost_accounts.rb \
  test/services/mcp/payable_bills_tool_mso_test.rb test/lib/stacks/people_cost_accounts_mso_test.rb
git commit -m "fix(mcp): executive compensation stays out of list_payable_bills and the financial outlook

The bill tool lists vendor, doc number and total for every mirrored bill and
has no notion of who is asking; MSO true-up bills are left out of it. The
outlook's spend by category hid people costs by account name, and an account
named for MSO or executive compensation matched none of the names."
```

---

### Task 6: Authorization

**Files:**
- Modify: `app/models/admin_authorization.rb`
- Create: `test/models/admin_authorization_mso_test.rb`

**Interfaces:**
- Consumes: `MsoTrueup`, `MsoSnapshot`
- Produces:
  - Any action on `MsoSnapshot` (class or record): admins only
  - Any action on the `MsoTrueup` class: admins only. On a record: admins anything **except accepting it**; its owner `:read` and `:toggle_acceptance`; everyone else nothing
  - `:toggle_acceptance` on a true-up: its owner only. An admin who is not the owner is refused
  - `:run_mso_compensation` on an `InvoicePass`: admins only

- [ ] **Step 1: Write the failing test**

Create `test/models/admin_authorization_mso_test.rb`:

```ruby
require "test_helper"

class AdminAuthorizationMsoTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 9, 1)
  EVERY_ACTION = [:read, :index, :new, :create, :update, :destroy, :toggle_acceptance, :check_collection,
                  :remove_qbo_bill].freeze

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("authz-exec")
    @other = mso_person("authz-other")
    @role = mso_role(@exec)
    @other_role = mso_role(@other, tier: :svp)
    @snapshot = mso_snapshot(@pass, lines: [
      mso_line(@role, garden3d_ledger(@exec), trueup: "1000.0"),
      mso_line(@other_role, garden3d_ledger(@other), trueup: "2000.0"),
    ])
    @mine = mso_trueup(@snapshot, @role, garden3d_ledger(@exec), amount: "1000")
    @theirs = mso_trueup(@snapshot, @other_role, garden3d_ledger(@other), amount: "2000")

    @admin = mso_admin
    @lead = AdminUser.create!(email: "authz-lead-#{SecureRandom.hex(3)}@example.com", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
    @nobody = login_for(mso_person("authz-nobody"))
    @exec_login = login_for(@exec)
  end

  def teardown
    clear_enterprise_memos
  end

  def auth_for(user)
    AdminAuthorization.new(nil, user)
  end

  test "an admin may do anything with MSO compensation except accept someone else's true-up" do
    auth = auth_for(@admin)

    [MsoTrueup, MsoSnapshot, @mine, @snapshot].each do |subject|
      (EVERY_ACTION - [:toggle_acceptance]).each do |action|
        assert auth.authorized?(action, subject), "admin should #{action} #{subject}"
      end
    end
    assert auth.authorized?(:run_mso_compensation, @pass)

    refute auth.authorized?(:toggle_acceptance, @mine), "accepting is the executive's own act"
    refute auth.authorized?(:toggle_acceptance, @theirs)
    refute auth.authorized?(:toggle_acceptance, MsoTrueup)
  end

  # Both expected executives are admins. Each can see the other's true-up
  # (unchanged, and a question for the owner) but must not accept it.
  test "an executive who is an admin can accept their own true-up and not the other executive's" do
    @exec_login.update!(roles: ["admin"])
    auth = auth_for(AdminUser.find(@exec_login.id))

    assert auth.authorized?(:toggle_acceptance, @mine)
    refute auth.authorized?(:toggle_acceptance, @theirs)
    assert auth.authorized?(:read, @theirs)
    assert auth.authorized?(:read, @snapshot)
  end

  test "a full lead can do nothing with any MSO subject, reading included" do
    auth = auth_for(@lead)
    # The premise: this user really does have the blanket lead grant.
    assert auth.authorized?(:read, Studio)

    [MsoTrueup, MsoSnapshot, @mine, @theirs, @snapshot, MsoTrueup.new, MsoSnapshot.new].each do |subject|
      EVERY_ACTION.each { |action| refute auth.authorized?(action, subject), "lead must not #{action} #{subject}" }
    end
  end

  test "someone with only a contributor record cannot list, start or create a true-up" do
    auth = auth_for(@nobody)

    [:index, :new, :create, :read].each do |action|
      refute auth.authorized?(action, MsoTrueup), "must not #{action} the class"
      refute auth.authorized?(action, MsoTrueup.new), "must not #{action} a new record"
    end
    refute auth.authorized?(:read, @mine)
    refute auth.authorized?(:read, MsoSnapshot)
  end

  test "an executive can read and accept their own true-up and nothing more" do
    auth = auth_for(@exec_login)

    assert auth.authorized?(:read, @mine)
    assert auth.authorized?(:toggle_acceptance, @mine)
    [:update, :destroy, :create, :remove_qbo_bill, :check_collection].each do |action|
      refute auth.authorized?(action, @mine), "owner must not #{action} their own true-up"
    end

    EVERY_ACTION.each { |action| refute auth.authorized?(action, @theirs), "must not #{action} another's true-up" }
    EVERY_ACTION.each { |action| refute auth.authorized?(action, @snapshot), "must not #{action} the snapshot" }
    [:index, :new, :create, :read].each { |action| refute auth.authorized?(action, MsoTrueup) }
  end

  test "an executive who is also a lead still sees only their own true-up" do
    PermissionGrant.create!(admin_user: @exec_login, permission: "lead")
    auth = auth_for(AdminUser.find(@exec_login.id))
    assert auth.authorized?(:read, Studio)

    assert auth.authorized?(:read, @mine)
    refute auth.authorized?(:read, @theirs)
    refute auth.authorized?(:read, @snapshot)
    refute auth.authorized?(:read, MsoSnapshot)
  end

  test "only an admin may run a month's MSO compensation" do
    assert auth_for(@admin).authorized?(:run_mso_compensation, @pass)
    refute auth_for(@lead).authorized?(:run_mso_compensation, @pass)
    refute auth_for(@exec_login).authorized?(:run_mso_compensation, @pass)
    # Whether a lead may still READ garden3d's pass is S1's rule (it is
    # becoming admin-only) and is not asserted here.
  end

  test "MsoTrueup is not one of the own-ledger-item classes" do
    # That list grants :index, :new and :create to anyone with a contributor.
    assert_not_includes AdminAuthorization::OWN_LEDGER_ITEM_CLASSES, MsoTrueup
    assert_not_includes AdminAuthorization::OWN_LEDGER_ITEM_CLASSES, MsoSnapshot
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/admin_authorization_mso_test.rb
```

Expected: 8 runs, 6 failures. "A full lead can do nothing" fails on its first refute (the blanket grant lets a lead read everything); "an executive can read and accept their own" fails on its first assert (nothing grants it); "an executive who is also a lead" fails because a lead can read another's; "only an admin may run" fails because a lead may; and the two admin tests fail because an admin may accept anyone's. "Someone with only a contributor record" and the constant test pass already; they pin behaviour the fix must keep.

- [ ] **Step 3: Write the guards**

In `app/models/admin_authorization.rb`, replace line 18 with:

```ruby
  MANAGEMENT_FEE_PASS_ADMIN_ACTIONS = [
    :create_management_fee_drafts,
    :refresh_management_fee_invoices,
    # Computes and writes every executive's true-up for the month.
    :run_mso_compensation,
  ].freeze

  # Executive compensation. MsoRolePeriod has its own line below.
  MSO_COMPENSATION_CLASSES = [MsoTrueup, MsoSnapshot].freeze
```

Directly below the `MsoRolePeriod` line (86), add:

```ruby

    # The snapshot holds fee income, the cap and every executive's line:
    # admins only. A true-up is for admins and for the executive whose ledger
    # it is on, who may read it. Class-level subjects (:index, :new, :create)
    # are admin-only, which is why MsoTrueup is NOT in OWN_LEDGER_ITEM_CLASSES.
    # Must stay above the blanket lead grant: every executive is likely to be
    # a lead, and a lead reads all.
    if MSO_COMPENSATION_CLASSES.any? { |klass| subject == klass || subject.is_a?(klass) }
      # Accepting a true-up is its owner's act alone. Checked BEFORE the admin
      # line: the executives are admins, and "an admin may accept" would let
      # each accept the other's.
      return own_mso_trueup?(subject) if action == :toggle_acceptance
      return true if user.is_admin?
      return action == :read && own_mso_trueup?(subject)
    end
```

At the very end of the class, directly above its closing `end` (line 216) and below `authorized?`'s own `end`, add:

```ruby

  private

  def own_mso_trueup?(subject)
    return false unless subject.is_a?(MsoTrueup) && subject.persisted?

    owner = subject.ledger&.contributor&.forecast_person&.admin_user
    owner.present? && owner == user
  end
```

The existing `InvoicePass` guard at lines 88-90 reads `MANAGEMENT_FEE_PASS_ADMIN_ACTIONS`, so `:run_mso_compensation` is admin-only without another line.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/models/admin_authorization_mso_test.rb test/models/admin_authorization_test.rb
```

Expected: PASS. 8 new runs.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 8 more runs than after Task 5 (baseline + 60), 0 failures, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add app/models/admin_authorization.rb test/models/admin_authorization_mso_test.rb
git commit -m "feat(mso): executive compensation is admin-only, and a true-up is its owner's

A lead reads everything by default. The snapshot and other people's
true-ups now refuse a lead, above that grant. An executive may read and
accept their own true-up and nothing else, and nobody, admins included,
can accept a true-up that is not theirs."
```

---

### Task 7: `Mso::MonthlyRun`

**Files:**
- Create: `app/services/mso/monthly_run.rb`
- Create: `test/services/mso/monthly_run_test.rb`

**Interfaces:**
- Consumes:
  - `Mso::ManagementFeeInvoices.collected?(invoice_pass:)`, `MANAGEMENT_FEE_START`, `ITEM_NAME`
  - `Mso::ManagementFeeIncome.reconcile!(date) -> { account_total:, payer_total:, variance:, invoices: }`
  - `MsoRolePeriod.active_during(date)`, `#tier_multiplier`
  - `Mso::Benchmark.for_month(date) -> Result(average, configured_n, counted, members, small_sample, excluded_without_login)`
  - `Ledger::QualifyingIncome.for(ledger:, month:, excluding:)`
  - `Mso::Compensation.call(benchmark_average:, lines:, fee_income:, cap_percentage:) -> Result(outputs, cap, total_calculated, total_trueup)`
- Produces:
  - `Mso::MonthlyRun.call(invoice_pass:, run_by: nil, today: Date.today) -> MsoSnapshot`. Raises `Mso::MonthlyRun::Refused` with a message fit to show an admin.
  - `Mso::MonthlyRun.preview(invoice_pass:, today: Date.today) -> { ledger_id => BigDecimal }`: what a run would produce now, computed from the database only, writing nothing and calling nothing outside it
  - `Mso::MonthlyRun.invalidate_snapshots_whose_fee_moved! -> [snapshot ids]`: the nightly, database-only check (wired up in Task 8)
  - `Mso::MonthlyRun.runnable?(invoice_pass) -> Boolean` (may the button be shown)
  - `Mso::MonthlyRun.already_earned(contributor_id:, month:, excluding: []) -> { ledger_id => BigDecimal }`
  - `Mso::MonthlyRun.assert_one_period_per_person!(role_periods)`

**What a run does, in order:**

1. Refuses unless the pass is garden3d's, holds no legacy Forecast tracker, is for a month on or after `MANAGEMENT_FEE_START`, and that month has ended.
2. Refuses unless Sanctuary's pass for the month exists, is `complete?` and has at least one contributor payout (spec §9.5: "all payouts accepted" would freeze every executive behind one person who never clicked Accept; September 2026 has 9 unaccepted of 54).
3. Calls `Mso::ManagementFeeInvoices.collected?` **once**. That refreshes every attached fee invoice from QuickBooks (one read each) and says whether the fee is paid.
4. Reconciles account 4100 against those now-fresh invoices; refuses on a variance or a missing row. The fee income is read once, here.
5. In one transaction, with garden3d's pass row locked: reads the roster (one period per person, or it refuses); **refuses if anyone on the roster has a founder true-up in the month**; reads the benchmark and each executive's qualifying income across all their ledgers excluding this pass's own true-ups; calls `Mso::Compensation`; rounds each true-up **down to the cent**; supersedes the current snapshot; writes the new one; creates, updates, restores or removes true-ups, each under its own row lock.

If any step refuses, or fails in any other way, nothing is written and the current snapshot (if there is one) is **invalidated**: nothing from it is payable and Check collection refuses, until a run succeeds.

A month can be run at any time after it has ended. Nothing here assumes it is last month: the run reads the pass's month, and August can be run in October.

- [ ] **Step 1: Write the failing test**

Create `test/services/mso/monthly_run_test.rb`:

```ruby
require "test_helper"

class Mso::MonthlyRunTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2093, 5, 1)
  TODAY = Date.new(2093, 6, 10)

  def setup
    @sanctuary = enterprises(:sanctuary)
    @sanctuary_pass = sanctuary_pass(MONTH)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Run Client #{SecureRandom.hex(3)}")
    @tracker = InvoiceTracker.create!(invoice_pass: @sanctuary_pass, forecast_client: client,
                                      qbo_account: Enterprise.find(@sanctuary.id).qbo_account)

    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @payer = make_payer("Run Payer #{SecureRandom.hex(3)}", customer_id: "2")
    @fee_tracker = fee_tracker(@pass, @payer)
    charge_fee("100000.0")

    # Sanctuary's top three: 30,000 / 20,000 / 10,000, so the benchmark is 20,000.
    @top = earner("a", 30_000)
    earner("b", 20_000)
    earner("c", 10_000)

    @chief = mso_person("chief")
    @chief_role = mso_role(@chief, tier: :chief, title: "Operations")
    @principal = mso_person("principal")
    @principal_role = mso_role(@principal, tier: :principal, title: "Founder")

    # The one QuickBooks-touching call a run makes. Everything else raises.
    Mso::ManagementFeeInvoices.stubs(:collected?).returns(true)
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range).raises(RuntimeError, "unexpected QuickBooks read")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
  end

  def teardown
    clear_enterprise_memos
  end

  # garden3d's fee for MONTH: one paid invoice and a matching 4100 row.
  def charge_fee(amount, account_total: amount)
    QboInvoice.where(qbo_account_id: garden3d_qbo_account.id, qbo_id: "9001").delete_all
    QboProfitAndLossReport.where(qbo_account_id: garden3d_qbo_account.id, starts_at: MONTH).delete_all
    attach_invoice(@fee_tracker, qbo_id: "9001", total: amount, balance: "0.0", sent: true)
    fee_report(MONTH, account_total)
  end

  # Saved without validation: these tests are about who earned what, not
  # about ContributorPayout's own invoice-share rules.
  def pay(contributor, amount, enterprise: @sanctuary, tracker: @tracker)
    ledger = Ledger.find_or_create_for(enterprise: enterprise, contributor: contributor)
    payout = ContributorPayout.new(ledger: ledger, invoice_tracker: tracker, created_by: mso_admin, amount: amount)
    payout.save!(validate: false)
    payout
  end

  def earner(tag, amount)
    mso_person("earner-#{tag}").tap { |contributor| pay(contributor, amount) }
  end

  def run!(pass: @pass, today: TODAY, **opts)
    Mso::MonthlyRun.call(invoice_pass: pass, today: today, **opts)
  end

  def trueup_for(contributor)
    MsoTrueup.find_by(invoice_pass_id: @pass.id, ledger_id: garden3d_ledger(contributor).id)
  end

  def line_for(snapshot, contributor)
    snapshot.lines.find { |line| line["contributor_id"] == contributor.id }
  end

  def refused(pass: @pass, today: TODAY)
    assert_raises(Mso::MonthlyRun::Refused) { run!(pass: pass, today: today) }
  end

  def assert_nothing_written
    assert_equal 0, MsoSnapshot.where(invoice_pass_id: @pass.id).count
    assert_equal 0, MsoTrueup.with_deleted.where(invoice_pass_id: @pass.id).count
  end

  # --- what a run records -----------------------------------------------------

  test "the snapshot records every input and output of the run" do
    snapshot = run!(run_by: mso_admin)

    assert snapshot.current?
    assert_equal @pass.id, snapshot.invoice_pass_id
    assert_equal @sanctuary_pass.id, snapshot.sanctuary_invoice_pass_id
    assert_equal mso_admin, snapshot.created_by
    assert_equal BigDecimal("100000"), snapshot.fee_income
    assert_equal "20000.0", snapshot.benchmark_average
    assert_equal [3, 3, false], [snapshot.configured_n, snapshot.counted, snapshot.small_sample]
    assert_equal %w[30000.0 20000.0 10000.0], snapshot.benchmark_members.map { |member| member["amount"] }
    assert_equal [], snapshot.excluded_without_login
    assert_equal BigDecimal("0.55"), snapshot.cap_percentage
    assert_equal BigDecimal("55000"), snapshot.cap
    assert_equal "43000.0", snapshot.total_calculated
    assert_equal BigDecimal("43000"), snapshot.total_trueup
    assert_equal BigDecimal("43000"), snapshot.total_trueup_as_billed
    assert_not snapshot.over_cap?
    assert_not snapshot.invalidated?
    assert_equal "0.0", snapshot.reconciliation["variance"]
    assert_equal ["9001"], snapshot.reconciliation["invoices"].map { |invoice| invoice["qbo_id"] }
    assert_equal [], snapshot.drift
    assert snapshot.fee_collected?

    assert_equal(
      {
        "mso_role_period_id" => @principal_role.id, "contributor_id" => @principal.id,
        "ledger_id" => garden3d_ledger(@principal).id, "tier" => "principal", "title" => "Founder",
        "multiplier" => "1.15", "started_at" => "2090-01-01", "ended_at" => nil,
        "already_earned" => "0.0", "earned_by_ledger" => {},
        "calculated" => "23000.0", "final" => "23000.0", "reduction" => "0.0", "trueup" => "23000.0",
        "trueup_before_rounding" => "23000.0"
      },
      line_for(snapshot, @principal),
    )
    assert_equal 2, snapshot.lines.size
  end

  test "each executive gets one unaccepted true-up on their garden3d ledger" do
    snapshot = run!

    chief = trueup_for(@chief)
    principal = trueup_for(@principal)
    assert_equal [BigDecimal("20000"), BigDecimal("23000")], [chief.amount, principal.amount]
    assert_equal [false, false], [chief.accepted?, principal.accepted?]
    assert_equal [snapshot.id, snapshot.id], [chief.mso_snapshot_id, principal.mso_snapshot_id]
    assert_equal @chief_role.id, chief.mso_role_period_id
    assert_equal garden3d.id, chief.ledger.enterprise_id
    assert_equal Date.new(2093, 5, 31), chief.payment_date
    assert_match(/MSO true-up for May 2093/, chief.description)
    assert_match(/Chief \(Operations\), 1\.0x/, chief.description)
    assert_match(/\$20,000\.00/, chief.description)
    assert_equal 2, MsoTrueup.where(invoice_pass_id: @pass.id).count
  end

  test "the benchmark average is stored unrounded" do
    pay(@top, "0.01") # the top three now total 60,000.01

    snapshot = run!

    live = Mso::Benchmark.for_month(MONTH).average
    assert_equal live, BigDecimal(snapshot.benchmark_average)
    assert_match(/\A20000\.003333333/, snapshot.benchmark_average)
    assert_match(/\A20000\.003333333/, line_for(snapshot, @chief)["calculated"])
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
  end

  test "what a person already earned is netted across all their ledgers" do
    pay(@chief, 5_000)
    pay(@chief, 2_000, enterprise: enterprises(:one))

    snapshot = run!

    line = line_for(snapshot, @chief)
    assert_equal "7000.0", line["already_earned"]
    assert_equal(
      {
        Ledger.find_by!(enterprise: @sanctuary, contributor: @chief).id.to_s => "5000.0",
        Ledger.find_by!(enterprise: enterprises(:one), contributor: @chief).id.to_s => "2000.0",
      },
      line["earned_by_ledger"],
    )
    assert_equal BigDecimal("13000"), trueup_for(@chief).amount
    # The cap is a ceiling: one person's earnings change nobody else's true-up.
    assert_equal BigDecimal("23000"), trueup_for(@principal).amount
  end

  test "someone who out-earned their target gets no true-up, no clawback and no row" do
    pay(@chief, 25_000)

    snapshot = run!

    assert_nil trueup_for(@chief)
    line = line_for(snapshot, @chief)
    assert_equal ["20000.0", "0.0"], [line["final"], line["trueup"]]
    assert_equal [garden3d_ledger(@principal).id], snapshot.expected_ledger_ids
    assert_equal BigDecimal("23000"), snapshot.total_trueup
  end

  test "over the cap, every line is reduced pro rata and the true-ups sum to the cap exactly" do
    charge_fee("60000.0") # cap 33,000 against 43,000 calculated

    snapshot = run!

    assert_equal BigDecimal("33000"), snapshot.cap
    assert_equal [BigDecimal("15348.84"), BigDecimal("17651.16")],
      [trueup_for(@chief).amount, trueup_for(@principal).amount]
    assert_equal "4651.16", line_for(snapshot, @chief)["reduction"]
    assert_equal BigDecimal("33000"), snapshot.total_trueup
  end

  test "once everyone accepts, the true-ups are payable" do
    run!
    chief = trueup_for(@chief)
    chief.toggle_acceptance!

    assert_equal false, MsoTrueup.find(chief.id).payable?

    trueup_for(@principal).toggle_acceptance!

    assert_equal true, MsoTrueup.find(chief.id).payable?
  end

  # --- running a month again ----------------------------------------------------

  test "running an unchanged month again does not net a true-up against itself" do
    run!
    first = trueup_for(@chief)

    snapshot = run!

    again = trueup_for(@chief)
    assert_equal first.id, again.id
    assert_equal BigDecimal("20000"), again.amount
    assert_equal "0.0", line_for(snapshot, @chief)["already_earned"]
  end

  test "a re-run supersedes the snapshot and keeps the old one's figures" do
    first = run!
    first_lines = first.lines.deep_dup
    pay(@chief, 1_000)

    second = run!

    first.reload
    assert_not first.current?
    assert_equal second, first.superseded_by
    assert_equal first_lines, first.lines
    assert_equal "20000.0", line_for(first, @chief)["trueup"]
    assert_equal "19000.0", line_for(second, @chief)["trueup"]
    assert_equal [second.id], MsoSnapshot.current.where(invoice_pass_id: @pass.id).pluck(:id)
    assert_equal second.id, trueup_for(@chief).mso_snapshot_id
    assert_equal second.id, trueup_for(@principal).mso_snapshot_id
  end

  test "an acceptance survives a re-run that leaves the amount alone, and is cleared by one that changes it" do
    run!
    trueup_for(@chief).toggle_acceptance!
    trueup_for(@principal).toggle_acceptance!

    run!
    assert trueup_for(@chief).accepted?
    assert trueup_for(@principal).accepted?

    pay(@chief, 1_000)
    run!

    chief = trueup_for(@chief)
    assert_equal BigDecimal("19000"), chief.amount
    assert_not chief.accepted?
    assert trueup_for(@principal).accepted?
  end

  test "a true-up with a QuickBooks bill is never altered; the difference is recorded as drift" do
    run!
    locked = trueup_for(@chief)
    locked.update_columns(accepted_at: Time.current, qbo_bill_id: "88")
    pay(@chief, 1_000)

    snapshot = run!

    locked.reload
    assert_equal BigDecimal("20000"), locked.amount
    assert locked.accepted?
    assert_equal "88", locked.qbo_bill_id
    assert_equal snapshot.id, locked.mso_snapshot_id
    assert_equal "19000.0", line_for(snapshot, @chief)["trueup"]
    assert_equal [{ "mso_trueup_id" => locked.id, "ledger_id" => locked.ledger_id,
                    "billed_amount" => "20000.0", "computed_amount" => "19000.0" }], snapshot.drift

    # And a locked true-up is not removed when its executive leaves the roster.
    @chief_role.update!(ended_at: Date.new(2093, 4, 30))
    after_leaving = run!
    assert_equal BigDecimal("20000"), MsoTrueup.find(locked.id).amount
    assert_equal ["0.0"], after_leaving.drift.map { |entry| entry["computed_amount"] }
  end

  test "a true-up no longer owed is removed, and comes back as the same row if it is owed again" do
    run!
    original = trueup_for(@chief)
    original.toggle_acceptance!
    @chief_role.update!(ended_at: Date.new(2093, 4, 30))

    without = run!

    assert_nil trueup_for(@chief)
    assert MsoTrueup.with_deleted.find(original.id).deleted_at.present?
    assert_equal [@principal.id], without.lines.map { |line| line["contributor_id"] }

    @chief_role.update!(ended_at: nil)
    run!

    restored = trueup_for(@chief)
    assert_equal original.id, restored.id
    assert_nil restored.deleted_at
    assert_equal BigDecimal("20000"), restored.amount
    assert_not restored.accepted?, "a restored true-up must be accepted afresh"
    assert_equal 2, MsoTrueup.with_deleted.where(invoice_pass_id: @pass.id).count
  end

  test "a month with nobody on the roster records the benchmark and pays nobody" do
    MsoRolePeriod.where(id: [@chief_role.id, @principal_role.id]).delete_all

    snapshot = run!

    assert_equal [], snapshot.lines
    assert_equal "20000.0", snapshot.benchmark_average
    assert_equal "0.0", snapshot.total_calculated
    assert_equal 0, MsoTrueup.where(invoice_pass_id: @pass.id).count
  end

  # --- refusals -------------------------------------------------------------------

  test "two role periods for one person in the month are refused, naming them" do
    second = MsoRolePeriod.new(contributor: @chief, tier: :svp, title: "Second", started_at: Date.new(2093, 1, 1))
    second.save!(validate: false)

    error = refused

    assert_match(/contributor #{@chief.id}/, error.message)
    assert_match(/#{@chief_role.id}, #{second.id}/, error.message)
    assert_nothing_written
  end

  test "it refuses when Sanctuary has no pass for the month" do
    other = garden3d_pass(Date.new(2093, 7, 1))

    error = refused(pass: other, today: Date.new(2093, 8, 10))

    assert_match(/Sanctuary Computer Inc has no invoice pass for July 2093/, error.message)
  end

  test "it refuses while Sanctuary's pass is not complete" do
    @sanctuary_pass.update_columns(completed_at: nil)

    assert_match(/has not finished invoicing/, refused.message)
    assert_nothing_written
  end

  test "it refuses when Sanctuary's pass has no contributor payouts yet" do
    ContributorPayout.where(invoice_tracker_id: @tracker.id).each(&:destroy)

    assert_match(/no contributor payouts/, refused.message)
    assert_nothing_written
  end

  test "it refuses a month that has not ended" do
    assert_match(/has not ended/, refused(today: Date.new(2093, 5, 31)).message)
    assert_nothing_written
    assert_nothing_raised { run!(today: Date.new(2093, 6, 1)) }
  end

  test "it refuses any pass that is not a runnable garden3d month" do
    assert_match(/garden3d, LLC's pass/, refused(pass: @sanctuary_pass).message)

    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START
    early = InvoicePass.find_or_create_by!(enterprise: garden3d, start_of_month: start - 1.month) { |p| p.data = {} }
    assert_match(/#{start.strftime('%B %Y')} onward/, refused(pass: early).message)
    assert_equal false, Mso::MonthlyRun.runnable?(early)

    legacy = garden3d_pass(Date.new(2093, 8, 1))
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Legacy #{SecureRandom.hex(3)}")
    InvoiceTracker.create!(invoice_pass: legacy, forecast_client: client, qbo_account: garden3d_qbo_account,
                           blueprint: { "lines" => { "Line" => { "quantity" => 1, "unit_price" => 1 } } })
    assert_match(/Forecast-driven tracker/, refused(pass: legacy, today: Date.new(2093, 9, 10)).message)
    assert_equal false, Mso::MonthlyRun.runnable?(legacy)

    assert_equal true, Mso::MonthlyRun.runnable?(@pass)
    assert_equal false, Mso::MonthlyRun.runnable?(@sanctuary_pass)
  end

  test "a reconcile variance refuses the run and says how to clear it" do
    charge_fee("100000.0", account_total: "130000.0") # 30,000 in account 4100 that no fee invoice explains

    error = refused

    assert_match(/variance 30000\.0/, error.message)
    assert_match(/attach/i, error.message)
    assert_match(/Managerial Services/, error.message)
    assert_nothing_written
  end

  test "a refused run invalidates the earlier one: nothing stays payable, and only a successful run restores it" do
    first = run!
    trueup_for(@chief).toggle_acceptance!
    trueup_for(@principal).toggle_acceptance!
    assert_equal true, trueup_for(@chief).payable?

    # The month's 4100 row disappears (the fee invoice was voided).
    QboProfitAndLossReport.where(qbo_account_id: garden3d_qbo_account.id, starts_at: MONTH).delete_all
    QboProfitAndLossReport.create!(
      qbo_account: garden3d_qbo_account, starts_at: MONTH, ends_at: MONTH.end_of_month,
      data: { cash: { rows: [] }, accrual: { rows: [["Total Income", "0.0"]] } },
    )

    error = refused

    assert_match(/no account 4100 row/, error.message)
    first.reload
    assert first.current?, "a refused run supersedes nothing"
    assert first.invalidated?
    assert_match(/refused/, first.invalidated_reason)
    assert_not first.fee_collected?
    assert_equal false, trueup_for(@chief).payable?
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount

    # Confirming collection cannot bring it back...
    assert_raises(MsoSnapshot::Unusable) { first.check_collection! }
    assert_equal false, trueup_for(@chief).payable?

    # ...only a run that succeeds can. The amounts did not change, so the
    # acceptances stand.
    charge_fee("100000.0")
    second = run!

    assert_not second.invalidated?
    assert trueup_for(@chief).accepted?
    assert_equal true, trueup_for(@chief).payable?
  end

  test "it asks QuickBooks about collection exactly once, and an uncollected month is not payable" do
    Mso::ManagementFeeInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(false)

    snapshot = run!

    assert_not snapshot.fee_collected?
    trueup_for(@chief).toggle_acceptance!
    trueup_for(@principal).toggle_acceptance!
    assert_equal false, trueup_for(@chief).payable?
  end

  test "it refuses when a fee invoice cannot be read from QuickBooks" do
    Mso::ManagementFeeInvoices.stubs(:collected?)
      .raises(Mso::ManagementFeeInvoices::RefreshFailed, "Could not read the QuickBooks invoice on InvoiceTracker 1")

    assert_match(/Could not read the QuickBooks invoice/, refused.message)
    assert_nothing_written
  end

  test "it refuses when an executive's garden3d ledger is not QuickBooks-bound" do
    garden3d_ledger(@chief).update!(mode: :legacy)

    error = refused

    assert_match(/Ledger #{garden3d_ledger(@chief).id}/, error.message)
    assert_nothing_written
  end

  test "a failure part-way through writes nothing, and marks the previous run invalid" do
    previous = run!
    pay(@chief, 1_000)
    Mso::MonthlyRun.any_instance.stubs(:apply!).raises(RuntimeError, "boom")

    assert_raises(RuntimeError) { run! }

    previous.reload
    assert previous.current?
    assert previous.invalidated?, "a run that blew up says nothing good about the figures before it"
    assert_equal [previous.id], MsoSnapshot.where(invoice_pass_id: @pass.id).pluck(:id)
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
  end

  # --- added by the review -----------------------------------------------------------

  test "a founder true-up for someone on the roster refuses the run, naming it" do
    old_style = Trueup.create!(
      invoice_pass: @sanctuary_pass, amount: "4000", description: "founder true-up",
      ledger: Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @principal),
    )

    error = refused

    assert_match(/Trueup #{old_style.id} \(contributor #{@principal.id}/, error.message)
    assert_match(/delete it/, error.message)
    assert_match(/QuickBooks bill/, error.message)
    assert_nothing_written

    old_style.destroy
    assert_nothing_raised { run! }
    assert_equal BigDecimal("23000"), trueup_for(@principal).amount
  end

  test "one month's true-up does not reduce the next month's" do
    run!
    trueup_for(@chief).toggle_acceptance!

    june = Date.new(2093, 6, 1)
    june_sanctuary = sanctuary_pass(june)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "June Client #{SecureRandom.hex(3)}")
    june_tracker = InvoiceTracker.create!(invoice_pass: june_sanctuary, forecast_client: client,
                                          qbo_account: Enterprise.find(@sanctuary.id).qbo_account)
    { "ja" => 30_000, "jb" => 20_000, "jc" => 10_000 }.each do |tag, amount|
      pay(mso_person("earner-#{tag}"), amount, tracker: june_tracker)
    end
    june_pass = garden3d_pass(june)
    attach_invoice(fee_tracker(june_pass, @payer), qbo_id: "9002", total: "100000.0", balance: "0.0", sent: true)
    fee_report(june, "100000.0")

    snapshot = run!(pass: june_pass, today: Date.new(2093, 7, 10))

    line = line_for(snapshot, @chief)
    assert_equal "0.0", line["already_earned"], "May's true-up is dated 31 May and is May's income"
    assert_equal "20000.0", line["trueup"]
    june_trueup = MsoTrueup.find_by!(invoice_pass_id: june_pass.id, ledger_id: garden3d_ledger(@chief).id)
    assert_equal BigDecimal("20000"), june_trueup.amount
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
    assert trueup_for(@chief).accepted?, "and running June leaves May alone"
  end

  test "a month can be run long after it ended, and is still dated its own last day" do
    snapshot = run!(today: Date.new(2094, 2, 14))

    chief = trueup_for(@chief)
    assert_equal BigDecimal("20000"), chief.amount
    assert_equal Date.new(2093, 5, 31), chief.payment_date
    assert_equal Date.new(2093, 5, 31), chief.bill_txn_date
    assert_equal MONTH, snapshot.month
  end

  test "an earned figure with a fraction of a cent gives a whole-cent true-up that a re-run does not disturb" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @chief)
    # Profit shares are stored unrounded; this is a real one's amount.
    Mso::MonthlyRun.stubs(:already_earned).returns({})
    Mso::MonthlyRun.stubs(:already_earned).with(has_entry(contributor_id: @chief.id))
      .returns({ sanctuary_ledger.id => BigDecimal("179.8089646737429") })

    snapshot = run!

    chief = trueup_for(@chief)
    line = line_for(snapshot, @chief)
    assert_equal BigDecimal("19820.19"), chief.amount, "20000 - 179.8089646737429, rounded DOWN"
    assert_equal "19820.19", line["trueup"]
    assert_equal "19820.1910353262571", line["trueup_before_rounding"]
    assert_equal BigDecimal("42820.19"), snapshot.total_trueup

    chief.toggle_acceptance!(expected_amount: "19820.19")
    second = run!

    again = trueup_for(@chief)
    assert_equal chief.id, again.id
    assert again.accepted?, "the same whole-cent amount must not clear the acceptance"
    assert_equal BigDecimal("19820.19"), again.amount
    assert_equal [], second.drift
  end

  test "a true-up of less than a cent creates no row and expects no acceptance" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @chief)
    Mso::MonthlyRun.stubs(:already_earned).returns({})
    Mso::MonthlyRun.stubs(:already_earned).with(has_entry(contributor_id: @chief.id))
      .returns({ sanctuary_ledger.id => BigDecimal("19999.996") })

    snapshot = run!

    assert_nil trueup_for(@chief)
    line = line_for(snapshot, @chief)
    assert_equal "0.0", line["trueup"]
    assert_equal "0.004", line["trueup_before_rounding"]
    assert_equal [garden3d_ledger(@principal).id], snapshot.expected_ledger_ids
    assert_equal BigDecimal("23000"), snapshot.total_trueup
  end

  test "preview computes the same amounts, writes nothing and asks QuickBooks nothing" do
    Mso::ManagementFeeInvoices.stubs(:collected?).raises(RuntimeError, "preview asked QuickBooks")

    amounts = Mso::MonthlyRun.preview(invoice_pass: @pass, today: TODAY)

    assert_equal(
      { garden3d_ledger(@chief).id => BigDecimal("20000"), garden3d_ledger(@principal).id => BigDecimal("23000") },
      amounts,
    )
    assert_nothing_written

    # It refuses where a run would, and a refused preview invalidates nothing.
    Mso::ManagementFeeInvoices.stubs(:collected?).returns(true)
    first = run!
    charge_fee("100000.0", account_total: "130000.0")
    assert_raises(Mso::MonthlyRun::Refused) { Mso::MonthlyRun.preview(invoice_pass: @pass, today: TODAY) }
    assert_not first.reload.invalidated?
  end

  test "a run takes the pass's row lock, and a second run replaces the first instead of standing beside it" do
    InvoicePass.any_instance.expects(:lock!).at_least(2)

    run!
    second = run!

    assert_equal [second.id], MsoSnapshot.current.where(invoice_pass_id: @pass.id).pluck(:id)
    assert_equal 2, MsoSnapshot.where(invoice_pass_id: @pass.id).count
    assert_equal 2, MsoTrueup.where(invoice_pass_id: @pass.id).count
    # The backstop if two runs ever got past the lock: the database refuses a
    # second current snapshot for the pass.
    assert_raises(ActiveRecord::RecordNotUnique) { mso_snapshot(@pass) }
  end

  test "a billed true-up plus recomputed ones can exceed a cap that has fallen; the snapshot says so" do
    run!
    trueup_for(@chief).update_columns(accepted_at: Time.current, qbo_bill_id: "88")
    charge_fee("40000.0") # the cap is now 22,000

    snapshot = run!

    assert_equal BigDecimal("22000"), snapshot.cap
    assert_equal BigDecimal("22000"), snapshot.total_trueup, "what this run computed: 10,232.56 + 11,767.44"
    assert_equal BigDecimal("31767.44"), snapshot.total_trueup_as_billed, "the billed 20,000 stands: + 11,767.44"
    assert snapshot.over_cap?
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
    assert_equal BigDecimal("11767.44"), trueup_for(@principal).amount
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/mso/monthly_run_test.rb
```

Expected: 33 runs, 33 errors, each `NameError: uninitialized constant Mso::MonthlyRun`.

- [ ] **Step 3: Write the service**

Create `app/services/mso/monthly_run.rb`:

```ruby
module Mso
  # Computes one month's MSO executive compensation and writes it down: an
  # immutable MsoSnapshot of every input and output, and one MsoTrueup on the
  # garden3d ledger of each executive who is owed money.
  #
  #   Mso::MonthlyRun.call(invoice_pass: garden3ds_pass, run_by: admin)
  #   Mso::MonthlyRun.preview(invoice_pass: garden3ds_pass)  # computes, writes nothing
  #
  # NOTHING SCHEDULED CALLS .call. It is reached from an admin's click on
  # garden3d's pass. It makes one QuickBooks READ per management fee invoice
  # (through Mso::ManagementFeeInvoices.collected?) and no QuickBooks write.
  # It pays nobody: a true-up becomes payable only after its executive
  # accepts it, every other executive accepts theirs, and the fee is confirmed
  # collected; and it reaches QuickBooks only when an admin syncs it from the
  # Money page, where it is checked against a fresh computation first.
  #
  # Running a month again is safe and is how a changed payout is picked up:
  # the snapshot is superseded, not edited, and each true-up is updated in
  # place. A true-up that already has a QuickBooks bill is never changed; if
  # its figure moved, the difference is recorded on the snapshot as drift.
  class MonthlyRun
    # The run would not start, or would not finish. The message is written to
    # be shown to an admin and says what to do.
    class Refused < StandardError; end

    ZERO = BigDecimal("0")

    Planned = Struct.new(:period, :ledger, :earned_by_ledger, :output, keyword_init: true) do
      def already_earned
        earned_by_ledger.values.sum(BigDecimal("0"))
      end

      # What is actually owed: the calculator's true-up rounded DOWN to the
      # cent. Earned income is not always whole cents (profit shares are
      # stored unrounded), so `final - earned` can carry a fraction of a cent.
      # Every use of a true-up amount goes through here, or a re-run would see
      # "a different amount" each time and clear the acceptance.
      def amount
        output.trueup.floor(2)
      end
    end

    Computation = Struct.new(:sanctuary_pass, :reconciliation, :benchmark, :result, :planned, :existing,
                             keyword_init: true)

    class << self
      def call(invoice_pass:, run_by: nil, today: Date.today)
        new(invoice_pass: invoice_pass, run_by: run_by, today: today).call
      end

      # What a run would produce right now, without writing anything and
      # without calling QuickBooks: { garden3d ledger id => true-up amount }.
      # Reads the invoice mirrors as stored, so refresh them first if that
      # matters (MsoSnapshot#check_collection! does). Raises Refused exactly
      # where a run would. Used to check a true-up is still right at the
      # moment its QuickBooks bill is first created.
      def preview(invoice_pass:, today: Date.today)
        new(invoice_pass: invoice_pass, run_by: nil, today: today).preview
      end

      # May a run be offered for this pass at all? (Whether it then succeeds
      # depends on the month's state; see #call.)
      def runnable?(invoice_pass)
        invoice_pass.management_fee? &&
          invoice_pass.start_of_month >= Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START &&
          !invoice_pass.legacy_forecast_trackers?
      end

      # One role period per person per month is a model validation only; the
      # database does not enforce it. Two would be two payments.
      def assert_one_period_per_person!(role_periods)
        doubled = role_periods.group_by(&:contributor_id).select { |_, periods| periods.size > 1 }
        return if doubled.empty?

        detail = doubled.map do |contributor_id, periods|
          "contributor #{contributor_id} (role periods #{periods.map(&:id).join(', ')})"
        end
        raise Refused, "More than one MSO role period is active in the month for #{detail.join('; ')}. " \
                       "End or delete the extra period on the MSO Roles page, then run again."
      end

      # What a person has already earned in the month, per ledger, across ALL
      # their ledgers (netting is not per company). Ledgers with nothing are
      # left out. `excluding:` takes the month's own MSO true-ups: they are
      # qualifying income, and counted here a re-run would net each true-up
      # against itself.
      def already_earned(contributor_id:, month:, excluding: [])
        Ledger.where(contributor_id: contributor_id).order(:id).each_with_object({}) do |ledger, by_ledger|
          amount = Ledger::QualifyingIncome.for(ledger: ledger, month: month, excluding: excluding)
          by_ledger[ledger.id] = amount unless amount.zero?
        end
      end

      # NIGHTLY, DATABASE ONLY. garden3d's stored P&L is re-fetched every
      # night by the existing sync; this compares what it now says for account
      # 4100 with the fee income each live snapshot was computed from, and
      # invalidates a snapshot whose fee has moved (an invoice voided, edited
      # or added after the run). It never fetches: a month with no stored
      # report is skipped. Returns the ids it invalidated.
      def invalidate_snapshots_whose_fee_moved!
        return [] unless MsoTrueup.schema_ready?

        garden3d_account_ids = QboAccount.where(enterprise_id: Enterprise.garden3d.id).pluck(:id)
        MsoSnapshot.current.where(invalidated_at: nil).includes(:invoice_pass).filter_map do |snapshot|
          month = snapshot.invoice_pass.start_of_month
          stored = QboProfitAndLossReport
            .where(qbo_account_id: garden3d_account_ids, starts_at: month, ends_at: month.end_of_month).exists?
          next unless stored # Mso::ManagementFeeIncome would FETCH a missing report; never do that here

          now_reads =
            begin
              Mso::ManagementFeeIncome.for_month(month).to_s("F")
            rescue Mso::ManagementFeeIncome::Error
              "no readable figure"
            end
          next if now_reads == snapshot.fee_income.to_s("F")

          snapshot.invalidate!("Account 4100 now reads #{now_reads} for #{snapshot.invoice_pass.invoice_month}; " \
                               "this run used #{snapshot.fee_income.to_s('F')}. Run the month again.")
          snapshot.id
        end
      end
    end

    def initialize(invoice_pass:, run_by:, today:)
      # A fresh copy: the caller's may carry stale associations.
      @pass = InvoicePass.find(invoice_pass.id)
      @month = @pass.start_of_month
      @run_by = run_by
      @today = today
    end

    def call
      run
    rescue Refused => e
      # Fail closed. Whatever stopped this run (a voided invoice, a variance,
      # a doubled roster row) may also mean the previous run's figures are no
      # longer right. The current snapshot is marked invalid: nothing from it
      # is payable, and Check collection cannot bring it back. Only a run that
      # succeeds (and so writes a new snapshot) clears this.
      invalidate_current!("A later run on #{@today} was refused: #{e.message}")
      raise
    rescue StandardError => e
      invalidate_current!("A later run on #{@today} failed with #{e.class}. Run the month again.")
      raise
    end

    def preview
      assert_runnable!
      computation = compute(sanctuary_pass!, reconcile!)
      computation.planned.to_h { |plan| [plan.ledger.id, plan.amount] }
    end

    private

    def run
      assert_runnable!
      sanctuary_pass = sanctuary_pass!
      # QuickBooks reads happen here, outside the transaction below.
      collected = fee_collected!
      reconciliation = reconcile!

      InvoicePass.transaction do
        # Serialises two runs of one month: the second waits here, then finds
        # the first's snapshot and supersedes it. The partial unique index on
        # mso_snapshots is the backstop.
        @pass.lock!

        computation = compute(sanctuary_pass, reconciliation)
        snapshot = write_snapshot!(computation, collected)
        apply!(snapshot, computation)
        snapshot
      end
    end

    # Everything a run reads from the database, and the calculation. Writes
    # nothing and calls nothing outside the database.
    def compute(sanctuary_pass, reconciliation)
      roster = roster!
      refuse_other_trueups!(roster)
      benchmark = Mso::Benchmark.for_month(@month)
      existing = MsoTrueup.where(invoice_pass_id: @pass.id).order(:id).to_a
      earned = roster.to_h do |period, _ledger|
        [period.contributor_id,
         self.class.already_earned(contributor_id: period.contributor_id, month: @month, excluding: existing)]
      end

      result = Mso::Compensation.call(
        benchmark_average: benchmark.average,
        lines: roster.map do |period, _ledger|
          Mso::Compensation::Line.new(
            key: period.contributor_id,
            multiplier: period.tier_multiplier,
            already_earned: earned.fetch(period.contributor_id).values.sum(ZERO),
          )
        end,
        fee_income: reconciliation[:account_total],
        cap_percentage: Mso::Compensation::DEFAULT_CAP_PERCENTAGE,
      )
      outputs = result.outputs.index_by(&:key)
      planned = roster.map do |period, ledger|
        Planned.new(period: period, ledger: ledger, earned_by_ledger: earned.fetch(period.contributor_id),
                    output: outputs.fetch(period.contributor_id))
      end

      Computation.new(sanctuary_pass: sanctuary_pass, reconciliation: reconciliation, benchmark: benchmark,
                      result: result, planned: planned, existing: existing)
    end

    # --- refusals -----------------------------------------------------------

    def assert_runnable!
      unless @pass.management_fee?
        raise Refused, "MSO compensation is run on #{Enterprise::GARDEN3D_NAME}'s pass; InvoicePass " \
                       "#{@pass.id} belongs to #{@pass.enterprise.name}."
      end
      if @pass.legacy_forecast_trackers?
        raise Refused, "#{@pass.invoice_month}'s pass holds a Forecast-driven tracker from before passes " \
                       "were per-company. MSO compensation is not run for that month."
      end
      start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START
      if @month < start
        raise Refused, "MSO compensation is run from #{start.strftime('%B %Y')} onward; " \
                       "#{@pass.invoice_month} is before that."
      end
      # garden3d's P&L for an unfinished month is whatever the last nightly
      # sync saw: a partial fee, and so a partial cap.
      if @today <= @month.end_of_month
        raise Refused, "#{@pass.invoice_month} has not ended. Its management fee income is still a " \
                       "partial figure; run it after the month closes."
      end
    end

    # Sanctuary's pass must exist, be complete and have payouts. NOT "every
    # payout accepted": one person who never clicks Accept would then freeze
    # every executive's pay. A payout that changes later is picked up by
    # running the month again, and a true-up is checked against a fresh
    # computation before its bill is created (MsoTrueup#sync_qbo_bill!).
    def sanctuary_pass!
      sanctuary = Enterprise.sanctuary
      pass = InvoicePass.find_by(enterprise_id: sanctuary.id, start_of_month: @month)
      if pass.nil?
        raise Refused, "#{sanctuary.name} has no invoice pass for #{@pass.invoice_month}, so there are no " \
                       "payouts to measure the benchmark or anyone's earnings from."
      end
      unless pass.complete?
        raise Refused, "#{sanctuary.name}'s pass for #{@pass.invoice_month} has not finished invoicing."
      end
      has_payouts = ContributorPayout.joins(:invoice_tracker)
        .where(invoice_trackers: { invoice_pass_id: pass.id }).exists?
      unless has_payouts
        raise Refused, "#{sanctuary.name}'s pass for #{@pass.invoice_month} has no contributor payouts yet. " \
                       "Run this after payouts have been calculated."
      end
      pass
    end

    # ONE call per run. It refreshes every attached fee invoice from
    # QuickBooks (a read each) and raises if any cannot be read.
    def fee_collected!
      Mso::ManagementFeeInvoices.collected?(invoice_pass: @pass)
    rescue Mso::ManagementFeeInvoices::Error => e
      raise Refused, "#{e.message}. Nothing was written; try again."
    end

    # In a run this follows fee_collected!, so it compares against fresh
    # invoices. The fee income is read here, once, before anything is written.
    # There is no override: the message says exactly what was compared and
    # what to do about each cause.
    def reconcile!
      Mso::ManagementFeeIncome.reconcile!(@month)
    rescue Mso::ManagementFeeIncome::RowMissing => e
      raise Refused, "#{e.message} MSO compensation is not run for a month with no management fee income. " \
                     "If a fee was charged for #{@pass.invoice_month}, check that it posts to account 4100 " \
                     "in garden3d's QuickBooks; Stacks sees the change after the nightly sync."
    rescue Mso::ManagementFeeIncome::VarianceError => e
      raise Refused, "#{e.message}. Nothing was written. To clear this: (1) if a paying company's invoice " \
                     "is missing from the list above, attach it to that company's tracker on this pass; " \
                     "(2) if an invoice's Managerial Services figure is lower than its total and the " \
                     "difference is fee, Finance moves that line to the " \
                     "#{Mso::ManagementFeeInvoices::ITEM_NAME} item in QuickBooks; (3) if account 4100 " \
                     "holds income that is not a management fee, Finance moves it to another account, and " \
                     "Stacks sees that after the nightly sync; (4) if an invoice is dated in another month, " \
                     "Finance corrects the date. Then run again."
    rescue Mso::ManagementFeeIncome::Error => e
      raise Refused, "#{e.message}. Nothing was written."
    end

    # [[MsoRolePeriod, garden3d Ledger], ...], one pair per executive.
    def roster!
      periods = MsoRolePeriod.active_during(@month).order(:id).to_a
      self.class.assert_one_period_per_person!(periods)

      periods.map do |period|
        # find_by, not find_or_create: computing must not write. Every
        # contributor has a ledger per company (Ledger.ensure_all!).
        ledger = Ledger.find_by(enterprise_id: @pass.enterprise_id, contributor_id: period.contributor_id)
        if ledger.nil?
          raise Refused, "Contributor #{period.contributor_id} has no #{@pass.enterprise.name} ledger."
        end
        unless ledger.qbo_bound?
          # The Money page lists only QuickBooks-bound ledgers; a true-up on
          # any other would be invisible there and never paid.
          raise Refused, "Ledger #{ledger.id} (contributor #{period.contributor_id} on " \
                         "#{@pass.enterprise.name}) is not QuickBooks-bound, so a true-up on it could not " \
                         "be paid. Migrate the ledger, then run again."
        end
        [period, ledger]
      end
    end

    # A founder true-up (Trueup) for someone on the roster, in this month, is
    # the old arrangement paying for the same month. It is uncapped money on
    # another company's ledger, already billed in that company's QuickBooks by
    # the nightly sync. Netting against it would let it stand outside the cap,
    # so the run stops until a person has removed it.
    def refuse_other_trueups!(roster)
      contributor_ids = roster.map { |period, _ledger| period.contributor_id }
      rows = Trueup.joins(:ledger, :invoice_pass)
        .where(ledgers: { contributor_id: contributor_ids }, invoice_passes: { start_of_month: @month })
        .order("trueups.id").pluck("trueups.id", "ledgers.contributor_id", "trueups.ledger_id")
      return if rows.empty?

      detail = rows.map { |id, contributor_id, ledger_id| "Trueup #{id} (contributor #{contributor_id}, ledger #{ledger_id})" }
      raise Refused, "#{@pass.invoice_month} already has a founder true-up for someone on the MSO roster: " \
                     "#{detail.join('; ')}. The MSO true-up replaces it, so it has to go first. Open it from " \
                     "that ledger and delete it: that also deletes its QuickBooks bill, and is refused if " \
                     "the bill has any payment. If the bill has been paid, that month was paid the old way; " \
                     "void the payment in QuickBooks first, or end the role period so it starts the " \
                     "following month. Then run again."
    end

    # --- writing ------------------------------------------------------------

    # A true-up with a QuickBooks bill is never rewritten (see apply!). Where
    # this run's figure differs from what was billed, say so on the snapshot.
    def drift_for(computation)
      computed = computation.planned.to_h { |plan| [plan.ledger.id, plan.amount] }
      computation.existing.select(&:locked?).filter_map do |row|
        amount = computed.fetch(row.ledger_id, ZERO)
        next if amount == row.amount

        { "mso_trueup_id" => row.id, "ledger_id" => row.ledger_id,
          "billed_amount" => row.amount.to_s("F"), "computed_amount" => amount.to_s("F") }
      end
    end

    # What will actually be owed once this run is applied: a billed row keeps
    # its billed amount whatever was computed. If the fee fell after a bill
    # was written this can exceed the cap; the snapshot page warns when it does.
    def total_as_billed(computation)
      locked = computation.existing.select(&:locked?).index_by(&:ledger_id)
      on_roster = computation.planned.sum(ZERO) do |plan|
        locked.delete(plan.ledger.id)&.amount || plan.amount
      end
      on_roster + locked.values.sum(ZERO, &:amount)
    end

    def write_snapshot!(computation, collected)
      now = Time.current
      result = computation.result
      benchmark = computation.benchmark
      previous = MsoSnapshot.current.find_by(invoice_pass_id: @pass.id)
      # Before the insert: the partial unique index allows one current row.
      previous&.update_columns(superseded_at: now)

      snapshot = MsoSnapshot.create!(
        invoice_pass: @pass,
        sanctuary_invoice_pass: computation.sanctuary_pass,
        created_by: @run_by,
        fee_income: computation.reconciliation[:account_total],
        # to_s("F"), not to_s: the default is scientific notation ("0.2e5").
        benchmark_average: benchmark.average.to_s("F"),
        configured_n: benchmark.configured_n,
        counted: benchmark.counted,
        small_sample: benchmark.small_sample,
        cap_percentage: Mso::Compensation::DEFAULT_CAP_PERCENTAGE,
        cap: result.cap,
        total_calculated: result.total_calculated.to_s("F"),
        total_trueup: computation.planned.sum(ZERO, &:amount),
        total_trueup_as_billed: total_as_billed(computation),
        benchmark_members: amounts_json(benchmark.members),
        excluded_without_login: amounts_json(benchmark.excluded_without_login),
        lines: computation.planned.map { |plan| line_json(plan) },
        drift: drift_for(computation),
        reconciliation: reconciliation_json(computation.reconciliation),
        fee_collected_at: collected ? now : nil,
      )
      previous&.update_columns(superseded_by_id: snapshot.id)
      snapshot
    end

    def apply!(snapshot, computation)
      # Consumed below: what is left after the roster has been walked belongs
      # to people no longer on it.
      existing_by_ledger = computation.existing.index_by(&:ledger_id)
      computation.planned.each do |plan|
        row = existing_by_ledger.delete(plan.ledger.id)
        if plan.amount.positive?
          write_trueup!(snapshot, plan, row)
        elsif row
          remove!(snapshot, row)
        end
      end
      existing_by_ledger.each_value { |row| remove!(snapshot, row) }
    end

    def write_trueup!(snapshot, plan, row)
      amount = plan.amount
      pointers = { mso_snapshot_id: snapshot.id, mso_role_period_id: plan.period.id }

      # No live row: restore the newest soft-deleted one rather than insert,
      # so the row keeps its id.
      row ||= MsoTrueup.with_deleted
        .where(ledger_id: plan.ledger.id, invoice_pass_id: @pass.id)
        .where.not(deleted_at: nil).order(:id).last

      if row
        # The same row lock MsoTrueup#toggle_acceptance! and #sync_qbo_bill!
        # take, and a reload under it. Without this an Accept clicked while
        # the run is writing could land on the new amount unseen, or a bill
        # could be created between our read and our write.
        row.lock!
        if row.locked?
          # Its amount is in QuickBooks and may have been paid. Point it at
          # the new snapshot and leave everything else alone.
          row.update_columns(pointers)
          return
        end
      else
        row = MsoTrueup.new(ledger: plan.ledger, invoice_pass: @pass)
      end

      changed = row.new_record? || row.deleted_at.present? || row.amount != amount
      row.assign_attributes(pointers.merge(amount: amount, description: description_for(plan), deleted_at: nil))
      # They accepted a different number. Saved in the same statement as the
      # new amount, under the lock.
      row.accepted_at = nil if changed
      row.save!
    end

    def remove!(snapshot, row)
      row.lock!
      if row.locked?
        row.update_columns(mso_snapshot_id: snapshot.id)
      else
        # A soft delete (acts_as_paranoid). The row has no QuickBooks bill, so
        # its before_destroy has nothing to detach.
        raise "MsoTrueup #{row.id} could not be removed" unless row.destroy
      end
    end

    # After the transaction has rolled back. update_all: no callbacks, and the
    # figure-immutability validation is not in play.
    def invalidate_current!(reason)
      return unless MsoTrueup.schema_ready?

      MsoSnapshot.current.where(invoice_pass_id: @pass.id).update_all(
        invalidated_at: Time.current, invalidated_reason: reason.to_s.truncate(2000), fee_collected_at: nil,
      )
    end

    # --- what is stored -------------------------------------------------------

    def line_json(plan)
      period = plan.period
      output = plan.output
      {
        "mso_role_period_id" => period.id,
        "contributor_id" => period.contributor_id,
        "ledger_id" => plan.ledger.id,
        "tier" => period.tier,
        "title" => period.title,
        "multiplier" => period.tier_multiplier.to_s("F"),
        "started_at" => period.started_at.iso8601,
        "ended_at" => period.ended_at&.iso8601,
        "already_earned" => plan.already_earned.to_s("F"),
        "earned_by_ledger" => plan.earned_by_ledger.to_h { |ledger_id, amount| [ledger_id.to_s, amount.to_s("F")] },
        "calculated" => output.calculated.to_s("F"),
        "final" => output.final.to_s("F"),
        "reduction" => output.reduction.to_s("F"),
        # What is owed, in whole cents; and the figure it was rounded down from.
        "trueup" => plan.amount.to_s("F"),
        "trueup_before_rounding" => output.trueup.to_s("F"),
      }
    end

    def amounts_json(entries)
      entries.map { |entry| { "contributor_id" => entry[:contributor_id], "amount" => entry[:amount].to_s("F") } }
    end

    def reconciliation_json(reconciliation)
      {
        "account_total" => reconciliation[:account_total].to_s("F"),
        "payer_total" => reconciliation[:payer_total].to_s("F"),
        "variance" => reconciliation[:variance].to_s("F"),
        "invoices" => reconciliation[:invoices].map do |invoice|
          {
            "tracker_id" => invoice[:tracker_id],
            "qbo_id" => invoice[:qbo_id],
            "total" => invoice[:total].to_s("F"),
            "managerial_services" => invoice[:managerial_services].to_s("F"),
          }
        end,
      }
    end

    # Shown on the true-up's own page, which only its executive and admins
    # can open. No names: the page already says whose it is.
    def description_for(plan)
      period = plan.period
      role = "#{period.tier.titleize} (#{period.title}), #{period.tier_multiplier.to_s('F')}x"
      <<~MARKDOWN
        # MSO true-up for #{@month.strftime("%B %Y")}
        - **Role:** #{role}
        - **Calculated:** #{money(plan.output.calculated)}
        - **After the cap:** #{money(plan.output.final)}
        - **Already earned this month:** #{money(plan.already_earned)}
        - **True-up:** #{money(plan.amount)}
      MARKDOWN
    end

    def money(amount)
      ActionController::Base.helpers.number_to_currency(amount)
    end
  end
end
```

Notes on what was read to write this:
- `Mso::Compensation::Line` is `(key, multiplier, already_earned)` and the result's outputs carry `key, calculated, final, reduction, trueup` (`app/services/mso/compensation.rb:21-23`). The key is the contributor id: numeric keys break rounding ties numerically (`:113-114`).
- `Mso::Benchmark::Result#members` and `#excluded_without_login` are arrays of `{ contributor_id:, amount: }` (`app/services/mso/benchmark.rb:51,53`).
- `reconcile!` returns the hash `reconcile` builds, with `BigDecimal` amounts (`app/services/mso/management_fee_income.rb:69-74,152-153`).
- Every contributor already has a ledger per company (`Ledger.ensure_all!`, `app/models/ledger.rb:62-77`), so the roster uses `find_by` and computing never writes; `preview` depends on that.
- `Trueup` rows are found through `ledgers.contributor_id` and the pass's `start_of_month`; a founder true-up sits on Sanctuary's pass for the month (`lib/stacks/system.rb:79-98`).
- `lock!` reloads the row `FOR UPDATE`; `MsoTrueup#toggle_acceptance!` takes the same lock through `with_lock` (Task 1).
- The founder true-up builds its description the same way (`lib/stacks/system.rb:103-108`).
- acts_as_paranoid 0.7.0's own `recover` restores a row by writing `nil` to the paranoid column and calling `save` (`acts_as_paranoid/core.rb:177-200` in the installed gem); `write_trueup!` does the same in one save together with the new amount. Its `destroy` is a soft delete that returns the record, or `false` when a callback halts (`core.rb:152-175`).

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/monthly_run_test.rb
```

Expected: PASS, 33 runs, 0 failures. Each run calls `Mso::Benchmark` over every Sanctuary ledger in the fixtures; the file takes a few seconds.

If the two sub-cent tests fail because the second `stubs(:already_earned).with(...)` does not take precedence, the matcher is not matching keyword arguments on this Mocha: replace both stubs with one `Mso::MonthlyRun.stubs(:already_earned).with { |**args| … }` block, or stub per call order. Do not change the service.

If "over the cap" is off by a cent in the other direction, do not adjust the service: check the two scaled figures (15348.8372… and 17651.1627…) against `Mso::Compensation#allocate_cents`, which gives the odd cent to the larger fractional remainder.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 33 more runs than after Task 6 (baseline + 93), 0 failures, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add app/services/mso/monthly_run.rb test/services/mso/monthly_run_test.rb
git commit -m "feat(mso): the monthly run computes each executive's true-up and records how

One run refreshes and reconciles the month's fee invoices, reads the roster,
the benchmark and what each executive already earned across all their
ledgers, and writes an immutable snapshot plus a true-up, rounded down to
the cent, for everyone owed money. Running again supersedes the snapshot and
updates the true-ups; one that already has a QuickBooks bill is never
changed. It refuses an unfinished month, an unreconciled fee, a doubled
roster row and a month that still has a founder true-up. A refused or failed
run invalidates the one before it. preview computes without writing."
```

---

### Task 8: The bill guard, and what keeps a snapshot honest afterwards

Creating a true-up's QuickBooks bill is what locks its amount, so that is where the last checks go. This task also adds everything that withdraws a "collected" stamp or invalidates a snapshot after the run, and the read-only nightly refresh that lets a paid MSO bill be seen as paid.

**Files:**
- Modify: `app/models/mso_trueup.rb`
- Modify: `app/models/enterprise.rb`
- Modify: `app/models/invoice_tracker.rb`
- Modify: `app/admin/invoice_passes.rb`, `app/admin/money.rb`
- Create: `test/models/mso_trueup_billing_test.rb`, `test/integration/admin_money_mso_sync_test.rb`

**Interfaces:**
- Consumes: `Mso::MonthlyRun.preview`, `.invalidate_snapshots_whose_fee_moved!` (Task 7); `MsoSnapshot#check_collection!`, `#invalidate!`, `.unconfirm_collection!` (Task 1); `Qbo::BillRouter` (Task 4)
- Produces:
  - `MsoTrueup#sync_qbo_bill!` raises a `MsoTrueup::SyncRefused` subclass (`NotPayable`, `MissingVendor`, `AccountNotConfigured`, `NotCollected`, `FiguresChanged`, `BooksClosed`) instead of returning `nil` or writing a wrong bill. The bill it writes is dated, and due, the last day of the fee month
  - `MsoTrueup#remove_qbo_bill!`, `#refresh_qbo_bill_mirror!`, `MsoTrueup.refresh_bill_mirrors! -> [[id, message]]`
  - `Enterprise#daily_tasks` (garden3d) runs the database-only fee check and the read-only bill-mirror refresh
  - Attaching or detaching a fee tracker's invoice, and the pass's Refresh action, clear the collection stamp

- [ ] **Step 1: Write the failing tests**

Create `test/models/mso_trueup_billing_test.rb`:

```ruby
require "test_helper"
require "ostruct"

class MsoTrueupBillingTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 11, 1)

  def setup
    @qa = garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("bill-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(@role, @ledger, trueup: "1200.0")], collected: true)
    @trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1200", accepted: true)
    @vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    @mapping = ContributorQboVendor.create!(contributor: @exec, qbo_account: @qa, qbo_vendor: @vendor)

    # A chart that HAS an MSO compensation account, and a router that knows
    # its number: the state after Finance has done their part.
    QboAccount.any_instance.stubs(:fetch_all_accounts)
      .returns([OpenStruct.new(acct_num: "6100", id: 61), OpenStruct.new(acct_num: "6200", id: 62)])
    @pinned = Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:garden3d].merge(mso_compensation: "6200")
    Qbo::BillRouter.any_instance.stubs(:enterprise_gl_map).returns(@pinned)

    # The two checks made before a first bill. Tests override these.
    Mso::ManagementFeeInvoices.stubs(:collected?).returns(true)
    Mso::MonthlyRun.stubs(:preview).returns({ @ledger.id => BigDecimal("1200") })

    # Any QuickBooks write a test did not ask for fails it.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token).returns(:token)
    Quickbooks::Service::Bill.any_instance.stubs(:access_token=)
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(RuntimeError, "unexpected QuickBooks bill write")
    Quickbooks::Service::Bill.any_instance.stubs(:update).raises(RuntimeError, "unexpected QuickBooks bill write")
    Quickbooks::Service::Bill.any_instance.stubs(:delete).raises(RuntimeError, "unexpected QuickBooks bill delete")
    QboBill.any_instance.stubs(:delete_qbo_bill!).raises(RuntimeError, "unexpected QuickBooks bill delete")
  end

  def teardown
    clear_enterprise_memos
  end

  def fresh
    MsoTrueup.find(@trueup.id)
  end

  def remote_bill(id, balance: "1200", total: "1200")
    Quickbooks::Model::Bill.new.tap do |bill|
      bill.id = id
      bill.balance = BigDecimal(balance)
      bill.total = BigDecimal(total)
      bill.vendor_ref = Quickbooks::Model::BaseReference.new(@vendor.qbo_id)
    end
  end

  def mirror!(qbo_id, data)
    QboBill.create!(qbo_account: @qa, qbo_id: qbo_id, qbo_vendor_id: @vendor.qbo_id, data: data)
  end

  # --- the first bill ----------------------------------------------------------

  test "with no garden3d vendor the sync raises and says what to do, instead of doing nothing" do
    @mapping.destroy

    error = assert_raises(MsoTrueup::MissingVendor) { fresh.sync_qbo_bill! }

    assert_kind_of MsoTrueup::SyncRefused, error
    assert_match(/no vendor in garden3d, LLC's QuickBooks/, error.message)
    assert_match(/Contributor record/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "with no MSO compensation account the sync raises and says who has to act" do
    Qbo::BillRouter.any_instance.unstub(:enterprise_gl_map) # back to the real "____"

    error = assert_raises(MsoTrueup::AccountNotConfigured) { fresh.sync_qbo_bill! }

    assert_match(/mso_compensation/, error.message)
    assert_match(/Finance/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "collection is re-checked live before the first bill, and an unpaid fee stops it" do
    Mso::ManagementFeeInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(false)

    error = assert_raises(MsoTrueup::NotCollected) { fresh.sync_qbo_bill! }

    assert_match(/has not been collected/, error.message)
    assert_nil fresh.qbo_bill_id
    assert_not @snapshot.reload.fee_collected?, "and the stamp is withdrawn, not rolled back with the refusal"
    assert_equal false, fresh.payable?
  end

  test "a fee invoice that cannot be read stops the first bill" do
    Mso::ManagementFeeInvoices.stubs(:collected?)
      .raises(Mso::ManagementFeeInvoices::RefreshFailed, "Could not read the QuickBooks invoice on InvoiceTracker 9")

    error = assert_raises(MsoTrueup::NotCollected) { fresh.sync_qbo_bill! }

    assert_match(/Could not read/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "the first bill is refused when a fresh computation gives a different figure" do
    Mso::MonthlyRun.expects(:preview).with(invoice_pass: @pass).once.returns({ @ledger.id => BigDecimal("1150.25") })

    error = assert_raises(MsoTrueup::FiguresChanged) { fresh.sync_qbo_bill! }

    assert_match(/1200\.0/, error.message)
    assert_match(/1150\.25/, error.message)
    assert_match(/run the month again/i, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "the first bill is refused when the month can no longer be computed, or the person has left it" do
    Mso::MonthlyRun.stubs(:preview).raises(Mso::MonthlyRun::Refused, "a reconcile variance")
    assert_match(/a reconcile variance/, assert_raises(MsoTrueup::FiguresChanged) { fresh.sync_qbo_bill! }.message)

    Mso::MonthlyRun.stubs(:preview).returns({})
    assert_match(/0\.0/, assert_raises(MsoTrueup::FiguresChanged) { fresh.sync_qbo_bill! }.message)
    assert_nil fresh.qbo_bill_id
  end

  test "when everything holds, one bill is created; syncing again updates it without re-checking" do
    Mso::ManagementFeeInvoices.expects(:collected?).once.returns(true)
    Mso::MonthlyRun.expects(:preview).once.returns({ @ledger.id => BigDecimal("1200") })
    Quickbooks::Service::Bill.any_instance.expects(:create).once.returns(remote_bill("900"))

    fresh.sync_qbo_bill!

    assert_equal "900", fresh.qbo_bill_id
    assert QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "900")

    QboAccount.any_instance.stubs(:fetch_bill_by_id).returns(remote_bill("900"))
    Quickbooks::Service::Bill.any_instance.expects(:update).once.returns(remote_bill("900"))

    fresh.sync_qbo_bill!

    assert_equal "900", fresh.qbo_bill_id
    assert_equal 1, QboBill.where(qbo_account_id: @qa.id).count
  end

  # Accrual dating (owner decision O2): the bill is dated the last day of the
  # fee month. If garden3d's books for that month are already closed,
  # QuickBooks rejects it; say so in words Finance can act on.
  test "if the books are closed for the bill's date, the refusal says so and what to do" do
    closed = Quickbooks::IntuitRequestException.new(
      "The account period has closed and the account books cannot be updated through through QBO Services API. " \
      "Please use the QBO website to make these changes.",
    )
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(closed)

    error = assert_raises(MsoTrueup::BooksClosed) { fresh.sync_qbo_bill! }

    assert_match(%r{closed for 11/30/2090}, error.message)
    assert_match(/reopen/i, error.message)
    assert_match(/before the month is closed/, error.message)
    assert_nil fresh.qbo_bill_id
  end

  test "any other QuickBooks rejection is passed on as it is" do
    Quickbooks::Service::Bill.any_instance.stubs(:create)
      .raises(Quickbooks::IntuitRequestException.new("Duplicate Document Number Error"))

    error = assert_raises(Quickbooks::IntuitRequestException) { fresh.sync_qbo_bill! }
    assert_match(/Duplicate Document Number/, error.message)
  end

  test "the Money page's sync-all contains each refusal and carries its message" do
    @mapping.destroy
    failures = nil

    assert_nothing_raised { failures = Money::RefreshPayableQboBills.call(qbo_account: @qa) }

    mine = failures.select { |host, _| host.is_a?(MsoTrueup) }
    assert_equal [@trueup.id], mine.map { |host, _| host.id }
    assert_kind_of MsoTrueup::MissingVendor, mine.first.last
  end

  # --- after the bill --------------------------------------------------------------

  test "a billed true-up stays in the balance when its snapshot is invalidated, and leaves it when the bill is paid" do
    mirror!("901", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "901")
    @snapshot.invalidate!("a later run was refused")

    ledger = Ledger.find(@ledger.id)
    assert_equal true, fresh.payable?
    assert_equal 1200.0, ledger.balance.to_f
    assert_equal 0.0, ledger.unsettled.to_f
    assert_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup

    QboBill.where(qbo_account_id: @qa.id, qbo_id: "901").update_all(data: { "balance" => "0", "total_amt" => "1200" })

    ledger = Ledger.find(@ledger.id)
    assert_equal 0.0, ledger.balance.to_f
    assert_equal 0.0, ledger.unsettled.to_f
    assert_not_includes Money::PayableQboBills.call(qbo_account: @qa).map(&:host), @trueup
  end

  test "removing the bill clears the acceptance and invalidates the snapshot" do
    @trueup.update_columns(qbo_bill_id: "902")
    # The existing guard: re-reads the bill, refuses if paid, deletes it.
    MsoTrueup.any_instance.expects(:detach_and_destroy_qbo_bill).once

    fresh.remove_qbo_bill!

    assert_not fresh.accepted?
    assert @snapshot.reload.invalidated?
    assert_not @snapshot.fee_collected?
    assert_match(/bill for MsoTrueup #{@trueup.id} was removed/, @snapshot.invalidated_reason)
  end

  test "a paid bill cannot be removed, and nothing changes" do
    @trueup.update_columns(qbo_bill_id: "903")
    MsoTrueup.any_instance.stubs(:detach_and_destroy_qbo_bill)
      .raises(SyncsAsQboBill::PaidQboBillError, "refusing to destroy QBO bill 903")

    assert_raises(SyncsAsQboBill::PaidQboBillError) { fresh.remove_qbo_bill! }

    assert_equal "903", fresh.qbo_bill_id
    assert fresh.accepted?
    assert_not @snapshot.reload.invalidated?
  end

  # --- the nightly, read-only refresh ---------------------------------------------

  test "the mirror refresh reads the bill and writes nothing to QuickBooks" do
    mirror!("904", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "904")
    QboAccount.any_instance.expects(:fetch_bill_by_id).with("904").once.returns(remote_bill("904", balance: "0"))

    assert_equal :refreshed, fresh.refresh_qbo_bill_mirror!

    assert QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "904").paid?
    assert_equal "904", fresh.qbo_bill_id
    assert_equal 0.0, Ledger.find(@ledger.id).balance.to_f
  end

  test "a bill deleted in QuickBooks unlocks the true-up without another QuickBooks call" do
    mirror!("905", { "balance" => "1200", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "905")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "Object Not Found: Something you're trying to use has been made inactive")

    assert_equal :bill_gone, fresh.refresh_qbo_bill_mirror!

    assert_nil fresh.qbo_bill_id
    assert_not fresh.accepted?
    assert_nil QboBill.find_by(qbo_account_id: @qa.id, qbo_id: "905")
    assert @snapshot.reload.invalidated?
  end

  test "the batch refresh skips settled bills and contains a failure" do
    mirror!("906", { "balance" => "0", "total_amt" => "1200" })
    @trueup.update_columns(qbo_bill_id: "906")
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "unexpected QuickBooks read")

    assert_equal [], MsoTrueup.refresh_bill_mirrors!

    QboBill.where(qbo_account_id: @qa.id, qbo_id: "906").update_all(data: { "balance" => "1200", "total_amt" => "1200" })
    QboAccount.any_instance.stubs(:fetch_bill_by_id).raises(RuntimeError, "QuickBooks is down")

    failures = MsoTrueup.refresh_bill_mirrors!

    assert_equal [@trueup.id], failures.map(&:first)
    assert_match(/QuickBooks is down/, failures.first.last)
    assert_equal "906", fresh.qbo_bill_id
  end

  # --- what withdraws a stamp or invalidates a snapshot --------------------------------

  test "nightly: a snapshot whose fee income no longer matches account 4100 is invalidated, from stored data only" do
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range).raises(RuntimeError, "unexpected QuickBooks read")

    # No stored report for the month at all: skipped, never fetched.
    assert_equal [], Mso::MonthlyRun.invalidate_snapshots_whose_fee_moved!
    assert_not @snapshot.reload.invalidated?

    report = fee_report(MONTH, "100000.0") # what the snapshot used
    assert_equal [], Mso::MonthlyRun.invalidate_snapshots_whose_fee_moved!
    assert @snapshot.reload.fee_collected?

    report.destroy
    fee_report(MONTH, "90000.0") # an invoice was voided after the run

    assert_equal [@snapshot.id], Mso::MonthlyRun.invalidate_snapshots_whose_fee_moved!
    @snapshot.reload
    assert @snapshot.invalidated?
    assert_match(/now reads 90000\.0/, @snapshot.invalidated_reason)
    assert_equal false, fresh.payable?
  end

  test "garden3d's nightly step runs the fee check and the read-only refresh, and nothing that writes a bill" do
    Mso::ManagementFeeInvoices.stubs(:ensure_previous_month!)
    Mso::MonthlyRun.expects(:invalidate_snapshots_whose_fee_moved!).once.returns([])
    MsoTrueup.expects(:refresh_bill_mirrors!).once.returns([])
    Mso::MonthlyRun.stubs(:call).raises(RuntimeError, "the nightly step ran the month")
    MsoTrueup.any_instance.stubs(:sync_qbo_bill!).raises(RuntimeError, "the nightly step synced a bill")

    Enterprise.find(garden3d.id).daily_tasks
    # Another company's nightly step does neither: a second call would exceed `once`.
    Enterprise.find(enterprises(:sanctuary).id).daily_tasks
  end

  test "attaching or detaching a fee invoice withdraws the collection stamp" do
    payer = make_payer("Stamp Payer #{SecureRandom.hex(3)}", customer_id: "2")
    tracker = fee_tracker(@pass, payer)
    @snapshot.update_columns(fee_collected_at: Time.current)

    attach_invoice(tracker, qbo_id: "9100", total: "100000.0", balance: "0.0", sent: true)
    assert_not @snapshot.reload.fee_collected?

    @snapshot.update_columns(fee_collected_at: Time.current)
    InvoiceTracker.find(tracker.id).update!(qbo_invoice_id: nil)
    assert_not @snapshot.reload.fee_collected?

    # A change that is not about the invoice leaves the stamp alone.
    @snapshot.update_columns(fee_collected_at: Time.current)
    InvoiceTracker.find(tracker.id).update!(notes: "a note")
    assert @snapshot.reload.fee_collected?
  end
end
```

Create `test/integration/admin_money_mso_sync_test.rb`:

```ruby
require "test_helper"

class AdminMoneyMsoSyncTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  MONTH = Date.new(2094, 4, 1)

  setup do
    @qa = garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @admin = mso_admin
    exec = mso_person("money-exec")
    ledger = garden3d_ledger(exec)
    role = mso_role(exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(role, ledger, trueup: "1200.0")], collected: true)
    @trueup = mso_trueup(@snapshot, role, ledger, amount: "1200", accepted: true)

    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  teardown do
    clear_enterprise_memos
  end

  test "Sync all tells the admin why an MSO true-up was not synced" do
    sign_in @admin

    # No garden3d vendor is mapped for this executive.
    post admin_money_refresh_tab_path(qbo_account_id: @qa.id)

    assert_response :redirect
    assert_match(/MsoTrueup##{@trueup.id}/, flash[:alert])
    assert_match(/no vendor in garden3d, LLC's QuickBooks/, flash[:alert])
    assert_nil @trueup.reload.qbo_bill_id
  end

  test "Refresh from QuickBooks on the pass withdraws the collection stamp" do
    sign_in @admin
    assert @snapshot.fee_collected?

    post refresh_management_fee_invoices_admin_invoice_pass_path(@pass)

    assert_response :redirect
    assert_not @snapshot.reload.fee_collected?
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/models/mso_trueup_billing_test.rb test/integration/admin_money_mso_sync_test.rb
```

Expected: 21 runs, 18 failures or errors. The sync tests fail because the Task 1 override only checks `payable?` (with no vendor it returns `nil`; with a figure that moved it goes on to the write and hits "unexpected QuickBooks bill write"); the others error with `NoMethodError` for `remove_qbo_bill!`, `refresh_qbo_bill_mirror!` and `refresh_bill_mirrors!`, or see a stamp that was not withdrawn. Three pass already and are here to pin behaviour at the point it matters: "a billed true-up stays in the balance" (Task 1), "nightly: a snapshot whose fee income no longer matches" (Task 7) and "any other QuickBooks rejection is passed on as it is".

- [ ] **Step 3: The guard on `MsoTrueup#sync_qbo_bill!`**

The error classes were declared in Task 1. In `app/models/mso_trueup.rb`, replace the `sync_qbo_bill!` override from Task 1 with:

```ruby
  # Creating the bill is what locks this true-up's amount, so the last checks
  # happen here. sync_qbo_bill! itself has no guard of any kind, returns nil
  # without a word when the contributor has no vendor, and is called for every
  # row by the nightly stacks:sync_contributor_qbo_bills task. MsoTrueup is
  # deliberately not in that task; this makes sure nothing wrong can reach
  # QuickBooks even if it is ever added.
  #
  # For the FIRST bill this makes QuickBooks reads (the chart of accounts and
  # one per management fee invoice) and one full computation of the month.
  # It is an admin's click on the Money page.
  def sync_qbo_bill!(accounts_cache: nil)
    accounts_cache ||= Qbo::AccountsCache.new

    # Outside the lock and its transaction: a stamp these checks withdraw
    # must stay withdrawn when the sync is then refused.
    assert_can_be_billed!(accounts_cache)
    assert_first_bill_is_still_right! unless locked?

    # The row lock makes a double click safe: the second caller waits here,
    # reloads, finds the bill the first one created and updates it instead
    # of creating another. Mso::MonthlyRun takes the same lock.
    with_lock do
      raise NotPayable, not_payable_message unless payable?

      begin
        super(accounts_cache: accounts_cache)
      rescue Quickbooks::IntuitRequestException => e
        # The bill is dated the last day of the fee month. Once that month is
        # closed in QuickBooks a bill dated in it is rejected. Recognised by
        # the wording of QuickBooks' message; anything else is passed on.
        raise unless e.message.to_s.match?(/period has closed|books (are|is) closed|closing date/i)

        raise BooksClosed, "#{enterprise.name}'s books are closed for #{bill_txn_date.strftime('%m/%d/%Y')}, " \
                           "the date this bill must carry. Finance has to reopen the period (or move the " \
                           "closing date) in QuickBooks; then sync again. MSO bills need creating before " \
                           "the month is closed. No bill was written. (QuickBooks said: #{e.message})"
      end
    end
  end

  # An admin's way to unfreeze a true-up whose figure needs to change. Reads
  # the bill from QuickBooks, refuses if it has any payment
  # (SyncsAsQboBill::PaidQboBillError), deletes it. The acceptance is cleared
  # and the snapshot invalidated, so the row cannot be synced again at the old
  # amount: the month has to be run again first.
  def remove_qbo_bill!
    detach_and_destroy_qbo_bill
    update_columns(accepted_at: nil)
    mso_snapshot.invalidate!("The QuickBooks bill for MsoTrueup #{id} was removed. Run the month again.")
  end

  # READ ONLY. Brings the stored copy of this true-up's bill up to date so a
  # bill paid in QuickBooks is seen as paid here. The nightly bill sync does
  # this for other ledger items by re-writing each bill; this only reads.
  # It can never create or change a bill.
  def refresh_qbo_bill_mirror!
    return :no_bill unless locked?

    qbo_account = qbo_account_for_bill
    return :no_account if qbo_account.nil?

    begin
      remote = qbo_account.fetch_bill_by_id(qbo_bill_id)
    rescue => e
      raise unless e.message.to_s.start_with?("Object Not Found:")

      # Someone deleted the bill in QuickBooks. delete_all, not destroy:
      # QboBill#destroy would call QuickBooks to delete it again.
      QboBill.where(qbo_account_id: qbo_account.id, qbo_id: qbo_bill_id).delete_all
      gone = qbo_bill_id
      update_columns(qbo_bill_id: nil, accepted_at: nil)
      mso_snapshot.invalidate!("QuickBooks bill #{gone} for MsoTrueup #{id} no longer exists. Run the month again.")
      return :bill_gone
    end

    # By the (account, id) pair: a bill id is unique only within one account.
    mirrors = QboBill.where(qbo_account_id: qbo_account.id, qbo_id: qbo_bill_id)
    if mirrors.exists?
      mirrors.update_all(data: remote.as_json, updated_at: Time.current)
    else
      QboBill.create!(qbo_id: qbo_bill_id, qbo_account_id: qbo_account.id, data: remote.as_json,
                      qbo_vendor_id: remote.vendor_ref&.value)
    end
    :refreshed
  end

  # Nightly, from garden3d's daily step. QuickBooks READS only. Bills already
  # settled are skipped. One failure does not stop the rest.
  def self.refresh_bill_mirrors!
    return [] unless schema_ready?

    failures = []
    where.not(qbo_bill_id: nil).find_each do |trueup|
      next if trueup.qbo_bill&.paid?

      trueup.refresh_qbo_bill_mirror!
    rescue => e
      failures << [trueup.id, "#{e.class}: #{e.message}"]
      Rails.logger.error("[mso] bill mirror refresh failed for MsoTrueup #{trueup.id}: #{e.class}: #{e.message}")
    end
    failures
  end
```

and add to the `private` section:

```ruby
  def not_payable_message
    "MsoTrueup #{id} is not payable yet: it needs its executive's acceptance, every other executive's " \
      "acceptance for the month, and a confirmed fee collection. No bill was written."
  end

  def assert_can_be_billed!(accounts_cache)
    raise NotPayable, not_payable_message unless payable?

    qbo_account = qbo_account_for_bill
    if qbo_account.nil?
      raise SyncRefused, "#{enterprise.name} has no connected QuickBooks account. No bill was written."
    end
    if contributor.qbo_vendor_for(qbo_account).nil?
      raise MissingVendor, "Contributor #{contributor.id} has no vendor in #{enterprise.name}'s QuickBooks. " \
                           "Create the vendor there, map it on their Contributor record (Team → " \
                           "Contributors → Edit), then sync again. No bill was written."
    end

    begin
      Qbo::BillRouter.new(self, accounts_cache: accounts_cache).lines
    rescue RuntimeError => e
      raise AccountNotConfigured, "#{enterprise.name} has no MSO compensation account that Stacks can " \
                                  "post to (concept mso_compensation). Finance creates the account in " \
                                  "QuickBooks; its account number then replaces the placeholder in " \
                                  "app/services/qbo/bill_router.rb. No bill was written. (#{e.message})"
    end
  end

  # Only before the FIRST bill. Afterwards the amount is in QuickBooks and
  # these questions are the snapshot's drift, not a reason to refuse an update.
  def assert_first_bill_is_still_right!
    collected =
      begin
        mso_snapshot.check_collection!
      rescue Mso::ManagementFeeInvoices::Error, MsoSnapshot::Unusable => e
        raise NotCollected, "#{e.message}. No bill was written."
      end
    unless collected
      raise NotCollected, "The management fee for #{payment_date.strftime('%B %Y')} has not been collected " \
                          "in full, as of a check with QuickBooks just now. No bill was written."
    end

    fresh =
      begin
        Mso::MonthlyRun.preview(invoice_pass: invoice_pass).fetch(ledger_id, BigDecimal("0"))
      rescue Mso::MonthlyRun::Refused => e
        raise FiguresChanged, "The month can no longer be computed as it was run (#{e.message}). " \
                              "Run the month again. No bill was written."
      end
    return if fresh == amount

    raise FiguresChanged, "This true-up is #{amount.to_s('F')} but a fresh computation gives " \
                          "#{fresh.to_s('F')}: figures changed since the run. Run the month again. " \
                          "No bill was written."
  end
```

Notes on what was read to write this:
- The base method returns silently with no QuickBooks account, with no vendor, and for a non-positive amount, and otherwise goes straight to the router and the write (`app/models/concerns/syncs_as_qbo_bill.rb:128-177`). The vendor lookup is `Contributor#qbo_vendor_for` (`app/models/contributor.rb:63-66`).
- `load_qbo_bill!` is how the base method finds an existing bill; on a second call under the lock it loads and updates rather than creating (`:144`, `:160`).
- `fetch_bill_by_id` is a read (`app/models/qbo_account.rb:191-197`). `QboBill#destroy` deletes the remote bill (`app/models/qbo_bill.rb:12,66-75`), which is why the bill-gone branch uses `delete_all`.
- `MsoSnapshot#check_collection!` writes its stamp with `update_columns`; calling it before `with_lock` means a refusal cannot roll that write back.

- [ ] **Step 4: The nightly step**

In `app/models/enterprise.rb`, replace `daily_tasks` (lines 84-90) with:

```ruby
  def daily_tasks
    Stacks::Optix.deactivate_inactive_members! if is_index?
    return unless is_garden3d?

    # Database only: garden3d's pass and trackers for last month, and for any
    # earlier month since the start that has none. Nothing here may write to
    # QuickBooks; an admin creates the drafts by hand.
    Mso::ManagementFeeInvoices.ensure_previous_month!
    # Database only: a snapshot whose fee income no longer matches the stored
    # P&L is invalidated, so nothing computed from the old fee stays payable.
    Mso::MonthlyRun.invalidate_snapshots_whose_fee_moved!
    # QuickBooks READS only: refresh the stored copy of MSO bills that already
    # exist, so a paid one is seen as paid. Cannot create or change a bill.
    MsoTrueup.refresh_bill_mirrors!
  end
```

`stacks:daily_enterprise_tasks` already rescues each enterprise's `daily_tasks` on its own (`lib/tasks/stacks.rake`, the `Enterprise.find_each` block), and it runs after every account's P&L has been re-synced, so the fee check reads tonight's figures.

- [ ] **Step 5: Attaching, detaching and refreshing withdraw the stamp**

In `app/models/invoice_tracker.rb`, directly below the last `belongs_to` (line 24), add:

```ruby

  # "The management fee was collected" was confirmed against the invoices
  # attached at the time. Attach or detach one on garden3d's pass and that
  # confirmation no longer describes the pass; an admin confirms again.
  after_save :withdraw_mso_collection_stamp,
    if: -> { saved_change_to_qbo_invoice_id? || saved_change_to_qbo_account_id? }

  def withdraw_mso_collection_stamp
    return unless invoice_pass&.management_fee?
    MsoSnapshot.unconfirm_collection!(invoice_pass_id)
  end
```

`management_fee?` checks `forecast?` first (`app/models/invoice_pass.rb:24-27`), so a Sanctuary tracker, which is nearly every tracker, costs one comparison and no query.

In `app/admin/invoice_passes.rb`, in the `refresh_management_fee_invoices` member action, directly below the `begin … rescue … end` that calls `refresh!` (lines 124-128), add:

```ruby

    # What Stacks holds for these invoices has just changed. Whether the fee
    # is collected has to be confirmed again (Check collection, or a run).
    MsoSnapshot.unconfirm_collection!(resource.id)
```

- [ ] **Step 6: The Money page says why**

In `app/admin/money.rb`, replace line 118 (inside `refresh_tab`) with:

```ruby
      # The message, not just the class: a refused MSO true-up says what to do.
      preview = failures.first(3).map { |host, e| "#{host.class.name}##{host.id}: #{e.message.to_s.truncate(220)}" }.join(" | ")
```

The single-row action already shows `e.message` (`app/admin/money.rb:99`). Every path that calls `sync_qbo_bill!` on a batch rescues per row: `Money::RefreshPayableQboBills` (`app/services/money/refresh_payable_qbo_bills.rb:19-24`) and the nightly rake task (`lib/tasks/stacks.rake:526-530`), which never reaches an `MsoTrueup`.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
bin/rails test test/models/mso_trueup_billing_test.rb test/integration/admin_money_mso_sync_test.rb test/models/mso_trueup_test.rb test/models/mso_trueup_qbo_registration_test.rb test/integration/admin_management_fee_invoices_test.rb
```

Expected: PASS. 21 new runs. Task 1's "sync_qbo_bill! refuses a true-up that is not payable" still passes: `NotPayable` is raised first.

- [ ] **Step 8: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 21 more runs than after Task 7 (baseline + 114), 0 failures, 0 errors. The new `after_save` on `InvoiceTracker` runs in every test that attaches an invoice; if an S1 test fails here, read it before changing anything: the callback only touches `mso_snapshots`.

- [ ] **Step 9: Commit**

```bash
git add app/models/mso_trueup.rb app/models/enterprise.rb app/models/invoice_tracker.rb \
  app/admin/invoice_passes.rb app/admin/money.rb \
  test/models/mso_trueup_billing_test.rb test/integration/admin_money_mso_sync_test.rb
git commit -m "feat(mso): a true-up's first QuickBooks bill is checked against the present, not the run

Creating the bill is what locks the amount. Before the first one, the sync
re-checks with QuickBooks that the fee was collected and recomputes the
month; it refuses if the figure moved, if the executive has no vendor or if
there is no account to post to, and says which. A billed true-up stays
payable so it can settle. A snapshot is invalidated when the stored fee
income moves, and the collection stamp is withdrawn when the pass's
invoices change."
```

---

### Task 9: The founder true-up stops where the MSO starts, and cannot come back

`Stacks::System.sync_founder_trueups!` runs nightly and rewrites the founder's true-up for every completed month since June 2025 (`lib/stacks/system.rb:77-111`, `lib/tasks/stacks.rake:569-577`); the nightly bill sync then bills each one in Sanctuary's QuickBooks (`lib/tasks/stacks.rake:546`). From the first month the founder is paid through the MSO, their Principal-level MSO true-up replaces it (Decisions 4 and 5). Four changes make that hold:

1. Deleting a founder true-up deletes its QuickBooks bill with it (today the bill is left behind, open and payable).
2. The nightly sync skips a month the founder was, or is, paid for through the MSO: an active role period, **or** any snapshot line, **or** any MSO true-up for them in that month, soft-deleted ones included.
3. A role period that a run has used cannot be destroyed or edited so as to change a month already run.
4. (`Mso::MonthlyRun` refusing to run beside a founder true-up was built in Task 7.)

**Files:**
- Modify: `app/models/trueup.rb`, `app/admin/trueups.rb`
- Modify: `lib/stacks/system.rb`
- Modify: `app/models/mso_role_period.rb`, `app/admin/mso_role_periods.rb`
- Create: `test/lib/stacks/founder_trueup_mso_test.rb`, `test/models/mso_role_period_run_guard_test.rb`, `test/integration/admin_mso_role_period_guard_test.rb`

**Interfaces:**
- Consumes: `MsoRolePeriod.active_during(date)`, `MsoSnapshot`, `MsoTrueup`
- Produces:
  - `Trueup` deletes its QuickBooks bill when destroyed; refused if the bill has any payment
  - `Stacks::System.founder_contributor`, `Stacks::System.founder_paid_by_mso?(founder, month)`
  - `MsoRolePeriod#months_run -> [Date]`; destroy and month-changing edits are refused once a snapshot names the period

- [ ] **Step 1: Write the failing tests**

Create `test/lib/stacks/founder_trueup_mso_test.rb`:

```ruby
require "test_helper"

class FounderTrueupMsoTest < ActiveSupport::TestCase
  include MsoFixtures

  JANUARY = Date.new(2091, 1, 1)
  FEBRUARY = Date.new(2091, 2, 1)

  def setup
    @sanctuary = enterprises(:sanctuary)
    email = Stacks::System.singleton_class::FOUNDER_EMAIL
    fp = ForecastPerson.find_by(email: email) ||
         ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    @founder = fp.contributor || Contributor.create!(forecast_person: fp)
    @founder_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @founder)
    @top_earner = mso_person("ft-top", login: false)
    garden3d_qbo_account
    InvoicePass.where(start_of_month: [JANUARY, FEBRUARY]).destroy_all
  end

  def teardown
    clear_enterprise_memos
  end

  # Sanctuary's pass for the month: the top earner made 5,000, the founder 1,000.
  def month_with_payouts(month)
    pass = InvoicePass.create!(start_of_month: month, enterprise: @sanctuary, data: {})
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "FT Client #{SecureRandom.hex(3)}")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client: client,
                                     qbo_account: Enterprise.find(@sanctuary.id).qbo_account)
    { @top_earner => 5_000, @founder => 1_000 }.each do |contributor, amount|
      ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: contributor)
      ContributorPayout.new(ledger: ledger, invoice_tracker: tracker, created_by: mso_admin, amount: amount)
                       .save!(validate: false)
    end
    pass
  end

  def founder_role(started_at)
    MsoRolePeriod.create!(contributor: @founder, tier: :principal, title: "Founder", started_at: started_at)
  end

  # February was paid through the MSO: a snapshot line and a true-up for the founder.
  def february_run(role)
    pass = garden3d_pass(FEBRUARY)
    ledger = garden3d_ledger(@founder)
    snapshot = mso_snapshot(pass, lines: [mso_line(role, ledger, trueup: "900.0")])
    [snapshot, mso_trueup(snapshot, role, ledger, amount: "900")]
  end

  def sync!(*months)
    Stacks::System.stubs(:founder_trueup_months).returns(months)
    Stacks::System.sync_founder_trueups!
  end

  test "without an MSO role the founder true-up is written as before" do
    pass = month_with_payouts(JANUARY)

    sync!(JANUARY)

    assert_equal BigDecimal("4000"), Trueup.find_by!(invoice_pass: pass, ledger: @founder_ledger).amount
  end

  test "from the month the founder holds an MSO role, no founder true-up is written" do
    january = month_with_payouts(JANUARY)
    # February has no Sanctuary pass at all: a skipped month must not need one.
    founder_role(FEBRUARY)

    assert_difference -> { Trueup.count }, 1 do
      sync!(JANUARY, FEBRUARY)
    end

    assert Trueup.exists?(invoice_pass: january, ledger: @founder_ledger), "the month before the role is untouched"
    assert_equal true, Stacks::System.founder_paid_by_mso?(@founder, FEBRUARY)
    assert_equal false, Stacks::System.founder_paid_by_mso?(@founder, JANUARY)
  end

  test "an existing founder true-up in an MSO month is not rewritten by the sync" do
    pass = month_with_payouts(FEBRUARY)
    existing = Trueup.create!(invoice_pass: pass, ledger: @founder_ledger, amount: "123.45", description: "earlier")
    founder_role(FEBRUARY)

    assert_no_difference -> { Trueup.with_deleted.count } do
      sync!(FEBRUARY)
    end

    assert_equal BigDecimal("123.45"), existing.reload.amount
  end

  test "deleting the role period after the month was run does not bring the founder true-up back" do
    month_with_payouts(FEBRUARY)
    role = founder_role(FEBRUARY)
    snapshot, trueup = february_run(role)
    # However it happened: the roster row is gone and so is the true-up row.
    trueup.destroy
    MsoSnapshot.where(id: snapshot.id).update_all(lines: [])
    MsoRolePeriod.where(id: role.id).update_all(started_at: Date.new(2091, 3, 1))

    assert_equal true, Stacks::System.founder_paid_by_mso?(@founder, FEBRUARY),
      "a soft-deleted MSO true-up still marks the month"
    assert_no_difference -> { Trueup.with_deleted.count } do
      sync!(FEBRUARY)
    end
  end

  test "moving the role's start later does not bring the founder true-up back for a month a snapshot covers" do
    month_with_payouts(FEBRUARY)
    role = founder_role(FEBRUARY)
    _snapshot, trueup = february_run(role)
    # No true-up row at all this time; only the snapshot's line names the founder.
    MsoTrueup.with_deleted.where(id: trueup.id).delete_all!
    MsoRolePeriod.where(id: role.id).update_all(started_at: Date.new(2091, 3, 1))

    assert_equal true, Stacks::System.founder_paid_by_mso?(@founder, FEBRUARY)
    assert_no_difference -> { Trueup.with_deleted.count } do
      sync!(FEBRUARY)
    end
  end

  test "deleting a founder true-up deletes its QuickBooks bill, and a paid bill refuses the delete" do
    pass = month_with_payouts(JANUARY)
    trueup = Trueup.create!(invoice_pass: pass, ledger: @founder_ledger, amount: "4000", description: "x",
                            qbo_bill_id: "55")

    Trueup.any_instance.expects(:detach_and_destroy_qbo_bill).once
      .raises(SyncsAsQboBill::PaidQboBillError, "refusing to destroy QBO bill 55")
    assert_raises(SyncsAsQboBill::PaidQboBillError) { trueup.destroy }
    assert Trueup.find_by(id: trueup.id), "a refused delete leaves the row"

    Trueup.any_instance.expects(:detach_and_destroy_qbo_bill).once
    Trueup.find(trueup.id).destroy
    assert_nil Trueup.find_by(id: trueup.id)
  end
end
```

Create `test/models/mso_role_period_run_guard_test.rb`:

```ruby
require "test_helper"

class MsoRolePeriodRunGuardTest < ActiveSupport::TestCase
  include MsoFixtures

  MARCH = Date.new(2091, 3, 1)
  MAY = Date.new(2091, 5, 1)

  def setup
    garden3d_qbo_account
    @exec = mso_person("guard-exec")
    @role = mso_role(@exec, tier: :chief, started_at: Date.new(2091, 1, 1))
    ledger = garden3d_ledger(@exec)
    # March and May have been run with this role period; a superseded
    # snapshot counts as much as a current one.
    [MARCH, MAY].each do |month|
      mso_snapshot(garden3d_pass(month), lines: [mso_line(@role, ledger, trueup: "100.0")])
    end
    MsoSnapshot.joins(:invoice_pass).where(invoice_passes: { start_of_month: MARCH })
      .update_all(superseded_at: Time.current)
  end

  def teardown
    clear_enterprise_memos
  end

  test "a role period a run has used cannot be destroyed; one never used can" do
    assert_equal [MARCH, MAY], @role.months_run

    assert_equal false, @role.destroy
    assert_match(/March 2091/, @role.errors.full_messages.to_sentence)
    assert MsoRolePeriod.exists?(@role.id)

    unused = mso_role(mso_person("guard-unused"), started_at: Date.new(2091, 1, 1))
    assert unused.destroy
    assert_not MsoRolePeriod.exists?(unused.id)
  end

  test "its tier, person, start and end cannot be changed so as to alter a month already run" do
    period = -> { MsoRolePeriod.find(@role.id) }

    assert_not period.call.update(tier: :principal)
    assert_not period.call.update(contributor: mso_person("guard-other"))
    assert_not period.call.update(started_at: Date.new(2091, 4, 1)), "would drop March"
    assert_not period.call.update(ended_at: Date.new(2091, 4, 30)), "would drop May"

    record = period.call
    record.update(tier: :principal)
    assert_match(/end this period and start a new one/, record.errors[:tier].to_sentence)

    # What stays possible: ending it after the last month run, starting it
    # earlier, and renaming it.
    assert period.call.update(ended_at: Date.new(2091, 5, 31))
    assert period.call.update(started_at: Date.new(2090, 12, 1))
    assert period.call.update(title: "Operations and Finance")
    assert_equal "chief", period.call.tier
  end
end
```

Create `test/integration/admin_mso_role_period_guard_test.rb`:

```ruby
require "test_helper"

class AdminMsoRolePeriodGuardTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  test "deleting a role period a run has used is refused on the roster page, with the reason" do
    garden3d_qbo_account
    exec = mso_person("guard-ui-exec")
    role = mso_role(exec, started_at: Date.new(2091, 1, 1))
    mso_snapshot(garden3d_pass(Date.new(2091, 6, 1)), lines: [mso_line(role, garden3d_ledger(exec), trueup: "100.0")])
    sign_in mso_admin

    assert_no_difference -> { MsoRolePeriod.count } do
      delete admin_mso_role_period_path(role)
    end

    assert_redirected_to admin_mso_role_periods_path
    assert_match(/June 2091/, flash[:alert])

    patch admin_mso_role_period_path(role), params: { mso_role_period: { tier: "principal" } }
    assert_match(/end this period and start a new one/, response.body)
    assert_equal "chief", role.reload.tier
  ensure
    clear_enterprise_memos
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/lib/stacks/founder_trueup_mso_test.rb test/models/mso_role_period_run_guard_test.rb test/integration/admin_mso_role_period_guard_test.rb
```

Expected: 9 runs, 9 errors. Every founder test errors in `setup` with `NameError: uninitialized constant … FOUNDER_EMAIL`; the role-period tests error with `NoMethodError: undefined method 'months_run'` or see the destroy succeed.

- [ ] **Step 3: A founder true-up takes its bill with it**

In `app/models/trueup.rb`, directly below `validates :description, presence: true` (line 9), add:

```ruby

  # As ProfitShare and PayStub. Without this, deleting a founder true-up left
  # its bill open in QuickBooks, still payable. Reads the bill first and
  # raises SyncsAsQboBill::PaidQboBillError if it has any payment.
  before_destroy :detach_and_destroy_qbo_bill
```

The only code that destroys a `Trueup` is its admin page (`app/admin/trueups.rb:4` allows `:destroy`); nothing in `app/` or `lib/` calls `destroy` or `delete` on one, and no association has `dependent:` on it. A true-up with no bill, which is every one the tests create, is unaffected: the callback returns at once when there is no bill (`app/models/concerns/syncs_as_qbo_bill.rb:34-35`).

In `app/admin/trueups.rb`, directly below `belongs_to :ledger` (line 7), add:

```ruby

  controller do
    # Deleting a true-up now deletes its QuickBooks bill. A bill with a
    # payment refuses; show why instead of an error page.
    rescue_from SyncsAsQboBill::PaidQboBillError do |e|
      redirect_back fallback_location: admin_root_path, alert: e.message
    end
  end
```

(`app/admin/project_trackers.rb:72` handles the same error the same way.)

- [ ] **Step 4: The nightly sync skips MSO months**

In `lib/stacks/system.rb`, directly below `NEW_DEAL_START_AT = Date.new(2025, 6, 1)` (line 4), add a constant holding the address that line 96 already carries as a literal (copy the literal from line 96; it is not repeated in this plan):

```ruby

    # The founder, whose pay is topped up to the highest earner's each month
    # (sync_founder_trueups!) until they are paid through the MSO.
    FOUNDER_EMAIL = "<the literal from line 96>".freeze
```

Replace `sync_founder_trueups!` (lines 77-111) with the following. The body of the loop below the new `next` is the existing code, with line 96's lookup replaced by `hugh = founder`:

```ruby
    def founder_contributor
      ForecastPerson.find_by(email: FOUNDER_EMAIL)&.contributor
    end

    # Is, or was, the founder paid through the MSO for this month? Then the
    # founder true-up must not be written for it.
    #
    # Deliberately NOT just "is there a role period": the roster can be
    # edited, and this runs unattended every night and its output is billed
    # in QuickBooks the same night. A month counts as an MSO month if ANY of
    # these exist for the founder: an active role period; a line on any
    # snapshot (current or superseded); an MSO true-up, soft-deleted included.
    #
    # The table checks matter: migrations are run by hand on production after
    # the deploy.
    def founder_paid_by_mso?(founder, month)
      return false if founder.nil?

      roster_ready = ActiveRecord::Base.connection.data_source_exists?(MsoRolePeriod.table_name)
      return true if roster_ready && MsoRolePeriod.where(contributor_id: founder.id).active_during(month).exists?
      return false unless MsoTrueup.schema_ready?

      trueup = MsoTrueup.with_deleted.joins(:ledger, :invoice_pass)
        .where(ledgers: { contributor_id: founder.id }, invoice_passes: { start_of_month: month.beginning_of_month })
      return true if trueup.exists?

      MsoSnapshot.joins(:invoice_pass)
        .where(invoice_passes: { start_of_month: month.beginning_of_month })
        .where("mso_snapshots.lines @> ?", [{ contributor_id: founder.id }].to_json)
        .exists?
    end

    def sync_founder_trueups!
      founder = founder_contributor

      founder_trueup_months.each do |working_date|
        # Skipped entirely: nothing is written and an existing founder true-up
        # for this month is not touched. Mso::MonthlyRun refuses to run the
        # month while one exists, and deleting it removes its bill.
        next if founder_paid_by_mso?(founder, working_date)

        invoice_pass = InvoicePass
          .includes(invoice_trackers: :contributor_payouts)
          .where(start_of_month: working_date, enterprise: Enterprise.sanctuary)
          .first
        raise "No invoice pass found for #{working_date}" unless invoice_pass.present?

        contributor_payouts_by_contributor = invoice_pass.invoice_trackers.reduce({}) do |acc, invoice_tracker|
          invoice_tracker.contributor_payouts.each do |contributor_payout|
            acc[contributor_payout.contributor] ||= { payouts: [], amount: 0 }
            acc[contributor_payout.contributor][:payouts] << contributor_payout
            acc[contributor_payout.contributor][:amount] += contributor_payout.amount
          end
          acc
        end

        highest_contributor, highest_contributor_data = contributor_payouts_by_contributor.max_by{|k, v| v[:amount]}

        hugh = founder
        hugh_ledger = Ledger.find_or_create_for(enterprise: Enterprise.sanctuary, contributor: hugh)
        trueup = Trueup.find_or_initialize_by(invoice_pass: invoice_pass, ledger: hugh_ledger)
        founder_trueup_amount = highest_contributor_data[:amount] - contributor_payouts_by_contributor[hugh][:amount]

        trueup.update!(
          amount: founder_trueup_amount,
          description: <<~HEREDOC
          # Trueup for #{working_date.strftime("%B %Y")}
          - **Highest Paid Contributor:** #{highest_contributor.forecast_person.email}
          - **Amount:** #{ActionController::Base.helpers.number_to_currency(highest_contributor_data[:amount])}
          - **Trueup Amount:** #{ActionController::Base.helpers.number_to_currency(founder_trueup_amount)}
          HEREDOC
        )
      end
    end
```

`FOUNDER_EMAIL` sits inside `class << self`, like `NEW_DEAL_START_AT`, so it is read as `Stacks::System.singleton_class::FOUNDER_EMAIL` from outside (as `app/models/ledger.rb:139` reads the other). The jsonb containment test (`@>`) matches a line whose `contributor_id` is the founder's whatever its other keys are.

- [ ] **Step 5: A role period a run has used is protected**

In `app/models/mso_role_period.rb`, directly below `validate :full_months_only` (line 26), add:

```ruby
  validate :months_already_run_are_not_changed, on: :update
  before_destroy :refuse_destroy_once_run
```

and add these methods directly above `def full_months_only` (line 65):

```ruby
  # The first day of every month whose MSO run used this role period, from
  # any snapshot, current or superseded. A run records the period's id on
  # each line it writes.
  def months_run
    return [] if new_record? || !MsoTrueup.schema_ready?

    MsoSnapshot.joins(:invoice_pass)
      .where("mso_snapshots.lines @> ?", [{ mso_role_period_id: id }].to_json)
      .distinct.pluck("invoice_passes.start_of_month").sort
  end

  # Once a month has been run with this period, what it says about that month
  # is history. Changing it would change a past month on its next re-run, and
  # would let the nightly founder true-up come back for a month already paid
  # through the MSO. Ending the period going forward stays possible; a
  # promotion is "end this period and start a new one".
  def months_already_run_are_not_changed
    months = months_run
    return if months.empty?

    span = "#{months.first.strftime('%B %Y')} to #{months.last.strftime('%B %Y')}"
    advice = "MSO compensation has been run with this role period (#{span}). To change someone's tier, " \
             "end this period and start a new one."
    errors.add(:tier, advice) if tier_changed?
    errors.add(:contributor, advice) if contributor_id_changed?
    if started_at_changed? && started_at && started_at > months.first
      errors.add(:started_at, "cannot move past #{months.first.strftime('%B %Y')}, which has been run. #{advice}")
    end
    if ended_at_changed? && ended_at && ended_at < months.last.end_of_month
      errors.add(:ended_at, "cannot be before the end of #{months.last.strftime('%B %Y')}, which has been run. " \
                            "#{advice}")
    end
  end

  def refuse_destroy_once_run
    months = months_run
    return if months.empty?

    errors.add(:base, "MSO compensation has been run with this role period " \
                      "(#{months.map { |month| month.strftime('%B %Y') }.join(', ')}), so it cannot be deleted. " \
                      "Give it an end date instead.")
    throw :abort
  end
```

In `app/admin/mso_role_periods.rb`, inside the existing `controller do` block (lines 8-12), below `scoped_collection`, add:

```ruby

    # A role period a run has used refuses to be destroyed. Say why.
    def destroy
      destroy! do |_success, failure|
        failure.html do
          redirect_to admin_mso_role_periods_path, alert: resource.errors.full_messages.to_sentence
        end
      end
    end
```

A refused edit needs nothing here: the form already renders `f.semantic_errors` and field errors (`app/admin/mso_role_periods.rb:26`).

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/lib/stacks/founder_trueup_mso_test.rb test/lib/stacks/founder_trueup_scoping_test.rb test/lib/stacks/system_test.rb test/models/mso_role_period_run_guard_test.rb test/models/mso_role_period_test.rb test/integration/admin_mso_role_period_guard_test.rb test/integration/admin_mso_role_periods_test.rb
```

Expected: PASS. 9 new runs. The existing roster tests still pass: none of their periods has been used by a run.

If `delete_all!` in "moving the role's start later" is not the hard-delete this version of acts_as_paranoid provides (it is, `acts_as_paranoid/core.rb:37-39` in 0.7.0), use `MsoTrueup.unscoped.where(id: trueup.id).delete_all`.

- [ ] **Step 7: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 9 more runs than after Task 8 (baseline + 123), 0 failures, 0 errors. Tests that destroy a `Trueup` (`test/models/ledger/qualifying_income_test.rb`, `test/services/mso/benchmark_test.rb`) now run the new callback; none of their true-ups has a bill, so it returns at once.

- [ ] **Step 8: Commit**

```bash
git add app/models/trueup.rb app/admin/trueups.rb lib/stacks/system.rb app/models/mso_role_period.rb \
  app/admin/mso_role_periods.rb test/lib/stacks/founder_trueup_mso_test.rb \
  test/models/mso_role_period_run_guard_test.rb test/integration/admin_mso_role_period_guard_test.rb
git commit -m "feat(mso): the founder true-up stops where the MSO starts and cannot come back

The nightly sync rewrote and billed a founder true-up for every month. It
now skips any month the founder is or was paid for through the MSO, judged
by what was run and not only by the roster, so editing the roster cannot
bring one back. A role period a run has used cannot be deleted or changed
for the months it covered. Deleting a founder true-up now deletes its
QuickBooks bill instead of leaving it open."
```

---

### Task 10: Admin pages — run the month, read the snapshot, accept a true-up

**Files:**
- Create: `app/admin/mso_trueups.rb`, `app/views/admin/mso_trueups/_show.html.erb`
- Create: `app/admin/mso_snapshots.rb`
- Modify: `app/models/mso_snapshot.rb` (`display_name`)
- Modify: `app/admin/invoice_passes.rb`, `app/views/admin/invoice_passes/_management_fee_pass.html.erb`
- Modify: `app/views/admin/money/payable_qbo_bills.html.erb`
- Create: `test/integration/admin_mso_compensation_test.rb`

**Interfaces:**
- Consumes: `Mso::MonthlyRun.call`, `.runnable?`, `MsoSnapshot#check_collection!`, `MsoTrueup#toggle_acceptance!(expected_amount:)`, `#remove_qbo_bill!`, the Task 6 authorization
- Produces:
  - `POST /admin/invoice_passes/:id/run_mso_compensation` (admin)
  - `/admin/mso_snapshots`, `/admin/mso_snapshots/:id`, `POST …/check_collection` (admin)
  - `/admin/ledgers/:ledger_id/mso_trueups/:id` (owner or admin), `POST …/toggle_acceptance?amount=…` (**owner only**), `POST …/remove_qbo_bill` (admin)

garden3d's pass page is itself becoming admin-only to view (owner decision O3, an S1 change). Every action here keeps its own admin guard anyway; none relies on who can open the page it is linked from.

Nothing here writes a bill to QuickBooks. The two QuickBooks-touching buttons are **Check collection** (reads the month's fee invoices) and **Remove QuickBooks bill** (deletes one bill, refused if it has any payment); both are an admin's click.

- [ ] **Step 1: Write the failing test**

Create `test/integration/admin_mso_compensation_test.rb`:

```ruby
require "test_helper"

class AdminMsoCompensationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  MONTH = Date.new(2094, 3, 1)

  setup do
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @admin = mso_admin
    @lead = AdminUser.create!(email: "mso-ui-lead-#{SecureRandom.hex(3)}@example.com", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    @exec = mso_person("ui-exec")
    @other = mso_person("ui-other")
    @exec_login = login_for(@exec)
    @other_login = login_for(@other)
    role = mso_role(@exec)
    other_role = mso_role(@other, tier: :principal)
    @ledger = garden3d_ledger(@exec)
    @other_ledger = garden3d_ledger(@other)
    @lines = [mso_line(role, @ledger, trueup: "1234.56"), mso_line(other_role, @other_ledger, trueup: "6543.21")]
    @snapshot = mso_snapshot(@pass, lines: @lines)
    @mine = mso_trueup(@snapshot, role, @ledger, amount: "1234.56")
    @theirs = mso_trueup(@snapshot, other_role, @other_ledger, amount: "6543.21")

    # No page here may reach QuickBooks unless its test says so.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  teardown do
    clear_enterprise_memos
  end

  def assert_not_authorized
    # ActiveAdmin redirects an unauthorized user with a flash error. Asserting
    # both means a silently failed sign-in cannot pass.
    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
  end

  def accept(ledger, trueup, amount: trueup.amount.to_s("F"))
    post toggle_acceptance_admin_ledger_mso_trueup_path(ledger, trueup, amount: amount)
  end

  test "an admin can list snapshots and read one in full" do
    sign_in @admin

    get admin_mso_snapshots_path
    assert_response :success
    assert_match(/March 2094/, response.body)

    get admin_mso_snapshot_path(@snapshot)
    assert_response :success
    assert_match(/1,234\.56/, response.body)
    assert_match(/6,543\.21/, response.body)
    assert_match(/100,000\.00/, response.body) # fee income
    assert_match(/55,000\.00/, response.body)  # the cap
    assert_match(/Check collection/, response.body)
    assert_no_match(/NO LONGER VALID|more than the cap/, response.body)
  end

  test "a superseded snapshot is drawn from its own lines; an invalid or over-cap one says so loudly" do
    @snapshot.update_columns(superseded_at: Time.current)
    replacement = MsoSnapshot.create!(
      invoice_pass: @pass, sanctuary_invoice_pass: @snapshot.sanctuary_invoice_pass, fee_income: "10000",
      benchmark_average: "20000.0", configured_n: 3, counted: 3, cap_percentage: "0.55", cap: "5500",
      total_calculated: "20000.0", total_trueup: "5500", total_trueup_as_billed: "7777.77", lines: @lines,
    )
    @snapshot.update_columns(superseded_by_id: replacement.id)
    replacement.invalidate!("Account 4100 now reads 9000.0")
    sign_in @admin

    get admin_mso_snapshot_path(@snapshot)
    assert_response :success
    assert_match(/1,234\.56/, response.body)
    assert_match(/As run; see the current snapshot/, response.body)
    assert_no_match(/>Missing</, response.body)
    assert_no_match(/Check collection/, response.body)

    get admin_mso_snapshot_path(replacement)
    assert_response :success
    assert_match(/NO LONGER VALID/, response.body)
    assert_match(/Account 4100 now reads 9000\.0/, response.body)
    assert_match(/more than the cap/, response.body)
    assert_match(/7,777\.77/, response.body)
    assert_no_match(/Check collection/, response.body)
  end

  test "a lead cannot list or open a snapshot" do
    sign_in @lead

    get admin_mso_snapshots_path
    assert_not_authorized

    get admin_mso_snapshot_path(@snapshot)
    assert_not_authorized
  end

  test "an executive can open their own true-up, and neither another's nor the snapshot" do
    sign_in @exec_login

    get admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_response :success
    assert_match(/1,234\.56/, response.body)
    assert_no_match(/6,543\.21/, response.body)

    get admin_ledger_mso_trueup_path(@other_ledger, @theirs)
    assert_not_authorized

    get admin_mso_snapshot_path(@snapshot)
    assert_not_authorized
  end

  test "a true-up's page gives its figures to nobody else as JSON either" do
    [@lead, @other_login].each do |viewer|
      sign_in viewer
      get admin_ledger_mso_trueup_path(@ledger, @mine, format: :json)

      assert_not response.successful?, "#{viewer.email} must not get the true-up as JSON"
      assert_no_match(/1234\.56/, response.body)
      sign_out viewer
    end

    sign_in @lead
    get admin_mso_snapshot_path(@snapshot, format: :json)
    assert_not response.successful?
    assert_no_match(/1234\.56|6543\.21/, response.body)
  end

  test "an executive can accept their own true-up and not another's" do
    sign_in @exec_login

    accept(@ledger, @mine)
    assert_response :redirect
    assert @mine.reload.accepted?

    accept(@other_ledger, @theirs)
    assert_not_authorized
    assert_not @theirs.reload.accepted?
  end

  # Both executives are admins in production. Seeing is one thing (unchanged);
  # accepting on the other's behalf must be impossible, by URL as well.
  test "an admin cannot accept a true-up that is not theirs, not even another executive who is an admin" do
    @other_login.update!(roles: ["admin"])

    [@admin, AdminUser.find(@other_login.id)].each do |viewer|
      sign_in viewer
      get admin_ledger_mso_trueup_path(@ledger, @mine)
      assert_response :success, "an admin can still see it"
      assert_no_match(/toggle_acceptance/, response.body)

      accept(@ledger, @mine)

      assert_not_authorized
      assert_not @mine.reload.accepted?
      sign_out viewer
    end
  end

  test "accepting a figure that has changed since the page was shown is refused" do
    sign_in @exec_login

    accept(@ledger, @mine, amount: "999.99")
    assert_response :redirect
    assert_match(/not the figure you were shown/, flash[:alert])
    assert_not @mine.reload.accepted?

    post toggle_acceptance_admin_ledger_mso_trueup_path(@ledger, @mine) # no amount at all
    assert_response :redirect
    assert_match(/accept it from there/, flash[:alert])
    assert_not @mine.reload.accepted?
  end

  test "a lead can neither open nor accept a true-up" do
    sign_in @lead

    get admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_not_authorized

    accept(@ledger, @mine)
    assert_not_authorized
    assert_not @mine.reload.accepted?
  end

  test "a true-up with a QuickBooks bill cannot be un-accepted" do
    @mine.update_columns(accepted_at: Time.current, qbo_bill_id: "5")
    sign_in @exec_login

    accept(@ledger, @mine)

    assert_response :redirect
    assert_match(/QuickBooks bill/, flash[:alert])
    assert @mine.reload.accepted?
  end

  test "an admin can remove a true-up's QuickBooks bill, and a paid bill is refused with the reason" do
    @mine.update_columns(accepted_at: Time.current, qbo_bill_id: "5")
    sign_in @admin

    MsoTrueup.any_instance.expects(:detach_and_destroy_qbo_bill).once
    post remove_qbo_bill_admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_response :redirect
    assert_match(/removed/, flash[:notice])
    assert_not @mine.reload.accepted?, "it must be accepted afresh after the next run"
    assert @snapshot.reload.invalidated?

    MsoTrueup.any_instance.expects(:detach_and_destroy_qbo_bill).once
      .raises(SyncsAsQboBill::PaidQboBillError, "refusing to destroy QBO bill 5")
    post remove_qbo_bill_admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_response :redirect
    assert_match(/refusing to destroy/, flash[:alert])

    sign_out @admin
    sign_in @exec_login
    post remove_qbo_bill_admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_not_authorized
  end

  test "an admin runs the month from garden3d's pass and lands on the snapshot" do
    sign_in @admin

    get admin_invoice_pass_path(@pass)
    assert_response :success
    assert_match(/Run MSO compensation/, response.body)

    Mso::MonthlyRun.expects(:call).with(invoice_pass: @pass, run_by: @admin).once.returns(@snapshot)
    post run_mso_compensation_admin_invoice_pass_path(@pass)

    assert_redirected_to admin_mso_snapshot_path(@snapshot)
  end

  test "a refused run shows the reason on the pass" do
    sign_in @admin
    Mso::MonthlyRun.stubs(:call).raises(Mso::MonthlyRun::Refused, "March 2094 has not ended.")

    post run_mso_compensation_admin_invoice_pass_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/has not ended/, flash[:alert])
  end

  # Whether a lead can even open garden3d's pass is S1's rule (it is becoming
  # admin-only). The run has its own guard regardless.
  test "a lead cannot post the run or Check collection" do
    sign_in @lead
    Mso::MonthlyRun.stubs(:call).raises(RuntimeError, "a lead reached the run")
    Mso::ManagementFeeInvoices.stubs(:collected?).raises(RuntimeError, "a lead reached QuickBooks")

    post run_mso_compensation_admin_invoice_pass_path(@pass)
    assert_not_authorized

    post check_collection_admin_mso_snapshot_path(@snapshot)
    assert_not_authorized
    assert_not @snapshot.reload.fee_collected?
  end

  test "Check collection asks QuickBooks once and records the answer" do
    sign_in @admin
    Mso::ManagementFeeInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(true)

    post check_collection_admin_mso_snapshot_path(@snapshot)

    assert_redirected_to admin_mso_snapshot_path(@snapshot)
    assert_match(/collected/, flash[:notice])
    assert @snapshot.reload.fee_collected?
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/integration/admin_mso_compensation_test.rb
```

Expected: 15 runs, 15 errors, each a `NameError` or `NoMethodError` for a route helper that does not exist yet (`admin_mso_snapshots_path`, `admin_ledger_mso_trueup_path`, `run_mso_compensation_admin_invoice_pass_path`).

- [ ] **Step 3: The true-up page**

Create `app/admin/mso_trueups.rb`:

```ruby
ActiveAdmin.register MsoTrueup do
  config.filters = false
  config.paginate = false
  menu false
  # :show only. There is no index (the list of everyone's true-ups is the
  # snapshot, which is admin-only) and no new, edit or destroy:
  # Mso::MonthlyRun is the only thing that writes a true-up.
  #
  # AdminAuthorization lets an admin, or the executive whose ledger this is
  # on, read it. Only that executive may accept it; not even an admin can
  # accept for them.
  actions :show

  belongs_to :ledger

  action_item :toggle_acceptance, only: :show,
    if: proc { !resource.locked? && authorized?(:toggle_acceptance, resource) } do
    # The amount goes with the click: if a run has changed it since this page
    # was drawn, the acceptance is refused rather than landing on a figure
    # the person never saw.
    link_to (resource.accepted? ? "Unaccept" : "Accept"),
      toggle_acceptance_admin_ledger_mso_trueup_path(resource.ledger, resource, amount: resource.amount.to_s("F")),
      method: :post
  end

  action_item :remove_qbo_bill, only: :show,
    if: proc { current_admin_user.is_admin? && resource.locked? } do
    link_to "Remove QuickBooks bill",
      remove_qbo_bill_admin_ledger_mso_trueup_path(resource.ledger, resource),
      method: :post,
      data: { confirm: "Delete this true-up's bill in QuickBooks? Stacks checks QuickBooks first and refuses " \
                       "if the bill has any payment. The true-up will need accepting again, and the month " \
                       "must be run again before anything from it can be paid." }
  end

  member_action :toggle_acceptance, method: :post do
    # `resource` has already been authorized as :toggle_acceptance, which
    # AdminAuthorization grants to the owner alone. Checked again here.
    owner = resource.contributor.forecast_person&.admin_user
    unless owner.present? && owner == current_admin_user
      redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
        alert: "Only the person a true-up belongs to can accept it."
      return
    end

    resource.toggle_acceptance!(expected_amount: params.require(:amount))
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
      notice: resource.accepted? ? "Accepted." : "Acceptance withdrawn."
  rescue MsoTrueup::Locked, MsoTrueup::AmountChanged => e
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource), alert: e.message
  rescue ActionController::ParameterMissing
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
      alert: "Open the true-up and accept it from there."
  end

  # The one way to unlock a true-up whose amount needs to change. Reads the
  # bill from QuickBooks, refuses if it has any payment, deletes it, clears
  # the acceptance and invalidates the snapshot (MsoTrueup#remove_qbo_bill!).
  member_action :remove_qbo_bill, method: :post do
    unless current_admin_user.is_admin?
      redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource), alert: "Only an admin can remove a bill."
      return
    end
    resource.remove_qbo_bill!
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
      notice: "The QuickBooks bill was removed. Run the month again; this true-up will then need accepting again."
  rescue SyncsAsQboBill::PaidQboBillError => e
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource), alert: e.message
  end

  show do
    render partial: "show", locals: { resource: resource }
  end
end
```

`remove_qbo_bill!` (Task 8) wraps `detach_and_destroy_qbo_bill`, the existing guard every bill host uses: it re-reads the bill, fails closed if QuickBooks cannot be reached and raises `PaidQboBillError` if any payment exists (`app/models/concerns/syncs_as_qbo_bill.rb:33-77`). The explicit owner check in `toggle_acceptance` repeats what `AdminAuthorization` already enforces, as `app/admin/pay_stubs.rb:43-47` does; unlike a pay stub, an admin is not let through.

Create `app/views/admin/mso_trueups/_show.html.erb`:

```erb
<%= link_to "Ledger ↗", admin_contributor_path(resource.contributor, ledger: resource.ledger_id), class: "nag", style: "margin-right: 6px;" %>

<span class="pill <%= resource.accepted? ? "accepted" : "pending" %>" style="margin-right: 6px;">
  <%= resource.accepted? ? "Accepted" : "Awaiting acceptance by the person it belongs to" %>
</span>
<span class="pill <%= resource.payable? ? "paid" : "pending" %>" style="margin-right: 6px;">
  <%= resource.payable? ? "Payable" : "Not yet payable" %>
</span>

<% if current_admin_user.is_admin? %>
  <%= link_to "Snapshot ↗", admin_mso_snapshot_path(resource.mso_snapshot), class: "nag", style: "margin-right: 6px;" %>
  <% if resource.qbo_bill.present? %>
    <a href="<%= resource.qbo_bill.qbo_url %>" target="_blank" rel="noopener">
      <p class="nag" style="margin-bottom: 0px;margin-right: 6px;">QBO Bill ↗</p>
    </a>
  <% end %>
<% end %>

<div class="dashboard-modules table index_table index" style="margin-top:20px;">
  <div class="dashboard-module">
    <div class="module-header">
      <p>MSO true-up, <%= resource.payment_date.strftime("%B %Y") %>: <%= number_to_currency(resource.amount) %></p>
    </div>
    <div class="module-body markdown-body">
      <%= sanitize RDiscount.new(resource.description || "").to_html %>
      <% unless resource.payable? %>
        <p>
          This becomes payable once every executive has accepted their own true-up for the month and garden3d's
          management fee for the month has been confirmed as collected. It is dated
          <%= resource.payment_date.strftime("%m/%d/%Y") %>, the last day of the month it is for.
        </p>
      <% end %>
    </div>
  </div>
</div>
```

- [ ] **Step 4: The snapshot pages**

In `app/models/mso_snapshot.rb`, directly below `def month … end`, add:

```ruby

  # ActiveAdmin's page title and breadcrumb.
  def display_name
    "MSO compensation, #{invoice_pass.invoice_month}#{current? ? '' : ' (superseded)'}"
  end
```

Create `app/admin/mso_snapshots.rb`:

```ruby
# The record of each run of a month's MSO compensation: fee income, the cap,
# the benchmark and every executive's line. ADMINS ONLY, for every action;
# AdminAuthorization enforces it above the blanket lead grant, and the menu
# item is hidden from everyone else because they cannot :read the class.
ActiveAdmin.register MsoSnapshot do
  menu label: "MSO Compensation", parent: "Money"
  config.filters = false
  config.sort_order = "created_at_desc"
  # Read-only. A snapshot is written by Mso::MonthlyRun and never edited.
  actions :index, :show

  controller do
    def scoped_collection
      super.includes(:invoice_pass)
    end
  end

  index download_links: false, title: "MSO Compensation" do
    column(:month) { |snapshot| snapshot.invoice_pass.invoice_month }
    column(:status) do |snapshot|
      if !snapshot.current? then "Superseded"
      elsif snapshot.invalidated? then "INVALID — run again"
      else "Current"
      end
    end
    column(:fee_income) { |snapshot| number_to_currency(snapshot.fee_income) }
    column(:cap) { |snapshot| number_to_currency(snapshot.cap) }
    column(:benchmark) { |snapshot| number_to_currency(BigDecimal(snapshot.benchmark_average)) }
    column(:total_true_up) { |snapshot| number_to_currency(snapshot.total_trueup) }
    column(:fee_collected) { |snapshot| snapshot.fee_collected? ? "Yes" : "No" }
    column(:warnings) do |snapshot|
      [("over the cap" if snapshot.over_cap?), ("#{snapshot.drift.size} billed row(s) differ" if snapshot.drift.any?)]
        .compact.join("; ")
    end
    column :created_at
    actions
  end

  action_item :check_collection, only: :show, if: proc { resource.current? && !resource.invalidated? } do
    link_to "Check collection", check_collection_admin_mso_snapshot_path(resource), method: :post,
      data: { confirm: "Read this month's management fee invoices from QuickBooks and record whether the " \
                       "fee has been paid?" }
  end

  # One QuickBooks READ per fee invoice. The answer is stamped on the
  # snapshot; MsoTrueup#payable? reads the stamp and never QuickBooks.
  member_action :check_collection, method: :post do
    unless current_admin_user.is_admin?
      redirect_to admin_root_path, alert: "Only an admin can check collection."
      return
    end

    begin
      collected = resource.check_collection!
    rescue Mso::ManagementFeeInvoices::Error, MsoSnapshot::Unusable => e
      redirect_to admin_mso_snapshot_path(resource), alert: e.message.truncate(1200)
      return
    end

    if collected
      redirect_to admin_mso_snapshot_path(resource),
        notice: "The management fee has been collected. True-ups are payable once every executive accepts."
    else
      redirect_to admin_mso_snapshot_path(resource),
        alert: "The management fee has not been collected in full. That is also the answer when a paying " \
               "company has no tracker or no invoice on the pass, an invoice is dated outside the month, or " \
               "QuickBooks holds an invoice to a payer for the month that is not attached. True-ups for this " \
               "month are not payable."
    end
  end

  show title: :display_name do
    snapshot = resource
    money = ->(value) { number_to_currency(BigDecimal(value.to_s)) }
    contributor_ids = (snapshot.lines + snapshot.benchmark_members + snapshot.excluded_without_login)
      .map { |entry| entry["contributor_id"] }.uniq
    contributors = Contributor.where(id: contributor_ids).includes(:forecast_person).index_by(&:id)
    name_for = ->(id) { contributors[id]&.display_name || "Contributor ##{id}" }
    # Only the current snapshot's lines correspond to rows that exist now. A
    # superseded snapshot is drawn from its own stored lines alone: today's
    # rows belong to a later run.
    trueups = snapshot.current? ? MsoTrueup.with_deleted.where(mso_snapshot_id: snapshot.id).index_by(&:ledger_id) : {}

    if snapshot.current? && snapshot.invalidated?
      panel "THIS RUN IS NO LONGER VALID — nothing from it is payable" do
        para snapshot.invalidated_reason
        para "Invalidated #{l(snapshot.invalidated_at, format: :long)}. Run the month again from garden3d's " \
             "pass; confirming collection will not restore this run."
      end
    end

    if snapshot.over_cap?
      panel "WARNING: what is owed is more than the cap" do
        para "Counting true-ups that already have a QuickBooks bill at their billed amounts, this month's " \
             "true-ups total #{money.call(snapshot.total_trueup_as_billed)}, against a cap of " \
             "#{money.call(snapshot.cap)}. The fee income fell after a bill was written. A person has to " \
             "decide what to do about the billed rows listed under Drift."
      end
    end

    attributes_table do
      row("Month") { link_to snapshot.invoice_pass.invoice_month, admin_invoice_pass_path(snapshot.invoice_pass) }
      row("Status") do
        if snapshot.current?
          snapshot.invalidated? ? "Current, but INVALID" : "Current"
        elsif snapshot.superseded_by
          link_to "Superseded #{l(snapshot.superseded_at, format: :short)} — see the run that replaced it",
            admin_mso_snapshot_path(snapshot.superseded_by)
        else
          "Superseded"
        end
      end
      row("Run") { "#{l(snapshot.created_at, format: :long)}#{snapshot.created_by ? " by #{snapshot.created_by.email}" : ''}" }
      row("Management fee income (account 4100)") { money.call(snapshot.fee_income) }
      row("Cap") { "#{money.call(snapshot.cap)} (#{(snapshot.cap_percentage * 100).to_s('F')}% of fee income)" }
      row("Benchmark average") do
        "#{snapshot.benchmark_average} — top #{snapshot.configured_n}, #{snapshot.counted} counted" \
          "#{snapshot.small_sample ? ' (fewer earners than the setting)' : ''}"
      end
      row("Total calculated") { money.call(snapshot.total_calculated) }
      row("Total true-up") { money.call(snapshot.total_trueup) }
      row("Total true-up, counting billed rows as billed") { money.call(snapshot.total_trueup_as_billed) }
      row("Fee collected") do
        snapshot.fee_collected? ? "Confirmed #{l(snapshot.fee_collected_at, format: :short)}" : "Not confirmed"
      end
      if snapshot.current?
        row("Every expected true-up accepted") { snapshot.all_expected_trueups_accepted? ? "Yes" : "No" }
      end
    end

    if snapshot.drift.any?
      panel "Drift: true-ups that already have a QuickBooks bill and were not changed" do
        table_for snapshot.drift do
          column("True-up") { |entry| "MsoTrueup ##{entry['mso_trueup_id']}" }
          column("Billed") { |entry| money.call(entry["billed_amount"]) }
          column("This run computed") { |entry| money.call(entry["computed_amount"]) }
        end
        para "Each of these needs a person to decide what to do. To change one, remove its QuickBooks bill " \
             "from the true-up's page and run the month again."
      end
    end

    panel "Executives" do
      table_for snapshot.lines do
        column("Executive") { |line| link_to name_for.call(line["contributor_id"]), admin_contributor_path(line["contributor_id"], ledger: line["ledger_id"]) }
        column("Role") { |line| "#{line['tier'].to_s.titleize} (#{line['title']}), #{line['multiplier']}x" }
        column("Calculated") { |line| money.call(line["calculated"]) }
        column("Reduction") { |line| money.call(line["reduction"]) }
        column("After cap") { |line| money.call(line["final"]) }
        column("Already earned") { |line| money.call(line["already_earned"]) }
        column("True-up") { |line| money.call(line["trueup"]) }
        column("Row") do |line|
          trueup = trueups[line["ledger_id"]]
          if !snapshot.current?
            "As run; see the current snapshot"
          elsif trueup.nil?
            BigDecimal(line["trueup"].to_s).positive? ? "Missing" : "None owed"
          elsif trueup.deleted_at.present?
            "Removed"
          else
            link_to "#{trueup.accepted? ? 'Accepted' : 'Awaiting acceptance'}#{trueup.locked? ? ', billed' : ''} ↗",
              admin_ledger_mso_trueup_path(trueup.ledger_id, trueup)
          end
        end
      end
    end

    panel "Benchmark: the earners averaged" do
      table_for snapshot.benchmark_members do
        column("Contributor") { |member| name_for.call(member["contributor_id"]) }
        column("Qualifying income") { |member| money.call(member["amount"]) }
      end
      if snapshot.excluded_without_login.any?
        para "Left out for having no Stacks login, though they would have ranked: " +
             snapshot.excluded_without_login.map { |entry| "#{name_for.call(entry['contributor_id'])} (#{money.call(entry['amount'])})" }.join(", ")
      end
    end

    panel "Fee income reconciliation" do
      reconciliation = snapshot.reconciliation
      para "Account 4100: #{money.call(reconciliation['account_total'] || 0)}. " \
           "Managerial Services on attached invoices: #{money.call(reconciliation['payer_total'] || 0)}."
      table_for(reconciliation["invoices"] || []) do
        column("QuickBooks invoice") { |invoice| invoice["qbo_id"] }
        column("Total") { |invoice| money.call(invoice["total"]) }
        column("Managerial Services") { |invoice| money.call(invoice["managerial_services"]) }
      end
    end
  end
end
```

A line's `reduction` under the cap is not exactly zero: the calculator reports `calculated − final`, and `final` is `calculated` rounded to cents (`app/services/mso/compensation.rb:65,97`), so September 2026's hypothetical lines carry `0.0028…`. The page shows it rounded to cents.

- [ ] **Step 5: The run button on garden3d's pass**

In `app/admin/invoice_passes.rb`, directly below the `refresh_management_fee_invoices` action item (it ends at line 92), add:

```ruby

  # Computes every MSO executive's true-up for the month and records the run.
  # An admin's click and nothing else: no rake task or job calls it. It reads
  # the month's fee invoices from QuickBooks and writes nothing there.
  action_item :run_mso_compensation, only: :show,
    if: proc { current_admin_user.is_admin? && Mso::MonthlyRun.runnable?(resource) } do
    link_to "Run MSO compensation",
      run_mso_compensation_admin_invoice_pass_path(resource),
      method: :post,
      data: { confirm: "Compute MSO compensation for #{resource.invoice_month}? Stacks reads this month's " \
                       "management fee invoices from QuickBooks, checks them against account 4100, and " \
                       "writes each executive's true-up, dated the last day of the month. Running a month " \
                       "again replaces its figures." }
  end
```

Directly below the `refresh_management_fee_invoices` member action (it ends at line 142), add:

```ruby

  member_action :run_mso_compensation, method: :post do
    # Kept even though the pass page is itself admin-only to view.
    unless current_admin_user.is_admin?
      return redirect_to admin_invoice_pass_path(resource), alert: "MSO compensation is run by an admin."
    end

    begin
      snapshot = Mso::MonthlyRun.call(invoice_pass: resource, run_by: current_admin_user)
    rescue Mso::MonthlyRun::Refused => e
      # truncate: the flash lives in the session cookie, and a variance
      # message lists every invoice it compared.
      return redirect_to admin_invoice_pass_path(resource), alert: e.message.truncate(1200)
    end

    redirect_to admin_mso_snapshot_path(snapshot),
      notice: "MSO compensation for #{resource.invoice_month} has been computed. Nobody is paid until every " \
              "executive accepts and the fee is confirmed collected."
  end
```

`:run_mso_compensation` is already admin-only on the server (Task 6, `MANAGEMENT_FEE_PASS_ADMIN_ACTIONS`); the `if:` only hides the button.

At the very end of `app/views/admin/invoice_passes/_management_fee_pass.html.erb` (below line 64), add:

```erb

<%# Admins only, whoever may open this pass: the snapshot is executive compensation. %>
<% if current_admin_user.is_admin? && MsoTrueup.schema_ready? %>
  <% mso_snapshot = MsoSnapshot.current.find_by(invoice_pass_id: invoice_pass.id) %>
  <% if mso_snapshot %>
    <p style="margin-top: 20px;">
      <%= link_to "MSO compensation for this month ↗", admin_mso_snapshot_path(mso_snapshot) %>
    </p>
  <% end %>
<% end %>
```

- [ ] **Step 6: The Money page's row link**

In `app/views/admin/money/payable_qbo_bills.html.erb`, add one arm to `ledger_item_path` directly below the `PayStub` arm (line 27):

```erb
  when MsoTrueup               then admin_ledger_mso_trueup_path(li.ledger, li)
```

This is spec §9.7 #6. It is done here, not in Task 4, because the route does not exist until this task registers the page.

- [ ] **Step 7: Run the test to verify it passes**

```bash
bin/rails test test/integration/admin_mso_compensation_test.rb test/integration/admin_management_fee_invoices_test.rb test/integration/payable_qbo_bills_test.rb
```

Expected: PASS. 15 new runs.

- [ ] **Step 8: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 15 more runs than after Task 9 (baseline + 138), 0 failures, 0 errors.

- [ ] **Step 9: Commit**

```bash
git add app/admin/mso_trueups.rb app/views/admin/mso_trueups/_show.html.erb app/admin/mso_snapshots.rb \
  app/models/mso_snapshot.rb app/admin/invoice_passes.rb \
  app/views/admin/invoice_passes/_management_fee_pass.html.erb \
  app/views/admin/money/payable_qbo_bills.html.erb test/integration/admin_mso_compensation_test.rb
git commit -m "feat(mso): run a month's MSO compensation, read its snapshot, accept a true-up

An admin runs the month from garden3d's pass and lands on the snapshot,
which only admins can open. An executive opens their own true-up and is the
only person who can accept it; the click carries the amount they saw. Check
collection asks QuickBooks whether the fee was paid. The snapshot page says
loudly when a run is no longer valid or what is owed exceeds the cap."
```

---

### Task 11: The ledger page shows a true-up to its owner and to admins, and to nobody else

Any lead can open any contributor's ledger page (`app/models/admin_authorization.rb:107`), and that page lists every ledger item and totals them. Without this task an MSO true-up would be visible there, in the row list, in the Balance and Unsettled cards, in each ledger tab's pills and in the "Elevated Service … $X" badge.

**Files:**
- Modify: `app/models/contributor.rb`
- Modify: `app/admin/contributors.rb`
- Modify: `app/views/admin/contributors/_show.html.erb`, `app/views/admin/contributors/_ledger_tabs.html.erb`
- Modify: `app/views/admin/admin_users/_show.html.erb`
- Create: `test/integration/admin_contributor_mso_trueup_test.rb`

**Interfaces:**
- Consumes: the `include_mso_trueups:` switches from Tasks 2 and 3
- Produces: `Contributor#mso_trueups_visible_to?(admin_user) -> Boolean`

- [ ] **Step 1: Write the failing test**

Create `test/integration/admin_contributor_mso_trueup_test.rb`:

```ruby
require "test_helper"

class AdminContributorMsoTrueupTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  # A month near today: the ledger page renders every month from June 2025 to
  # two months past its latest item.
  MONTH = Date.new(2026, 11, 1)

  setup do
    garden3d_qbo_account
    @pass = InvoicePass.find_or_create_by!(enterprise: garden3d, start_of_month: MONTH) { |pass| pass.data = {} }
    @admin = mso_admin
    @lead = AdminUser.create!(email: "ledger-lead-#{SecureRandom.hex(3)}@example.com", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
    @exec = mso_person("ledger-page-exec")
    @ledger = garden3d_ledger(@exec)
    role = mso_role(@exec, started_at: Date.new(2026, 10, 1))
    snapshot = mso_snapshot(@pass, lines: [mso_line(role, @ledger, trueup: "4321.09")])
    @trueup = mso_trueup(snapshot, role, @ledger, amount: "4321.09")

    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
  end

  teardown do
    clear_enterprise_memos
  end

  def ledger_page
    get admin_contributor_path(@exec, ledger: @ledger.id)
    assert_response :success
    response.body
  end

  test "who may see an executive's MSO true-ups" do
    assert_equal true, @exec.mso_trueups_visible_to?(@admin)
    assert_equal true, @exec.mso_trueups_visible_to?(login_for(@exec))
    assert_equal false, @exec.mso_trueups_visible_to?(@lead)
    assert_equal false, @exec.mso_trueups_visible_to?(login_for(mso_person("ledger-page-other")))
    assert_equal false, @exec.mso_trueups_visible_to?(nil)
  end

  test "the executive sees their true-up on their own ledger, with a way to accept it" do
    sign_in login_for(@exec)

    body = ledger_page

    assert_match(/4,321\.09/, body)
    assert_match(/Mso trueup/i, body)
    assert_includes body, ERB::Util.html_escape(
      toggle_acceptance_admin_ledger_mso_trueup_path(@ledger, @trueup, amount: "4321.09"),
    )
  end

  test "an admin sees it too, but is not offered the owner's Accept" do
    sign_in @admin

    body = ledger_page

    assert_match(/4,321\.09/, body)
    assert_not_includes body, "toggle_acceptance"
  end

  test "a lead sees neither the row nor its amount in any total" do
    sign_in @lead

    body = ledger_page

    assert_no_match(/4,321/, body)
    assert_no_match(/mso_trueups/, body)
    assert_no_match(/Mso trueup/i, body)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/integration/admin_contributor_mso_trueup_test.rb
```

Expected: 4 runs. The first errors with `NoMethodError: undefined method 'mso_trueups_visible_to?'`. The second and third fail or error inside the page: the row has no branch for the new class. The fourth fails: a lead sees `4,321`.

No existing test renders this page. If the three page tests error for a reason unrelated to this task (the page needs something the test database lacks), stop and report what; do not weaken them to model-level assertions without saying so.

- [ ] **Step 3: The predicate**

In `app/models/contributor.rb`, directly below `deel_invoice_actions_visible_to?` (it ends at line 301), add:

```ruby

  # An MSO true-up is executive compensation. Its rows and its amount are
  # shown to admins and to the executive themself; anyone else who can open
  # this contributor's page (every lead can) sees the ledger without them.
  def mso_trueups_visible_to?(admin_user)
    return false if admin_user.nil?
    admin_user.is_admin? || forecast_person&.admin_user == admin_user
  end
```

- [ ] **Step 4: The page**

In `app/admin/contributors.rb`, in the `show` block:

Directly below `resource.preload_for_ledger_view!` (line 261), add:

```ruby

    # Executive compensation: rows and totals are computed without MSO
    # true-ups unless the viewer is an admin or this contributor.
    show_mso_trueups = resource.mso_trueups_visible_to?(current_admin_user)
```

Replace the `items_result` assignment (lines 296-301) with:

```ruby
    items_result =
      if view_mode == :all
        resource.all_items_grouped_by_month(min_ends_at: floor, include_mso_trueups: show_mso_trueups)
      else
        current_ledger.items_grouped_by_month(min_ends_at: floor, include_mso_trueups: show_mso_trueups)
      end
```

Replace the `balance` assignment (lines 317-322) with:

```ruby
    balance =
      if view_mode == :ledger && current_ledger
        {
          balance: current_ledger.balance(include_mso_trueups: show_mso_trueups).to_f,
          unsettled: current_ledger.unsettled(include_mso_trueups: show_mso_trueups).to_f,
        }
      else
        resource.new_deal_balance(nil, include_mso_trueups: show_mso_trueups)
      end
```

In the `render(partial: "show", locals: { … })` call (lines 336-350), add one local below `runn_link: runn_link,`:

```ruby
      include_mso_trueups: show_mso_trueups,
```

In `app/views/admin/contributors/_show.html.erb`:

Replace the `render 'ledger_tabs'` call (lines 1-5) with:

```erb
<%= render 'ledger_tabs',
      contributor: contributor,
      ledgers: ledgers,
      current_ledger: current_ledger,
      view_mode: view_mode,
      include_mso_trueups: include_mso_trueups %>
```

Change line 142 (the date cell) from `<% elsif li.is_a?(Trueup) %>` to:

```erb
              <% elsif li.is_a?(Trueup) || li.is_a?(MsoTrueup) %>
```

Directly above line 198 (the status cell's `<% elsif li.is_a?(Trueup) %>`), add:

```erb
              <% elsif li.is_a?(MsoTrueup) %>
                <% if li.deleted_at.present? %>
                  <span class="pill deleted">Deleted</span>
                <% else %>
                  <span class="pill <%= li.payable? ? "paid" : "pending" %>">
                    MSO true-up
                    <span class="split"><%= li.payable? ? "Payable" : "Not yet payable" %></span>
                  </span>
                <% end %>
```

Directly above line 290 (the amount cell's `<% elsif li.is_a?(Trueup) %>`), add:

```erb
              <% elsif li.is_a?(MsoTrueup) %>
                <% if li.deleted_at.present? %>
                  <del><%= number_to_currency(li.amount) %></del>
                <% else %>
                  + <%= number_to_currency(li.amount) %>

                  <span class="pill <%= li.accepted? ? "accepted" : "pending" %>" style="margin-right: 6px;">
                    <%= li.accepted? ? "Accepted" : "Pending" %>
                    <%# The row is rendered for its owner or an admin; only the owner can accept.
                        The amount travels with the click (see MsoTrueup#toggle_acceptance!). %>
                    <% if !li.locked? && current_admin_user == li.contributor.forecast_person&.admin_user %>
                      <span class="split">
                        <%= link_to li.accepted? ? "Unaccept ↗" : "Accept ↗", toggle_acceptance_admin_ledger_mso_trueup_path(li.ledger, li, amount: li.amount.to_s("F")), method: :post, style: "font-size: unset;" %>
                      </span>
                    <% end %>
                  </span>
                <% end %>
```

Directly above line 336 (the details cell's `<% elsif li.is_a?(Trueup) %>`), add:

```erb
                <% elsif li.is_a?(MsoTrueup) %>
                  <%= link_to "Info ↗", admin_ledger_mso_trueup_path(li.ledger, li) %>
```

Apply the four edits from the bottom of the file upward (336, 290, 198, 142) so the line numbers above stay right.

In `app/views/admin/contributors/_ledger_tabs.html.erb`, replace lines 26-27 with:

```erb
    <% balance_owed = ledger.balance(include_mso_trueups: include_mso_trueups).to_f %>
    <% unsettled = ledger.unsettled(include_mso_trueups: include_mso_trueups).to_f %>
```

In `app/views/admin/admin_users/_show.html.erb`, replace line 35 with:

```erb
        <% ledger_contributor = resource.forecast_person.contributor %>
        <% new_deal_balance = ledger_contributor.new_deal_balance(nil, include_mso_trueups: ledger_contributor.mso_trueups_visible_to?(current_admin_user)) %>
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/integration/admin_contributor_mso_trueup_test.rb
```

Expected: PASS, 4 runs, 0 failures.

- [ ] **Step 6: Check nothing else renders these partials**

```bash
grep -rn "ledger_tabs\|new_deal_balance\|all_items_grouped_by_month\|items_grouped_by_month" app lib --include="*.rb" --include="*.erb" --include="*.arb"
```

Expected callers, each accounted for: `app/admin/contributors.rb` and the two partials (this task); `app/views/admin/admin_users/_show.html.erb` (this task); `app/admin/dashboard.rb` and `app/services/mcp/get_executive_dashboard_tool.rb` (`aggregated_new_deal_balance`, which leaves MSO true-ups out entirely, Task 3 and Decisions 29); `app/models/periodic_report.rb:227` and `app/models/associates_award_agreement.rb:41` (elevated service, which is meant to count MSO true-ups); `app/services/contributors/submit_deel_invoice_adjustment.rb:86-87` (the contributor's own Deel withdrawal limit). If the grep shows a caller not on this list that renders amounts to someone other than the contributor, stop and report it.

- [ ] **Step 7: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 4 more runs than after Task 10 (baseline + 142), 0 failures, 0 errors.

- [ ] **Step 8: Commit**

```bash
git add app/models/contributor.rb app/admin/contributors.rb app/views/admin/contributors/_show.html.erb \
  app/views/admin/contributors/_ledger_tabs.html.erb app/views/admin/admin_users/_show.html.erb \
  test/integration/admin_contributor_mso_trueup_test.rb
git commit -m "feat(mso): a ledger page shows MSO true-ups only to their owner and to admins

Every lead can open every contributor's ledger. For anyone but an admin or
the contributor themself, the rows, the balance, the unsettled total, the
ledger tab pills and the month's income are all computed without MSO
true-ups."
```

---

### Task 12: A task for an unaccepted true-up, and for a missing vendor

Nobody is paid until every executive accepts their own true-up, and nobody can accept for them (Tasks 1 and 6), so something has to ask them. And a true-up cannot become a QuickBooks bill until its executive has a vendor in garden3d's QuickBooks; the sync refuses and says so (Task 8), and this raises a task for it ahead of time.

**Files:**
- Create: `lib/stacks/task_builder/discoveries/unaccepted_mso_trueups.rb`
- Modify: `lib/stacks/task_builder.rb`
- Modify: `app/models/stacks_task.rb`
- Modify: `lib/stacks/task_builder/discoveries/missing_qbo_vendors.rb`, `lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration.rb`
- Create: `test/lib/stacks/task_builder/discoveries/unaccepted_mso_trueups_test.rb`

**Interfaces:**
- Consumes: `MsoTrueup`
- Produces: a `:unaccepted_mso_trueup` task per executive with one or more unaccepted true-ups, owned by that executive, linking to their garden3d ledger; `:missing_qbo_vendor_for_contributor` now also fires for a ledger whose only item is an MSO true-up

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/task_builder/discoveries/unaccepted_mso_trueups_test.rb`:

```ruby
require "test_helper"

class Stacks::TaskBuilder::Discoveries::UnacceptedMsoTrueupsTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 10, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("nag-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(@role, @ledger, trueup: "1000.0")])
    @trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1000")
  end

  def teardown
    clear_enterprise_memos
  end

  def tasks
    Stacks::TaskBuilder::Discoveries::UnacceptedMsoTrueups.new(admin_fallback: [mso_admin]).tasks
  end

  test "an unaccepted true-up is one task for its executive, linking to their garden3d ledger" do
    mine = tasks.select { |task| task.subject == @exec }

    assert_equal 1, mine.size
    assert_equal :unaccepted_mso_trueup, mine.first.type
    assert_equal [login_for(@exec)], mine.first.owners
    assert_equal Rails.application.routes.url_helpers.admin_contributor_path(@exec, ledger: @ledger.id),
      mine.first.subject_url
    assert_equal "Contributor has an MSO true-up to accept", mine.first.humanized_type
    assert_no_match(/1000|1,000/, mine.first.subject_display_name(redact_amounts: true))
  end

  test "an accepted true-up needs no task" do
    @trueup.toggle_acceptance!

    assert_empty tasks.select { |task| task.subject == @exec }
  end

  test "a removed true-up needs no task" do
    @trueup.destroy

    assert_empty tasks.select { |task| task.subject == @exec }
  end

  test "an executive with a true-up and no garden3d QuickBooks vendor is flagged for a vendor mapping" do
    vendor_tasks = lambda do
      Stacks::TaskBuilder::Discoveries::MissingQboVendors.new(admin_fallback: [mso_admin]).tasks
        .select { |task| task.subject == @ledger }
    end

    assert_equal [:missing_qbo_vendor_for_contributor], vendor_tasks.call.map(&:type)

    vendor = QboVendor.create!(qbo_account: garden3d_qbo_account, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    ContributorQboVendor.create!(contributor: @exec, qbo_account: garden3d_qbo_account, qbo_vendor: vendor)

    assert_empty vendor_tasks.call
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/lib/stacks/task_builder/discoveries/unaccepted_mso_trueups_test.rb
```

Expected: 4 runs, 4 failures or errors. Three error with `NameError: uninitialized constant … UnacceptedMsoTrueups`; the vendor test fails because the ledger has no row in any table that discovery looks at.

- [ ] **Step 3: Write the discovery**

Create `lib/stacks/task_builder/discoveries/unaccepted_mso_trueups.rb`:

```ruby
module Stacks
  class TaskBuilder
    module Discoveries
      # An MSO true-up is payable only once EVERY executive has accepted
      # theirs for the month, so one person not clicking Accept holds up
      # everyone. One task per executive, owned by them, linking to their
      # garden3d ledger. The task carries no amount.
      class UnacceptedMsoTrueups < Base
        def tasks
          # Migrations are run by hand after the deploy.
          return [] unless MsoTrueup.schema_ready?

          MsoTrueup.where(accepted_at: nil)
            .includes(ledger: { contributor: :forecast_person })
            .group_by { |trueup| trueup.ledger.contributor }
            .map do |contributor, trueups|
              task(
                subject: contributor,
                type: :unaccepted_mso_trueup,
                owners: [contributor.forecast_person&.admin_user],
                ledger: trueups.first.ledger,
              )
            end
        end
      end
    end
  end
end
```

It follows `UnacceptedPayouts` (`lib/stacks/task_builder/discoveries/unaccepted_payouts.rb:5-17`). `Base#task` falls back to the admin team when the executive has no login (`base.rb:17-21`), and `StacksTask#subject_url` already links a `Contributor` subject to the task's ledger (`app/models/stacks_task.rb:184`).

In `lib/stacks/task_builder.rb`, add below line 16:

```ruby
require_relative "task_builder/discoveries/unaccepted_mso_trueups"
```

and add to `DISCOVERY_CLASSES`, below `Discoveries::UnacceptedPayouts,` (line 61):

```ruby
      Discoveries::UnacceptedMsoTrueups,
```

In `app/models/stacks_task.rb`, below `unaccepted_payouts: "Contributor has unaccepted payout(s)",` (line 60), add:

```ruby
    unaccepted_mso_trueup: "Contributor has an MSO true-up to accept",
```

- [ ] **Step 4: The two discoveries that enumerate ledger-item tables**

In `lib/stacks/task_builder/discoveries/missing_qbo_vendors.rb`, replace `any_payable_subquery` (lines 45-49) with:

```ruby
        def any_payable_subquery
          payable_tables.map do |t|
            "SELECT 1 FROM #{t} WHERE #{t}.ledger_id = ledgers.id"
          end.join(" UNION ALL ")
        end

        # An MSO true-up needs a vendor in garden3d's QuickBooks before it can
        # become a bill. Guarded: the table arrives by hand after the deploy.
        def payable_tables
          MsoTrueup.schema_ready? ? PAYABLE_TABLES + ["mso_trueups"] : PAYABLE_TABLES
        end
```

In `lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration.rb`, replace `any_payable_subquery` (lines 37-46; keep its comment) with:

```ruby
        def any_payable_subquery
          # Every PAYABLE_TABLES model is acts_as_paranoid, so the raw SQL has
          # to filter deleted_at IS NULL — otherwise a ledger whose only payable
          # rows are soft-deleted still surfaces a migration task that the
          # readiness check then declares trivial (visible_items is empty),
          # spamming the Tasks dashboard.
          payable_tables.map do |t|
            "SELECT 1 FROM #{t} WHERE #{t}.ledger_id = ledgers.id AND #{t}.deleted_at IS NULL"
          end.join(" UNION ALL ")
        end

        def payable_tables
          MsoTrueup.schema_ready? ? PAYABLE_TABLES + ["mso_trueups"] : PAYABLE_TABLES
        end
```

`Mso::MonthlyRun` refuses to put a true-up on a legacy ledger, so the second one is for consistency: a ledger flipped to legacy by hand afterwards would still be surfaced.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bin/rails test test/lib/stacks/task_builder
```

Expected: PASS. 4 new runs.

- [ ] **Step 6: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: 4 more runs than after Task 11 (**baseline + 146**), 0 failures, 0 errors, 2 skips.

- [ ] **Step 7: Commit**

```bash
git add lib/stacks/task_builder/discoveries/unaccepted_mso_trueups.rb lib/stacks/task_builder.rb \
  app/models/stacks_task.rb lib/stacks/task_builder/discoveries/missing_qbo_vendors.rb \
  lib/stacks/task_builder/discoveries/legacy_ledgers_pending_qbo_migration.rb \
  test/lib/stacks/task_builder/discoveries/unaccepted_mso_trueups_test.rb
git commit -m "feat(mso): a task for an unaccepted MSO true-up, and for an executive with no vendor

Nobody is paid until every executive accepts, so each one with an
unaccepted true-up gets a task linking to their ledger. An executive with a
true-up and no vendor in garden3d's QuickBooks is flagged the way any other
unmapped contributor is."
```

---

### Task 13: Verification against the dev database

Read-only checks against real data. The dev database is a copy of production with live credentials, so every script below first makes a QuickBooks call impossible, prints ids, counts and amounts only (never a person's or company's name or email), and leaves nothing behind: anything that writes is inside a transaction that is rolled back.

No commit in this task. Delete each script after running it. `tmp/` is git-ignored.

Steps 1, 3 and 4 need the migration to have run on the dev database. **Do not run it from this worktree** (`bin/rails db:migrate` re-dumps `db/schema.rb`). If the dev database has not been migrated, run Steps 2 and 5 only and say so.

- [ ] **Step 1: What the first two MSO months would pay, with hypothetical executives**

The roster is empty in the dev copy. This computes August and September 2026 for two hypothetical lines, contributor 3 at Principal and contributor 120 at Chief, both starting 2026-08-01. It saves the two role periods **inside a transaction that is rolled back**, so the benchmark pool excludes them exactly as a real run would.

Save as `tmp/verify_mso_hypothetical.rb`:

```ruby
ActiveRecord::Base.logger = nil
# Any QuickBooks call needs a token. Make getting one impossible.
QboAccount.class_eval do
  def make_and_refresh_qbo_access_token(*)
    raise "verification must not call QuickBooks"
  end
end

HYPOTHETICAL = { 3 => :principal, 120 => :chief }.freeze
ZERO = BigDecimal("0")

[Date.new(2026, 8, 1), Date.new(2026, 9, 1)].each do |month|
  ActiveRecord::Base.transaction do
    roster = HYPOTHETICAL.map do |contributor_id, tier|
      MsoRolePeriod.create!(contributor_id: contributor_id, tier: tier, title: "hypothetical",
                            started_at: Date.new(2026, 8, 1))
    end
    Mso::MonthlyRun.assert_one_period_per_person!(roster)

    fee = Mso::ManagementFeeIncome.for_month(month)
    benchmark = Mso::Benchmark.for_month(month)
    puts "=== #{month.strftime('%Y-%m')}: fee #{fee.to_s('F')} benchmark #{benchmark.average.round(2).to_s('F')} " \
         "members #{benchmark.members.map { |m| [m[:contributor_id], m[:amount].to_s('F')] }.inspect}"

    # What the run would refuse on: founder true-ups for roster members in the month.
    blocking = Trueup.joins(:ledger, :invoice_pass)
      .where(ledgers: { contributor_id: HYPOTHETICAL.keys }, invoice_passes: { start_of_month: month }).to_a
    puts "founder true-ups that would make the run refuse: #{blocking.map { |t| [t.id, t.amount.to_s('F')] }.inspect}"

    { "with the founder true-up left in (the run refuses this)" => [],
      "with the founder true-up removed" => blocking }.each do |label, excluding|
      earned = roster.to_h do |period|
        [period.contributor_id,
         Mso::MonthlyRun.already_earned(contributor_id: period.contributor_id, month: month, excluding: excluding)]
      end
      result = Mso::Compensation.call(
        benchmark_average: benchmark.average,
        lines: roster.map do |period|
          Mso::Compensation::Line.new(key: period.contributor_id, multiplier: period.tier_multiplier,
                                      already_earned: earned.fetch(period.contributor_id).values.sum(ZERO))
        end,
        fee_income: fee,
      )
      puts "--- #{label}: cap #{result.cap.to_s('F')} total calculated #{result.total_calculated.round(2).to_s('F')}"
      result.outputs.each do |output|
        already = earned.fetch(output.key).values.sum(ZERO)
        trueup = output.trueup.floor(2)
        puts "contributor #{output.key}: earned #{already.to_s('F')} final #{output.final.to_s('F')} " \
             "true-up #{trueup.to_s('F')} month total #{(already + trueup).to_s('F')}"
      end
    end

    raise ActiveRecord::Rollback
  end
end

# A month before the start is refused before anything is read. The pass is
# made only to hand to the run, and is rolled back.
ActiveRecord::Base.transaction do
  early = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START - 1.month
  pass = InvoicePass.find_or_create_by!(enterprise: Enterprise.garden3d, start_of_month: early) { |p| p.data = {} }
  begin
    Mso::MonthlyRun.call(invoice_pass: pass)
    puts "UNEXPECTED: the run was not refused"
  rescue Mso::MonthlyRun::Refused => e
    puts "run refused: #{e.message}"
  end
  puts "snapshots written: #{MsoSnapshot.where(invoice_pass_id: pass.id).count} " \
       "true-ups written: #{MsoTrueup.with_deleted.where(invoice_pass_id: pass.id).count}"
  raise ActiveRecord::Rollback
end
puts "after rollback: roster rows #{MsoRolePeriod.count}"
```

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
bin/rails runner tmp/verify_mso_hypothetical.rb
rm tmp/verify_mso_hypothetical.rb
```

Expected. The figures are what the same computation printed against the dev copy on 2026-10-12, using the existing services directly:

```
=== 2026-08: fee 140000.0 benchmark 26082.02 members [[112, "28692.42"], [202, "27055.16"], [36, "22498.47"]]
founder true-ups that would make the run refuse: [[203, "26383.92"]]
--- with the founder true-up left in (the run refuses this): cap 77000.0 total calculated 56076.34
contributor 3: earned 28692.42 final 29994.32 true-up 1301.9 month total 29994.32
contributor 120: earned 0.0 final 26082.02 true-up 26082.02 month total 26082.02
--- with the founder true-up removed: cap 77000.0 total calculated 56076.34
contributor 3: earned 2308.5 final 29994.32 true-up 27685.82 month total 29994.32
contributor 120: earned 0.0 final 26082.02 true-up 26082.02 month total 26082.02
=== 2026-09: fee 135000.0 benchmark 27882.26 members [[111, "29546.1"], [112, "28164.79"], [34, "25935.9"]]
founder true-ups that would make the run refuse: [[204, "29289.6"]]
--- with the founder true-up left in (the run refuses this): cap 74250.0 total calculated 59946.87
contributor 3: earned 29546.1 final 32064.6 true-up 2518.5 month total 32064.6
contributor 120: earned 0.0 final 27882.26 true-up 27882.26 month total 27882.26
--- with the founder true-up removed: cap 74250.0 total calculated 59946.87
contributor 3: earned 256.5 final 32064.6 true-up 31808.1 month total 32064.6
contributor 120: earned 0.0 final 27882.26 true-up 27882.26 month total 27882.26
run refused: MSO compensation is run from August 2026 onward; July 2026 is before that.
snapshots written: 0 true-ups written: 0
after rollback: roster rows 0
```

What this shows:
- Neither month's cap binds (77,000 against 56,076.34; 74,250 against 59,946.87).
- The founder's month total is the same with the founder true-up left in or removed **only because the cap does not bind**. The run refuses the first case regardless (Decisions 4).
- The refusal line names whatever `MANAGEMENT_FEE_START` is when this is run (2026-08-01 since `8e0664e2`).
- September still has unaccepted Sanctuary payouts (9 of 54 on 2026-10-12), so its figures can still move. A different figure is not a failure; a different *relationship* (true-up ≠ final − earned, floored at zero and to the cent) is.

If any line raises `verification must not call QuickBooks`, something tried to reach QuickBooks: stop and report where.

- [ ] **Step 2: Nothing scheduled can write an MSO bill or run the month**

Needs no migration.

```bash
grep -c "MsoTrueup\|mso_trueup\|MonthlyRun" lib/tasks/stacks.rake
```

Expected: `0`.

```bash
grep -rn "MonthlyRun.call\|\.sync_qbo_bill!" app lib --include="*.rb" --include="*.rake" | grep -i "mso\|MonthlyRun"
```

Expected: `Mso::MonthlyRun.call` only in `app/admin/invoice_passes.rb` (the admin action); `sync_qbo_bill!` under an MSO name only as the override's definition in `app/models/mso_trueup.rb`.

```bash
grep -n "daily_tasks" -A14 app/models/enterprise.rb
```

Expected: for garden3d, `ensure_previous_month!`, `invalidate_snapshots_whose_fee_moved!` and `refresh_bill_mirrors!`, and nothing else. None of the three can create or change a QuickBooks bill; the last makes reads.

```bash
grep -n "sync_qbo_bills!" -A14 app/models/contributor.rb
```

Expected: `Contributor#sync_qbo_bills!` still lists payouts, adjustments, profit shares and reimbursements only.

Save as `tmp/verify_mso_schedule.rb`:

```ruby
ActiveRecord::Base.logger = nil
recent = SystemTask.where("created_at > ?", 10.days.ago).group(:name).count
%w[stacks:sync_contributor_qbo_bills stacks:sync_founder_trueups stacks:daily_enterprise_tasks stacks:daily_tasks].each do |name|
  puts "#{name}: #{recent[name].to_i} runs in the last 10 days"
end
puts "garden3d GL for MSO compensation: #{Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:garden3d][:mso_compensation].inspect}"
puts "fallbackable: #{Qbo::BillRouter::FALLBACKABLE_CONCEPTS.inspect}"
puts "bills already carrying the MT code: #{QboBill.where("data->>'doc_number' ~ ?", '^Stacks_[0-9]+_MT$').count}"
```

```bash
bin/rails runner tmp/verify_mso_schedule.rb
rm tmp/verify_mso_schedule.rb
```

Expected: the two sync tasks and the two daily tasks each show about one run a day (7 or 8 in ten days on the dev copy), which is why Decisions 4, 5 and 9 matter; `"____"`; `[:subcontractor, :bonuses, :commission]`; `0`.

- [ ] **Step 3: The registration points, on real data**

Save as `tmp/verify_mso_registration.rb`:

```ruby
ActiveRecord::Base.logger = nil
QboAccount.class_eval do
  def make_and_refresh_qbo_access_token(*)
    raise "verification must not call QuickBooks"
  end
end

puts "schema ready: #{MsoTrueup.schema_ready?}"
puts "rows: snapshots #{MsoSnapshot.count}, true-ups #{MsoTrueup.with_deleted.count}"
puts "qualifying income: #{Ledger::QualifyingIncome::KLASSES.map(&:name).inspect}"
puts "benchmark income: #{Mso::Benchmark::KLASSES.map(&:name).inspect}"
puts "money page hosts: #{Money::PayableQboBills.host_klasses.map(&:name).inspect}"
puts "discoveries include the nag: #{Stacks::TaskBuilder::DISCOVERY_CLASSES.include?(Stacks::TaskBuilder::Discoveries::UnacceptedMsoTrueups)}"

# With no true-ups in the database, nothing that existed before may change.
garden3d = QboAccount.where(enterprise_id: Enterprise.garden3d.id).order(:id).first
summary = Money::QboBillSummary.call(qbo_account: garden3d)
puts "garden3d Money page: #{summary.payable_rows.size} payable, #{summary.unsettled_count} unsettled, " \
     "#{summary.payable_rows.count { |row| row.host.is_a?(MsoTrueup) }} of them MSO"
[404, 458].each do |ledger_id|
  ledger = Ledger.find(ledger_id)
  puts "ledger #{ledger_id}: mode #{ledger.mode} balance #{ledger.balance.to_f} unsettled #{ledger.unsettled.to_f} " \
       "(without MSO: #{ledger.balance(include_mso_trueups: false).to_f} / #{ledger.unsettled(include_mso_trueups: false).to_f})"
end
puts "nightly fee check invalidated: #{Mso::MonthlyRun.invalidate_snapshots_whose_fee_moved!.inspect}"
puts "nightly bill refresh failures: #{MsoTrueup.refresh_bill_mirrors!.inspect}"
```

```bash
bin/rails runner tmp/verify_mso_registration.rb
rm tmp/verify_mso_registration.rb
```

Expected: `schema ready: true`; zero rows of both; qualifying income lists six classes ending in `MsoTrueup`; benchmark income lists four with neither `Trueup` nor `MsoTrueup`; the Money page hosts end in `MsoTrueup`; `true`; `0 of them MSO`; ledgers 404 and 458 are `qbo_bound` and each prints the same pair of figures with and without MSO; both nightly calls return `[]` (there is nothing to check or refresh, so neither reaches QuickBooks).

- [ ] **Step 4: The founder true-ups that stand in the way of the first MSO months**

Save as `tmp/verify_mso_founder.rb`:

```ruby
ActiveRecord::Base.logger = nil
QboAccount.class_eval do
  def make_and_refresh_qbo_access_token(*)
    raise "verification must not call QuickBooks"
  end
end

start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START
founder = Stacks::System.founder_contributor
sanctuary_account_ids = QboAccount.where(enterprise_id: Enterprise.sanctuary.id).pluck(:id)
puts "founder contributor #{founder&.id}; first MSO month #{start}"

rows = Trueup.joins(:ledger, :invoice_pass).where(ledgers: { contributor_id: founder.id })
  .order("invoice_passes.start_of_month")
  .pluck("trueups.id", "invoice_passes.start_of_month", "trueups.amount", "trueups.qbo_bill_id", "trueups.ledger_id")
puts "founder true-ups: #{rows.size}, with a bill #{rows.count { |row| row[3].present? }}"

puts "from the first MSO month onward (each must be deleted before its month can be run):"
rows.select { |_, month, _, _, _| month >= start }.each do |id, month, amount, bill_id, ledger_id|
  bill = bill_id && QboBill.find_by(qbo_account_id: sanctuary_account_ids, qbo_id: bill_id)
  state = bill ? "bill total #{bill.total_amount} balance #{bill.remaining_balance} has payments #{bill.has_payments?}" : "no bill"
  puts "  Trueup #{id} #{month.strftime('%Y-%m')} amount #{amount.to_s('F')} ledger #{ledger_id}: #{state}"
end
puts "months the nightly sync now skips: #{Stacks::System.founder_trueup_months.count { |m| Stacks::System.founder_paid_by_mso?(founder, m) }}"

garden3d = Enterprise.garden3d
garden3d_account = QboAccount.where(enterprise_id: garden3d.id).order(:id).first
people = (MsoRolePeriod.distinct.pluck(:contributor_id) + [3, 120]).uniq.sort
people.each do |contributor_id|
  contributor = Contributor.find(contributor_id)
  ledger = Ledger.find_by(enterprise_id: garden3d.id, contributor_id: contributor_id)
  puts "contributor #{contributor_id}: role periods #{MsoRolePeriod.where(contributor_id: contributor_id).count}, " \
       "garden3d ledger #{ledger&.id} (#{ledger&.mode}), garden3d QuickBooks vendor mapped " \
       "#{contributor.qbo_vendor_for(garden3d_account).present?}, has a login #{contributor.forecast_person&.admin_user.present?}"
end
```

```bash
bin/rails runner tmp/verify_mso_founder.rb
rm tmp/verify_mso_founder.rb
```

Expected on the dev copy of 2026-10-12, with `MANAGEMENT_FEE_START` at 2026-08-01: founder contributor `3`; 16 founder true-ups, all 16 with a bill; two from the first MSO month onward:

```
  Trueup 203 2026-08 amount 26383.92 ledger 2: bill total 26383.92 balance 26383.92 has payments false
  Trueup 204 2026-09 amount 29289.6 ledger 2: bill total 29289.6 balance 29289.6 has payments false
```

There is **no October 2026 founder true-up yet**: the nightly task writes a month only once it has ended (`lib/stacks/system.rb:65-75`), so October's would first appear on 1 November. 0 months skipped (the roster is empty). Contributors 3 and 120 each have 0 role periods, a `qbo_bound` garden3d ledger (404 and 458), **no garden3d vendor mapped**, and a login. "Has payments" is read from Stacks' stored copy of each bill, which the nightly bill sync refreshes; the delete itself re-reads QuickBooks.

- [ ] **Step 5: The new people-cost patterns hide nothing that is shown today**

Needs no migration. Save as `tmp/verify_mso_patterns.rb`:

```ruby
ActiveRecord::Base.logger = nil
NEW = [/compensation/i, /\bmso\b/i, /executive/i].freeze
# Account labels are generic words; anything else is masked, in case a label carries a name.
GENERIC = /\A(compensation|mso|executive|executives|officer|officers|total|expense|expenses|and|of|the|cost|costs|insurance|deferred|stock|accrued|other|fees?|services?|management|program|education|training|coaching|search|recruit\w*|development|leadership|team|\d+|&|-|\[[^\]]*\])\z/i
hits = Hash.new(0)
QboProfitAndLossReport.find_each do |report|
  stack = []
  Array(report.data&.dig("accrual", "rows")).each do |label, value|
    label = label.to_s
    if value.nil?
      stack.push(label)
    elsif label.start_with?("Total ")
      i = stack.rindex(label.delete_prefix("Total "))
      stack.slice!(i..) if i
    elsif Stacks::FinancialOutlook::SPEND_SECTIONS.include?(stack.first)
      labels = [label, *stack.drop(1)]
      next unless labels.any? { |l| NEW.any? { |pattern| pattern.match?(l) } }
      # Before Task 5 this asks "is it shown today?"; after it, "was it only hidden by the new patterns?"
      old_patterns = Stacks::PeopleCostAccounts::PATTERNS - NEW
      next if labels.any? { |l| old_patterns.any? { |pattern| pattern.match?(l) } }
      masked = labels.map { |l| l.split(/\s+/).map { |word| word.match?(GENERIC) ? word : "…" }.join(" ") }.join(" < ")
      hits[[report.qbo_account_id, masked]] += 1
    end
  end
end
puts "accounts hidden only by the three new patterns: #{hits.size}"
hits.sort.each { |(account_id, masked), count| puts "qbo_account #{account_id}: #{masked} (#{count} report rows)" }
```

```bash
bin/rails runner tmp/verify_mso_patterns.rb
rm tmp/verify_mso_patterns.rb
```

Expected: `accounts hidden only by the three new patterns: 0`, as on 2026-10-12. If it lists anything, read the masked label and decide whether that account should be hidden before merging; the patterns are in `lib/stacks/people_cost_accounts.rb`.

---

## Deploy

Merging to `main` deploys once `main`'s own CI is green. **Migrations are run by hand afterwards; there is no release phase.** So the new code runs for a while against a database without the two new tables.

**What breaks between merge and migrate: nothing that works today.**

| Code path | Before the migration | Why it is safe |
| --- | --- | --- |
| Every `Ledger#balance` / `#unsettled`, every ledger page | unchanged | each asks `MsoTrueup.schema_ready?` first (Tasks 2, 3); the answer "no" is re-checked at most once a minute |
| `Ledger::QualifyingIncome`, `Mso::Benchmark` | unchanged | a class whose table is missing contributes zero (Task 2) |
| The Money page and its sync buttons | unchanged, except "Sync all" now shows each failure's message | they iterate `Money::PayableQboBills.host_klasses` (Task 4) |
| Nightly `stacks:sync_founder_trueups` | unchanged | `founder_paid_by_mso?` returns false while the tables are missing (Task 9) |
| Nightly `stacks:sync_contributor_qbo_bills` | unchanged | not modified; never touches an `MsoTrueup` |
| Nightly garden3d step | unchanged | the fee check, the drift check and the bill refresh return `[]` while the tables are missing (Tasks 7, 8; item 43); each step is isolated and a failure is reported, not raised |
| Saving an `InvoiceTracker`, editing or deleting a role period | unchanged | the new callback and validations ask `schema_ready?` (Tasks 8, 9) |
| Task discoveries, `list_payable_bills`, the financial outlook | unchanged; the outlook additionally hides any account named for compensation, the MSO or executives (none exists today) | guarded (Tasks 5, 12) |
| **Run MSO compensation** | the button is not shown; a posted run is refused with "run the pending migrations" | `Mso::MonthlyRun.runnable?` and the run itself ask `schema_ready?` (item 45) |
| The MSO Compensation menu, a true-up page | an error page | new features; nothing scheduled reaches them |

These behaviours change at deploy whether or not the migrations have run:

- **Deleting a founder true-up now deletes its QuickBooks bill** (and is refused if the bill has a payment, judged on the bill as QuickBooks has it at that moment). Before, the bill was left behind.
- **Only an admin can delete a founder true-up** (item 42). A lead no longer sees the Delete control and a DELETE by URL is refused.
- **`get_enterprise_health` with `raw_rows: true` no longer lists people-cost accounts** (payroll, benefits, contractors, payouts, intercompany) for any company (item 44).
- An MSO role period can no longer be given a start date before August 2026. One already on file is unaffected and can still be ended.
- An `MsoTrueup` can no longer be routed to `:subcontractor`. None exists.

There are **two** migrations, `20261014000001` (the tables) and `20261014000002` (the snapshot's `run_warnings` and `income_drift`). Run them together and no dyno restart is needed. If the first was ever run on its own, restart the dynos after the second: a process that has already loaded `mso_snapshots` does not see new columns, and until it does a run records no warnings and the nightly drift check does nothing (both are guarded; nothing fails).

### The first three MSO months: August, September and October 2026

The owner has decided the first MSO month is **August 2026** and that the role periods start **2026-08-01**. August and September are already closed months with founder true-ups written and billed the old way, so they need a one-time, ordered procedure. The state on the dev copy of 2026-10-12:

| Month | Founder true-up today (Sanctuary) | Its QuickBooks bill | Sanctuary pass |
| --- | --- | --- | --- |
| June 2026 | Trueup 201, 22,718.09 | unpaid | — pre-MSO, **stays as it is** |
| July 2026 | Trueup 202, 25,552.41 | unpaid | — pre-MSO, **stays as it is** |
| August 2026 | Trueup 203, 26,383.92 | unpaid (balance 26,383.92) | 836, complete, 69 payouts, all accepted |
| September 2026 | Trueup 204, 29,289.60 | unpaid (balance 29,289.60) | 837, complete, 54 payouts, 9 unaccepted |
| October 2026 | none yet (would be written on 1 November) | — | not yet created |

What each person is paid for the month, before and after, with contributor 3 at Principal and contributor 120 at Chief (hypothetical tiers; Verification Step 1):

| Month | Person | Today | After | Change |
| --- | --- | --- | --- | --- |
| August | contributor 3 | 2,308.50 payouts + 26,383.92 founder true-up = **28,692.42**, all from Sanctuary | 2,308.50 payouts (Sanctuary) + 27,685.82 MSO true-up (garden3d) = **29,994.32** | +1,301.90 |
| August | contributor 120 | 0.00 | 26,082.02 MSO true-up (garden3d) | +26,082.02 |
| September | contributor 3 | 256.50 payouts + 29,289.60 founder true-up = **29,546.10**, all from Sanctuary | 256.50 payouts (Sanctuary) + 31,808.10 MSO true-up (garden3d) = **32,064.60** | +2,518.50 |
| September | contributor 120 | 0.00 | 27,882.26 MSO true-up (garden3d) | +27,882.26 |

Neither month's cap binds (August: cap 77,000 against 56,076.34 calculated; September: 74,250 against 59,946.87). Sanctuary's payables fall by 55,673.52 (the two founder true-ups); garden3d's rise by 53,767.84 for August and 59,690.36 for September. September's figures can still move while nine payouts are unaccepted.

**Steps, in order:**

1. Merge. Wait for the deploy. Run the migrations on production by hand: `rails db:migrate` (any earlier migration not yet run goes first).
2. Run Task 13 Steps 2–5 against production. Step 4 lists the founder true-ups in the way and whether Stacks believes each bill has a payment.
3. **Enter the role periods** on Money → MSO Roles, each starting **2026-08-01**. Do this before 1 November 2026: from that night the founder sync would otherwise write October's founder true-up.
   - From the next nightly run, the founder sync **skips August onward**. It does not remove what it already wrote: Trueups 203 and 204 are still there, and the nightly bill sync keeps their bills in step with them.
   - June and July (Trueups 201, 202) are before the role period: they keep being recomputed and billed exactly as today.
4. **Delete the August and September founder true-ups** (Trueup 203 and 204), each from its own page, **as an admin** (item 42): open contributor 3's Sanctuary ledger, open the true-up, Delete. This now also deletes its bill in Sanctuary's QuickBooks, after re-reading the bill.
   - **If the bill has any payment, the delete is refused** and nothing changes: the message names the bill. Then there are two ways forward, and it is Finance's call which: (a) void that payment in Sanctuary's QuickBooks and delete again; or (b) leave that month paid the old way, and move the role periods' start to the first month whose founder true-up can be removed (possible while no MSO month has been run). Do not try to do both: the run refuses while the founder true-up exists.
   - Do not delete a founder true-up until its month is ready to run. Between the delete and the MSO true-up's bill, that month's top-up exists nowhere.
   - Nothing recreates it: the role period is active for the month, and once the month has been run the snapshot keeps it skipped even if the roster is later edited.
5. **Give August and September their fee invoices** (S1's Deploy section): garden3d's passes for the months are created by the nightly catch-up (or `ensure_month!`); fill garden3d's invoice mirror; attach each paying company's hand-made invoice to its tracker. The collection gate now also needs every current payer to have a tracker on the pass, each attached invoice to be dated within the month, and no unattached invoice to a payer dated in the month.
6. **Run August, then September**: on garden3d's pass, **Run MSO compensation**. A run of a month can be made at any time after the month has ended; nothing assumes it is last month. If it is refused the message says why and what to do; nothing is written by a refused run.
7. Each executive opens their ledger and **accepts** their own true-up (a task asks them to). Nobody else can accept for them.
8. When the fee invoices are paid: **Check collection** on the snapshot.
9. **Before garden3d's books for the month are hard-closed**, an admin syncs each true-up from the Money page. The bill is dated the **last day of the fee month** (08/31 for August), with the same due date, as the finance lead asked. This needs, first: Finance's MSO compensation account, with its number in `app/services/qbo/bill_router.rb`; and a garden3d vendor mapped for each executive. If the books are already closed for that date QuickBooks rejects the bill; Stacks reports that as "garden3d's books are closed for 08/31" and writes nothing, and Finance must reopen the period (or move the closing date) before syncing again. **So the order is: sync the bills, then hard-close.**
10. **October** follows the ordinary monthly routine below, provided step 3 was done before 1 November. If it was not, October has a founder true-up too and joins step 4.

### Every month after that

After the month has ended and Sanctuary's invoices and payouts for it exist: check the pass's invoices are attached; **Run MSO compensation**; executives accept; if payouts change, run again (accepted true-ups whose amount did not change stay accepted); when the fee is paid, **Check collection**; then sync each true-up from the Money page **before the month is hard-closed**. At that last click Stacks re-checks collection with QuickBooks and recomputes the month; if a figure has moved it refuses and asks for the month to be run again.

Two things to look at on the snapshot page in between (item 43). **Not finished when this month was run** lists what the run did not wait for. **FIGURES HAVE MOVED SINCE THIS RUN** is the nightly check: a true-up without a bill has had its run marked invalid, so run the month again; a true-up that already has a bill is left alone, and a person decides whether to remove the bill and run again. If a bill is deleted in QuickBooks itself, syncing that true-up is refused (item 41) and the month has to be run again.

### Rollback

Reverting this branch brings back the unguarded nightly founder sync, which would **recreate and bill founder true-ups for every MSO month that night**, on top of MSO true-ups already paid. So, in this order:

1. **First, stop the scheduler job `stacks:sync_founder_trueups`** (and leave it stopped until the roster question is settled), or keep Task 9's commit when reverting.
2. If any true-up has a QuickBooks bill, decide with Finance whether it stands. A bill that stands needs nothing; one that should not is removed from the true-up's page **before** the revert, while the code that knows the `MT` doc code is still deployed.
3. Revert the merge and deploy. The two tables can stay; nothing else reads them.
4. Only then, if the founder is to go back to the old arrangement, re-enable the job. It will write founder true-ups for every month since June 2025 that lacks one, including the MSO months.

---

## Self-Review

**Spec coverage.** §9.1 schema, the partial unique index, restore-not-insert → Tasks 1 and 7. §9.2 required methods and "do not copy `Trueup#payable?`" → Task 1. §9.3 amount, netting across all ledgers, `excluding:` → Task 7. §9.4 payability and the every-expected-true-up gate → Task 1, with the collection half changed (Decisions 21). §9.5 orchestration, the Sanctuary-pass prerequisites, idempotency by recomputation, QuickBooks work outside the transaction → Task 7. §9.6 a dedicated admin-only table and the supersede chain → Tasks 1, 6, 7. §9.7: #1, #2, #3, #4, #5, #11 → Task 4; #6 → Task 10; #7 → Task 2; #8 → Task 3 (less the company-wide aggregate, Decisions 29); #9 → Task 3; #10 → Task 12; the four view branches → Task 11. §10 → Tasks 5, 6, 10, 11. §11's S4 rows each have a test. §12's S4 list: every item has a test.

**The owner's decisions.** Cap as ceiling, benchmark, qualifying income and its exclusion, elevated service, no waiver, one line per person → Tasks 2, 3, 7. Founder true-up replaced → Tasks 7 and 9 and the Deploy procedure. Nothing unattended → Tasks 1 and 8 and Verification Step 2. GL concept → Task 4. First MSO month August 2026 → Deploy and Verification Steps 1 and 4. Bills dated the last day of the fee month → Task 1 (the date methods and their test) and Task 8 (the closed-books error). garden3d's passes admin-only → Tasks 6 and 10 keep their own admin guards and no longer test what a lead sees on the pass.

**Review findings, and where each landed.**

| Finding | Where |
| --- | --- |
| C1 frozen founder true-up double-pays | Task 9: `Trueup` `before_destroy`, admin rescue. Task 7: the run refuses beside a founder true-up. Decisions 4; Deploy steps 3–4 |
| C2 founder true-ups come back unattended | Task 9: skip keyed on role period OR snapshot line OR MSO true-up (deleted included); `MsoRolePeriod` destroy/edit guards with form errors. Rollback step 1. Decisions 5 |
| C3 no fresh computation before the locking bill | Task 7: `Mso::MonthlyRun.preview`. Task 8: `FiguresChanged`. Decisions 22 |
| I1 sub-cent amounts | Task 7: `Planned#amount` floors to cents, used everywhere. Decisions 16 |
| I2 stale-true stamp, bypassable safety net | Task 1: `invalidated_at`, `invalidate!`, `unconfirm_collection!`. Task 7: refusal and any other failure invalidate; nightly database-only fee check. Task 8: live re-check at first bill; attach/detach and Refresh clear the stamp. Decisions 21 |
| I3 billed true-up never settles | Task 1: `payable?` true when billed. Task 8: read-only mirror refresh, nightly. Decisions 23 |
| I4 privacy | Task 6: owner-only acceptance. Task 5: people-cost patterns. Task 3: aggregate leaves MSO out. Decisions 27, 29, 30 |
| I5 silent no-op sync | Task 8: `MissingVendor`, `AccountNotConfigured`; Money page shows messages |
| I6 Remove bill | Task 8: `remove_qbo_bill!` clears acceptance, invalidates |
| I7 variance | Task 7: message with breakdown and numbered remedies; override not built (question J) |
| I8 tests | Founder true-up present → Task 7; both C2 sequences → Task 9; month M not reducing M+1, sub-cent, stamp not restorable, two runs → Task 7; billed-then-unpayable settles → Task 8; aggregate → Task 3; outlook → Task 5; `.json` as a lead and as another executive → Task 10 |
| Minors | Accept race and amount check → Tasks 1, 7, 10. Over the cap → Tasks 1, 7, 10. Tier edits → Task 9. Superseded page from stored lines → Task 10. `schema_ready?` → Task 1. Double-click Sync → Task 8. Late profit shares → limitations below |

**No finding was rejected.** Three were applied with a difference, each stated where it is built: the nightly fee check *invalidates* the snapshot instead of only clearing the stamp, because a moved fee means a moved cap and re-confirming collection alone would restore payability at the old figures; the aggregate leaves MSO true-ups out for everyone, not only for non-admins; and "refuse changing a period a snapshot references" counts superseded snapshots too.

**Differences from the spec, to carry back into it.** Decisions 11–17 and 20–24. The ones that change a rule: `payable?` reads a stamp and an invalidation flag; a true-up is rounded down to the cent and a zero has no row; a billed true-up is locked and counts as payable; the first bill is gated on a live collection check and a fresh computation; the run refuses beside a founder true-up; the company-wide balance leaves MSO true-ups out.

**Known limitations, stated rather than solved.**

- **Late profit shares cause small drift on quarter-end months.** A profit share is dated the last day of its quarter and written weeks later. A quarter-end month run (and billed) before then has an "already earned" that is too low; the later re-run records drift on the billed rows. The first-bill check catches it only if the profit share exists by then.
- A founder true-up whose bill has been **paid** cannot be replaced by an MSO true-up for that month without Finance voiding the payment.
- A role period entered for the wrong person and then run can only be corrected from the console.
- An executive with no Stacks login cannot accept; nobody can accept for them.
- The first-bill check costs one benchmark computation per row (969 queries for September 2026).
- "Has this bill been paid" on the Money page is as fresh as the last nightly read-only refresh.
- Two runs of one month are serialised by a row lock that a single-process test can only exercise in sequence.
- The amounts are partly derivable by any lead (Decisions 30).
- `Qbo::BillRouter`'s `:mso_compensation` has never resolved to a real account, and no MSO bill has ever been written. The closed-books error is recognised by its message text, which has not been seen from QuickBooks.
- The `schema_ready?` guards are tested by stubbing. They can be removed once production is migrated.
- The page tests in Task 11 are the first tests to render the contributor ledger page.
- `QboAccount#sync_all_bills!` detaches the six older host classes by bill id across every QuickBooks account. The new line is scoped; the old ones are not touched.

**Placeholders.** One, deliberate: Task 9's `FOUNDER_EMAIL` is given as "the literal from line 96" so that this document does not repeat a person's address.

**Type consistency.** `Mso::MonthlyRun.call` returns the `MsoSnapshot` the admin action redirects to; `.preview` returns `{ ledger_id => BigDecimal }` in whole cents, which `MsoTrueup#sync_qbo_bill!` compares with the row's `amount`. `Planned#amount` is the one place a true-up is rounded. `already_earned` returns `{ ledger_id => BigDecimal }`. Snapshot `lines` are an Array of String-keyed Hashes whose amounts are Strings. `MsoSnapshot#check_collection!` returns a Boolean and raises `MsoSnapshot::Unusable` when superseded or invalidated. `MsoTrueup#payable?` returns a Boolean from stored data only. Every refusal to sync is a `MsoTrueup::SyncRefused`. `Money::PayableQboBills.host_klasses` is what every iteration uses. `include_mso_trueups:` defaults to `true` on all five methods that take it. `MsoTrueup.schema_ready?` is the one guard.
