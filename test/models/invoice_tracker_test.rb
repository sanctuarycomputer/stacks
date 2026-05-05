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

  test "#commission_total_for_line sums Commission entries across CPs whose blueprint_metadata.id matches the line" do
    cp1 = ContributorPayout.new(blueprint: {
      "Commission" => [
        { "amount" => 100.0, "blueprint_metadata" => { "id" => "5" } },
        { "amount" => 50.0,  "blueprint_metadata" => { "id" => "6" } },
      ]
    })
    cp2 = ContributorPayout.new(blueprint: {
      "Commission" => [
        { "amount" => 25.0, "blueprint_metadata" => { "id" => "5" } },
      ],
      "IndividualContributor" => [
        { "amount" => 999.0, "blueprint_metadata" => { "id" => "5" } },
      ]
    })

    invoice_tracker = InvoiceTracker.new
    invoice_tracker.stubs(:contributor_payouts).returns(stub(includes: [cp1, cp2]))

    assert_in_delta 125.0, invoice_tracker.commission_total_for_line("5"), 0.001
    assert_in_delta 50.0,  invoice_tracker.commission_total_for_line(6), 0.001
    assert_equal 0, invoice_tracker.commission_total_for_line("99")
  end

  test "#commission_deductions_for_line returns a deduction per active commission, in order" do
    pt = mock("project_tracker")
    contrib_a = mock("contrib_a")
    contrib_a.stubs(:display_name).returns("Acme")
    contrib_b = mock("contrib_b")
    contrib_b.stubs(:display_name).returns("Beta")

    pct = PercentageCommission.new(rate: 0.10)
    pct.stubs(:contributor).returns(contrib_a)
    per_hr = PerHourCommission.new(rate: 5.0)
    per_hr.stubs(:contributor).returns(contrib_b)
    pt.stubs(:commissions).returns([pct, per_hr])

    line_item = { "id" => "5", "amount" => 2000.0 }
    metadata  = { "quantity" => 10, "unit_price" => 200 }

    deductions = InvoiceTracker.new.commission_deductions_for_line(pt, line_item, metadata)

    assert_equal 2, deductions.length
    assert_equal pct, deductions[0][:commission]
    assert_in_delta 200.0, deductions[0][:amount], 0.01
    assert_equal per_hr, deductions[1][:commission]
    assert_in_delta 50.0, deductions[1][:amount], 0.01
  end

  test "#commission_deductions_for_line drops zero-amount deductions" do
    pt = mock("project_tracker")
    contrib = mock("contrib")
    contrib.stubs(:display_name).returns("Acme")
    pct = PercentageCommission.new(rate: 0.0)
    pct.stubs(:contributor).returns(contrib)
    pt.stubs(:commissions).returns([pct])

    deductions = InvoiceTracker.new.commission_deductions_for_line(
      pt,
      { "id" => "5", "amount" => 1000.0 },
      { "quantity" => 5, "unit_price" => 200 },
    )
    assert_empty deductions
  end
end
