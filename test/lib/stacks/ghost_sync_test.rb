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
end
