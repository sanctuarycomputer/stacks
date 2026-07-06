require "test_helper"

class InvoicePassTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    # Far-future month to avoid colliding with any other test's InvoicePass
    # row (start_of_month has a unique index).
    @pass = InvoicePass.create!(start_of_month: Date.new(2099, 1, 1))
  end

  # NOTE on queries: `make_trackers!` calls `statuses`, which calls
  # `invoice_trackers.map(&:status)` — this LOADS the (initially empty)
  # collection into the AR association cache. Any subsequent read via
  # `@pass.invoice_trackers` returns from the stale in-memory cache, so we
  # query the table directly (or call `.reload`) to verify rows.
  def trackers_for_pass
    InvoiceTracker.where(invoice_pass_id: @pass.id)
  end

  test "make_trackers! creates an InvoiceTracker for an external (non-internal) client" do
    external = ForecastClient.create!(forecast_id: 99_001, name: "External Co")
    refute external.is_internal?, "fixture sanity: external client should not be internal"
    @pass.stubs(:clients_served).returns([external])

    @pass.make_trackers!

    assert_equal [external.forecast_id], trackers_for_pass.pluck(:forecast_client_id)
  end

  test "make_trackers! skips internal clients" do
    enterprise = Enterprise.create!(name: "InternalEnt-#{SecureRandom.hex(2)}")
    internal = ForecastClient.create!(forecast_id: 99_002, name: "Internal Co")
    EnterpriseForecastClient.create!(enterprise: enterprise, forecast_client_id: internal.forecast_id)
    assert internal.reload.is_internal?, "fixture sanity: mapped client should be internal"

    @pass.stubs(:clients_served).returns([internal])

    @pass.make_trackers!

    assert_equal [], trackers_for_pass.pluck(:forecast_client_id)
  end

  test "make_trackers! filters internal but keeps external when both are present" do
    enterprise = Enterprise.create!(name: "MixedEnt-#{SecureRandom.hex(2)}")
    internal = ForecastClient.create!(forecast_id: 99_003, name: "Internal Mixed")
    external = ForecastClient.create!(forecast_id: 99_004, name: "External Mixed")
    EnterpriseForecastClient.create!(enterprise: enterprise, forecast_client_id: internal.forecast_id)

    @pass.stubs(:clients_served).returns([internal, external])

    @pass.make_trackers!

    assert_equal [external.forecast_id], trackers_for_pass.pluck(:forecast_client_id)
  end
end
