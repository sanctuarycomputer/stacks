require 'test_helper'

class Stacks::GhostSyncTest < ActiveSupport::TestCase
  def member(id:, email:, labels: [], newsletters: [], name: nil, extra: {})
    {
      "id" => id, "email" => email, "name" => name,
      "labels" => labels.map { |n| { "name" => n, "slug" => n.parameterize } },
      "newsletters" => newsletters.map { |s| { "id" => "nl-#{s}", "slug" => s, "name" => s.titleize } },
    }.merge(extra)
  end

  def sync_with(ghost)
    Stacks::GhostSync.new(ghost)
  end

  def enable_sources(*sources)
    System.first_or_create!(settings: {}).update!(ghost_synced_sources: sources)
  end

  # Generic System settings writer for tests, going through first_or_create!
  # rather than the memoized System.instance (see the "reads settings fresh"
  # test below for why that memo is dangerous inside a test transaction).
  def sys!(**attrs)
    System.first_or_create!(settings: {}).update!(attrs)
  end

  def enabled_sources
    System.first_or_create!(settings: {}).ghost_synced_sources
  end

  # Minimal active-newsletter payloads, keyed by id, for stubbing all_newsletters.
  def active_nl(*ids)
    ids.map { |id| { "id" => id, "name" => id, "slug" => id, "status" => "active" } }
  end

  test "upsert resolves newsletter slugs via the newsletters endpoint when the member payload lacks them" do
    ghost = mock("ghost")
    # .once also proves the map is memoized across upserts on the same sync
    ghost.expects(:all_newsletters).once.returns([
      { "id" => "nl-1", "name" => "garden3d", "slug" => "garden3d" },
    ])
    sync = sync_with(ghost)
    slugless = { "newsletters" => [{ "id" => "nl-1", "name" => "garden3d", "status" => "active" }] }

    contact = sync.upsert_contact_from_member(
      member(id: "m40", email: "slugless@example.com", extra: slugless)
    ).reload
    assert_equal ["g3d:ghost:garden3d"], contact.sources

    contact2 = sync.upsert_contact_from_member(
      member(id: "m41", email: "slugless2@example.com", extra: slugless)
    ).reload
    assert_equal ["g3d:ghost:garden3d"], contact2.sources
  end

  test "upsert does not call the newsletters endpoint when payload slugs are present" do
    ghost = mock("ghost")
    ghost.expects(:all_newsletters).never
    sync = sync_with(ghost)
    contact = sync.upsert_contact_from_member(
      member(id: "m42", email: "hasslug@example.com", newsletters: %w[weekly])
    ).reload
    assert_equal ["g3d:ghost:weekly"], contact.sources
  end

  test "creates a member with source-name labels for an eligible contact and links ghost_id" do
    enable_sources("newsletter")
    contact = Contact.create!(email: "new@example.com", sources: ["newsletter"], display_name: "New Person")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    created = member(id: "m1", email: "new@example.com", labels: ["newsletter"], newsletters: ["weekly"])
    ghost.expects(:create_member)
      .with { |attrs|
        attrs[:email] == "new@example.com" && attrs[:name] == "New Person" &&
          attrs[:labels] == ["newsletter"] && attrs[:newsletters] == []
      }
      .returns(created)

    sync = sync_with(ghost)
    sync.sync_all!
    contact.reload
    assert_equal "m1", contact.ghost_id
    assert contact.ghost_data["synced_at"].present?
    assert_equal 1, sync.summary[:created]
  end

  test "updates managed labels while preserving unmanaged (hand-added) labels; never writes newsletters" do
    enable_sources("newsletter", "fundraising")
    contact = Contact.create!(
      email: "update@example.com",
      sources: %w[newsletter fundraising],
      ghost_id: "m2"
    )
    existing = member(id: "m2", email: "update@example.com",
      labels: ["VIP", "newsletter"], newsletters: ["weekly"], name: "Kept Name")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).with do |id, attrs|
      id == "m2" &&
        attrs[:labels].sort == ["VIP", "fundraising", "newsletter"] &&
        !attrs.key?(:newsletters) && !attrs.key?(:name)
    end.returns(existing.merge("labels" => [
      { "name" => "VIP" }, { "name" => "fundraising" }, { "name" => "newsletter" },
    ]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:updated]
  end

  test "no-op when labels already match" do
    enable_sources("newsletter")
    Contact.create!(email: "same@example.com", sources: ["newsletter"], ghost_id: "m3")
    existing = member(id: "m3", email: "same@example.com", labels: ["newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).never
    ghost.expects(:create_member).never

    sync_with(ghost).sync_all!
  end

  test "adopts the existing member on 422 duplicate-email create" do
    enable_sources("newsletter")
    contact = Contact.create!(email: "dupe@example.com", sources: ["newsletter"])
    existing = member(id: "m4", email: "dupe@example.com", labels: [])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([]) # not in the sweep snapshot (raced in)
    ghost.expects(:create_member).raises(Stacks::Ghost::RequestError.new(422, "Member already exists."))
    ghost.expects(:find_member_by_email).with("dupe@example.com").returns(existing)
    ghost.expects(:update_member).with do |id, attrs|
      id == "m4" && attrs[:labels] == ["newsletter"]
    end.returns(existing.merge("labels" => [{ "name" => "newsletter" }]))

    sync_with(ghost).sync_all!
    assert_equal "m4", contact.reload.ghost_id
  end

  test "delabels a linked contact that is no longer eligible, keeps the member" do
    enable_sources("newsletter")
    Contact.create!(email: "gone@example.com", sources: ["etl:meet"], ghost_id: "m5")
    existing = member(id: "m5", email: "gone@example.com", labels: ["VIP", "newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).with do |id, attrs|
      id == "m5" && attrs[:labels] == ["VIP"]
    end.returns(existing.merge("labels" => [{ "name" => "VIP" }]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:delabeled]
  end

  test "skips contacts with no enabled source and does nothing outbound when no sources enabled" do
    Contact.create!(email: "ineligible@example.com", sources: ["etl:meet"])
    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).never
    ghost.expects(:update_member).never
    sync_with(ghost).sync_all!
  end

  test "a per-contact failure is counted and does not halt the sweep" do
    enable_sources("newsletter")
    Contact.create!(email: "fail@example.com", sources: ["newsletter"])
    ok_contact = Contact.create!(email: "ok@example.com", sources: ["newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    created = member(id: "m6", email: "ok@example.com", labels: ["newsletter"])
    ghost.stubs(:create_member).with do |attrs|
      raise Stacks::Ghost::RequestError.new(500, "boom") if attrs[:email] == "fail@example.com"
      true
    end.returns(created)

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:errors]
    assert_equal "m6", ok_contact.reload.ghost_id
    assert_match(/fail@example.com/, sync.errors.first)
  end

  test "upsert creates a contact from a Ghost member with per-newsletter sources and events" do
    ghost = mock("ghost")
    sync = sync_with(ghost)
    m = member(id: "m10", email: "Signup@Example.com", name: "Signer Upper",
      newsletters: %w[weekly-digest], extra: {
        "email_suppression" => { "suppressed" => false }, "email_disabled" => false,
      })

    contact = sync.upsert_contact_from_member(m)
    contact.reload
    assert_equal "signup@example.com", contact.email
    assert_equal ["g3d:ghost:weekly-digest"], contact.sources
    assert_equal "m10", contact.ghost_id
    assert_equal "Signer Upper", contact.display_name
    assert_equal ["weekly-digest"], contact.ghost_data.dig("snapshot", "newsletters")
    assert_equal 1, contact.source_events["g3d:ghost:weekly-digest"].length
  end

  test "upsert is idempotent — repeat calls add no sources and no events" do
    ghost = mock("ghost")
    sync = sync_with(ghost)
    m = member(id: "m11", email: "twice@example.com", newsletters: %w[weekly-digest])
    sync.upsert_contact_from_member(m)
    contact = sync.upsert_contact_from_member(m).reload
    assert_equal ["g3d:ghost:weekly-digest"], contact.sources
    assert_equal 1, contact.source_events["g3d:ghost:weekly-digest"].length
  end

  test "member with no active newsletters gets the bare g3d:ghost source" do
    sync = sync_with(mock("ghost"))
    contact = sync.upsert_contact_from_member(member(id: "m12", email: "unsub@example.com")).reload
    assert_equal ["g3d:ghost"], contact.sources
  end

  test "upsert matches an existing contact by email, links ghost_id, keeps display_name" do
    existing = Contact.create!(email: "known@example.com", sources: ["newsletter"], display_name: "Original")
    sync = sync_with(mock("ghost"))
    m = member(id: "m13", email: "KNOWN@example.com", name: "Ghost Name", newsletters: %w[weekly-digest])
    sync.upsert_contact_from_member(m)
    existing.reload
    assert_equal "m13", existing.ghost_id
    assert_equal "Original", existing.display_name
    assert_equal %w[newsletter g3d:ghost:weekly-digest], existing.sources
  end

  test "email changed in Ghost records mismatch without mutating contact.email" do
    existing = Contact.create!(email: "old@example.com", ghost_id: "m14")
    sync = sync_with(mock("ghost"))
    sync.upsert_contact_from_member(member(id: "m14", email: "renamed@example.com"))
    existing.reload
    assert_equal "old@example.com", existing.email
    assert_equal "renamed@example.com", existing.ghost_data.dig("snapshot", "email_in_ghost")
  end

  test "suppression is snapshotted" do
    sync = sync_with(mock("ghost"))
    m = member(id: "m15", email: "bounced@example.com", extra: {
      "email_suppression" => { "suppressed" => true }, "email_disabled" => true,
    })
    contact = sync.upsert_contact_from_member(m).reload
    assert_equal true, contact.ghost_data.dig("snapshot", "suppressed")
    assert_equal true, contact.ghost_data.dig("snapshot", "email_disabled")
  end

  test "the pull leg records observed ledger entries for current subscriptions" do
    ghost = mock("ghost")
    sync = sync_with(ghost)
    m = member(id: "m90", email: "obs@example.com", newsletters: %w[weekly])
    contact = sync.upsert_contact_from_member(m).reload

    assert_equal "observed", contact.ledger_state("nl-weekly")
    assert_equal "m90", contact.ledger_member_id
    assert_equal ["weekly"], contact.ghost_data.dig("snapshot", "newsletters"),
      "snapshot semantics must be untouched"
  end

  test "observation never overwrites an existing ledger entry" do
    ghost = mock("ghost")
    sync = sync_with(ghost)
    contact = Contact.create!(email: "obs2@example.com", ghost_id: "m91", ghost_data: {
      "newsletter_ledger" => { "member_id" => "m91", "entries" => {
        "nl-weekly" => { "state" => "history", "at" => "2026-01-01T00:00:00Z" } } } })

    sync.upsert_contact_from_member(member(id: "m91", email: "obs2@example.com", newsletters: %w[weekly]))
    assert_equal "history", contact.reload.ledger_state("nl-weekly")
  end

  test "sync_all! pull leg upserts Ghost-only members" do
    ghost = mock("ghost")
    ghost.expects(:all_members).returns([
      member(id: "m17", email: "organic@example.com", newsletters: %w[weekly-digest]),
    ])
    sync = sync_with(ghost)
    sync.sync_all!
    contact = Contact.find_by(email: "organic@example.com")
    assert_equal "m17", contact.ghost_id
    assert_equal ["g3d:ghost:weekly-digest"], contact.sources
    assert_equal 1, sync.summary[:pulled]
  end

  test "sync_all_with_lock! returns nil when the advisory lock is held elsewhere" do
    other = ActiveRecord::Base.connection_pool.checkout
    other.execute("SELECT pg_advisory_lock(#{Stacks::GhostSync::ADVISORY_LOCK_KEY})")
    ghost = mock("ghost")
    assert_nil Stacks::GhostSync.sync_all_with_lock!(ghost)
  ensure
    other.execute("SELECT pg_advisory_unlock(#{Stacks::GhostSync::ADVISORY_LOCK_KEY})")
    ActiveRecord::Base.connection_pool.checkin(other)
  end

  test "skips contacts with invalid email and increments skipped_invalid" do
    enable_sources("newsletter")
    # Create a valid contact with an enabled source, then bypass validation to set invalid email
    contact = Contact.create!(email: "invalid@example.com", sources: ["newsletter"])
    contact.update_column(:email, "not-an-email")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).never
    ghost.expects(:update_member).never

    sync = sync_with(ghost)
    sync.sync_all!

    assert_equal 1, sync.summary[:skipped_invalid]
  end

  test "repeat upsert with identical member issues no write" do
    sync = sync_with(mock("ghost"))
    m = member(id: "m30", email: "steady@example.com", newsletters: %w[weekly-digest])
    contact = sync.upsert_contact_from_member(m).reload

    # Count UPDATE queries on the second call
    update_count = 0

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |name, started, finished, unique_id, payload|
      if payload[:sql].match?(/UPDATE\s+contacts/i)
        update_count += 1
      end
    end

    sync.upsert_contact_from_member(m)

    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_equal 0, update_count, "repeat upsert with identical member should issue no UPDATE"
  end

  # Finding A: synced_at stamped only on real outbound writes
  test "already-linked contact with matching labels is not written during sweep" do
    enable_sources("newsletter")
    contact = Contact.create!(
      email: "stable@example.com",
      sources: ["newsletter", "g3d:ghost"],
      ghost_id: "m40",
      display_name: "Stable",
      ghost_data: {
        "synced_at" => "2024-01-01T00:00:00Z",
        "snapshot" => {
          "newsletters" => [],
          "suppressed" => false,
          "email_disabled" => false,
        }
      }
    )
    existing = member(id: "m40", email: "stable@example.com", labels: ["newsletter"], name: "Stable",
      extra: { "email_suppression" => { "suppressed" => false }, "email_disabled" => false })

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).never
    ghost.expects(:create_member).never

    assert_no_changes -> { contact.reload.updated_at } do
      sync_with(ghost).sync_all!
    end
  end

  # Finding B: sweep reconciles Ghost-side member deletion
  test "linked non-eligible contact missing from all_members gets ghost_id cleared and deleted_at stamped" do
    contact = Contact.create!(email: "gone@example.com", sources: ["etl:meet"], ghost_id: "m50")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])

    sync = sync_with(ghost)
    sync.sync_all!
    contact.reload
    assert_nil contact.ghost_id
    assert contact.ghost_data.dig("snapshot", "deleted_at").present?
    assert_equal 1, sync.summary[:member_deleted]
  end

  test "linked ELIGIBLE contact missing from all_members gets reconciled, not re-created in same sweep" do
    enable_sources("newsletter")
    contact = Contact.create!(email: "vanished@example.com", sources: ["newsletter"], ghost_id: "m51")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).never

    sync = sync_with(ghost)
    sync.sync_all!
    contact.reload
    assert_nil contact.ghost_id
    assert contact.ghost_data.dig("snapshot", "deleted_at").present?
  end

  # Finding C: deletion sticks — no re-create of deleted members
  test "contact with deleted_at and no member match is suppressed, not re-created" do
    enable_sources("newsletter")
    contact = Contact.create!(
      email: "deleted@example.com",
      sources: ["newsletter"],
      ghost_data: { "snapshot" => { "deleted_at" => "2024-01-01T00:00:00Z" } }
    )

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).never

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:suppressed_deleted]
  end

  test "contact with deleted_at that re-signed up in Ghost is adopted and deleted_at cleared" do
    enable_sources("newsletter")
    contact = Contact.create!(
      email: "resigup@example.com",
      sources: ["newsletter"],
      ghost_data: { "snapshot" => { "deleted_at" => "2024-01-01T00:00:00Z" } }
    )
    existing = member(id: "m52", email: "resigup@example.com", labels: ["newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).never

    sync = sync_with(ghost)
    sync.sync_all!
    contact.reload
    assert_equal "m52", contact.ghost_id
    assert_nil contact.ghost_data.dig("snapshot", "deleted_at")
  end

  # Fix #3: link_contact! steal skips case-fold duplicates to avoid ping-pong
  test "link_contact! skips steal when owner email case-folds equal to contact email and counts link_conflict" do
    enable_sources("newsletter")
    # Two contacts differing only by email case (case-fold duplicates)
    owner = Contact.create!(
      email: "casefold@example.com",
      sources: ["newsletter"],
      ghost_id: "m-cf1"
    )
    other = Contact.create!(
      email: "CASEFOLD@example.com",
      sources: ["newsletter"]
    )
    ghost_member = member(id: "m-cf1", email: "casefold@example.com", labels: ["newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([ghost_member])
    # The sync will try to sync the other contact (uppercase email, same source)
    # It finds the member by email; link_contact! should detect owner email case-folds
    # equal to other.email and skip the steal
    ghost.stubs(:update_member).returns(ghost_member)

    sync = sync_with(ghost)
    sync.sync_all!

    # owner must keep ghost_id (steal was skipped)
    assert_equal "m-cf1", owner.reload.ghost_id
    # other must NOT have stolen ghost_id
    assert_nil other.reload.ghost_id
    assert_equal 1, sync.summary[:link_conflicts]
  end

  # Fix #4: label comparison is case/slug-insensitive — existing "newsletter" matches desired "Newsletter"
  test "no-op when Ghost label name differs only by case from the enabled source name" do
    enable_sources("Newsletter")
    Contact.create!(email: "caselab@example.com", sources: ["Newsletter"], ghost_id: "m-caselab")
    # Ghost stored the label as lowercase "newsletter" (Ghost dedupes by slug)
    existing = member(id: "m-caselab", email: "caselab@example.com", labels: ["newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).never
    ghost.expects(:create_member).never

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 0, sync.summary[:updated]
  end

  # Fix #4b: non-managed label case is not destroyed when diffing
  test "non-managed label with unusual casing is preserved and update_member is not called spuriously" do
    enable_sources("Newsletter")
    Contact.create!(
      email: "nonmanaged@example.com",
      sources: ["Newsletter"],
      ghost_id: "m-nonmgd"
    )
    # Ghost has "newsletter" (managed, case mismatch) and "VIP" (non-managed)
    existing = member(id: "m-nonmgd", email: "nonmanaged@example.com", labels: ["newsletter", "VIP"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).never

    sync_with(ghost).sync_all!
  end

  test "label_attrs_for computes the label diff without issuing a request" do
    enable_sources("newsletter", "fundraising")
    contact = Contact.create!(email: "attrs@example.com", sources: %w[newsletter fundraising])
    existing = member(id: "m70", email: "attrs@example.com", labels: ["VIP", "newsletter"])

    ghost = mock("ghost")
    ghost.expects(:update_member).never
    sync = sync_with(ghost)
    attrs = sync.send(:label_attrs_for, contact, existing, %w[fundraising newsletter], %w[newsletter fundraising])

    assert_equal ["VIP", "fundraising", "newsletter"], attrs[:labels].sort
    refute attrs.key?(:newsletters)
  end

  test "label_attrs_for returns nil when nothing needs changing" do
    enable_sources("newsletter")
    contact = Contact.create!(email: "attrs2@example.com", sources: %w[newsletter], display_name: nil)
    existing = member(id: "m71", email: "attrs2@example.com", labels: ["newsletter"], name: "Has Name")
    sync = sync_with(mock("ghost"))
    assert_nil sync.send(:label_attrs_for, contact, existing, %w[newsletter], %w[newsletter])
  end

  # Finding F: NQL email filter escapes single quotes
  test "find_member_by_email escapes single quotes in the NQL filter" do
    Stacks::Utils.stubs(:config).returns({
      ghost: {
        api_url: "https://example.ghost.io",
        admin_api_key: "65abc123def:0123456789abcdef0123456789abcdef",
      }
    })
    client = Stacks::Ghost.new(max_retries: 0)
    captured_filter = nil
    Stacks::Ghost.stubs(:get).with { |_url, opts|
      captured_filter = opts[:query][:filter]
      true
    }.returns(
      begin
        resp = mock("response")
        resp.stubs(:success?).returns(true)
        resp.stubs(:code).returns(200)
        resp.stubs(:parsed_response).returns({ "members" => [] })
        resp
      end
    )
    client.find_member_by_email("o'brien@x.com")
    assert captured_filter.include?("o\\'brien"), "Expected escaped quote in filter, got: #{captured_filter}"
  end

  test "source_prefix takes the first colon segment, downcased" do
    { "index:luma:chinatown" => "index", "xxix:" => "xxix", "team" => "team",
      "G3D:foo" => "g3d", "sanctu:luma:family.intelligence" => "sanctu" }.each do |source, expected|
      assert_equal expected, Stacks::GhostSync.source_prefix(source), source
    end
  end

  test "the g3d:ghost namespace never produces a target even when g3d is mapped" do
    enable_sources("g3d:ghost", "g3d:ghost:index", "g3d:substack:g3d_substack")
    sys!(ghost_newsletter_prefix_map: { "g3d" => "nl-g3d" })
    contact = Contact.create!(email: "loop@example.com",
      sources: ["g3d:ghost", "g3d:ghost:index", "g3d:substack:g3d_substack"])
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-g3d"))
    sync = sync_with(ghost)
    sync.send(:load_newsletter_config!)
    # Both directions. Without the third source an over-broad exclusion such as
    # start_with?("g3d") would pass this test while silently dropping every
    # g3d:substack:* contact (3,197 of them) out of the g3d newsletter.
    assert_equal ["nl-g3d"], sync.target_newsletter_ids(contact, enabled_sources),
      "g3d:ghost* is excluded; other g3d:* sources still map to the g3d newsletter"
  end

  test "excluded_source? draws the boundary at the colon, not the prefix string" do
    { "g3d:ghost" => true, "g3d:ghost:index" => true, "G3D:Ghost" => true,
      "g3d:ghostwriter" => false, "g3d:substack:g3d_substack" => false,
      "g3d" => false }.each do |source, expected|
      assert_equal expected, Stacks::GhostSync.excluded_source?(source), source
    end
  end

  test "targets come only from enabled, mapped, non-blank prefixes" do
    enable_sources("index:shopify_customer", "index:luma:chinatown", "xxix:mailchimp:xxix_mailchimp")
    sys!(ghost_newsletter_prefix_map: {
      "index" => "nl-index", "xxix" => "", "usb_club" => "nl-usb" })
    contact = Contact.create!(email: "t@example.com", sources: [
      "index:shopify_customer",              # enabled + mapped
      "index:luma:chinatown",                # same prefix again: must not duplicate
      "xxix:mailchimp:xxix_mailchimp",       # enabled but mapped to blank
      "usb_club:shopify_customer",           # mapped but NOT enabled
      "etl:meet",                            # neither
    ])
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index", "nl-usb"))
    sync = sync_with(ghost)
    sync.send(:load_newsletter_config!)
    assert_equal ["nl-index"], sync.target_newsletter_ids(contact, enabled_sources)
  end

  test "sync_all! loads the newsletter config" do
    # Pins the call site itself: remove it and @prefix_map stays empty.
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "cfg@example.com", sources: ["index:shopify_customer"])
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    ghost.stubs(:create_member).returns(member(id: "mcfg", email: "cfg@example.com"))
    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal({ "index" => "nl-index" }, sync.instance_variable_get(:@prefix_map))
  end

  test "a /newsletters/ outage degrades to no grants but lets the rest of the sweep finish" do
    # Before this fix, load_newsletter_config! was the first unguarded statement in
    # sync_all!, so an all_newsletters exception aborted the deletion and label legs
    # too. It must now fail closed on grants alone (empty @prefix_map) while the
    # rest of the sweep -- here, creating the contact's Ghost member -- still runs.
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "outage@example.com", sources: ["index:shopify_customer"])
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).raises(StandardError, "boom")
    ghost.expects(:all_members).returns([])
    ghost.stubs(:create_member).returns(member(id: "mout", email: "outage@example.com"))
    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal({}, sync.instance_variable_get(:@prefix_map))
    assert_equal 1, sync.summary[:grant_config_unavailable]
    assert sync.errors.any? { |e| e.include?("newsletter config") }, sync.errors.inspect
    assert_equal 1, sync.summary[:created], "label/create leg must still complete despite the newsletters outage"
  end

  test "an empty prefix map issues no all_newsletters call" do
    enable_sources("newsletter")
    Contact.create!(email: "nomap@example.com", sources: ["newsletter"])
    ghost = mock("ghost")
    ghost.expects(:all_newsletters).never
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).returns(member(id: "m1", email: "nomap@example.com"))
    sync_with(ghost).sync_all!
  end

  test "the sweep reads settings fresh, not through the memoized System.instance" do
    enable_sources("index:shopify_customer")
    System.instance   # prime the class-variable memo
    # Change the row behind the memo, the way another puma worker or a rake dyno would.
    System.first.update_columns(settings: System.first.settings.merge(
      "ghost_newsletter_prefix_map" => { "index" => "nl-index" }))

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    sync = sync_with(ghost)
    sync.send(:load_newsletter_config!)
    assert_equal({ "index" => "nl-index" }, sync.instance_variable_get(:@prefix_map),
      "System.instance memoizes per process and is never invalidated")
  ensure
    System.class_variable_set(:@@instance, nil)
  end

  test "a mapping to an unknown or archived newsletter is dropped and counted" do
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: {
      "index" => "nl-index", "sanctu" => "nl-archived", "team" => "nl-missing" })
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns([
      { "id" => "nl-index", "name" => "Index Space", "slug" => "index", "status" => "active" },
      { "id" => "nl-archived", "name" => "Old", "slug" => "old", "status" => "archived" },
    ])
    sync = sync_with(ghost)
    sync.send(:load_newsletter_config!)
    assert_equal({ "index" => "nl-index" }, sync.instance_variable_get(:@prefix_map))
    assert_equal 2, sync.summary[:grant_mapping_invalid]
  end

  test "a newsletter with no status key is treated as inactive, not active" do
    # Strict == "active" is the safer failure: if Ghost ever omitted status, every
    # newsletter would be dropped, meaning no grants -- fail-closed and visible via
    # grant_mapping_invalid -- rather than silently granting against an unverified state.
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns([
      { "id" => "nl-index", "name" => "Index Space", "slug" => "index" },
    ])
    sync = sync_with(ghost)
    sync.send(:load_newsletter_config!)
    assert_equal({}, sync.instance_variable_get(:@prefix_map))
    assert_equal 1, sync.summary[:grant_mapping_invalid]
  end

  # ghost_id defaults to "m50" (matching every other grant test's member id),
  # but is overridable: the suppressed/email-disabled test calls this twice in
  # one test and needs distinct ghost_ids to avoid colliding on the unique index.
  def grant_setup(sources:, map:, newsletters: [], ghost_id: "m50")
    enable_sources(*sources)
    sys!(ghost_newsletter_prefix_map: map)
    Contact.create!(email: "g@example.com", sources: sources, ghost_id: ghost_id)
  end

  test "a never-subscribed member with a mapped source becomes a grant candidate" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).with("m50", current_newsletter_ids: []).returns([])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal ["nl-xxix"], sync.send(:grant_candidates_for, contact, m, enabled_sources)
  end

  test "a currently subscribed newsletter is observed, never a candidate" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com", extra: {
      "newsletters" => [{ "id" => "nl-xxix", "name" => "XXIX", "status" => "active" }] })
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).never
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal "observed", contact.ledger_state("nl-xxix")
  end

  test "an existing ledger entry blocks the grant without any events call" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    contact.record_ledger_entry!("nl-xxix", "history", member_id: "m50")
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).never
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal 1, sync.summary[:unsubscribe_respected]
  end

  test "history showing any event for N blocks the grant and caches a history entry" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m50", "newsletter_id" => "nl-xxix", "subscribed" => false,
        "created_at" => "2026-01-01T00:00:00.000Z" } }])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal "history", contact.ledger_state("nl-xxix")
    assert_equal 1, sync.summary[:unsubscribe_respected]
  end

  test "a prior SUBSCRIBE event disqualifies just as an unsubscribe does" do
    # "Never been subscribed" means never, in either direction. Narrowing this to
    # subscribed == false would re-grant anyone who subscribed and later unsubscribed,
    # which is the entire population this feature protects.
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m50", "newsletter_id" => "nl-xxix", "subscribed" => true,
        "created_at" => "2026-01-01T00:00:00.000Z" } }])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal "history", contact.ledger_state("nl-xxix")
  end

  test "a granted or observed ledger entry counts as already_handled, not unsubscribe_respected" do
    # These are different numbers in the rollout review: unsubscribe_respected is meant to
    # mean "we correctly did not re-subscribe someone", so entries this sync created must
    # not inflate it.
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    contact.record_ledger_entry!("nl-xxix", "granted", member_id: "m50")
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).never
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal 1, sync.summary[:already_handled]
    assert_equal 0, sync.summary[:unsubscribe_respected]
  end

  test "the history is read at most once per member across several targets" do
    # Pins both the memoization and the per-MEMBER (not per-target) scope of the read.
    enable_sources("xxix:", "index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix", "index" => "nl-index" })
    contact = Contact.create!(email: "multi@example.com",
      sources: ["xxix:", "index:shopify_customer"], ghost_id: "m57")
    # BOTH targets must reach the fetch line, so the member is subscribed to NEITHER.
    # With one target currently subscribed it short-circuits first, and then `events =`
    # and `events ||=` are indistinguishable: only one target ever fetches.
    m = member(id: "m57", email: "multi@example.com")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix", "nl-index"))
    ghost.expects(:newsletter_events_for).once.returns([])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal %w[nl-index nl-xxix],
      sync.send(:grant_candidates_for, contact, m, enabled_sources).sort
  end

  test "a target the member is already subscribed to costs no API call" do
    enable_sources("xxix:", "index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix", "index" => "nl-index" })
    contact = Contact.create!(email: "mixed@example.com",
      sources: ["xxix:", "index:shopify_customer"], ghost_id: "m58")
    m = member(id: "m58", email: "mixed@example.com", extra: {
      "newsletters" => [{ "id" => "nl-index", "name" => "Index", "status" => "active" }] })

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix", "nl-index"))
    ghost.expects(:newsletter_events_for).once.returns([])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal ["nl-xxix"], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal "observed", contact.ledger_state("nl-index")
  end

  test "a RequestError from the history read also fails closed" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).raises(Stacks::Ghost::RequestError.new(500, "boom"))
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal 1, sync.summary[:grant_errors]
  end

  test "history for a different newsletter does not block the grant" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m50", "newsletter_id" => "nl-other", "subscribed" => false,
        "created_at" => "2026-01-01T00:00:00.000Z" } }])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    candidates = sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal ["nl-xxix"], candidates
    assert_equal({}, contact.newsletter_ledger_entries,
      "a candidate is not a grant: the decision writes no ledger entry for it")
  end

  test "an untrustworthy history fails closed for the whole member" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).raises(Stacks::Ghost::UntrustworthyHistory, "200 with empty list")
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
    assert_equal 1, sync.summary[:grant_errors]
    assert_equal({}, contact.newsletter_ledger_entries, "a failed history read writes no ledger entry")
  end

  test "a suppressed or email-disabled member is skipped before any events call" do
    [{ "email_suppression" => { "suppressed" => true } }, { "email_disabled" => true }].each_with_index do |extra, i|
      contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" }, ghost_id: "m5#{i}")
      contact.update!(email: "g#{i}@example.com")
      m = member(id: "m5#{i}", email: contact.email, extra: extra)
      ghost = mock("ghost")
      ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
      ghost.expects(:newsletter_events_for).never
      sync = sync_with(ghost); sync.send(:load_newsletter_config!)

      assert_equal [], sync.send(:grant_candidates_for, contact, m, enabled_sources)
      assert_equal 1, sync.summary[:grant_skipped_undeliverable]
      assert_nil contact.ledger_state("nl-xxix")
    end
  end

  test "a ledger describing a different member is ignored, falling through to history" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    contact.record_ledger_entry!("nl-xxix", "granted", member_id: "SOMEONE-ELSE")
    m = member(id: "m50", email: "g@example.com")
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:newsletter_events_for).returns([])
    sync = sync_with(ghost); sync.send(:load_newsletter_config!)

    assert_equal ["nl-xxix"], sync.send(:grant_candidates_for, contact, m, enabled_sources)
  end

  test "a grant re-reads the member and its history immediately before the PUT" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    sys!(ghost_newsletter_grants_enabled: "1")
    # labels match the enabled source, so the label path is a genuine no-op and any
    # update_member call we see is the grant.
    snapshot = member(id: "m50", email: "g@example.com", labels: ["xxix:"])
    fresh = member(id: "m50", email: "g@example.com", labels: ["xxix:"], extra: {
      "newsletters" => [{ "id" => "nl-index", "name" => "Index", "status" => "active" }] })

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix", "nl-index"))
    ghost.expects(:all_members).returns([snapshot])
    ghost.expects(:newsletter_events_for).twice.returns([])
    ghost.expects(:find_member).with("m50").returns(fresh)
    ghost.expects(:update_member).with { |id, attrs|
      id == "m50" &&
        attrs[:newsletters].map { |n| n[:id] }.sort == %w[nl-index nl-xxix] &&
        !attrs.key?(:subscribed)
    }.returns(fresh.merge("newsletters" => [
      { "id" => "nl-index" }, { "id" => "nl-xxix" }]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal "granted", contact.reload.ledger_state("nl-xxix")
    assert_equal 1, sync.summary[:granted]
  end

  test "an unsubscribe landing between the decision and the PUT blocks the write" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    sys!(ghost_newsletter_grants_enabled: "1")
    m = member(id: "m50", email: "g@example.com", labels: ["xxix:"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([m])
    ghost.expects(:find_member).with("m50").returns(m)
    # Decision-phase read sees nothing; the pre-PUT read sees the unsubscribe.
    ghost.expects(:newsletter_events_for).twice.returns([]).then.returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m50", "newsletter_id" => "nl-xxix", "subscribed" => false,
        "created_at" => "2026-09-16T04:00:00.000Z" } }])
    ghost.expects(:update_member).never

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal "history", contact.reload.ledger_state("nl-xxix")
    # count: false on the pre-write recheck. Flipping it to true double-counts every
    # number the rollout review reads.
    assert_equal 1, sync.summary[:unsubscribe_respected]
  end

  test "a grant and a label change ride in a single PUT" do
    # This is the whole reason label_attrs_for was extracted. Without the fold, labels
    # are silently dropped from every combined write and the suite stays green.
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" }, ghost_newsletter_grants_enabled: "1")
    Contact.create!(email: "combo@example.com", sources: ["xxix:"], ghost_id: "m87")
    stale = member(id: "m87", email: "combo@example.com", labels: [])
    fresh = member(id: "m87", email: "combo@example.com", labels: [])

    seen = []
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([stale])
    ghost.stubs(:newsletter_events_for).returns([])
    ghost.expects(:find_member).with("m87").returns(fresh)
    ghost.expects(:update_member).once.with { |_id, attrs| seen << attrs; true }
      .returns(member(id: "m87", email: "combo@example.com", labels: ["xxix:"])
        .merge("newsletters" => [{ "id" => "nl-xxix" }]))

    sync_with(ghost).sync_all!
    assert_equal 1, seen.length, "one PUT, not one for labels and one for newsletters"
    assert_equal ["xxix:"], seen.first[:labels]
    assert_equal [{ id: "nl-xxix" }], seen.first[:newsletters]
  end

  test "an unlinked case-fold duplicate drives no Ghost write at all" do
    # Not even a label write. The owner contact converges the member; a duplicate that
    # does not own it must not touch it, or the two ping-pong one PUT each per sweep
    # forever with the last writer winning.
    enable_sources("index:shopify_customer", "team")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" },
         ghost_newsletter_grants_enabled: "1")
    Contact.create!(email: "own@example.com", sources: ["index:shopify_customer"], ghost_id: "m88")
    # The duplicate wants an EXTRA label ("team") the owner does not have, so its label
    # diff is still non-empty even after the owner's own write has converged the member.
    # If the duplicate shared the owner's exact sources, its diff would already be a
    # no-op by the time it is reached and the test could not see the guard at all.
    Contact.create!(email: "OWN@example.com", sources: ["index:shopify_customer", "team"])
    # labels: [] so a label diff WOULD fire for the duplicate if the guard let it through.
    linked = member(id: "m88", email: "own@example.com", labels: [])

    seen = []
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([linked])
    ghost.stubs(:newsletter_events_for).returns([])
    ghost.stubs(:find_member).returns(linked)
    ghost.stubs(:update_member).with { |_id, attrs| seen << attrs; true }
      .returns(linked.merge("labels" => [{ "name" => "index:shopify_customer" }],
                            "newsletters" => [{ "id" => "nl-index" }]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, seen.length, "only the owner writes; the duplicate writes nothing"
    refute seen.any? { |a| Array(a[:labels]).include?("team") },
      "the duplicate's own labels must never reach a member it does not own"
    assert_equal 1, sync.summary[:writes_skipped_unlinked]
  end

  test "the pre-write recheck does not re-count what the decision phase already counted" do
    # Two targets: one the member is already subscribed to (recorded observed during the
    # decision phase), one a real candidate. The decision-phase snapshot has nl-index
    # subscribed, so it is caught by the current-subscription fast path (recorded
    # "observed", uncounted either way). The fresh member returned by find_member for
    # the recheck does NOT show nl-index as current -- so the recheck instead reaches
    # the ledger fast path (`ledger_has?`), which finds that same "observed" entry.
    # That is exactly where count applies: with count: true it increments
    # already_handled a second time, inflating the numbers the rollout review reads.
    enable_sources("xxix:", "index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix", "index" => "nl-index" },
         ghost_newsletter_grants_enabled: "1")
    Contact.create!(email: "recount@example.com",
      sources: ["xxix:", "index:shopify_customer"], ghost_id: "m89")
    snapshot = member(id: "m89", email: "recount@example.com",
      labels: %w[xxix: index:shopify_customer],
      extra: { "newsletters" => [{ "id" => "nl-index", "name" => "Index", "status" => "active" }] })
    fresh = member(id: "m89", email: "recount@example.com", labels: %w[xxix: index:shopify_customer])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix", "nl-index"))
    ghost.expects(:all_members).returns([snapshot])
    ghost.stubs(:newsletter_events_for).returns([])
    ghost.expects(:find_member).with("m89").returns(fresh)
    ghost.expects(:update_member).returns(fresh.merge("newsletters" => [{ "id" => "nl-xxix" }]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:granted]
    assert_equal 0, sync.summary[:already_handled],
      "the recheck passes count: false, so the ledger fast path must not re-count"
  end

  test "with the grants flag off the decision runs but nothing is written to Ghost" do
    contact = grant_setup(sources: ["xxix:"], map: { "xxix" => "nl-xxix" })
    sys!(ghost_newsletter_grants_enabled: "0")
    m = member(id: "m50", email: "g@example.com", labels: ["xxix:"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([m])
    ghost.expects(:newsletter_events_for).returns([])
    ghost.expects(:find_member).never
    ghost.expects(:update_member).never

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_planned]
    assert_equal 0, sync.summary[:granted]
    assert_nil contact.reload.ledger_state("nl-xxix"), "a planned grant writes no granted entry"
  end

  test "a new member is created with its mapped newsletters even when grants are off" do
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" },
         ghost_newsletter_grants_enabled: "0")
    contact = Contact.create!(email: "fresh@example.com", sources: ["index:shopify_customer"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).with { |attrs| attrs[:newsletters] == [{ id: "nl-index" }] }
      .returns(member(id: "m60", email: "fresh@example.com").merge(
        "newsletters" => [{ "id" => "nl-index" }]))

    sync_with(ghost).sync_all!
    assert_equal "granted", contact.reload.ledger_state("nl-index")
  end

  test "a contact with no mapped prefix is created with an explicit empty newsletters array" do
    enable_sources("usb_club:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "unmapped@example.com", sources: ["usb_club:shopify_customer"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).with { |attrs| attrs.key?(:newsletters) && attrs[:newsletters] == [] }
      .returns(member(id: "m61", email: "unmapped@example.com"))

    sync_with(ghost).sync_all!
  end

  test "granted is written only for newsletters the create response confirms" do
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    contact = Contact.create!(email: "dropped@example.com", sources: ["index:shopify_customer"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    # Ghost silently drops the newsletter. A granted entry is write-once and would
    # block the legitimate grant forever, with no repair path.
    ghost.expects(:create_member).returns(member(id: "m62", email: "dropped@example.com"))

    sync_with(ghost).sync_all!
    assert_nil contact.reload.ledger_state("nl-index")
  end

  test "a history ledger entry survives a sweep that also writes a label update" do
    # link_contact! rebuilds the whole ghost_data column from the in-memory hash. If a
    # ledger entry were written out of band (update_column / raw jsonb), this would
    # clobber it, turning a durable "no" back into a fresh layer-3 roll every sweep.
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" }, ghost_newsletter_grants_enabled: "1")
    contact = Contact.create!(email: "clob@example.com", sources: ["xxix:"], ghost_id: "m85")
    m = member(id: "m85", email: "clob@example.com", labels: [])   # label diff WILL fire

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([m])
    ghost.stubs(:newsletter_events_for).returns([
      { "type" => "newsletter_event", "data" => {
        "member_id" => "m85", "newsletter_id" => "nl-xxix", "subscribed" => false,
        "created_at" => "2026-01-01T00:00:00.000Z" } }])
    ghost.stubs(:update_member).returns(member(id: "m85", email: "clob@example.com", labels: ["xxix:"]))

    sync_with(ghost).sync_all!
    assert_equal "history", contact.reload.ledger_state("nl-xxix"),
      "the ledger entry must survive link_contact! rebuilding ghost_data"
  end

  test "the 422 adopt path runs layer 3 and respects the grants flag" do
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" }, ghost_newsletter_grants_enabled: "0")
    contact = Contact.create!(email: "adopt@example.com", sources: ["xxix:"])
    existing = member(id: "m86", email: "adopt@example.com", labels: ["xxix:"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).raises(Stacks::Ghost::RequestError.new(422, "already exists"))
    ghost.expects(:find_member_by_email).with("adopt@example.com").returns(existing)
    # An adopted member is NOT new: it must run the history check, not skip it.
    ghost.expects(:newsletter_events_for).returns([])
    ghost.expects(:update_member).never   # grants flag is off

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_planned]
    assert_equal "m86", contact.reload.ghost_id
  end

  test "two case-fold duplicate contacts produce exactly one create" do
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" })
    Contact.create!(email: "dup@example.com", sources: ["index:shopify_customer"])
    Contact.create!(email: "DUP@example.com", sources: ["index:shopify_customer"])

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).once.returns(
      member(id: "m63", email: "dup@example.com").merge("newsletters" => [{ "id" => "nl-index" }]))
    ghost.stubs(:newsletter_events_for).returns([])

    sync_with(ghost).sync_all!
  end

  test "a contact left unlinked by a case-fold link conflict never drives a newsletters write" do
    enable_sources("index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "index" => "nl-index" },
         ghost_newsletter_grants_enabled: "1")
    Contact.create!(email: "owner@example.com", sources: ["index:shopify_customer"], ghost_id: "m64")
    Contact.create!(email: "OWNER@example.com", sources: ["index:shopify_customer"])

    linked = member(id: "m64", email: "owner@example.com", labels: ["index:shopify_customer"])
    seen = []
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-index"))
    ghost.expects(:all_members).returns([linked])
    ghost.stubs(:newsletter_events_for).returns([])
    ghost.stubs(:find_member).returns(linked)
    ghost.stubs(:update_member).with { |_id, attrs| seen << attrs; true }
      .returns(linked.merge("newsletters" => [{ "id" => "nl-index" }]))

    sync = sync_with(ghost)
    sync.sync_all!

    assert_equal 1, seen.count { |a| a.key?(:newsletters) },
      "exactly one contact may write newsletters for member m64"
    assert_equal 1, sync.summary[:writes_skipped_unlinked]
  end

  test "the budget caps creates and defers the rest without linking them" do
    enable_sources("index:x")
    sys!(ghost_newsletter_prefix_map: {}, ghost_sweep_write_budget: 1)
    3.times { |i| Contact.create!(email: "b#{i}@example.com", sources: ["index:x"]) }

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).once.returns(member(id: "mb1", email: "b0@example.com"))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:created]
    assert_equal 2, sync.summary[:creates_deferred]
    assert_equal 2, Contact.where(ghost_id: nil).where("email LIKE 'b%'").count
  end

  test "a deferred contact is created by the next sweep" do
    enable_sources("index:x")
    sys!(ghost_newsletter_prefix_map: {}, ghost_sweep_write_budget: 1)
    2.times { |i| Contact.create!(email: "c#{i}@example.com", sources: ["index:x"]) }

    ghost = mock("ghost")
    # The second sweep must see the member created by the first. Otherwise the
    # deletion-reconciliation leg (ghost_sync.rb:47-51) clears c0's ghost_id and stamps
    # deleted_at, and the test would pass by recycling c0 rather than resuming c1.
    # Labels must match what create_member was sent (desired: ["index:x"]) - an
    # unlabeled double here would make c0's re-sweep look like a pending label fix,
    # spending the only budget unit on a no-op update instead of leaving it for c1.
    ghost.stubs(:all_members).returns([]).then.returns(
      [member(id: "mc1", email: "c0@example.com", labels: ["index:x"])])
    ghost.stubs(:create_member).returns(
      member(id: "mc1", email: "c0@example.com")).then.returns(
      member(id: "mc2", email: "c1@example.com"))

    Stacks::GhostSync.new(ghost).sync_all!
    # The budget lives on the instance, so the second sweep needs a second object.
    second = Stacks::GhostSync.new(ghost)
    second.sync_all!
    assert_equal 1, second.summary[:created]
    assert_equal "mc2", Contact.find_by(email: "c1@example.com").ghost_id,
      "the deferred contact is the one that resumed"
  end

  test "an exhausted budget skips the history read entirely" do
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" }, ghost_sweep_write_budget: 1)
    # Two linked contacts, budget 1. The second must be deferred BEFORE its history read.
    Contact.create!(email: "g1@example.com", sources: ["xxix:"], ghost_id: "m51")
    Contact.create!(email: "g2@example.com", sources: ["xxix:"], ghost_id: "m52")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([
      member(id: "m51", email: "g1@example.com", labels: ["xxix:"]),
      member(id: "m52", email: "g2@example.com", labels: ["xxix:"])])
    # Exactly one history read: the deferred contact must cost no API calls at all.
    ghost.expects(:newsletter_events_for).once.returns([])

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_deferred]
  end

  test "linked contacts get their reserved allowance even when creates would exhaust it" do
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" },
         ghost_newsletter_grants_enabled: "0",
         ghost_sweep_write_budget: 2)
    # Create the unlinked contacts FIRST so they sort ahead of the linked one by id.
    # Without the scope split, find_each's id order would exhaust the budget on these
    # five creates and never reach `linked`, so this ordering is what makes the test
    # actually exercise the reservation.
    5.times { |i| Contact.create!(email: "z#{i}@example.com", sources: ["xxix:"]) }
    Contact.create!(email: "linked@example.com", sources: ["xxix:"], ghost_id: "m80")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([
      member(id: "m80", email: "linked@example.com", labels: ["xxix:"])])
    ghost.expects(:newsletter_events_for).with("m80", anything).returns([])
    ghost.stubs(:create_member).returns(member(id: "mz", email: "z0@example.com"))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_planned],
      "the linked contact's decision must run on the first sweep, not after the ramp"
    assert_operator sync.summary[:creates_deferred], :>=, 4
  end

  test "two candidate newsletters are one PUT and one budget unit" do
    # The defining semantic of the budget: the unit is a MUTATION, not a newsletter.
    # With a per-newsletter decrement this contact would consume 2 units and, at a budget
    # of 1, be deferred entirely rather than granted.
    enable_sources("xxix:", "index:shopify_customer")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix", "index" => "nl-index" },
         ghost_newsletter_grants_enabled: "1", ghost_sweep_write_budget: 1)
    contact = Contact.create!(email: "twocand@example.com",
      sources: ["xxix:", "index:shopify_customer"], ghost_id: "m90")
    m = member(id: "m90", email: "twocand@example.com",
      labels: %w[xxix: index:shopify_customer])

    seen = []
    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix", "nl-index"))
    ghost.expects(:all_members).returns([m])
    ghost.stubs(:newsletter_events_for).returns([])
    ghost.expects(:find_member).with("m90").returns(m)
    ghost.expects(:update_member).once.with { |_id, attrs| seen << attrs; true }
      .returns(m.merge("newsletters" => [{ "id" => "nl-index" }, { "id" => "nl-xxix" }]))

    sync = sync_with(ghost)
    sync.sync_all!

    assert_equal 1, seen.length
    assert_equal %w[nl-index nl-xxix], seen.first[:newsletters].map { |n| n[:id] }.sort
    assert_equal 1, sync.summary[:writes_used]
    assert_equal 2, sync.summary[:granted]
    assert_equal 0, sync.summary[:grants_deferred]
    assert_equal "granted", contact.reload.ledger_state("nl-xxix")
  end

  test "a dry-run grant costs one unit, not two, when labels also differ" do
    # The rollout runs with the flag OFF, and the 52 pre-existing members are exactly the
    # population likely to have both an unwritten label and a first-time candidate. If a
    # planned grant charged a unit AND its label write charged another, the dry run would
    # burn budget at twice the real run's rate and under-report grants_planned.
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" },
         ghost_newsletter_grants_enabled: "0", ghost_sweep_write_budget: 1)
    Contact.create!(email: "dry@example.com", sources: ["xxix:"], ghost_id: "m91")
    m = member(id: "m91", email: "dry@example.com", labels: [])   # label diff WILL fire

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([m])
    ghost.stubs(:newsletter_events_for).returns([])
    ghost.expects(:update_member).once.returns(
      member(id: "m91", email: "dry@example.com", labels: ["xxix:"]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_planned]
    assert_equal 1, sync.summary[:writes_used], "one contact, one unit"
    assert_equal 0, sync.summary[:updates_deferred]
  end

  test "the delabel leg shares the same budget" do
    enable_sources("newsletter")
    sys!(ghost_sweep_write_budget: 1)
    # Linked, labelled, but no longer carrying an enabled source: the delabel leg.
    Contact.create!(email: "dl1@example.com", sources: ["other"], ghost_id: "m92")
    Contact.create!(email: "dl2@example.com", sources: ["other"], ghost_id: "m93")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([
      member(id: "m92", email: "dl1@example.com", labels: ["newsletter"]),
      member(id: "m93", email: "dl2@example.com", labels: ["newsletter"])])
    ghost.expects(:update_member).once.returns(
      member(id: "m92", email: "dl1@example.com", labels: []))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:delabeled]
    assert_equal 1, sync.summary[:updates_deferred]
  end

  test "the budget binds identically when the grants flag is off" do
    enable_sources("xxix:")
    sys!(ghost_newsletter_prefix_map: { "xxix" => "nl-xxix" },
         ghost_newsletter_grants_enabled: "0", ghost_sweep_write_budget: 1)
    Contact.create!(email: "d1@example.com", sources: ["xxix:"], ghost_id: "m53")
    Contact.create!(email: "d2@example.com", sources: ["xxix:"], ghost_id: "m54")

    ghost = mock("ghost")
    ghost.stubs(:all_newsletters).returns(active_nl("nl-xxix"))
    ghost.expects(:all_members).returns([
      member(id: "m53", email: "d1@example.com", labels: ["xxix:"]),
      member(id: "m54", email: "d2@example.com", labels: ["xxix:"])])
    ghost.expects(:newsletter_events_for).once.returns([])

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:grants_deferred],
      "a planned grant consumes budget exactly as a real one does"
  end

  test "an exhausted budget defers label-only updates" do
    enable_sources("newsletter", "fundraising")
    sys!(ghost_sweep_write_budget: 1)
    Contact.create!(email: "l1@example.com", sources: %w[newsletter fundraising], ghost_id: "m55")
    Contact.create!(email: "l2@example.com", sources: %w[newsletter fundraising], ghost_id: "m56")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([
      member(id: "m55", email: "l1@example.com", labels: ["newsletter"]),
      member(id: "m56", email: "l2@example.com", labels: ["newsletter"])])
    ghost.expects(:update_member).once.returns(
      member(id: "m55", email: "l1@example.com", labels: %w[newsletter fundraising]))

    sync = sync_with(ghost)
    sync.sync_all!
    assert_equal 1, sync.summary[:updates_deferred]
  end

  test "the sweep persists its summary with a finished_at" do
    enable_sources("newsletter")
    Contact.create!(email: "sum@example.com", sources: ["newsletter"])
    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    ghost.expects(:create_member).returns(member(id: "ms1", email: "sum@example.com"))

    sync_with(ghost).sync_all!
    stored = System.first.reload.ghost_last_sync_summary
    assert_equal 1, stored["created"]
    assert stored["finished_at"].present?
  end

  test "an aborted sweep still persists its counters" do
    enable_sources("newsletter")
    Contact.create!(email: "boom@example.com", sources: ["newsletter"])
    ghost = mock("ghost")
    ghost.expects(:all_members).raises(RuntimeError, "ghost is down")

    assert_raises(RuntimeError) { sync_with(ghost).sync_all! }
    assert System.first.reload.ghost_last_sync_summary["finished_at"].present?,
      "the rollout's review gate reads this panel; a killed sweep must not leave it empty"
  end
end
