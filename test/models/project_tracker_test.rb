require "test_helper"

class ProjectTrackerTest < ActiveSupport::TestCase
  test "likely_complete? is true when in dormant scope and name is not ongoing or retainer" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)

    chain = mock("chain")
    ProjectTracker.expects(:dormant).returns(chain)
    chain.expects(:where).with(id: pt.id).returns(chain)
    chain.expects(:exists?).returns(true)

    assert_predicate pt, :likely_complete?
  end

  test "likely_complete? is false when name matches considered_ongoing?" do
    pt = ProjectTracker.new(name: "Something ongoing")
    pt.save!(validate: false)

    chain = mock("chain")
    ProjectTracker.expects(:dormant).returns(chain)
    chain.expects(:where).with(id: pt.id).returns(chain)
    chain.expects(:exists?).returns(true)

    assert_not pt.likely_complete?
  end

  test "likely_complete? is false when not in dormant scope" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)

    chain = mock("chain")
    ProjectTracker.expects(:dormant).returns(chain)
    chain.expects(:where).with(id: pt.id).returns(chain)
    chain.expects(:exists?).returns(false)

    assert_not pt.likely_complete?
  end

  test "in_progress scope uses SQL subqueries instead of materializing complete and dormant ids" do
    sql = ProjectTracker.in_progress.to_sql
    not_in_selects = sql.scan(/NOT IN \(SELECT/)
    assert_operator not_in_selects.size, :>=, 2,
      "expected chained NOT IN subqueries (avoid splat [*complete, *dormant] loading all rows in Ruby)"
  end
end
