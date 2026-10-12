require 'test_helper'

class AdminAuthorizationTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def teardown
    clear_enterprise_memos
  end

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

    ip = InvoicePass.create!(start_of_month: Date.new(2031, 1, 1), enterprise: Enterprise.sanctuary)
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

  # Sign-off exists to police project leads, so it must not inherit the blanket
  # lead access granted a few lines below in authorized?.
  test "a lead cannot sign off or revoke sign-off on a project capsule" do
    user = make_user("lead@sanctuary.computer")
    pt = make_project_tracker("Gated")
    ProjectLeadPeriod.create!(admin_user: user, project_tracker: pt, started_at: Date.today.beginning_of_month)
    capsule = ProjectCapsule.create!(project_tracker: pt)

    auth = auth_for(user)
    assert auth.authorized?(:update, capsule), "leads still edit capsules normally"
    refute auth.authorized?(:sign_off, capsule)
    refute auth.authorized?(:revoke_sign_off, capsule)
    refute auth.authorized?(:sign_off, ProjectCapsule)
  end

  test "an admin can sign off and revoke sign-off on a project capsule" do
    user = AdminUser.create!(email: "boss@sanctuary.computer", password: "password12345", roles: ["admin"])
    capsule = ProjectCapsule.create!(project_tracker: make_project_tracker("Gated"))

    auth = auth_for(user)
    assert auth.authorized?(:sign_off, capsule)
    assert auth.authorized?(:revoke_sign_off, capsule)
  end

  # Closing/reopening a survey is the cheapest way around the new opt-out sign-off
  # gate (an empty survey a lead creates and closes themselves reads as Complete
  # for free), so this must be as tightly policed as sign_off/revoke_sign_off.
  test "a lead cannot close or reopen a project satisfaction survey, but an admin can" do
    lead = make_user("survey-lead@sanctuary.computer")
    pt = make_project_tracker("Surveyed")
    ProjectLeadPeriod.create!(admin_user: lead, project_tracker: pt, started_at: Date.today.beginning_of_month)
    capsule = ProjectCapsule.create!(project_tracker: pt)
    survey = ProjectSatisfactionSurvey.create!(
      project_capsule: capsule,
      title: "Project Satisfaction Survey",
      description: "Feedback please",
    )

    lead_auth = auth_for(lead)
    refute lead_auth.authorized?(:close_survey, survey)
    refute lead_auth.authorized?(:reopen_survey, survey)

    admin = AdminUser.create!(email: "survey-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    admin_auth = auth_for(admin)
    assert admin_auth.authorized?(:close_survey, survey)
    assert admin_auth.authorized?(:reopen_survey, survey)
  end

  test "only admins may touch the MSO roster, including reading it" do
    admin = AdminUser.create!(email: "mso-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    lead = make_user("mso-lead@sanctuary.computer")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    nobody = make_user("mso-nobody@sanctuary.computer")

    %i[read create update destroy].each do |action|
      assert auth_for(admin).authorized?(action, MsoRolePeriod), "admin should #{action}"
      assert auth_for(admin).authorized?(action, MsoRolePeriod.new), "admin should #{action} a record"
      refute auth_for(lead).authorized?(action, MsoRolePeriod), "lead must not #{action}"
      refute auth_for(lead).authorized?(action, MsoRolePeriod.new), "lead must not #{action} a record"
      refute auth_for(nobody).authorized?(action, MsoRolePeriod), "non-lead must not #{action}"
      refute auth_for(nobody).authorized?(action, MsoRolePeriod.new), "non-lead must not #{action} a record"
    end
  end

  # --- garden3d's passes are admin-only ---------------------------------------
  # They hold what the operating companies pay garden3d. The owner's decision
  # covers every garden3d pass, the seven legacy 2025 ones included, and every
  # tracker on one, for every action.

  PASS_ACTIONS = %i[read create_management_fee_drafts refresh_management_fee_invoices rerun_invoice_pass
                    rerun_invoice_pass_without_reminders].freeze
  TRACKER_ACTIONS = %i[read update toggle_ownership attempt_generate notify_reviewers resync_qbo_line_item_services
                       toggle_contributor_payout_acceptance].freeze

  def garden3d_world
    garden3d_qbo_account
    fee_pass = garden3d_pass(Date.new(2094, 3, 1))
    fee = fee_tracker(fee_pass, make_payer("Auth Fee #{SecureRandom.hex(3)}"))
    legacy_pass = garden3d_pass(Date.new(2094, 4, 1))
    legacy = fee_tracker(legacy_pass, make_payer("Auth Legacy #{SecureRandom.hex(3)}"))
    legacy.update!(blueprint: { "lines" => {} })

    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    sanctuary_pass = InvoicePass.create!(start_of_month: Date.new(2094, 3, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 971_010, name: "External Co")
    sanctuary = InvoiceTracker.create!(invoice_pass: sanctuary_pass, forecast_client_id: client.forecast_id,
                                       qbo_account: sanctuary_qa, blueprint: { "lines" => {} })
    { fee_pass: fee_pass, fee: fee, legacy_pass: legacy_pass, legacy: InvoiceTracker.find(legacy.id),
      sanctuary_pass: sanctuary_pass, sanctuary: sanctuary }
  end

  def non_admins
    lead = make_user("g3d-lead@sanctuary.computer")
    PermissionGrant.create!(admin_user: lead, permission: "lead")
    past_lead = make_user("g3d-past-lead@sanctuary.computer")
    ProjectLeadPeriod.create!(admin_user: past_lead, project_tracker: make_project_tracker("Led"),
                              started_at: Date.today.beginning_of_month)
    scoped = make_user("g3d-scoped@sanctuary.computer")
    PermissionGrant.create!(admin_user: scoped, permission: "lead", subject: make_project_tracker("Scoped"))
    contributor = make_user("g3d-contributor@sanctuary.computer")
    ForecastPerson.create!(forecast_id: 971_020, email: contributor.email, data: {}).ensure_contributor_exists!
    { "a lead" => lead, "a past project lead" => past_lead, "a scoped grantee" => scoped,
      "a contributor" => AdminUser.find(contributor.id), "a plain user" => make_user("g3d-nobody@sanctuary.computer") }
  end

  test "nobody but an admin may do anything with a garden3d pass, reading included" do
    world = garden3d_world
    admin = AdminUser.create!(email: "g3d-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    users = non_admins

    [world[:fee_pass], world[:legacy_pass]].each do |pass|
      PASS_ACTIONS.each do |action|
        assert auth_for(admin).authorized?(action, pass), "admin should #{action} garden3d's #{pass.invoice_month} pass"
        users.each do |who, user|
          refute auth_for(user).authorized?(action, pass), "#{who} must not #{action} garden3d's #{pass.invoice_month} pass"
        end
      end
    end
  end

  test "nobody but an admin may do anything with a tracker on a garden3d pass, legacy ones included" do
    world = garden3d_world
    admin = AdminUser.create!(email: "g3d-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    users = non_admins
    assert users["a contributor"].forecast_person&.contributor.present?, "sanity: a contributor"

    [world[:fee], world[:legacy]].each do |tracker|
      TRACKER_ACTIONS.each do |action|
        assert auth_for(admin).authorized?(action, tracker), "admin should #{action}"
        users.each do |who, user|
          refute auth_for(user).authorized?(action, tracker), "#{who} must not #{action} a garden3d tracker"
        end
      end
    end
  end

  test "Sanctuary's passes and trackers are as they were for a lead, a grantee and a contributor" do
    world = garden3d_world
    users = non_admins

    ["a lead", "a past project lead"].each do |who|
      auth = auth_for(users[who])
      assert auth.authorized?(:read, world[:sanctuary_pass]), who
      TRACKER_ACTIONS.each { |action| assert auth.authorized?(action, world[:sanctuary]), "#{who} #{action}" }
      # The menu and the index page are class-level reads.
      assert auth.authorized?(:read, InvoicePass), who
      assert auth.authorized?(:read, InvoiceTracker), who
    end

    scoped = auth_for(users["a scoped grantee"])
    assert scoped.authorized?(:read, InvoicePass)
    assert scoped.authorized?(:read, world[:sanctuary_pass]), "a pass is the container a grantee navigates through"

    # A contributor accepts their own payout through the tracker.
    assert auth_for(users["a contributor"]).authorized?(:toggle_contributor_payout_acceptance, world[:sanctuary])
  end

  test "scope_collection hides garden3d's passes and trackers from everyone but an admin" do
    world = garden3d_world
    admin = AdminUser.create!(email: "g3d-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    garden3d_pass_ids = [world[:fee_pass].id, world[:legacy_pass].id]
    garden3d_tracker_ids = [world[:fee].id, world[:legacy].id]

    assert_equal InvoicePass.count, auth_for(admin).scope_collection(InvoicePass.all).count
    assert_equal InvoiceTracker.count, auth_for(admin).scope_collection(InvoiceTracker.all).count

    non_admins.slice("a lead", "a past project lead", "a contributor", "a plain user").each do |who, user|
      passes = auth_for(user).scope_collection(InvoicePass.all).pluck(:id)
      assert_empty passes & garden3d_pass_ids, "#{who} must not list a garden3d pass"
      assert_includes passes, world[:sanctuary_pass].id, "#{who}: Sanctuary's pass is still listed"

      trackers = auth_for(user).scope_collection(InvoiceTracker.all).pluck(:id)
      assert_empty trackers & garden3d_tracker_ids, "#{who} must not list a garden3d tracker"
      assert_includes trackers, world[:sanctuary].id, "#{who}: Sanctuary's tracker is still listed"

      # The nested trackers index hands over the parent pass's own association.
      assert_empty auth_for(user).scope_collection(world[:fee_pass].invoice_trackers).pluck(:id), who
      # ActiveAdmin can hand over the bare model class.
      assert_empty auth_for(user).scope_collection(InvoicePass).pluck(:id) & garden3d_pass_ids, who
      assert_empty auth_for(user).scope_collection(InvoiceTracker).pluck(:id) & garden3d_tracker_ids, who
    end
  end

  test "scope_collection hides garden3d's passes and trackers from a scoped grantee too" do
    world = garden3d_world
    scoped = non_admins["a scoped grantee"]

    passes = auth_for(scoped).scope_collection(InvoicePass.all).pluck(:id)
    assert_empty passes & [world[:fee_pass].id, world[:legacy_pass].id]
    assert_includes passes, world[:sanctuary_pass].id
    assert_empty auth_for(scoped).scope_collection(InvoiceTracker.all).pluck(:id) & [world[:fee].id, world[:legacy].id]
  end
end
