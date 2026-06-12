require "test_helper"

class LedgerMigrationTest < ActionDispatch::IntegrationTest
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "MigPanel-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "mp#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)

    @admin = AdminUser.create!(
      email: "lmig#{SecureRandom.hex(2)}@example.com",
      password: "password123",
      password_confirmation: "password123",
      roles: ["admin"]
    )
    sign_in @admin
  end

  test "Migrate posts and flips ready ledger to qbo_bound" do
    assert @ledger.legacy?
    post migrate_to_qbo_bound_admin_ledger_path(@ledger)
    assert_response :redirect
    @ledger.reload
    assert @ledger.qbo_bound?
  end

  test "Migrate refuses to flip a ledger with non-zero drift" do
    not_ready = Ledgers::QboBoundMigrationCheck::Result.new(
      current_balance: 0, current_unsettled: 0,
      proposed_balance: 100, proposed_unsettled: 0,
      balance_delta: 100, unsettled_delta: 0,
      ready?: false, blocking_bills: [], ignored_negative_cas: [],
    )
    Ledgers::QboBoundMigrationCheck.expects(:call).with(@ledger).returns(not_ready)

    post migrate_to_qbo_bound_admin_ledger_path(@ledger)
    assert_response :redirect
    @ledger.reload
    assert @ledger.legacy?
  end

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
