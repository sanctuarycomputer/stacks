require 'test_helper'

class Stacks::Etl::Groups::ConnectorTest < ActiveSupport::TestCase
  setup do
    skip_without_pgvector # ingest creates Embedding records (pgvector column)
    Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1)
  end

  def thread_doc(root:, bodies:, subject: 'Deploy failed', group: 'dev@sanctuary.computer')
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
      segments: segs, raw_metadata: { 'group_email' => group },
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
    assert doc.not_excluded?, 'an ordinary list thread is eligible'
    assert doc.chunks.any?, 'eligible thread must be chunked/embedded'
    assert_equal 'GoogleGroupThread', doc.source_record_type
    assert_equal 'dev@sanctuary.computer', doc.source_record.group_email
  end

  test 'a thread whose subject names a sensitive topic is walled off like a meeting title' do
    src = mock('source')
    src.stubs(:each_thread).multiple_yields([thread_doc(root: '<s@x>', bodies: ['numbers inside'], subject: 'Re: 2027 salary bands')])
    Stacks::Etl::Groups::GroupsSource.stubs(:new).returns(src)

    Stacks::Etl::Groups::Connector.new(admin_email: 'hugh@sanctuary.computer').run(track: false)

    doc = Document.find_by!(source: :google_groups, external_id: '<s@x>')
    assert doc.auto_excluded?
    assert doc.reason_compensation?
    assert_equal 0, doc.chunks.count
  end

  test 'mail to a sensitive group (jobs@, admin@, accounting@) is content-reviewed; other lists are not' do
    conn = Stacks::Etl::Groups::Connector.new(admin_email: 'hugh@sanctuary.computer')
    Stacks::Etl::ContentReview.expects(:call).with(has_entries(text: "Alice: your salary goes up in May")).returns([:auto_excluded, :sensitive_content])
    admin = thread_doc(root: '<r1@x>', bodies: ['your salary goes up in May'], subject: 'Re: next year', group: 'admin@sanctuary.computer')
    assert_equal [:auto_excluded, :sensitive_content], conn.exclusion_for(admin)

    dev = thread_doc(root: '<r2@x>', bodies: ['the api is down'], group: 'dev@sanctuary.computer')
    assert_equal [:not_excluded, :none], conn.exclusion_for(dev)
  end

  test 'the subject rules still run first for screened groups (no model call)' do
    conn = Stacks::Etl::Groups::Connector.new(admin_email: 'hugh@sanctuary.computer')
    Stacks::Etl::ContentReview.expects(:call).never
    doc = thread_doc(root: '<r3@x>', bodies: ['x'], subject: 'Payroll run', group: 'accounting@sanctuary.computer')
    assert_equal [:auto_excluded, :compensation], conn.exclusion_for(doc)
  end

  test 'a thread cross-posted to jobs@ and another list stays screened whichever crawl runs last' do
    skip_without_pgvector
    Stacks::Etl::ContentReview.stubs(:call).returns([:auto_excluded, :sensitive_content])
    run = lambda do |group|
      src = mock('source')
      src.stubs(:each_thread).multiple_yields([thread_doc(root: '<x@x>', bodies: ['offer details'], subject: 'Re: next steps', group: group)])
      Stacks::Etl::Groups::GroupsSource.stubs(:new).returns(src)
      Stacks::Etl::Groups::Connector.new(admin_email: 'hugh@sanctuary.computer').run(track: false)
    end
    run.('jobs@xxix.co')          # a screened list, on another of the org's domains
    run.('team@sanctuary.computer')
    doc = Document.find_by!(external_id: '<x@x>')
    assert doc.reason_sensitive_content?, 'the later, unscreened crawl must not undo the screening'
    assert_equal 0, doc.chunks.count
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
