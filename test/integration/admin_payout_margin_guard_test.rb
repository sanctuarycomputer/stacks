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
    assert_match(/Could not generate payouts: No project trackers found/, flash[:alert])
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
    assert_match(/Could not generate payouts/, flash[:alert])
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

  # A leftover payout for someone this invoice no longer pays. Its IC chunk
  # on line "1" is cheap enough to generate lead surplus while it stays:
  # margin 0.90 - 0.43 = 4,700, and 705 of it to each lead.
  def add_stale_payout(it)
    stranger = ForecastPerson.create!(forecast_id: 700_099, email: "stale-guard@example.com", data: {})
    stranger.ensure_contributor_exists!
    ledger = Ledger.find_or_create_for(enterprise: @client.billing_enterprise, contributor: stranger.reload.contributor)
    stale = ContributorPayout.new(
      invoice_tracker: it,
      ledger: ledger,
      amount: 1000.0,
      blueprint: { "IndividualContributor" => [{ "amount" => 1000.0, "blueprint_metadata" => { "id" => "1", "forecast_project" => @project.forecast_id, "forecast_person" => stranger.forecast_id } }] },
      created_by: @creator,
    )
    stale.skip_seventy_percent_check = true
    stale.save!
    stale
  end

  test "an unremovable stale payout that leaves the invoice over its cap writes nothing" do
    it = within_cap_tracker
    it.make_contributor_payouts!(@creator)
    stale = add_stale_payout(it)
    # A successful write would now pay the IC 100 hrs * $50, not 5700.
    @project.update!(notes: "#{@ic.email}:50p/h")
    before = it.contributor_payouts.reload.map { |cp| [cp.id, cp.amount.to_f, cp.deleted_at] }.sort
    assert_equal [500.0, 800.0, 1000.0, 5700.0], before.map { |row| row[1] }.sort
    ContributorPayout.any_instance.stubs(:detach_and_destroy_qbo_bill).raises(SyncsAsQboBill::PaidQboBillError, "cannot verify")

    assert_no_difference "ContributorPayout.with_deleted.count" do
      post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    end
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_match(/\ACould not generate payouts: Payouts would exceed the cap because an earlier payout \(##{stale.id}\) could not be removed/, flash[:alert])
    assert_not_equal "Payouts processed!", flash[:notice]
    assert_equal before, it.contributor_payouts.reload.map { |cp| [cp.id, cp.amount.to_f, cp.deleted_at] }.sort
    assert_nil it.reload.notes
  end

  # The cache said the stale payout's bill was paid, so the pre-flight judged
  # the invoice over its cap and the admin forced it. The delete then went
  # through: what was written is within the cap, and nothing was overridden.
  test "a forced generate that turns out within the cap records no override" do
    it = within_cap_tracker
    it.update!(notes: "Existing note")
    stale = add_stale_payout(it)
    bill = mock("qbo_bill")
    bill.stubs(:has_payments?).returns(true)
    ContributorPayout.any_instance.stubs(:qbo_bill).returns(bill)
    assert InvoicePayouts::MarginCheck.new(InvoicePayouts::Build.new(it)).breached?, "fixture must breach before the write"

    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert ContributorPayout.exists?(stale.id), "unforced, the pre-flight still stops it"

    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "Agreed fixed fee with the contractor" }

    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    assert_equal "Payouts processed!", flash[:notice]
    assert_not ContributorPayout.exists?(stale.id)
    assert_equal [500.0, 800.0, 5700.0], it.contributor_payouts.reload.map { |cp| cp.amount.to_f }.sort
    assert_equal 7000.0, it.contributor_payouts.sum { |cp| cp.amount.to_f }
    assert_equal "Existing note", it.reload.notes
  end

  # Forced on a prediction that was wrong the other way: the note quotes what
  # was written, survivor and its surplus included, not the pre-flight.
  test "a forced generate records the figures that were written, not the ones predicted" do
    it = breaching_tracker # 9000 + 800 + 500 = 10,300
    add_stale_payout(it)
    ContributorPayout.any_instance.stubs(:detach_and_destroy_qbo_bill).raises(SyncsAsQboBill::PaidQboBillError, "cannot verify")

    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "Agreed fee" }

    assert_redirected_to admin_invoice_tracker_contributor_payouts_path(it)
    # 10,300 + the survivor's 1000 + 2 * 705 surplus = 12,710
    assert_in_delta 12_710.0, it.contributor_payouts.reload.sum { |cp| cp.amount.to_f }, 0.01
    assert_match(/generated payouts over the cap \(127\.1% vs 70\.0%\): Agreed fee/, it.reload.notes)
  end

  test "with nothing billed after commissions the overlay quotes dollars, not percentages" do
    recipient = ForecastPerson.create!(forecast_id: 710_004, email: "comm-guard@example.com", data: {})
    recipient.ensure_contributor_exists!
    PercentageCommission.create!(project_tracker: ProjectTracker.last, contributor: recipient.reload.contributor, rate: 1.0)
    it = breaching_tracker # the whole 10,000 goes to commission; the IC is still paid 100 hrs * $90

    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success
    assert_select ".full-screen-modal.margin-breach tr.margin-breach__total" do
      assert_select "td", text: "$9,000.00"
      assert_select "td", text: /%/, count: 0
    end
  end

  test "a multi-line exception is flashed as its first line" do
    it = within_cap_tracker
    InvoicePayouts::Build.any_instance.stubs(:payees).raises(StandardError, "boom\n\n  some.code\n  ^^^^")
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    assert_equal "Could not generate payouts: boom", flash[:alert]
  end

  test "the overlay lists every line with its roles and the override form" do
    it = breaching_tracker
    get admin_invoice_tracker_contributor_payouts_path(it, margin_breach: 1)
    assert_response :success

    assert_select ".full-screen-modal.margin-breach" do
      assert_select ".full-screen-modal__contents__title p", text: "Error generating payouts"
      assert_select ".full-screen-modal__contents__title a.margin-breach__close[href=?]", admin_invoice_tracker_contributor_payouts_path(it)
      assert_select "tr.margin-breach__total td", text: "103.0%"
      assert_select "tr.margin-breach__total td", text: "$7,000.00"
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

  test "generate anyway records who overrode the cap, when and why" do
    it = breaching_tracker
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "Agreed fixed fee" }

    it.reload
    assert_equal @creator, it.payout_cap_override_by
    assert_equal "Agreed fixed fee", it.payout_cap_override_reason
    assert_in_delta Time.current, it.payout_cap_override_at, 60
    assert_in_delta 103.0, it.payout_cap_override_payout_percentage, 0.01
    assert_in_delta 70.0, it.payout_cap_override_cap_percentage, 0.01
    assert it.payout_cap_overridden?
  end

  test "a later generation within the cap clears the recorded override" do
    it = breaching_tracker
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "Agreed fixed fee" }
    assert it.reload.payout_cap_overridden?

    @project.update!(notes: nil) # no more rate override: the invoice is back on its cap
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it)
    assert_equal "Payouts processed!", flash[:notice]

    it.reload
    assert_not it.payout_cap_overridden?
    assert_nil it.payout_cap_override_by
    assert_nil it.payout_cap_override_reason
  end

  test "the override is recorded against the real admin, not the one they impersonate" do
    other_admin = AdminUser.create!(email: "other-admin-guard@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
    it = breaching_tracker
    post impersonate_admin_admin_user_path(other_admin)
    assert_match(/Now impersonating/, flash[:notice])

    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "Agreed fixed fee" }

    it.reload
    assert_equal @creator, it.payout_cap_override_by
    assert_match(/#{Regexp.escape(@creator.email)} generated payouts over the cap/, it.notes)
    assert_no_match(/#{Regexp.escape(other_admin.email)}/, it.notes)
    assert_equal [@creator.id], it.contributor_payouts.map(&:created_by_id).uniq
  end

  test "the override cannot be set through the tracker form" do
    it = within_cap_tracker
    patch admin_invoice_pass_invoice_tracker_path(it.invoice_pass, it), params: { invoice_tracker: { payout_cap_override_by_id: @creator.id, payout_cap_override_reason: "sneaky", notes: "edited" } }
    it.reload
    assert_equal "edited", it.notes, "the update itself must have gone through"
    assert_nil it.payout_cap_override_by_id
    assert_nil it.payout_cap_override_reason
  end

  test "the tracker's override banner names who overrode the cap and why" do
    it = breaching_tracker
    post make_payouts_admin_invoice_tracker_contributor_payouts_path(it), params: { force: "1", override_reason: "Agreed <b>fixed</b> fee" }

    html = ApplicationController.render(partial: "admin/invoice_trackers/payout_cap_override", locals: { invoice_tracker: it.reload })
    assert_match "These payouts were generated over the invoice's cap", html
    assert_match "(103.0% against a cap of 70.0%)", html
    assert_match @creator.email, html
    assert_match "Reason given: Agreed &lt;b&gt;fixed&lt;/b&gt; fee", html

    blank = ApplicationController.render(partial: "admin/invoice_trackers/payout_cap_override", locals: { invoice_tracker: within_cap_tracker })
    assert_equal "", blank.strip
  end

  private

  def sign_in(admin)
    post admin_user_session_path, params: { admin_user: { email: admin.email, password: "password123" } }
  end
end
