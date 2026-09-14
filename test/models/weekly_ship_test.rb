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

  test "human UPDATE of a sweep-created ship locks the scan and links it" do
    doc = make_document
    tracker = make_tracker
    # Create via sweep (no scan written, no human lock)
    ship = WeeklyShip.new(document: doc, project_tracker: tracker,
                          sent_at: Time.zone.now, matched_by: :llm)
    ship.via_sweep = true
    ship.save!
    assert_nil ShipScan.find_by(document: doc), "sweep create must not write a scan"

    # Reload a fresh instance (no via_sweep set) and do a human update
    fresh_ship = WeeklyShip.find(ship.id)
    fresh_ship.update!(sent_by_email: "x@y.com")

    scan = ShipScan.find_by(document: doc)
    assert scan, "scan must exist after human update"
    assert scan.human_locked?, "scan must be human-locked"
    assert scan.linked?, "scan outcome must be linked"
  end

  # ── Issue #2b: document_must_be_ships_group validation ──────────────────

  test "rejects a document that is not a ships@ google_groups document" do
    non_ships_doc = Document.create!(
      source: :google_groups,
      external_id: "<non-ships-#{SecureRandom.hex(4)}@mail.gmail.com>",
      title: "Other Group",
      occurred_at: Time.zone.now,
      raw_metadata: { "group_email" => "other@sanctuary.computer",
                      "gmail_message_ids" => [] }
    )
    ship = WeeklyShip.new(document: non_ships_doc, project_tracker: make_tracker,
                          sent_at: Time.zone.now)
    assert_not ship.valid?
    assert_includes ship.errors[:document], "must be a ships@ Google Groups document"
  end

  test "accepts a ships@ google_groups document" do
    doc = make_document
    ship = WeeklyShip.new(document: doc, project_tracker: make_tracker, sent_at: Time.zone.now)
    assert ship.valid?, ship.errors.full_messages.inspect
  end

  # ── Issue #3: tracker destroy cascade must not human-lock scans ──────────

  test "destroying a tracker leaves no human_locked scan for sweep-created ships" do
    doc = make_document
    tracker = make_tracker
    ship = WeeklyShip.new(document: doc, project_tracker: tracker,
                          sent_at: Time.zone.now, matched_by: :llm)
    ship.via_sweep = true
    ship.save!
    tracker.destroy!
    scan = ShipScan.find_by(document: doc)
    assert_nil scan, "tracker cascade must not create a human-locked scan"
  end

  test "destroying a ship directly still human-locks the scan as no_match" do
    doc = make_document
    tracker = make_tracker
    ship = WeeklyShip.create!(document: doc, project_tracker: tracker,
                              sent_at: Time.zone.now, matched_by: :human)
    ship.destroy!
    scan = ShipScan.find_by(document: doc)
    assert scan, "direct destroy must leave a scan"
    assert scan.human_locked?
    assert scan.no_match?
  end

  # ── Issue #7: editing a ship's document re-evaluates the old doc's scan ──

  test "updating document_id marks old doc scan as no_match when it has no remaining ships" do
    doc_a = make_document
    doc_b = make_document
    tracker = make_tracker

    # Human creates ship on doc_a → scan becomes linked
    ship = WeeklyShip.create!(document: doc_a, project_tracker: tracker,
                              sent_at: Time.zone.now, matched_by: :human)
    scan_a = ShipScan.find_by(document: doc_a)
    assert scan_a.linked?

    # Human updates to doc_b
    ship.update!(document: doc_b)

    # doc_a now has no ships → scan should be no_match + human_locked
    scan_a.reload
    assert scan_a.no_match?, "old doc scan must be no_match after reassignment"
    assert scan_a.human_locked?

    # doc_b scan should be linked + human_locked
    scan_b = ShipScan.find_by(document: doc_b)
    assert scan_b, "new doc must have a scan"
    assert scan_b.linked?
    assert scan_b.human_locked?
  end
end
