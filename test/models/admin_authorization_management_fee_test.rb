require "test_helper"

class AdminAuthorizationManagementFeeTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2094, 6, 1))
    @payer = make_payer("Auth Payer #{SecureRandom.hex(3)}")
    @fee_tracker = fee_tracker(@pass, @payer)

    @admin = AdminUser.create!(email: "fee-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "fee-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
  end

  def teardown
    clear_enterprise_memos
  end

  def auth_for(user)
    AdminAuthorization.new(nil, user)
  end

  def sanctuary_tracker
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2094, 6, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 970_010, name: "External Co")
    InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id, qbo_account: sanctuary_qa)
  end

  # The owner's decision: garden3d's passes, and every tracker on them, are
  # admin-only for every action, reading included. The tests below used to
  # assert that a lead could READ a fee tracker and its pass, and kept
  # :update on a legacy garden3d tracker. They now assert the opposite.

  test "only an admin may update or regenerate a management fee invoice tracker, or read it" do
    %i[update attempt_generate read].each do |action|
      assert auth_for(@admin).authorized?(action, @fee_tracker), "admin should #{action}"
      refute auth_for(@lead).authorized?(action, @fee_tracker), "a lead must not #{action}"
    end
  end

  test "a lead may still read, update and regenerate a Sanctuary tracker" do
    tracker = sanctuary_tracker

    assert auth_for(@lead).authorized?(:read, tracker)
    assert auth_for(@lead).authorized?(:update, tracker)
    assert auth_for(@lead).authorized?(:attempt_generate, tracker)
    assert auth_for(@lead).authorized?(:read, tracker.invoice_pass)
  end

  test "a lead no longer has anything on a legacy garden3d tracker" do
    other = make_payer("Legacy Auth #{SecureRandom.hex(3)}")
    legacy = fee_tracker(@pass, other)
    legacy.update!(blueprint: { "lines" => {} })

    %i[read update attempt_generate].each do |action|
      refute auth_for(@lead).authorized?(action, legacy), "a lead must not #{action}"
      assert auth_for(@admin).authorized?(action, legacy), "admin should #{action}"
    end
  end

  test "only an admin may create drafts or refresh on a pass, or read garden3d's" do
    %i[create_management_fee_drafts refresh_management_fee_invoices read].each do |action|
      assert auth_for(@admin).authorized?(action, @pass), "admin should #{action}"
      refute auth_for(@lead).authorized?(action, @pass), "a lead must not #{action}"
    end
  end

  test "a lead cannot create drafts or refresh on a Sanctuary pass either" do
    pass = sanctuary_tracker.invoice_pass

    %i[create_management_fee_drafts refresh_management_fee_invoices].each do |action|
      refute auth_for(@lead).authorized?(action, pass), "a lead must not #{action}"
      assert auth_for(@admin).authorized?(action, pass), "admin should #{action}"
    end
  end

  test "only an admin may open a month for garden3d" do
    # A collection action: it is asked of the class.
    assert auth_for(@admin).authorized?(:open_management_fee_month, InvoicePass)
    refute auth_for(@lead).authorized?(:open_management_fee_month, InvoicePass)
    refute trainee_auth.authorized?(:open_management_fee_month, InvoicePass)
    assert auth_for(@lead).authorized?(:read, InvoicePass), "the index itself is unchanged for a lead"
  end

  def trainee_auth
    trainee = AdminUser.create!(email: "fee-trainee@sanctuary.computer", password: "password12345")
    project = ProjectTracker.new(name: "Training Project")
    project.save!(validate: false)
    PermissionGrant.create!(admin_user: trainee, permission: "lead", subject: project)
    auth_for(trainee)
  end

  test "a project-scoped grantee can list passes but cannot open garden3d's management fee pass" do
    sanctuary_pass = InvoicePass.create!(start_of_month: Date.new(2094, 6, 1),
                                         enterprise: enterprises(:sanctuary), data: {})

    auth = trainee_auth
    assert auth.authorized?(:read, InvoicePass), "class-level read keeps the menu and index working"
    assert auth.authorized?(:read, sanctuary_pass)
    refute auth.authorized?(:read, @pass)
  end

  test "a project-scoped grantee cannot open a legacy garden3d pass any more" do
    @fee_tracker.update!(blueprint: { "lines" => {} })

    refute trainee_auth.authorized?(:read, @pass)
  end
end
