require "test_helper"

class InvoicePayoutsMarginCheckTest < ActiveSupport::TestCase
  include PayoutFixtures

  setup { setup_payout_people }

  def check_for(lines, **opts)
    InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(build_invoice_tracker(lines, **opts)))
  end

  test "an ordinary invoice sits exactly on its cap and is not breached" do
    build_tracker("new_deal_v2")
    check = check_for([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    assert_in_delta 6700.0, check.pool, 0.01
    assert_in_delta 6700.0, check.cap, 0.01
    assert_not check.breached?
    assert_in_delta 67.0, check.cap_percentage, 0.01
  end

  # A cheap line creates headroom AND surplus; the surplus spends headroom the
  # expensive line was relying on. Pre-surplus the pool is 13,600 (under).
  test "lead surplus on a cheap line counts toward a breach caused by an expensive one" do
    build_tracker("new_deal_v1")
    @project.update!(notes: "#{@ic.email}:20p/h, #{@ic2.email}:90p/h")
    check = check_for([
      { id: "1", person: @ic, hours: 100.0, rate: 100.0 },
      { id: "2", person: @ic2, hours: 100.0, rate: 100.0 },
    ])

    assert_in_delta 14_710.0, check.pool, 0.01
    assert_in_delta 14_000.0, check.cap, 0.01
    assert check.breached?
    assert_in_delta 710.0, check.over_by, 0.01
    assert_in_delta 73.6, check.payout_percentage, 0.01
    assert_in_delta 70.0, check.cap_percentage, 0.01

    cheap, expensive = check.rows
    assert_in_delta 4410.0, cheap.payouts, 0.01     # 2000 + 800 + 500 + 2 * 555
    assert_not cheap.over?
    assert_in_delta 10_300.0, expensive.payouts, 0.01
    assert_in_delta 7000.0, expensive.allowed, 0.01
    assert_in_delta 3300.0, expensive.over, 0.01
    assert expensive.over?
    assert_in_delta 103.0, expensive.payout_percentage, 0.01
    assert_in_delta(-3.0, expensive.margin_percentage, 0.01)
    assert expensive.entries.find { |e| e.role == "IndividualContributor" }.rate_override
    assert_in_delta 0.0, check.other_billed, 0.01
    assert_in_delta 0.0, check.other_allowed, 0.01
  end

  test "payees who are not paid out are left out of the pool" do
    build_tracker("new_deal_v1")
    FullTimePeriod.create!(admin_user: @al_admin, started_at: Date.new(2020, 1, 1), contributor_type: :five_day, expected_utilization: 0.8)
    check = check_for([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    assert_in_delta 6200.0, check.pool, 0.01 # 5700 IC + 500 PL; the AL's 800 is salaried
    assert_in_delta 6200.0, check.rows.first.payouts, 0.01
    assert_equal 3, check.rows.first.entries.length, "unpaid entries are still listed"
  end

  test "commissions are outside the pool and come off the cap's basis" do
    pt = build_tracker("new_deal_v2")
    recipient = ForecastPerson.create!(forecast_id: 710_004, email: "comm-guard@example.com", data: {})
    recipient.ensure_contributor_exists!
    PercentageCommission.create!(project_tracker: pt, contributor: recipient.reload.contributor, rate: 0.10)
    check = check_for([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    assert_in_delta 9000.0, check.post_commission_total, 0.01
    assert_in_delta 6030.0, check.cap, 0.01
    assert_in_delta 6030.0, check.pool, 0.01
    assert_in_delta 1000.0, check.rows.first.commissions, 0.01
    assert_not check.breached?
  end

  test "the unmapped remainder reconciles the rows to the cap" do
    build_tracker("new_deal_v2")
    check = check_for([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }], total: 12_000.0)
    assert_in_delta 2000.0, check.other_billed, 0.01
    assert_in_delta 1400.0, check.other_allowed, 0.01
    assert_in_delta check.cap, check.rows.sum(&:allowed) + check.other_allowed, 0.01
  end

  test "a payout that cannot be removed stays in the pool" do
    build_tracker("new_deal_v1")
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    stranger = ForecastPerson.create!(forecast_id: 710_009, email: "gone-guard@example.com", data: {})
    stranger.ensure_contributor_exists!
    ledger = Ledger.find_or_create_for(enterprise: @client.billing_enterprise, contributor: stranger.reload.contributor)
    paid = ContributorPayout.new(invoice_tracker: it, ledger: ledger, amount: 3000.0, blueprint: {}, created_by: @creator)
    paid.skip_seventy_percent_check = true
    paid.save!
    bill = mock("qbo_bill")
    bill.stubs(:has_payments?).returns(true)
    ContributorPayout.any_instance.stubs(:qbo_bill).returns(bill)

    check = InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(it.reload))
    assert_in_delta 3000.0, check.retained_total, 0.01
    assert_in_delta 10_000.0, check.pool, 0.01
    assert check.breached?
  end

  test "the surplus invariant: a lone line with surplus never exceeds its own cap" do
    Stacks::BillingModel::ALL.each_value do |rules|
      assert rules.surplus_lead_share * 2 < 1, "#{rules.name}: lead surplus shares must leave some surplus for the company"
    end
  end

  test "the pool the check predicts is the pool generation saves" do
    build_tracker("new_deal_v1")
    @project.update!(notes: "#{@ic.email}:20p/h, #{@ic2.email}:90p/h")
    it = build_invoice_tracker([
      { id: "1", person: @ic, hours: 100.0, rate: 100.0 },
      { id: "2", person: @ic2, hours: 100.0, rate: 100.0 },
    ])
    predicted = InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(it)).pool
    it.make_contributor_payouts!(@creator)
    saved = it.contributor_payouts.reload.sum { |cp| cp.amount.to_f - cp.as_commission }
    assert_in_delta predicted, saved, 0.01
    assert_in_delta it.surplus, 3700.0, 0.01, "the saved-state surplus view still agrees"
  end
end
