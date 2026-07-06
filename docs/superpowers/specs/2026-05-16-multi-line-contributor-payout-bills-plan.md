# Implementation plan — Multi-line CP bills

Branch off `main`: `feat/multi-line-contributor-payout-bills`.

## Step 1 — Add `ContributorPayoutQboBillLines` (pure compute, fully unit-tested)

**New file:** `app/models/contributor_payout_qbo_bill_lines.rb`

A plain Ruby class instantiated per ContributorPayout. Takes the CP and a `qbo_accounts` array (the result of `qbo_account.fetch_all_accounts`). Exposes a single public method `call` that returns an array of `{ amount:, description:, account: }` hashes.

Internal constants:

```ruby
ROLE_LABEL_BY_BUCKET = {
  individual_contributor:  "Individual Contributor",
  account_lead_base:       "Account Lead",
  account_lead_surplus:    "Account Lead Surplus",
  project_lead_base:       "Project Lead",
  project_lead_surplus:    "Project Lead Surplus",
  commission:              "Commission",
}.freeze

# Substring in description_line that identifies a surplus-share entry
# inside the mixed AccountLead / ProjectLead buckets.
SURPLUS_DESCRIPTION_MARKER = "surplus revenue".freeze
```

Algorithm:

1. If `cp.in_sync?` is false → return a single-line collapse (see Step 1.5).
2. Build a 6-bucket hash by walking `cp.blueprint`:
   - `IndividualContributor` and `Commission` map directly.
   - `AccountLead` entries split by `description_line.include?(SURPLUS_DESCRIPTION_MARKER)` → base or surplus bucket.
   - `ProjectLead` entries split the same way.
3. For each bucket, build a `{ amount, description, account }` hash:
   - `amount`: sum of entry `amount` fields, rounded to 2 decimals. Skip the bucket entirely if `amount == 0`.
   - `description`: heading like `"# Account Lead Surplus\n"` + joined `description_line` strings (mirrors the existing aggregate-description format in `invoice_tracker.rb:596-602`).
   - `account`: result of `account_for_bucket(bucket, qbo_accounts)`. Tries the specific name first, then falls back to `cp.find_qbo_account!.first` (the default).
4. Safety check: if `lines.sum(:amount).round(2) != cp.amount.to_f.round(2)`, return single-line collapse instead. Log a WARN.
5. Return the lines array.

### Step 1.5 — Single-line collapse helper

`single_line` private method on the class: returns `[{ amount: cp.amount, description: cp.bill_description, account: cp.find_qbo_account!.first }]`. Used by both the out-of-sync branch and the drift-safety branch.

### Step 1.6 — `account_for_bucket(bucket, qbo_accounts)` helper

Computes the bucket-specific account name. For a contributor's studio:

```ruby
studio = cp.contributor.forecast_person.studio
studio_label = studio&.qbo_subcontractors_categories&.first
return default_account if studio_label.nil?

specific_name = "Contractors - #{ROLE_LABEL_BY_BUCKET[bucket]} - #{studio_label}"
qbo_accounts.find { |a| a.name == specific_name } || default_account
```

`default_account` is `cp.find_qbo_account!(qbo_accounts).first` — the existing single-account routing (with internal-client override preserved). Memoized per-call.

## Step 2 — Extend `SyncsAsQboBill` with a `bill_line_items` hook

**Edit:** `app/models/concerns/syncs_as_qbo_bill.rb`

Refactor `sync_qbo_bill!` so the line construction goes through a new method:

```ruby
bill.line_items = bill_line_items(qa.fetch_all_accounts)
```

(That `fetch_all_accounts` call already happens inside `find_qbo_account!`; refactor to fetch once and pass through to avoid duplicate API calls.)

Add a default `bill_line_items` implementation in the concern:

```ruby
def bill_line_items(qbo_accounts)
  account, _studio = find_qbo_account!(qbo_accounts)
  line = Quickbooks::Model::BillLineItem.new(description: bill_description, amount: amount)
  line.account_based_expense_item! do |detail|
    detail.account_ref = Quickbooks::Model::BaseReference.new(account.id)
  end
  [line]
end
```

Equivalent to the current inline construction. Other hosts inherit this default unchanged.

## Step 3 — `ContributorPayout#bill_line_items` override

**Edit:** `app/models/contributor_payout.rb`

```ruby
def bill_line_items(qbo_accounts)
  lines_data = ContributorPayoutQboBillLines.new(self, qbo_accounts).call
  lines_data.map do |data|
    line = Quickbooks::Model::BillLineItem.new(
      description: data[:description],
      amount: data[:amount],
    )
    line.account_based_expense_item! do |detail|
      detail.account_ref = Quickbooks::Model::BaseReference.new(data[:account].id)
    end
    line
  end
end
```

Pure data → BillLineItem conversion. All bucketing / account lookup / fallback logic lives in `ContributorPayoutQboBillLines`.

## Step 4 — Tests

**New file:** `test/models/contributor_payout_qbo_bill_lines_test.rb`

Cases (each with a synthetic CP + qbo_accounts list, no API calls):

1. Multi-line happy path: blueprint with all 6 buckets populated, all bucket-specific QBO accounts present → returns 6 lines with correct amounts and accounts.
2. Skips zero-amount buckets (e.g., Commission empty) → returns 5 lines.
3. AL bucket mixed (one base entry + one surplus entry) → splits to 2 separate lines with correct amounts.
4. Specific bucket account missing in qbo_accounts → that one line falls back to default account; other lines keep their specific accounts.
5. `cp.in_sync?` is false → returns single-line at default account.
6. Multi-line sum drifts (synthetic blueprint where bucket sums total to something other than cp.amount) → returns single-line at default account, logs WARN.
7. Studio-less contributor → all lines fall back to default account.

**Edit:** `test/models/contributor_payout_test.rb`

Add coverage that `ContributorPayout#bill_line_items` delegates correctly (one assertion confirming the return is the same as what `ContributorPayoutQboBillLines.new(...).call` would produce after the data-to-model conversion).

**Confirm passing:** existing `Trueup`, `ContributorAdjustment`, `ProfitShare`, `PayStub` tests that exercise `SyncsAsQboBill` continue to pass — proves the default `bill_line_items` preserves current behavior.

## Step 5 — Verification

Run the full suite. Confirm no regressions. Expect 1 known UTC-midnight flake on `admin_user_test.rb:331` — unrelated.

## Step 6 — Commit + push + PR

Single commit on `feat/multi-line-contributor-payout-bills`, off `main`. PR body explains the bucket model, the in_sync? fallback, the per-bucket-account fallback, and that no schema or data migration ships.

## Codebase notes (self-review)

- `ContributorPayout#find_qbo_account!` (line 29) does NOT accept a `qbo_accounts` arg — must add `(qbo_accounts = nil)` and forward to `super`, mirroring the SyncsAsQboBill default. Otherwise each bill makes 2 `fetch_all_accounts` API calls.
- `CP#bill_description` is just an admin URL; per-line descriptions in multi-line mode should add a role heading and the entries' `description_line` strings on top of that URL.
- `default_account` (the fallback) is memoized per `ContributorPayoutQboBillLines` instance — only computed if any line actually falls back.
- Drift-safety fallback logs via `Rails.logger.warn` (not a Stacksbot exception). The single-line collapse handles it silently from a sync-failure perspective.

## Sub-agent decomposition

Three independently-buildable chunks, each gets its own sub-agent dispatch:

- **Agent A — ContributorPayoutQboBillLines + its tests** (Step 1 + Step 4 test file). Self-contained — no edits to other files. Output: `app/models/contributor_payout_qbo_bill_lines.rb` + `test/models/contributor_payout_qbo_bill_lines_test.rb`.
- **Agent B — SyncsAsQboBill `bill_line_items` extraction** (Step 2). Refactor the existing single-line construction into a default `bill_line_items` method. Verify all existing `SyncsAsQboBill` tests pass.
- **Agent C — ContributorPayout `bill_line_items` override + delegation test** (Step 3 + the contributor_payout_test.rb addition). Depends on A and B landing first.

I'll run A and B in parallel, then C in serial.
