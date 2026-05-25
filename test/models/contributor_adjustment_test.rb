require "test_helper"

class ContributorAdjustmentTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil

    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary,
      client_id: "test_client",
      client_secret: "test_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )

    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ca#{SecureRandom.hex(2)}@x.com", data: {})
    contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: contributor)
  end

  def new_adj(attrs = {})
    ContributorAdjustment.new({ ledger: @ledger, amount: 100, effective_on: Date.today, qbo_account: @sanctuary_qa }.merge(attrs))
  end

  test "payable when no qbo invoice" do
    adj = new_adj(qbo_invoice_id: nil)
    assert adj.payable?
  end

  test "not payable when invoice record missing" do
    adj = new_adj(qbo_invoice_id: "missing")
    # With qbo_account scoping, find_by now includes qbo_account_id.
    QboInvoice.expects(:find_by).with(qbo_id: "missing", qbo_account_id: @sanctuary_qa.id).returns(nil)
    assert_not adj.payable?
  end

  test "not payable for voided invoice" do
    inv = QboInvoice.new(qbo_id: "inv1")
    inv.stubs(:status).returns(:voided)
    QboInvoice.stubs(:find_by).with(qbo_id: "inv1", qbo_account_id: @sanctuary_qa.id).returns(inv)

    adj = new_adj(qbo_invoice_id: "inv1")
    assert_not adj.payable?
  end

  test "not payable until invoice fully paid" do
    inv = QboInvoice.new(qbo_id: "inv1")
    inv.stubs(:status).returns(:partially_paid)
    QboInvoice.stubs(:find_by).with(qbo_id: "inv1", qbo_account_id: @sanctuary_qa.id).returns(inv)

    adj = new_adj(qbo_invoice_id: "inv1")
    assert_not adj.payable?
  end

  test "payable when invoice is paid" do
    inv = QboInvoice.new(qbo_id: "inv1")
    inv.stubs(:status).returns(:paid)
    QboInvoice.stubs(:find_by).with(qbo_id: "inv1", qbo_account_id: @sanctuary_qa.id).returns(inv)

    adj = new_adj(qbo_invoice_id: "inv1")
    assert adj.payable?
  end

  test "not payable when qbo_invoice_id references a non-existent invoice in qbo_account" do
    adj = new_adj(qbo_invoice_id: "GHOST#{SecureRandom.hex(3)}")
    refute adj.payable?, "should be false when qbo_invoice does not exist in the qbo_account"
  end
end
