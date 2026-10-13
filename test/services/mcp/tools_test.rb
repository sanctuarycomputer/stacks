require 'test_helper'

class Mcp::ToolsTest < ActiveSupport::TestCase
  setup do
    @doc = Document.create!(source: :meet, external_id: 'd1', title: 'Gateway', excluded: :not_excluded)
    @chunk = Chunk.create!(document: @doc, position: 0, content: 'we decided to ship the gateway', source: :meet)
    @excluded = Document.create!(source: :meet, external_id: 'd2', title: 'Secret 1:1', excluded: :auto_excluded)
  end

  test 'search tool returns hits as json text' do
    resp = Mcp::SearchTool.call(query: 'gateway', mode: 'keyword', server_context: {})
    text = resp.content.first[:text]
    assert_includes text, 'gateway'
  end

  test 'get_document refuses an excluded document' do
    resp = Mcp::GetDocumentTool.call(id: @excluded.id, server_context: {})
    assert_includes resp.content.first[:text].downcase, 'not found'
  end

  test 'list_documents omits excluded documents (privacy wall)' do
    resp = Mcp::ListDocumentsTool.call(server_context: {})
    payload = JSON.parse(resp.content.first[:text])
    ids = payload.map { |d| d['id'] }
    assert_includes ids, @doc.id
    refute_includes ids, @excluded.id
  end

  test 'list_documents filters by occurred_at range and paginates with offset' do
    a = Document.create!(source: :meet, external_id: 'a', title: 'Recent A', excluded: :not_excluded, occurred_at: Time.utc(2026, 6, 3))
    b = Document.create!(source: :meet, external_id: 'b', title: 'Recent B', excluded: :not_excluded, occurred_at: Time.utc(2026, 6, 2))
    _old = Document.create!(source: :meet, external_id: 'c', title: 'Old', excluded: :not_excluded, occurred_at: Time.utc(2025, 1, 1))

    ranged = ids_for(Mcp::ListDocumentsTool.call(occurred_after: '2026-06-01', server_context: {}))
    assert_equal [a.id, b.id], ranged, 'only in-range docs, newest first'

    page2 = ids_for(Mcp::ListDocumentsTool.call(occurred_after: '2026-06-01', limit: 1, offset: 1, server_context: {}))
    assert_equal [b.id], page2, 'offset skips the first (newest) in-range doc'
  end

  test "list_documents can filter to gemini_notes and hides excluded notes" do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/z")
    note = Document.create!(source: :gemini_notes, external_id: "gn", title: "Roadmap notes", excluded: :not_excluded, source_record: m)
    Document.create!(source: :gemini_notes, external_id: "gn2", title: "1:1 notes", excluded: :auto_excluded, source_record: m)

    resp = Mcp::ListDocumentsTool.call(source: "gemini_notes", server_context: {})
    ids = JSON.parse(resp.content.first[:text]).map { |d| d["id"] }
    assert_equal [note.id], ids
  end

  test 'get_document returns body joined from the doc chunks in position order' do
    # @doc already has a position-0 chunk from setup; add a later one out of insertion order.
    Chunk.create!(document: @doc, position: 2, content: 'and we set the launch date', source: :meet)
    Chunk.create!(document: @doc, position: 1, content: 'then we picked the rollout plan', source: :meet)

    payload = JSON.parse(Mcp::GetDocumentTool.call(id: @doc.id, server_context: {}).content.first[:text])
    assert_equal(
      "we decided to ship the gateway\nthen we picked the rollout plan\nand we set the launch date",
      payload['body']
    )
  end

  test 'get_document returns meeting_key for a meeting-backed doc and nil for a standalone doc' do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: 'cr/gd-1')
    note = Document.create!(source: :gemini_notes, external_id: 'gd-note', title: 'Roadmap notes',
                            excluded: :not_excluded, source_record: m)
    Chunk.create!(document: note, position: 0, content: 'summary: shipped the gateway', source: :meet)

    linked = JSON.parse(Mcp::GetDocumentTool.call(id: note.id, server_context: {}).content.first[:text])
    assert_equal m.id, linked['meeting_key']
    assert_equal 'summary: shipped the gateway', linked['body']

    standalone = JSON.parse(Mcp::GetDocumentTool.call(id: @doc.id, server_context: {}).content.first[:text])
    assert_nil standalone['meeting_key']
  end

  # project_tracker_ids: which project tracker(s) a document's meeting was matched to.

  def matched_meeting!(key, tracker_names, rationale: 'RATIONALE-TEXT names the client.')
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/#{key}", started_at: 1.day.ago)
    transcript = Document.create!(source: :meet, external_id: "t-#{key}", title: "Sync #{key}", excluded: :not_excluded,
                                  source_record: m, occurred_at: 1.day.ago)
    notes = Document.create!(source: :gemini_notes, external_id: "n-#{key}", title: "Sync #{key} notes", excluded: :not_excluded,
                             source_record: m, occurred_at: 1.day.ago)
    trackers = tracker_names.map { |n| ProjectTracker.new(name: n).tap { |t| t.save!(validate: false) } }
    m.project_trackers << trackers.reverse
    MeetingScan.create!(meeting: m, outcome: :linked, scanned_at: 1.hour.ago, confidence: 0.91, rationale: rationale)
    [m, transcript, notes, trackers.map(&:id).sort]
  end

  def listed(**args)
    JSON.parse(Mcp::ListDocumentsTool.call(server_context: {}, **args).content.first[:text])
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    count
  end

  test 'list_documents gives a meeting transcript and its notes the same sorted project_tracker_ids' do
    _m, transcript, notes, ids = matched_meeting!('one', %w[Harvey Acme])
    by_id = listed.index_by { |d| d['id'] }
    assert_equal 2, ids.size
    assert_equal ids, by_id[transcript.id]['project_tracker_ids']
    assert_equal ids, by_id[notes.id]['project_tracker_ids']
  end

  test 'list_documents answers for two meetings in one call, and [] for everything else' do
    _a, a_doc, _a_notes, a_ids = matched_meeting!('a', %w[Harvey])
    _b, b_doc, _b_notes, b_ids = matched_meeting!('b', %w[Acme])
    unmatched = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: 'cr/none')
    plain = Document.create!(source: :meet, external_id: 'none', excluded: :not_excluded, source_record: unmatched)
    mail = Document.create!(source: :google_groups, external_id: '<m@x>', excluded: :not_excluded, title: 'Deploy chatter')

    by_id = listed.index_by { |d| d['id'] }
    assert_equal a_ids, by_id[a_doc.id]['project_tracker_ids']
    assert_equal b_ids, by_id[b_doc.id]['project_tracker_ids']
    assert_not_equal a_ids, b_ids
    assert_equal [], by_id[plain.id]['project_tracker_ids']
    assert_equal [], by_id[mail.id]['project_tracker_ids']
    assert_equal [], by_id[@doc.id]['project_tracker_ids'], 'a document with no meeting'
  end

  test 'list_documents adds no query per document' do
    matched_meeting!('q1', %w[Harvey])
    few = count_queries { listed }
    matched_meeting!('q2', %w[Acme])
    matched_meeting!('q3', %w[Initech])
    assert_equal few, count_queries { listed }
  end

  # notion_project_ids: the Notion projects of every tracker a document is
  # linked to, through its meeting's match or, for a ships@ email, its weekly ship.

  def notion_tracker!(name, notion_project_ids)
    ProjectTracker.new(name: name, notion_project_ids: notion_project_ids).tap { |t| t.save!(validate: false) }
  end

  def meeting_doc!(key, trackers)
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/np-#{key}", started_at: 1.day.ago)
    doc = Document.create!(source: :meet, external_id: "np-#{key}", title: "Sync #{key}", excluded: :not_excluded,
                           source_record: m, occurred_at: 1.day.ago)
    m.project_trackers << trackers
    doc
  end

  def ship_email!(key, trackers)
    doc = Document.create!(source: :google_groups, external_id: "<ship-#{key}@x>", title: "Ship #{key}", excluded: :not_excluded,
                           occurred_at: 1.day.ago, raw_metadata: { 'group_email' => Document::SHIPS_GROUP_EMAIL })
    trackers.each do |t|
      ship = WeeklyShip.new(document: doc, project_tracker: t, sent_at: 1.day.ago, matched_by: :llm)
      ship.via_sweep = true
      ship.save!
    end
    doc
  end

  def got(doc)
    JSON.parse(Mcp::GetDocumentTool.call(id: doc.id, server_context: {}).content.first[:text])
  end

  test 'notion_project_ids is the de-duplicated union over the trackers a meeting was matched to' do
    harvey = notion_tracker!('Harvey', %w[proj-b proj-a])
    retainer = notion_tracker!('Harvey Retainer', %w[proj-c proj-a])
    doc = meeting_doc!('two', [harvey, retainer])
    assert_equal %w[proj-a proj-b proj-c], listed.index_by { |d| d['id'] }[doc.id]['notion_project_ids']
    payload = got(doc)
    assert_equal %w[proj-a proj-b proj-c], payload['notion_project_ids']
    assert_equal [harvey.id, retainer.id].sort, payload['project_tracker_ids']
  end

  test 'a ships@ email returns the Notion projects of the trackers its weekly ship is linked to' do
    harvey = notion_tracker!('Harvey', %w[proj-a])
    acme = notion_tracker!('Acme', %w[proj-d proj-a])
    doc = ship_email!('one', [harvey, acme])
    assert_equal %w[proj-a proj-d], listed.index_by { |d| d['id'] }[doc.id]['notion_project_ids']
    payload = got(doc)
    assert_equal %w[proj-a proj-d], payload['notion_project_ids']
    assert_equal [], payload['project_tracker_ids'], 'project_tracker_ids still means the meeting match'
  end

  test 'notion_project_ids is [] for a document with no tracker, and for one whose tracker names no Notion project' do
    bare = meeting_doc!('bare', [notion_tracker!('No project', [])])
    half = meeting_doc!('half', [notion_tracker!('No project either', []), notion_tracker!('Has one', %w[proj-z])])
    mail = Document.create!(source: :google_groups, external_id: '<plain@x>', excluded: :not_excluded, title: 'Deploy chatter')
    by_id = listed.index_by { |d| d['id'] }
    assert_equal [], by_id[@doc.id]['notion_project_ids'], 'no meeting, no tracker'
    assert_equal [], by_id[mail.id]['notion_project_ids'], 'mail that is not a ship'
    assert_equal [], by_id[bare.id]['notion_project_ids']
    assert_equal 1, by_id[bare.id]['project_tracker_ids'].size, 'the tracker is still listed'
    assert_equal %w[proj-z], by_id[half.id]['notion_project_ids']
    [@doc, mail, bare].each { |d| assert_equal [], got(d)['notion_project_ids'] }
  end

  test 'list_documents reads notion_project_ids in the same number of queries for 2 linked documents as for 6' do
    make = lambda do |key|
      meeting_doc!("m#{key}", [notion_tracker!("M#{key}", ["proj-m#{key}"]), notion_tracker!("N#{key}", ["proj-n#{key}"])])
      ship_email!("s#{key}", [notion_tracker!("S#{key}", ["proj-s#{key}"])])
    end
    make.(1)
    few = count_queries { assert_equal 2, listed.count { |d| d['notion_project_ids'].any? } }
    make.(2)
    make.(3)
    many = count_queries { assert_equal 6, listed.count { |d| d['notion_project_ids'].any? } }
    assert_equal few, many
    assert_operator few, :<=, 5, 'the page, the join-table check, the meeting matches, the weekly ships, the trackers'
  end

  test 'the tool descriptions document notion_project_ids' do
    [Mcp::ListDocumentsTool, Mcp::GetDocumentTool].each do |tool|
      assert_includes tool.description, 'notion_project_ids', tool.tool_name
    end
  end

  test 'list_documents and get_document never return the rationale or the confidence' do
    _m, transcript, _notes, _ids = matched_meeting!('quiet', %w[Harvey])
    [Mcp::ListDocumentsTool.call(server_context: {}),
     Mcp::GetDocumentTool.call(id: transcript.id, server_context: {})].each do |resp|
      json = resp.content.first[:text]
      assert_includes json, 'project_tracker_ids'
      assert_not_includes json, 'rationale'
      assert_not_includes json, 'RATIONALE-TEXT'
      assert_not_includes json, 'confidence'
      assert_not_includes json, '0.91'
    end
  end

  test 'list_documents still hides an excluded document of a matched meeting' do
    _m, transcript, notes, ids = matched_meeting!('walled', %w[Harvey])
    transcript.update_columns(excluded: Document.excludeds[:manually_excluded])
    by_id = listed.index_by { |d| d['id'] }
    assert_nil by_id[transcript.id]
    assert_equal ids, by_id[notes.id]['project_tracker_ids']
    assert_includes Mcp::GetDocumentTool.call(id: transcript.id, server_context: {}).content.first[:text].downcase, 'not found'
  end

  test 'both document tools still answer, with no tracker ids, before the join table exists' do
    _m, transcript, _notes, _ids = matched_meeting!('early', %w[Harvey])
    ActiveRecord::Base.connection.stubs(:table_exists?).with('meetings_project_trackers').returns(false)
    queries = []
    record = ->(*, payload) { queries << payload[:sql] }
    listed_ids = got = nil
    ActiveSupport::Notifications.subscribed(record, 'sql.active_record') do
      listed_ids = listed.index_by { |d| d['id'] }[transcript.id]['project_tracker_ids']
      got = JSON.parse(Mcp::GetDocumentTool.call(id: transcript.id, server_context: {}).content.first[:text])
    end
    assert_equal [], listed_ids
    assert_equal [], got['project_tracker_ids']
    assert_equal transcript.id, got['id']
    assert_empty queries.grep(/meetings_project_trackers/), 'the missing table is never queried'
  end

  test 'a missing join table is not remembered: the ids come back once it exists' do
    _m, transcript, _notes, ids = matched_meeting!('later', %w[Harvey])
    ActiveRecord::Base.connection.stubs(:table_exists?).with('meetings_project_trackers').returns(false)
    assert_equal [], listed.index_by { |d| d['id'] }[transcript.id]['project_tracker_ids']
    ActiveRecord::Base.connection.unstub(:table_exists?)
    assert_equal ids, listed.index_by { |d| d['id'] }[transcript.id]['project_tracker_ids']
    assert_equal ids, JSON.parse(Mcp::GetDocumentTool.call(id: transcript.id, server_context: {}).content.first[:text])['project_tracker_ids']
  end

  test 'the document tools describe project_tracker_ids' do
    assert_includes Mcp::ListDocumentsTool.description, 'project_tracker_ids'
    assert_includes Mcp::GetDocumentTool.description, 'project_tracker_ids'
  end

  def ids_for(resp)
    JSON.parse(resp.content.first[:text]).map { |d| d['id'] }
  end
end
