require "test_helper"

class AdminAuthorizationManagementFeeTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2094, 6, 1))
    @payer = make_payer("Auth Payer #{SecureRandom.hex(3)}")
    @fee_tracker = fee_tracker(@pass, @payer)

    @admin = AdminUser.create!(email: "fee-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "fee-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
  end

  def teardown
    clear_enterprise_memos
  end

  def auth_for(user)
    AdminAuthorization.new(nil, user)
  end

  def sanctuary_tracker
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 6, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 970_010, name: "External Co")
    InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id, qbo_account: sanctuary_qa)
  end

  test "only an admin may update or regenerate a management fee invoice tracker" do
    %i[update attempt_generate].each do |action|
      assert auth_for(@admin).authorized?(action, @fee_tracker), "admin should #{action}"
      refute auth_for(@lead).authorized?(action, @fee_tracker), "a lead must not #{action}"
    end
    assert auth_for(@lead).authorized?(:read, @fee_tracker), "reading is unchanged"
  end

  test "a lead may still update and regenerate a Sanctuary tracker" do
    tracker = sanctuary_tracker

    assert auth_for(@lead).authorized?(:update, tracker)
    assert auth_for(@lead).authorized?(:attempt_generate, tracker)
  end

  test "a lead keeps update on a legacy garden3d tracker" do
    other = make_payer("Legacy Auth #{SecureRandom.hex(3)}")
    legacy = fee_tracker(@pass, other)
    legacy.update!(blueprint: { "lines" => {} })

    assert auth_for(@lead).authorized?(:update, legacy)
    assert auth_for(@lead).authorized?(:attempt_generate, legacy)
  end
end
