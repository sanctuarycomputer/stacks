require "test_helper"

# Real commits across threads, so transactional tests are off and teardown
# deletes everything this test created.
class StacksLearningQuizConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 8

  setup do
    @person = learning_person!
    @mod = learning_module!(steps: ["read"], questions: 2, pass_percent: 80)
    @course = learning_course!(modules: [@mod])
    @assignment = learning_assign!(@person, @course)
    complete_step!(@person, @mod.module_steps.first)
  end

  teardown do
    QuizAttempt.where(admin_user_id: @person.id).delete_all
    QuizRetryGrant.where(admin_user_id: @person.id).delete_all
    ModuleCompletion.where(admin_user_id: @person.id).delete_all
    StepCompletion.where(admin_user_id: @person.id).delete_all
    QualificationGrant.where(admin_user_id: @person.id).delete_all
    CourseAssignment.where(admin_user_id: @person.id).delete_all
    CourseModule.where(course_id: @course.id).delete_all
    @course.destroy
    QuizQuestion.where(learning_module_id: @mod.id).delete_all
    ModuleStep.where(learning_module_id: @mod.id).delete_all
    @mod.destroy
    @person.destroy
  end

  test "simultaneous wrong submissions never exceed the attempt limit" do
    wrong = @mod.quiz_questions.to_h { |q| [q.id.to_s, "1"] }
    # One failed attempt already recorded: exactly one more is allowed.
    QuizAttempt.create!(admin_user: @person, learning_module: @mod, answers: wrong,
                        correct_count: 0, question_count: 2, passed: false)

    ready = Queue.new
    go = Queue.new
    threads = Array.new(THREADS) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          assignment = CourseAssignment.find(@assignment.id)
          ready << true
          go.pop
          Stacks::Learning::Quiz.submit!(assignment: assignment, learning_module: @mod, answers: wrong)
        end
      end
    end
    THREADS.times { ready.pop }
    THREADS.times { go << true }
    threads.each(&:join)

    assert_equal 2, QuizAttempt.where(admin_user: @person, learning_module: @mod).count
  end
end
