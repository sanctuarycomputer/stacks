require 'test_helper'

class Api::ContactsControllerTest < ActionDispatch::IntegrationTest
  test "it fails with an incorrect API key" do
    post "/api/contacts"
    assert_response :forbidden
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
end
