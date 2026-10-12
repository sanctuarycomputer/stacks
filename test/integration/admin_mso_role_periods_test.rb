require "test_helper"

class AdminMsoRolePeriodsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(email: "roster-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "roster-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "roster-exec@example.com", data: {})
    @contributor = fp.contributor || Contributor.create!(forecast_person: fp)
  end

  test "an admin can list and create role periods" do
    sign_in @admin

    get admin_mso_role_periods_path
    assert_response :success

    assert_difference -> { MsoRolePeriod.count }, 1 do
      post admin_mso_role_periods_path, params: { mso_role_period: {
        contributor_id: @contributor.id, tier: "chief", title: "Operations",
        started_at: "2026-01-01",
      } }
    end
    period = MsoRolePeriod.last
    assert_equal "chief", period.tier
    assert_equal Date.new(2026, 1, 1), period.started_at
  end

  test "a lead cannot see the roster" do
    sign_in @lead

    get admin_mso_role_periods_path

    # ActiveAdmin redirects an unauthorized user with a flash error. Asserting
    # both means a silently failed sign-in cannot pass this test.
    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
  end

  test "a lead cannot create a role period by posting directly" do
    sign_in @lead

    assert_no_difference -> { MsoRolePeriod.count } do
      post admin_mso_role_periods_path, params: { mso_role_period: {
        contributor_id: @contributor.id, tier: "principal", title: "Self-appointed",
        started_at: "2026-01-01",
      } }
    end
  end
end
