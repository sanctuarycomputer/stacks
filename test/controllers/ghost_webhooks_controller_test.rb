require 'test_helper'

class GhostWebhooksControllerTest < ActionDispatch::IntegrationTest
  SECRET = "test-webhook-secret".freeze

  setup do
    GhostWebhooksController.any_instance.stubs(:webhook_secret).returns(SECRET)
    # Mock Stacks::Ghost to avoid real API calls; the webhook receiver doesn't
    # need Ghost methods beyond init—all logic is in Stacks::GhostSync.
    Stacks::Ghost.stubs(:new).returns(mock("ghost"))
  end

  def signed_post(payload, secret: SECRET, at: Time.current)
    body = JSON.dump(payload)
    ts = (at.to_f * 1000).to_i.to_s
    hex = OpenSSL::HMAC.hexdigest("SHA256", secret, body + ts)
    post "/webhooks/ghost", params: body, headers: {
      "Content-Type" => "application/json",
      "X-Ghost-Signature" => "sha256=#{hex}, t=#{ts}",
    }
  end

  def member_payload(id:, email:, newsletters: [])
    {
      "id" => id, "email" => email, "name" => nil,
      "labels" => [],
      "newsletters" => newsletters.map { |s| { "id" => "nl-#{s}", "slug" => s } },
    }
  end

  test "rejects a missing signature" do
    post "/webhooks/ghost", params: JSON.dump({}), headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  test "rejects a wrong-secret signature" do
    signed_post({ "member" => {} }, secret: "wrong")
    assert_response :unauthorized
  end

  test "rejects a stale timestamp" do
    signed_post({ "member" => {} }, at: 10.minutes.ago)
    assert_response :unauthorized
  end

  test "member.added upserts a contact into the funnel" do
    payload = {
      "member" => {
        "current" => member_payload(id: "m20", email: "hook@example.com", newsletters: %w[weekly-digest]),
        "previous" => {},
      },
    }
    assert_difference("Contact.count", 1) { signed_post(payload) }
    assert_response :ok
    contact = Contact.find_by(email: "hook@example.com")
    assert_equal "m20", contact.ghost_id
    assert_equal ["g3d:ghost:weekly-digest"], contact.sources
  end

  test "member.deleted clears the link but keeps the contact" do
    contact = Contact.create!(email: "del@example.com", ghost_id: "m21")
    payload = {
      "member" => {
        "current" => {},
        "previous" => member_payload(id: "m21", email: "del@example.com"),
      },
    }
    assert_no_difference("Contact.count") { signed_post(payload) }
    assert_response :ok
    assert_nil contact.reload.ghost_id
  end

  test "handler errors still return 200" do
    Stacks::GhostSync.any_instance.stubs(:upsert_contact_from_member).raises(StandardError.new("boom"))
    payload = {
      "member" => { "current" => member_payload(id: "m22", email: "err@example.com"), "previous" => {} },
    }
    signed_post(payload)
    assert_response :ok
  end

  test "unknown payload shape is a 200 no-op" do
    signed_post({ "post" => { "current" => { "id" => "p1" } } })
    assert_response :ok
  end

  test "rejects when no webhook secret is configured" do
    GhostWebhooksController.any_instance.stubs(:webhook_secret).returns("")
    signed_post({ "member" => {} }, secret: "")
    assert_response :unauthorized
  end

  test "rejects a non-numeric timestamp" do
    body = JSON.dump({ "member" => {} })
    hex = OpenSSL::HMAC.hexdigest("SHA256", SECRET, body + "abc")
    post "/webhooks/ghost", params: body, headers: {
      "Content-Type" => "application/json",
      "X-Ghost-Signature" => "sha256=#{hex}, t=abc",
    }
    assert_response :unauthorized
  end

  # Finding E: malformed header must return 401, not 200
  test "rejects a malformed X-Ghost-Signature header" do
    post "/webhooks/ghost",
      params: JSON.dump({ "member" => {} }),
      headers: {
        "Content-Type" => "application/json",
        "X-Ghost-Signature" => "garbage",
      }
    assert_response :unauthorized
  end
end
