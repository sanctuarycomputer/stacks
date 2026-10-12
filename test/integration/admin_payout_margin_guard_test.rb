require "test_helper"

class AdminPayoutMarginGuardTest < ActionDispatch::IntegrationTest
  include PayoutFixtures

  setup do
    setup_payout_people
    build_tracker("new_deal_v1")
    sign_in @creator
  end

  def within_cap_tracker
    build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
  end

  def breaching_tracker
    @project.update!(notes: "#{@ic.email}:90p/h")
    build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }]) # 9000 + 800 + 500 vs 7000
  end

  test "within the cap: payouts are generated" do
    it = within_cap_tracker
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_equal "Payouts processed!", flash[:notice]
    assert_equal 3, it.contributor_payouts.count
  end

  test "over the cap: nothing is written and the admin is sent to the overlay" do
    it = breaching_tracker
    assert InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(it)).breached?, "fixture must breach"

    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    end
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
  end

  test "force without a reason writes nothing" do
    it = breaching_tracker
    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "   " }
    end
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_match(/reason is required/i, flash[:alert])
    assert_nil it.reload.notes
  end

  test "force with a reason generates and records the override in the notes" do
    it = breaching_tracker
    it.update!(notes: "Existing note")
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "Agreed fixed fee with the contractor" }

    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_equal 3, it.contributor_payouts.count
    assert_in_delta 10_300.0, it.contributor_payouts.sum(:amount).to_f, 0.01
    notes = it.reload.notes
    assert notes.start_with?("Existing note\n\n"), notes
    assert_match(/\[\d{4}-\d{2}-\d{2}\] #{Regexp.escape(@creator.email)} generated payouts over the cap \(103\.0% vs 70\.0%\): Agreed fixed fee with the contractor/, notes)
  end

  test "non-admins cannot generate payouts" do
    it = within_cap_tracker
    delete destroy_admin_user_session_path
    lead = AdminUser.create!(email: "lead-guard@example.com", password: "password123", password_confirmation: "password123")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    sign_in lead

    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    end
    assert_equal "Admins only.", flash[:alert]
  end

  test "a build failure is reported, not a 500" do
    it = within_cap_tracker
    ProjectTrackerForecastProject.delete_all
    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    end
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_match(/Could not calculate payouts: No project trackers found/, flash[:alert])
  end

  test "a falsy force param is not a force" do
    it = breaching_tracker
    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "0", override_reason: "x" }
    end
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_nil it.reload.notes
  end

  test "an invoice with no QBO invoice says so and writes nothing" do
    it = within_cap_tracker
    InvoiceTracker.any_instance.stubs(:qbo_invoice).returns(nil)
    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    end
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_equal "This invoice has no QBO invoice yet, so there is nothing to pay out.", flash[:alert]
    assert_not_equal "Payouts processed!", flash[:notice]
  end

  test "a forced generate that fails after writing rolls the payouts back" do
    it = breaching_tracker
    InvoiceTracker.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(InvoiceTracker.new))
    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "Agreed fee" }
    end
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_match(/Could not calculate payouts/, flash[:alert])
  end

  test "a non-admin cannot smuggle skip_seventy_percent_check through update" do
    it = within_cap_tracker
    it.make_contributor_payouts!(@creator)
    cp = it.contributor_payouts.find { |c| c.contributor.forecast_person == @ic }
    delete destroy_admin_user_session_path
    lead = AdminUser.create!(email: "lead2-guard@example.com", password: "password123", password_confirmation: "password123")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    sign_in lead

    patch admin_invoice_tracker_contributor_payout_path(it, cp), params: { contributor_payout: { amount: 9000, skip_seventy_percent_check: "1" } }
    assert_in_delta 5700.0, cp.reload.amount.to_f, 0.01

    delete destroy_admin_user_session_path
    sign_in @creator
    patch admin_invoice_tracker_contributor_payout_path(it, cp), params: { contributor_payout: { amount: 9000, skip_seventy_percent_check: "1" } }
    assert_in_delta 9000.0, cp.reload.amount.to_f, 0.01, "an admin can still use the override"
  end

  test "a non-admin cannot rewrite a blueprint through update" do
    it = within_cap_tracker
    it.make_contributor_payouts!(@creator)
    cp = it.contributor_payouts.find { |c| c.contributor.forecast_person == @ic }
    assert cp.reload.blueprint["Commission"].blank?
    delete destroy_admin_user_session_path
    lead = AdminUser.create!(email: "lead3-guard@example.com", password: "password123", password_confirmation: "password123")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    sign_in lead

    blueprint = { "Commission" => [{ "amount" => 5000 }] }.to_json
    patch admin_invoice_tracker_contributor_payout_path(it, cp), params: { contributor_payout: { blueprint: blueprint } }
    assert cp.reload.blueprint["Commission"].blank?, "a lead's blueprint must be ignored"

    delete destroy_admin_user_session_path
    sign_in @creator
    patch admin_invoice_tracker_contributor_payout_path(it, cp), params: { contributor_payout: { blueprint: blueprint, skip_seventy_percent_check: "1" } }
    assert_equal [{ "amount" => 5000 }], cp.reload.blueprint["Commission"], "an admin can still edit it"
  end

  test "a non-admin cannot skip the cap check on create" do
    it = within_cap_tracker
    it.make_contributor_payouts!(@creator)
    @ic2.ensure_contributor_exists!
    delete destroy_admin_user_session_path
    lead = AdminUser.create!(email: "lead4-guard@example.com", password: "password123", password_confirmation: "password123")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    sign_in lead

    # The controller's build_new_resource never assigns the parent tracker
    # (pre-existing), so over HTTP the model has no invoice_tracker and the
    # cap validation cannot even run. Hand it the tracker so the strip is
    # the only thing standing between the flag and the cap.
    ContributorPayout.any_instance.stubs(:invoice_tracker).returns(it)
    assert_no_difference "ContributorPayout.with_deleted.count" do
      post admin_invoice_tracker_contributor_payouts_path(it), params: { contributor_payout: { contributor_id: @ic2.reload.contributor.id, amount: 9000, skip_seventy_percent_check: "1" } }
    end
    assert_match(/may not exceed/, response.body, "the cap validation, not something else, must be what blocked it")
  end

  test "the overlay lists every line with its roles and the override form" do
    it = breaching_tracker
    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success

    assert_select ".full-screen-modal.margin-breach" do
      assert_select "h2", text: /The generated payouts would be 103\.0% of gross earnings\. The cap for this invoice is 70\.0%\./
      assert_select "tr.margin-breach__line", 1
      assert_select "tr.margin-breach__line.over", 1
      assert_select "tr.margin-breach__entry", 3
      assert_select "tr.margin-breach__entry", text: /rate override/
      assert_select "tr.margin-breach__entry", text: /#{Regexp.escape(@ic.email)}/
      assert_select "form[action=?][method=post]", make_payouts_admin_invoice_tracker_contributor_payouts_path(it) do
        assert_select "input[name=force][value='1']"
        assert_select "textarea[name=override_reason][required]"
        assert_select "input[type=submit][value='Generate anyway']"
      end
      assert_select "a[href=?]", admin_invoice_tracker_contributor_payouts_path(it), text: /Close/
    end
    assert_select ".margin-breach tr.margin-breach__entry", text: /not paid out/, count: 0
    assert_match "$10,300.00", response.body
    assert_match "$7,000.00", response.body
    assert_match "$3,300.00", response.body
  end

  test "no overlay when the invoice is within its cap, even with the flag" do
    it = within_cap_tracker
    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success
    assert_select ".margin-breach", 0
  end

  test "no overlay without the flag" do
    it = breaching_tracker
    get admin_invoice_tracker_contributor_payouts_path(it)
    assert_response :success
    assert_select ".margin-breach", 0
  end

  test "no overlay, and no error, when the build cannot be computed" do
    it = breaching_tracker
    ProjectTrackerForecastProject.delete_all
    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success
    assert_select ".margin-breach", 0
  end

  test "non-admins never see the overlay" do
    it = breaching_tracker
    delete destroy_admin_user_session_path
    viewer = AdminUser.create!(email: "viewer-guard@example.com", password: "password123", password_confirmation: "password123")
    PermissionGrant.create!(admin_user: viewer, permission: "lead") # a lead can read the index; a bare user is redirected
    sign_in viewer

    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success
    assert_select ".margin-breach", 0
    assert_no_match(/rate override/, response.body)
  end

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
