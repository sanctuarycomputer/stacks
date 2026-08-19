require 'test_helper'

class WeeklyShipTest < ActiveSupport::TestCase
  def make_document(external_id: "<root-#{SecureRandom.hex(4)}@mail.gmail.com>", gmail_ids: nil)
    Document.create!(
      source: :google_groups,
      external_id: external_id,
      title: "[Client] Weekly Ship",
      occurred_at: Time.zone.now,
      raw_metadata: { "group_email" => "ships@sanctuary.computer",
                      "gmail_message_ids" => gmail_ids || [external_id] }
    )
  end

  def make_tracker(name: "Client Project")
    pt = ProjectTracker.new(name: name)
    pt.save!(validate: false)
    pt
  end

  test "human create locks the document's scan as linked" do
    doc = make_document
    WeeklyShip.create!(document: doc, project_tracker: make_tracker,
                       sent_at: Time.zone.now, matched_by: :human)
    scan = ShipScan.find_by(document: doc)
    assert scan.human_locked?
    assert scan.linked?
  end

  test "human destroy of the last link marks the scan no_match and locked" do
    doc = make_document
    ship = WeeklyShip.create!(document: doc, project_tracker: make_tracker,
                              sent_at: Time.zone.now, matched_by: :human)
    ship.destroy!
    scan = ShipScan.find_by(document: doc)
    assert scan.human_locked?
    assert scan.no_match?
  end

  test "sweep-created ships (via_sweep) do not human-lock the scan" do
    doc = make_document
    ship = WeeklyShip.new(document: doc, project_tracker: make_tracker,
                          sent_at: Time.zone.now, matched_by: :llm)
    ship.via_sweep = true
    ship.save!
    assert_nil ShipScan.find_by(document: doc)
  end

  test "defaults matched_by to human when not set by the sweep" do
    doc = make_document
    ship = WeeklyShip.create!(document: doc, project_tracker: make_tracker, sent_at: Time.zone.now)
    assert ship.human?
  end

  test "rejects duplicate document+tracker pairs" do
    doc = make_document
    tracker = make_tracker
    WeeklyShip.create!(document: doc, project_tracker: tracker, sent_at: Time.zone.now, matched_by: :human)
    assert_raises(ActiveRecord::RecordInvalid) do
      WeeklyShip.create!(document: doc, project_tracker: tracker, sent_at: Time.zone.now, matched_by: :human)
    end
  end
end
