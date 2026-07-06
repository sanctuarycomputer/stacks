require "test_helper"

class Studios::Snapshots::OkrRowsTest < ActiveSupport::TestCase
  setup do
    @studio = Studio.create!(name: "XXIX", mini_name: "xxix")
    @okr = Okr.create!(name: "Profit Margin", datapoint: "profit_margin", operator: "greater_than")
    @okr_period = OkrPeriod.create!(
      okr: @okr,
      starts_at: Date.new(2024, 1, 1),
      ends_at: Date.new(2024, 12, 31),
      target: 20,
      tolerance: 5
    )
    OkrPeriodStudio.create!(okr_period: @okr_period, studio: @studio)
    @period = Stacks::Period.new("January, 2024", Date.new(2024, 1, 1), Date.new(2024, 1, 31), :month)
    @datapoints = {
      profit_margin: { value: 30.0, unit: :percentage },
      income: { value: 1000.0, unit: :usd },
      net_operating_income: { value: 300.0, unit: :usd },
    }
  end

  test "returns health-annotated okr rows and synthesized Profit rows" do
    okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio } }).all
    out = Studios::Snapshots::OkrRows.call(
      studio: @studio, period: @period, datapoints: @datapoints, okrs: okrs
    )

    assert out.key?("Profit Margin")
    assert_equal 30.0, out["Profit Margin"][:value]
    assert out["Profit Margin"][:health].present?
    # profit_margin OKRs synthesize Profit / Surplus Profit rows
    assert out.key?("Profit")
    assert_equal 300.0, out["Profit"][:value]
    assert_equal 200.0, out["Profit"][:target] # 1000 * (20/100)
  end

  test "Studio#okrs_for_period delegates to the service (legacy path parity)" do
    okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio } }).all
    legacy = @studio.okrs_for_period(@period, @datapoints, okrs)
    extracted = Studios::Snapshots::OkrRows.call(
      studio: @studio, period: @period, datapoints: @datapoints, okrs: okrs
    )
    assert_equal extracted, legacy
  end

  test "studio without matching okr periods gets raw datapoint row" do
    other = Studio.create!(name: "Other", mini_name: "oth")
    okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio } }).all
    out = Studios::Snapshots::OkrRows.call(
      studio: other, period: @period, datapoints: @datapoints, okrs: okrs
    )
    assert_equal({}, out)
  end
end
