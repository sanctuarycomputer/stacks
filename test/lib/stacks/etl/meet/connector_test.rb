require 'test_helper'

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

    # standalone: no resolvable transcript -> classify on the count
    standalone = conn.exclusion_for(transcript_doc_id: "NOPE", title: "Team Weekly", participant_count: 5, contacts: [])
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
end
