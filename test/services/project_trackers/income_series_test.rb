require "test_helper"

# ProjectTrackers::IncomeSeries is the extracted admin burn-up income
# assembly (formerly ProjectTracker#income_series) — same ordering (invoice
# due_date, falling back to the tracker row's created_at), same attribution
# rules (tracker-attributable line items for InvoiceTrackers, the whole
# invoice total for adhoc), same {x:, y: 0} seed point. The service reads
# ONLY the stored `data` jsonb: a QboInvoice whose stored data is blank is
# skipped and counted, never lazily re-synced (QboInvoice#data's lazy path
# can update! or even destroy the row).
class ProjectTrackers::IncomeSeriesTest < ActiveSupport::TestCase
  def qbo_account!
    enterprise = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    enterprise.qbo_account || QboAccount.create!(
      enterprise: enterprise,
      client_id: "test_client",
      client_secret: "test_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )
  end

  def tracker!(forecast_project)
    pt = ProjectTracker.new(name: "Income Series Test")
    pt.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project_id: forecast_project.forecast_id)
    pt.update_column(:snapshot, { "first_forecast_assignment_start_date" => "2026-01-01" })
    ProjectTracker.find(pt.id)
  end

  test "accumulates attributable invoice income sorted by due date with a seed point" do
    qbo_account = qbo_account!
    forecast_client = ForecastClient.create!(forecast_id: 90_400_001, name: "Income Client")
    fp = ForecastProject.create!(forecast_id: 90_400_002, name: "Income Project", code: "INC-1", client_id: forecast_client.forecast_id)
    other_fp = ForecastProject.create!(forecast_id: 90_400_003, name: "Other Project", code: "OTH-1", client_id: forecast_client.forecast_id)
    pt = tracker!(fp)

    # A generated invoice for June: only the line item attributed to this
    # tracker's forecast project counts (1000.0) — the 999.0 line belongs
    # to a different tracker on the same client-level invoice.
    generated_invoice = QboInvoice.create!(qbo_account: qbo_account, qbo_id: "inc-gen", data: {
      "due_date" => "2026-06-15",
      "line_items" => [
        { "id" => "li-1", "description" => "INC-1 work", "amount" => 1000.0, "detail_type" => "SalesItemLineDetail",
          "sales_line_item_detail" => { "quantity" => 10.0, "unit_price" => 100.0 } },
        { "id" => "li-2", "description" => "OTH-1 work", "amount" => 999.0, "detail_type" => "SalesItemLineDetail",
          "sales_line_item_detail" => { "quantity" => 9.0, "unit_price" => 111.0 } },
      ],
    })
    InvoiceTracker.create!(
      forecast_client: forecast_client,
      invoice_pass: InvoicePass.find_or_create_by!(start_of_month: Date.new(2026, 5, 1)),
      qbo_account: qbo_account,
      qbo_invoice_id: generated_invoice.qbo_id,
      blueprint: { "lines" => {
        "INC-1 work" => { "id" => "li-1", "forecast_project" => fp.forecast_id, "quantity" => 10.0, "unit_price" => 100.0 },
        "OTH-1 work" => { "id" => "li-2", "forecast_project" => other_fp.forecast_id, "quantity" => 9.0, "unit_price" => 111.0 },
      } },
    )

    # An adhoc invoice due earlier (May): its WHOLE total counts.
    adhoc_invoice = QboInvoice.create!(qbo_account: qbo_account, qbo_id: "inc-adhoc", data: {
      "due_date" => "2026-05-15",
      "total" => 500.0,
    })
    AdhocInvoiceTracker.create!(project_tracker: pt, qbo_account: qbo_account, qbo_invoice_id: adhoc_invoice.qbo_id)

    # An adhoc invoice with no due_date in its synced data: falls back to
    # the tracker row's created_at (today), so it sorts last.
    no_due_invoice = QboInvoice.create!(qbo_account: qbo_account, qbo_id: "inc-nodue", data: { "total" => 200.0 })
    no_due_row = AdhocInvoiceTracker.create!(project_tracker: pt, qbo_account: qbo_account, qbo_invoice_id: no_due_invoice.qbo_id)

    series = ProjectTrackers::IncomeSeries.call(pt)

    assert_equal [
      { x: "2026-01-01", y: 0 },
      { x: "2026-05-15", y: 500.0 },
      { x: "2026-06-15", y: 1500.0 },
      { x: no_due_row.created_at.to_date.iso8601, y: 1700.0 },
    ], series[:income]
    assert_in_delta 1700.0, series[:income_total], 0.001
    assert_equal 0, series[:skipped_invoices]
  end

  test "a blank-data QboInvoice is skipped and counted, and its lazy sync! path is NEVER touched" do
    qbo_account = qbo_account!
    forecast_client = ForecastClient.create!(forecast_id: 90_400_011, name: "Blank Client")
    fp = ForecastProject.create!(forecast_id: 90_400_012, name: "Blank Project", code: "BLK-1", client_id: forecast_client.forecast_id)
    pt = tracker!(fp)

    # A healthy adhoc invoice so the series still accumulates around the
    # skipped row.
    good_invoice = QboInvoice.create!(qbo_account: qbo_account, qbo_id: "blk-good", data: {
      "due_date" => "2026-05-15",
      "total" => 500.0,
    })
    AdhocInvoiceTracker.create!(project_tracker: pt, qbo_account: qbo_account, qbo_invoice_id: good_invoice.qbo_id)

    # An unsynced mirror row: stored data jsonb is blank. QboInvoice#data
    # would live-fetch via sync! here — which can update! or even DESTROY
    # the row — so the service must skip it via the stored attribute.
    QboInvoice.create!(qbo_account: qbo_account, qbo_id: "blk-empty", data: {})
    AdhocInvoiceTracker.create!(project_tracker: pt, qbo_account: qbo_account, qbo_invoice_id: "blk-empty")

    QboInvoice.any_instance.expects(:sync!).never

    series = ProjectTrackers::IncomeSeries.call(pt)

    assert_equal [
      { x: "2026-01-01", y: 0 },
      { x: "2026-05-15", y: 500.0 },
    ], series[:income], "the blank-data invoice must not contribute a point"
    assert_in_delta 500.0, series[:income_total], 0.001
    assert_equal 1, series[:skipped_invoices]
  end
end
