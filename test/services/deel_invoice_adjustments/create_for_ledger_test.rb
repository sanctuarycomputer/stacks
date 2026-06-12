require "test_helper"

class DeelInvoiceAdjustments::CreateForLedgerTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "DelegLed-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "del#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[deel])

    dp_id = "dp#{SecureRandom.hex(2)}"
    DeelPerson.create!(deel_id: dp_id, data: {})
    @contract = DeelContract.create!(deel_id: "dc#{SecureRandom.hex(2)}", deel_person_id: dp_id, data: { "type" => "ongoing_time_based" })

    @admin = AdminUser.create!(email: "dca#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
  end

  test "creates a DIA when Deel API call succeeds" do
    fake_response = { "data" => { "id" => "adj-42", "status" => "pending" } }
    DeelInvoiceAdjustment.expects(:create_from_deel_response!).with(
      ledger: @ledger,
      deel_contract_id: @contract.deel_id,
      amount: 100,
      description: "test",
      date_submitted: Date.current,
      parsed_response: fake_response,
    ).returns(DeelInvoiceAdjustment.new)

    DeelInvoiceAdjustments::CreateForLedger.any_instance.stubs(:call_deel_api).returns(fake_response)

    result = DeelInvoiceAdjustments::CreateForLedger.call(
      ledger: @ledger,
      amount: 100,
      contract_id: @contract.deel_id,
      description: "test",
      date_submitted: Date.current,
      initiated_by: @admin,
    )
    assert result.is_a?(DeelInvoiceAdjustment)
  end

  test "raises CreateForLedger::Error when Deel API returns no adjustment id" do
    DeelInvoiceAdjustments::CreateForLedger.any_instance.stubs(:call_deel_api).returns({ "data" => {} })

    assert_raises(DeelInvoiceAdjustments::CreateForLedger::Error) do
      DeelInvoiceAdjustments::CreateForLedger.call(
        ledger: @ledger,
        amount: 100,
        contract_id: @contract.deel_id,
        description: "test",
        date_submitted: Date.current,
        initiated_by: @admin,
      )
    end
  end
end
