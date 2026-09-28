require 'test_helper'

class Stacks::Etl::ReclassifierTest < ActiveSupport::TestCase
  R = Stacks::Etl::Reclassifier
  MEMO = Stacks::Etl::ContentReview::MEMO_KEY

  setup do
    Stacks::AI.stubs(:configured?).returns(true)
    Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1)
  end

  def ai(sensitive) = Stacks::AI::Result.new({ 'sensitive' => sensitive, 'category' => sensitive ? 'hr' : 'none' }, 1, 1)

  def transcript!(id, participants:, invited: 0, excluded: :not_excluded, reason: :none, raw: {}, text: 'we shipped it')
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/#{id}", participant_count: participants)
    m.segments.create!(position: 0, speaker_name: 'A', text: text)
    d = Document.create!(source: :meet, external_id: "cr/#{id}", source_record: m, title: 'Team sync', content_hash: "h-#{id}",
                         excluded: excluded, excluded_reason: reason, raw_metadata: raw)
    invited.times { |i| d.document_contacts.create!(email: "p#{i}@x.co", role: 'attendee') }
    d
  end

  def fresh_memo(doc, sensitive: false)
    doc.update!(raw_metadata: doc.raw_metadata.merge(MEMO => { 'content_hash' => doc.content_hash, 'sensitive' => sensitive }))
    doc
  end

  test 'a group thread whose subject is sensitive is walled off and loses its chunks; a normal one is untouched' do
    bad = Document.create!(source: :google_groups, external_id: '<b@x>', title: 'Bonus payouts', excluded: :not_excluded)
    bad.chunks.create!(source: :google_groups, position: 0, content: 'numbers')
    ok = Document.create!(source: :google_groups, external_id: '<o@x>', title: 'Deploy failed', excluded: :not_excluded)

    stats = R.call

    assert bad.reload.auto_excluded?
    assert bad.reason_compensation?
    assert_equal 0, bad.chunks.count
    assert ok.reload.not_excluded?
    assert_equal 1, stats['not_excluded/none -> auto_excluded/compensation']
  end

  test 'human decisions are never touched' do
    locked = Document.create!(source: :google_groups, external_id: '<l@x>', title: 'Salary', excluded: :manually_included)
    R.call
    assert locked.reload.manually_included?
  end

  test 'standalone notes are walled off; notes follow a transcript that flips in the SAME run' do
    Document.create!(source: :gemini_notes, external_id: 'N1', title: 'Team Weekly', excluded: :not_excluded,
                     raw_metadata: { 'transcript_doc_id' => nil })
    tx = fresh_memo(transcript!('t2', participants: 2, raw: { 'drive_doc_id' => 'D2' })) # legacy: really a 1:1
    notes = Document.create!(source: :gemini_notes, external_id: 'N2', title: 'Team sync', excluded: :not_excluded,
                             raw_metadata: { 'transcript_doc_id' => 'D2' })

    R.call

    assert_equal %w[auto_excluded attendance_unknown],
                 Document.find_by!(external_id: 'N1').then { |d| [d.excluded, d.excluded_reason] }
    assert tx.reload.reason_one_on_one?
    assert notes.reload.reason_one_on_one?, 'notes inherit the decision made earlier in the same run'
  end

  test 'transcripts the rules let through are content-reviewed, once' do
    tx = transcript!('t3', participants: 5, text: 'about your PIP')
    Stacks::AI.expects(:extract).once.returns(ai(true))

    R.call
    assert tx.reload.reason_sensitive_content?

    R.call # memoised: no second model call
  end

  test 'a fresh memo means no model call' do
    fresh_memo(transcript!('t4', participants: 5))
    Stacks::AI.expects(:extract).never
    R.call
  end

  test 'an unreviewed transcript is retried, and re-indexed from stored segments when it clears' do
    skip_without_pgvector
    tx = transcript!('t5', participants: 5, excluded: :auto_excluded, reason: :unreviewed)
    Stacks::AI.expects(:extract).once.returns(ai(false))

    R.call

    assert tx.reload.not_excluded?
    assert_equal 1, tx.chunks.count, 'indexed from the stored segment'
  end

  test 'the head-counts recorded at ingest win over stored rows, so ingest and reclassify agree' do
    # Ingest saw 5 invited; the stored contact rows were deduped down to 1. Without the
    # recorded inputs this would flip to a 1:1 every night and back again on the next ingest.
    tx = fresh_memo(transcript!('t6', participants: 2, invited: 1,
                                raw: { 'privacy_inputs' => { 'participant_count' => 2, 'invite_count' => 5 } }))
    R.call
    assert tx.reload.not_excluded?
  end

  test 'dry run: reports transitions and pending reviews, writes nothing, calls no model' do
    bad = Document.create!(source: :google_groups, external_id: '<d@x>', title: 'Layoffs', excluded: :not_excluded)
    transcript!('t7', participants: 5)
    Stacks::AI.expects(:extract).never

    stats = R.call(dry_run: true)

    assert bad.reload.not_excluded?
    assert_equal 1, stats['not_excluded/none -> auto_excluded/offboarding']
    assert_equal 1, stats[:would_content_review]
  end

  test 'one bad document does not stop the run' do
    Document.create!(source: :google_groups, external_id: '<x@x>', title: 'Payroll', excluded: :not_excluded)
    ok = Document.create!(source: :google_groups, external_id: '<y@x>', title: 'Severance', excluded: :not_excluded)
    calls = 0
    Stacks::Etl::Groups::Connector.any_instance.stubs(:exclusion_for).with do |*|
      (calls += 1) == 1 ? raise('boom') : true
    end.returns([:auto_excluded, :compensation])

    stats = R.call
    assert_equal 1, stats[:errored]
    assert ok.reload.auto_excluded?
  end
end
