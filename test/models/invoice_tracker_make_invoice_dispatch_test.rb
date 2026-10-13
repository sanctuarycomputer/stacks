require "test_helper"

class InvoiceTrackerMakeInvoiceDispatchTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2094, 5, 1))
    @payer = make_payer("Dispatch Payer #{SecureRandom.hex(3)}", customer_id: "2")
    @tracker = fee_tracker(@pass, @payer)
  end

  def teardown
    clear_enterprise_memos
  end

  test "a management fee invoice tracker is pushed as a management fee draft" do
    Mso::IntercompanyInvoices.expects(:push_invoice!).once
      .with(invoice_tracker: @tracker).returns(:pushed)
    @tracker.expects(:configuration_errors).never
    @tracker.expects(:assignments).never

    assert_equal :pushed, @tracker.make_invoice!
  end

  test "a misconfigured management fee invoice tracker raises instead of silently doing nothing" do
    stub_garden3d_qbo(items: [qbo_item("1", "Services")], customers: [qbo_customer("2", "Payer")])

    assert_raises(Mso::IntercompanyInvoices::Misconfigured) { @tracker.make_invoice! }
  end

  test "a legacy garden3d tracker stays on the Forecast path" do
    @tracker.update!(blueprint: { "lines" => {} })
    Mso::IntercompanyInvoices.expects(:push_invoice!).never
    @tracker.stubs(:configuration_errors).returns([[:missing_qbo_customer]])

    assert_nil @tracker.make_invoice!, "the Forecast path's first guard, as today"
  end

  test "a tracker on a pass that is neither Sanctuary's nor garden3d's raises" do
    other_qa = QboAccount.create!(enterprise: enterprises(:one), realm_id: "one-#{SecureRandom.hex(4)}",
                                  client_id: "x", client_secret: "y")
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 5, 1), enterprise: enterprises(:one), data: {})
    client = ForecastClient.create!(forecast_id: 970_001, name: "External Co")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id, qbo_account: other_qa)
    Mso::IntercompanyInvoices.expects(:push_invoice!).never
    tracker.expects(:configuration_errors).never

    error = assert_raises(RuntimeError) { tracker.make_invoice! }

    assert_match(/makes no invoices through Stacks/, error.message)
  end
end
