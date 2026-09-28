require 'test_helper'

class Stacks::Etl::ContentReviewTest < ActiveSupport::TestCase
  R = Stacks::Etl::ContentReview

  def result(sensitive, category = 'none')
    Stacks::AI::Result.new({ 'sensitive' => sensitive, 'category' => category }, 10, 5)
  end

  def doc(hash: 'h1', raw: {})
    Document.new(source: :meet, external_id: SecureRandom.hex(4), content_hash: hash, raw_metadata: raw)
  end

  setup { Stacks::AI.stubs(:configured?).returns(true) }

  test 'an ordinary meeting stays eligible and the verdict is memoised on the doc' do
    d = doc
    Stacks::AI.expects(:extract).once.returns(result(false))
    assert_equal [:not_excluded, :none], R.call(doc: d, text: 'we shipped the gateway')
    memo = d.raw_metadata[R::MEMO_KEY]
    assert_equal 'h1', memo['content_hash']
    assert_equal false, memo['sensitive']
  end

  test 'a flagged meeting is walled off as sensitive_content, with its category recorded' do
    d = doc
    Stacks::AI.expects(:extract).once.returns(result(true, 'compensation'))
    assert_equal [:auto_excluded, :sensitive_content], R.call(doc: d, text: "let's talk about your raise")
    assert_equal 'compensation', d.raw_metadata[R::MEMO_KEY]['category']
  end

  test 'a memo for the same content is reused (no second model call)' do
    d = doc(raw: { R::MEMO_KEY => { 'content_hash' => 'h1', 'version' => R::VERSION, 'sensitive' => true, 'category' => 'hr' } })
    Stacks::AI.expects(:extract).never
    assert_equal [:auto_excluded, :sensitive_content], R.call(doc: d, text: 'x')
  end

  test 'changed content invalidates the memo' do
    d = doc(hash: 'h2', raw: { R::MEMO_KEY => { 'content_hash' => 'h1', 'version' => R::VERSION, 'sensitive' => false } })
    Stacks::AI.expects(:extract).once.returns(result(true, 'hr'))
    assert_equal [:auto_excluded, :sensitive_content], R.call(doc: d, text: 'x')
  end

  test 'long transcripts are reviewed window by window; any flagged window walls the whole doc' do
    text = ('a' * (R::WINDOW_CHARS - 10)) + ' secret raise talk ' + ('b' * R::WINDOW_CHARS)
    Stacks::AI.expects(:extract).twice.returns(result(false)).then.returns(result(true, 'compensation'))
    assert_equal [:auto_excluded, :sensitive_content], R.call(doc: doc, text: text)
  end

  test 'windows overlap so a passage on a window boundary is seen whole by one window' do
    text = 'x' * (R::WINDOW_CHARS * 2 + 5)
    windows = R.windows(text)
    assert windows.size >= 3
    assert windows.all? { |w| w.length <= R::WINDOW_CHARS }
    windows.each_cons(2) { |a, b| assert_equal a[-R::OVERLAP_CHARS..], b[0, R::OVERLAP_CHARS] }
  end

  test 'fails CLOSED when no AI key is configured' do
    Stacks::AI.stubs(:configured?).returns(false)
    Stacks::AI.expects(:extract).never
    d = doc
    assert_equal [:auto_excluded, :unreviewed], R.call(doc: d, text: 'anything')
    assert_nil d.raw_metadata[R::MEMO_KEY], 'a failed review is never memoised, so it is retried'
  end

  test 'fails CLOSED on a model error' do
    Stacks::AI.stubs(:extract).raises(Stacks::AI::Error, 'Anthropic API error 529')
    assert_equal [:auto_excluded, :unreviewed], R.call(doc: doc, text: 'anything')
  end

  test 'fails CLOSED when the model answer is not an explicit false' do
    Stacks::AI.stubs(:extract).returns(Stacks::AI::Result.new({ 'sensitive' => nil, 'category' => 'none' }, 1, 1))
    assert_equal [:auto_excluded, :sensitive_content], R.call(doc: doc, text: 'anything')
  end

  test 'a memo from an unknown older prompt version is re-reviewed' do
    d = doc(raw: { R::MEMO_KEY => { 'content_hash' => 'h1', 'version' => 0, 'sensitive' => false } })
    Stacks::AI.expects(:extract).once.returns(result(true, 'hr'))
    assert_equal [:auto_excluded, :sensitive_content], R.call(doc: d, text: 'x')
    assert_equal R::VERSION, d.raw_metadata[R::MEMO_KEY]['version']
  end

  test 'no text to read fails CLOSED (missing is not the same as clean)' do
    Stacks::AI.expects(:extract).never
    assert_equal [:auto_excluded, :unreviewed], R.call(doc: doc, text: '')
    assert_equal [:auto_excluded, :unreviewed], R.call(doc: doc, text: "  \n ")
  end

  test 'works without a doc (no memo)' do
    Stacks::AI.expects(:extract).once.returns(result(false))
    assert_equal [:not_excluded, :none], R.call(doc: nil, text: 'hello', content_hash: 'z')
  end

  # 2026-09-28, Hugh: assessments of job candidates are hiring work (Creative Network grading),
  # not private personnel matters. v2 stopped walling them.
  test 'the prompt no longer treats candidate assessments as sensitive' do
    refute_includes R::CATEGORIES, 'candidate_evaluation'
    assert_match(/assessments? of job candidates/i, R::SYSTEM)
    refute_match(/\(category: candidate_evaluation\)/, R::SYSTEM)
  end

  test 'a v1 verdict stays valid under v2 unless it walled a candidate assessment' do
    v1 = ->(sensitive, category) { doc(raw: { R::MEMO_KEY => { 'content_hash' => 'h1', 'version' => 1,
                                                                 'sensitive' => sensitive, 'category' => category } }) }
    Stacks::AI.expects(:extract).once.returns(result(false)) # only the candidate one is re-read
    assert_equal [:not_excluded, :none], R.call(doc: v1.(false, 'none'), text: 'x')
    assert_equal [:auto_excluded, :sensitive_content], R.call(doc: v1.(true, 'compensation'), text: 'x')
    assert_equal [:not_excluded, :none], R.call(doc: v1.(true, 'candidate_evaluation'), text: 'x')
  end
end
