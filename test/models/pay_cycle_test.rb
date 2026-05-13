require "test_helper"

class PayCycleTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "G3D Test #{SecureRandom.hex(2)}")
    @starts = Date.new(2026, 5, 1)
    @ends = Date.new(2026, 5, 31)
  end

  test "valid with enterprise, starts_at, ends_at" do
    pc = PayCycle.new(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    assert pc.valid?, pc.errors.full_messages.inspect
  end

  test "requires starts_at <= ends_at" do
    pc = PayCycle.new(enterprise: @enterprise, starts_at: @ends, ends_at: @starts)
    refute pc.valid?
    assert_includes pc.errors[:ends_at], "must be on or after starts_at"
  end

  test "uniqueness on (enterprise_id, starts_at, ends_at)" do
    PayCycle.create!(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    dup = PayCycle.new(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    refute dup.valid?
  end

  test "stubs_status returns :no_stubs when there are no pay_stubs" do
    pc = PayCycle.create!(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    assert_equal :no_stubs, pc.stubs_status
  end

  test "acts_as_paranoid soft-deletes" do
    pc = PayCycle.create!(enterprise: @enterprise, starts_at: @starts, ends_at: @ends)
    pc.destroy
    assert pc.deleted_at.present?
    assert_equal 0, PayCycle.where(id: pc.id).count
    assert_equal 1, PayCycle.with_deleted.where(id: pc.id).count
  end

  test "rejects a cycle that overlaps an existing sibling" do
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))
    overlap = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 5, 10), ends_at: Date.new(2026, 5, 20))
    refute overlap.valid?
    assert_includes overlap.errors[:base], "overlaps another pay cycle for this enterprise"
  end

  test "rejects a cycle that doesn't start the day after the latest sibling's ends_at" do
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))
    # Should start May 16. May 17 leaves a gap; rejected.
    gap = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 5, 17), ends_at: Date.new(2026, 5, 31))
    refute gap.valid?
    assert(gap.errors[:starts_at].any? { |e| e.include?("contiguous") })
  end

  test "accepts a contiguous cycle starting the day after the latest sibling" do
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))
    next_one = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 5, 16), ends_at: Date.new(2026, 5, 31))
    assert next_one.valid?, next_one.errors.full_messages.inspect
  end

  test "first cycle for an enterprise has no timeline constraint" do
    # No prior cycles → any (starts_at, ends_at) is acceptable.
    first = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2027, 3, 7), ends_at: Date.new(2027, 3, 22))
    assert first.valid?, first.errors.full_messages.inspect
  end

  test "switching cadence mid-stream is allowed (twice_monthly → monthly picks up where prior cycle left off)" do
    # Twice-monthly first half
    PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 15))
    # Now switch to monthly — the next cycle continues from May 16 through end of month
    transition = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 5, 16), ends_at: Date.new(2026, 5, 31))
    assert transition.valid?
    transition.save!
    # Next monthly cycle runs Jun 1..30
    next_monthly = PayCycle.new(enterprise: @enterprise, starts_at: Date.new(2026, 6, 1), ends_at: Date.new(2026, 6, 30))
    assert next_monthly.valid?
  end
end

class PayCycleApprovalTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "PCA-#{SecureRandom.hex(2)}")
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2027, 1, 1), ends_at: Date.new(2027, 1, 31))
    @ent_admin = AdminUser.create!(email: "ea#{SecureRandom.hex(2)}@x.com", password: "password123", password_confirmation: "password123")
    @enterprise.admin_users << @ent_admin
    @global_admin = AdminUser.create!(email: "ga#{SecureRandom.hex(2)}@x.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
    @stranger = AdminUser.create!(email: "st#{SecureRandom.hex(2)}@x.com", password: "password123", password_confirmation: "password123")
  end

  test "approved? is false by default" do
    refute @cycle.approved?
  end

  test "toggle_approval! by an enterprise admin sets approved_at and approved_by" do
    @cycle.toggle_approval!(by: @ent_admin)
    assert @cycle.approved?
    assert_equal @ent_admin.id, @cycle.approved_by_id
    assert @cycle.approved_at.present?
  end

  test "toggle_approval! by a global super-admin is allowed (admin_of? falls through is_admin?)" do
    @cycle.toggle_approval!(by: @global_admin)
    assert @cycle.approved?
  end

  test "toggle_approval! by a non-enterprise-admin raises NotAuthorizedToApprove" do
    assert_raises(PayCycle::NotAuthorizedToApprove) do
      @cycle.toggle_approval!(by: @stranger)
    end
    refute @cycle.reload.approved?
  end

  test "toggle_approval! by nil raises NotAuthorizedToApprove" do
    assert_raises(PayCycle::NotAuthorizedToApprove) do
      @cycle.toggle_approval!(by: nil)
    end
  end

  test "toggle_approval! is reversible (unapprove)" do
    @cycle.toggle_approval!(by: @ent_admin)
    assert @cycle.approved?
    @cycle.toggle_approval!(by: @ent_admin)
    refute @cycle.approved?
    assert_nil @cycle.approved_by_id
  end
end

class EnterpriseAdminAndPayStubPayableTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "EAP-#{SecureRandom.hex(2)}")
    @ent_admin = AdminUser.create!(email: "epa#{SecureRandom.hex(2)}@x.com", password: "password123", password_confirmation: "password123")
    @enterprise.admin_users << @ent_admin
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "eap#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2027, 2, 1), ends_at: Date.new(2027, 2, 28))
    @stub_admin = AdminUser.create!(email: "stuba#{SecureRandom.hex(2)}@x.com", password: "password123", password_confirmation: "password123")
    @blueprint = { "lines" => [{ "forecast_project" => "p", "hours" => 1, "rate" => 100, "amount" => 100, "description" => "x" }] }
    @stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: @blueprint)
  end

  test "stub is NOT payable when only accepted but cycle is not approved" do
    @stub.update!(accepted_at: DateTime.now, accepted_by: @stub_admin)
    assert_equal :all_accepted, @cycle.reload.stubs_status
    refute @stub.reload.payable?, "should be blocked by missing cycle approval"
  end

  test "stub IS payable when accepted AND cycle is approved" do
    @stub.update!(accepted_at: DateTime.now, accepted_by: @stub_admin)
    @cycle.toggle_approval!(by: @ent_admin)
    assert @stub.reload.payable?
  end

  test "stub is NOT payable when cycle is approved but the stub itself is unaccepted" do
    @cycle.toggle_approval!(by: @ent_admin)
    refute @stub.reload.payable?
  end

  test "AdminUser#admin_of? returns true for an enterprise admin, false for an unrelated admin" do
    assert @ent_admin.admin_of?(@enterprise)
    refute @stub_admin.admin_of?(@enterprise), "stub_admin is not in enterprise_admins"
  end

  test "AdminUser#admin_of? returns true for any enterprise when global is_admin?" do
    g = AdminUser.create!(email: "gg#{SecureRandom.hex(2)}@x.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
    assert g.admin_of?(@enterprise)
  end

  test "AdminUser#admin_of? returns false when enterprise is nil" do
    refute @ent_admin.admin_of?(nil)
  end
end
