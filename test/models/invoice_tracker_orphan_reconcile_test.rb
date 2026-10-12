require "test_helper"

# Generation predicts which earlier payouts it cannot remove from the cached
# QBO bill, then finds out for real when it deletes them. These cover the two
# ways the prediction can be wrong: what is saved must follow what happened.
class InvoiceTrackerOrphanReconcileTest < ActiveSupport::TestCase
  include PayoutFixtures

  setup do
    setup_payout_people
    build_tracker("new_deal_v1")
  end

  # A leftover payout on the ledger of someone this invoice no longer pays,
  # whose IC chunk is priced low enough on line "1" to generate lead surplus:
  # margin (10,000 - 1,000) / 10,000 = 0.90, less the 0.43 threshold = 4,700,
  # 15% of which (705) goes to each lead.
  def add_stale_payout(it)
    stranger = ForecastPerson.create!(forecast_id: 710_009, email: "stale-guard@example.com", data: {})
    stranger.ensure_contributor_exists!
    ledger = Ledger.find_or_create_for(enterprise: @client.billing_enterprise, contributor: stranger.reload.contributor)
    stale = ContributorPayout.new(
      invoice_tracker: it,
      ledger: ledger,
      amount: 1000.0,
      blueprint: { "IndividualContributor" => [{ "amount" => 1000.0, "blueprint_metadata" => { "id" => "1", "forecast_project" => @project.forecast_id, "forecast_person" => stranger.forecast_id } }] },
      created_by: @creator,
    )
    stale.skip_seventy_percent_check = true
    stale.save!
    it.contributor_payouts.reset
    stale
  end

  def cached_bill_says_paid
    bill = mock("qbo_bill")
    bill.stubs(:has_payments?).returns(true)
    ContributorPayout.any_instance.stubs(:qbo_bill).returns(bill)
  end

  # The live check at delete time refuses, whatever the cache said.
  def qbo_refuses_the_delete
    ContributorPayout.any_instance.stubs(:detach_and_destroy_qbo_bill).raises(SyncsAsQboBill::PaidQboBillError, "cannot verify")
  end

  def amounts(it)
    it.contributor_payouts.reload.map { |cp| [cp.id, cp.amount.to_f] }.sort
  end

  def amount_for(it, forecast_person)
    it.contributor_payouts.reload.find { |cp| cp.contributor.forecast_person == forecast_person }&.amount&.to_f
  end

  def surplus_entries(it)
    it.contributor_payouts.reload.flat_map { |cp| cp.blueprint.values_at("AccountLeadSurplus", "ProjectLeadSurplus").flatten.compact }
  end

  def assert_removable_orphan_is_reconciled(allow_over_cap:)
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    stale = add_stale_payout(it)
    cached_bill_says_paid

    preflight = InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(it))
    assert_equal [stale], preflight.retained_orphans
    assert_in_delta 9410.0, preflight.pool, 0.01 # 5700 + (800 + 705) + (500 + 705) + the stale 1000
    assert preflight.breached?, "the pre-flight must judge this over the cap"

    it.make_contributor_payouts!(@creator, allow_over_cap: allow_over_cap)

    assert_nil ContributorPayout.find_by(id: stale.id), "the stale payout was removable after all"
    assert_equal [500.0, 800.0, 5700.0], it.contributor_payouts.reload.map { |cp| cp.amount.to_f }.sort
    assert_equal 7000.0, it.contributor_payouts.sum { |cp| cp.amount.to_f }
    assert_empty surplus_entries(it), "no lead may be paid surplus from a payout that no longer exists"
    written = InvoicePayouts::MarginCheck.new(it.written_payout_build)
    assert_empty written.retained_orphans
    assert_in_delta 7000.0, written.pool, 0.01
    assert_not written.breached?
  end

  test "a payout predicted to stay that is in fact removed pays no surplus, forced" do
    assert_removable_orphan_is_reconciled(allow_over_cap: true)
  end

  test "a payout predicted to stay that is in fact removed leaves the invoice within its cap, so no force is needed" do
    assert_removable_orphan_is_reconciled(allow_over_cap: false)
  end

  test "a payout not predicted to stay that survives still feeds lead surplus" do
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }], total: 20_000.0)
    stale = add_stale_payout(it)
    preflight = InvoicePayouts::Build.new(it)
    assert_equal [stale], preflight.orphan_candidates
    assert_empty preflight.retained_orphans, "the cache does not say the bill is paid"
    qbo_refuses_the_delete

    assert_nothing_raised { it.make_contributor_payouts!(@creator) }

    assert_in_delta 1000.0, stale.reload.amount.to_f, 0.001
    assert_nil stale.deleted_at
    assert_in_delta 5700.0, amount_for(it, @ic), 0.001
    assert_in_delta 800.0 + 705.0, amount_for(it, @al), 0.001
    assert_in_delta 500.0 + 705.0, amount_for(it, @pl), 0.001
    assert_equal 4, it.contributor_payouts.reload.length
    assert_equal [stale.id], it.written_payout_build.retained_orphans.map(&:id)
    written = InvoicePayouts::MarginCheck.new(it.written_payout_build)
    assert_in_delta 9410.0, written.pool, 0.01
    assert_in_delta 14_000.0, written.cap, 0.01
    assert_not written.breached?
  end

  test "a payout not predicted to stay that survives and tips the invoice over its cap rolls the write back" do
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    it.make_contributor_payouts!(@creator)
    stale = add_stale_payout(it)
    # A successful write would now pay the IC 100 hrs * $50, not 5700.
    @project.update!(notes: "#{@ic.email}:50p/h")
    assert_not InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(it)).breached?, "without the survivor this is within the cap"
    before = amounts(it)
    assert_equal [1000.0, 500.0, 800.0, 5700.0].sort, before.map(&:last).sort
    qbo_refuses_the_delete

    error = assert_raises(InvoiceTracker::PayoutsOverCapError) { it.make_contributor_payouts!(@creator) }
    assert_equal "Payouts would exceed the cap because an earlier payout (##{stale.id}) could not be removed: its QBO bill has payments or could not be checked. No payouts were changed, though QBO bills of other removed payouts may already have been deleted and will be recreated on the next sync. Retry once QBO is reachable, or generate with a reason.", error.message
    assert_equal before, amounts(it)
    assert_nil it.written_payout_build

    assert_nothing_raised { it.make_contributor_payouts!(@creator, allow_over_cap: true) }
    # The IC's own chunk: margin 0.50 - 0.43 = 700 surplus, 105 to each lead,
    # on top of the survivor's 705.
    assert_in_delta 5000.0, amount_for(it, @ic), 0.001
    assert_in_delta 800.0 + 105.0 + 705.0, amount_for(it, @al), 0.001
    assert_in_delta 500.0 + 105.0 + 705.0, amount_for(it, @pl), 0.001
    assert_in_delta 1000.0, stale.reload.amount.to_f, 0.001
    assert InvoicePayouts::MarginCheck.new(it.written_payout_build).breached?
  end

  # A lead with no base share is a candidate before the surplus pass, so the
  # write removes their payout first and the surplus they are owed brings the
  # same row back. The whole line goes to a salaried recipient's commission
  # (deducted, never paid), so the leads' base is 0 while surplus is priced on
  # the full 10,000: IC 100 hrs * $20, margin 0.80 - 0.43 = 3,700, 555 each.
  def surplus_only_tracker
    recipient_admin = AdminUser.create!(email: "comm-salaried-guard@example.com", password: "password123", password_confirmation: "password123")
    recipient = ForecastPerson.create!(forecast_id: 710_006, email: recipient_admin.email, data: {})
    recipient.ensure_contributor_exists!
    FullTimePeriod.create!(admin_user: recipient_admin, started_at: Date.new(2020, 1, 1), contributor_type: :five_day, expected_utilization: 0.8)
    PercentageCommission.create!(project_tracker: ProjectTracker.last, contributor: recipient.reload.contributor, rate: 1.0)
    @project.update!(notes: "#{@ic.email}:20p/h")
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    it.make_contributor_payouts!(@creator)
    assert_equal [555.0, 555.0, 2000.0], it.contributor_payouts.reload.map { |cp| cp.amount.to_f }.sort
    it
  end

  def assert_surplus_only_lead_keeps_their_payout(it)
    al_cp = it.contributor_payouts.reload.find { |cp| cp.contributor.forecast_person == @al }
    assert_equal [0.0], al_cp.blueprint["AccountLead"].map { |e| e["amount"] }
    al_cp.update_columns(accepted_at: Time.current)
    assert_includes InvoicePayouts::Build.new(it).orphan_candidates.map(&:id), al_cp.id

    it.make_contributor_payouts!(@creator)

    assert_equal [555.0, 555.0, 2000.0], it.contributor_payouts.reload.map { |cp| cp.amount.to_f }.sort
    rows = ContributorPayout.with_deleted.where(invoice_tracker: it, ledger_id: al_cp.ledger_id)
    assert_equal [al_cp.id], rows.map(&:id), "the same row, not a second one"
    assert_nil rows.first.deleted_at
    assert_equal 555.0, rows.first.amount.to_f
    assert_equal 1, rows.first.blueprint["AccountLeadSurplus"].length
    assert rows.first.accepted_at.present?, "an unchanged amount keeps its acceptance"
    assert_empty it.written_payout_build.retained_orphans
  end

  test "a lead paid through surplus alone has their payout removed and brought back" do
    assert_surplus_only_lead_keeps_their_payout(surplus_only_tracker)
  end

  test "a lead paid through surplus alone whose payout cannot be removed is rewritten in place" do
    it = surplus_only_tracker
    qbo_refuses_the_delete
    assert_surplus_only_lead_keeps_their_payout(it)
  end
end
