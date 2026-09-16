require 'test_helper'

class DocumentPermalinkTest < ActiveSupport::TestCase
  def doc(external_id:, gmail_ids:, source: :google_groups, group: "ships@sanctuary.computer")
    Document.new(source: source, external_id: external_id, occurred_at: Time.zone.now,
                 raw_metadata: { "group_email" => group, "gmail_message_ids" => gmail_ids })
  end

  test "prefers the first gmail message id and escapes + and @" do
    d = doc(external_id: "<root@x.com>", gmail_ids: ["<CAJQ+abc=def@mail.gmail.com>"])
    assert_equal "https://groups.google.com/a/sanctuary.computer/d/msgid/ships/CAJQ%2Babc%3Ddef%40mail.gmail.com",
                 d.google_groups_permalink
  end

  test "falls back to external_id when gmail_message_ids is empty or missing" do
    d = doc(external_id: "<root@mail.gmail.com>", gmail_ids: [])
    assert_equal "https://groups.google.com/a/sanctuary.computer/d/msgid/ships/root%40mail.gmail.com",
                 d.google_groups_permalink
    d2 = doc(external_id: "<root@mail.gmail.com>", gmail_ids: nil)
    assert_equal "https://groups.google.com/a/sanctuary.computer/d/msgid/ships/root%40mail.gmail.com",
                 d2.google_groups_permalink
  end

  test "nil for non-google_groups sources and blank group email" do
    assert_nil doc(external_id: "<x@y>", gmail_ids: ["<x@y>"], source: :meet).google_groups_permalink
    assert_nil doc(external_id: "<x@y>", gmail_ids: ["<x@y>"], group: nil).google_groups_permalink
  end

  test "ships_group scope filters by group email" do
    a = Document.create!(source: :google_groups, external_id: "<a@m>", occurred_at: Time.zone.now,
                         raw_metadata: { "group_email" => "ships@sanctuary.computer" })
    Document.create!(source: :google_groups, external_id: "<b@m>", occurred_at: Time.zone.now,
                     raw_metadata: { "group_email" => "other@sanctuary.computer" })
    assert_equal [a.id], Document.ships_group.pluck(:id)
  end
end
