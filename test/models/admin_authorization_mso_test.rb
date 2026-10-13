require "test_helper"

class AdminAuthorizationMsoTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 9, 1)
  EVERY_ACTION = [:read, :index, :new, :create, :update, :destroy, :toggle_acceptance, :check_collection,
                  :remove_qbo_bill].freeze

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("authz-exec")
    @other = mso_person("authz-other")
    @role = mso_role(@exec)
    @other_role = mso_role(@other, tier: :svp)
    @snapshot = mso_snapshot(@pass, lines: [
      mso_line(@role, garden3d_ledger(@exec), trueup: "1000.0"),
      mso_line(@other_role, garden3d_ledger(@other), trueup: "2000.0"),
    ])
    @mine = mso_trueup(@snapshot, @role, garden3d_ledger(@exec), amount: "1000")
    @theirs = mso_trueup(@snapshot, @other_role, garden3d_ledger(@other), amount: "2000")

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

    [MsoTrueup, MsoSnapshot, @mine, @snapshot].each do |subject|
      (EVERY_ACTION - [:toggle_acceptance]).each do |action|
        assert auth.authorized?(action, subject), "admin should #{action} #{subject}"
      end
    end
    assert auth.authorized?(:run_mso_compensation, @pass)

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
    assert auth.authorized?(:read, @snapshot)
  end

  test "a full lead can do nothing with any MSO subject, reading included" do
    auth = auth_for(@lead)
    # The premise: this user really does have the blanket lead grant.
    assert auth.authorized?(:read, Studio)

    [MsoTrueup, MsoSnapshot, @mine, @theirs, @snapshot, MsoTrueup.new, MsoSnapshot.new].each do |subject|
      EVERY_ACTION.each { |action| refute auth.authorized?(action, subject), "lead must not #{action} #{subject}" }
    end
  end

  test "someone with only a contributor record cannot list, start or create a true-up" do
    auth = auth_for(@nobody)

    [:index, :new, :create, :read].each do |action|
      refute auth.authorized?(action, MsoTrueup), "must not #{action} the class"
      refute auth.authorized?(action, MsoTrueup.new), "must not #{action} a new record"
    end
    refute auth.authorized?(:read, @mine)
    refute auth.authorized?(:read, MsoSnapshot)
  end

  test "an executive can read and accept their own true-up and nothing more" do
    auth = auth_for(@exec_login)

    assert auth.authorized?(:read, @mine)
    assert auth.authorized?(:toggle_acceptance, @mine)
    [:update, :destroy, :create, :remove_qbo_bill, :check_collection].each do |action|
      refute auth.authorized?(action, @mine), "owner must not #{action} their own true-up"
    end

    EVERY_ACTION.each { |action| refute auth.authorized?(action, @theirs), "must not #{action} another's true-up" }
    EVERY_ACTION.each { |action| refute auth.authorized?(action, @snapshot), "must not #{action} the snapshot" }
    [:index, :new, :create, :read].each { |action| refute auth.authorized?(action, MsoTrueup) }
  end

  test "an executive who is also a lead still sees only their own true-up" do
    PermissionGrant.create!(admin_user: @exec_login, permission: "lead")
    auth = auth_for(AdminUser.find(@exec_login.id))
    assert auth.authorized?(:read, Studio)

    assert auth.authorized?(:read, @mine)
    refute auth.authorized?(:read, @theirs)
    refute auth.authorized?(:read, @snapshot)
    refute auth.authorized?(:read, MsoSnapshot)
  end

  test "only an admin may run a month's MSO compensation" do
    assert auth_for(@admin).authorized?(:run_mso_compensation, @pass)
    refute auth_for(@lead).authorized?(:run_mso_compensation, @pass)
    refute auth_for(@exec_login).authorized?(:run_mso_compensation, @pass)
    # garden3d's own pass already refuses a lead every action. The action is
    # admin-only on any other pass too, where a lead may otherwise do anything.
    refute auth_for(@lead).authorized?(:run_mso_compensation, @snapshot.sanctuary_invoice_pass)
    # Whether a lead may still READ garden3d's pass is S1's rule (it is
    # becoming admin-only) and is not asserted here.
  end

  test "MsoTrueup is not one of the own-ledger-item classes" do
    # That list grants :index, :new and :create to anyone with a contributor.
    assert_not_includes AdminAuthorization::OWN_LEDGER_ITEM_CLASSES, MsoTrueup
    assert_not_includes AdminAuthorization::OWN_LEDGER_ITEM_CLASSES, MsoSnapshot
  end

  # Deleting a founder true-up deletes its QuickBooks bill, and for a month
  # the MSO pays the nightly sync will not write it again.
  test "only an admin may delete a founder true-up; a lead may still read one" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: @exec)
    trueup = Trueup.create!(invoice_pass: @snapshot.sanctuary_invoice_pass, ledger: sanctuary_ledger,
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
