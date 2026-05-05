require "test_helper"

class ContributorPayoutTest < ActiveSupport::TestCase
  test "as_commission sums Commission blueprint entries" do
    cp = ContributorPayout.new(blueprint: {
      "Commission" => [
        { "amount" => 100.0 },
        { "amount" => 50.5 },
      ],
      "IndividualContributor" => [
        { "amount" => 200.0 },
      ],
    })
    assert_in_delta 150.5, cp.as_commission, 0.001
  end

  test "as_commission returns 0 when no Commission entries" do
    cp = ContributorPayout.new(blueprint: {
      "IndividualContributor" => [{ "amount" => 200.0 }],
    })
    assert_equal 0, cp.as_commission
  end

  test "as_commission returns 0 when blueprint is empty" do
    cp = ContributorPayout.new(blueprint: {})
    assert_equal 0, cp.as_commission
  end

  test "70% cap excludes commission entries from LHS sum and uses post-commission total as basis" do
    invoice_tracker = mock("invoice_tracker")
    forecast_client = mock("forecast_client")
    forecast_client.stubs(:is_internal?).returns(false)
    invoice_tracker.stubs(:forecast_client).returns(forecast_client)
    invoice_tracker.stubs(:total).returns(1000.0)
    invoice_tracker.stubs(:company_treasury_split).returns(BigDecimal("0.30"))

    # Pretend there is a $100 commission CP and a $620 IC CP already on the invoice.
    commission_cp = ContributorPayout.new(amount: 100.0, blueprint: { "Commission" => [{ "amount" => 100.0 }] })
    ic_cp = ContributorPayout.new(amount: 620.0, blueprint: { "IndividualContributor" => [{ "amount" => 620.0 }] })

    invoice_tracker.stubs(:contributor_payouts).returns([commission_cp, ic_cp])

    # post_commission_total = 1000 - 100 = 900; cap = 900 * 0.7 = 630
    # contributor_pool_sum = (100 - 100) + (620 - 0) = 620
    # 620 <= 630, so should be valid
    ic_cp.stubs(:invoice_tracker).returns(invoice_tracker)
    ic_cp.send(:contributor_payouts_within_seventy_percent)
    assert_empty ic_cp.errors[:base], "Expected the IC CP to be valid (under post-commission cap)"
  end

  test "70% cap rejects when contributor pool exceeds post-commission cap" do
    invoice_tracker = mock("invoice_tracker")
    forecast_client = mock("forecast_client")
    forecast_client.stubs(:is_internal?).returns(false)
    invoice_tracker.stubs(:forecast_client).returns(forecast_client)
    invoice_tracker.stubs(:total).returns(1000.0)
    invoice_tracker.stubs(:company_treasury_split).returns(BigDecimal("0.30"))

    commission_cp = ContributorPayout.new(amount: 100.0, blueprint: { "Commission" => [{ "amount" => 100.0 }] })
    # 700 from contributor pool; cap is 630 post-commission
    ic_cp = ContributorPayout.new(amount: 700.0, blueprint: { "IndividualContributor" => [{ "amount" => 700.0 }] })

    invoice_tracker.stubs(:contributor_payouts).returns([commission_cp, ic_cp])
    ic_cp.stubs(:invoice_tracker).returns(invoice_tracker)
    ic_cp.send(:contributor_payouts_within_seventy_percent)
    assert_not_empty ic_cp.errors[:base]
  end
end
