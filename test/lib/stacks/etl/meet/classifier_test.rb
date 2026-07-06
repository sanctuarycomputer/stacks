require 'test_helper'

class Stacks::Etl::Meet::ClassifierTest < ActiveSupport::TestCase
  C = Stacks::Etl::Meet::Classifier

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
end
