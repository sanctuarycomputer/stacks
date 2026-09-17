require "test_helper"

class AdminGhostSyncPageTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "admin-#{SecureRandom.hex(4)}@example.com",
      password: "password12345",
      password_confirmation: "password12345",
      roles: ["admin"]
    )
    sign_in @admin
  end

  test "the Ghost Sync page renders with a mapping configured" do
    System.first_or_create!(settings: {}).update!(
      ghost_synced_sources: ["index:shopify_customer"],
      ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "render@example.com", sources: ["index:shopify_customer"])
    Stacks::Ghost.any_instance.stubs(:all_newsletters).returns(
      [{ "id" => "nl-index", "name" => "Index Space", "slug" => "index", "status" => "active" }])

    get admin_ghost_sync_path
    assert_response :success
    assert_match "Index Space", response.body
  end

  test "saving synced sources preserves the newsletter mapping" do
    System.first_or_create!(settings: {}).update!(
      ghost_newsletter_prefix_map: { "index" => "nl-index" })
    post admin_ghost_sync_update_sources_path, params: { sources: ["index:shopify_customer"] }
    assert_equal({ "index" => "nl-index" },
      System.first.reload.ghost_newsletter_prefix_map_clean,
      "update_sources must not write back a stale settings hash")
  end
end
