require 'test_helper'

class Stacks::GhostTest < ActiveSupport::TestCase
  # Secret must be hex — Ghost hex-decodes it before signing.
  FAKE_CONFIG = {
    ghost: {
      api_url: "https://example.ghost.io",
      admin_api_key: "65abc123def:0123456789abcdef0123456789abcdef",
    },
  }.freeze

  def build_client(max_retries: 0)
    Stacks::Utils.stubs(:config).returns(FAKE_CONFIG)
    Stacks::Ghost.new(max_retries: max_retries)
  end

  def fake_response(code:, body:)
    resp = mock("response")
    resp.stubs(:success?).returns(code < 400)
    resp.stubs(:code).returns(code)
    resp.stubs(:body).returns(JSON.dump(body))
    resp.stubs(:parsed_response).returns(body.deep_stringify_keys)
    resp
  end

  test "token is an HS256 JWT signed with the hex-decoded secret, kid header, /admin/ audience" do
    client = build_client
    secret = ["0123456789abcdef0123456789abcdef"].pack("H*")
    payload, header = JWT.decode(client.token, secret, true, { algorithm: "HS256" })
    assert_equal "65abc123def", header["kid"]
    assert_equal "/admin/", payload["aud"]
    assert_in_delta Time.now.to_i, payload["iat"], 5
    assert_operator payload["exp"] - payload["iat"], :<=, 300
  end

  test "all_members paginates until meta.pagination.next is nil" do
    client = build_client
    page1 = fake_response(code: 200, body: {
      members: [{ id: "m1", email: "a@x.com" }],
      meta: { pagination: { next: 2 } },
    })
    page2 = fake_response(code: 200, body: {
      members: [{ id: "m2", email: "b@x.com" }],
      meta: { pagination: { next: nil } },
    })
    Stacks::Ghost.stubs(:get).returns(page1).then.returns(page2)
    members = client.all_members
    assert_equal %w[m1 m2], members.map { |m| m["id"] }
  end

  test "find_member_by_email returns the first match or nil" do
    client = build_client
    found = fake_response(code: 200, body: { members: [{ id: "m1", email: "a@x.com" }] })
    empty = fake_response(code: 200, body: { members: [] })
    Stacks::Ghost.stubs(:get).returns(found).then.returns(empty)
    assert_equal "m1", client.find_member_by_email("A@x.com")["id"]
    assert_nil client.find_member_by_email("nope@x.com")
  end

  test "non-success raises RequestError with code; 422 is not retryable" do
    client = build_client
    Stacks::Ghost.stubs(:post).returns(
      fake_response(code: 422, body: { errors: [{ message: "Member already exists." }] })
    )
    error = assert_raises(Stacks::Ghost::RequestError) do
      client.create_member(email: "dupe@x.com")
    end
    assert_equal 422, error.code
    assert_not error.retryable?
  end

  test "retryable errors are retried up to max_retries then raised" do
    client = build_client(max_retries: 2)
    client.stubs(:backoff) # don't sleep in tests
    # 1 initial attempt + 2 retries = exactly 3 calls
    Stacks::Ghost.expects(:get).times(3).returns(fake_response(code: 500, body: { errors: [] }))
    error = assert_raises(Stacks::Ghost::RequestError) { client.all_members }
    assert_equal 500, error.code
  end
end
