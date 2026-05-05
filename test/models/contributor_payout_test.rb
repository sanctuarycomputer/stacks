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
end
