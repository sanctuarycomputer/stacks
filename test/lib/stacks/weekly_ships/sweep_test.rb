require 'test_helper'

class StacksWeeklyShipsSweepTest < ActiveSupport::TestCase
  def setup
    Stacks::AI.stubs(:configured?).returns(true)
    # save!(validate: false) bypasses has_msa_and_sow_links validation
    @tracker = ProjectTracker.new(name: "Copilot Money Homepage").tap { |t| t.save!(validate: false) }
  end

  def make_ship_doc(title: "[Copilot Money] Weekly Ship", occurred_at: 1.day.ago,
                    sender_email: "hugh@sanctuary.computer", sender_name: "Hugh Francis",
                    content_hash: SecureRandom.hex(8))
    doc = Document.create!(
      source: :google_groups, external_id: "<#{SecureRandom.hex(6)}@mail.gmail.com>",
      title: title, occurred_at: occurred_at, content_hash: content_hash,
      raw_metadata: { "group_email" => "ships@sanctuary.computer", "gmail_message_ids" => [] }
    )
    # Chunk: position, content, speaker_name, source, occurred_at are the real columns
    doc.chunks.create!(position: 0, content: "This week we shipped things.",
                       speaker_name: sender_name, source: :google_groups, occurred_at: occurred_at)
    # DocumentContact: role, email, name are the real columns
    doc.document_contacts.create!(role: "sender", email: sender_email, name: sender_name)
    doc
  end

  def ai_result(tracker_ids: [], not_a_ship: false, confidence: 0.9, rationale: "r")
    Stacks::AI::Result.new(
      { "tracker_ids" => tracker_ids, "not_a_ship" => not_a_ship,
        "confidence" => confidence, "rationale" => rationale }, 100, 20)
  end

  test "links a ship to the tracker the LLM names, with sender + provenance" do
    doc = make_ship_doc
    Stacks::AI.stubs(:extract).returns(ai_result(tracker_ids: [@tracker.id]))
    stats = Stacks::WeeklyShips::Sweep.run!
    ship = WeeklyShip.find_by(document: doc, project_tracker: @tracker)
    assert ship.llm?
    assert_equal "hugh@sanctuary.computer", ship.sent_by_email
    assert_equal "Hugh Francis", ship.sent_by_name
    assert_equal doc.occurred_at.to_i, ship.sent_at.to_i
    assert_equal 0.9, ship.confidence
    assert ShipScan.find_by(document: doc).linked?
    assert_equal 1, stats[:linked]
  end

  test "multi-tracker ships create one link per tracker" do
    other = ProjectTracker.new(name: "XXIX 3.0 Website").tap { |t| t.save!(validate: false) }
    make_ship_doc
    Stacks::AI.stubs(:extract).returns(ai_result(tracker_ids: [@tracker.id, other.id]))
    Stacks::WeeklyShips::Sweep.run!
    assert_equal 2, WeeklyShip.count
  end

  test "not_a_ship and low-confidence outcomes record scans without links" do
    doc1 = make_ship_doc(title: "Lunch plans")
    doc2 = make_ship_doc(title: "[Mystery] Weekly Ship")
    Stacks::AI.stubs(:extract)
      .returns(ai_result(not_a_ship: true), ai_result(tracker_ids: [@tracker.id], confidence: 0.3))
    Stacks::WeeklyShips::Sweep.run!
    assert ShipScan.find_by(document: doc1).not_a_ship?
    assert ShipScan.find_by(document: doc2).no_match?
    assert_equal 0, WeeklyShip.count
  end

  test "documents older than 90 days are out_of_scope with no LLM call" do
    doc = make_ship_doc(occurred_at: 120.days.ago)
    Stacks::AI.expects(:extract).never
    Stacks::WeeklyShips::Sweep.run!
    assert ShipScan.find_by(document: doc).out_of_scope?
  end

  test "already-scanned documents with unchanged content_hash are skipped" do
    doc = make_ship_doc(content_hash: "abc")
    ShipScan.create!(document: doc, outcome: :no_match, scanned_at: 1.day.ago,
                     scanned_content_hash: "abc")
    Stacks::AI.expects(:extract).never
    Stacks::WeeklyShips::Sweep.run!
  end

  test "changed content_hash re-scans: refreshes sent fields and adds links, never removes" do
    doc = make_ship_doc(content_hash: "v2", occurred_at: Time.zone.now)
    ship = WeeklyShip.new(document: doc, project_tracker: @tracker,
                          sent_at: 8.days.ago, matched_by: :llm)
    ship.via_sweep = true
    ship.save!
    ShipScan.create!(document: doc, outcome: :linked, scanned_at: 8.days.ago,
                     scanned_content_hash: "v1")
    other = ProjectTracker.new(name: "F2").tap { |t| t.save!(validate: false) }
    Stacks::AI.stubs(:extract).returns(ai_result(tracker_ids: [other.id]))
    Stacks::WeeklyShips::Sweep.run!
    assert WeeklyShip.exists?(document: doc, project_tracker: @tracker), "existing link must not be removed"
    assert WeeklyShip.exists?(document: doc, project_tracker: other)
    assert_equal doc.occurred_at.to_i, ship.reload.sent_at.to_i, "sent_at must refresh on re-scan"
  end

  test "human_locked scans are never re-processed even when content changes" do
    doc = make_ship_doc(content_hash: "v2")
    ShipScan.create!(document: doc, outcome: :no_match, scanned_at: 1.day.ago,
                     scanned_content_hash: "v1", human_locked: true)
    Stacks::AI.expects(:extract).never
    Stacks::WeeklyShips::Sweep.run!
  end

  test "AI errors leave no scan row (retry next night) and count as errored" do
    make_ship_doc
    Stacks::AI.stubs(:extract).raises(Stacks::AI::Error, "boom")
    stats = Stacks::WeeklyShips::Sweep.run!
    assert_equal 0, ShipScan.count
    assert_equal 1, stats[:errored]
  end

  test "without an API key the LLM pass is skipped entirely" do
    Stacks::AI.stubs(:configured?).returns(false)
    make_ship_doc
    Stacks::AI.expects(:extract).never
    stats = Stacks::WeeklyShips::Sweep.run!
    assert_equal 0, ShipScan.count
    assert_equal 1, stats[:skipped_no_key]
  end

  test "prompt candidates are ranked with subject-matching trackers first" do
    ProjectTracker.new(name: "Zzz Unrelated").tap { |t| t.save!(validate: false) }
    make_ship_doc(title: "[Copilot Money] Weekly Ship")
    captured = nil
    Stacks::AI.stubs(:extract).with { |kw| captured = kw[:prompt]; true }
      .returns(ai_result(tracker_ids: [@tracker.id]))
    Stacks::WeeklyShips::Sweep.run!
    assert captured.index("Copilot Money Homepage") < captured.index("Zzz Unrelated")
  end

  test "a distinctive client token ranks a tracker without full-name containment" do
    harvey = ProjectTracker.new(name: "Harvey Staff Augmentation").tap { |t| t.save!(validate: false) }
    ProjectTracker.new(name: "Zzz Unrelated").tap { |t| t.save!(validate: false) }
    make_ship_doc(title: "[Sanctuary / Harvey.ai] Weekly Ship - 8/14/26")
    captured = nil
    Stacks::AI.stubs(:extract).with { |kw| captured = kw[:prompt]; true }
      .returns(ai_result(tracker_ids: [harvey.id]))
    Stacks::WeeklyShips::Sweep.run!
    assert captured.index("Harvey Staff Augmentation") < captured.index("Zzz Unrelated"),
      "token overlap (harvey) should outrank non-matching trackers"
  end

  test "ETL-excluded ships@ documents are never scanned" do
    doc = make_ship_doc
    doc.update_column(:excluded, Document.excludeds[:auto_excluded])
    Stacks::AI.expects(:extract).never
    Stacks::WeeklyShips::Sweep.run!
    assert_nil ShipScan.find_by(document: doc)
  end

  test "nil occurred_at counts as errored without writing a scan row" do
    doc = make_ship_doc
    doc.update_column(:occurred_at, nil)
    Stacks::AI.expects(:extract).never
    stats = Stacks::WeeklyShips::Sweep.run!
    assert_equal 0, ShipScan.count
    assert_equal 1, stats[:errored]
  end

  test "ActiveRecord error on a doc is caught and does not abort remaining docs" do
    # Two docs; the first AI call raises an AR error, the second succeeds.
    # Both docs must be attempted (error on one never aborts the run).
    make_ship_doc(title: "[Copilot Money] Weekly Ship A")
    make_ship_doc(title: "[Copilot Money] Weekly Ship B")
    Stacks::AI.stubs(:extract)
      .raises(ActiveRecord::StatementInvalid, "simulated db error")
      .then.returns(ai_result(tracker_ids: [@tracker.id]))
    stats = Stacks::WeeklyShips::Sweep.run!
    assert_equal 1, stats[:errored], "first doc should count as errored"
    assert_equal 1, stats[:linked], "second doc should still be processed and linked"
  end
end
