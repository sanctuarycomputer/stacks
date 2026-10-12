require "test_helper"

class Mso::CompensationTest < ActiveSupport::TestCase
  def line(key, multiplier, earned = "0")
    Mso::Compensation::Line.new(
      key: key,
      multiplier: BigDecimal(multiplier),
      already_earned: BigDecimal(earned),
    )
  end

  def compute(benchmark:, lines:, fee_income:, cap_percentage: "0.55")
    Mso::Compensation.call(
      benchmark_average: BigDecimal(benchmark),
      lines: lines,
      fee_income: BigDecimal(fee_income),
      cap_percentage: BigDecimal(cap_percentage),
    )
  end

  def roster(chief_earned = "0", svp_earned = "0", head_earned = "0")
    [line(:chief, "1.00", chief_earned), line(:svp, "0.85", svp_earned), line(:head, "0.70", head_earned)]
  end

  def sum_of_finals(result)
    result.outputs.sum(BigDecimal("0"), &:final)
  end

  # --- the formula -----------------------------------------------------------

  test "calculated is the benchmark times the multiplier" do
    result = compute(benchmark: "25000", lines: roster, fee_income: "200000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("25000"), by_key[:chief].calculated
    assert_equal BigDecimal("21250"), by_key[:svp].calculated
    assert_equal BigDecimal("17500"), by_key[:head].calculated
  end

  test "the cap is cap_percentage, a fraction, times fee income" do
    result = compute(benchmark: "1000", lines: [line(:chief, "1.00")], fee_income: "140000")
    assert_equal BigDecimal("77000"), result.cap
  end

  test "the default cap percentage is 55%" do
    result = Mso::Compensation.call(benchmark_average: BigDecimal("1000"), lines: [line(:chief, "1.00")],
                                    fee_income: BigDecimal("100000"))
    assert_equal BigDecimal("55000"), result.cap
  end

  test "under the cap there is no reduction and final equals calculated" do
    result = compute(benchmark: "25000", lines: roster, fee_income: "200000")

    assert_equal BigDecimal("110000"), result.cap
    result.outputs.each do |output|
      assert_equal output.calculated, output.final
      assert_equal BigDecimal("0"), output.reduction
    end
  end

  test "the true-up is the final less what the executive already earned" do
    result = compute(benchmark: "20000", lines: [line(:chief, "1.00", "5620")], fee_income: "200000")

    output = result.outputs.first
    assert_equal BigDecimal("20000"), output.final
    assert_equal BigDecimal("14380"), output.trueup
  end

  test "the true-up floors at zero when earnings exceed the final" do
    result = compute(benchmark: "20000", lines: [line(:chief, "1.00", "32606")], fee_income: "200000")

    assert_equal BigDecimal("20000"), result.outputs.first.final
    assert_equal BigDecimal("0"), result.outputs.first.trueup
  end

  test "totals are reported" do
    result = compute(benchmark: "20000",
                     lines: [line(:chief, "1.00", "5000"), line(:svp, "0.85")], fee_income: "200000")

    assert_equal BigDecimal("37000"), result.total_calculated
    assert_equal BigDecimal("32000"), result.total_trueup
  end

  # --- the cap ---------------------------------------------------------------

  test "over the cap, finals are reduced pro rata and sum to exactly the cap" do
    # total calculated 66,153.6045 against a cap of 49,500
    result = compute(benchmark: "25942.59", lines: roster, fee_income: "90000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("49500"), result.cap
    assert_equal BigDecimal("19411.76"), by_key[:chief].final
    assert_equal BigDecimal("16500.00"), by_key[:svp].final
    assert_equal BigDecimal("13588.24"), by_key[:head].final
    assert_equal BigDecimal("49500"), sum_of_finals(result)
  end

  test "reduction is what the cap took off" do
    result = compute(benchmark: "25942.59", lines: roster, fee_income: "90000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("6530.83"), by_key[:chief].reduction
    result.outputs.each do |output|
      assert_equal output.calculated - output.final, output.reduction
      assert_operator output.reduction, :>, BigDecimal("0")
    end
  end

  test "unused cap is NOT redistributed when a true-up floors at zero" do
    # The chief already out-earned their reduced final, so their true-up is
    # zero. That room must not flow to the others: the cap is a ceiling, not a
    # budget, and what is not paid stays with garden3d.
    result = compute(benchmark: "25942.59", lines: roster("32606", "12047.50", "9000"), fee_income: "90000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("0"), by_key[:chief].trueup
    assert_equal BigDecimal("16500.00"), by_key[:svp].final
    assert_equal BigDecimal("13588.24"), by_key[:head].final
    assert_equal BigDecimal("4452.50"), by_key[:svp].trueup
    assert_equal BigDecimal("4588.24"), by_key[:head].trueup
    assert_equal BigDecimal("9040.74"), result.total_trueup
  end

  # --- rounding --------------------------------------------------------------

  test "finals are exact cents" do
    result = compute(benchmark: "25942.59", lines: roster, fee_income: "90000")

    result.outputs.each do |output|
      assert_equal output.final.round(2), output.final, "#{output.key} is not whole cents"
    end
  end

  test "a cap with a fraction of a cent is never exceeded" do
    # 55% of 90,000.01 is 49,500.0055. Finals must total 49,500.00, not .01.
    result = compute(benchmark: "25942.59", lines: roster, fee_income: "90000.01")

    assert_equal BigDecimal("49500.0055"), result.cap
    assert_operator sum_of_finals(result), :<=, result.cap
    assert_equal BigDecimal("49500.00"), sum_of_finals(result)
  end

  test "under the cap, each line is rounded on its own" do
    # 25,000.004 and 21,250.0034 each round down; together they would round up.
    result = compute(benchmark: "25000.004", lines: [line(:chief, "1.00"), line(:svp, "0.85")],
                     fee_income: "1000000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("25000.00"), by_key[:chief].final
    assert_equal BigDecimal("21250.00"), by_key[:svp].final
  end

  test "rounding cannot lift the total above a cap the unrounded total just met" do
    # Two lines of 10,000.005 total exactly the cap of 20,000.01. Rounding each
    # up would pay 20,000.02.
    result = compute(benchmark: "10000.005", lines: [line(:a, "1.00"), line(:b, "1.00")],
                     fee_income: "20000.01", cap_percentage: "1")

    assert_equal result.cap, result.total_calculated
    assert_equal BigDecimal("20000.01"), sum_of_finals(result)
    assert_equal [BigDecimal("10000.01"), BigDecimal("10000.00")], result.outputs.map(&:final)
  end

  test "the odd cent goes to the largest remainder, not the largest line" do
    # 100 split 1.00 : 0.70 is 58.8235 / 41.1765. The smaller line has the
    # bigger remainder, so it gets the cent.
    result = compute(benchmark: "1000", lines: [line(:chief, "1.00"), line(:head, "0.70")],
                     fee_income: "100", cap_percentage: "1")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("58.82"), by_key[:chief].final
    assert_equal BigDecimal("41.18"), by_key[:head].final
  end

  # --- boundaries ------------------------------------------------------------

  test "zero fee income means a zero cap and no true-ups" do
    result = compute(benchmark: "25000", lines: roster, fee_income: "0")

    assert_equal BigDecimal("0"), result.cap
    assert_equal BigDecimal("0"), result.total_trueup
    result.outputs.each { |output| assert_equal BigDecimal("0"), output.final }
  end

  test "an empty roster returns an empty result" do
    result = compute(benchmark: "25000", lines: [], fee_income: "140000")

    assert_equal [], result.outputs
    assert_equal BigDecimal("0"), result.total_calculated
    assert_equal BigDecimal("0"), result.total_trueup
  end

  test "a zero benchmark yields all zeros" do
    result = compute(benchmark: "0", lines: roster, fee_income: "140000")

    result.outputs.each do |output|
      assert_equal BigDecimal("0"), output.calculated
      assert_equal BigDecimal("0"), output.final
      assert_equal BigDecimal("0"), output.trueup
    end
  end

  test "duplicate line keys are rejected" do
    error = assert_raises(ArgumentError) do
      compute(benchmark: "1000", lines: [line(:a, "1.00"), line(:a, "0.70")], fee_income: "1000")
    end
    assert_match(/duplicate line keys/, error.message)
  end

  test "integer keys work, as the true-up subsystem will pass record ids" do
    result = compute(benchmark: "1000", lines: [line(7, "1.00"), line(12, "0.70")], fee_income: "100000")
    assert_equal [7, 12], result.outputs.map(&:key)
  end

  # --- purity ----------------------------------------------------------------

  test "every amount is a BigDecimal" do
    result = compute(benchmark: "25942.59", lines: [line(:chief, "1.00", "1000")], fee_income: "90000")

    output = result.outputs.first
    [output.calculated, output.final, output.reduction, output.trueup,
     result.cap, result.total_calculated, result.total_trueup].each do |value|
      assert_kind_of BigDecimal, value
    end
  end

  test "the same inputs always give the same outputs, with no database access" do
    queries = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*| queries += 1 }

    first = compute(benchmark: "25942.59", lines: roster("100"), fee_income: "90000")
    second = compute(benchmark: "25942.59", lines: roster("100"), fee_income: "90000")

    assert_equal first.outputs.map(&:to_a), second.outputs.map(&:to_a)
    assert_equal 0, queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "the calculator's source reaches for no clock, model or framework" do
    source = File.read(Rails.root.join("app/services/mso/compensation.rb")).gsub(/^\s*#.*$/, "")
    refute_match(/\bDate\b|\bTime\b|ActiveRecord|Rails\.|\.where\(|\.find/, source)
  end
end
