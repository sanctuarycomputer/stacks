require "test_helper"

class ReviewTest < ActiveSupport::TestCase
  test "#level returns the greatest matching level whose points are below the review's points" do
    review = Review.new
    review.expects(:total_points).returns(625)

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

  test "#level returns the correct level when the individual is right on the cusp" do
    review = Review.new
    review.expects(:total_points).returns(595)

    assert_equal({
      name: "S1",
      min_points: 595,
      salary: 107231.25
    }, review.level)
  end

  test "#level returns the correct level when the individual is 1 point below the cusp" do
    review = Review.new
    review.expects(:total_points).returns(594)

    assert_equal({
      name: "EML3",
      min_points: 540,
      salary: 96862.5
    }, review.level)
  end
end
