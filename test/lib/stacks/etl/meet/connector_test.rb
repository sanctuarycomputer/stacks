require 'test_helper'
require 'digest'

class Stacks::Etl::Meet::ConnectorTest < ActiveSupport::TestCase
  setup do
    skip_without_pgvector # ingest creates Embedding records, which need the pgvector column
    Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1)
  end

  def normalized(id, title, pcount)
    {
      external_id: id, title: title, url: 'http://x', occurred_at: Time.utc(2026, 1, 1), content_hash: id,
      contacts: Array.new(pcount) { |i| { email: "p#{i}@x.co", name: "P#{i}", role: 'participant' } },
      segments: [{ speaker_name: 'P0', speaker_email: 'p0@x.co', text: 'decision text', started_at: Time.utc(2026, 1, 1) }],
      raw_metadata: {}, build_source_record: ->(_doc) { nil }
    }
  end

  test 'api mode ingests and classifies a 1:1 as excluded' do
    source = mock('source')
    source.stubs(:each_meeting).multiple_yields([normalized('m1', 'Gateway kickoff', 5)], [normalized('m2', 'Drew 1:1', 2)])
    Stacks::Etl::Meet::MeetApiSource.stubs(:new).returns(source)

    Stacks::Etl::Meet::Connector.new(admin_email: 'hugh@sanctuary.computer', mode: :api).run

    assert Document.find_by!(external_id: 'm1').not_excluded?
    m2 = Document.find_by!(external_id: 'm2')
    assert m2.auto_excluded?
    assert m2.reason_one_on_one?
    assert_equal 0, m2.chunks.count
  end

  test 'classifies on real participant_count, not contacts.size (big meeting, few speakers != 1:1)' do
    # 6-person meeting where Calendar enrichment missed, so contacts fell back to the 2
    # distinct speakers. participant_count=6 must keep it OUT of the 1:1 exclusion.
    n = normalized('m3', 'Roadmap planning', 2).merge(participant_count: 6)
    source = mock('source')
    source.stubs(:each_meeting).multiple_yields([n])
    Stacks::Etl::Meet::MeetApiSource.stubs(:new).returns(source)

    Stacks::Etl::Meet::Connector.new(admin_email: 'hugh@sanctuary.computer', mode: :api).run
    assert Document.find_by!(external_id: 'm3').not_excluded?
  end

  test "exclusion_for inherits a joined transcript's decision at ingest, else classifies on count" do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/inh")
    Document.create!(source: :meet, external_id: "TX1", source_record: m,
                     excluded: :auto_excluded, excluded_reason: :one_on_one)
    conn = Stacks::Etl::Meet::Connector.new(admin_email: "a@x.co", mode: :gemini_notes)

    # joined: resolves TX1 via for_drive_doc and inherits verbatim
    joined = conn.exclusion_for(transcript_doc_id: "TX1", title: "Anything", participant_count: 9, contacts: [])
    assert_equal [:auto_excluded, :one_on_one], joined

    # standalone: genuine notes-only (no transcript link, nil) -> classify on the count
    standalone = conn.exclusion_for(transcript_doc_id: nil, title: "Team Weekly", participant_count: 5, contacts: [])
    assert_equal [:not_excluded, :none], standalone

    # API-keyed transcript: for_drive_doc must resolve via raw_metadata->>'drive_doc_id'
    # (MeetApiSource keys external_id on the conference-record id, not the Drive doc id).
    Document.create!(source: :meet, external_id: "confRec/1",
                     raw_metadata: { "drive_doc_id" => "DRV1" },
                     excluded: :auto_excluded, excluded_reason: :one_on_one)
    api = conn.exclusion_for(transcript_doc_id: "DRV1", title: "Benign Title", participant_count: 9, contacts: [])
    assert_equal [:auto_excluded, :one_on_one], api,
                 "API-ingested transcript (drive_doc_id in raw_metadata) must still inherit its exclusion"
  end

  test "notes for an eligible meeting are ingested, chunked, and searchable; a 1:1's notes are walled off" do
    skip_without_pgvector
    # Eligible transcript meeting + a 1:1 transcript meeting already ingested:
    ok_m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/ok")
    Document.create!(source: :meet, external_id: "T_OK", source_record: ok_m, excluded: :not_excluded, excluded_reason: :none)
    oo_m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/oo")
    Document.create!(source: :meet, external_id: "T_OO", source_record: oo_m, excluded: :auto_excluded, excluded_reason: :one_on_one)

    files = [
      OpenStruct.new(id: "N_OK", name: "Roadmap - 2026/06/30 15:00 EDT - Notes by Gemini", created_time: "2026-06-30T15:00:00Z"),
      OpenStruct.new(id: "N_OO", name: "1:1 - 2026/06/30 16:00 EDT - Notes by Gemini", created_time: "2026-06-30T16:00:00Z")
    ]
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: files, next_page_token: nil))
    svc.stubs(:export_file).with("N_OK", "text/markdown").returns("Notes\n\nInvited [A](mailto:a@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/T_OK/edit)\n\n### Summary\nShip the gateway.")
    svc.stubs(:export_file).with("N_OO", "text/markdown").returns("Notes\n\nMeeting records [Transcript](https://docs.google.com/document/d/T_OO/edit)\n\n### Summary\nSensitive 1:1 content.")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    Stacks::Etl::Meet::Connector.new(admin_email: "hugh@sanctuary.computer", mode: :gemini_notes).run(track: false)

    ok = Document.find_by!(source: :gemini_notes, external_id: "N_OK")
    assert ok.not_excluded?
    assert ok.chunks.any?, "eligible notes should be chunked/searchable"
    assert_equal ["a@x.co"], ok.document_contacts.pluck(:email)
    assert_equal ok_m.id, ok.source_record_id

    oo = Document.find_by!(source: :gemini_notes, external_id: "N_OO")
    assert oo.auto_excluded?
    assert oo.reason_one_on_one?
    assert_equal 0, oo.chunks.count, "a 1:1's notes must be walled off"
  end

  test "API path: conference record with docsDestination ingests transcript + notes on one Meeting; 1:1 walled" do
    skip_without_pgvector

    # Two conference records: one group meeting, one 1:1.
    cr_group = OpenStruct.new(name: 'conferenceRecords/g1', start_time: '2026-01-01T09:00:00Z',
                               end_time: '2026-01-01T09:30:00Z', space: 'spaces/g1')
    cr_11    = OpenStruct.new(name: 'conferenceRecords/oo1', start_time: '2026-01-01T10:00:00Z',
                               end_time: '2026-01-01T10:30:00Z', space: 'spaces/oo1')

    tx_group = OpenStruct.new(name: 'conferenceRecords/g1/transcripts/1',
                               docs_destination: OpenStruct.new(document: 'NOTES_DOC_G1'))
    tx_11    = OpenStruct.new(name: 'conferenceRecords/oo1/transcripts/1',
                               docs_destination: OpenStruct.new(document: 'NOTES_DOC_OO1'))

    entry_g  = OpenStruct.new(participant: 'p1', text: 'roadmap decision', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    entry_oo = OpenStruct.new(participant: 'p1', text: 'sensitive', start_time: '2026-01-01T10:01:00Z', end_time: '2026-01-01T10:01:05Z')

    # 3 participants in the group meeting; 2 in the 1:1.
    parts_g  = [%w[p1 Alice], %w[p2 Bob], %w[p3 Carol]].map { |n, d| OpenStruct.new(name: n, signedin_user: OpenStruct.new(display_name: d)) }
    parts_oo = [%w[p1 Drew], %w[p2 Hugh]].map { |n, d| OpenStruct.new(name: n, signedin_user: OpenStruct.new(display_name: d)) }

    meet_svc = mock('meet')
    meet_svc.stubs(:list_conference_records).returns(
      OpenStruct.new(conference_records: [cr_group, cr_11], next_page_token: nil)
    )
    meet_svc.stubs(:get_space).returns(OpenStruct.new(meeting_code: 'abc', meeting_uri: 'https://meet.google.com/abc'))
    meet_svc.stubs(:list_conference_record_transcripts).with('conferenceRecords/g1', page_token: nil)
            .returns(OpenStruct.new(transcripts: [tx_group], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_transcripts).with('conferenceRecords/oo1', page_token: nil)
            .returns(OpenStruct.new(transcripts: [tx_11], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_transcript_entries)
            .with('conferenceRecords/g1/transcripts/1', page_size: 100, page_token: nil)
            .returns(OpenStruct.new(transcript_entries: [entry_g], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_transcript_entries)
            .with('conferenceRecords/oo1/transcripts/1', page_size: 100, page_token: nil)
            .returns(OpenStruct.new(transcript_entries: [entry_oo], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_participants).with('conferenceRecords/g1', page_token: nil)
            .returns(OpenStruct.new(participants: parts_g, next_page_token: nil))
    meet_svc.stubs(:list_conference_record_participants).with('conferenceRecords/oo1', page_token: nil)
            .returns(OpenStruct.new(participants: parts_oo, next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(meet_svc)
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'Team Sync', attendees: [])

    notes_group_md = "# 📝 Notes\n\n## Team Sync\n\nInvited [A](mailto:alice@x.co) [B](mailto:bob@x.co) [C](mailto:carol@x.co)\n\n### Summary\nRoadmap aligned.\n"
    notes_11_md    = "# 📝 Notes\n\n## Drew & Hugh\n\nInvited [D](mailto:drew@x.co) [H](mailto:hugh@x.co)\n\n### Summary\nSensitive 1:1 content.\n"

    drive_svc = mock('drive')
    drive_svc.stubs(:export_file).with('NOTES_DOC_G1', 'text/markdown').returns(notes_group_md)
    drive_svc.stubs(:export_file).with('NOTES_DOC_OO1', 'text/markdown').returns(notes_11_md)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(drive_svc)

    Stacks::Etl::Meet::Connector.new(admin_email: 'hugh@sanctuary.computer', mode: :api).run(track: false)

    # Group meeting — both documents eligible and chunked.
    tx_g = Document.find_by!(source: :meet, external_id: 'conferenceRecords/g1')
    nt_g = Document.find_by!(source: :gemini_notes, external_id: 'NOTES_DOC_G1')
    assert tx_g.not_excluded?, "group transcript must be eligible"
    assert nt_g.not_excluded?, "group notes must inherit eligibility"
    assert tx_g.chunks.any?, "transcript must be chunked"
    assert nt_g.chunks.any?, "notes must be chunked"
    assert_equal tx_g.source_record_id, nt_g.source_record_id, "transcript and notes must share one Meeting"
    assert_equal 'NOTES_DOC_G1', nt_g.raw_metadata['gemini_notes_doc_id']

    # 1:1 meeting — both documents walled (0 chunks).
    tx_oo = Document.find_by!(source: :meet, external_id: 'conferenceRecords/oo1')
    nt_oo = Document.find_by!(source: :gemini_notes, external_id: 'NOTES_DOC_OO1')
    assert tx_oo.auto_excluded?, "1:1 transcript must be auto-excluded by participant count"
    assert tx_oo.reason_one_on_one?
    assert nt_oo.auto_excluded?, "notes must inherit the 1:1 exclusion"
    assert nt_oo.reason_one_on_one?, "notes must inherit the transcript's exclusion REASON verbatim"
    assert_equal 0, tx_oo.chunks.count
    assert_equal 0, nt_oo.chunks.count
  end

  test "exclusion_for conservatively excludes a referenced-but-unresolved transcript (not invited count)" do
    conn = Stacks::Etl::Meet::Connector.new(admin_email: "a@x.co", mode: :gemini_notes)
    pending = conn.exclusion_for(transcript_doc_id: "NOT_INGESTED_YET", title: "Benign Title", participant_count: 5, contacts: [])
    assert_equal [:auto_excluded, :pending_transcript], pending,
                 "a transcript-bearing meeting whose transcript isn't ingested yet must NOT be classified on the invited count"
    none = conn.exclusion_for(transcript_doc_id: nil, title: "Team Weekly", participant_count: 5, contacts: [])
    assert_equal [:not_excluded, :none], none, "genuine notes-only (no transcript reference) still classifies on the count"
  end

  test "API transcript absorbs a pre-existing standalone notes Meeting (heals the split)" do
    skip_without_pgvector
    export = "# Notes\n\n## Sync\n\nInvited [A](mailto:a@x.co)\n\n### Summary\nStuff happened.\n"
    # Night 1: notes ingested standalone (before the transcript existed), same content the API
    # will recompute -> content_hash matches -> changed:false -> only the ABSORB can re-home it.
    standalone = Meeting.create!(meet_source: :gemini_notes, gemini_notes_doc_id: "NOTES_DOC_X")
    notes_doc = Document.create!(source: :gemini_notes, external_id: "NOTES_DOC_X", source_record: standalone,
                                 excluded: :not_excluded, excluded_reason: :none,
                                 content_hash: Digest::SHA256.hexdigest(export))
    # Night 2: the API transcript for the SAME meeting arrives (docsDestination = NOTES_DOC_X).
    cr = OpenStruct.new(name: 'conferenceRecords/x1', start_time: '2026-01-01T09:00:00Z', end_time: '2026-01-01T09:30:00Z', space: 'spaces/x')
    tx = OpenStruct.new(name: 'conferenceRecords/x1/transcripts/1', docs_destination: OpenStruct.new(document: 'NOTES_DOC_X'))
    entry = OpenStruct.new(participant: 'p1', text: 'hello', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    parts = [OpenStruct.new(name: 'p1', signedin_user: OpenStruct.new(display_name: 'Alice'))]
    meet_svc = mock('meet')
    meet_svc.stubs(:list_conference_records).returns(OpenStruct.new(conference_records: [cr], next_page_token: nil))
    meet_svc.stubs(:get_space).returns(OpenStruct.new(meeting_code: 'abc', meeting_uri: 'https://meet.google.com/abc'))
    meet_svc.stubs(:list_conference_record_transcripts).returns(OpenStruct.new(transcripts: [tx], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_transcript_entries).returns(OpenStruct.new(transcript_entries: [entry], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_participants).returns(OpenStruct.new(participants: parts, next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(meet_svc)
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'Sync', attendees: [])
    drive_svc = mock('drive')
    drive_svc.stubs(:export_file).with("NOTES_DOC_X", "text/markdown").returns(export)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(drive_svc)

    Stacks::Etl::Meet::Connector.new(admin_email: "hugh@sanctuary.computer", mode: :api).run(track: false)

    tx_doc = Document.find_by!(source: :meet, external_id: "conferenceRecords/x1")
    notes_doc.reload
    assert_equal tx_doc.source_record_id, notes_doc.source_record_id, "notes must be re-homed onto the transcript's Meeting"
    assert_equal 0, Meeting.where(id: standalone.id).count, "the standalone notes Meeting must be absorbed (deleted)"
    assert_equal 1, Meeting.where(meet_conference_record_id: 'conferenceRecords/x1').count, "exactly one Meeting for the meeting"
  end

  test "combined doc ingests as a meet transcript + gemini_notes doc on one meeting; 1:1 walled by speakers" do
    skip_without_pgvector
    group = OpenStruct.new(id: "N_GROUP", name: "Roadmap - 2026/06/30 15:00 EDT - Notes by Gemini", created_time: "2026-06-30T15:00:00Z")
    group_md = "# 📝 Notes\n\n## Roadmap\n\nInvited [A](mailto:a@x.co) [B](mailto:b@x.co) [C](mailto:c@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/N_GROUP/edit)\n\n### Summary\nShip the gateway.\n\n# 📖 Transcript\n\nAlice: kickoff\nBob: agreed\nCarol: shipping\n"
    oneone = OpenStruct.new(id: "N_11", name: "Kyle & Hugh - 2026/06/30 16:00 EDT - Notes by Gemini", created_time: "2026-06-30T16:00:00Z")
    # Two people INVITED plus a 3rd invitee, but only TWO actually speak -> 1:1 by real attendance.
    oneone_md = "# 📝 Notes\n\n## Kyle & Hugh\n\nInvited [K](mailto:k@x.co) [H](mailto:h@x.co) [X](mailto:x@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/N_11/edit)\n\n### Summary\nSensitive.\n\n# 📖 Transcript\n\nKyle: hey\nHugh: hi\n"

    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [group, oneone], next_page_token: nil))
    svc.stubs(:export_file).with("N_GROUP", "text/markdown").returns(group_md)
    svc.stubs(:export_file).with("N_11", "text/markdown").returns(oneone_md)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    # This exercises the BACKFILL path (transcript parsed from the combined doc's markdown),
    # which is now gated behind parse_transcript: true. In daily mode (the default) recent
    # transcripts come structured from the Meet API instead.
    Stacks::Etl::Meet::Connector.new(admin_email: "hugh@sanctuary.computer", mode: :gemini_notes, parse_transcript: true).run(track: false)

    tx = Document.find_by!(source: :meet, external_id: "N_GROUP")
    notes = Document.find_by!(source: :gemini_notes, external_id: "N_GROUP")
    assert tx.not_excluded?
    assert notes.not_excluded?
    assert tx.chunks.any?, "transcript chunked/searchable"
    assert notes.chunks.any?, "notes chunked/searchable"
    assert_equal tx.source_record_id, notes.source_record_id, "same Meeting"
    assert_equal ["a@x.co", "b@x.co", "c@x.co"], tx.document_contacts.pluck(:email).sort

    tx11 = Document.find_by!(source: :meet, external_id: "N_11")
    notes11 = Document.find_by!(source: :gemini_notes, external_id: "N_11")
    assert tx11.auto_excluded?, "2 real speakers -> 1:1 excluded despite 3 invited"
    assert tx11.reason_one_on_one?
    assert notes11.auto_excluded?, "notes inherit the 1:1 exclusion"
    assert_equal 0, tx11.chunks.count
    assert_equal 0, notes11.chunks.count
  end
end
