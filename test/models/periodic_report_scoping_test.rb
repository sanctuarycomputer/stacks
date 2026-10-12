require "test_helper"

class PeriodicReportScopingTest < ActiveSupport::TestCase
  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "invoice_passes only includes the Sanctuary pass for the period" do
    month = Date.new(2092, 1, 1)
    sanctuary_pass = InvoicePass.create!(start_of_month: month,
                                         enterprise: enterprises(:sanctuary), data: {})
    InvoicePass.create!(start_of_month: month,
                        enterprise: enterprises(:garden3d), data: {})

    report = PeriodicReport.new(period_starts_at: month, period_gradation: :quarter)

    assert_equal [sanctuary_pass.id], report.invoice_passes.map(&:id)
  end

  test "surplus ignores other enterprises' trackers" do
    month = Date.new(2092, 4, 1)
    InvoicePass.create!(start_of_month: month,
                        enterprise: enterprises(:sanctuary), data: {})
    InvoicePass.create!(start_of_month: month,
                        enterprise: enterprises(:garden3d), data: {})

    report = PeriodicReport.new(period_starts_at: month, period_gradation: :quarter)

    assert_equal [], report.invoice_trackers
    assert_nil report.surplus
  end
end
