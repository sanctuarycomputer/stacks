# Multi-Enterprise PR 1: Ledger Routing (no STI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Promote Stacks to a true multi-enterprise platform by introducing a `Ledger` (per-(enterprise, contributor)) that becomes the anchor for every ledger-affecting record. Keep the existing per-type AR models and tables (no STI); each gains a `ledger_id` foreign key. Drop `MiscPayment` (folded into `ContributorAdjustment` and the new `LedgerWithdrawal`). Add `LedgerWithdrawal` as its own model + table (skeleton for the future automated-withdrawal feature). Admin pages nest under `Ledger`. Elevated service computation moves to `Contributor#elevated_service_for_month` because it aggregates across enterprises.

**Architecture:** No STI — each ledger-affecting model keeps its own table with type-specific columns. Common interface lives in a shared `Concerns::LedgerItem` module. `Ledger` is the routing layer between `Contributor` and the per-type models; `Contributor`'s associations to those models go `through: :ledgers`. `contributor_id` columns get DROPPED from each legacy table; the Ledger is the sole source of contributor identity for each item.

**Tech Stack:** Rails 6.1, Ruby 3.1.7, PostgreSQL, Minitest + Mocha, ActiveAdmin, `acts_as_paranoid`.

---

## File map

**New files:**
- `db/migrate/<ts1>_add_multi_enterprise_infrastructure.rb` — enterprises.deel_legal_entity_id, deel_contracts.deel_legal_entity_id (with inline backfill from data), enterprise_forecast_clients join table
- `db/migrate/<ts2>_create_ledgers.rb`
- `db/migrate/<ts3>_route_ledger_models_through_ledger.rb` — add ledger_id to contributor_payouts, contributor_adjustments, trueups, reimbursements, profit_shares; backfill via Sanctuary ledger; make NOT NULL; drop contributor_id
- `db/migrate/<ts4>_fold_misc_payments_into_adjustments.rb` — migrate MiscPayment rows into ContributorAdjustment, drop misc_payments
- `db/migrate/<ts5>_create_ledger_withdrawals.rb`
- `app/models/concerns/ledger_item.rb` — shared interface module
- `app/models/enterprise_forecast_client.rb`
- `app/models/ledger.rb`
- `app/models/ledger_withdrawal.rb`
- `app/admin/ledgers.rb`
- `test/models/enterprise_forecast_client_test.rb`
- `test/models/ledger_test.rb`
- `test/models/ledger_withdrawal_test.rb`
- `test/models/forecast_client_test.rb`
- `test/models/deel_contract_test.rb`
- `test/lib/stacks/deel_test.rb`
- `test/fixtures/enterprise_forecast_clients.yml`
- `test/fixtures/ledgers.yml`
- `test/fixtures/ledger_withdrawals.yml`

**Modified files:**
- `app/models/enterprise.rb` — `Enterprise.sanctuary`, `has_many :enterprise_forecast_clients`, `has_many :forecast_clients, through:`, `has_many :ledgers`
- `app/models/forecast_client.rb` — `has_one :enterprise_forecast_client`, `has_one :enterprise, through:`, `#billing_enterprise`
- `app/models/contributor.rb` — drop direct `has_many` for ledger-bearing types; replace with `through: :ledgers`; drop `new_deal_ledger_items`, `new_deal_balance`, `aggregated_new_deal_balance`; add `#elevated_service_for_month`, `#all_items_grouped_by_month`
- `app/models/contributor_payout.rb` — include `Concerns::LedgerItem`; `belongs_to :ledger`; delegate :contributor; drop direct `belongs_to :contributor`; admin-form virtual attribute `contributor_id` derives `ledger_id`
- `app/models/contributor_adjustment.rb` — same pattern
- `app/models/trueup.rb` — same
- `app/models/reimbursement.rb` — same
- `app/models/profit_share.rb` — same
- `app/models/deel_contract.rb` — `#extract_legal_entity_id`
- `app/models/invoice_tracker.rb` — `make_contributor_payouts!` creates payouts with `ledger:` instead of `contributor:`
- `app/models/periodic_report.rb` — creates ProfitShares with `ledger:`; profit-share-acceptance methods updated to walk through ledgers
- `lib/stacks/deel.rb` — `sync_contracts!` writes `deel_legal_entity_id`
- `lib/stacks/system.rb` — `sync_founder_trueups!` uses `ledger:`
- `lib/tasks/stacks.rake` — `sync_contributor_qbo_bills` uses `c.contributor_payouts` etc. (still works via through association)
- `db/seeds.rb` — seed Sanctuary Enterprise
- `app/admin/contributors.rb` — uses Ledger UI
- `app/admin/ledgers.rb` (new) — registers Ledger; show page renders items
- `app/admin/contributor_payouts.rb` — `belongs_to :invoice_tracker` (legacy URL nesting preserved); form uses `contributor_id` virtual attr
- `app/admin/contributor_adjustments.rb` — `belongs_to :ledger`; nested under Ledger
- `app/admin/trueups.rb` — `belongs_to :ledger`; nested under Ledger
- `app/admin/reimbursements.rb` — `belongs_to :ledger`; nested under Ledger
- `app/admin/misc_payments.rb` — DELETED
- `app/models/misc_payment.rb` — DELETED
- `app/views/admin/contributors/_show.html.erb` — tab bar with "All" + per-enterprise tabs; "All" tab is the only place elevated_service pill renders
- `test/fixtures/enterprises.yml` — add sanctuary row
- Various tests reflecting the new associations

**Deleted files:**
- `app/models/misc_payment.rb`
- `app/admin/misc_payments.rb`
- `test/fixtures/misc_payments.yml` (if exists)

---

## Task list

### Task 1: Multi-enterprise infrastructure + DeelContract caching

Single migration adds three things:
1. `enterprises.deel_legal_entity_id` (string, unique partial-index where NOT NULL).
2. `deel_contracts.deel_legal_entity_id` (string, indexed). Inline backfill: `UPDATE deel_contracts SET deel_legal_entity_id = data#>>'{client,legal_entity,id}' WHERE deel_legal_entity_id IS NULL`.
3. `enterprise_forecast_clients` join table (`enterprise_id`, `forecast_client_id` integer matching `forecast_clients.forecast_id`, unique on forecast_client_id).

Plus model + helper code:
- `Enterprise::SANCTUARY_NAME` constant + `Enterprise.sanctuary` class method (Thread.current memoized).
- `Enterprise has_many :enterprise_forecast_clients`, `has_many :forecast_clients, through:`.
- `EnterpriseForecastClient` model (belongs_to both sides, primary_key: :forecast_id on forecast_client).
- `ForecastClient has_one :enterprise_forecast_client`, `has_one :enterprise, through:`, `#billing_enterprise` returning linked enterprise or `Enterprise.sanctuary`.
- `DeelContract#extract_legal_entity_id` reading `data["client"]["legal_entity"]["id"]`.
- `Stacks::Deel#sync_contracts!` writes `deel_legal_entity_id:` in the upsert hash.
- `db/seeds.rb` seeds Sanctuary Enterprise row.
- `test/fixtures/enterprises.yml` includes sanctuary row.

Tests for each piece. Single commit.

### Task 2: Ledger model

Migration creates `ledgers` (enterprise_id NOT NULL, contributor_id NOT NULL, unique composite).

Model:
```ruby
class Ledger < ApplicationRecord
  belongs_to :enterprise
  belongs_to :contributor

  validates :enterprise_id, uniqueness: { scope: :contributor_id }

  def self.find_or_create_for(enterprise:, contributor:)
    find_or_create_by!(enterprise: enterprise, contributor: contributor)
  end
end
```

Associations on `Contributor` and `Enterprise`: `has_many :ledgers`.

Empty fixture file. Tests for create, uniqueness, find_or_create_for.

### Task 3: Add `Concerns::LedgerItem` module

Create `app/models/concerns/ledger_item.rb`:

```ruby
module Concerns
  module LedgerItem
    extend ActiveSupport::Concern

    included do
      belongs_to :ledger
      delegate :contributor, :enterprise, to: :ledger
    end

    # Default — override per-host.
    def signed_amount
      amount
    end

    # Default — override per-host.
    def payable?
      accepted_at.present?
    end
  end
end
```

(The host model still has `acts_as_paranoid`, type-specific validations, type-specific date attribute mapped to `effective_on` semantics via per-host method, etc. Each host overrides `signed_amount` / `payable?` as needed.)

No tests yet — exercised through host model tests.

### Task 4: Add `ledger_id` to each legacy ledger-bearing table; drop `contributor_id`

Big migration:
1. `add_reference :contributor_payouts, :ledger, null: true, foreign_key: true`
2. Same for `contributor_adjustments`, `trueups`, `reimbursements`, `profit_shares`.
3. For each table, backfill: iterate rows, find_or_create the Sanctuary ledger for the contributor, set `ledger_id`.
4. Make `ledger_id` NOT NULL on each.
5. Drop `contributor_id` from each table.

Model updates:
- `ContributorPayout`: drop `belongs_to :contributor`; include `Concerns::LedgerItem`; remove `forecast_person` direct belongs_to (handled via delegate). Keep all method bodies untouched — they reference `contributor` which now goes via delegate.
- Same pattern for `ContributorAdjustment`, `Trueup`, `Reimbursement`, `ProfitShare`.
- `Contributor`: replace direct `has_many :contributor_payouts` with `has_many :contributor_payouts, through: :ledgers`. Same for the other 4 models. Drop `has_many :*_with_deleted` versions OR replicate as `through: :ledgers` with a `with_deleted` scope chain.

Tests:
- Existing model tests for CP, CA, Trueup, etc. should keep passing (the change is internal).
- `Contributor#contributor_payouts.first.contributor` still returns the contributor (via delegate).

### Task 5: Form-virtual-attribute for `contributor_id`

For models still expected by admin forms to take a `contributor_id` (Reimbursement, ContributorAdjustment, ContributorPayout):

```ruby
class Reimbursement < ApplicationRecord
  include Concerns::LedgerItem
  attr_accessor :contributor_id_virtual

  before_validation :derive_ledger_from_contributor_id_virtual

  private def derive_ledger_from_contributor_id_virtual
    return if ledger.present?
    return if contributor_id_virtual.blank?
    self.ledger = Ledger.find_or_create_for(
      enterprise: Enterprise.sanctuary,
      contributor: Contributor.find(contributor_id_virtual),
    )
  end
end
```

For ContributorPayout, the enterprise comes from `invoice_tracker.forecast_client.billing_enterprise` instead of always Sanctuary.

Admin pages' `permit_params` add `:contributor_id_virtual` (renamed in the view to `:contributor_id`).

Actually — simpler: since `Contributor` still exists as a model, and the form's select for "contributor" can submit any param name, just use `permit_params :ledger_id` and have a select field that posts ledger_id directly. The ledger nesting (Task 7) makes this automatic for most cases.

For ContributorPayout under InvoiceTracker (legacy URL nesting): form provides invoice_tracker_id, admin selects contributor, model derives ledger from `invoice_tracker.forecast_client.billing_enterprise + contributor`. Use the virtual-attribute pattern there.

### Task 6: Migrate MiscPayments into ContributorAdjustments; drop MiscPayment

Migration:
- For each MiscPayment row: insert a ContributorAdjustment with `amount = -original.amount` (MiscPayment was deducted from balance; CA with negative amount achieves the same), `effective_on = paid_at`, `description = "Misc payment: #{remittance.presence || 'no remittance'}"`, `ledger_id = original.ledger.id` (via Task 4 backfill), `created_at`/`updated_at`/`deleted_at` preserved.
- Drop the `misc_payments` table.
- Delete `app/models/misc_payment.rb`, `app/admin/misc_payments.rb`, `app/views/admin/misc_payments/`.
- Update `Contributor` — remove `has_many :misc_payments`.
- Update `app/views/admin/contributors/_show.html.erb` — remove MiscPayment branches in is_a? checks (those branches still appear in the legacy file at this point).
- Update `lib/tasks/stacks.rake` — `c.misc_payments` references → drop (already absorbed into adjustments).

Verify: row counts before+after match (MP count moves into CA count).

### Task 7: New `LedgerWithdrawal` model

Migration creates `ledger_withdrawals`:
- ledger_id NOT NULL FK
- amount decimal(12, 2) NOT NULL
- effective_on date NOT NULL
- description text
- withdrawal_method integer enum (deel_contract: 0)
- withdrawal_status string ("pending"/"approved"/"paid"/"rejected"/"cancelled")
- deel_contract_id string nullable
- deel_adjustment_id string nullable (unique partial index)
- accepted_at timestamp
- deleted_at timestamp
- timestamps

Model:
```ruby
class LedgerWithdrawal < ApplicationRecord
  acts_as_paranoid
  include Concerns::LedgerItem

  enum withdrawal_method: { deel_contract: 0 }

  PAYABLE_STATUSES = %w[approved paid].freeze

  validates :amount, presence: true, numericality: true
  validates :effective_on, presence: true

  def signed_amount
    -amount
  end

  def payable?
    PAYABLE_STATUSES.include?(withdrawal_status.to_s)
  end
end
```

`Contributor has_many :ledger_withdrawals, through: :ledgers`.

Tests: signed_amount returns -amount, payable? branches, enum mapping.

Skeleton only. The full feature (UI + Deel polling) ships in a later PR.

### Task 8: Aggregation on Ledger + Contributor

`Ledger#balance` / `#unsettled`:

```ruby
def balance
  all_items.select(&:payable?).sum(&:signed_amount)
end

def unsettled
  all_items.reject(&:payable?).sum(&:signed_amount)
end

private

def all_items
  contributor_payouts.with_deleted.to_a +
    contributor_adjustments.with_deleted.to_a +
    trueups.with_deleted.to_a +
    reimbursements.with_deleted.to_a +
    profit_shares.with_deleted.to_a +
    ledger_withdrawals.with_deleted.to_a
end
```

`Ledger#items_grouped_by_month(include_salary: false)` — month-bucketed ledger items, NO elevated_service computation (that lives on Contributor).

`Contributor#all_ledger_items_grouped_by_month` — merges items across all ledgers, bucketed by month, with elevated_service / total_hours / partial_salary / fulltime computed from the aggregate. The "All" tab in the UI uses this.

`Contributor#elevated_service_for_month(month_period)` — exposes the elevated_service determination for a specific month, used by `PeriodicReport#tentative_profit_shares_by_contributor`.

### Task 9: Admin nesting under Ledger

`app/admin/ledgers.rb` (new):
```ruby
ActiveAdmin.register Ledger do
  belongs_to :contributor
  permit_params :enterprise_id
  # show page renders all items for this ledger; "Add adjustment", "Add reimbursement" etc actions.
end
```

For each child model, add `belongs_to :ledger, optional: true` (already there from model `belongs_to`) and update the admin:

```ruby
ActiveAdmin.register ContributorAdjustment do
  belongs_to :ledger, optional: true   # AA-side nesting; supports both /admin/contributor_adjustments/:id and /admin/ledgers/:ledger_id/contributor_adjustments/:id

  permit_params :amount, :effective_on, :description, :ledger_id
  # No custom create method — ledger_id is in permit_params and provided by URL nesting.
end
```

Same pattern for Trueup, Reimbursement.

ContributorPayout stays nested under InvoiceTracker (preserving QBO bill URLs). Its form's contributor selection uses a virtual attribute that derives ledger via `invoice_tracker.forecast_client.billing_enterprise`.

Delete misc_payments admin entirely (Task 6 already deleted the model).

### Task 10: Contributor admin show page — multi-ledger tabs

`app/views/admin/contributors/_show.html.erb` renders a tab bar:
- Tabs: "All" (default), one tab per Enterprise with non-empty ledger.
- Selected tab passed via `?ledger=<enterprise_name>` or `?ledger=all`.
- "All" tab body renders `contributor.all_ledger_items_grouped_by_month` and shows the elevated_service pill per month.
- Per-enterprise tab body renders that ledger's items (no elevated_service pill).
- Type label / pill rendering: keep the per-type icon and existing label semantics (e.g. "Contributor payout").

### Task 11: Update callers + cleanup

- `lib/tasks/stacks.rake` `sync_contributor_qbo_bills`: `c.contributor_payouts`, `c.contributor_adjustments`, `c.profit_shares` still work via through associations. Verify.
- `lib/stacks/system.rb#sync_founder_trueups!`: change `Trueup.find_or_initialize_by(contributor: hugh, ...)` to `Trueup.find_or_initialize_by(ledger: hugh_ledger, ...)`.
- `lib/stacks/quickbooks.rb#cleanup_orphaned_qbo_objects!`: no change needed (no STI offsets).
- Update fixtures / fixture-referencing tests.

### Task 12: Drop `enterprise.snapshot` regression test + verify full suite

After all the above, run `bundle exec rails test`. Goal: 0 failures (modulo the pre-existing AdminUser timezone flake).

### Task 13: Reconciliation + final verification

- Migration runs cleanly on a prod-restore dev DB.
- Row counts: existing CP/CA/Trueup/Reimb/PS counts preserved. MP count migrated into CA.
- `Ledger.count == Contributor.count` (one Sanctuary ledger per contributor after migration).
- Smoke check `/admin/contributors/<id>` — "All" tab + Sanctuary tab; ledger items render; elevated_service pill on "All".
- Smoke check `/admin/ledgers/:id` — per-ledger view.
- Submit a Reimbursement via the admin form → confirm save.

### Task 14: Force-push + update PR #93 description

Force-push to PR #93 (since branch was reset). Update PR description to reflect the new (no-STI) architecture.

---

## Risks and mitigations

**Through associations on Contributor:** `Contributor#contributor_payouts` and friends now use `through: :ledgers`, which generates JOIN SQL instead of direct lookup. Each query gets a JOIN. For typical contributor pages (one contributor, finite items), this is negligible. The `.where(contributor_id: X)` queries that previously hit the direct FK are gone — callers using through will work, but explicit `.where(contributor: X)` style queries need to change to `.joins(:ledger).where(ledgers: { contributor: X })`. Audit grep for `where(contributor:` in CP/CA/Trueup/Reimb/PS contexts during Task 4.

**Form virtual attributes vs ledger_id:** Some admin forms keep their existing UX (admin picks a contributor from a select). The virtual `contributor_id` attribute pattern means the form posts contributor_id, the model derives ledger_id in `before_validation`. Cleaner than custom create methods but requires care that:
- the virtual attribute is in `permit_params`
- the derivation runs before validation
- if `ledger_id` is already set (admin posted it directly), don't override

**MiscPayment migration:** 313 rows. Each becomes a ContributorAdjustment. Sign convention: legacy MP was deducted from balance (`acc[:balance] -= mp.amount`), so the new CA stores `-original.amount` to achieve the same. Description preserved via `"Misc payment: #{remittance}"`.

**Admin URL nesting:** Ledger items nested under Ledger; CP nested under InvoiceTracker. URL patterns:
- `/admin/contributors/:contributor_id/ledgers/:id` — ledger show
- `/admin/ledgers/:ledger_id/contributor_adjustments/new` — new CA
- `/admin/invoice_trackers/:itid/contributor_payouts/:id` — CP show (legacy URL preserved)
- `/admin/contributor_adjustments/:id` — direct access still works (AA `belongs_to ..., optional: true`)

**Elevated service across enterprises:** `Contributor#elevated_service_for_month(period)` reads from ALL the contributor's ledgers' items in that period plus admin_user salary/hours. Profit-share-qualification logic in `PeriodicReport#tentative_profit_shares_by_contributor` calls this single method for each month.
