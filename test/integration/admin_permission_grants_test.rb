require 'test_helper'

class AdminPermissionGrantsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def make_project_tracker(name)
    pt = ProjectTracker.new(name: name)
    pt.save!(validate: false)
    pt
  end

  setup do
    @admin = AdminUser.create!(
      email: "hugh@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345',
      roles: ['admin']
    )
    @trainee = AdminUser.create!(
      email: "trainee@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345'
    )
  end

  test "an admin can create a global lead grant from the edit form" do
    sign_in @admin
    put admin_admin_user_path(@trainee), params: {
      admin_user: {
        permission_grants_attributes: {
          "0" => { permission: "lead", subject_id: "", notes: "AL training" }
        }
      }
    }
    assert_equal 1, @trainee.reload.permission_grants.count
    grant = @trainee.permission_grants.first
    assert grant.global?
    assert_equal @admin.id, grant.granted_by_id
    assert @trainee.can_act_as_lead?
  end

  test "an admin can create a project-scoped grant" do
    pt = make_project_tracker("Training Project")
    sign_in @admin
    put admin_admin_user_path(@trainee), params: {
      admin_user: {
        permission_grants_attributes: {
          "0" => { permission: "lead", subject_id: pt.id.to_s }
        }
      }
    }
    grant = @trainee.reload.permission_grants.first
    assert_equal pt, grant.subject
    refute @trainee.can_act_as_lead?
    assert_equal [pt.id], @trainee.lead_scoped_project_tracker_ids
  end

  test "a non-admin (even a global grantee) cannot create grants" do
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", granted_by: @admin)
    sign_in @trainee
    put admin_admin_user_path(@trainee), params: {
      admin_user: {
        profit_share_notes: "hi",
        permission_grants_attributes: {
          "0" => { permission: "lead", subject_id: "", notes: "sneaky second grant" }
        }
      }
    }
    assert_equal 1, @trainee.reload.permission_grants.count
  end

  test "a non-admin lead cannot promote themselves to admin" do
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", granted_by: @admin)
    sign_in @trainee
    post promote_admin_user_admin_admin_user_path(@trainee)
    refute @trainee.reload.is_admin?
  end

  test "a non-admin lead cannot demote an admin" do
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", granted_by: @admin)
    sign_in @trainee
    post demote_admin_user_admin_admin_user_path(@admin)
    assert @admin.reload.is_admin?
  end

  test "an admin can still promote and demote" do
    sign_in @admin
    post promote_admin_user_admin_admin_user_path(@trainee)
    assert @trainee.reload.is_admin?
    post demote_admin_user_admin_admin_user_path(@trainee)
    refute @trainee.reload.is_admin?
  end

  test "the show page lists grants for admins" do
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", granted_by: @admin, notes: "Q3 cohort")
    sign_in @admin
    get admin_admin_user_path(@trainee)
    assert_response :success
    assert_includes response.body, "Permission Grants"
    assert_includes response.body, "Q3 cohort"
  end

  test "a project-scoped grantee cannot see company-wide invoicing aggregates on the invoice passes index" do
    pt = make_project_tracker("Training Project")
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", subject: pt, granted_by: @admin)
    InvoicePass.create!(start_of_month: Date.today.beginning_of_month)

    sign_in @trainee
    get admin_invoice_passes_path
    assert_response :success
    refute_includes response.body, "Outstanding"
    refute_includes response.body, "Surplus"
  end

  test "an admin can see company-wide invoicing aggregates on the invoice passes index" do
    InvoicePass.create!(start_of_month: Date.today.beginning_of_month)

    sign_in @admin
    get admin_invoice_passes_path
    assert_response :success
    assert_includes response.body, "Outstanding"
    assert_includes response.body, "Surplus"
  end
end
