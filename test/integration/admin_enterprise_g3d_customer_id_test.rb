require "test_helper"

# Storing an enterprise's customer id in garden3d's QuickBooks is what makes
# garden3d invoice it each month. Admins only, enforced on the server.
class AdminEnterpriseG3dCustomerIdTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ManagementFeeFixtures

  setup do
    @admin = AdminUser.create!(email: "g3d-id-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @lead = AdminUser.create!(email: "g3d-id-lead@sanctuary.computer", password: "password12345")
    PermissionGrant.create!(admin_user: @lead, permission: "lead")
    @enterprise = enterprises(:one)
    Stacks::Deel.stubs(:fetch_all_legal_entities).returns([])
  end

  # The form always posts the QuickBooks token fields; the update reads them.
  def update_params
    { enterprise: { g3d_qbo_customer_id: "41", qbo_token: { unchanged: "1" } } }
  end

  test "an admin stores the customer id, and the enterprise is then billed by garden3d" do
    refute_includes Enterprise.billed_by_garden3d, @enterprise
    sign_in @admin

    patch admin_enterprise_path(@enterprise), params: update_params

    assert_equal "41", @enterprise.reload.g3d_qbo_customer_id
    assert_includes Enterprise.billed_by_garden3d, @enterprise
  end

  test "a lead's update cannot set the customer id, whatever is posted" do
    sign_in @lead

    patch admin_enterprise_path(@enterprise), params: update_params

    assert_nil @enterprise.reload.g3d_qbo_customer_id
  end

  test "the field is a dropdown of garden3d's QuickBooks customers, and not on garden3d's own form" do
    garden3d_qbo_account
    @enterprise.update_columns(g3d_qbo_customer_id: "9")
    QboAccount.any_instance.stubs(:fetch_all_customers)
              .returns([qbo_customer("41", "Zed Co"), qbo_customer("7", "Acme Co")])
    sign_in @admin

    get edit_admin_enterprise_path(@enterprise)
    assert_response :success
    assert_select "select#enterprise_g3d_qbo_customer_id option", count: 4
    assert_select "select#enterprise_g3d_qbo_customer_id option[value='41']", text: "Zed Co (41)"
    assert_select "select#enterprise_g3d_qbo_customer_id option[value='7']", text: "Acme Co (7)"
    # The stored id QuickBooks no longer lists stays selected.
    assert_select "select#enterprise_g3d_qbo_customer_id option[value='9'][selected]", count: 1

    get edit_admin_enterprise_path(enterprises(:garden3d))
    assert_response :success
    assert_select "#enterprise_g3d_qbo_customer_id", count: 0
  end

  test "when garden3d's QuickBooks cannot be read, the field is a text input" do
    garden3d_qbo_account
    QboAccount.any_instance.stubs(:fetch_all_customers).raises(RuntimeError, "QuickBooks is down")
    sign_in @admin

    get edit_admin_enterprise_path(@enterprise)

    assert_response :success
    assert_select "input#enterprise_g3d_qbo_customer_id", count: 1
  end

  test "a lead's edit form has no such field, and asks QuickBooks nothing" do
    garden3d_qbo_account
    QboAccount.any_instance.expects(:fetch_all_customers).never
    sign_in @lead

    get edit_admin_enterprise_path(@enterprise)

    assert_response :success
    assert_select "#enterprise_g3d_qbo_customer_id", count: 0
  end
end
