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

  test 'unknown count (0 or nil) is not a 1:1; title rules still apply' do
    # 0 = "unknown" (e.g. the participants endpoint returned empty) — must not wall off a
    # legitimate large meeting.
    assert_equal [:not_excluded, :none], C.call(title: 'All Hands', participant_count: 0)
    assert_equal [:not_excluded, :none], C.call(title: 'All Hands', participant_count: nil)
    # ...but a sensitive title is still excluded regardless of the unknown count.
    assert_equal [:auto_excluded, :performance_review], C.call(title: 'Performance Review', participant_count: 0)
  end
end
