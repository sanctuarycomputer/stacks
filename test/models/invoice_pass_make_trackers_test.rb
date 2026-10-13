require "test_helper"

# An enterprise makes one pass a month, and the pass makes its trackers. Who
# gets one depends on the enterprise.
class InvoicePassMakeTrackersTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  START = InvoicePass::INTERCOMPANY_START

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2096, 3, 1))
    @sanctuary = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [981_001])
    @index = make_payer(Enterprise::INDEX_SPACE_NAME, customer_id: "5", forecast_ids: [981_002])
    # Nothing here may touch QuickBooks.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token).raises(RuntimeError, "unexpected QuickBooks call")
  end

  def teardown
    clear_enterprise_memos
  end

  def trackers(pass = @pass)
    InvoiceTracker.where(invoice_pass_id: pass.id).order(:forecast_client_id).to_a
  end

  # --- which pass is which ---------------------------------------------------

  test "the first month is August 2026" do
    assert_equal Date.new(2026, 8, 1), START
  end

  # --- Sanctuary's trackers --------------------------------------------------

  test "a Sanctuary pass creates a tracker for an external client" do
    sanctuary = enterprises(:sanctuary)
    external_client = ForecastClient.create!(forecast_id: 910_001, name: "External Co")
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 2, 1), enterprise: sanctuary, data: {})
    pass.stubs(:clients_served).returns([external_client])

    pass.make_trackers!

    assert_equal 1, pass.invoice_trackers.count
    # make_trackers! calls `statuses` first, which memoizes invoice_trackers
    # as empty before the tracker is created; reload to see the fresh row.
    tracker = pass.invoice_trackers.reload.first
    assert_equal external_client.forecast_id, tracker.forecast_client_id
    assert_equal sanctuary.id, tracker.qbo_account.enterprise_id
  end

  test "a Sanctuary pass never gets a tracker for an enterprise garden3d bills" do
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 2, 1), enterprise: enterprises(:sanctuary), data: {})
    pass.stubs(:clients_served).returns([ForecastClient.find_by!(forecast_id: 981_002)])

    pass.make_trackers!

    assert_empty trackers(pass), "an internal client is paid through pay cycles, never invoiced by Sanctuary"
  end

  # --- garden3d's trackers ---------------------------------------------------

  test "garden3d's pass gets one blueprint-less tracker per enterprise it bills, on garden3d's QuickBooks account" do
    @pass.make_trackers!

    assert_equal [981_001, 981_002], trackers.map(&:forecast_client_id)
    assert trackers.all? { |tracker| tracker.blueprint.nil? }
    assert trackers.all? { |tracker| tracker.qbo_account_id == @qbo_account.id }
    assert trackers.all? { |tracker| tracker.qbo_invoice_id.nil? }
    assert trackers.all?(&:intercompany_invoice?)
  end

  test "an enterprise with no customer id in garden3d's QuickBooks gets no tracker" do
    make_payer("No Customer #{SecureRandom.hex(3)}", customer_id: nil, forecast_ids: [981_003])
    make_payer("Blank Customer #{SecureRandom.hex(3)}", customer_id: "", forecast_ids: [981_004])

    @pass.make_trackers!

    assert_equal [981_001, 981_002], trackers.map(&:forecast_client_id)
  end

  test "garden3d never bills itself, even with a customer id stored" do
    garden3d.update_columns(g3d_qbo_customer_id: "1")
    ForecastClient.create!(forecast_id: 981_009, name: "garden3d internal")
    EnterpriseForecastClient.create!(enterprise: garden3d, forecast_client_id: 981_009)

    @pass.make_trackers!

    assert_equal [981_001, 981_002], trackers.map(&:forecast_client_id)
  end

  test "making trackers twice changes nothing" do
    @pass.make_trackers!
    before = trackers.map(&:id)

    @pass.make_trackers!

    assert_equal before, trackers.map(&:id)
  end

  test "an enterprise with several internal clients gets one tracker, on the lowest Forecast id" do
    ForecastClient.create!(forecast_id: 980_000, name: "Index earlier internal")
    EnterpriseForecastClient.create!(enterprise: @index, forecast_client_id: 980_000)

    @pass.make_trackers!

    assert_equal [980_000, 981_001], trackers.map(&:forecast_client_id)
  end

  test "a tracker already on another of the enterprise's clients is reused" do
    @pass.make_trackers!
    ForecastClient.create!(forecast_id: 980_000, name: "Index earlier internal")
    EnterpriseForecastClient.create!(enterprise: @index, forecast_client_id: 980_000)

    @pass.make_trackers!

    assert_equal [981_001, 981_002], trackers.map(&:forecast_client_id)
  end

  test "an enterprise garden3d bills that has no internal Forecast client raises" do
    clientless = Enterprise.create!(name: "Clientless #{SecureRandom.hex(3)}", g3d_qbo_customer_id: "9")

    error = assert_raises(RuntimeError) { @pass.make_trackers! }

    assert_match(/#{clientless.name} has no internal Forecast client/, error.message)
  end

  test "it raises when garden3d has no QuickBooks account" do
    @qbo_account.destroy!

    error = assert_raises(RuntimeError) { @pass.make_trackers! }

    assert_match(/no connected QboAccount/, error.message)
    assert_empty trackers
  end

  test "a garden3d pass before the first month makes no trackers: it was invoiced by hand" do
    early = garden3d_pass(START - 1.month)

    error = assert_raises(RuntimeError) { early.make_trackers! }

    assert_match(/were made by hand/, error.message)
    assert_empty trackers(early)
  end

  test "any other enterprise's pass makes no trackers" do
    other_pass = InvoicePass.create!(start_of_month: Date.new(2096, 3, 1), enterprise: enterprises(:one), data: {})
    other_pass.expects(:clients_served).never

    error = assert_raises(NotImplementedError) { other_pass.make_trackers! }

    assert_match(/makes no invoices through Stacks/, error.message)
    assert_empty trackers(other_pass)
  end

  # --- the nightly step ------------------------------------------------------

  test "the nightly step makes garden3d's pass and trackers for every month from the first through last month" do
    InvoicePass.make_intercompany_passes!(today: Date.new(2026, 11, 3))

    passes = InvoicePass.where(enterprise: garden3d, start_of_month: START..Date.new(2026, 12, 1)).order(:start_of_month)
    assert_equal [Date.new(2026, 8, 1), Date.new(2026, 9, 1), Date.new(2026, 10, 1)], passes.map(&:start_of_month)
    passes.each do |pass|
      assert_equal [981_001, 981_002], trackers(pass).map(&:forecast_client_id), pass.invoice_month
    end
  end

  test "the nightly step leaves a month that has its pass alone: a newly billed enterprise is not added to it" do
    InvoicePass.make_intercompany_passes!(today: Date.new(2026, 10, 3))
    make_payer("Late Joiner #{SecureRandom.hex(3)}", customer_id: "31", forecast_ids: [981_020])

    InvoicePass.make_intercompany_passes!(today: Date.new(2026, 11, 3))

    august = InvoicePass.find_by!(enterprise: garden3d, start_of_month: START)
    october = InvoicePass.find_by!(enterprise: garden3d, start_of_month: Date.new(2026, 10, 1))
    assert_equal [981_001, 981_002], trackers(august).map(&:forecast_client_id)
    assert_equal [981_001, 981_002, 981_020], trackers(october).map(&:forecast_client_id)

    # An admin's Generate Invoices is make_trackers! on that pass: it does add it.
    august.make_trackers!
    assert_equal [981_001, 981_002, 981_020], trackers(august).map(&:forecast_client_id)
  end

  test "a month whose trackers cannot be made keeps no pass, so the next night tries again" do
    clientless = Enterprise.create!(name: "Clientless #{SecureRandom.hex(3)}", g3d_qbo_customer_id: "9")

    assert_raises(RuntimeError) { InvoicePass.make_intercompany_passes!(today: Date.new(2026, 9, 2)) }
    refute InvoicePass.exists?(enterprise: garden3d, start_of_month: START)

    clientless.update_columns(g3d_qbo_customer_id: nil)
    InvoicePass.make_intercompany_passes!(today: Date.new(2026, 9, 2))
    assert_equal 2, trackers(InvoicePass.find_by!(enterprise: garden3d, start_of_month: START)).size
  end

  test "the nightly step twice changes nothing, and fills in a month that is missing" do
    InvoicePass.make_intercompany_passes!(today: Date.new(2026, 10, 3))
    before = InvoiceTracker.count

    InvoicePass.make_intercompany_passes!(today: Date.new(2026, 10, 3))
    assert_equal before, InvoiceTracker.count

    InvoicePass.make_intercompany_passes!(today: Date.new(2026, 11, 1))
    assert InvoicePass.exists?(enterprise: garden3d, start_of_month: Date.new(2026, 10, 1))
  end

  test "the nightly step makes nothing before the first month has ended" do
    assert_no_difference -> { InvoicePass.count } do
      InvoicePass.make_intercompany_passes!(today: Date.new(2026, 8, 31))
    end
  end

  test "the nightly step leaves Sanctuary's pass for the same month alone" do
    sanctuary_pass = InvoicePass.create!(start_of_month: START, enterprise: enterprises(:sanctuary), data: {})

    InvoicePass.make_intercompany_passes!(today: Date.new(2026, 9, 2))

    assert_empty trackers(sanctuary_pass)
    assert_equal 2, trackers(InvoicePass.find_by!(enterprise: garden3d, start_of_month: START)).size
  end

  test "garden3d's daily tasks run the nightly step, and no other enterprise's do" do
    InvoicePass.expects(:make_intercompany_passes!).once

    garden3d.daily_tasks
    enterprises(:one).daily_tasks
  end
end
