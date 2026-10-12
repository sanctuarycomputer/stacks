require "test_helper"

class InvoicePassMakeTrackersTest < ActiveSupport::TestCase
  def setup
    @sanctuary = enterprises(:sanctuary)
    @garden3d = enterprises(:garden3d)
    # Sanctuary already has two qbo_account fixtures and has_one has no ORDER BY;
    # pin the one it picks rather than creating a third.
    @sanctuary_qa = Enterprise.find(@sanctuary.id).qbo_account
    QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm",
                       client_id: "x", client_secret: "y")

    @external_client = ForecastClient.create!(forecast_id: 910_001, name: "External Co")
  end

  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "a garden3d pass creates no forecast trackers for Sanctuary's clients" do
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 1, 1),
                               enterprise: @garden3d, data: {})
    pass.stubs(:clients_served).returns([@external_client])

    pass.make_trackers!

    assert_equal 0, pass.invoice_trackers.count,
      "garden3d's pass must not absorb clients issued by Sanctuary"
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
    assert_equal @sanctuary_qa, tracker.qbo_account
    assert_equal "forecast", tracker.source
  end
end
