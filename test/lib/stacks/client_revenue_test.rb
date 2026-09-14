require 'test_helper'

class StacksClientRevenueTest < ActiveSupport::TestCase
  def setup
    @g3d = Studio.new(name: "garden3d", mini_name: "g3d")
    @sanctu = Studio.new(name: "Sanctuary Computer", mini_name: "sanctu")
    @studios = [@g3d, @sanctu]
    @acme = ForecastClient.new(name: "Acme")
    @globex = ForecastClient.new(name: "Globex")
  end

  def make_tracker(client:, month:, total:, blueprint: nil, voided: false, no_invoice: false, internal: false)
    tracker = InvoiceTracker.new
    if no_invoice
      tracker.stubs(:qbo_invoice).returns(nil)
    else
      # Use non-blank data so the blank-data guard in build_rows doesn't skip these trackers.
      invoice = QboInvoice.new(data: { "synced" => true })
      invoice.stubs(:status).returns(voided ? :voided : :paid)
      invoice.stubs(:total).returns(total.to_f)
      tracker.stubs(:qbo_invoice).returns(invoice)
    end
    client.stubs(:is_internal?).returns(true) if internal
    tracker.stubs(:forecast_client).returns(client)
    tracker.stubs(:invoice_pass).returns(InvoicePass.new(start_of_month: month))
    tracker.stubs(:blueprint).returns(blueprint)
    tracker
  end

  test "garden3d counts full invoice totals grouped by client" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 1, 1), total: 10_000),
      make_tracker(client: @acme, month: Date.new(2025, 3, 1), total: 20_000),
      make_tracker(client: @globex, month: Date.new(2025, 2, 1), total: 30_000)
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)

    assert_equal 2, cr.client_count_asof(Date.new(2025, 12, 31))
    assert_equal 30_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
  end

  test "excludes voided, unlinked, and internal-client trackers" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 1, 1), total: 10_000),
      make_tracker(client: @acme, month: Date.new(2025, 2, 1), total: 99_999, voided: true),
      make_tracker(client: @acme, month: Date.new(2025, 3, 1), total: 99_999, no_invoice: true),
      make_tracker(client: @globex, month: Date.new(2025, 1, 1), total: 99_999, internal: true)
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)

    assert_equal 1, cr.client_count_asof(Date.new(2025, 12, 31))
    assert_equal 10_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
    assert_equal 0, cr.skipped_tracker_count
  end

  test "asof date excludes later invoices" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 1, 1), total: 10_000),
      make_tracker(client: @acme, month: Date.new(2025, 6, 1), total: 50_000)
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)

    assert_equal 10_000.0, cr.average_lifetime_value_asof(Date.new(2025, 3, 31))
  end

  test "average tenure is whole months between first and last invoice month per client" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 1, 1), total: 1),
      make_tracker(client: @acme, month: Date.new(2025, 7, 1), total: 1),   # 6 months
      make_tracker(client: @globex, month: Date.new(2025, 3, 1), total: 1)  # 0 months
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)

    assert_equal 3.0, cr.average_tenure_months_asof(Date.new(2025, 12, 31))
  end

  test "concentration is the largest client's share of in-range revenue" do
    trackers = [
      make_tracker(client: @acme, month: Date.new(2025, 4, 1), total: 75_000),
      make_tracker(client: @globex, month: Date.new(2025, 5, 1), total: 25_000),
      make_tracker(client: @globex, month: Date.new(2024, 1, 1), total: 900_000) # out of range
    ]
    cr = Stacks::ClientRevenue.new(@g3d, @studios, trackers)
    result = cr.concentration_for_range(Date.new(2025, 4, 1), Date.new(2025, 6, 30))

    assert_equal 75.0, result[:value]
    assert_equal "Acme", result[:top_client_name]
    assert_equal 75_000.0, result[:top_client_amount]
    assert_equal 100_000.0, result[:total_revenue]
  end

  test "concentration with no in-range revenue returns zeros" do
    cr = Stacks::ClientRevenue.new(@g3d, @studios, [])
    result = cr.concentration_for_range(Date.new(2025, 1, 1), Date.new(2025, 1, 31))

    assert_equal 0, result[:value]
    assert_nil result[:top_client_name]
  end

  test "empty rows return 0 for averages" do
    cr = Stacks::ClientRevenue.new(@g3d, @studios, [])
    assert_equal 0, cr.average_lifetime_value_asof(Date.today)
    assert_equal 0, cr.average_tenure_months_asof(Date.today)
  end

  test "sub-studio takes a pro-rata share of the invoice via blueprint person lines" do
    person_in_sanctu = ForecastPerson.create!(
      id: 111, first_name: "Sanctu", last_name: "Person", email: "sanctu@sanctuary.computer",
      archived: false, roles: ["Sanctuary Computer"], updated_at: Date.today
    )
    person_elsewhere = ForecastPerson.create!(
      id: 222, first_name: "Other", last_name: "Person", email: "other@sanctuary.computer",
      archived: false, roles: ["XXIX"], updated_at: Date.today
    )

    blueprint = {
      "lines" => {
        "ACME-1 Acme (July 2025) Sanctu Person [FP-111]" => {
          "forecast_person" => person_in_sanctu.forecast_id, "quantity" => 10, "unit_price" => 100
        },
        "ACME-1 Acme (July 2025) Other Person [FP-222]" => {
          "forecast_person" => person_elsewhere.forecast_id, "quantity" => 30, "unit_price" => 100
        }
      }
    }
    # blueprint sums to $4,000; sanctu's share is 1,000/4,000 = 25% of the $8,000 invoice
    trackers = [make_tracker(client: @acme, month: Date.new(2025, 7, 1), total: 8_000, blueprint: blueprint)]
    cr = Stacks::ClientRevenue.new(@sanctu, @studios, trackers)

    assert_equal 2_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
  end

  test "sub-studio resolves legacy lines via the [FP-id] description tag" do
    person_in_sanctu = ForecastPerson.create!(
      id: 111, first_name: "Sanctu", last_name: "Person", email: "sanctu@sanctuary.computer",
      archived: false, roles: ["Sanctuary Computer"], updated_at: Date.today
    )

    blueprint = {
      "lines" => {
        "ACME-1 Acme (July 2025) Sanctu Person [FP-111]" => { "quantity" => 10, "unit_price" => 100 }
      }
    }
    trackers = [make_tracker(client: @acme, month: Date.new(2025, 7, 1), total: 1_000, blueprint: blueprint)]
    cr = Stacks::ClientRevenue.new(@sanctu, @studios, trackers)

    assert_equal 1_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
  end

  test "sub-studio skips malformed blueprint lines and trackers with no usable lines" do
    blueprint = {
      "lines" => {
        "bad line" => { "quantity" => "ten", "unit_price" => 100 }
      }
    }
    trackers = [make_tracker(client: @acme, month: Date.new(2025, 7, 1), total: 1_000, blueprint: blueprint)]
    cr = Stacks::ClientRevenue.new(@sanctu, @studios, trackers)

    assert_equal 0, cr.client_count_asof(Date.new(2025, 12, 31))
  end

  test "a tracker whose invoice raises TypeError from #status is skipped while a healthy tracker still counts" do
    # Simulates QboInvoice#status calling `due_date - Date.today` where due_date is nil
    bad_invoice = QboInvoice.new(data: { "synced" => true })
    bad_invoice.stubs(:status).raises(TypeError, "nil can't be coerced into Integer")

    bad_tracker = InvoiceTracker.new
    bad_tracker.stubs(:qbo_invoice).returns(bad_invoice)
    bad_tracker.stubs(:forecast_client).returns(@acme)
    bad_tracker.stubs(:invoice_pass).returns(InvoicePass.new(start_of_month: Date.new(2025, 1, 1)))
    bad_tracker.stubs(:blueprint).returns(nil)

    healthy_tracker = make_tracker(client: @globex, month: Date.new(2025, 2, 1), total: 5_000)

    cr = Stacks::ClientRevenue.new(@g3d, @studios, [bad_tracker, healthy_tracker])

    assert_equal 1, cr.client_count_asof(Date.new(2025, 12, 31))
    assert_equal 5_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
    assert_equal 1, cr.skipped_tracker_count
  end

  test "a tracker whose invoice has blank data is skipped without triggering lazy sync; a healthy tracker still counts" do
    # blank-data invoice: QboInvoice.new with NO data attribute — the new guard must skip it
    # without ever calling #status or #total (which would trigger the lazy live-QBO sync).
    blank_invoice = QboInvoice.new  # data column is nil/blank — no data: kwarg
    blank_invoice.expects(:status).never
    blank_invoice.expects(:total).never

    blank_tracker = InvoiceTracker.new
    blank_tracker.stubs(:qbo_invoice).returns(blank_invoice)
    blank_tracker.stubs(:forecast_client).returns(@acme)
    blank_tracker.stubs(:invoice_pass).returns(InvoicePass.new(start_of_month: Date.new(2025, 1, 1)))
    blank_tracker.stubs(:blueprint).returns(nil)

    healthy_tracker = make_tracker(client: @globex, month: Date.new(2025, 2, 1), total: 5_000)

    cr = Stacks::ClientRevenue.new(@g3d, @studios, [blank_tracker, healthy_tracker])

    assert_equal 1, cr.client_count_asof(Date.new(2025, 12, 31))
    assert_equal 5_000.0, cr.average_lifetime_value_asof(Date.new(2025, 12, 31))
    assert_equal 1, cr.skipped_tracker_count
  end
end
