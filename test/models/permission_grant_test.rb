require 'test_helper'

class PermissionGrantTest < ActiveSupport::TestCase
  def make_user(email)
    AdminUser.create!(email: email, password: "password12345")
  end

  test "a global lead grant is valid and global?" do
    user = make_user("trainee@sanctuary.computer")
    granter = make_user("granter@sanctuary.computer")
    grant = PermissionGrant.create!(admin_user: user, permission: "lead", granted_by: granter)
    assert grant.global?
    assert_includes PermissionGrant.global.for_permission("lead"), grant
  end

  test "permission must be in the allow-list" do
    user = make_user("trainee@sanctuary.computer")
    grant = PermissionGrant.new(admin_user: user, permission: "superuser")
    refute grant.valid?
    assert grant.errors[:permission].any?
  end

  test "subject_type defaults to ProjectTracker when only subject_id is set" do
    user = make_user("trainee@sanctuary.computer")
    pt = ProjectTracker.create!(name: "Some Project")
    grant = PermissionGrant.create!(admin_user: user, permission: "lead", subject_id: pt.id)
    assert_equal "ProjectTracker", grant.subject_type
    assert_equal pt, grant.subject
    refute grant.global?
  end

  test "duplicate grants are rejected" do
    user = make_user("trainee@sanctuary.computer")
    PermissionGrant.create!(admin_user: user, permission: "lead")
    dup = PermissionGrant.new(admin_user: user, permission: "lead")
    refute dup.valid?

    pt = ProjectTracker.create!(name: "Some Project")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)
    scoped_dup = PermissionGrant.new(admin_user: user, permission: "lead", subject: pt)
    refute scoped_dup.valid?
  end

  test "subject_type outside the allow-list is rejected" do
    user = make_user("trainee@sanctuary.computer")
    grant = PermissionGrant.new(admin_user: user, permission: "lead", subject_type: "Studio", subject_id: 1)
    refute grant.valid?
    assert grant.errors[:subject_type].any?
  end
end
