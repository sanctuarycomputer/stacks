require "test_helper"

class AdminMsoRolePeriodGuardTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include MsoFixtures

  test "deleting a role period a run has used is refused on the roster page, with the reason" do
    garden3d_qbo_account
    exec = mso_person("guard-ui-exec")
    role = mso_role(exec, started_at: Date.new(2091, 1, 1))
    mso_snapshot(garden3d_pass(Date.new(2091, 6, 1)), lines: [mso_line(role, garden3d_ledger(exec), trueup: "100.0")])
    sign_in mso_admin

    assert_no_difference -> { MsoRolePeriod.count } do
      delete admin_mso_role_period_path(role)
    end

    assert_redirected_to admin_mso_role_periods_path
    assert_match(/June 2091/, flash[:alert])

    patch admin_mso_role_period_path(role), params: { mso_role_period: { tier: "principal" } }
    assert_match(/end this period and start a new one/, response.body)
    assert_equal "chief", role.reload.tier
  ensure
    clear_enterprise_memos
  end
end
