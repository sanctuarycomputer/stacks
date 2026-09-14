require 'test_helper'

class AdminAuthorizationTest < ActiveSupport::TestCase
  def auth_for(user)
    AdminAuthorization.new(nil, user)
  end

  def make_user(email)
    AdminUser.create!(email: email, password: "password12345")
  end

  def make_project_tracker(name)
    pt = ProjectTracker.new(name: name)
    pt.save!(validate: false)
    pt
  end

  test "a user with no grants and no lead history has no ProjectTracker access" do
    user = make_user("nobody@sanctuary.computer")
    refute auth_for(user).authorized?(:read, ProjectTracker)
  end

  test "a global lead grant confers the same blanket access as having led" do
    user = make_user("trainee@sanctuary.computer")
    PermissionGrant.create!(admin_user: user, permission: "lead")
    auth = auth_for(user)
    assert auth.authorized?(:read, ProjectTracker)
    assert auth.authorized?(:update, ProjectTracker.new)
    assert auth.authorized?(:read, InvoiceTracker)
    assert auth.authorized?(:read, Studio)
  end

  test "a project-scoped grant gives read-only access to that project" do
    user = make_user("scoped@sanctuary.computer")
    pt_mine = make_project_tracker("Mine")
    pt_other = make_project_tracker("Other")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt_mine)

    auth = auth_for(user)
    # class-level reads so menus and index pages render
    assert auth.authorized?(:read, ProjectTracker)
    assert auth.authorized?(:read, InvoiceTracker)
    assert auth.authorized?(:read, InvoicePass)
    # record-level reads limited to the granted project
    assert auth.authorized?(:read, pt_mine)
    refute auth.authorized?(:read, pt_other)
    # strictly read-only
    refute auth.authorized?(:update, pt_mine)
    refute auth.authorized?(:destroy, pt_mine)
    refute auth.authorized?(:create, ProjectTracker)
    # no blanket access to anything else
    refute auth.authorized?(:read, Studio)
  end

  test "scoped grant allows reading only invoice trackers billing the granted project" do
    user = make_user("scoped2@sanctuary.computer")
    pt = make_project_tracker("Mine")
    fc = ForecastClient.create!(forecast_id: 920001, name: "Client")
    fp = ForecastProject.create!(forecast_id: 930001, name: "Mine FP", code: "MINE-1", forecast_client: fc)
    other_fp = ForecastProject.create!(forecast_id: 930002, name: "Other FP", code: "OTHR-1", forecast_client: fc)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: fp)
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)

    in_scope = InvoiceTracker.new(blueprint: { "lines" => { "0" => { "forecast_project" => fp.id } } })
    out_of_scope = InvoiceTracker.new(blueprint: { "lines" => { "0" => { "forecast_project" => other_fp.id } } })

    auth = auth_for(user)
    assert auth.authorized?(:read, in_scope)
    refute auth.authorized?(:read, out_of_scope)
    refute auth.authorized?(:toggle_ownership, in_scope)
  end

  test "scope_collection filters ProjectTracker index to granted projects" do
    user = make_user("scoped3@sanctuary.computer")
    pt_mine = make_project_tracker("Mine")
    make_project_tracker("Other")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt_mine)

    assert_equal [pt_mine.id], auth_for(user).scope_collection(ProjectTracker.all).pluck(:id)
  end

  test "scope_collection filters InvoiceTracker index via blueprint forecast projects" do
    user = make_user("scoped4@sanctuary.computer")
    pt = make_project_tracker("Mine")
    fc = ForecastClient.create!(forecast_id: 920002, name: "Client")
    fp = ForecastProject.create!(forecast_id: 930003, name: "Mine FP", code: "MINE-2", forecast_client: fc)
    other_fp = ForecastProject.create!(forecast_id: 930004, name: "Other FP", code: "OTHR-2", forecast_client: fc)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: fp)
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)

    ip = InvoicePass.create!(start_of_month: Date.new(2031, 1, 1))
    fc_mine = ForecastClient.create!(forecast_id: 910001, name: "Client Mine")
    fc_other = ForecastClient.create!(forecast_id: 910002, name: "Client Other")
    qbo = qbo_accounts(:one)
    it_mine = InvoiceTracker.create!(forecast_client: fc_mine, invoice_pass: ip, qbo_account: qbo,
      blueprint: { "lines" => { "0" => { "forecast_project" => fp.id } } })
    InvoiceTracker.create!(forecast_client: fc_other, invoice_pass: ip, qbo_account: qbo,
      blueprint: { "lines" => { "0" => { "forecast_project" => other_fp.id } } })
    InvoiceTracker.create!(forecast_client: ForecastClient.create!(forecast_id: 910003, name: "Nil BP"),
      invoice_pass: ip, qbo_account: qbo, blueprint: nil)

    assert_equal [it_mine.id], auth_for(user).scope_collection(InvoiceTracker.all).pluck(:id)
  end

  test "scope_collection filters a bare model Class (ActiveAdmin's end_of_association_chain) to granted projects" do
    user = make_user("scoped5@sanctuary.computer")
    pt_mine = make_project_tracker("Mine")
    make_project_tracker("Other")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt_mine)

    # Top-level resources without a scoped_collection override hand
    # ActiveAdmin (and thus scope_collection) the bare model Class, not a
    # Relation. Must not raise NoMethodError on #klass.
    assert_equal [pt_mine.id], auth_for(user).scope_collection(ProjectTracker).pluck(:id)
  end

  test "scope_collection leaves a bare unrelated model Class unchanged" do
    user = make_user("scoped6@sanctuary.computer")
    pt_mine = make_project_tracker("Mine")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt_mine)

    result = auth_for(user).scope_collection(Ledger)
    assert_equal Ledger, result
  end

  test "scope_collection leaves collections untouched for admins, leads, and unrelated classes" do
    admin = make_user("adm@sanctuary.computer")
    admin.update!(roles: ["admin"])
    lead_grantee = make_user("gl@sanctuary.computer")
    PermissionGrant.create!(admin_user: lead_grantee, permission: "lead")
    make_project_tracker("A")

    assert_equal ProjectTracker.count, auth_for(admin).scope_collection(ProjectTracker.all).count
    assert_equal ProjectTracker.count, auth_for(lead_grantee).scope_collection(ProjectTracker.all).count

    scoped = make_user("sc@sanctuary.computer")
    PermissionGrant.create!(admin_user: scoped, permission: "lead", subject: ProjectTracker.first)
    assert_equal AdminUser.count, auth_for(scoped).scope_collection(AdminUser.all).count
  end

  test "existing contributor fallback rules still work for users without grants" do
    user = make_user("plain@sanctuary.computer")
    auth = auth_for(user)
    assert auth.authorized?(:read, user)          # own AdminUser record
    assert auth.authorized?(:read, Survey)
    refute auth.authorized?(:read, InvoiceTracker)
  end
end
