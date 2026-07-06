require "test_helper"

class Studios::Snapshots::UtilizationByMonthTest < ActiveSupport::TestCase
  setup do
    @studio = Studio.create!(name: "XXIX", mini_name: "xxix")
    @fp = ForecastPerson.create!(forecast_id: 9101, email: "a@x.com")
    @other_fp = ForecastPerson.create!(forecast_id: 9102, email: "b@x.com")
    StudioForecastPerson.create!(studio: @studio, forecast_person: @fp)
  end

  def report!(fp, month, gradation: :month, sellable: 100, billable_map: { "150.0" => 40.0 })
    ForecastPersonUtilizationReport.create!(
      forecast_person_id: fp.id,
      starts_at: month,
      ends_at: month.end_of_month,
      period_gradation: gradation,
      expected_hours_sold: sellable,
      expected_hours_unsold: 10,
      actual_hours_sold: 40,
      actual_hours_internal: 5,
      actual_hours_time_off: 8,
      actual_hours_sold_by_rate: billable_map,
      utilization_rate: 40.0
    )
  end

  test "returns per-month per-person maps for the studio's people only" do
    report!(@fp, Date.new(2024, 1, 1))
    report!(@other_fp, Date.new(2024, 1, 1)) # not in studio → excluded

    out = Studios::Snapshots::UtilizationByMonth.call(
      studio: @studio, from: Date.new(2024, 1, 1), through: Date.new(2024, 1, 31)
    )

    month = out[Date.new(2024, 1, 1)]
    assert_equal [@fp.id], month.keys.map(&:id)
    data = month[@fp]
    assert_equal 8, data[:time_off]
    assert_equal({ "150.0" => 40.0 }, data[:billable])
    assert_equal 5, data[:non_billable]
    assert_equal 10, data[:non_sellable]
    assert_equal 100, data[:sellable]
  end

  test "only monthly-gradation rows are read" do
    report!(@fp, Date.new(2024, 1, 1), gradation: :quarter)
    out = Studios::Snapshots::UtilizationByMonth.call(
      studio: @studio, from: Date.new(2024, 1, 1), through: Date.new(2024, 3, 31)
    )
    assert_equal({}, out)
  end

  test "spans multiple months" do
    report!(@fp, Date.new(2024, 1, 1))
    report!(@fp, Date.new(2024, 2, 1))
    out = Studios::Snapshots::UtilizationByMonth.call(
      studio: @studio, from: Date.new(2024, 1, 1), through: Date.new(2024, 2, 29)
    )
    assert_equal [Date.new(2024, 1, 1), Date.new(2024, 2, 1)], out.keys.sort
  end
end
