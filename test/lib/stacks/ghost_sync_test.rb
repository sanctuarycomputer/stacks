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

  test "creates a member with source-name labels for an eligible contact and links ghost_id" do
    GhostSyncedSource.create!(source: "newsletter")
    contact = Contact.create!(email: "new@example.com", sources: ["newsletter"], display_name: "New Person")

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([])
    created = member(id: "m1", email: "new@example.com", labels: ["newsletter"], newsletters: ["weekly"])
    ghost.expects(:create_member)
      .with(email: "new@example.com", name: "New Person", labels: ["newsletter"])
      .returns(created)

    sync = sync_with(ghost)
    sync.sync_all!
    contact.reload
    assert_equal "m1", contact.ghost_id
    assert contact.ghost_data["synced_at"].present?
    assert_equal 1, sync.summary[:created]
  end

  test "updates managed labels while preserving unmanaged (hand-added) labels; never writes newsletters" do
    GhostSyncedSource.create!(source: "newsletter")
    GhostSyncedSource.create!(source: "fundraising")
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
    GhostSyncedSource.create!(source: "newsletter")
    Contact.create!(email: "same@example.com", sources: ["newsletter"], ghost_id: "m3")
    existing = member(id: "m3", email: "same@example.com", labels: ["newsletter"])

    ghost = mock("ghost")
    ghost.expects(:all_members).returns([existing])
    ghost.expects(:update_member).never
    ghost.expects(:create_member).never

    sync_with(ghost).sync_all!
  end

  test "adopts the existing member on 422 duplicate-email create" do
    GhostSyncedSource.create!(source: "newsletter")
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
    GhostSyncedSource.create!(source: "newsletter")
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
    GhostSyncedSource.create!(source: "newsletter")
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

  test "handle_member_deleted keeps the contact, clears ghost_id, stamps deleted_at" do
    existing = Contact.create!(email: "bye@example.com", ghost_id: "m16", sources: ["g3d:ghost"])
    sync = sync_with(mock("ghost"))
    sync.handle_member_deleted("id" => "m16", "email" => "bye@example.com")
    existing.reload
    assert_nil existing.ghost_id
    assert existing.ghost_data.dig("snapshot", "deleted_at").present?
    assert_equal ["g3d:ghost"], existing.sources
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
    GhostSyncedSource.create!(source: "newsletter")
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
    original_handler = ActiveRecord::Base.connection.instance_variable_get(:@query_cache_enabled)

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |name, started, finished, unique_id, payload|
      if payload[:sql].match?(/UPDATE\s+contacts/i)
        update_count += 1
      end
    end

    sync.upsert_contact_from_member(m)

    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_equal 0, update_count, "repeat upsert with identical member should issue no UPDATE"
  end
end
