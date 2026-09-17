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

  test "May subscribe count excludes a contact whose only enabled source is not the matching one" do
    # `team` is enabled and mapped to nothing; `index:...` is NOT enabled but is mapped
    # to a newsletter. target_newsletter_ids only ever derives newsletters from
    # (contact.sources & enabled), so this contact will never be subscribed under
    # `index` -- the panel must not count it there.
    System.first_or_create!(settings: {}).update!(
      ghost_synced_sources: ["team"],
      ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "trap@example.com", sources: ["team", "index:luma:chinatown"])
    Stacks::Ghost.any_instance.stubs(:all_newsletters).returns(
      [{ "id" => "nl-index", "name" => "Index Space", "slug" => "index", "status" => "active" }])

    get admin_ghost_sync_path
    assert_response :success

    doc = Nokogiri::HTML(response.body)
    row = doc.css("tr").find { |tr| tr.at_css("td.col-prefix")&.text&.strip == "index" }
    assert row, "expected a table row for the 'index' prefix"
    assert_equal "0", row.at_css("td.col-may_subscribe")&.text&.strip,
      "a contact whose only enabled source is unrelated to 'index' must not be counted " \
      "under 'index': the sweep will never subscribe it"
  end

  test "the newsletter list rendering does not mark itself renderable when a successful fetch omits a mapped id" do
    System.first_or_create!(settings: {}).update!(
      ghost_newsletter_prefix_map: { "index" => "nl-index", "xxix" => "nl-xxix" })
    Contact.create!(email: "partial@example.com", sources: ["index:shopify_customer"])
    # The call succeeds (no exception) but the returned list omits nl-xxix -- e.g. a
    # plan change, every matching newsletter archived, or a partial response.
    Stacks::Ghost.any_instance.stubs(:all_newsletters).returns(
      [{ "id" => "nl-index", "name" => "Index Space", "slug" => "index", "status" => "active" }])

    get admin_ghost_sync_path
    assert_response :success

    doc = Nokogiri::HTML(response.body)
    hidden = doc.at_css('input[name="newsletters_ok"]')
    assert_equal "0", hidden["value"],
      "a successful-but-incomplete newsletter list must not be reported as renderable"
    submit = doc.at_css('input[type="submit"][value="Save Newsletter Settings"]')
    assert submit["disabled"],
      "saving must be disabled: submitting would silently drop the xxix mapping"
  end

  test "a submission posted while the newsletter list was successful but incomplete does not wipe the missing prefix" do
    System.first_or_create!(settings: {}).update!(
      ghost_newsletter_prefix_map: { "index" => "nl-index", "xxix" => "nl-xxix" })

    # Simulates exactly what the dropdown-defaulted-to-blank submission this state
    # produces: xxix's <select> has no `selected:` option (its id was not in the
    # successful-but-incomplete list), so it posts "" for that prefix while "index"
    # (which WAS represented) posts its real value -- a PARTIAL, non-empty map, which
    # a guard gated only on `map.empty?` could never catch.
    post admin_ghost_sync_update_newsletter_settings_path, params: {
      prefix_map: { "index" => "nl-index", "xxix" => "" },
      newsletters_ok: "0",
      grants_enabled: "0",
      write_budget: "2500",
    }

    assert_redirected_to admin_ghost_sync_path
    assert_equal({ "index" => "nl-index", "xxix" => "nl-xxix" },
      System.first.reload.ghost_newsletter_prefix_map_clean,
      "a partial map posted while newsletters_ok=0 must not silently drop the xxix mapping")
  end

  test "a deliberate unmap of the last prefix succeeds" do
    System.first_or_create!(settings: {}).update!(
      ghost_newsletter_prefix_map: { "index" => "nl-index" })

    post admin_ghost_sync_update_newsletter_settings_path, params: {
      prefix_map: { "index" => "" },
      newsletters_ok: "1",
      grants_enabled: "0",
      write_budget: "2500",
    }

    assert_redirected_to admin_ghost_sync_path
    assert_equal({}, System.first.reload.ghost_newsletter_prefix_map_clean,
      "a deliberate unmap at n=1, submitted while the newsletter list rendered fine, must succeed")
  end

  test "a submission made while the newsletter list is unavailable does not clear a non-empty map" do
    System.first_or_create!(settings: {}).update!(
      ghost_newsletter_prefix_map: { "index" => "nl-index" })

    post admin_ghost_sync_update_newsletter_settings_path, params: {
      prefix_map: { "index" => "" },
      newsletters_ok: "0",
      grants_enabled: "0",
      write_budget: "2500",
    }

    assert_redirected_to admin_ghost_sync_path
    assert_equal({ "index" => "nl-index" }, System.first.reload.ghost_newsletter_prefix_map_clean,
      "a submission posted while newsletters_ok=0 must never clear an existing mapping")
  end

  # Minor #9: the label must come from the sweep-persisted id-to-name map, not from
  # inverting the prefix map -- an inverted map shows the source PREFIX (e.g.
  # "index"), not the newsletter's actual name, and collapses whenever two prefixes
  # map to the same newsletter id.
  test "contact show page resolves newsletter ledger ids to the newsletter name persisted by the sweep" do
    System.first_or_create!(settings: {}).update!(
      ghost_newsletter_prefix_map: { "index" => "nl-index" },
      ghost_newsletter_name_by_id: { "nl-index" => "Index Space" })
    contact = Contact.create!(email: "ledger@example.com", sources: ["index:luma:chinatown"])
    contact.record_ledger_entry!("nl-index", "granted", member_id: "member-1")
    contact.save!

    get admin_contact_path(contact)
    assert_response :success
    assert_match "Index Space: granted", response.body
    assert_no_match "nl-index", response.body
    assert_no_match ">index: granted", response.body
  end

  test "contact show page falls back to the raw newsletter id when the sweep has never persisted a name for it" do
    contact = Contact.create!(email: "unknown-nl@example.com", sources: ["index:luma:chinatown"])
    contact.record_ledger_entry!("nl-mystery", "granted", member_id: "member-1")
    contact.save!

    get admin_contact_path(contact)
    assert_response :success
    assert_match "nl-mystery: granted", response.body
  end
end
