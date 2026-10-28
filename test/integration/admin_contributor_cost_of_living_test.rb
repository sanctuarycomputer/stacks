require "test_helper"

class AdminContributorCostOfLivingTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "col-admin-#{SecureRandom.hex(3)}@sanctuary.computer",
      password: "password12345", password_confirmation: "password12345",
      roles: ["admin"]
    )
    # A global lead grant gets past AdminAuthorization, so the strip in
    # #update is what's actually under test.
    @lead = AdminUser.create!(
      email: "col-lead-#{SecureRandom.hex(3)}@sanctuary.computer",
      password: "password12345", password_confirmation: "password12345"
    )
    PermissionGrant.create!(admin_user: @lead, permission: "lead", granted_by: @admin)
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "col-target@sanctuary.computer", data: {})
    @contributor = fp.contributor
  end

  test "an admin can set the cost-of-living country" do
    sign_in @admin
    put admin_contributor_path(@contributor), params: { contributor: { cost_of_living_country: "Canada" } }
    assert_equal "Canada", @contributor.reload.cost_of_living_country
  end

  test "a non-admin lead cannot set the cost-of-living country" do
    sign_in @lead
    put admin_contributor_path(@contributor), params: { contributor: { cost_of_living_country: "Canada" } }
    # The update went through (not refused), so the strip is what kept it out.
    assert_redirected_to admin_contributor_path(@contributor)
    assert_nil @contributor.reload.cost_of_living_country
  end

  test "the edit form offers the field to admins only" do
    sign_in @admin
    get edit_admin_contributor_path(@contributor)
    assert_response :success
    assert_includes response.body, "contributor[cost_of_living_country]"

    sign_out @admin
    sign_in @lead
    get edit_admin_contributor_path(@contributor)
    assert_response :success
    refute_includes response.body, "contributor[cost_of_living_country]"
  end
end
