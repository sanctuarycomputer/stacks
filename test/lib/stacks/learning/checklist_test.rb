require "test_helper"

class StacksLearningChecklistTest < ActiveSupport::TestCase
  CL = Stacks::Learning::Checklist

  test "quiz state moves none / not_open / open / locked / passed" do
    person = learning_person!
    plain = learning_module!(steps: ["read"])
    quizzed = learning_module!(steps: ["read"], questions: 2)
    a = learning_assign!(person, learning_course!(modules: [plain, quizzed]))

    assert_equal :none, CL.new(a).module_state(plain).quiz_state
    assert_equal :not_open, CL.new(a).module_state(quizzed).quiz_state

    complete_step!(person, quizzed.module_steps.first)
    assert_equal :open, CL.new(a).module_state(quizzed).quiz_state
    assert_equal 2, CL.new(a).module_state(quizzed).attempts_left

    2.times { QuizAttempt.create!(admin_user: person, learning_module: quizzed, correct_count: 0, question_count: 2) }
    state = CL.new(a).module_state(quizzed)
    assert_equal :locked, state.quiz_state
    assert_equal 0, state.attempts_left

    QuizRetryGrant.create!(admin_user: person, learning_module: quizzed)
    assert_equal :open, CL.new(a).module_state(quizzed).quiz_state

    QuizAttempt.create!(admin_user: person, learning_module: quizzed, correct_count: 2, question_count: 2, passed: true)
    state = CL.new(a).module_state(quizzed)
    assert_equal :passed, state.quiz_state
    assert state.done?
  end

  test "another person's completions and attempts do not count" do
    person = learning_person!
    other = learning_person!
    mod = learning_module!(steps: ["read"], questions: 1)
    a = learning_assign!(person, learning_course!(modules: [mod]))
    complete_step!(other, mod.module_steps.first)
    QuizAttempt.create!(admin_user: other, learning_module: mod, correct_count: 1, question_count: 1, passed: true)
    state = CL.new(a).module_state(mod)
    assert_not state.steps_done?
    assert_equal :not_open, state.quiz_state
  end

  test "a sign-off is ready only when earlier steps and earlier modules are done" do
    person = learning_person!
    first = learning_module!(steps: ["read"])
    last = learning_module!(steps: ["do", "admin_sign_off"])
    a = learning_assign!(person, learning_course!(modules: [first, last]))
    sign_off = last.module_steps.last

    assert_empty CL.new(a).ready_sign_off_steps
    complete_step!(person, first.module_steps.first)
    assert_empty CL.new(a).ready_sign_off_steps, "the 'do' step before it is not done"
    complete_step!(person, last.module_steps.first)
    assert_equal [sign_off], CL.new(a).ready_sign_off_steps
    assert CL.new(a).step_state(sign_off).ready

    complete_step!(person, sign_off, source: "admin")
    assert_empty CL.new(a).ready_sign_off_steps
  end

  test "a sign-off that is the first step of the first module is ready immediately" do
    person = learning_person!
    mod = learning_module!(steps: ["admin_sign_off", "read"])
    a = learning_assign!(person, learning_course!(modules: [mod]))
    assert_equal [mod.module_steps.first], CL.new(a).ready_sign_off_steps
  end

  test "own_work_remaining? ignores sign-offs and locked quizzes" do
    person = learning_person!
    mod = learning_module!(steps: ["read", "admin_sign_off"], questions: 1)
    a = learning_assign!(person, learning_course!(modules: [mod]))
    assert CL.new(a).own_work_remaining?, "a read step is theirs"

    complete_step!(person, mod.module_steps.first)
    assert_not CL.new(a).own_work_remaining?, "only the sign-off is left (quiz not open yet)"

    complete_step!(person, mod.module_steps.last, source: "admin")
    assert CL.new(a).own_work_remaining?, "the quiz is open and is theirs"

    2.times { QuizAttempt.create!(admin_user: person, learning_module: mod, correct_count: 0, question_count: 1) }
    assert_not CL.new(a).own_work_remaining?, "locked: waiting on an admin"
  end

  test "an auto_check step counts as the person's own work" do
    person = learning_person!
    mod = learning_module!(steps: [["auto_check", "forecast_account"]])
    a = learning_assign!(person, learning_course!(modules: [mod]))
    assert CL.new(a).own_work_remaining?
  end

  test "a module with a completion row stays done after a step is added to it" do
    person = learning_person!
    mod = learning_module!(steps: ["read"])
    a = learning_assign!(person, learning_course!(modules: [mod]))
    complete_step!(person, mod.module_steps.first)
    ModuleCompletion.create!(admin_user: person, learning_module: mod, completed_at: Time.current)
    mod.module_steps.create!(position: 9, kind: "read", title: "added later")
    cl = CL.new(a)
    assert cl.module_state(mod).done?
    assert cl.all_done?
    assert_not cl.own_work_remaining?
    assert_equal [2, 1], [cl.steps_total, cl.steps_done]
  end

  test "a course with no modules is never all done" do
    a = learning_assign!(learning_person!, learning_course!(modules: []))
    assert_not CL.new(a).all_done?
  end
end
