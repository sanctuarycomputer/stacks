require 'test_helper'

# G4: the privacy wall (Document.corpus_eligible) is the ONLY thing keeping HR / comp / 1:1
# content away from the agent. These tests seed walled-off content carrying a CANARY string and
# assert that no agent-facing read path returns it, plus a tripwire that forces every new MCP
# tool touching corpus data through review.
class PrivacyWallTest < ActiveSupport::TestCase
  CANARY = 'zebracanary salary of forty'.freeze

  # A walled-off 1:1 transcript and the (eligible) notes of the same meeting. They share one
  # Meeting row, which holds the transcript's segments.
  def walled_meeting!
    meeting = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/#{SecureRandom.hex(3)}")
    meeting.segments.create!(position: 0, speaker_name: 'Drew', text: CANARY)
    tx = Document.create!(source: :meet, external_id: meeting.meet_conference_record_id, source_record: meeting,
                          title: 'Private chat', excluded: :auto_excluded, excluded_reason: :one_on_one)
    notes = Document.create!(source: :gemini_notes, external_id: "notes-#{SecureRandom.hex(3)}", source_record: meeting,
                             title: 'Team sync notes', excluded: :manually_included, excluded_reason: :none)
    notes.chunks.create!(source: :gemini_notes, position: 0, content: 'ordinary notes summary')
    [tx, notes, meeting]
  end

  test 'search never returns chunks of a walled-off document, even stale ones' do
    doc = Document.create!(source: :meet, external_id: 'stale', title: 'Comp chat',
                           excluded: :auto_excluded, excluded_reason: :compensation)
    doc.chunks.create!(source: :meet, position: 0, content: CANARY) # should have been deleted; defence in depth

    payload = mcp_payload(Mcp::SearchTool.call(query: 'zebracanary', mode: 'keyword', server_context: {}))
    refute_includes payload.to_json, 'zebracanary'
  end

  test 'list_documents and get_document never expose a walled-off document' do
    tx, = walled_meeting!
    refute_includes mcp_payload(Mcp::ListDocumentsTool.call(server_context: {})).to_json, 'Private chat'
    assert_equal({ 'error' => 'Document not found' }, mcp_payload(Mcp::GetDocumentTool.call(id: tx.id, server_context: {})))
  end

  test "get_document on eligible notes does NOT return the walled-off transcript's segments" do
    _tx, notes, = walled_meeting!
    payload = mcp_payload(Mcp::GetDocumentTool.call(id: notes.id, server_context: {}))
    assert_equal 'ordinary notes summary', payload['body']
    refute_includes payload.to_json, 'zebracanary'
  end

  test "including a notes doc does not index its meeting's walled-off transcript" do
    _tx, notes, = walled_meeting!
    notes.chunks.destroy_all
    Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1)
    refute Stacks::Etl::Reindexer.call(notes)
    refute_includes notes.chunks.pluck(:content), CANARY
  end

  test 'a human exclusion walls off every document of the same meeting' do
    meeting = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: 'cr/cascade')
    tx = Document.create!(source: :meet, external_id: 'cr/cascade', source_record: meeting,
                          excluded: :not_excluded, excluded_reason: :none)
    notes = Document.create!(source: :gemini_notes, external_id: 'n-cascade', source_record: meeting,
                             excluded: :not_excluded, excluded_reason: :none)
    notes.chunks.create!(source: :gemini_notes, position: 0, content: 'summary')
    other = Document.create!(source: :meet, external_id: 'unrelated', excluded: :not_excluded, excluded_reason: :none)

    tx.exclude!(by: 'hugh@sanctuary.computer')

    [tx, notes].each do |d|
      d.reload
      assert d.manually_excluded?, "#{d.source} should be walled off"
      assert_equal 'hugh@sanctuary.computer', d.excluded_by
      assert_equal 0, d.chunks.count
    end
    assert other.reload.not_excluded?, 'documents of other meetings are untouched'
  end

  test 'weekly ship tools omit ships whose email was walled off' do
    tracker = ProjectTracker.new(name: 'Wall Tracker')
    tracker.save!(validate: false)
    doc = Document.create!(source: :google_groups, external_id: '<w@x>', title: CANARY, occurred_at: Time.zone.now,
                           excluded: :auto_excluded, excluded_reason: :compensation,
                           raw_metadata: { 'group_email' => 'ships@sanctuary.computer' })
    ship = WeeklyShip.new(document: doc, project_tracker: tracker, sent_at: 1.day.ago, matched_by: :llm, confidence: 0.9)
    ship.via_sweep = true
    ship.save!

    out = Mcp::ListWeeklyShipsTool.call(tracker: tracker.id.to_s, server_context: {})
    refute_includes out.content.first[:text], 'zebracanary'
  end

  test "list_project_trackers shows a walled ship's date but never its subject or link" do
    tracker = ProjectTracker.new(name: 'Wall Tracker 2')
    tracker.save!(validate: false)
    doc = Document.create!(source: :google_groups, external_id: '<w2@x>', title: CANARY, occurred_at: Time.zone.now,
                           excluded: :auto_excluded, excluded_reason: :compensation,
                           raw_metadata: { 'group_email' => 'ships@sanctuary.computer', 'gmail_message_ids' => ['w2@x'] })
    ship = WeeklyShip.new(document: doc, project_tracker: tracker, sent_at: 1.day.ago, matched_by: :llm, confidence: 0.9)
    ship.via_sweep = true
    ship.save!

    out = Mcp::ListProjectTrackersTool.call(name: 'Wall Tracker 2', server_context: {}).content.first[:text]
    refute_includes out, 'zebracanary'
    refute_includes out, 'w2%40x'
    assert_includes out, 'last_weekly_ship', 'the ship itself (its date) is still reported'
  end

  # ---- Tripwire -----------------------------------------------------------------------------
  # Every MCP tool file that touches corpus-derived data, and how it stays behind the wall.
  # A NEW tool that touches these models fails this test until someone reviews it and adds it
  # here. That review is the point: the wall only holds if every read path scopes through
  # Document.corpus_eligible (or a scope built on it).
  CORPUS_TOUCHING = /\b(Document|Chunk|Embedding|Meeting|MeetingTranscriptSegment|MeetingParticipant|Mention|DocumentContact|WeeklyShip|ShipScan|GoogleGroupThread)\b|\.(chunks|segments|weekly_ships?|last_weekly_ship|documents?|document_contacts|mentions|source_record|participants|ship_scans?)\b|:(chunks|weekly_ships?|documents?|document_contacts|mentions|ship_scans?)\b|Stacks::Etl::/

  REVIEWED = {
    'search_tool.rb' => 'Stacks::Etl::Search, which starts from Chunk.corpus_eligible',
    'list_documents_tool.rb' => 'Document.corpus_eligible',
    'get_document_tool.rb' => 'Document.corpus_eligible; segments only for the transcript doc itself',
    'list_weekly_ships_tool.rb' => 'weekly_ships.corpus_eligible',
    'get_weekly_ship_block_tool.rb' => 'WeeklyShip.corpus_eligible',
    'get_project_burnup_tool.rb' => 'weekly_ships.corpus_eligible',
    'provisioning_serializers.rb' => 'serializes ships its callers already scoped with corpus_eligible',
    'list_project_trackers_tool.rb' => "a walled ship's date/sender only; subject + permalink gated on Document.corpus_eligible"
  }.freeze

  test 'tripwire: every MCP file that touches corpus data has been reviewed for the wall' do
    touching = Dir[Rails.root.join('app/services/mcp/**/*.rb')].select { |f| File.read(f).match?(CORPUS_TOUCHING) }
                                                            .map { |f| File.basename(f) }.sort
    # The JSON API is the other agent-reachable surface; today nothing there touches the corpus.
    api = Dir[Rails.root.join('app/controllers/**/*.rb')].select { |f| File.read(f).match?(CORPUS_TOUCHING) }
    assert_empty api, "An API controller now touches corpus data (#{api.join(', ')}): scope it through " \
                      'corpus_eligible and add a canary test here.'
    unreviewed = touching - REVIEWED.keys
    assert_empty unreviewed, "New MCP code touches corpus data: #{unreviewed.join(', ')}. Scope it through " \
                             'Document.corpus_eligible (or a scope built on it), add a canary test above, then list it in REVIEWED.'
    stale = REVIEWED.keys - touching
    assert_empty stale, "REVIEWED lists files that no longer touch corpus data: #{stale.join(', ')}"
  end

  test 'tripwire: each reviewed tool (except the registry/serializer) names its scope' do
    (REVIEWED.keys - %w[provisioning_serializers.rb search_tool.rb]).each do |f|
      assert_match(/corpus_eligible/, File.read(Rails.root.join('app/services/mcp', f)), "#{f} must scope through corpus_eligible")
    end
    assert_match(/Chunk\.corpus_eligible/, File.read(Rails.root.join('lib/stacks/etl/search.rb')))
  end
end
