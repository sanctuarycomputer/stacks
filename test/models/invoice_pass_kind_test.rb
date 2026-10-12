require "test_helper"

class InvoicePassKindTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def teardown
    clear_enterprise_memos
  end

  def pass_for(enterprise, month)
    InvoicePass.create!(start_of_month: month, enterprise: enterprise, data: {})
  end

  test "Sanctuary's pass is Forecast invoicing" do
    pass = pass_for(enterprises(:sanctuary), Date.new(2097, 1, 1))

    assert_equal :forecast, pass.invoicing_kind
    assert pass.forecast?
    refute pass.management_fee?
  end

  test "garden3d's pass is management fee invoicing" do
    pass = garden3d_pass(Date.new(2097, 2, 1))

    assert_equal :management_fee, pass.invoicing_kind
    assert pass.management_fee?
    refute pass.forecast?
  end

  test "any other enterprise's pass raises instead of defaulting to one kind" do
    pass = pass_for(enterprises(:one), Date.new(2097, 3, 1))

    error = assert_raises(InvoicePass::UnsupportedIssuer) { pass.invoicing_kind }

    assert_match(/One LLC/, error.message)
    refute pass.forecast?
    refute pass.management_fee?
  end

  test "a Sanctuary pass never looks garden3d up" do
    pass = pass_for(enterprises(:sanctuary), Date.new(2097, 4, 1))
    Enterprise.expects(:garden3d).never

    refute pass.management_fee?
    assert_equal :forecast, pass.invoicing_kind
  end

  test "a tracker on garden3d's pass is a management fee tracker" do
    tracker = InvoiceTracker.new(invoice_pass: garden3d_pass(Date.new(2097, 5, 1)))

    assert tracker.management_fee?
  end

  test "a tracker on Sanctuary's pass is not" do
    tracker = InvoiceTracker.new(invoice_pass: pass_for(enterprises(:sanctuary), Date.new(2097, 6, 1)))

    refute tracker.management_fee?
  end

  test "a tracker with no pass is not" do
    refute InvoiceTracker.new.management_fee?
    refute InvoiceTracker.new.management_fee_invoice?
  end

  test "a management fee invoice tracker is one on garden3d's pass with no blueprint" do
    pass = garden3d_pass(Date.new(2097, 7, 1))

    assert InvoiceTracker.new(invoice_pass: pass).management_fee_invoice?
    legacy = InvoiceTracker.new(invoice_pass: pass, blueprint: { "lines" => {} })
    assert legacy.management_fee?, "the pass is still garden3d's"
    refute legacy.management_fee_invoice?, "but a blueprint marks a legacy Forecast tracker"
    refute InvoiceTracker.new(invoice_pass: pass_for(enterprises(:sanctuary), Date.new(2097, 7, 1)))
      .management_fee_invoice?
  end

  test "a pass knows whether it holds a legacy Forecast tracker" do
    garden3d_qbo_account
    pass = garden3d_pass(Date.new(2097, 8, 1))
    payer = make_payer("Legacy Check #{SecureRandom.hex(3)}")
    tracker = fee_tracker(pass, payer)

    refute pass.legacy_forecast_trackers?

    tracker.update!(blueprint: { "lines" => {} })
    assert pass.legacy_forecast_trackers?
  end
end
