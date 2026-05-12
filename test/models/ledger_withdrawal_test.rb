require "test_helper"

class LedgerWithdrawalTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    e = Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)
    fp = ForecastPerson.create!(forecast_id: 990_701, email: "lw@example.com", data: {})
    c = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: e, contributor: c)
  end

  test "signed_amount returns -amount (withdrawals deduct)" do
    w = LedgerWithdrawal.new(
      ledger: @ledger, amount: 500, effective_on: Date.today,
      withdrawal_method: :deel_contract, withdrawal_status: "pending"
    )
    assert_equal(-500, w.signed_amount)
  end

  test "payable? true when status is approved or paid" do
    w = LedgerWithdrawal.new(
      ledger: @ledger, amount: 1, effective_on: Date.today,
      withdrawal_method: :deel_contract, withdrawal_status: "pending"
    )
    assert_not w.payable?
    w.withdrawal_status = "approved"
    assert w.payable?
    w.withdrawal_status = "paid"
    assert w.payable?
    w.withdrawal_status = "rejected"
    assert_not w.payable?
  end

  test "enum withdrawal_method accepts :deel_contract" do
    w = LedgerWithdrawal.create!(
      ledger: @ledger, amount: 1, effective_on: Date.today,
      withdrawal_method: :deel_contract, withdrawal_status: "pending"
    )
    assert_equal "deel_contract", w.reload.withdrawal_method
  end

  test "contributor and enterprise delegate through ledger" do
    w = LedgerWithdrawal.create!(
      ledger: @ledger, amount: 1, effective_on: Date.today,
      withdrawal_method: :deel_contract, withdrawal_status: "pending"
    )
    assert_equal @ledger.contributor, w.contributor
    assert_equal @ledger.enterprise, w.enterprise
  end
end
