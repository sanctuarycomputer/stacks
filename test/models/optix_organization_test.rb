require "test_helper"

class OptixOrganizationMembershipTest < ActiveSupport::TestCase
  setup do
    @org = OptixOrganization.create!(name: "Test Org #{SecureRandom.hex(4)}")
  end

  def make_user(id)
    OptixUser.create!(optix_id: id, optix_organization_id: @org.id, email: "#{id}@example.com")
  end

  def make_plan(user_optix_id, status:)
    OptixAccountPlan.create!(
      optix_id: SecureRandom.hex(6),
      optix_organization_id: @org.id,
      status: status,
      access_usage_user_optix_id: user_optix_id,
    )
  end

  test "a user with an UPCOMING plan is an active member, not churned" do
    upcoming = make_user("u-upcoming")
    make_plan("u-upcoming", status: "UPCOMING")

    churned = make_user("u-churned")
    make_plan("u-churned", status: "ENDED")

    assert_includes @org.active_members, upcoming
    refute_includes @org.inactive_members, upcoming
    assert_includes @org.inactive_members, churned
    refute_includes @org.active_members, churned
  end

  test "ACTIVE and IN_TRIAL still count as membership" do
    active = make_user("u-active")
    make_plan("u-active", status: "ACTIVE")
    trial = make_user("u-trial")
    make_plan("u-trial", status: "IN_TRIAL")

    assert_includes @org.active_members, active
    assert_includes @org.active_members, trial
    assert_empty @org.inactive_members
  end
end
