require 'test_helper'

class Stacks::Etl::Groups::ConnectorTest < ActiveSupport::TestCase
  setup do
    skip_without_pgvector # ingest creates Embedding records (pgvector column)
    Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1)
  end

  def thread_doc(root:, bodies:, subject: 'Deploy failed')
    segs = bodies.each_with_index.map { |b, i|
      { speaker_name: 'Alice', speaker_email: 'alice@x.co', text: b, started_at: Time.utc(2026, 6, 1, 10 + i), ended_at: nil }
    }
    {
      source: :google_groups, external_id: root, title: subject,
      url: 'https://groups.google.com/a/sanctuary.computer/g/dev',
      occurred_at: Time.utc(2026, 6, 1, 10),
      content_hash: Digest::SHA256.hexdigest(bodies.join("\n")),
      participant_count: 1,
      contacts: [{ email: 'dev@sanctuary.computer', name: 'Dev', role: 'group' },
                 { email: 'alice@x.co', name: 'Alice', role: 'sender' }],
      segments: segs, raw_metadata: { 'group_email' => 'dev@sanctuary.computer' },
      build_source_record: ->(doc) {
        GoogleGroupThread.find_or_create_by(root_message_id: doc.external_id) do |gt|
          gt.group_email = 'dev@sanctuary.computer'
          gt.subject = subject
          gt.message_count = bodies.size
          gt.first_message_at = Time.utc(2026, 6, 1, 10)
          gt.last_message_at = Time.utc(2026, 6, 1, 11)
        end
      }
    }
  end

  test 'ingests a thread: not_excluded, chunked, embedded, with a GoogleGroupThread source_record' do
    src = mock('source')
    src.stubs(:each_thread).multiple_yields([thread_doc(root: '<a@x>', bodies: ['the api is down'])])
    Stacks::Etl::Groups::GroupsSource.stubs(:new).returns(src)

    Stacks::Etl::Groups::Connector.new(admin_email: 'hugh@sanctuary.computer').run(track: false)

    doc = Document.find_by!(source: :google_groups, external_id: '<a@x>')
    assert doc.not_excluded?, 'public group mail is never auto-excluded'
    assert doc.chunks.any?, 'eligible thread must be chunked/embedded'
    assert_equal 'GoogleGroupThread', doc.source_record_type
    assert_equal 'dev@sanctuary.computer', doc.source_record.group_email
  end

  test 'a new reply changes content_hash and re-indexes the same Document' do
    one = mock('s1')
    one.stubs(:each_thread).multiple_yields([thread_doc(root: '<a@x>', bodies: ['down'])])
    Stacks::Etl::Groups::GroupsSource.stubs(:new).returns(one)
    Stacks::Etl::Groups::Connector.new(admin_email: 'a@x.co').run(track: false)
    first_count = Document.find_by!(external_id: '<a@x>').chunks.count

    two = mock('s2')
    two.stubs(:each_thread).multiple_yields([thread_doc(root: '<a@x>', bodies: ['down', 'up and fixed now'])])
    Stacks::Etl::Groups::GroupsSource.stubs(:new).returns(two)
    Stacks::Etl::Groups::Connector.new(admin_email: 'a@x.co').run(track: false)

    assert_equal 1, Document.where(external_id: '<a@x>').count, 'same thread, one Document'
    assert_operator Document.find_by!(external_id: '<a@x>').chunks.count, :>=, first_count
  end
end
