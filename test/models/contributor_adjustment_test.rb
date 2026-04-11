require "test_helper"

class ContributorAdjustmentTest < ActiveSupport::TestCase
  test "payable when no qbo invoice" do
    adj = ContributorAdjustment.new(amount: 100, qbo_invoice_id: nil)
    assert adj.payable?
  end

  test "not payable when invoice record missing" do
    adj = ContributorAdjustment.new(amount: 100, qbo_invoice_id: "missing")
    QboInvoice.expects(:find_by).with(qbo_id: "missing").returns(nil)
    assert_not adj.payable?
  end

  test "not payable for voided invoice" do
    inv = QboInvoice.new(qbo_id: "inv1")
    inv.stubs(:status).returns(:voided)
    QboInvoice.stubs(:find_by).with(qbo_id: "inv1").returns(inv)

    adj = ContributorAdjustment.new(amount: 1000, qbo_invoice_id: "inv1")
    assert_not adj.payable?
  end

  test "not payable until invoice fully paid" do
    inv = QboInvoice.new(qbo_id: "inv1")
    inv.stubs(:status).returns(:partially_paid)
    QboInvoice.stubs(:find_by).with(qbo_id: "inv1").returns(inv)

    adj = ContributorAdjustment.new(amount: 1000, qbo_invoice_id: "inv1")
    assert_not adj.payable?
  end

  test "payable when invoice is paid" do
    inv = QboInvoice.new(qbo_id: "inv1")
    inv.stubs(:status).returns(:paid)
    QboInvoice.stubs(:find_by).with(qbo_id: "inv1").returns(inv)

    adj = ContributorAdjustment.new(amount: 1000, qbo_invoice_id: "inv1")
    assert adj.payable?
  end
end
