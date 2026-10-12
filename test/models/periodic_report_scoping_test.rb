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
    garden3d_pass = InvoicePass.create!(start_of_month: month,
                                        enterprise: enterprises(:garden3d), data: {})

    garden3d_qa = QboAccount.create!(enterprise: enterprises(:garden3d), realm_id: "g-realm",
                                     client_id: "x", client_secret: "y")
    garden3d_client = ForecastClient.create!(forecast_id: 920_001, name: "garden3d Co")
    InvoiceTracker.create!(invoice_pass: garden3d_pass, qbo_account: garden3d_qa,
                           forecast_client: garden3d_client)

    report = PeriodicReport.new(period_starts_at: month, period_gradation: :quarter)

    # Unscoped, invoice_passes would also pull in garden3d's pass and its
    # tracker above -- this assertion only discriminates because that
    # tracker now exists.
    assert_equal [], report.invoice_trackers
    assert_nil report.surplus
  end
end
