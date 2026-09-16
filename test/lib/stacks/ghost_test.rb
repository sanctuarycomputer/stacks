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

  test "all_newsletters fetches the newsletters collection" do
    client = build_client
    resp = fake_response(code: 200, body: { newsletters: [{ id: "nl-1", slug: "garden3d" }] })
    Stacks::Ghost.expects(:get).with { |url, _opts| url.include?("/newsletters/") }.returns(resp)
    assert_equal "garden3d", client.all_newsletters.first["slug"]
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

  MEMBER_ID = "6aaa0647345d7200012fc658".freeze

  def nl_event(member_id: MEMBER_ID, newsletter_id: "nl-1", subscribed: true, created_at: "2026-09-16T03:00:23.000Z")
    { "type" => "newsletter_event",
      "data" => { "id" => "ev-#{rand(1_000_000)}", "member_id" => member_id,
                  "subscribed" => subscribed, "created_at" => created_at,
                  "source" => "api", "newsletter_id" => newsletter_id } }
  end

  def events_response(events, total: nil)
    fake_response(code: 200, body: {
      events: events,
      meta: { pagination: { limit: 100, total: total || events.length, pages: 1, page: nil, next: nil } },
    })
  end

  test "newsletter_events_for returns events and filters by type and member only" do
    client = build_client
    Stacks::Ghost.expects(:get).with { |url, opts|
      url.include?("/members/events/") &&
        opts[:query][:filter].include?("type:newsletter_event") &&
        opts[:query][:filter].include?(MEMBER_ID) &&
        # verified 400s if present
        !opts[:query][:filter].include?("data.subscribed") &&
        !opts[:query][:filter].include?("data.newsletter_id") &&
        # verified silently ignored on this endpoint
        !opts[:query].key?(:page) &&
        opts[:query][:limit] == 100
    }.returns(events_response([nl_event]))

    events = client.newsletter_events_for(MEMBER_ID)
    assert_equal 1, events.length
    assert_equal "nl-1", events.first["data"]["newsletter_id"]
  end

  test "newsletter_events_for rejects a malformed member id without issuing a request" do
    client = build_client
    Stacks::Ghost.expects(:get).never
    ["not-an-id", "", nil, "6AAA0647345D7200012FC658", "6aaa0647345d7200012fc65"].each do |bad|
      assert_raises(Stacks::Ghost::UntrustworthyHistory) { client.newsletter_events_for(bad) }
    end
  end

  test "newsletter_events_for raises when an event belongs to a different member" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event(member_id: "someone-else")]))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) { client.newsletter_events_for(MEMBER_ID) }
  end

  test "newsletter_events_for raises when fewer events are collected than meta.pagination.total" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event], total: 7))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) { client.newsletter_events_for(MEMBER_ID) }
  end

  test "newsletter_events_for raises on an empty history for a member that has live subscriptions" do
    # A 200 with an empty list is what a nonexistent or malformed member id returns.
    # A member currently subscribed to something MUST have at least one event, so an
    # empty result here is incoherent and must never read as "never subscribed".
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
  end

  test "newsletter_events_for allows a genuinely empty history for a member with no subscriptions" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    assert_equal [], client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
  end

  test "newsletter_events_for pages with a raw-quoted created_at cursor, never the page param" do
    client = build_client
    page1 = Array.new(100) { |i| nl_event(created_at: "2026-09-#{format('%02d', 16 - (i / 20))}T03:00:23.000Z") }
    page2 = [nl_event(created_at: "2026-08-01T00:00:00.000Z")]
    seen_filters = []
    Stacks::Ghost.stubs(:get).with { |_url, opts| seen_filters << opts[:query][:filter]; true }
      .returns(events_response(page1, total: 101)).then.returns(events_response(page2, total: 101))

    events = client.newsletter_events_for(MEMBER_ID)
    assert_equal 101, events.length
    assert_equal 2, seen_filters.length
    assert seen_filters[1].include?("data.created_at:<'"), "cursor must use raw single quotes"
    refute seen_filters[1].include?("%27"), "percent-encoded quotes yield 422"
  end

  test "newsletter_events_for raises rather than looping when a page does not advance the cursor" do
    client = build_client
    stuck = Array.new(100) { nl_event(created_at: "2026-09-16T03:00:23.000Z") }
    Stacks::Ghost.stubs(:get).returns(events_response(stuck, total: 500))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) { client.newsletter_events_for(MEMBER_ID) }
  end

  test "find_member requests one member with labels and newsletters" do
    client = build_client
    Stacks::Ghost.expects(:get).with { |url, opts|
      url.include?("/members/m1/") && opts[:query][:include] == "labels,newsletters"
    }.returns(fake_response(code: 200, body: { members: [{ id: "m1", email: "a@x.com" }] }))
    assert_equal "m1", client.find_member("m1")["id"]
  end
end
