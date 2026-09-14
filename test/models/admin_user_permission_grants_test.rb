require 'test_helper'

class AdminUserPermissionGrantsTest < ActiveSupport::TestCase
  def make_user(email)
    AdminUser.create!(email: email, password: "password12345")
  end

  def make_project_tracker(name)
    pt = ProjectTracker.new(name: name)
    pt.save!(validate: false)
    pt
  end

  test "can_act_as_lead? is true for someone who actually led a project" do
    user = make_user("led@sanctuary.computer")
    pt = make_project_tracker("Led Project")
    ProjectLeadPeriod.create!(project_tracker: pt, admin_user: user,
      started_at: Date.new(2025, 1, 1), ended_at: Date.new(2025, 3, 31))
    assert user.can_act_as_lead?
  end

  test "can_act_as_lead? is true with a global lead grant and false otherwise" do
    user = make_user("trainee@sanctuary.computer")
    refute user.can_act_as_lead?
    PermissionGrant.create!(admin_user: user, permission: "lead")
    assert user.reload.can_act_as_lead?
  end

  test "a project-scoped grant does NOT make can_act_as_lead? true, but appears in lead_scoped_project_tracker_ids" do
    user = make_user("scoped@sanctuary.computer")
    pt = make_project_tracker("Scoped Project")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)
    refute user.can_act_as_lead?
    assert_equal [pt.id], user.lead_scoped_project_tracker_ids
  end

  test "destroying a project tracker destroys grants scoped to it" do
    user = make_user("scoped@sanctuary.computer")
    pt = make_project_tracker("Doomed Project")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)
    pt.destroy!
    assert_equal [], user.reload.permission_grants
  end

  test "destroying a user destroys their grants" do
    user = make_user("leaving@sanctuary.computer")
    grant = PermissionGrant.create!(admin_user: user, permission: "lead")
    user.destroy!
    refute PermissionGrant.exists?(grant.id)
  end
end
