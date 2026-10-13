require "test_helper"

# The owner's decision: garden3d's invoice passes are admin-only to view. They
# hold what the operating companies pay garden3d. That covers every garden3d
# pass -- the seven legacy 2025 ones too -- every tracker on one, and the
# payouts pages that hang off such a tracker. Everything here goes by URL.
class AdminGarden3dPassesAdminOnlyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ManagementFeeFixtures

  setup do
    @admin = AdminUser.create!(email: "g3d-only-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "g3d-only-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
    @trainee = AdminUser.create!(email: "g3d-only-trainee@sanctuary.computer", password: "password12345")
    project = ProjectTracker.new(name: "Training Project")
    project.save!(validate: false)
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", subject: project)

    @qbo_account = garden3d_qbo_account
    @payer = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [981_001])

    # A management fee pass, its invoice sent for $130,000.
    @fee_pass = garden3d_pass(Date.new(2094, 7, 1))
    @fee = attach_invoice(fee_tracker(@fee_pass, @payer), qbo_id: "8300", total: "130000.0", balance: "130000.0",
                                                          sent: true)

    # A legacy garden3d pass: one Forecast-driven tracker, with a blueprint.
    @legacy_pass = garden3d_pass(Date.new(2094, 8, 1))
    legacy = attach_invoice(fee_tracker(@legacy_pass, @payer), qbo_id: "8301", total: "1000.0", balance: "1000.0",
                                                               sent: true)
    legacy.update!(blueprint: { "lines" => {} })
    @legacy = InvoiceTracker.find(legacy.id)

    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    @sanctuary_pass = InvoicePass.create!(start_of_month: Date.new(2094, 7, 1), enterprise: enterprises(:sanctuary),
                                          data: {})
    client = ForecastClient.create!(forecast_id: 981_010, name: "External Co")
    sanctuary = InvoiceTracker.create!(invoice_pass: @sanctuary_pass, forecast_client_id: client.forecast_id,
                                       qbo_account: sanctuary_qa, blueprint: { "lines" => {} })
    @sanctuary = attach_invoice(sanctuary, qbo_id: "sc-8302", total: "1000.0", balance: "1000.0", sent: true)

    # Nothing here may reach QuickBooks, Twist or Forecast.
    QboInvoice.any_instance.stubs(:sync!).returns(true)
    Stacks::Automator.stubs(:discover_people_missing_hours_for_month).returns([])
    InvoicePass.any_instance.expects(:make_trackers!).never
    Mso::IntercompanyInvoices.expects(:refresh!).never
    Mso::IntercompanyInvoices.expects(:push_invoice!).never
    Stacks::Twist.expects(:new).never
  end

  teardown do
    clear_enterprise_memos
  end

  def assert_denied(what)
    assert_response :redirect, what
    assert_match(/not authorized/i, flash[:error].to_s, what)
  end

  def tracker_path(tracker)
    admin_invoice_pass_invoice_tracker_path(tracker.invoice_pass, tracker)
  end

  def trackers_path(pass, **options)
    admin_invoice_pass_invoice_trackers_path(pass, **options)
  end

  # A contributor paid on the legacy garden3d tracker, as on the real 2025
  # passes: the payout is accepted.
  def paid_contributor
    user = AdminUser.create!(email: "g3d-only-payee@sanctuary.computer", password: "password12345")
    person = ForecastPerson.create!(forecast_id: 981_020, email: user.email, data: {})
    person.ensure_contributor_exists!
    contributor = person.reload.contributor
    ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: contributor)
    payout = ContributorPayout.create!(invoice_tracker: @legacy, ledger: ledger, amount: 100.0, created_by: @admin,
                                       accepted_at: Time.current, description: "Legacy garden3d payout")
    [AdminUser.find(user.id), contributor, payout]
  end

  # --- a lead, and a project-scoped grantee -----------------------------------

  { "a lead" => :@lead, "a project-scoped grantee" => :@trainee }.each do |who, ivar|
    test "#{who} is denied garden3d's pass pages, the legacy ones included" do
      sign_in instance_variable_get(ivar)

      [@fee_pass, @legacy_pass].each do |pass|
        get admin_invoice_pass_path(pass)
        assert_denied "#{pass.invoice_month} show"
        assert_no_match(/130,000/, response.body)

        get admin_invoice_pass_path(pass, format: :json)
        assert_no_match(/#{pass.start_of_month.iso8601}/, response.body, "#{pass.invoice_month} show as JSON")

        get trackers_path(pass)
        assert_denied "#{pass.invoice_month} trackers index"

        get trackers_path(pass, format: :json)
        assert_no_match(/8300|8301/, response.body, "#{pass.invoice_month} trackers index as JSON")

        get trackers_path(pass, format: :csv)
        assert_no_match(/8300|8301/, response.body, "#{pass.invoice_month} trackers index as CSV")

        post rerun_invoice_pass_without_reminders_admin_invoice_pass_path(pass)
        assert_denied "#{pass.invoice_month} generate invoices"

        post refresh_intercompany_invoices_admin_invoice_pass_path(pass)
        assert_denied "#{pass.invoice_month} refresh"
      end
    end

    test "#{who} is denied every page and action of a tracker on a garden3d pass" do
      user = instance_variable_get(ivar)
      sign_in user

      [@fee, @legacy].each do |tracker|
        pass = tracker.invoice_pass

        get tracker_path(tracker)
        assert_denied "show"
        assert_no_match(/130,000/, response.body)

        get admin_invoice_pass_invoice_tracker_path(pass, tracker, format: :json)
        assert_no_match(/#{tracker.qbo_invoice_id}/, response.body, "show as JSON")

        get edit_admin_invoice_pass_invoice_tracker_path(pass, tracker)
        assert_denied "edit"

        patch tracker_path(tracker), params: { invoice_tracker: { notes: "From a non-admin" } }
        assert_denied "update"

        post toggle_ownership_admin_invoice_pass_invoice_tracker_path(pass, tracker)
        assert_denied "toggle_ownership"

        post attempt_generate_admin_invoice_pass_invoice_tracker_path(pass, tracker)
        assert_denied "attempt_generate"

        post notify_reviewers_admin_invoice_pass_invoice_tracker_path(pass, tracker)
        assert_denied "notify_reviewers"

        post resync_qbo_line_item_services_admin_invoice_pass_invoice_tracker_path(pass, tracker)
        assert_denied "resync_qbo_line_item_services"

        tracker.reload
        assert_nil tracker.notes
        assert_nil tracker.admin_user_id, "not claimed"
      end
    end

    test "#{who} does not see garden3d's passes in the passes index, in any format" do
      sign_in instance_variable_get(ivar)

      get admin_invoice_passes_path

      assert_response :success
      assert_select "a[href=?]", trackers_path(@sanctuary_pass), count: 1
      assert_select "a[href=?]", trackers_path(@fee_pass), count: 0
      assert_select "a[href=?]", trackers_path(@legacy_pass), count: 0
      assert_no_match(/garden3d/, response.body)
      assert_no_match(/130,000/, response.body)

      get admin_invoice_passes_path(format: :json)
      assert_no_match(/"id":\s*(#{@fee_pass.id}|#{@legacy_pass.id})\b/, response.body)

      get admin_invoice_passes_path(format: :csv)
      assert_no_match(/^(#{@fee_pass.id}|#{@legacy_pass.id}),/, response.body)
    end
  end

  # --- a lead on Sanctuary's passes: unchanged ---------------------------------

  test "Sanctuary's pass and its tracker are unchanged for a lead" do
    sign_in @lead

    get admin_invoice_pass_path(@sanctuary_pass)
    assert_response :success

    get trackers_path(@sanctuary_pass)
    assert_response :success
    assert_match(/External Co/, response.body)

    get tracker_path(@sanctuary)
    assert_response :success

    get edit_admin_invoice_pass_invoice_tracker_path(@sanctuary_pass, @sanctuary)
    assert_response :success

    patch tracker_path(@sanctuary), params: { invoice_tracker: { notes: "From a lead" } }
    assert_equal "From a lead", @sanctuary.reload.notes

    post toggle_ownership_admin_invoice_pass_invoice_tracker_path(@sanctuary_pass, @sanctuary)
    assert_equal @lead.id, @sanctuary.reload.admin_user_id
  end

  test "a project-scoped grantee can still open a Sanctuary pass" do
    sign_in @trainee

    get admin_invoice_pass_path(@sanctuary_pass)

    assert_response :success
  end

  test "asking for garden3d's tab by URL shows a lead nothing" do
    sign_in @lead

    get admin_invoice_passes_path(scope: "garden3d")

    assert_response :success
    [@sanctuary_pass, @fee_pass, @legacy_pass].each do |pass|
      assert_select "a[href=?]", trackers_path(pass), count: 0
    end
    assert_select "a[href=?]", admin_invoice_passes_path(scope: "garden3d"), count: 0
  end

  # --- an admin sees everything --------------------------------------------------

  test "an admin sees garden3d's passes in the index and can open every one of their pages" do
    sign_in @admin

    # One tab per enterprise: Sanctuary's by default, garden3d's on its own.
    get admin_invoice_passes_path

    assert_response :success
    assert_select "a[href=?]", trackers_path(@sanctuary_pass), count: 1
    [@fee_pass, @legacy_pass].each do |pass|
      assert_select "a[href=?]", trackers_path(pass), count: 0
    end
    assert_select "a[href=?]", admin_invoice_passes_path(scope: "garden3d"), count: 1

    get admin_invoice_passes_path(scope: "garden3d")

    assert_response :success
    assert_select "a[href=?]", trackers_path(@sanctuary_pass), count: 0
    [@fee_pass, @legacy_pass].each do |pass|
      assert_select "a[href=?]", trackers_path(pass), count: 1
    end

    # The index pages turn their download links off, and ActiveAdmin then
    # refuses the index in any other format, to everyone. So JSON and CSV are
    # not a way round the HTML index for anybody.
    [admin_invoice_passes_path(format: :json), admin_invoice_passes_path(format: :csv),
     trackers_path(@fee_pass, format: :json), trackers_path(@fee_pass, format: :csv)].each do |path|
      get path
      assert_includes [401, 302], response.status, path
      assert_no_match(/130000|8300/, response.body, path)
    end

    get admin_invoice_pass_path(@fee_pass)
    assert_response :success
    assert_match(/\$130,000\.00/, response.body)

    get admin_invoice_pass_path(@legacy_pass)
    assert_response :success

    [@fee, @legacy].each do |tracker|
      get trackers_path(tracker.invoice_pass)
      assert_response :success

      get tracker_path(tracker)
      assert_response :success

      get edit_admin_invoice_pass_invoice_tracker_path(tracker.invoice_pass, tracker)
      assert_response :success

      patch tracker_path(tracker), params: { invoice_tracker: { notes: "From an admin" } }
      assert_equal "From an admin", tracker.reload.notes
    end
  end

  # --- the payouts pages under a garden3d tracker ------------------------------
  # Only the legacy trackers have payouts (a management fee invoice never
  # does). They follow the tracker: admin-only, except that a contributor can
  # still read their own payout.

  test "a lead is denied the payouts pages under a garden3d tracker" do
    _user, _contributor, payout = paid_contributor
    sign_in @lead

    [@legacy, @fee].each do |tracker|
      get admin_invoice_tracker_contributor_payouts_path(tracker)
      assert_denied "index"

      get admin_invoice_tracker_contributor_payouts_path(tracker, format: :json)
      assert_no_match(/Legacy garden3d payout/, response.body)

      get new_admin_invoice_tracker_contributor_payout_path(tracker)
      assert_denied "new"

      post make_payouts_admin_invoice_tracker_contributor_payouts_path(tracker)
      assert_denied "make_payouts"
    end

    get admin_invoice_tracker_contributor_payout_path(@legacy, payout)
    assert_denied "show"

    get edit_admin_invoice_tracker_contributor_payout_path(@legacy, payout)
    assert_denied "edit"

    patch admin_invoice_tracker_contributor_payout_path(@legacy, payout), params: { contributor_payout: { amount: 5 } }
    assert_denied "update"

    delete admin_invoice_tracker_contributor_payout_path(@legacy, payout)
    assert_denied "destroy"

    post toggle_acceptance_admin_invoice_tracker_contributor_payout_path(@legacy, payout)
    assert_denied "toggle_acceptance"

    payout.reload
    assert_equal 100.0, payout.amount.to_f
    assert payout.accepted?
    assert_nil payout.deleted_at
  end

  test "an admin still reaches the payouts pages under a legacy garden3d tracker" do
    _user, _contributor, payout = paid_contributor
    sign_in @admin

    get admin_invoice_tracker_contributor_payouts_path(@legacy)
    assert_response :success

    get admin_invoice_tracker_contributor_payout_path(@legacy, payout)
    assert_response :success
  end

  test "a contributor paid on a legacy garden3d tracker still sees the payout on their own page" do
    user, contributor, payout = paid_contributor
    sign_in user

    get admin_contributor_path(contributor)

    assert_response :success
    assert_select "a[href=?]", admin_invoice_tracker_contributor_payout_path(@legacy, payout), count: 1
    assert_match(/August 01, 2094/, response.body)

    # Their own payout is theirs to read.
    get admin_invoice_tracker_contributor_payout_path(@legacy, payout)

    assert_response :success
    assert_match(/Legacy garden3d payout/, response.body)
    # ...with no button that could only be refused.
    assert_select "a[href*=?]", "toggle_contributor_payout_acceptance", count: 0
  end

  test "a lead still sees that payout row on the contributor's page" do
    _user, contributor, payout = paid_contributor
    sign_in @lead

    get admin_contributor_path(contributor)

    assert_response :success
    assert_select "a[href=?]", admin_invoice_tracker_contributor_payout_path(@legacy, payout), count: 1
  end

  test "that contributor cannot open the garden3d tracker, list its payouts, or change the acceptance" do
    user, _contributor, payout = paid_contributor
    sign_in user

    get tracker_path(@legacy)
    assert_denied "tracker show"

    get admin_invoice_tracker_contributor_payouts_path(@legacy)
    assert_denied "payouts index"

    post toggle_contributor_payout_acceptance_admin_invoice_pass_invoice_tracker_path(
      @legacy_pass, @legacy, contributor_payout_id: payout.id,
    )
    assert_denied "toggle through the tracker"

    post toggle_acceptance_admin_invoice_tracker_contributor_payout_path(@legacy, payout)
    assert_denied "toggle through the payout"

    # The index's own link passes the payout's id where the tracker's belongs.
    post toggle_acceptance_admin_invoice_tracker_contributor_payout_path(payout.id, payout)
    assert_denied "toggle through the payout, as the index links it"

    assert payout.reload.accepted?, "still accepted"
  end

  test "another contributor cannot read that payout" do
    _user, _contributor, payout = paid_contributor
    other = AdminUser.create!(email: "g3d-only-other@sanctuary.computer", password: "password12345")
    ForecastPerson.create!(forecast_id: 981_021, email: other.email, data: {}).ensure_contributor_exists!
    sign_in AdminUser.find(other.id)

    get admin_invoice_tracker_contributor_payout_path(@legacy, payout)

    assert_denied "another contributor's payout"
  end

  test "a contributor still accepts their own payout on a Sanctuary tracker" do
    user, contributor, _payout = paid_contributor
    ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: contributor)
    payout = ContributorPayout.create!(invoice_tracker: @sanctuary, ledger: ledger, amount: 100.0, created_by: @admin)
    sign_in user

    post toggle_contributor_payout_acceptance_admin_invoice_pass_invoice_tracker_path(
      @sanctuary_pass, @sanctuary, contributor_payout_id: payout.id,
    )

    assert payout.reload.accepted?
  end
end
