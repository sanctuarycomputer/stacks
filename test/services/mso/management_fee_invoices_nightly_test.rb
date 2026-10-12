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

  test "garden3d's daily tasks run it, without QuickBooks" do
    forbid_quickbooks
    Stacks::Optix.expects(:deactivate_inactive_members!).never

    travel_to TODAY do
      assert_difference -> { garden3d_passes.count }, 1 do
        Enterprise.find(garden3d.id).daily_tasks
      end
    end
    assert_equal [LAST_MONTH], garden3d_passes.pluck(:start_of_month)
  end

  test "another enterprise's daily tasks do not" do
    Mso::ManagementFeeInvoices.expects(:ensure_previous_month!).never

    enterprises(:one).daily_tasks
  end
end
