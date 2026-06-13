require "test_helper"

class Ledgers::QboBoundMigrationCheckTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @qa = QboAccount.create!(client_id: "mc#{SecureRandom.hex(2)}", client_secret: "s", realm_id: "r#{SecureRandom.hex(2)}", enterprise: nil) rescue nil
    @enterprise = Enterprise.create!(name: "MigCheck-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "mc#{SecureRandom.hex(2)}", client_secret: "s", realm_id: "r#{SecureRandom.hex(2)}")
    @qbo_vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "v#{SecureRandom.hex(2)}", data: { "balance" => "0.0", "display_name" => "Test" })
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "mc#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    ContributorQboVendor.create!(contributor: @contributor, qbo_account: @qa, qbo_vendor: @qbo_vendor)
  end

  test "empty legacy ledger with QBO vendor at $0 is ready" do
    result = Ledgers::QboBoundMigrationCheck.call(@ledger)
    assert result.ready?
    assert result.qbo_match?
    refute result.qbo_vendor_missing?
    assert_in_delta 0, result.qbo_diff, 0.001
  end

  test "result struct exposes the required fields" do
    r = Ledgers::QboBoundMigrationCheck.call(@ledger)
    assert_respond_to r, :current_balance
    assert_respond_to r, :proposed_balance
    assert_respond_to r, :balance_delta
    assert_respond_to r, :ready?
    assert_respond_to r, :removed_neg_cas
    assert_respond_to r, :removed_dias
    assert_respond_to r, :dropped_paid_hosts
    assert_respond_to r, :open_qbo_bills
    assert_respond_to r, :stacks_open_total
    assert_respond_to r, :qbo_vendor_balance
    assert_respond_to r, :qbo_diff
    assert_respond_to r, :qbo_match?
    assert_respond_to r, :qbo_vendor_missing?
  end

  test "blocked when Stacks open total does not match QBO vendor balance" do
    @qbo_vendor.update!(data: { "balance" => "999.0", "display_name" => "Test" })
    result = Ledgers::QboBoundMigrationCheck.call(@ledger)
    refute result.ready?
    refute result.qbo_match?
    assert_in_delta(-999, result.qbo_diff, 0.01)
  end

  test "blocked when contributor has no QBO vendor mapping" do
    ContributorQboVendor.where(contributor: @contributor).destroy_all
    result = Ledgers::QboBoundMigrationCheck.call(@ledger)
    refute result.ready?
    assert result.qbo_vendor_missing?
  end

  test "Δ between legacy and qbo_bound is surfaced as diagnostic info" do
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
    assert_in_delta(-50, result.balance_delta, 0.01)
  end
end
