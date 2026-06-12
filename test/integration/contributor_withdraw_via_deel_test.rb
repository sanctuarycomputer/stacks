require "test_helper"

class ContributorWithdrawViaDeelTest < ActionDispatch::IntegrationTest
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "WVD-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "wvd#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[deel])

    dp_id = "dp#{SecureRandom.hex(2)}"
    DeelPerson.create!(deel_id: dp_id, data: {})
    @contract = DeelContract.create!(deel_id: "dc#{SecureRandom.hex(2)}", deel_person_id: dp_id, data: { "type" => "ongoing_time_based" })

    @admin = AdminUser.create!(email: "wvd#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
    sign_in @admin
  end

  test "POST withdraw_via_deel calls CreateForLedger on a deel-enabled ledger" do
    DeelInvoiceAdjustments::CreateForLedger.expects(:call).with(
      ledger: @ledger,
      amount: "100",
      contract_id: @contract.deel_id,
      description: "",
      date_submitted: anything,
      initiated_by: instance_of(AdminUser),
    ).returns(DeelInvoiceAdjustment.new)

    post withdraw_via_deel_admin_contributor_path(@contributor), params: {
      ledger_id: @ledger.id,
      amount: "100",
      contract_id: @contract.deel_id,
    }
    assert_response :redirect
  end

  test "POST withdraw_via_deel refuses on a non-deel ledger" do
    @ledger.update!(payment_methods: %w[qbo])
    DeelInvoiceAdjustments::CreateForLedger.expects(:call).never

    post withdraw_via_deel_admin_contributor_path(@contributor), params: {
      ledger_id: @ledger.id,
      amount: "100",
      contract_id: @contract.deel_id,
    }
    assert_response :redirect
  end

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
