require "test_helper"

class StacksBillingModelTest < ActiveSupport::TestCase
  test "new_deal_v1 derives the legacy 57% ceiling and 43% threshold" do
    rules = Stacks::BillingModel.for("new_deal_v1")
    assert_equal BigDecimal("0.30"), rules.treasury_share
    assert_equal BigDecimal("0.08"), rules.account_lead_share
    assert_equal BigDecimal("0.05"), rules.project_lead_share
    assert_equal BigDecimal("0.15"), rules.surplus_lead_share
    assert_equal BigDecimal("0.57"), rules.ic_ceiling
    assert_equal BigDecimal("0.43"), rules.surplus_threshold
  end

  test "new_deal_v2 derives the 54% ceiling and 46% threshold" do
    rules = Stacks::BillingModel.for("new_deal_v2")
    assert_equal BigDecimal("0.33"), rules.treasury_share
    assert_equal BigDecimal("0.54"), rules.ic_ceiling
    assert_equal BigDecimal("0.46"), rules.surplus_threshold
  end

  test "ic_share subtracts only the leads that are present" do
    rules = Stacks::BillingModel.for("new_deal_v2")
    assert_equal BigDecimal("0.54"), rules.ic_share(account_lead: true, project_lead: true)
    assert_equal BigDecimal("0.62"), rules.ic_share(account_lead: false, project_lead: true)
    assert_equal BigDecimal("0.59"), rules.ic_share(account_lead: true, project_lead: false)
    assert_equal BigDecimal("0.67"), rules.ic_share(account_lead: false, project_lead: false)
  end

  test "surplus_for is zero when the IC is paid exactly the model's ceiling" do
    rules = Stacks::BillingModel.for("new_deal_v1")
    assert_equal 0.0, rules.surplus_for(working_amount: 1000.0, ic_amount: 570.0)
  end

  test "surplus_for returns the margin above the threshold as a Float" do
    surplus = Stacks::BillingModel.for("new_deal_v2").surplus_for(working_amount: 1000.0, ic_amount: 400.0)
    assert_in_delta 140.0, surplus, 0.001   # (0.60 - 0.46) * 1000
    assert_kind_of Float, surplus, "surplus lands in a jsonb blueprint; a BigDecimal would serialize as a string"
  end

  test "surplus_for is zero when either amount is not positive" do
    rules = Stacks::BillingModel.for("new_deal_v2")
    assert_equal 0.0, rules.surplus_for(working_amount: 0.0, ic_amount: 400.0)
    assert_equal 0.0, rules.surplus_for(working_amount: -100.0, ic_amount: 400.0)
    assert_equal 0.0, rules.surplus_for(working_amount: 1000.0, ic_amount: 0.0)
  end

  test "for raises on an unknown model" do
    assert_raises(ArgumentError) { Stacks::BillingModel.for("old_deal") }
    assert_raises(ArgumentError) { Stacks::BillingModel.for(nil) }
  end

  test "DEFAULT is new_deal_v1 and names lists both models in order" do
    assert_equal "new_deal_v1", Stacks::BillingModel::DEFAULT
    assert_equal %w[new_deal_v1 new_deal_v2], Stacks::BillingModel.names
  end

  test "label is human readable" do
    assert_equal "new_deal_v2 — 33% treasury, 54% IC ceiling", Stacks::BillingModel.for("new_deal_v2").label
  end

  test "registry is frozen" do
    assert Stacks::BillingModel::ALL.frozen?
    assert Stacks::BillingModel.for("new_deal_v1").frozen?
  end
end
