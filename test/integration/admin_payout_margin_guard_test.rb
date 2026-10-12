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
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_match(/Could not calculate payouts: No project trackers found/, flash[:alert])
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

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
