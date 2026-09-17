require "test_helper"

class AdminGhostSyncPageTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    # Guard against System's process-lifetime memo leaking between tests: any prior
    # test (or the page itself, under a regression) can prime @@instance, which would
    # otherwise mask the very staleness bug the second test below exists to catch.
    System.class_variable_set(:@@instance, nil)
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
    # This has to PRIME the memo to discriminate. System.instance caches a System object
    # for the life of the process; Storext then writes the whole settings jsonb column
    # from whatever that cached object holds. So the bug only shows when the row has
    # moved on since the cache was populated, which is the real-world case: one puma
    # worker saves the mapping, another still holds a pre-mapping instance.
    System.first_or_create!(settings: {}).update!(
      ghost_newsletter_prefix_map: { "index" => "nl-index" })
    System.instance   # prime with the one-entry map
    # Now the row moves on behind the memo, as another worker or a rake dyno would do.
    System.first.update!(
      ghost_newsletter_prefix_map: { "index" => "nl-index", "xxix" => "nl-xxix" })

    post admin_ghost_sync_update_sources_path, params: { sources: ["index:shopify_customer"] }

    assert_equal({ "index" => "nl-index", "xxix" => "nl-xxix" },
      System.first.reload.ghost_newsletter_prefix_map_clean,
      "update_sources must read fresh: a stale settings hash silently deletes the mapping")
  ensure
    System.class_variable_set(:@@instance, nil)
  end
end
