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
        started_at: "2027-01-01",
      } }
    end
    period = MsoRolePeriod.last
    assert_equal "chief", period.tier
    assert_equal Date.new(2027, 1, 1), period.started_at
  end

  test "an admin can view, edit and end a role period" do
    period = MsoRolePeriod.create!(contributor: @contributor, tier: :svp, title: "Finance",
                                   started_at: Date.new(2027, 1, 1), ended_at: Date.new(2027, 6, 30))
    sign_in @admin

    get admin_mso_role_periods_path
    assert_response :success
    assert_match(/0\.85x/, response.body)
    assert_match(/Finance/, response.body)

    get new_admin_mso_role_period_path
    assert_response :success

    get edit_admin_mso_role_period_path(period)
    assert_response :success

    # Clearing the end date re-opens the role.
    patch admin_mso_role_period_path(period), params: { mso_role_period: { ended_at: "" } }
    assert_response :redirect
    assert_nil period.reload.ended_at
  end

  test "a second open-ended period for the same person is a form error" do
    MsoRolePeriod.create!(contributor: @contributor, tier: :chief, title: "Operations",
                          started_at: Date.new(2027, 1, 1))
    sign_in @admin

    assert_no_difference -> { MsoRolePeriod.count } do
      post admin_mso_role_periods_path, params: { mso_role_period: {
        contributor_id: @contributor.id, tier: "principal", title: "Operations",
        started_at: "2027-01-01",
      } }
    end
    assert_match(/overlaps with another/, response.body)
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
        started_at: "2027-01-01",
      } }
    end
    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
  end

  test "a start date that is not the first of a month is a form error, not a saved record" do
    sign_in @admin

    assert_no_difference -> { MsoRolePeriod.count } do
      post admin_mso_role_periods_path, params: { mso_role_period: {
        contributor_id: @contributor.id, tier: "chief", title: "Operations",
        started_at: "2027-01-15",
      } }
    end
    assert_response :success
    assert_match(/must be the first day of the month/, response.body)
  end

  test "a lead cannot fetch the roster as JSON" do
    MsoRolePeriod.create!(contributor: @contributor, tier: :chief, title: "Operations",
                          started_at: Date.new(2027, 1, 1))
    sign_in @lead

    get admin_mso_role_periods_path(format: :json)

    assert_not_equal 200, response.status
    assert_no_match(/Operations/, response.body)
  end

  test "a lead cannot update or delete an existing role period" do
    period = MsoRolePeriod.create!(contributor: @contributor, tier: :head, title: "Operations",
                                   started_at: Date.new(2027, 1, 1))
    sign_in @lead

    patch admin_mso_role_period_path(period), params: { mso_role_period: { tier: "principal" } }
    assert_match(/not authorized/i, flash[:error])
    assert_equal "head", period.reload.tier

    delete admin_mso_role_period_path(period)
    assert_match(/not authorized/i, flash[:error])
    assert MsoRolePeriod.exists?(period.id)
  end

  test "an executive cannot see the roster, their own role included" do
    email = "roster-self@example.com"
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    executive = AdminUser.create!(email: email, password: "password12345")
    MsoRolePeriod.create!(contributor: fp.contributor || Contributor.create!(forecast_person: fp),
                          tier: :chief, title: "Operations", started_at: Date.new(2027, 1, 1))
    sign_in executive

    get admin_mso_role_periods_path

    assert_response :redirect
    assert_match(/not authorized/i, flash[:error])
  end
end
