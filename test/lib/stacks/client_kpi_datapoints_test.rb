require 'test_helper'

class StacksClientKpiDatapointsTest < ActiveSupport::TestCase
  test "datapoint enum includes the four client & pipeline KPIs at 27-30" do
    assert_equal 27, Okr.datapoints["average_client_lifetime_value"]
    assert_equal 28, Okr.datapoints["average_client_tenure"]
    assert_equal 29, Okr.datapoints["client_revenue_concentration"]
    assert_equal 30, Okr.datapoints["forecasted_sales_revenue"]
  end

  test ".call returns the four KPI entries" do
    studio = Studio.new(name: "garden3d", mini_name: "g3d")
    acme = ForecastClient.new(name: "Acme")

    invoice = QboInvoice.new(data: { "synced" => true })
    invoice.stubs(:status).returns(:paid)
    invoice.stubs(:total).returns(10_000.0)
    tracker = InvoiceTracker.new
    tracker.stubs(:qbo_invoice).returns(invoice)
    tracker.stubs(:forecast_client).returns(acme)
    tracker.stubs(:invoice_pass).returns(InvoicePass.new(start_of_month: Date.new(2025, 2, 1)))
    tracker.stubs(:blueprint).returns(nil)

    client_revenue = Stacks::ClientRevenue.new(studio, [studio], [tracker])

    open_budgeted = NotionPage.new(data: { "properties" => {
      "Lead Status" => { "type" => "status", "status" => { "name" => "Active" } },
      "Est. Budget Low" => { "type" => "number", "number" => 40_000 },
      "Est. Budget High" => { "type" => "number", "number" => 60_000 }
    } }).as_lead
    open_unbudgeted = NotionPage.new(data: { "properties" => {
      "Lead Status" => { "type" => "status", "status" => { "name" => "Not started" } }
    } }).as_lead
    lost = NotionPage.new(data: { "properties" => {
      "Lead Status" => { "type" => "status", "status" => { "name" => "Lost" } },
      "Est. Budget High" => { "type" => "number", "number" => 999_999 }
    } }).as_lead

    period = Stacks::Period.new("Feb 2025", Date.new(2025, 2, 1), Date.new(2025, 2, 28))
    data = Stacks::ClientKpiDatapoints.call(
      period: period,
      leads: [open_budgeted, open_unbudgeted, lost],
      client_revenue: client_revenue
    )

    assert_equal 10_000.0, data[:average_client_lifetime_value][:value]
    assert_equal :usd, data[:average_client_lifetime_value][:unit]
    assert_equal 1, data[:average_client_lifetime_value][:extras][:client_count]
    assert_equal 0, data[:average_client_lifetime_value][:extras][:skipped_tracker_count]

    assert_equal 0.0, data[:average_client_tenure][:value]
    assert_equal :count, data[:average_client_tenure][:unit]

    assert_equal 100.0, data[:client_revenue_concentration][:value]
    assert_equal :percentage, data[:client_revenue_concentration][:unit]
    assert_equal "Acme", data[:client_revenue_concentration][:extras][:top_client_name]
    assert_equal 0, data[:client_revenue_concentration][:extras][:skipped_tracker_count]

    assert_equal 50_000.0, data[:forecasted_sales_revenue][:value]
    assert_equal :usd, data[:forecasted_sales_revenue][:unit]
    assert_equal 2, data[:forecasted_sales_revenue][:extras][:open_lead_count]
    assert_equal 1, data[:forecasted_sales_revenue][:extras][:budgeted_lead_count]
  end
end
