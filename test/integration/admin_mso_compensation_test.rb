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
    @lines = [mso_line(role, @ledger, trueup: "1234.56"), mso_line(other_role, @other_ledger, trueup: "6543.21")]
    @snapshot = mso_snapshot(@pass, lines: @lines)
    @mine = mso_trueup(@snapshot, role, @ledger, amount: "1234.56")
    @theirs = mso_trueup(@snapshot, other_role, @other_ledger, amount: "6543.21")

    # No page here may reach QuickBooks unless its test says so.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
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

  # Stacks' stored copy of a QuickBooks bill in garden3d's account.
  def stored_bill(qbo_id)
    vendor = QboVendor.create!(qbo_account: garden3d_qbo_account, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    QboBill.create!(qbo_account: garden3d_qbo_account, qbo_id: qbo_id, qbo_vendor_id: vendor.qbo_id,
                    data: { "balance" => "1234.56", "total_amt" => "1234.56" })
  end

  def accept(ledger, trueup, amount: trueup.amount.to_s("F"))
    post toggle_acceptance_admin_ledger_mso_trueup_path(ledger, trueup, amount: amount)
  end

  test "an admin can list snapshots and read one in full" do
    sign_in @admin

    get admin_mso_snapshots_path
    assert_response :success
    assert_match(/March 2094/, response.body)

    get admin_mso_snapshot_path(@snapshot)
    assert_response :success
    assert_match(/1,234\.56/, response.body)
    assert_match(/6,543\.21/, response.body)
    assert_match(/100,000\.00/, response.body) # fee income
    assert_match(/55,000\.00/, response.body)  # the cap
    assert_match(/Check collection/, response.body)
    assert_no_match(/NO LONGER VALID|more than the cap/, response.body)
    assert_no_match(/FIGURES HAVE MOVED|not finished when this month was run/i, response.body)
  end

  test "the snapshot page says what was unfinished at the run, and loudly what has moved since" do
    @snapshot.update_columns(
      run_warnings: {
        "incomplete_passes" => [{ "invoice_pass_id" => 7101, "enterprise_id" => enterprises(:sanctuary).id }],
        "unaccepted_payouts" => [{ "contributor_id" => @exec.id, "count" => 2, "contributor_payout_ids" => [7201, 7202] }],
      },
      income_drift: {
        "checked_at" => Time.current.iso8601,
        "lines" => [
          { "contributor_id" => @exec.id, "ledger_id" => @ledger.id, "stored" => "1234.56", "now" => "1000.0",
            "billed" => true },
          { "contributor_id" => @other.id, "ledger_id" => @other_ledger.id, "stored" => "6543.21", "now" => "6000.5",
            "billed" => false },
        ],
      },
    )
    sign_in @admin

    get admin_mso_snapshot_path(@snapshot)

    assert_response :success
    assert_match(/FIGURES HAVE MOVED SINCE THIS RUN/, response.body)
    assert_match(/1,000\.00/, response.body)
    assert_match(/6,000\.50/, response.body)
    assert_match(/Has a QuickBooks bill: a person decides/, response.body)
    assert_match(/No bill: run the month again/, response.body)
    assert response.body.index("FIGURES HAVE MOVED") < response.body.index("100,000.00"),
           "above the figures, not under them"
    assert_match(/Not finished when this month was run/, response.body)
    assert_match(/InvoicePass #7101/, response.body)
    assert_match(/2 unaccepted \(ContributorPayout 7201, 7202\)/, response.body)

    get admin_mso_snapshots_path
    assert_response :success
    assert_match(/2 true-up\(s\) have moved since the run/, response.body)
    assert_match(/unfinished at the run/, response.body)

    @snapshot.update_columns(income_drift: { "checked_at" => Time.current.iso8601, "lines" => [],
                                             "refused" => "a reconcile variance of 30000.0" })
    get admin_mso_snapshot_path(@snapshot)
    assert_match(/FIGURES HAVE MOVED SINCE THIS RUN/, response.body)
    assert_match(/a reconcile variance of 30000\.0/, response.body)
  end

  test "a superseded snapshot is drawn from its own lines; an invalid or over-cap one says so loudly" do
    @snapshot.update_columns(superseded_at: Time.current)
    replacement = MsoSnapshot.create!(
      invoice_pass: @pass, sanctuary_invoice_pass: @snapshot.sanctuary_invoice_pass, fee_income: "10000",
      benchmark_average: "20000.0", configured_n: 3, counted: 3, cap_percentage: "0.55", cap: "5500",
      total_calculated: "20000.0", total_trueup: "5500", total_trueup_as_billed: "7777.77", lines: @lines,
    )
    @snapshot.update_columns(superseded_by_id: replacement.id)
    replacement.invalidate!("Account 4100 now reads 9000.0")
    sign_in @admin

    get admin_mso_snapshot_path(@snapshot)
    assert_response :success
    assert_match(/1,234\.56/, response.body)
    assert_match(/As run; see the current snapshot/, response.body)
    assert_no_match(/>Missing</, response.body)
    assert_no_match(/Check collection/, response.body)

    get admin_mso_snapshot_path(replacement)
    assert_response :success
    assert_match(/NO LONGER VALID/, response.body)
    assert_match(/Account 4100 now reads 9000\.0/, response.body)
    assert_match(/more than the cap/, response.body)
    assert_match(/7,777\.77/, response.body)
    assert_no_match(/Check collection/, response.body)
  end

  test "a lead cannot list or open a snapshot" do
    sign_in @lead

    get admin_mso_snapshots_path
    assert_not_authorized

    get admin_mso_snapshot_path(@snapshot)
    assert_not_authorized
  end

  test "an executive can open their own true-up, and neither another's nor the snapshot" do
    sign_in @exec_login

    get admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_response :success
    assert_match(/1,234\.56/, response.body)
    assert_no_match(/6,543\.21/, response.body)

    get admin_ledger_mso_trueup_path(@other_ledger, @theirs)
    assert_not_authorized

    get admin_mso_snapshot_path(@snapshot)
    assert_not_authorized
  end

  test "someone who cannot read ledgers gets no true-up as JSON, and a lead gets no snapshot" do
    sign_in @other_login
    get admin_ledger_mso_trueup_path(@ledger, @mine, format: :json)
    assert_not response.successful?
    assert_no_match(/1234\.56/, response.body)
    sign_out @other_login

    sign_in @lead
    get admin_mso_snapshot_path(@snapshot, format: :json)
    assert_not response.successful?
    assert_no_match(/1234\.56|6543\.21/, response.body)
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

  # Both executives are admins in production. Seeing is one thing (unchanged);
  # accepting on the other's behalf must be impossible, by URL as well.
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

  test "accepting a figure that has changed since the page was shown is refused" do
    sign_in @exec_login

    accept(@ledger, @mine, amount: "999.99")
    assert_response :redirect
    assert_match(/not the figure you were shown/, flash[:alert])
    assert_not @mine.reload.accepted?

    post toggle_acceptance_admin_ledger_mso_trueup_path(@ledger, @mine) # no amount at all
    assert_response :redirect
    assert_match(/accept it from there/, flash[:alert])
    assert_not @mine.reload.accepted?
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

  test "an admin can remove a true-up's QuickBooks bill, and a paid bill is refused with the reason" do
    @mine.update_columns(accepted_at: Time.current, qbo_bill_id: "5")
    stored_bill("5")
    sign_in @admin

    # The real guard runs: it reads the bill (no payment on it), then deletes
    # it in QuickBooks exactly once and clears the row's link to it. The page
    # reports a removal only when that link is really gone.
    QboAccount.any_instance.stubs(:fetch_bill_by_id).with("5")
      .returns(stub(balance: BigDecimal("1234.56"), total_amt: BigDecimal("1234.56")))
    QboAccount.any_instance.expects(:delete_bill).once
    post remove_qbo_bill_admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_response :redirect
    assert_match(/removed/, flash[:notice])
    assert_nil flash[:alert]
    assert_not @mine.reload.locked?
    assert_not @mine.accepted?, "it must be accepted afresh after the next run"
    assert @snapshot.reload.invalidated?

    @mine.update_columns(accepted_at: Time.current, qbo_bill_id: "5")
    MsoTrueup.any_instance.expects(:detach_and_destroy_qbo_bill).once
      .raises(SyncsAsQboBill::PaidQboBillError, "refusing to destroy QBO bill 5")
    post remove_qbo_bill_admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_response :redirect
    assert_match(/refusing to destroy/, flash[:alert])
    assert @mine.reload.locked?
    assert @mine.accepted?, "a refused removal changes nothing"

    sign_out @admin
    sign_in @exec_login
    post remove_qbo_bill_admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_not_authorized
    assert @mine.reload.locked?
  end

  # The guard returns without a word when Stacks holds no stored copy of the
  # bill: nothing is read from QuickBooks, nothing is deleted, and the row
  # still points at the bill. That must never be reported as a removal.
  test "a bill that was not actually removed is reported as a failure, not a success" do
    @mine.update_columns(accepted_at: Time.current, qbo_bill_id: "5")
    assert_nil MsoTrueup.find(@mine.id).qbo_bill, "no stored copy of the bill"
    QboAccount.any_instance.expects(:delete_bill).never
    sign_in @admin

    post remove_qbo_bill_admin_ledger_mso_trueup_path(@ledger, @mine)

    assert_redirected_to admin_ledger_mso_trueup_path(@ledger, @mine)
    assert_nil flash[:notice]
    assert_match(/NOT removed/, flash[:alert])
    assert_match(/bill 5/, flash[:alert])
    assert @mine.reload.locked?, "the bill is still in QuickBooks and the row still points at it"
    assert_equal true, @mine.payable?, "and it still counts as owed"
  end

  test "an executive who is not an admin can reach nothing but their own true-up" do
    sign_in @exec_login
    Mso::MonthlyRun.stubs(:call).raises(RuntimeError, "a non-admin reached the run")
    Mso::IntercompanyInvoices.stubs(:collected?).raises(RuntimeError, "a non-admin reached QuickBooks")
    Mso::IntercompanyInvoices.stubs(:refresh!).raises(RuntimeError, "a non-admin reached QuickBooks")
    @snapshot.update_columns(fee_collected_at: Time.current)

    get admin_mso_snapshots_path
    assert_not_authorized

    post run_mso_compensation_admin_invoice_pass_path(@pass)
    assert_not_authorized

    post check_collection_admin_mso_snapshot_path(@snapshot)
    assert_not_authorized

    post refresh_intercompany_invoices_admin_invoice_pass_path(@pass)
    assert_not_authorized
    assert @snapshot.reload.fee_collected?, "a refused request withdraws nothing"

    post remove_qbo_bill_admin_ledger_mso_trueup_path(@other_ledger, @theirs)
    assert_not_authorized
  end

  # --- Refresh from QuickBooks withdraws "the fee was collected" -------------

  test "refreshing the pass's invoices withdraws the collection stamp" do
    @snapshot.update_columns(fee_collected_at: Time.current)
    run = Mso::IntercompanyInvoices::RefreshRun.new(attempted: 1, succeeded: 1, detached: 0, failed: [])
    Mso::IntercompanyInvoices.expects(:refresh!).once.returns(run)
    sign_in @admin

    post refresh_intercompany_invoices_admin_invoice_pass_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/Refreshed 1 of 1/, flash[:notice])
    assert_not @snapshot.reload.fee_collected?
  end

  # Fail closed: a refresh that stops part-way may already have rewritten or
  # detached an invoice. The stamp goes whether it is refused or blows up.
  test "a refresh that raises still withdraws the collection stamp" do
    sign_in @admin

    @snapshot.update_columns(fee_collected_at: Time.current)
    Mso::IntercompanyInvoices.stubs(:refresh!).raises(Mso::IntercompanyInvoices::Error, "QuickBooks said no")
    post refresh_intercompany_invoices_admin_invoice_pass_path(@pass)
    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/QuickBooks said no/, flash[:alert])
    assert_not @snapshot.reload.fee_collected?

    @snapshot.update_columns(fee_collected_at: Time.current)
    Mso::IntercompanyInvoices.stubs(:refresh!).raises(RuntimeError, "connection reset half-way")
    assert_raises(RuntimeError) { post refresh_intercompany_invoices_admin_invoice_pass_path(@pass) }
    assert_not @snapshot.reload.fee_collected?
  end

  test "an admin runs the month from garden3d's pass and lands on the snapshot" do
    sign_in @admin

    get admin_invoice_pass_path(@pass)
    assert_response :success
    assert_match(/Run MSO compensation/, response.body)

    Mso::MonthlyRun.expects(:call).with(invoice_pass: @pass, run_by: @admin).once.returns(@snapshot)
    post run_mso_compensation_admin_invoice_pass_path(@pass)

    assert_redirected_to admin_mso_snapshot_path(@snapshot)
  end

  test "a refused run shows the reason on the pass" do
    sign_in @admin
    Mso::MonthlyRun.stubs(:call).raises(Mso::MonthlyRun::Refused, "March 2094 has not ended.")

    post run_mso_compensation_admin_invoice_pass_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/has not ended/, flash[:alert])
  end

  # Migrations are run by hand after the deploy.
  test "a run posted before the MSO tables exist says what to do instead of failing" do
    sign_in @admin
    MsoTrueup.stubs(:schema_ready?).returns(false)

    get admin_invoice_pass_path(@pass)
    assert_response :success
    assert_no_match(/Run MSO compensation/, response.body)

    post run_mso_compensation_admin_invoice_pass_path(@pass)

    assert_redirected_to admin_invoice_pass_path(@pass)
    assert_match(/migration/i, flash[:alert])
  end

  # Whether a lead can even open garden3d's pass is S1's rule (it is becoming
  # admin-only). The run has its own guard regardless.
  test "a lead cannot post the run or Check collection" do
    sign_in @lead
    Mso::MonthlyRun.stubs(:call).raises(RuntimeError, "a lead reached the run")
    Mso::IntercompanyInvoices.stubs(:collected?).raises(RuntimeError, "a lead reached QuickBooks")

    post run_mso_compensation_admin_invoice_pass_path(@pass)
    assert_not_authorized

    post check_collection_admin_mso_snapshot_path(@snapshot)
    assert_not_authorized
    assert_not @snapshot.reload.fee_collected?
  end

  test "Check collection asks QuickBooks once and records the answer" do
    sign_in @admin
    Mso::IntercompanyInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(true)

    post check_collection_admin_mso_snapshot_path(@snapshot)

    assert_redirected_to admin_mso_snapshot_path(@snapshot)
    assert_match(/collected/, flash[:notice])
    assert @snapshot.reload.fee_collected?
  end
end
