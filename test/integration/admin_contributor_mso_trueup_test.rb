require "test_helper"

class AdminContributorMsoTrueupTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  # A month near today: the ledger page renders every month from June 2025 to
  # two months past its latest item.
  MONTH = Date.new(2026, 11, 1)

  setup do
    garden3d_qbo_account
    InvoicePass.find_or_create_by!(enterprise: garden3d, start_of_month: MONTH) { |pass| pass.data = {} }
    @admin = mso_admin
    @lead = AdminUser.create!(email: "ledger-lead-#{SecureRandom.hex(3)}@example.com", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
    @exec = mso_person("ledger-page-exec")
    @ledger = garden3d_ledger(@exec)
    role = mso_role(@exec, started_at: Date.new(2026, 10, 1))
    @trueup = mso_trueup(mso_report(MONTH), role, @ledger, amount: "4321.09")

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

  test "the executive sees their true-up on their own ledger, with a way to accept it" do
    sign_in login_for(@exec)

    body = ledger_page

    assert_match(/4,321\.09/, body)
    assert_match(/Mso trueup/i, body)
    assert_includes body, ERB::Util.html_escape(
      toggle_acceptance_admin_ledger_mso_trueup_path(@ledger, @trueup),
    )
  end

  test "an admin sees it too, but is not offered the owner's Accept" do
    sign_in @admin

    body = ledger_page

    assert_match(/4,321\.09/, body)
    assert_not_includes body, "toggle_acceptance"
  end

  test "a lead sees it like any other ledger item, and is not offered the owner's Accept" do
    sign_in @lead

    body = ledger_page

    assert_match(/4,321\.09/, body)
    assert_match(/Mso trueup/i, body)
    assert_not_includes body, "toggle_acceptance"
  end

  # The same page without ?ledger= is the "All" view; the person's user page
  # carries their balance. Both are open to every lead.
  test "a lead sees it on the All view and on the person's user page too" do
    sign_in @lead

    get admin_contributor_path(@exec)
    assert_response :success
    assert_match(/4,321\.09/, response.body)

    get admin_admin_user_path(login_for(@exec))
    assert_response :success
    assert_match(/4,321\.09/, response.body)
  end

  # Once a true-up is payable and billed it is owed, and moves from the tab's
  # UNSETTLED pill to its BALANCE pill.
  test "a payable, billed true-up shows in the ledger tab's balance pill for everyone who can open the page" do
    InvoicePass.any_instance.stubs(:management_fee_collected?).returns(true)
    vendor = QboVendor.create!(qbo_account: garden3d_qbo_account, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    QboBill.create!(qbo_account: garden3d_qbo_account, qbo_id: "8801", qbo_vendor_id: vendor.qbo_id,
                    data: { "balance" => "4321.09", "total_amt" => "4321.09" })
    @trueup.update_columns(accepted_at: Time.current, qbo_bill_id: "8801")
    ledger = Ledger.find(@ledger.id)
    assert_in_delta 4321.09, ledger.balance.to_f, 0.001
    assert_equal 0.0, ledger.unsettled.to_f, "sanity: only the balance pill can carry it"

    [@lead, @admin, login_for(@exec)].each do |viewer|
      sign_in viewer
      get admin_contributor_path(@exec, ledger: @ledger.id)
      assert_response :success
      assert_select "span.notifier--balance", text: "$4,321"
      sign_out viewer
    end
  end

  test "the ledger says why a true-up is not ready to pay: acceptance, fee invoices and vendor apart" do
    sign_in login_for(@exec)

    body = ledger_page

    assert_match(/MSO Acceptance\s*<span class="split">Some Pending/, body)
    assert_match(/Fee Invoices\s*<span class="split">Unpaid/, body)
    assert_match(/QBO Vendor\s*<span class="split">Missing/, body)
  end

  test "the true-up page shows each status as its own pill, the vendor without a bill, and what is missing" do
    vendor = QboVendor.create!(qbo_account: garden3d_qbo_account, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    ContributorQboVendor.create!(contributor: @exec, qbo_vendor: vendor, qbo_account: garden3d_qbo_account)
    @trueup.update_columns(accepted_at: Time.current)
    sign_in login_for(@exec)

    get admin_ledger_mso_trueup_path(@ledger, @trueup)
    assert_response :success

    assert_select "p.pill.nag.accepted", text: "Accepted"
    assert_select "p.pill.nag.accepted", text: "All Accepted"
    assert_select "p.pill.nag.pending", text: "Fee Invoices Unpaid"
    assert_includes response.body, vendor.qbo_url
    assert_not_includes response.body, "No QBO Vendor"
    assert_includes response.body, "management fee invoices for the month have to be paid"
    assert_not_includes response.body, "Everyone on the team has to accept"
  end
end
