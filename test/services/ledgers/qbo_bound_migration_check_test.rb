require "test_helper"

class Ledgers::QboBoundMigrationCheckTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "MigCheck-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "mc#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
  end

  test "empty legacy ledger is ready (Δ = 0 trivially)" do
    result = Ledgers::QboBoundMigrationCheck.call(@ledger)
    assert result.ready?
    assert_in_delta 0, result.balance_delta, 0.001
    assert_in_delta 0, result.unsettled_delta, 0.001
  end

  test "result struct exposes the required fields" do
    r = Ledgers::QboBoundMigrationCheck.call(@ledger)
    assert_respond_to r, :current_balance
    assert_respond_to r, :proposed_balance
    assert_respond_to r, :balance_delta
    assert_respond_to r, :ready?
    assert_respond_to r, :blocking_bills
    assert_respond_to r, :ignored_negative_cas
  end

  test "ledger is blocked when ledger.balance under qbo_bound != legacy" do
    paid_qb = mock("qbo_bill"); paid_qb.stubs(:paid?).returns(true)
    cp = ContributorPayout.new(amount: 100)
    cp.stubs(:payable?).returns(true)
    cp.stubs(:qbo_bill).returns(paid_qb)
    cp.stubs(:signed_amount).returns(100)
    cp.stubs(:in_balance_under_qbo_bound?).returns(false)

    neg_ca = ContributorAdjustment.new(amount: -50)
    neg_ca.stubs(:signed_amount).returns(-50)

    @ledger.stubs(:visible_items).returns([cp, neg_ca])
    @ledger.stubs(:qbo_bound_visible_items).returns([cp])

    result = Ledgers::QboBoundMigrationCheck.call(@ledger)
    assert_in_delta -50, result.balance_delta, 0.01
    refute result.ready?
  end
end
