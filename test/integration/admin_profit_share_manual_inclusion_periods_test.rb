require "test_helper"

class AdminProfitShareManualInclusionPeriodsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(email: "inclusion-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    # A global lead grant passes the blanket lead rule, so this proves the
    # admin-only rule above it.
    @lead = AdminUser.create!(email: "inclusion-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")

    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "christian-test@sanctuary.computer", data: {})
    @contributor = fp.contributor || Contributor.create!(forecast_person: fp)
  end

  test "an admin can list, create and end an inclusion" do
    sign_in @admin

    get admin_profit_share_manual_inclusion_periods_path
    assert_response :success
    get new_admin_profit_share_manual_inclusion_period_path
    assert_response :success

    assert_difference -> { ProfitShareManualInclusionPeriod.count }, 1 do
      post admin_profit_share_manual_inclusion_periods_path, params: { profit_share_manual_inclusion_period: {
        contributor_id: @contributor.id, started_at: "2026-07-01", note: "garden3d ops, does Sanctuary client work",
      } }
    end
    inclusion = ProfitShareManualInclusionPeriod.last
    assert_nil inclusion.ended_at

    get edit_admin_profit_share_manual_inclusion_period_path(inclusion)
    assert_response :success
    put admin_profit_share_manual_inclusion_period_path(inclusion), params: { profit_share_manual_inclusion_period: { ended_at: "2026-12-31" } }
    assert_equal Date.new(2026, 12, 31), inclusion.reload.ended_at
  end

  test "a lead can't see or create inclusions" do
    sign_in @lead

    get admin_profit_share_manual_inclusion_periods_path
    assert_redirected_to admin_root_path

    assert_no_difference -> { ProfitShareManualInclusionPeriod.count } do
      post admin_profit_share_manual_inclusion_periods_path, params: { profit_share_manual_inclusion_period: {
        contributor_id: @contributor.id, started_at: "2026-07-01", note: "self-included",
      } }
    end
  end

  test "a lead can't edit or delete an existing inclusion" do
    inclusion = ProfitShareManualInclusionPeriod.create!(contributor: @contributor, started_at: Date.new(2026, 7, 1), note: "ops")
    sign_in @lead

    put admin_profit_share_manual_inclusion_period_path(inclusion),
      params: { profit_share_manual_inclusion_period: { ended_at: "2026-07-31" } }
    assert_nil inclusion.reload.ended_at

    assert_no_difference -> { ProfitShareManualInclusionPeriod.count } do
      delete admin_profit_share_manual_inclusion_period_path(inclusion)
    end
  end
end
