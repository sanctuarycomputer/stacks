require 'test_helper'

class AdminApiTokensTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "hugh@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345',
      roles: ['admin']
    )
    @lead = AdminUser.create!(
      email: "lead@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345'
    )
    PermissionGrant.create!(admin_user: @lead, permission: "lead", granted_by: @admin)
  end

  test "an admin mints a token, sees the plaintext once, and only its digest is stored" do
    sign_in @admin
    post admin_api_tokens_path, params: { api_token: { name: "Stacksbot write", scopes: ["", "mcp:write:trackers"] } }
    assert_response :success
    token = ApiToken.last
    assert_equal ["mcp:write:trackers"], token.scopes
    assert_equal @admin, token.created_by
    raw = response.body[/stk_[A-Za-z0-9_\-]{20,}/]
    assert raw, "the plaintext is on the mint page"
    assert_equal ApiToken.digest(raw), token.token_digest
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil flash[:notice], "the plaintext never goes into the session cookie"

    get admin_api_token_path(token)
    refute_includes response.body, raw, "it is not shown again"
  end

  test "an admin revokes a token and it stops authenticating" do
    record, raw = ApiToken.mint!(name: "x", scopes: ["mcp:read"], created_by: @admin, expires_at: nil)
    sign_in @admin
    post revoke_admin_api_token_path(record)
    assert record.reload.revoked_at
    assert_nil ApiToken.authenticate(raw)
  end

  test "a lead cannot see, mint, or revoke tokens" do
    record, _raw = ApiToken.mint!(name: "x", scopes: ["mcp:read"], created_by: @admin, expires_at: nil)
    sign_in @lead
    get admin_api_tokens_path
    refute response.successful?, "leads are refused the index"
    post admin_api_tokens_path, params: { api_token: { name: "sneaky", scopes: ["mcp:write:resourcing"] } }
    assert_equal 1, ApiToken.count
    post revoke_admin_api_token_path(record)
    assert_nil record.reload.revoked_at
  end
end
