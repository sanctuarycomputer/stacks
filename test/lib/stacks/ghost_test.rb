require 'test_helper'

class Stacks::GhostTest < ActiveSupport::TestCase
  # Secret must be hex — Ghost hex-decodes it before signing.
  FAKE_CONFIG = {
    ghost: {
      api_url: "https://example.ghost.io",
      admin_api_key: "65abc123def:0123456789abcdef0123456789abcdef",
    },
  }.freeze

  MEMBER_ID = "6aaa0647345d7200012fc658".freeze

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

  def nl_event(member_id: MEMBER_ID, newsletter_id: "nl-1", subscribed: true,
               created_at: "2026-09-16T03:00:23.000Z", type: "newsletter_event")
    { "type" => type,
      "data" => { "id" => "ev-1", "member_id" => member_id, "subscribed" => subscribed,
                  "created_at" => created_at, "source" => "api", "newsletter_id" => newsletter_id } }
  end

  def events_response(events, total: nil, meta: :default)
    body = { events: events }
    unless meta == :omit
      body[:meta] = { pagination: { limit: 100, total: total || events.length, pages: 1 } }
    end
    fake_response(code: 200, body: body)
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

  test "newsletter_events_for issues ONE request, filtered by type and member only" do
    client = build_client
    Stacks::Ghost.expects(:get).once.with { |url, opts|
      url.include?("/members/events/") &&
        opts[:query][:filter].include?("type:newsletter_event") &&
        opts[:query][:filter].include?(MEMBER_ID) &&
        !opts[:query][:filter].include?("data.subscribed") &&   # verified 400
        !opts[:query][:filter].include?("data.newsletter_id") && # verified 400
        !opts[:query][:filter].include?("%27") &&                # verified 422
        !opts[:query].key?(:page) &&                             # verified ignored
        !opts[:query].key?(:order) &&                            # verified ignored
        opts[:query][:limit] == 100
    }.returns(events_response([nl_event]))

    events = client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    assert_equal 1, events.length
    assert_equal "nl-1", events.first["data"]["newsletter_id"]
  end

  test "newsletter_events_for rejects a malformed member id without issuing a request" do
    client = build_client
    Stacks::Ghost.expects(:get).never
    ["not-an-id", "", nil, :"6aaa0647345d7200012fc658",
     "6AAA0647345D7200012FC658", "6aaa0647345d7200012fc65"].each do |bad|
      assert_raises(Stacks::Ghost::UntrustworthyHistory, "accepted #{bad.inspect}") do
        client.newsletter_events_for(bad, current_newsletter_ids: [])
      end
    end
  end

  test "newsletter_events_for raises when an event belongs to a different member" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event(member_id: "someone-else")]))
    err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
    assert_match(/someone-else/, err.message)
  end

  test "newsletter_events_for raises on an event of the wrong type" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event(type: "email_delivered_event")]))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
  end

  test "newsletter_events_for raises when the member has more events than one page can carry" do
    # page and order are both silently ignored, so a second page cannot be fetched
    # reliably. Fail closed rather than return a truncated history.
    client = build_client
    Stacks::Ghost.expects(:get).once.returns(events_response(Array.new(100) { nl_event }, total: 150))
    err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
    assert_match(/100 of 150/, err.message)
  end

  test "newsletter_events_for raises when the collected count exceeds total" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event, nl_event], total: 1))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
  end

  test "newsletter_events_for raises when meta.pagination.total is absent or not an Integer" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([], meta: :omit))
    err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
    assert_match(/meta\.pagination\.total/, err.message)

    # A Float total is what makes the Integer check load-bearing: 1 == 1.0 in Ruby, so
    # without it this response passes the completeness check and is accepted.
    Stacks::Ghost.stubs(:get).returns(events_response([nl_event], total: 1.0))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
  end

  test "newsletter_events_for raises when meta itself is a scalar" do
    # body.dig would raise TypeError here, escaping the fail-closed error class.
    client = build_client
    [{ events: [], meta: "nope" }, { events: [], meta: [] }].each do |body|
      Stacks::Ghost.stubs(:get).returns(fake_response(code: 200, body: body))
      assert_raises(Stacks::Ghost::UntrustworthyHistory) do
        client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
      end
    end
  end

  test "newsletter_events_for raises when the response body is not an object at all" do
    client = build_client
    resp = mock("response")
    resp.stubs(:success?).returns(true)
    resp.stubs(:code).returns(200)
    resp.stubs(:body).returns("<html>gateway error</html>")
    resp.stubs(:parsed_response).returns("<html>gateway error</html>")
    Stacks::Ghost.stubs(:get).returns(resp)
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
  end

  test "newsletter_events_for raises on an empty history for a member with live subscriptions" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    # never: the coherence guard must fire on its own, not fall through to the probe.
    client.expects(:find_member).never
    err = assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: ["nl-1"])
    end
    assert_match(/subscribed to 1 newsletter/, err.message)
  end

  test "an empty history fails closed when the existence probe 404s" do
    # Verified live: GET /members/<unknown>/ answers 404, so find_member RAISES rather
    # than returning nil. This is the realistic shape of the case the probe exists for.
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    client.expects(:find_member).with(MEMBER_ID)
      .raises(Stacks::Ghost::RequestError.new(404, "not found"))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
  end

  test "an empty history fails closed when the probe returns a different member" do
    # This is the ONLY exit that lets a caller conclude "never subscribed" and grant,
    # so bare truthiness is not enough.
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    [{}, { "id" => "someotheridsomeotherid00" }].each do |probed|
      client.stubs(:find_member).returns(probed)
      assert_raises(Stacks::Ghost::UntrustworthyHistory) do
        client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
      end
    end
  end

  test "an empty history is confirmed against the member actually existing" do
    # The coherence guard above is inert when current_newsletter_ids is empty, which is
    # exactly the case for someone who unsubscribed from everything: the population this
    # feature exists to protect. Their empty history is indistinguishable from a
    # nonexistent or mistyped id, which returns the same 200 {"events": []}.
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    client.expects(:find_member).with(MEMBER_ID).returns(nil)
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end
  end

  test "a genuinely empty history for a confirmed member is allowed" do
    client = build_client
    Stacks::Ghost.stubs(:get).returns(events_response([]))
    client.expects(:find_member).with(MEMBER_ID).returns({ "id" => MEMBER_ID, "newsletters" => [] })
    assert_equal [], client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
  end

  test "newsletter_events_for raises rather than NoMethodError on malformed events" do
    # One malformed member must not take down the whole sweep. Each case carries a VALID
    # meta.pagination.total, so it reaches the per-event shape guards rather than being
    # short-circuited by the total check (which would make those guards deletable with
    # the suite still green).
    client = build_client
    Stacks::Ghost.stubs(:get).returns(fake_response(code: 200, body: { events: "not-an-array",
      meta: { pagination: { limit: 100, total: 0, pages: 1 } } }))
    assert_raises(Stacks::Ghost::UntrustworthyHistory) do
      client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
    end

    [events_response(["not-a-hash"], total: 1),
     events_response([{ "type" => "newsletter_event", "data" => "scalar" }], total: 1)].each do |resp|
      Stacks::Ghost.stubs(:get).returns(resp)
      assert_raises(Stacks::Ghost::UntrustworthyHistory) do
        client.newsletter_events_for(MEMBER_ID, current_newsletter_ids: [])
      end
    end
  end

  test "find_member requests one member with labels and newsletters" do
    client = build_client
    Stacks::Ghost.expects(:get).with { |url, opts|
      url.include?("/members/m1/") && opts[:query][:include] == "labels,newsletters"
    }.returns(fake_response(code: 200, body: { members: [{ id: "m1", email: "a@x.com" }] }))
    assert_equal "m1", client.find_member("m1")["id"]
  end
end
