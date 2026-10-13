require "test_helper"

class StacksLearningQuizTest < ActiveSupport::TestCase
  Q = Stacks::Learning::Quiz

  setup do
    @person = learning_person!
    @mod = learning_module!(steps: ["read"], questions: 5, pass_percent: 80)
    @assignment = learning_assign!(@person, learning_course!(modules: [@mod]))
    complete_step!(@person, @mod.module_steps.first)
  end

  # right: how many of the questions to answer correctly (correct_index is 0).
  def answers(right:)
    @mod.quiz_questions.each_with_index.to_h { |q, i| [q.id.to_s, i < right ? "0" : "1"] }
  end

  def submit(right:)
    Q.submit!(assignment: @assignment, learning_module: @mod, answers: answers(right: right))
  end

  test "4 of 5 at an 80% pass mark passes, completes the module and the assignment" do
    result = submit(right: 4)
    assert_equal :passed, result.status
    assert result.attempt.passed
    assert_equal [4, 5], [result.attempt.correct_count, result.attempt.question_count]
    assert ModuleCompletion.exists?(admin_user: @person, learning_module: @mod)
    assert @assignment.reload.completed_at.present?
  end

  test "3 of 5 fails, is recorded, and leaves one attempt" do
    result = submit(right: 3)
    assert_equal :failed, result.status
    assert_not result.attempt.passed
    assert_equal 1, result.attempts_left
    assert_equal 1, QuizAttempt.where(admin_user: @person).count
  end

  test "the failure message gives the score and pass mark but no answers" do
    result = submit(right: 3)
    assert_includes result.message, "3 of 5"
    assert_includes result.message, "4"
    assert_not_includes result.message, "right"
    assert_not_includes result.message, "Because"
  end

  test "a third attempt is refused and not recorded" do
    2.times { submit(right: 0) }
    result = submit(right: 5)
    assert_equal :rejected, result.status
    assert_nil result.attempt
    assert_equal 2, QuizAttempt.where(admin_user: @person).count
    assert_not ModuleCompletion.exists?(admin_user: @person, learning_module: @mod)
  end

  test "one retry grant allows exactly one more attempt" do
    2.times { submit(right: 0) }
    QuizRetryGrant.create!(admin_user: @person, learning_module: @mod)
    assert_equal :failed, submit(right: 0).status
    assert_equal :rejected, submit(right: 5).status
    assert_equal 3, QuizAttempt.where(admin_user: @person).count
  end

  test "an incomplete or malformed submission is rejected and does not use an attempt" do
    partial = answers(right: 5).first(4).to_h
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: partial).status
    out_of_range = answers(right: 5).transform_values { "9" }
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: out_of_range).status
    junk = answers(right: 5).transform_values { "abc" }
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: junk).status
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: nil).status
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: ["0"]).status
    hexish = answers(right: 5).transform_values { "0x0" }
    assert_equal :rejected, Q.submit!(assignment: @assignment, learning_module: @mod, answers: hexish).status
    assert_equal 0, QuizAttempt.where(admin_user: @person).count
  end

  test "no attempt after a pass" do
    submit(right: 5)
    assert_equal :rejected, submit(right: 5).status
    assert_equal 1, QuizAttempt.where(admin_user: @person).count
  end

  test "the quiz is closed until every step is done" do
    StepCompletion.where(admin_user: @person).delete_all
    assert_equal :rejected, submit(right: 5).status
    assert_equal 0, QuizAttempt.where(admin_user: @person).count
  end

  test "a module that is not in the assignment's course is rejected" do
    stray = learning_module!(steps: [], questions: 1)
    result = Q.submit!(assignment: @assignment, learning_module: stray, answers: { stray.quiz_questions.first.id.to_s => "0" })
    assert_equal :rejected, result.status
    assert_equal 0, QuizAttempt.count
  end

  test "a waived assignment takes no attempts" do
    @assignment.update!(waived_at: Time.current)
    assert_equal :rejected, submit(right: 5).status
  end
end
