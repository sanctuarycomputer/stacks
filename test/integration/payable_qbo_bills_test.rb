require "test_helper"

class PayableQboBillsTest < ActionDispatch::IntegrationTest
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.create!(name: "IntEnt-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "pgi#{SecureRandom.hex(2)}", client_secret: "s", realm_id: "r#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ip#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @ledger.update!(payment_methods: %w[qbo])

    @admin = AdminUser.create!(email: "pq#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
    sign_in @admin
  end

  test "GET payable_qbo_bills renders" do
    get admin_money_payable_qbo_bills_path(qbo_account_id: @qa.id)
    assert_response :success
    # Page shows enterprise name (since QboAccount has no name column).
    assert_match @enterprise.name, response.body
  end

  test "POST refresh_tab kicks off bulk refresh" do
    # Service now returns an array of [host, exception] failure pairs so the
    # controller can render a single aggregated alert instead of 500ing on
    # one bad bill. Returning [] = "everything succeeded".
    Money::RefreshPayableQboBills.expects(:call).with(qbo_account: instance_of(QboAccount)).returns([])
    post admin_money_refresh_tab_path(qbo_account_id: @qa.id)
    assert_response :redirect
  end

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
