require 'test_helper'

class Api::ContactsControllerTest < ActionDispatch::IntegrationTest
  test "it fails with an incorrect API key" do
    post "/api/contacts"
    assert_response :forbidden
  end

  test "index fails without API key" do
    get "/api/contacts", params: { source: "foobar" }
    assert_response :forbidden
  end

  test "index requires source query param" do
    get "/api/contacts",
      headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_includes body["error"], "source"
  end

  test "index returns contacts whose sources include the given source" do
    api_key = { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }

    post "/api/contacts",
      headers: api_key,
      params: {
        email: "alpha@example.com",
        sources: %w[foobar newsletter],
        metadata: { label: "a" },
      },
      as: :json

    post "/api/contacts",
      headers: api_key,
      params: {
        email: "beta@example.com",
        sources: ["other"],
        metadata: { label: "b" },
      },
      as: :json

    get "/api/contacts",
      headers: api_key,
      params: { source: "foobar" }

    assert_response :success
    list = JSON.parse(response.body)
    assert_equal 1, list.length
    row = list.first
    assert_equal "alpha@example.com", row["email"]
    assert_equal %w[foobar newsletter], row["sources"]
    assert_equal({ "label" => "a" }, row["metadata"])
  end

  test "it fails with bad email address" do
    post "/api/contacts",
      headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] },
      params: { email: "hugh@" },
      as: :json
    assert_response :unprocessable_entity
  end

  test "it works with a correct API key" do
    assert_difference("Contact.count", 1) do
      post "/api/contacts",
        headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] },
        params: { email: "hugh@sanctuary.computer" },
        as: :json
    end

    assert Contact.first.email, "hugh@sanctuary.computer"
    assert Contact.first.sources, []

    assert_difference("Contact.count", 0) do
      post "/api/contacts",
        headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] },
        params: { email: "hugh@sanctuary.computer", sources: ["substack"] },
        as: :json
    end

    assert Contact.first.email, "hugh@sanctuary.computer"
    assert Contact.first.sources, ["substack"]

    assert_response :success
  end

  test "it deep-merges arbitrary JSON from the metadata key only" do
    email = "blob-test@sanctuary.computer"

    post "/api/contacts",
      headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] },
      params: {
        email: email,
        sources: ["newsletter"],
        metadata: {
          funnel: "landing",
          extra: { tier: "pro", flags: %w[a b] },
        },
      },
      as: :json

    assert_response :success
    contact = Contact.find_by!(email: email)
    assert_equal "landing", contact.metadata["funnel"]
    assert_equal "pro", contact.metadata.dig("extra", "tier")
    assert_equal %w[a b], contact.metadata.dig("extra", "flags")
    refute contact.metadata.key?("email")
    assert_equal ["newsletter"], contact.sources

    post "/api/contacts",
      headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] },
      params: {
        email: email,
        metadata: {
          extra: { tier: "enterprise", "note" => "upsell" },
        },
      },
      as: :json

    assert_response :success
    contact.reload
    assert_equal "enterprise", contact.metadata.dig("extra", "tier")
    assert_equal "upsell", contact.metadata.dig("extra", "note")
    assert_equal %w[a b], contact.metadata.dig("extra", "flags")
    assert_equal "landing", contact.metadata["funnel"]
  end

  test "index includes source_events so callers can read view counts" do
    api_key = { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }
    email = "view-counts@example.com"

    2.times do
      post "/api/contacts", headers: api_key,
        params: { email: email, sources: ["fundraising"] }, as: :json
    end

    get "/api/contacts", headers: api_key, params: { source: "fundraising" }
    assert_response :success
    row = JSON.parse(response.body).first
    assert_equal 2, row["source_events"]["fundraising"].length
  end

  test "appends a timestamped source event on every post, even for duplicate sources" do
    api_key = { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] }
    email = "views@example.com"

    post "/api/contacts", headers: api_key,
      params: { email: email, sources: %w[newsletter fundraising] }, as: :json
    post "/api/contacts", headers: api_key,
      params: { email: email, sources: ["fundraising"] }, as: :json

    assert_response :success
    contact = Contact.find_by!(email: email)
    assert_equal %w[newsletter fundraising], contact.sources
    assert_equal 1, contact.source_events["newsletter"].length
    assert_equal 2, contact.source_events["fundraising"].length
    contact.source_events.values.flatten.each do |event|
      assert_equal ["added_at"], event.keys
      assert Time.iso8601(event["added_at"])
    end
  end

  test "records no source events when no sources are posted" do
    post "/api/contacts",
      headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] },
      params: { email: "no-events@example.com" },
      as: :json

    assert_response :success
    assert_equal({}, Contact.find_by!(email: "no-events@example.com").source_events)
  end

  test "top-level keys outside metadata are not stored in contact metadata" do
    email = "no-leak@sanctuary.computer"

    post "/api/contacts",
      headers: { "X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key] },
      params: { email: email, funnel: "should_not_persist" },
      as: :json

    assert_response :success
    contact = Contact.find_by!(email: email)
    assert_equal({}, contact.metadata)
  end
end
