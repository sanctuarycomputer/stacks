require "test_helper"

class Stacks::SystemTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # Regression for the founder-trueup sync silently going no-op once the
  # calendar reached a month whose number repeats one inside the New Deal
  # range (June 2025 onward). The old `break if working_date.month ==
  # Date.today.month` compared month-of-year only, ignoring the year.
  test "founder_trueup_months covers every completed month since the New Deal, year-aware" do
    travel_to Date.new(2026, 7, 13) do
      months = Stacks::System.founder_trueup_months

      assert_equal Date.new(2025, 6, 1), months.first
      assert_equal Date.new(2026, 6, 1), months.last
      assert_includes months, Date.new(2026, 5, 1), "May 2026 must be synced"
      assert_includes months, Date.new(2026, 6, 1), "June 2026 must be synced"
    end
  end

  test "founder_trueup_months excludes the current, in-progress month" do
    travel_to Date.new(2026, 7, 13) do
      refute_includes Stacks::System.founder_trueup_months, Date.new(2026, 7, 1)
    end
  end

  # The month-number collision first bites in June 2026, where the buggy
  # loop broke on the very first iteration and processed nothing.
  test "founder_trueup_months does not truncate on a same-month-number collision" do
    travel_to Date.new(2026, 6, 13) do
      months = Stacks::System.founder_trueup_months
      assert_equal Date.new(2025, 6, 1), months.first
      assert_equal Date.new(2026, 5, 1), months.last
    end
  end
end
