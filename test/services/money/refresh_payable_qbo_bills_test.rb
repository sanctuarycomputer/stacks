require "test_helper"

class Money::RefreshPayableQboBillsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.create!(name: "RefreshEnt-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "c", client_secret: "s", realm_id: "rfp#{SecureRandom.hex(2)}")
    @vendor = QboVendor.create!(qbo_id: "VND-rfp#{SecureRandom.hex(3)}", qbo_account: @qa, data: {})
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "rfp#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[qbo])

    @bill = QboBill.create!(qbo_account: @qa, qbo_id: "rfb1", qbo_vendor_id: @vendor.qbo_id, data: { "balance" => "100" })
    @ca = ContributorAdjustment.create!(ledger: @ledger, qbo_account: @qa, amount: 100, effective_on: Date.current, qbo_bill_id: @bill.qbo_id, description: "test")
  end

  test "calls sync_qbo_bill! on every row returned by PayableQboBills" do
    ContributorAdjustment.any_instance.stubs(:payable?).returns(true)
    ContributorAdjustment.any_instance.expects(:sync_qbo_bill!).at_least_once

    Money::RefreshPayableQboBills.call(qbo_account: @qa)
  end
end
