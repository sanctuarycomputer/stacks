require "test_helper"

class AdminContributorMsoTrueupTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  # A month near today: the ledger page renders every month from June 2025 to
  # two months past its latest item.
  MONTH = Date.new(2026, 11, 1)

  setup do
    garden3d_qbo_account
    @pass = InvoicePass.find_or_create_by!(enterprise: garden3d, start_of_month: MONTH) { |pass| pass.data = {} }
    @admin = mso_admin
    @lead = AdminUser.create!(email: "ledger-lead-#{SecureRandom.hex(3)}@example.com", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
    @exec = mso_person("ledger-page-exec")
    @ledger = garden3d_ledger(@exec)
    role = mso_role(@exec, started_at: Date.new(2026, 10, 1))
    snapshot = mso_snapshot(@pass, lines: [mso_line(role, @ledger, trueup: "4321.09")])
    @trueup = mso_trueup(snapshot, role, @ledger, amount: "4321.09")

    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
  end

  teardown do
    clear_enterprise_memos
  end

  def ledger_page
    get admin_contributor_path(@exec, ledger: @ledger.id)
    assert_response :success
    response.body
  end

  test "who may see an executive's MSO true-ups" do
    assert_equal true, @exec.mso_trueups_visible_to?(@admin)
    assert_equal true, @exec.mso_trueups_visible_to?(login_for(@exec))
    assert_equal false, @exec.mso_trueups_visible_to?(@lead)
    assert_equal false, @exec.mso_trueups_visible_to?(login_for(mso_person("ledger-page-other")))
    assert_equal false, @exec.mso_trueups_visible_to?(nil)
  end

  test "the executive sees their true-up on their own ledger, with a way to accept it" do
    sign_in login_for(@exec)

    body = ledger_page

    assert_match(/4,321\.09/, body)
    assert_match(/Mso trueup/i, body)
    assert_includes body, ERB::Util.html_escape(
      toggle_acceptance_admin_ledger_mso_trueup_path(@ledger, @trueup, amount: "4321.09"),
    )
  end

  test "an admin sees it too, but is not offered the owner's Accept" do
    sign_in @admin

    body = ledger_page

    assert_match(/4,321\.09/, body)
    assert_not_includes body, "toggle_acceptance"
  end

  test "a lead sees neither the row nor its amount in any total" do
    sign_in @lead

    body = ledger_page

    assert_no_match(/4,321/, body)
    assert_no_match(/mso_trueups/, body)
    assert_no_match(/Mso trueup/i, body)
  end

  # The same page without ?ledger= is the "All" view, which also carries each
  # month's income in its Elevated/Standard Service badge; and the person's
  # user page carries their balance. Both are open to every lead.
  test "a lead does not see it on the All view or on the person's user page either" do
    sign_in @lead

    get admin_contributor_path(@exec)
    assert_response :success
    assert_no_match(/4,321/, response.body)
    assert_no_match(/mso_trueups/, response.body)
    assert_no_match(/Mso trueup/i, response.body)

    get admin_admin_user_path(login_for(@exec))
    assert_response :success
    assert_no_match(/4,321/, response.body)
    sign_out @lead

    # Not vacuous: the same two pages do show it to an admin.
    sign_in @admin
    get admin_contributor_path(@exec)
    assert_match(/4,321\.09/, response.body)
    get admin_admin_user_path(login_for(@exec))
    assert_match(/4,321\.09/, response.body)
  end

  # An unaccepted true-up shows in the tab's UNSETTLED pill (covered above).
  # Once it has a QuickBooks bill it is owed, and moves to the BALANCE pill.
  test "a billed true-up's balance pill on the ledger tab is for its owner and admins only" do
    vendor = QboVendor.create!(qbo_account: garden3d_qbo_account, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    QboBill.create!(qbo_account: garden3d_qbo_account, qbo_id: "8801", qbo_vendor_id: vendor.qbo_id,
                    data: { "balance" => "4321.09", "total_amt" => "4321.09" })
    @trueup.update_columns(accepted_at: Time.current, qbo_bill_id: "8801")
    ledger = Ledger.find(@ledger.id)
    assert_in_delta 4321.09, ledger.balance.to_f, 0.001
    assert_equal 0.0, ledger.unsettled.to_f, "sanity: only the balance pill can carry it"

    sign_in @lead
    [admin_contributor_path(@exec, ledger: @ledger.id), admin_contributor_path(@exec)].each do |path|
      get path
      assert_response :success
      assert_select "span.notifier--balance", count: 0
      assert_no_match(/4,321/, response.body)
    end
    sign_out @lead

    [@admin, login_for(@exec)].each do |viewer|
      sign_in viewer
      get admin_contributor_path(@exec, ledger: @ledger.id)
      assert_response :success
      assert_select "span.notifier--balance", text: "$4,321"
      sign_out viewer
    end
  end
end
