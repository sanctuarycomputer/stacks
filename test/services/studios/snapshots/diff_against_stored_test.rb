require "test_helper"

class Studios::Snapshots::DiffAgainstStoredTest < ActiveSupport::TestCase
  setup do
    Studio.instance_variable_set(:@all_studios, nil)
    @studio = Studio.create!(name: "XXIX", mini_name: "xxix", accounting_prefix: "XXIX")
  end

  def stored_row(label:, income:)
    {
      "label" => label,
      "period_starts_at" => "01/01/2024",
      "period_ends_at" => "01/31/2024",
      "cash" => { "datapoints" => { "income" => { "value" => income, "unit" => "usd" } }, "okrs" => {} },
      "accrual" => { "datapoints" => {} , "okrs" => {} },
      "utilization" => {}
    }
  end

  def live_row(label:, income:)
    {
      label: label,
      period_starts_at: "01/01/2024",
      period_ends_at: "01/31/2024",
      cash: { datapoints: { income: { value: income, unit: :usd } }, okrs: {} },
      accrual: { datapoints: {}, okrs: {} },
      utilization: {}
    }
  end

  test "matching rows produce zero mismatches" do
    @studio.update!(snapshot: { "month" => [stored_row(label: "January, 2024", income: 100.0)] })
    Studios::Snapshots::GradationRows.stubs(:call).returns([live_row(label: "January, 2024", income: 100.004)])

    result = Studios::Snapshots::DiffAgainstStored.call(studio: @studio, gradations: ["month"])
    assert_equal 1, result.checked
    assert_equal [], result.mismatches
  end

  test "value drift beyond tolerance is reported" do
    @studio.update!(snapshot: { "month" => [stored_row(label: "January, 2024", income: 100.0)] })
    Studios::Snapshots::GradationRows.stubs(:call).returns([live_row(label: "January, 2024", income: 150.0)])

    result = Studios::Snapshots::DiffAgainstStored.call(studio: @studio, gradations: ["month"])
    assert_equal 1, result.mismatches.length
    assert_match(/month\/January, 2024\/cash\/income/, result.mismatches.first)
  end

  test "stored nil matches live NaN and Infinity (JSON encoding parity)" do
    @studio.update!(snapshot: { "month" => [stored_row(label: "January, 2024", income: nil)] })
    Studios::Snapshots::GradationRows.stubs(:call).returns([live_row(label: "January, 2024", income: Float::NAN)])

    result = Studios::Snapshots::DiffAgainstStored.call(studio: @studio, gradations: ["month"])
    assert_equal [], result.mismatches
  end

  test "missing live row is a mismatch" do
    @studio.update!(snapshot: { "month" => [stored_row(label: "January, 2024", income: 1.0)] })
    Studios::Snapshots::GradationRows.stubs(:call).returns([])

    result = Studios::Snapshots::DiffAgainstStored.call(studio: @studio, gradations: ["month"])
    assert_match(/no live row/, result.mismatches.first)
  end
end
