require "test_helper"

class ContributorPayoutCapValidationTest < ActiveSupport::TestCase
  include PayoutFixtures

  setup do
    setup_payout_people
    build_tracker("new_deal_v2")
    @it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    @it.make_contributor_payouts!(@creator) # IC 5400, AL 800, PL 500 = 6700 = the 67% cap
    @ic_cp = @it.contributor_payouts.reload.find { |cp| cp.contributor.forecast_person == @ic }
  end

  test "editing a persisted payout over the cap is rejected" do
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 9000.0
    assert_not cp.valid?
    assert_match(/may not exceed \$6,700\.00 \(67\.0% of post-commission invoice total\)/, cp.errors[:base].join)
  end

  test "an edit that stays within the cap is accepted" do
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 5400.5 # within the dollar of slack
    assert cp.valid?, cp.errors.full_messages.join(", ")
  end

  test "a new manual payout that pushes the invoice over is rejected" do
    stranger = ForecastPerson.create!(forecast_id: 710_009, email: "extra-guard@example.com", data: {})
    stranger.ensure_contributor_exists!
    ledger = Ledger.find_or_create_for(enterprise: @client.billing_enterprise, contributor: stranger.reload.contributor)
    cp = ContributorPayout.new(invoice_tracker: @it, ledger: ledger, amount: 50.0, blueprint: {}, created_by: @creator)
    assert_not cp.valid?
  end

  test "a v2 invoice is capped at 67%, not the old flat 70%" do
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 5600.0 # pool 6900: under 70%, over 67%
    assert_not cp.valid?
  end

  test "target_margin_override loosens the cap" do
    @it.update!(target_margin_override: 0.25)
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 6100.0 # pool 7400 <= 7500
    assert cp.valid?, cp.errors.full_messages.join(", ")
  end

  test "the admin override and acceptance-only saves still skip the check" do
    cp = ContributorPayout.find(@ic_cp.id)
    cp.amount = 9000.0
    cp.skip_seventy_percent_check = "1"
    assert cp.valid?

    @ic_cp.update_columns(amount: 9000.0)
    over = ContributorPayout.find(@ic_cp.id)
    over.accepted_at = Time.current
    assert over.valid?
  end
end
