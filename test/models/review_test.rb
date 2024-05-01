require "test_helper"

class ReviewTest < ActiveSupport::TestCase
  test "#level returns the greatest matching level whose points are below the review's points" do
    review = Review.new
    review.expects(:total_points).returns(650)

    assert_equal({
      name: "S1",
      min_points: 595,
      salary: 107231.25
    }, review.level)
  end

  test "#level returns the minimum level if no levels are below the review's points" do
    review = Review.new
    review.expects(:total_points).returns(-1)

    assert_equal({
      name: "J1",
      min_points: 100,
      salary: 63000
    }, review.level)
  end
end
