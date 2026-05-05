require "test_helper"

class PerHourCommissionTest < ActiveSupport::TestCase
  test "deduction_for_line is rate * blueprint quantity, rounded to 2 decimals" do
    c = PerHourCommission.new(rate: 15.0)
    deduction = c.deduction_for_line({ "amount" => 2808 }, { "quantity" => 12, "unit_price" => 234 })
    assert_in_delta 180.00, deduction, 0.001
  end

  test "deduction_for_line returns 0 when quantity is 0" do
    c = PerHourCommission.new(rate: 15.0)
    deduction = c.deduction_for_line({ "amount" => 0 }, { "quantity" => 0, "unit_price" => 0 })
    assert_equal 0, deduction
  end

  test "deduction_for_line ignores qbo amount edits" do
    # Per-hour commission is anchored to the blueprint quantity (the agreed hours).
    c = PerHourCommission.new(rate: 10.0)
    deduction = c.deduction_for_line({ "amount" => 999 }, { "quantity" => 8, "unit_price" => 200 })
    assert_in_delta 80.0, deduction, 0.001
  end

  test "description_line includes hrs, $/hr rate, and recipient" do
    contributor = mock("contributor")
    contributor.stubs(:display_name).returns("Acme Corp")
    c = PerHourCommission.new(rate: 15.0)
    c.stubs(:contributor).returns(contributor)
    line = c.description_line({ "amount" => 2808 }, { "quantity" => 12, "unit_price" => 234 }, 180.0)
    assert_includes line, "12"
    assert_includes line, "$15.00"
    assert_includes line, "$180.00"
    assert_includes line, "Acme Corp"
  end
end
