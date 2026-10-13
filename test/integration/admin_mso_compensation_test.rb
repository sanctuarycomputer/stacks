require "test_helper"

class AdminMsoCompensationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  MONTH = Date.new(2094, 3, 1)

  setup do
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @admin = mso_admin
    @lead = AdminUser.create!(email: "mso-ui-lead-#{SecureRandom.hex(3)}@example.com", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    @exec = mso_person("ui-exec")
    @other = mso_person("ui-other")
    @exec_login = login_for(@exec)
    @other_login = login_for(@other)
    role = mso_role(@exec)
    other_role = mso_role(@other, tier: :principal)
    @ledger = garden3d_ledger(@exec)
    @other_ledger = garden3d_ledger(@other)
    @report = mso_report(MONTH)
    @report.update!(blueprint: {
      "generated_at" => "2094-04-02T09:00:00+00:00", "fee_income" => "100000.0", "cap_percentage" => "0.55",
      "cap" => "55000.0", "benchmark_average" => "20000.0", "configured_n" => 3, "counted" => 3,
      "small_sample" => false, "total_calculated" => "7777.77", "total_trueup" => "7777.77",
      "reconciliation" => { "variance" => "0.0", "invoices" => [] }
    })
    @mine = mso_trueup(@report, role, @ledger, amount: "1234.56")
    @theirs = mso_trueup(@report, other_role, @other_ledger, amount: "6543.21")

    # No page here may reach QuickBooks or Twist.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
    Stacks::Notifications.stubs(:twist).returns(stub(add_comment_to_thread: nil))
  end

  teardown do
    clear_enterprise_memos
  end

  def assert_not_authorized
    # ActiveAdmin redirects an unauthorized user with a flash error. Asserting
    # both means a silently failed sign-in cannot pass.
    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
  end

  def accept(ledger, trueup)
    post toggle_acceptance_admin_ledger_mso_trueup_path(ledger, trueup)
  end

  # --- the monthly report --------------------------------------------------------

  test "an admin and a lead can both read a monthly report: the figures and every true-up" do
    [@admin, @lead].each do |viewer|
      sign_in viewer

      get admin_periodic_report_path(@report)

      assert_response :success
      assert_match(/MSO compensation/, response.body)
      assert_match(/100,000\.00/, response.body) # fee income
      assert_match(/55,000\.00/, response.body)  # the cap
      assert_match(/1,234\.56/, response.body)
      assert_match(/6,543\.21/, response.body)
      assert_includes response.body, admin_ledger_mso_trueup_path(@ledger, @mine)
      assert_no_match(/Profit Share/, response.body)
      sign_out viewer
    end
  end

  test "only an admin is offered the sync, and a monthly report offers no profit share sync" do
    sign_in @admin
    get admin_periodic_report_path(@report)
    assert_includes response.body, sync_mso_trueups_admin_periodic_report_path(@report)
    assert_not_includes response.body, "sync_profit_shares"
    sign_out @admin

    sign_in @lead
    get admin_periodic_report_path(@report)
    assert_response :success
    assert_not_includes response.body, "sync_mso_trueups"
  end

  test "a monthly report that has not been synced, or whose sync failed, still renders" do
    sign_in @admin
    empty = mso_report(MONTH + 1.month)

    get admin_periodic_report_path(empty)
    assert_response :success
    assert_match(/No MSO true-ups for this month yet/, response.body)

    post sync_mso_trueups_admin_periodic_report_path(empty) # 2094 has not happened yet
    assert_redirected_to admin_periodic_report_path(empty)
    assert_match(/recorded an error/, flash[:alert])

    get admin_periodic_report_path(empty)
    assert_response :success
    assert_match(/April 2094 has not ended/, response.body)
  end

  test "the reports index lists quarters by default and months on their own tab" do
    quarter = PeriodicReport.create!(period_gradation: :quarter, period_starts_at: Date.new(2094, 1, 1),
                                     period_label: "Q1, 2094")
    sign_in @lead

    get admin_periodic_reports_path
    assert_response :success
    assert_includes response.body, admin_periodic_report_path(quarter)
    assert_not_includes response.body, admin_periodic_report_path(@report)

    get admin_periodic_reports_path(scope: "monthly")
    assert_response :success
    assert_includes response.body, admin_periodic_report_path(@report)
    assert_not_includes response.body, admin_periodic_report_path(quarter)
  end

  # --- Sync MSO true-ups -----------------------------------------------------------

  test "an admin syncs the month's true-ups from the report" do
    PeriodicReport.any_instance.expects(:sync_mso_trueups!).once
    sign_in @admin

    post sync_mso_trueups_admin_periodic_report_path(@report)

    assert_redirected_to admin_periodic_report_path(@report)
    assert_match(/Sync completed/, flash[:notice])
  end

  test "an admin's sync of a real month writes the true-ups" do
    month = Date.new(2094, 5, 1)
    MsoRolePeriod.delete_all # setup's two executives; build_mso_month makes its own
    build_mso_month(month)
    report = mso_report(month)
    sign_in @admin

    travel_to Date.new(2094, 6, 10) do
      post sync_mso_trueups_admin_periodic_report_path(report)
    end

    assert_match(/Sync completed/, flash[:notice])
    assert_equal [BigDecimal("20000"), BigDecimal("23000")], report.mso_trueups.order(:amount).pluck(:amount)
  end

  test "a settled month says the sync was skipped" do
    [@mine, @theirs].each { |trueup| trueup.update_columns(accepted_at: Time.current) }
    Mso::MonthlyRun.expects(:compute).never
    sign_in @admin

    post sync_mso_trueups_admin_periodic_report_path(@report)

    assert_match(/Sync skipped/, flash[:notice])
  end

  test "a lead, an executive and someone with no role cannot post the sync, and nothing changes" do
    Mso::MonthlyRun.stubs(:compute).raises(RuntimeError, "a non-admin reached the computation")
    PeriodicReport.any_instance.expects(:sync_mso_trueups!).never
    before = MsoTrueup.order(:id).pluck(:id, :amount, :accepted_at, :updated_at)

    [@lead, @exec_login].each do |viewer|
      sign_in viewer
      refused =
        begin
          post sync_mso_trueups_admin_periodic_report_path(@report)
          response.redirect? && flash[:notice].blank?
        rescue AbstractController::ActionNotFound
          true # the action does not exist at all for someone who is not an admin
        end
      assert refused, "#{viewer.id} must not sync"
      sign_out viewer
    end

    assert_equal before, MsoTrueup.order(:id).pluck(:id, :amount, :accepted_at, :updated_at)
    assert_nil @report.reload.notification
  end

  test "each sync is refused on the other kind of report" do
    quarter = PeriodicReport.create!(period_gradation: :quarter, period_starts_at: Date.new(2094, 1, 1),
                                     period_label: "Q1, 2094")
    PeriodicReport.any_instance.expects(:sync_mso_trueups!).never
    PeriodicReport.any_instance.expects(:sync_profit_shares!).never
    sign_in @admin

    post sync_mso_trueups_admin_periodic_report_path(quarter)
    assert_match(/does not apply/, flash[:alert])

    post sync_profit_shares_admin_periodic_report_path(@report)
    assert_match(/does not apply/, flash[:alert])
  end

  # --- a true-up's own page ----------------------------------------------------------

  test "an executive can open their own true-up, and not another's" do
    sign_in @exec_login

    get admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_response :success
    assert_match(/1,234\.56/, response.body)
    assert_no_match(/6,543\.21/, response.body)

    get admin_ledger_mso_trueup_path(@other_ledger, @theirs)
    assert_not_authorized
  end

  test "someone who cannot read ledgers gets no true-up as JSON" do
    sign_in @other_login

    get admin_ledger_mso_trueup_path(@ledger, @mine, format: :json)

    assert_not response.successful?
    assert_no_match(/1234\.56/, response.body)
  end

  test "an executive can accept their own true-up and not another's" do
    sign_in @exec_login

    accept(@ledger, @mine)
    assert_response :redirect
    assert @mine.reload.accepted?

    accept(@other_ledger, @theirs)
    assert_not_authorized
    assert_not @theirs.reload.accepted?
  end

  # Both executives are admins in production. Seeing is one thing; accepting
  # on the other's behalf must be impossible, by URL as well.
  test "an admin cannot accept a true-up that is not theirs, not even another executive who is an admin" do
    @other_login.update!(roles: ["admin"])

    [@admin, AdminUser.find(@other_login.id)].each do |viewer|
      sign_in viewer
      get admin_ledger_mso_trueup_path(@ledger, @mine)
      assert_response :success, "an admin can still see it"
      assert_no_match(/toggle_acceptance/, response.body)

      accept(@ledger, @mine)

      assert_not_authorized
      assert_not @mine.reload.accepted?
      sign_out viewer
    end
  end

  test "a lead can open a true-up, like any ledger item, but not accept it" do
    sign_in @lead

    get admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_response :success

    accept(@ledger, @mine)
    assert_not_authorized
    assert_not @mine.reload.accepted?
  end

  test "a true-up with a QuickBooks bill cannot be un-accepted" do
    @mine.update_columns(accepted_at: Time.current, qbo_bill_id: "5")
    sign_in @exec_login

    accept(@ledger, @mine)

    assert_response :redirect
    assert_match(/QuickBooks bill/, flash[:alert])
    assert @mine.reload.accepted?
  end

  # --- what is gone ------------------------------------------------------------------

  test "the run action, the snapshot pages and the bill-removal action no longer exist" do
    helpers = Rails.application.routes.url_helpers
    %i[run_mso_compensation_admin_invoice_pass_path admin_mso_snapshots_path admin_mso_snapshot_path
       check_collection_admin_mso_snapshot_path remove_qbo_bill_admin_ledger_mso_trueup_path].each do |helper|
      assert_not helpers.respond_to?(helper), "#{helper} should be gone"
    end

    sign_in @admin
    get admin_invoice_pass_path(@pass)
    assert_response :success
    assert_no_match(/MSO compensation/, response.body)

    assert_raises(ActionController::RoutingError) { post "/admin/invoice_passes/#{@pass.id}/run_mso_compensation" }
    assert_raises(ActionController::RoutingError) do
      post "/admin/ledgers/#{@ledger.id}/mso_trueups/#{@mine.id}/remove_qbo_bill"
    end
  end
end
