require 'test_helper'

class Stacks::Etl::ClassifierTest < ActiveSupport::TestCase
  C = Stacks::Etl::Classifier

  test '1:1 by participant count' do
    assert_equal [:auto_excluded, :one_on_one], C.call(title: 'Sync', participant_count: 2)
  end

  test 'title families' do
    assert_equal [:auto_excluded, :one_on_one], C.call(title: 'Drew / Hugh 1:1', participant_count: 5)
    assert_equal [:auto_excluded, :performance_review], C.call(title: 'Q2 Performance Review', participant_count: 5)
    assert_equal [:auto_excluded, :compensation], C.call(title: 'Comp planning', participant_count: 5)
    assert_equal [:auto_excluded, :hr], C.call(title: 'HR catchup', participant_count: 5)
    assert_equal [:auto_excluded, :offboarding], C.call(title: 'Termination discussion', participant_count: 5)
    assert_equal [:auto_excluded, :pip], C.call(title: 'PIP review', participant_count: 5)
  end

  # G1: the broadened lexicon. Each title is a 3+ person meeting that the old rules let through.
  {
    'Raise conversation' => :compensation,
    'Annual raises' => :compensation,
    'Bonus pool planning' => :compensation,
    'Year-end bonuses' => :compensation,
    'Equity grants' => :compensation,
    'Payroll run' => :compensation,
    'Pay review 2026' => :compensation,
    'Pay bands workshop' => :compensation,
    'Salary bands' => :compensation,
    'Severance terms' => :compensation,
    'Promotion committee' => :performance_review,
    'Promotions' => :performance_review,
    'Peer feedback round' => :performance_review,
    '360 feedback: Sam' => :performance_review,
    'Upward feedback' => :performance_review,
    'Disciplinary meeting' => :hr,
    'Grievance hearing' => :hr,
    'Workplace investigation' => :hr,
    'Harassment complaint' => :hr,
    'Parental leave plan' => :hr,
    'Medical leave' => :hr,
    'Layoffs' => :offboarding,
    'Lay-off planning' => :offboarding,
    'Resignation' => :offboarding,
    'Exit interview' => :offboarding,
    'Skip-level with Hugh' => :one_on_one,
    'Skip level' => :one_on_one,
    'Skiplevel chat' => :one_on_one
  }.each do |title, reason|
    test "lexicon: #{title.inspect} -> #{reason}" do
      assert_equal [:auto_excluded, reason], C.call(title: title, participant_count: 6)
      assert_equal [:auto_excluded, reason], C.title_exclusion(title)
    end
  end

  # Deliberately NOT title rules: they are common in ordinary studio/client work (prod: 129
  # group threads titled "feedback", mostly client design feedback). The content review
  # (Stacks::Etl::ContentReview) catches the personal kind in meetings.
  ['Design feedback session', 'Client feedback on comps', 'Homepage comps', 'Quarterly review',
   'Fundraise sync', 'Code review', 'Weekly check-in', 'Gateway redesign kickoff'].each do |title|
    test "not a title rule: #{title.inspect}" do
      assert_equal [:not_excluded, :none], C.call(title: title, participant_count: 6)
      assert_nil C.title_exclusion(title)
    end
  end

  test 'ordinary group meeting is not excluded' do
    assert_equal [:not_excluded, :none], C.call(title: 'Gateway redesign kickoff', participant_count: 6)
  end

  test 'a zero/unknown head-count is conservatively treated as a probable 1:1 (privacy-first)' do
    # 0 = "couldn't confirm a group" (e.g. the participants endpoint returned empty). We
    # wall it off pending human review rather than risk leaking a private 1:1.
    assert_equal [:auto_excluded, :one_on_one], C.call(title: 'Catch up', participant_count: 0)
    # nil = no count signal supplied at all -> title rules only (callers always pass an int).
    assert_equal [:not_excluded, :none], C.call(title: 'Gateway kickoff', participant_count: nil)
  end

  test 'title_exclusion tolerates nil' do
    assert_nil C.title_exclusion(nil)
  end
end
