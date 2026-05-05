require "test_helper"

class PercentageCommissionTest < ActiveSupport::TestCase
  test "deduction_for_line is rate * line amount, rounded to 2 decimals" do
    c = PercentageCommission.new(rate: 0.15)
    qbo_line = { "amount" => 234.0 * 12 } # $2808
    deduction = c.deduction_for_line(qbo_line, { "quantity" => 12, "unit_price" => 234 })
    assert_in_delta 421.20, deduction, 0.001
  end

  test "deduction_for_line returns 0 when amount is 0" do
    c = PercentageCommission.new(rate: 0.15)
    deduction = c.deduction_for_line({ "amount" => 0 }, { "quantity" => 0, "unit_price" => 0 })
    assert_equal 0, deduction
  end

  test "deduction_for_line uses qbo line amount even when blueprint quantity differs" do
    # Reflects QBO-side edits to the line amount (e.g. partial discount).
    c = PercentageCommission.new(rate: 0.10)
    deduction = c.deduction_for_line({ "amount" => 1000 }, { "quantity" => 5, "unit_price" => 234 })
    assert_in_delta 100.0, deduction, 0.001
  end

  test "rate must be <= 1" do
    c = PercentageCommission.new(rate: 1.5)
    assert_not c.valid?
    assert_includes c.errors[:rate], "must be less than or equal to 1"
  end

  test "description_line includes hrs, rate, and recipient" do
    contributor = mock("contributor")
    contributor.stubs(:display_name).returns("Acme Corp")
    c = PercentageCommission.new(rate: 0.15)
    c.stubs(:contributor).returns(contributor)
    line = c.description_line({ "amount" => 2808 }, { "quantity" => 12, "unit_price" => 234 }, 421.20)
    assert_includes line, "12"
    assert_includes line, "$234.00"
    assert_includes line, "15.0%"
    assert_includes line, "$421.20"
    assert_includes line, "Acme Corp"
  end
end
