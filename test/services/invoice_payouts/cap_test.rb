require "test_helper"

class InvoicePayoutsCapTest < ActiveSupport::TestCase
  include PayoutFixtures

  setup do
    setup_payout_people
    @project2 = ForecastProject.create!(forecast_id: 710_002, client_id: @client.forecast_id, name: "Guard Proj 2", code: "MG-2", tags: ["100p/h"])
  end

  def one_line(project: @project, id: "1")
    { id: id, person: @ic, project: project, hours: 100.0, rate: 100.0 } # $10,000
  end

  test "an all-v1 invoice caps at 70%" do
    build_tracker("new_deal_v1")
    cap = InvoicePayouts::Cap.new(build_invoice_tracker([one_line]))
    assert_in_delta 7000.0, cap.cap, 0.001
    assert_in_delta 10_000.0, cap.post_commission_total, 0.001
  end

  test "an all-v2 invoice caps at 67%" do
    build_tracker("new_deal_v2")
    assert_in_delta 6700.0, InvoicePayouts::Cap.new(build_invoice_tracker([one_line])).cap, 0.001
  end

  test "a mixed invoice is weighted by line" do
    build_tracker("new_deal_v1")
    build_tracker("new_deal_v2", project: @project2)
    it = build_invoice_tracker([one_line, one_line(project: @project2, id: "2")])
    assert_in_delta 13_700.0, InvoicePayouts::Cap.new(it).cap, 0.001
  end

  test "target_margin_override wins over the billing models" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker([one_line])
    it.update!(target_margin_override: 0.25)
    assert_in_delta 7500.0, InvoicePayouts::Cap.new(it).cap, 0.001
    assert_equal BigDecimal("0.25"), InvoicePayouts::Cap.new(it).treasury_share_for("1")
  end

  test "commissions come off the line before its share is applied" do
    build_tracker("new_deal_v2")
    cap = InvoicePayouts::Cap.new(build_invoice_tracker([one_line]), commissions_by_line: { "1" => 1000.0 })
    assert_in_delta 6030.0, cap.cap, 0.001 # (10000 - 1000) * 0.67
    assert_in_delta 9000.0, cap.post_commission_total, 0.001
  end

  test "the unmapped remainder and unattributed commissions use the default model" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker([one_line], total: 12_000.0)
    cap = InvoicePayouts::Cap.new(it, commissions_by_line: { nil => 500.0, "999" => 500.0 })
    # 10000 * 0.67 + (2000 - 1000) * 0.70
    assert_in_delta 7400.0, cap.cap, 0.001
  end

  test "an internal client caps at the whole post-commission total" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker([one_line])
    ForecastClient.any_instance.stubs(:is_internal?).returns(true)
    cap = InvoicePayouts::Cap.new(it, commissions_by_line: { "1" => 1000.0 })
    assert_in_delta 9000.0, cap.cap, 0.001
    assert_equal 0, cap.treasury_share_for("1")
  end

  test "a line whose project has no tracker falls into the remainder" do
    it = build_invoice_tracker([one_line])
    assert_in_delta 7000.0, InvoicePayouts::Cap.new(it).cap, 0.001
    assert_empty InvoicePayouts::Cap.new(it).mapped_lines
  end
end
