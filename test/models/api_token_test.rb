require 'test_helper'

class ApiTokenTest < ActiveSupport::TestCase
  test "mint stores only a digest; the plaintext authenticates and is never saved" do
    record, raw = ApiToken.mint!(name: "t", scopes: ["mcp:read"])
    assert raw.start_with?("stk_")
    assert_equal Digest::SHA256.hexdigest(raw), record.token_digest
    refute ApiToken.where(token_digest: raw).exists?, "the plaintext is never a column value"
    assert_equal record.token_prefix, raw[0, 12]
    assert_equal record, ApiToken.authenticate(raw)
  end

  test "revocation and expiry take effect immediately (nothing is cached)" do
    record, raw = ApiToken.mint!(name: "t", scopes: ["mcp:read"])
    assert ApiToken.authenticate(raw)
    record.revoke!
    assert_nil ApiToken.authenticate(raw)
    _, raw2 = ApiToken.mint!(name: "t2", scopes: ["mcp:read"], expires_at: 1.minute.ago)
    assert_nil ApiToken.authenticate(raw2)
  end

  test "unknown or legacy-looking values never authenticate; unknown scopes are refused" do
    assert_nil ApiToken.authenticate("")
    assert_nil ApiToken.authenticate("stk_not-a-real-token")
    assert_nil ApiToken.authenticate(Stacks::Utils.config[:stacks][:private_api_key])
    assert_raises(ActiveRecord::RecordInvalid) { ApiToken.mint!(name: "t", scopes: ["mcp:write:everything"]) }
    assert_raises(ActiveRecord::RecordInvalid) { ApiToken.mint!(name: "t", scopes: []) }
  end

  test "without the table (deploy before migration) tokens simply don't exist yet" do
    ApiToken.stub(:available?, false) do
      _, raw = [nil, "stk_whatever"]
      assert_nil ApiToken.authenticate(raw)
    end
  end
end
