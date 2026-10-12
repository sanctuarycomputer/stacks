require "test_helper"

class Mso::ManagementFeeInvoicesNightlyTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include ManagementFeeFixtures

  TODAY = Date.new(2090, 10, 12)
  LAST_MONTH = Date.new(2090, 9, 1)

  def setup
    @qbo_account = garden3d_qbo_account
    make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [993_001])
    make_payer(Enterprise::INDEX_SPACE_NAME, customer_id: "5", forecast_ids: [993_002])
  end

  def teardown
    clear_enterprise_memos
  end

  def forbid_quickbooks
    QboAccount.any_instance.expects(:make_and_refresh_qbo_access_token).never
    QboAccount.any_instance.expects(:fetch_all_items).never
    QboAccount.any_instance.expects(:fetch_all_terms).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    QboAccount.any_instance.expects(:fetch_invoice_by_id).never
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    Quickbooks::Service::Invoice.any_instance.expects(:query).never
    Quickbooks::Service::Customer.any_instance.expects(:create).never
    Mso::ManagementFeeInvoices.expects(:push_invoice!).never
    Mso::ManagementFeeInvoices.expects(:create_drafts!).never
  end

  def garden3d_passes
    InvoicePass.where(enterprise_id: garden3d.id)
  end

  # --- ensure_month! ---------------------------------------------------------

  test "ensure_month! creates garden3d's pass for that month with one tracker per payer" do
    pass = Mso::ManagementFeeInvoices.ensure_month!(Date.new(2090, 9, 17))

    assert_equal garden3d, pass.enterprise
    assert_equal LAST_MONTH, pass.start_of_month
    trackers = InvoiceTracker.where(invoice_pass_id: pass.id)
    assert_equal [993_001, 993_002], trackers.pluck(:forecast_client_id).sort
    assert_equal [nil, nil], trackers.pluck(:qbo_invoice_id)
  end

  test "ensure_month! works for a month before drafting started, so its invoices can be attached" do
    forbid_quickbooks
    month = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START - 4.months

    pass = Mso::ManagementFeeInvoices.ensure_month!(month)

    assert_equal month, pass.start_of_month
    assert_equal 2, InvoiceTracker.where(invoice_pass_id: pass.id).count
    refute Mso::ManagementFeeInvoices.draftable?(pass), "attachable, never draftable"
  end

  test "ensure_month! twice changes nothing" do
    first = Mso::ManagementFeeInvoices.ensure_month!(LAST_MONTH)

    assert_no_difference [-> { InvoicePass.count }, -> { InvoiceTracker.count }] do
      assert_equal first.id, Mso::ManagementFeeInvoices.ensure_month!(LAST_MONTH).id
    end
  end

  test "ensure_month! refuses a month whose garden3d pass holds a legacy Forecast tracker" do
    # The pass page renders such a pass as it always has and offers no way to
    # manage fee trackers, so adding them would strand them.
    forbid_quickbooks
    pass = garden3d_pass(Date.new(2090, 6, 1))
    ForecastClient.create!(forecast_id: 993_050, name: "garden3d internal")
    legacy = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: 993_050, qbo_account: @qbo_account,
                                    blueprint: { "lines" => {} })

    error = assert_raises(Mso::ManagementFeeInvoices::LegacyPass) do
      Mso::ManagementFeeInvoices.ensure_month!(Date.new(2090, 6, 17))
    end

    assert_match(/June 2090/, error.message)
    assert_match(/InvoicePass #{pass.id}/, error.message)
    assert_equal [legacy.id], InvoiceTracker.where(invoice_pass_id: pass.id).pluck(:id)
  end

  # --- openable_months -------------------------------------------------------

  test "openable_months lists the months with no garden3d pass, newest first, and reads only the database" do
    forbid_quickbooks
    first = Mso::ManagementFeeInvoices::FIRST_FEE_MONTH
    assert_equal Date.new(2024, 1, 1), first
    garden3d_pass(Date.new(2024, 2, 1))
    # Another company's pass does not take the month.
    InvoicePass.create!(start_of_month: Date.new(2024, 3, 1), enterprise: enterprises(:sanctuary), data: {})

    months = Mso::ManagementFeeInvoices.openable_months(today: Date.new(2024, 4, 20))

    assert_equal [Date.new(2024, 4, 1), Date.new(2024, 3, 1), Date.new(2024, 1, 1)], months
    assert_equal [], Mso::ManagementFeeInvoices.openable_months(today: first - 1.day)
  end

  # --- ensure_previous_month! ------------------------------------------------

  test "the nightly run creates last month's pass and never touches QuickBooks" do
    forbid_quickbooks

    pass = Mso::ManagementFeeInvoices.ensure_previous_month!(today: TODAY)

    assert_equal LAST_MONTH, pass.start_of_month
    assert_equal 2, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  test "the nightly run does nothing while last month predates the start month" do
    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START

    assert_no_difference [-> { InvoicePass.count }, -> { InvoiceTracker.count }] do
      # Any day in the start month: "last month" was invoiced by hand.
      assert_nil Mso::ManagementFeeInvoices.ensure_previous_month!(today: start + 11.days)
    end

    # The first of the following month: last month IS the start month.
    assert_equal start, Mso::ManagementFeeInvoices.ensure_previous_month!(today: start.next_month).start_of_month
    assert_equal [start], garden3d_passes.pluck(:start_of_month)
  end

  # --- the catch-up ----------------------------------------------------------
  # The nightly run only ever looked at LAST month, so a month it missed (the
  # start month itself, when the code shipped two months later) never got a
  # pass. It now makes every month from the start month through last month.

  test "the nightly run catches up every month from the start month, without QuickBooks" do
    forbid_quickbooks
    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START
    assert_equal Date.new(2026, 8, 1), start

    pass = Mso::ManagementFeeInvoices.ensure_previous_month!(today: Date.new(2026, 10, 12))

    assert_equal Date.new(2026, 9, 1), pass.start_of_month, "it still answers with last month's pass"
    assert_equal [Date.new(2026, 8, 1), Date.new(2026, 9, 1)], garden3d_passes.order(:start_of_month).pluck(:start_of_month)
    garden3d_passes.each do |made|
      assert_equal [993_001, 993_002], InvoiceTracker.where(invoice_pass_id: made.id).pluck(:forecast_client_id).sort
      assert_equal [nil, nil], InvoiceTracker.where(invoice_pass_id: made.id).pluck(:qbo_invoice_id)
    end
  end

  test "the catch-up twice changes nothing" do
    forbid_quickbooks
    Mso::ManagementFeeInvoices.ensure_previous_month!(today: Date.new(2026, 10, 12))

    assert_no_difference [-> { InvoicePass.count }, -> { InvoiceTracker.count }] do
      Mso::ManagementFeeInvoices.ensure_previous_month!(today: Date.new(2026, 10, 12))
    end
  end

  test "the catch-up fills in a month the nightly run missed and leaves the others alone" do
    forbid_quickbooks
    august = Mso::ManagementFeeInvoices.ensure_month!(Date.new(2026, 8, 1))
    october = Mso::ManagementFeeInvoices.ensure_month!(Date.new(2026, 10, 1))
    august_trackers = InvoiceTracker.where(invoice_pass_id: august.id).order(:id).pluck(:id)

    Mso::ManagementFeeInvoices.ensure_previous_month!(today: Date.new(2026, 11, 3))

    assert_equal [Date.new(2026, 8, 1), Date.new(2026, 9, 1), Date.new(2026, 10, 1)],
                 garden3d_passes.order(:start_of_month).pluck(:start_of_month)
    assert_equal august_trackers, InvoiceTracker.where(invoice_pass_id: august.id).order(:id).pluck(:id)
    assert_equal 2, InvoiceTracker.where(invoice_pass_id: october.id).count
  end

  test "the catch-up is bounded: it never reaches further back than CATCH_UP_MONTHS" do
    forbid_quickbooks
    window = Mso::ManagementFeeInvoices::CATCH_UP_MONTHS
    assert_equal 12, window

    Mso::ManagementFeeInvoices.ensure_previous_month!(today: TODAY)

    months = garden3d_passes.order(:start_of_month).pluck(:start_of_month)
    assert_equal window, months.size
    assert_equal LAST_MONTH - (window - 1).months, months.first
    assert_equal LAST_MONTH, months.last
  end

  test "the catch-up never reaches back before the start month" do
    forbid_quickbooks
    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START

    Mso::ManagementFeeInvoices.ensure_previous_month!(today: start + 3.months + 4.days)

    assert_equal [start, start + 1.month, start + 2.months], garden3d_passes.order(:start_of_month).pluck(:start_of_month)
  end

  test "the catch-up steps over a month whose pass holds a legacy Forecast tracker" do
    forbid_quickbooks
    legacy_pass = garden3d_pass(Date.new(2090, 6, 1))
    ForecastClient.create!(forecast_id: 993_051, name: "garden3d internal")
    legacy = InvoiceTracker.create!(invoice_pass: legacy_pass, forecast_client_id: 993_051, qbo_account: @qbo_account,
                                    blueprint: { "lines" => {} })

    pass = Mso::ManagementFeeInvoices.ensure_previous_month!(today: TODAY)

    assert_equal LAST_MONTH, pass.start_of_month
    assert_equal [legacy.id], InvoiceTracker.where(invoice_pass_id: legacy_pass.id).pluck(:id), "left as it was"
    others = garden3d_passes.where.not(id: legacy_pass.id)
    assert_equal 11, others.count
    others.each { |made| assert_equal 2, InvoiceTracker.where(invoice_pass_id: made.id).count }
  end

  test "the nightly run answers nil when last month's own pass is a legacy one" do
    forbid_quickbooks
    legacy_pass = garden3d_pass(LAST_MONTH)
    ForecastClient.create!(forecast_id: 993_052, name: "garden3d internal")
    InvoiceTracker.create!(invoice_pass: legacy_pass, forecast_client_id: 993_052, qbo_account: @qbo_account,
                           blueprint: { "lines" => {} })

    assert_nil Mso::ManagementFeeInvoices.ensure_previous_month!(today: TODAY)
    assert_equal 1, InvoiceTracker.where(invoice_pass_id: legacy_pass.id).count
  end

  test "the nightly run leaves Sanctuary's pass for the same month alone" do
    sanctuary_pass = InvoicePass.create!(start_of_month: LAST_MONTH, enterprise: enterprises(:sanctuary), data: {})

    pass = Mso::ManagementFeeInvoices.ensure_previous_month!(today: TODAY)

    refute_equal sanctuary_pass.id, pass.id
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: sanctuary_pass.id).count
  end

  # --- before the migration has run ------------------------------------------
  # Migrations are run by hand on production, after the deploy.

  test "the nightly run is a no-op until the management fee columns exist" do
    stub_management_fee_columns_missing
    forbid_quickbooks
    Enterprise.expects(:management_fee_payers).never

    assert_no_difference [-> { InvoicePass.count }, -> { InvoiceTracker.count }] do
      assert_nil Mso::ManagementFeeInvoices.ensure_previous_month!(today: TODAY)
    end
  end

  test "creating drafts before the columns exist raises a clear error, before any QuickBooks call" do
    pass = garden3d_pass(LAST_MONTH)
    assert Mso::ManagementFeeInvoices.draftable?(pass), "sanity: nothing else refuses this pass"
    stub_management_fee_columns_missing
    forbid_quickbooks
    Mso::ManagementFeeInvoices.unstub(:push_invoice!, :create_drafts!)
    Enterprise.expects(:management_fee_payers).never

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) do
      Mso::ManagementFeeInvoices.create_drafts!(invoice_pass: pass)
    end

    assert_match(/management fee columns are not on this database yet/, error.message)
    assert_match(/Run migration 20261013000001/, error.message)
    assert_equal 0, InvoiceTracker.where(invoice_pass_id: pass.id).count
  end

  test "pushing one draft before the columns exist raises a clear error, before any QuickBooks call" do
    pass = garden3d_pass(LAST_MONTH)
    tracker = fee_tracker(pass, Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME))
    stub_management_fee_columns_missing
    forbid_quickbooks
    Mso::ManagementFeeInvoices.unstub(:push_invoice!, :create_drafts!)

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) do
      Mso::ManagementFeeInvoices.push_invoice!(invoice_tracker: tracker)
    end

    assert_match(/Run migration 20261013000001/, error.message)
    assert_nil tracker.reload.qbo_invoice_id
  end

  # --- the hook --------------------------------------------------------------

  test "garden3d's daily tasks run it, catch-up included, without QuickBooks" do
    forbid_quickbooks
    Stacks::Optix.expects(:deactivate_inactive_members!).never

    # The day this ships: August and September 2026 have never had a pass.
    travel_to Date.new(2026, 10, 12) do
      assert_difference -> { garden3d_passes.count }, 2 do
        Enterprise.find(garden3d.id).daily_tasks
      end
    end
    assert_equal [Date.new(2026, 8, 1), Date.new(2026, 9, 1)], garden3d_passes.order(:start_of_month).pluck(:start_of_month)
    assert_equal 4, InvoiceTracker.where(invoice_pass_id: garden3d_passes.select(:id)).count
  end

  test "another enterprise's daily tasks do not" do
    Mso::ManagementFeeInvoices.expects(:ensure_previous_month!).never

    enterprises(:one).daily_tasks
  end
end
