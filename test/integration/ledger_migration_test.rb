require "test_helper"

class LedgerMigrationTest < ActionDispatch::IntegrationTest
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.create!(name: "MigPanel-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "mp#{SecureRandom.hex(2)}", client_secret: "s", realm_id: "r#{SecureRandom.hex(2)}")
    @qbo_vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "v#{SecureRandom.hex(2)}", data: { "balance" => "0.0" })
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "mp#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    # New ledgers default to :qbo_bound, but the operator-driven migration flow
    # only exists for legacy ledgers — pin this fixture to legacy so the flip
    # action has work to do.
    @ledger.update!(mode: :legacy)
    ContributorQboVendor.create!(contributor: @contributor, qbo_account: @qa, qbo_vendor: @qbo_vendor)

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

  test "Migrate refuses to flip a ledger that does not match QBO vendor balance" do
    not_ready = Ledgers::QboBoundMigrationCheck::Result.new(
      current_balance: 0, current_unsettled: 0,
      proposed_balance: 100, proposed_unsettled: 0,
      balance_delta: 100, unsettled_delta: 0,
      stacks_open_total: 100, qbo_vendor_balance: 0, qbo_diff: 100,
      qbo_match?: false, qbo_vendor_missing?: false,
      ready?: false, removed_neg_cas: [], removed_dias: [], dropped_paid_hosts: [], open_qbo_bills: [],
    )
    Ledgers::QboBoundMigrationCheck.expects(:call).with(@ledger).returns(not_ready)

    post migrate_to_qbo_bound_admin_ledger_path(@ledger)
    assert_response :redirect
    @ledger.reload
    assert @ledger.legacy?
  end

  test "Refresh QBO vendor data calls sync_all_vendors! and redirects" do
    QboAccount.any_instance.expects(:sync_all_vendors!).once
    post refresh_qbo_vendor_admin_ledger_path(@ledger)
    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
