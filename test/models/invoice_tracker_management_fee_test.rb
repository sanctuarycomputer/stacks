require "test_helper"

class InvoiceTrackerManagementFeeTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    garden3d_qbo_account
    @payer = make_payer("Fee Payer #{SecureRandom.hex(3)}")
    @pass = garden3d_pass(Date.new(2096, 1, 1))
    @tracker = fee_tracker(@pass, @payer)
    # Any live sync would be a QuickBooks call.
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    clear_enterprise_memos
  end

  test "a tracker with no invoice is not made" do
    assert_equal :not_made, @tracker.status
  end

  test "an unsent draft reads as not sent, not impossible" do
    tracker = attach_invoice(@tracker, qbo_id: "fee-1", total: "0.0", balance: "0.0", sent: false)

    assert_nil tracker.blueprint
    assert_equal :not_sent, tracker.status
  end

  test "a sent, unpaid invoice reads as unpaid" do
    tracker = attach_invoice(@tracker, qbo_id: "fee-2", total: "130000.0", balance: "130000.0", sent: true)

    assert_equal :unpaid, tracker.status
  end

  test "a Sanctuary tracker with an invoice and no blueprint is still impossible" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2096, 2, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 940_001, name: "External Co")
    QboInvoice.create!(qbo_account: sanctuary_qa, qbo_id: "sc-1",
                       data: { "total" => "100.0", "balance" => "100.0", "email_status" => "NotSet" })
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                     qbo_account: sanctuary_qa, qbo_invoice_id: "sc-1")

    assert_equal :impossible, tracker.status
  end

  test "a legacy garden3d tracker with a blueprint and no invoice is still deleted" do
    @tracker.update!(blueprint: { "lines" => {} })

    assert_equal :deleted, @tracker.status
  end

  test "a management fee tracker has no payout status" do
    assert @pass.allows_payment_splits?, "sanity: the pass is in the payment-splits era"
    assert_nil @tracker.contributor_payouts_status
  end

  test "a Sanctuary tracker with no payouts still reports no payouts" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2096, 3, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 940_002, name: "External Co 2")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                     qbo_account: sanctuary_qa)

    assert_equal :no_payouts, tracker.contributor_payouts_status
  end

  test "garden3d's pass shows invoice statuses and no payout pills" do
    other = make_payer("Second Payer #{SecureRandom.hex(3)}")
    attach_invoice(fee_tracker(@pass, other), qbo_id: "fee-3", total: "0.0", balance: "0.0", sent: false)

    pass = InvoicePass.find(@pass.id)

    assert_equal({ not_made: 1, not_sent: 1 }, pass.statuses)
    assert_equal({}, pass.payout_statuses)
  end

  test "a legacy garden3d tracker's configuration errors are still the Forecast checks" do
    @tracker.update!(blueprint: { "lines" => {} })
    QboAccount.any_instance.stubs(:fetch_all_customers).returns([])
    QboAccount.any_instance.stubs(:fetch_all_terms).returns([])

    assert_equal [[:missing_qbo_customer], [:missing_qbo_term]], @tracker.configuration_errors
  end

  test "configuration errors are empty and look nothing up in QuickBooks" do
    QboAccount.any_instance.expects(:fetch_all_customers).never
    QboAccount.any_instance.expects(:fetch_all_terms).never

    assert_equal [], @tracker.configuration_errors
  end

  test "generating payouts for a management fee invoice raises a clear error" do
    tracker = attach_invoice(@tracker, qbo_id: "fee-4", total: "130000.0", balance: "0.0", sent: true)

    error = assert_raises(RuntimeError) { tracker.make_contributor_payouts!(nil) }

    assert_match(/no contributor payouts/, error.message)
    assert_equal 0, ContributorPayout.where(invoice_tracker_id: tracker.id).count
  end
end
