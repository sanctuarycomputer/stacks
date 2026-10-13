require "test_helper"

class AdminAuthorizationMsoTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 9, 1)
  EVERY_ACTION = [:read, :index, :new, :create, :update, :destroy, :toggle_acceptance].freeze

  def setup
    garden3d_qbo_account
    @exec = mso_person("authz-exec")
    @other = mso_person("authz-other")
    @role = mso_role(@exec)
    @other_role = mso_role(@other, tier: :svp)
    @report = mso_report(MONTH)
    @mine = mso_trueup(@report, @role, garden3d_ledger(@exec), amount: "1000")
    @theirs = mso_trueup(@report, @other_role, garden3d_ledger(@other), amount: "2000")

    @admin = mso_admin
    @lead = AdminUser.create!(email: "authz-lead-#{SecureRandom.hex(3)}@example.com", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
    @nobody = login_for(mso_person("authz-nobody"))
    @exec_login = login_for(@exec)
  end

  def teardown
    clear_enterprise_memos
  end

  def auth_for(user)
    AdminAuthorization.new(nil, user)
  end

  test "an admin may do anything with MSO compensation except accept someone else's true-up" do
    auth = auth_for(@admin)

    [MsoTrueup, @mine].each do |subject|
      (EVERY_ACTION - [:toggle_acceptance]).each do |action|
        assert auth.authorized?(action, subject), "admin should #{action} #{subject}"
      end
    end
    assert auth.authorized?(:sync_mso_trueups, @report)

    refute auth.authorized?(:toggle_acceptance, @mine), "accepting is the executive's own act"
    refute auth.authorized?(:toggle_acceptance, @theirs)
    refute auth.authorized?(:toggle_acceptance, MsoTrueup)
  end

  # Both expected executives are admins. Each can see the other's true-up
  # (unchanged, and a question for the owner) but must not accept it.
  test "an executive who is an admin can accept their own true-up and not the other executive's" do
    @exec_login.update!(roles: ["admin"])
    auth = auth_for(AdminUser.find(@exec_login.id))

    assert auth.authorized?(:toggle_acceptance, @mine)
    refute auth.authorized?(:toggle_acceptance, @theirs)
    assert auth.authorized?(:read, @theirs)
  end

  test "a full lead reads a true-up like any ledger item, and can do nothing else with any MSO subject" do
    auth = auth_for(@lead)
    # The premise: this user really does have the blanket lead grant.
    assert auth.authorized?(:read, Studio)

    [MsoTrueup, @mine, @theirs].each { |subject| assert auth.authorized?(:read, subject), "lead reads #{subject}" }
    [MsoTrueup, @mine, @theirs, MsoTrueup.new].each do |subject|
      (EVERY_ACTION - [:read]).each do |action|
        refute auth.authorized?(action, subject), "lead must not #{action} #{subject}"
      end
    end
  end

  test "someone with only a contributor record cannot list, start or create a true-up" do
    auth = auth_for(@nobody)

    [:index, :new, :create, :read].each do |action|
      refute auth.authorized?(action, MsoTrueup), "must not #{action} the class"
      refute auth.authorized?(action, MsoTrueup.new), "must not #{action} a new record"
    end
    refute auth.authorized?(:read, @mine)
  end

  test "an executive can read and accept their own true-up and nothing more" do
    auth = auth_for(@exec_login)

    assert auth.authorized?(:read, @mine)
    assert auth.authorized?(:toggle_acceptance, @mine)
    [:update, :destroy, :create].each do |action|
      refute auth.authorized?(action, @mine), "owner must not #{action} their own true-up"
    end

    EVERY_ACTION.each { |action| refute auth.authorized?(action, @theirs), "must not #{action} another's true-up" }
    [:index, :new, :create, :read].each { |action| refute auth.authorized?(action, MsoTrueup) }
  end

  test "an executive who is also a lead reads the others' true-ups and accepts only their own" do
    PermissionGrant.create!(admin_user: @exec_login, permission: "lead")
    auth = auth_for(AdminUser.find(@exec_login.id))
    assert auth.authorized?(:read, Studio)

    assert auth.authorized?(:read, @mine)
    assert auth.authorized?(:read, @theirs)
    assert auth.authorized?(:toggle_acceptance, @mine)
    refute auth.authorized?(:toggle_acceptance, @theirs)
  end

  test "only an admin may sync a month's MSO true-ups; a lead still reads the report" do
    [@report, PeriodicReport].each do |subject|
      assert auth_for(@admin).authorized?(:sync_mso_trueups, subject)
      refute auth_for(@lead).authorized?(:sync_mso_trueups, subject)
      refute auth_for(@exec_login).authorized?(:sync_mso_trueups, subject)
    end
    assert auth_for(@lead).authorized?(:read, @report)
  end

  test "MsoTrueup is not one of the own-ledger-item classes" do
    # That list grants :index, :new and :create to anyone with a contributor.
    assert_not_includes AdminAuthorization::OWN_LEDGER_ITEM_CLASSES, MsoTrueup
  end

  # Deleting a founder true-up deletes its QuickBooks bill, and for a month
  # the MSO pays the nightly sync will not write it again.
  test "only an admin may delete a founder true-up; a lead may still read one" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: @exec)
    trueup = Trueup.create!(invoice_pass: sanctuary_pass(MONTH), ledger: sanctuary_ledger,
                            amount: "4000", description: "founder true-up")

    [trueup, Trueup].each do |subject|
      assert auth_for(@admin).authorized?(:destroy, subject)
      refute auth_for(@lead).authorized?(:destroy, subject), "a lead must not destroy #{subject}"
      refute auth_for(@exec_login).authorized?(:destroy, subject)
      refute auth_for(@nobody).authorized?(:destroy, subject)
      assert auth_for(@lead).authorized?(:read, subject), "a lead reads all, as before"
    end
  end
end
