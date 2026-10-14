require "test_helper"

class PeopleCostAccountsMsoTest < ActiveSupport::TestCase
  def excluded?(*labels)
    Stacks::PeopleCostAccounts.excluded?(*labels)
  end

  test "an account named for compensation, the MSO or executives is a people cost" do
    ["6200 MSO Compensation", "Executive Compensation", "[NYC] 6210 Executive Team", "MSO", "6200 Compensation - MSO",
     "Deferred compensation"].each { |label| assert excluded?(label), label }
    assert excluded?("6210 Principals", "6200 MSO"), "a parent header hides its children"
    assert excluded?("Anything", "Executive Compensation")
  end

  test "ordinary spend accounts are still shown" do
    ["6100 Platform Infrastructure", "Software and Subscriptions", "Rent Expense", "Marketing and Advertising",
     "Compost Service", "Msolutions Hosting", "Cosmos DB", "Carbon Offset Contributions"].each do |label|
      refute excluded?(label), label
    end
  end

  test "the outlook's spend by category leaves an MSO compensation account out" do
    rows = [
      ["Expenses", nil],
      ["6100 Platform Infrastructure", "500.0"],
      ["6200 MSO Compensation", "59946.87"],
      ["Total Expenses", "60446.87"],
    ]
    seen = {}

    # allocate: each_spend_row reads only its argument and two constants.
    Stacks::FinancialOutlook.allocate.each_spend_row(rows) { |category, value| seen[category] = value }

    assert_equal({ "Platform Infrastructure" => 500.0 }, seen)
  end
end
