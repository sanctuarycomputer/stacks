require 'test_helper'

class InvoiceTrackerTest < ActiveSupport::TestCase
  test "#qbo_line_items_relating_to_forecast_projects returns any line items without a corresponding base line item if their description matches the current project code" do
    qbo_invoice = QboInvoice.new

    qbo_invoice.expects(:line_items).returns([
      {
        "id" => 1
      },
      {
        "id" => 2
      }
    ])

    forecast_project = ForecastProject.new({
      id: 123,
      code: "ABCD-1"
    })

    invoice_tracker = InvoiceTracker.new({
      qbo_invoice: qbo_invoice
    })

    invoice_tracker.expects(:blueprint_diff).returns({
      "generated_at" => DateTime.now.to_s,
      "lines" => {
        "1" => {
          "id" => 2,
          "forecast_project" => forecast_project.id
        }
      }
    })

    line_items = invoice_tracker.qbo_line_items_relating_to_forecast_projects([
      forecast_project
    ])

    assert_equal([
      {
        "id" => 2
      }
    ], line_items)

  end

  test "#qbo_line_items_relating_to_forecast_projects returns any line items with a corresponding base line item sans forecast project if their description matches the current project code" do
    qbo_invoice = QboInvoice.new

    qbo_invoice.expects(:line_items).returns([
      {
        "id" => 1,
        "description" => "ABCD-1 Some info here"
      },
      {
        "id" => 2,
        "description" => "EFGH-2 Some other info here"
      }
    ])

    forecast_project = ForecastProject.new({
      id: 123,
      code: "ABCD-1"
    })

    invoice_tracker = InvoiceTracker.new({
      qbo_invoice: qbo_invoice
    })

    invoice_tracker.expects(:blueprint_diff).returns({
      "generated_at" => DateTime.now.to_s,
      "lines" => {}
    })

    line_items = invoice_tracker.qbo_line_items_relating_to_forecast_projects([
      forecast_project
    ])

    assert_equal([
      {
        "id" => 1,
        "description" => "ABCD-1 Some info here"
      }
    ], line_items)
  end
end
