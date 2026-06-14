require "test_helper"

class Money::PayableQboBillsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.create!(name: "PayableEnt-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "c", client_secret: "s", realm_id: "pq#{SecureRandom.hex(2)}")
    @vendor = QboVendor.create!(qbo_id: "VND-pq#{SecureRandom.hex(3)}", qbo_account: @qa, data: {})
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "pq#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[qbo])
  end

  test "returns rows only for hosts on qbo-enabled ledgers" do
    @ledger.update!(payment_methods: %w[deel])  # NOT qbo
    open_bill = QboBill.create!(qbo_account: @qa, qbo_id: "b1", qbo_vendor_id: @vendor.qbo_id, data: { "balance" => "100" })
    ca = ContributorAdjustment.create!(ledger: @ledger, qbo_account: @qa, amount: 100, effective_on: Date.current, qbo_bill_id: open_bill.qbo_id, description: "x")
    ContributorAdjustment.any_instance.stubs(:payable?).returns(true)

    rows = Money::PayableQboBills.call(qbo_account: @qa)
    refute rows.any? { |r| r.host == ca }
  end

  test "returns rows for payable hosts whose qbo_bill is open" do
    open_bill = QboBill.create!(qbo_account: @qa, qbo_id: "b2", qbo_vendor_id: @vendor.qbo_id, data: { "balance" => "100" })
    ca = ContributorAdjustment.create!(ledger: @ledger, qbo_account: @qa, amount: 100, effective_on: Date.current, qbo_bill_id: open_bill.qbo_id, description: "y")
    ContributorAdjustment.any_instance.stubs(:payable?).returns(true)

    rows = Money::PayableQboBills.call(qbo_account: @qa)
    assert rows.any? { |r| r.host.id == ca.id && r.qbo_bill.qbo_id == "b2" }
  end

  test "excludes paid bills" do
    paid_bill = QboBill.create!(qbo_account: @qa, qbo_id: "b3", qbo_vendor_id: @vendor.qbo_id, data: { "balance" => "0" })
    ca = ContributorAdjustment.create!(ledger: @ledger, qbo_account: @qa, amount: 100, effective_on: Date.current, qbo_bill_id: paid_bill.qbo_id, description: "z")
    ContributorAdjustment.any_instance.stubs(:payable?).returns(true)

    rows = Money::PayableQboBills.call(qbo_account: @qa)
    refute rows.any? { |r| r.host.id == ca.id }
  end

  test "excludes non-payable hosts" do
    open_bill = QboBill.create!(qbo_account: @qa, qbo_id: "b4", qbo_vendor_id: @vendor.qbo_id, data: { "balance" => "100" })
    ca = ContributorAdjustment.create!(ledger: @ledger, qbo_account: @qa, amount: 100, effective_on: Date.current, qbo_bill_id: open_bill.qbo_id, description: "w")
    ContributorAdjustment.any_instance.stubs(:payable?).returns(false)

    rows = Money::PayableQboBills.call(qbo_account: @qa)
    refute rows.any? { |r| r.host.id == ca.id }
  end
end
