require "test_helper"

class InvoicePassMakeTrackersTest < ActiveSupport::TestCase
  def setup
    @sanctuary = enterprises(:sanctuary)
    @garden3d = enterprises(:garden3d)
    QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm",
                       client_id: "x", client_secret: "y")

    @external_client = ForecastClient.create!(forecast_id: 910_001, name: "External Co")
  end

  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "make_trackers! refuses to run on a non-Sanctuary pass" do
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 1, 1),
                               enterprise: @garden3d, data: {})
    pass.expects(:clients_served).never

    error = assert_raises(RuntimeError) { pass.make_trackers! }

    assert_match(/only runs on Sanctuary Computer Inc's passes/, error.message)
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  test "a Sanctuary pass creates a tracker for an external client" do
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 2, 1),
                               enterprise: @sanctuary, data: {})
    pass.stubs(:clients_served).returns([@external_client])

    pass.make_trackers!

    assert_equal 1, pass.invoice_trackers.count
    # make_trackers! calls `statuses` first, which memoizes invoice_trackers
    # as empty before the tracker is created; reload to see the fresh row.
    tracker = pass.invoice_trackers.reload.first
    assert_equal @external_client.forecast_id, tracker.forecast_client_id
    assert_equal @sanctuary.id, tracker.qbo_account.enterprise_id
  end
end
